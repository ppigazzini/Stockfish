# The board

`src/engine/types.h`, `src/engine/bitboard.h`, `src/engine/bitboard.cpp`, `src/engine/attacks.h`, `src/engine/attacks.cpp`,
`src/engine/position.h`, `src/engine/position.cpp`, `src/engine/movegen.h`, `src/engine/movegen.cpp`.

Everything the search stands on: the value domain, square sets, attack generation, the
mutable board, and the move generator.

Audience: board and movegen.

## `types.h` -- the value domain

Fixed-width enums for the things that have a fixed range -- `Color`, `Square`, `File`,
`Rank`, `Piece`, `PieceType`, `Direction`, `CastlingRights`, `Bound`, `MoveType` -- and plain
aliases for the things that are computed with: `Value`, `Bitboard`, `Depth`, and `Key`. `Key`
is the transposition key: `Position::key()` and `Position::prefetch_key()` are the only
accessors that return one. The pawn, minor-piece, material and non-pawn keys are stored raw in
`StateInfo` but reached only through accessors returning `TypedKey<KeySpace>`, so outside
`position.cpp` they cannot substitute for one another; see
[09-type-design.md](09-type-design.md).

The encodings are load-bearing rather than arbitrary:

- `Piece` is `colour << 3 | type`, so `type_of` is `& 7`, `color_of` is `>> 3`, and `~pc`
  (flip colour) is `^ 8`.
- `Square` is `rank << 3 | file`, so `flip_rank` is `^ SQ_A8` and `flip_file` is `^ SQ_H1`.
- `relative_square(c, s)` is `s ^ (c * 56)` -- a branch-free board flip.
- A `Move` is 16 bits: destination in 0-5, origin in 6-11, promotion type in 12-13, a
  two-bit special flag in 14-15. `Move::none()` and `Move::null()` are sneaked in as origin
  equal to destination, which no real move produces.

`SQ_NONE` is an in-band 65th value of `Square`. `is_ok(Square)` exists to test it and appears
almost entirely inside `assert`s -- the code is written so that a square is known to be on
the board by construction, rather than tested at every use.

`using Depth = int` is deliberate. A depth-scaled product feeds a history bonus, two score
margins, a move count, a history magnitude and a reduction denominator -- six different
codomains -- so a type carrying depth through arithmetic would need six output types, which
is the same as needing none.

`types.h` ends with `#include "../shell/tune.h"` placed **after** its own `#endif`,
deliberately outside the include guard, so the tuning macros are visible anywhere `types.h`
reaches. That is how a developer can drop a `TUNE(...)` line beside a constant without adding
an include. It is also the one engine-to-shell include in the tree, and the sole entry in
`tests/depcheck.baseline`.

## `bitboard.h` -- square sets

A `Bitboard` is a `u64`, one bit per square, LSB = a1. Shifts and masks do the geometry:
`shift<NORTH>` is `<< 8`, and the file masks stop a shift wrapping around the board edge.

`pop_lsb` is how every move loop advances, so it is written as `lsb(b)` followed by
`b &= b - 1` and nothing else -- a `tzcnt`/`blsr` pair where the ISA has them. Anything added
to it is added to every iteration of every move loop in the engine.

## `attacks.cpp` -- slider attacks, three ways

Leapers (king, knight, pawn) are a table lookup. Sliders are the interesting case, and which
implementation compiles is decided by the macros at the top of `attacks.h`:

| macro | selected when | how |
|---|---|---|
| `USE_DUAL_HYPERBOLA_QUINT` | `USE_AVX2` | hyperbola quintessence through a `DualMagic`, returning bishop and rook sets together |
| `USE_HYPERBOLA_QUINT` | `__aarch64__`, or 64-bit loongarch | hyperbola quintessence, one attack set at a time |
| neither, with `USE_PEXT` | BMI2 available | PEXT extracts the occupancy index directly, so the table is dense |
| neither, without PEXT | everything else | magic bitboards: multiply the masked occupancy, shift, index |

