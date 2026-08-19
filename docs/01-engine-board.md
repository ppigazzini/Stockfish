# The board

`src/engine/types.h`, `src/engine/bitboard.h`, `src/engine/bitboard.cpp`, `src/engine/attacks.h`,
`src/engine/attacks.cpp`, `src/engine/position.h`, `src/engine/position.cpp`,
`src/engine/movegen.h`, `src/engine/movegen.cpp`.

Everything the search stands on: the value domain, square sets, attack generation, the
mutable board, and the move generator.

Audience: board and movegen.

## Where a question lands

| question | file | symbol |
|---|---|---|
| what is a move, in bits | `types.h` | `Move` |
| is this 16-bit word a real move | `types.h` | `Move::is_ok`, against `Move::none` / `Move::null` |
| what does the search see as one position | `position.h` | `Position::key`, `Position::state` |
| what a move changes, so NNUE can follow | `types.h` | `Dirties`, `DirtyPiece`, `DirtyThreats` |
| which squares does a slider attack | `attacks.h` | `Attacks::attacks_bb`, `Attacks::both_attacks_bb` |
| which of my pieces may not move | `position.h` | `Position::blockers_for_king`, `Position::pinners` |
| is this move legal | `position.cpp` | `Position::legal` |
| is a move off the transposition table even playable | `position.cpp` | `Position::pseudo_legal` |
| does it give check | `position.cpp` | `Position::gives_check` |
| make and unmake | `position.cpp` | `Position::do_move`, `Position::undo_move` |
| is this a draw | `position.cpp` | `Position::is_draw`, `Position::is_repetition`, `Position::upcoming_repetition` |
| is this capture sequence worth it | `position.cpp` | `Position::see_ge` |
| generate moves | `movegen.cpp` | `generate<GenType>`, `MoveList<GenType>` |
| where the castling rook actually is | `position.h` | `Position::castling_rook_square`, `Position::castling_impeded` |

## Startup: two `init`s in one order

`src/shell/main.cpp` calls `Attacks::init()` and then `Position::init()`, and **that order is a
requirement, not a listing**. `Position::init` builds the cuckoo table by asking
`attacks_bb(type_of(pc), s1, 0)` for every piece and square, so on any build that fills its slider
tables at run time -- the `HyperbolaMagic` and `BitboardMagic` branches below -- it reads tables
`Attacks::init` has not written yet. Reversing the two costs a wrong cuckoo table, which is a
repetition detector that silently disagrees with the rules, on the tiers where AVX2 does not put
the table in `constexpr` storage and hide the bug.

```sh
grep -n 'init()' src/shell/main.cpp
```

## `types.h` -- the value domain

Fixed-width enums for what has a fixed range -- `Color`, `CastlingRights`, `Bound`, `PieceType`,
`Piece`, `Square`, `Direction`, `File`, `Rank`, `MoveType` -- and plain aliases for what is
computed with: `Value`, `Bitboard`, `Depth`, `Key`.

```sh
grep -n '^enum' src/engine/types.h        # the ten, in declaration order
```

`Key` is the transposition key, and `Position::key()` and `Position::prefetch_key()` are the only
public accessors returning one. The pawn, minor-piece, material and non-pawn keys are stored raw in
`StateInfo` but reached only through accessors returning `TypedKey<KeySpace>`, so outside
`position.cpp` they cannot substitute for one another; see [09-type-design.md](09-type-design.md).

The encodings are load-bearing rather than arbitrary:

- `Piece` is `colour << 3 | type`, so `type_of` is `& 7` and `color_of` is `>> 3`, and `~pc`
  (flip colour) is `^ 8`. `NO_PIECE` is zero, so `color_of(NO_PIECE)` would answer `WHITE`
  rather than fail; the `assert` in `color_of` is the only thing that says so, and `-DNDEBUG`
  is what ships.