Hyperbola quintessence computes attacks arithmetically from a reversal. **The two variants
differ in how they get the rank**, and that is not cosmetic. `USE_HYPERBOLA_QUINT` reverses
the whole 64-bit word, so the same `hyperbola()` serves every direction including the rank.
`USE_DUAL_HYPERBOLA_QUINT` reverses bytes within 128-bit lanes, which works for file, diagonal
and antidiagonal -- those put every square in a different byte -- and cannot work for a rank,
where all eight squares share one. So the AVX2 path alone carries `RankAttacks`, a table
indexed by the slider's file and the six inner bits of the rank occupancy, `alignas(64)
constexpr` so it is built at compile time rather than at startup.

`DualMagic::both_attacks_bb` returns the bishop and rook attack sets for one square in a
single call. `DualMagic` is `alignas(32)` because the body starts with
`_mm256_load_si256(reinterpret_cast<const __m256i*>(this))`: the four masks are the first 32
bytes of the struct and are loaded as one aligned vector, so reordering a member above them or
dropping the alignment turns a legal aligned load into a fault. `Position::set_check_info` and
`Position::attackers_to` are the callers that need both sets, and they get them without
touching two structures.

**Which implementation is compiled changes the code but not the answer.** Every tier must
produce the same attack sets, and what holds that is the compile matrix benching one signature
after every architecture build it does ([10-tooling-ci.md](10-tooling-ci.md)).

## `position.cpp` -- the board

`Position` holds the piece placement, the by-type and by-colour bitboards, the side to move,
the castling rights, and a pointer to a `StateInfo`.

### `StateInfo` and the chain

State that cannot be recomputed cheaply is copied per move; state that can be is not. The
struct is split by that rule, with a comment marking the boundary:

```
// Not copied when making a move (will be recomputed anyhow)
Key        key;
Bitboard   checkersBB;
StateInfo* previous;
Bitboard   blockersForKing[COLOR_NB];
...
```

`previous` chains the states backwards, and the chain is what repetition and fifty-move
detection walk. The states live in a `std::deque` (`StateListPtr`) rather than a `vector`
**because pointers into it must survive a resize**.

`do_move` maintains the incremental state: the Zobrist key, the pawn/minor/non-pawn/material
keys, the check information, and the NNUE dirty-piece record. It also issues the
transposition and history prefetches from the point the child's keys become final -- inside
`do_move` rather than at the caller, because that is where the lead time is longest.

### Repetition, and why it is a cuckoo table

`upcoming_repetition` answers a harder question than "have we seen this position": it asks
whether the side to move *can force* a repetition, which lets the search cut off before
playing it. It uses Marcel van Kervinck's cuckoo algorithm -- an 8192-entry table of the
Zobrist keys of all reversible one-piece moves, with two hash functions, so a candidate
repetition is found by two lookups rather than a walk.

The table is a pure function of the Zobrist psq and side keys, and is built where those keys
are drawn.

### `see_ge` -- static exchange evaluation

Answers "is the exchange on this square worth at least this threshold" without searching it,
by alternately removing the least valuable attacker. It is what separates a good capture from
a bad one in the move picker, and what several pruning rules consult before discarding a move.

## `movegen.cpp` -- the generator

Pseudo-legal by default: moves that leave the king in check are filtered by `legal()` at the
point the search makes them, not at generation. Filtering earlier would cost a legality test
on every generated move, and most generated moves are never made.

`legal()` checks three cases and re-derives nothing:

- **castling** -- generation deliberately does not test whether the king's path is attacked,
  so `legal` walks it here, plus a Chess960 test that the castling rook was not itself
  blocking a check;
- **a king move** -- the destination must not be attacked with the king removed from the
  occupancy, or it would shield itself along the ray it is fleeing;
- **anything else** -- legal if the piece is not pinned, or if it moves along the ray to or
  from its own king.

En passant is not one of them. It cannot be settled by a pin test, because the capture
removes a pawn from a square the moving pawn never occupied. `generate<LEGAL>` in
`src/engine/movegen.cpp` therefore routes an `EN_PASSANT` move through the full `legal()`
check instead of the pin shortcut, alongside king moves and pinned pieces -- one filter
predicate, three disjuncts:

```sh
grep -n 'type_of() == EN_PASSANT' src/engine/movegen.cpp
```

Generation is templated on `GenType` -- `CAPTURES`, `QUIETS`, `EVASIONS`, `NON_EVASIONS`,
`LEGAL` -- and on colour, so the direction constants fold and the generator for one side has
no branches on colour.

**Under check, evasions are generated as one set.** There is no capture/quiet split, because
there are few evasions and omitting any is unsound.

`MAX_MOVES` is 256, which is above the maximum number of legal moves in any reachable
position, so a move list is a fixed array and the generator never allocates.

## Chess960

Castling is stored as rights plus the rook's origin square, so the king and rook may start
anywhere on the back rank and may pass through each other's squares. A castling move is
encoded as **king takes own rook**, which is unambiguous where "king moves two squares" is
not.

This is why `tests/perft.sh` carries Chess960 rows: standard-chess castling hides an entire
class of bug, and the same FEN means two different positions under the two dialects.