- `Square` is `rank << 3 | file`, so `flip_rank` is `^ SQ_A8` and `flip_file` is `^ SQ_H1`.
- `relative_square(c, s)` is `s ^ (c * 56)` -- a branch-free board flip. `relative_rank(c, r)`
  is `r ^ (c * 7)` for the same reason.
- A `Move` is 16 bits: destination in 0-5, origin in 6-11, promotion type minus `KNIGHT` in
  12-13, a two-bit `MoveType` in 14-15. `Move::none()` and `Move::null()` are sneaked in as
  origin equal to destination, which no real move produces -- and that is what `Move::is_ok()`
  tests. The search reads it as "was there a previous move at all": `(ss - 1)->currentMove`
  after a null move is `Move::null()`, whose `to_sq()` would index a table at square 1, so
  `search.cpp` tests `is_ok()` before using it as an index (`git grep -n 'currentMove).is_ok'
  -- src`).
- `Move::FromSqShift` and `Move::ToSqShift` exist because `movegen.cpp` assembles moves in
  vector lanes rather than through the constructor, and needs the field offsets as constants.

`SQ_NONE` is an in-band 65th value of `Square`. The free `is_ok(Square)` tests it and appears
almost entirely inside `assert`s -- the code is written so that a square is known to be on the
board by construction. Its one real use is `Attacks::safe_destination`, which is how a leaper
table refuses to wrap off the edge. It is a different function from `Move::is_ok()`.

```sh
git grep -n 'is_ok(' -- src | grep -v assert     # the non-assert uses, all but one on Move
```

`using Depth = int` is deliberate. A depth-scaled product feeds a history bonus, two score
margins, a move count, a history magnitude and a reduction denominator -- six different
codomains -- so a type carrying depth through arithmetic would need six output types, which
is the same as needing none.

`types.h` ends with `#include "../shell/tune.h"` placed **after** its own `#endif`, deliberately
outside the include guard, so the tuning macros are visible anywhere `types.h` reaches. That is
how a developer drops a `TUNE(...)` line beside a constant without adding an include. It is also
the one engine-to-shell include in the tree, and the sole entry in `tests/depcheck.baseline`.

## `bitboard.h` -- square sets

A `Bitboard` is a `u64`, one bit per square, LSB = a1. Shifts and masks do the geometry:
`shift<D>` covers the eight directions plus the two double pushes, `shift<NORTH>` is `<< 8`, and
the file masks are what stop an east or west shift wrapping onto the far edge. Drop a mask and
the generator produces a move from h4 to a5 that `legal()` will happily accept.

`pop_lsb` is how every move loop advances, so it is written as `lsb(b)` followed by `b &= b - 1`
and nothing else -- a `tzcnt`/`blsr` pair where the ISA has them. Anything added to it is added
to every iteration of every move loop in the engine. `least_significant_square_bb` is the same
bit without the index, for callers that only want the mask.

`lsb` and `msb` carry a GCC/Clang arm, two MSVC arms and `#error "Compiler not supported."`;
`popcount` has the same two arms and no `#error`, so a third toolchain fails at `lsb` rather than
at the first thing it cannot compile. `constexpr_popcount` beside them is the form a compile-time
table can call, and `src/engine/nnue/features/full_threats.cpp` is its only caller.
`constexpr_lsb` has none -- it is dead, and a grep for its callers is what says so, not a
comment.

`bitboard.cpp` holds only `Bitboards::pretty`, the ASCII dump used from a debugger.

## `attacks.h` -- slider attacks, three ways

Leapers (king, knight, pawn) come out of `PseudoAttacks`, a `constexpr` table built at compile
time. Sliders are the interesting case, and **there are three implementations**, selected by the
`#if` chain at the top of `attacks.h` in this order:

| selected when | type | how |
|---|---|---|
| `__aarch64__`, or 64-bit loongarch (`USE_HYPERBOLA_QUINT`) | `HyperbolaMagic` | hyperbola quintessence over a full 64-bit bit reversal, one attack set at a time |
| `USE_AVX2` (`USE_DUAL_HYPERBOLA_QUINT`) | `DualMagic` | hyperbola quintessence in 256-bit lanes, returning bishop and rook sets together |
| otherwise | `BitboardMagic` | magic bitboards: multiply the masked occupancy, shift, index |

```sh
grep -n 'USE_HYPERBOLA_QUINT\|USE_DUAL_HYPERBOLA_QUINT\|using Magic' src/engine/attacks.h
```

**There is no PEXT slider path.** `-DUSE_PEXT` is still a real build switch -- `src/Makefile`
sets it for the bmi2 and later x86-64 tiers -- but nothing in attack generation reads it:
`BitboardMagic::index` is unconditionally a multiply and a shift, the `pext(b, m)` macro in
`types.h` has no consumer at all, and `HasPext` reaches only the compiler banner in
`src/platform/misc.cpp`. This is a gap, not a design: on a bmi2 tier `USE_AVX2` is also set, so
the dual path wins and nobody notices the switch is inert. Do not add a PEXT row to the table
above on the strength of the macro existing.

```sh
git grep -n 'pext\|HasPext' -- src | grep -v Makefile
```

Hyperbola quintessence computes attacks arithmetically from a reversal. **The two hyperbola
variants differ in how they get the rank**, and that is not cosmetic. `HyperbolaMagic` reverses
the whole 64-bit word, so one `hyperbola()` serves every direction including the rank.
`DualMagic` reverses bytes within 128-bit lanes, which works for file, diagonal and antidiagonal
-- those put every square in a different byte -- and cannot work for a rank, where all eight
squares share one. So the AVX2 path alone carries `RankAttacks` in `attacks.cpp`, indexed by the
slider's file and the six inner bits of the rank occupancy (the edge squares never change the
attack set), `alignas(64) constexpr` so it is built at compile time rather than at startup.
`DualMagic::rankAttacksLookup` points a square at its file's row.

`DualMagic::both_attacks_bb` returns the bishop and rook attack sets for one square in a single
call. `DualMagic` is `alignas(32)` because the body loads `*this` as one aligned 256-bit vector:
the four masks are the first 32 bytes of the struct, so reordering a member above them or
dropping the alignment turns a legal aligned load into a fault.

Five call sites in `position.cpp` want both sets and get them without touching two structures --
`set_check_info`, `attackers_to`, `gives_check`, `update_piece_threats` and `see_ge`:

```sh
grep -n 'both_attacks_bb' src/engine/position.cpp
```

The non-dual path has no fused form; `Attacks::both_attacks_bb` there is two calls, which is why
the free function exists at all rather than callers reaching for `dual_magic`.

**The two non-dual layouts have two names.** `HyperbolaMagic` holds two masks; `BitboardMagic`
holds a mask, a table pointer, a multiplier and a shift. Each branch aliases the one it selected
to `Magic`, so callers are unchanged -- but a grep for `Magic` finds an alias per branch rather
than one struct, and which one a debugger shows you depends on the build.
`BitboardMagic::attacks_bb` takes a `Square` it does not use, `[[maybe_unused]]`, to match
`HyperbolaMagic::attacks_bb`: an interface shaped by a macro, and the comment beside it says so.

**Which implementation is compiled changes the code but not the answer.** Every tier must produce
the same attack sets, and what holds that is the compile matrix benching one signature after every
architecture build it does ([10-tooling-ci.md](10-tooling-ci.md)).

`Attacks::init` fills `LineBB`, `BetweenBB` and `RayPassBB` on every tier, and the slider tables
only on the two that need them. `between_bb(s1, s2)` **includes `s2`** -- the last line of the
loop is `BetweenBB[s1][s2] |= s2` -- which is what lets the evasion generator use it as a target
mask and thereby include capturing the checker.

## `position.h` / `position.cpp` -- the board

`Position` holds the piece array, the by-type and by-colour bitboards, per-piece counts, the
castling rights mask, rook squares and paths, the side to move, the game ply, the Chess960 flag,
one scratch `Dirties`, and a pointer to the current `StateInfo`. Everything else about the
position lives in the state chain.

### `StateInfo` and the copy boundary

State that cannot be recomputed cheaply is copied per move; state that can be is not. **The
member order in `StateInfo` is what implements that split**, because `do_move` copies with

```cpp
std::memcpy(&newSt, st, offsetof(StateInfo, key));
```

`key` is the first member below the `// Not copied when making a move` comment, so it is the
boundary itself. Add a member above `key` and it is copied; add it below and it must be written
unconditionally by `do_move` before anything reads it, or a node inherits the parent's value.
Neither mistake is a compile error and neither is a fault -- the first costs a copy per node, the
second is a wrong search. `do_null_move` copies `sizeof(StateInfo)` instead, because it recomputes
less.

```sh
sed -n '/^struct StateInfo/,/^};/p' src/engine/position.h
```

`previous` chains the states backwards; the chain is what repetition and fifty-move detection
walk. The states live in a `std::deque` (`StateListPtr`) rather than a `vector` **because
pointers into it must survive a resize**.

### `do_move` and `undo_move`

Two overloads. The short one -- `do_move(m, newSt, tt)` -- is for perft and for the shell
replaying a game. The search takes the long one, which additionally carries `givesCheck` (already
computed by the caller), the `Dirties&` NNUE record, and a `const SharedHistories*` for the
prefetches.

`do_move` maintains the incremental state: the Zobrist key, the pawn/minor/non-pawn/material keys,
the check information, and the dirty-piece record. It also issues the transposition and history
prefetches from the point the child's keys become final -- inside `do_move` rather than at the
caller, because that is where the lead time is longest. The four correction-history prefetches are
written out at the call site rather than wrapped in a helper: a function whose only effect is a
prefetch has no observable effect, so the compiler may delete the call, and four prefetches
silently missing score as an *improvement* on the instruction axis
([10-tooling-ci.md](10-tooling-ci.md)).

`undo_move` restores by walking `st = st->previous` and reversing the placement; it does not
restore the non-copied half, which the next `do_move` recomputes.

### Repetition, and why it is a cuckoo table

`upcoming_repetition` answers a harder question than "have we seen this position": it asks whether
the side to move *can force* a repetition, which lets the search cut off before playing it. It
still walks the state chain, two plies at a time, but at each candidate distance the question
"is the difference between these two keys a single reversible move, and which one" is answered by
two table probes rather than by generating moves. That is Marcel van Kervinck's cuckoo algorithm:
`cuckoo` and `cuckooMove` in `position.cpp`, 8192 entries, indexed by `H1` and `H2`.

The table is a pure function of the Zobrist psq and side keys, and is built in `Position::init`
where those keys are drawn -- see the ordering requirement at the top of this page.

### `see_ge` -- static exchange evaluation

`Position::see_ge(m, threshold)` answers "is the exchange on this square worth at least this
threshold" without searching it, by alternately removing the least valuable attacker. It is what
separates a good capture from a bad one in the move picker, and what several pruning rules consult
before discarding a move. It is a *bound* test, not a value: it returns a `bool` and gives no
number back, so a caller wanting the size of the exchange has to bisect it.

## `movegen.cpp` -- the generator

`generate<Type>` is instantiated for `CAPTURES`, `QUIETS`, `EVASIONS` and `NON_EVASIONS`, each
`static_assert`ing it is not `LEGAL`; `generate<LEGAL>` is a separate explicit specialisation that
calls one of the four and filters. `MoveList<Type>` in `movegen.h` is the wrapper that owns the
buffer.

Everything below `generate` is templated on colour as well as `GenType`, so the push directions
and promotion ranks fold to constants and the generator for one side has no branch on colour.

**Pseudo-legal by default.** Moves that leave the king in check are filtered by `Position::legal`
where the search makes them, not at generation:

```sh
grep -n 'pos.legal(' src/engine/search.cpp
```

Filtering earlier would cost a legality test on every generated move, and most generated moves
are never made.

**Under check, evasions are one set.** No capture/quiet split: there are few evasions and omitting
any is unsound. Under *double* check `generate_all` skips the non-king generators entirely, because
no interposition or capture can answer two checkers. Otherwise the target mask is
`between_bb(ksq, lsb(checkers))`, which includes the checker's own square, so captures of the
checker are in the same sweep.

### What `legal()` checks, and what it does not

`Position::legal` has exactly three branches:

- **castling** -- generation deliberately does not test whether the king's path is attacked, so
  `legal` walks it here. It then tests that the castling rook is not itself a blocker for its own
  king. That test is **unconditional**, not gated on Chess960: `Position::set` adopts the first
  rook it meets walking in from the corner, so a sloppy castling field records a 960 rook square
  on a board the option calls standard, and the option is not evidence about the geometry. In
  standard geometry a corner rook lies on no line between its own king and any slider, so the
  test costs one comparison and changes nothing there.
- **a king move** -- the destination must not be attacked with the king removed from the
  occupancy, or it would shield itself along the ray it is fleeing.
- **anything else** -- legal if the piece is not a blocker for its own king, or if it moves along
  the ray to or from that king.

**En passant is not one of them.** There is no `EN_PASSANT` case in `legal()`, so an en-passant
capture by an unpinned pawn falls through the third branch and is returned legal without further
test -- and the pin test genuinely cannot settle it, because the capture removes a pawn from a
square the moving pawn never occupied. What keeps an illegal en passant off the list is that
**`st->epSquare` is only ever written when a legal en-passant capture exists.** Both writers do
that check: `Position::set` walks every attacking pawn and clears the square unless one of them
can capture without exposing its king, and `do_move` sets it after a double push only when a
capturing pawn is not a blocker for the enemy king, or lies on the line from the enemy king
through the new en-passant square.

```sh
grep -n 'epSquare *=' src/engine/position.cpp
```

`generate<LEGAL>` still routes `EN_PASSANT` through `legal()` alongside king moves and pinned
pieces, so the filter reads as three disjuncts; only two of them reach a test that can reject.

```sh
grep -n 'type_of() == EN_PASSANT' src/engine/movegen.cpp
```

### `MAX_MOVES` is a buffer contract, not a headroom number

`MAX_MOVES` is 256 in `types.h`, which is above the 218 legal moves of the record position, so a
move list is a fixed array and the generator never allocates. On `USE_AVX512ICL` it is also a
**hard requirement**: `splat_moves` writes a full 512-bit register -- 32 moves -- regardless of
how many squares the bitboard held, so the buffer must have 32 slots past the worst case. A
`static_assert` in `movegen.cpp` states it, and it is the only thing that does; the function is
never told where the buffer ends and cannot check.

```sh
grep -n 'static_assert(MAX_MOVES' src/engine/movegen.cpp
```

A caller that hands `splat_moves` a pointer with fewer than 32 slots behind it corrupts whatever
follows, on one architecture, with no assert to hit.

## Chess960

Castling is stored as rights plus the rook's origin square (`castlingRookSquare`) and the squares
that must be empty (`castlingPath`), so king and rook may start anywhere on the back rank and may
pass through each other's squares. A castling move is encoded as **king takes own rook**, which is
unambiguous where "king moves two squares" is not.

`move_to_uci(m, chess960)` is where that meets the outside world: with `chess960` false it
rewrites the destination to the king's file, because that is the only form a non-Chess960 GUI
accepts.

This is why `tests/perft.sh` carries Chess960 rows: standard-chess castling hides an entire class
of bug, and the same FEN means two different positions under the two dialects.
