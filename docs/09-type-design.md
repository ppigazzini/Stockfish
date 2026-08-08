# The value domain

What the engine's quantities mean, which of them the compiler can tell apart, and -- stated
as plainly as the rest -- which of them it cannot.

`src/types.h` owns most of it; `src/history.h` owns the history clamps and
`src/position.h` the key accessors. The theory each family rests on is linked in
[11-references.md](11-references.md).

Audience: anyone adding a type or changing an encoding.

## The two instruments C++ gives, and they are not equally strong

| instrument | what it is | strength | arithmetic |
|---|---|---|---|
| `enum : T` | a distinct type with a fixed underlying width | a hard error on enum-to-enum | promotes to `int` freely |
| `using X = T` | an alias | none at all | unrestricted |

Almost every domain quantity here is in the first tier: `Color`, `Square`, `File`, `Rank`,
`Piece`, `PieceType`, `Direction`, `CastlingRights`, `Bound`, `MoveType`. Passing a
`Direction` where a `Square` belongs does not compile, which is why `operator+(Square,
Direction)` exists as a named operation rather than as integer addition.

`Move` is a third shape: a class over a `u16` with an `explicit` raw constructor and named
accessors, so a raw 16-bit value does not become a move without a visible cast.

**A plain alias is documentation, not a type.** `Value`, `Key`, `Bitboard` and `Depth` are
aliases, and a `Key` where a `Bitboard` belongs compiles silently.

## The encodings, and what depends on them

Each of these is load-bearing arithmetic, not a naming convention:

| encoding | what it buys |
|---|---|
| `Piece = colour << 3 \| type` | `type_of` is `& 7`, `color_of` is `>> 3`, `~pc` is `^ 8` |
| `Square = rank << 3 \| file` | `flip_rank` is `^ SQ_A8`, `flip_file` is `^ SQ_H1` |
| `relative_square(c, s) = s ^ (c * 56)` | a branch-free board flip |
| `relative_rank(c, r) = r ^ (c * 7)` | the same for ranks |
| `Move`: to in 0-5, from in 6-11, promotion in 12-13, flag in 14-15 | a move is one `u16`, and a move list is a fixed array |
| `Move::none()` / `Move::null()` have from == to | two sentinels inside the encoding, because no real move has them equal |

`PIECE_NB` is 16 rather than 12 because the encoding leaves a gap at `type == 0` and
`type == 7` in each colour. Indexing a `[PIECE_NB]` array by a `Piece` is therefore direct,
and the unused rows are the price.

## Where the compiler helps

- **A `Direction` cannot reach a `Square` parameter**, and the reverse. `operator+(Square,
  Direction)` is the only bridge.
- **A history bonus cannot be transposed with its clamp.** `StatsEntry<T, D>` takes the clamp
  as a *template parameter*, one per table, so `operator<<(int bonus)` has nothing beside the
  bonus to swap it with. A design that passed the limit as a second argument would make both
  directions of the swap compile.
- **A non-PV root cannot be named.** `NodeType` is `{NonPV, PV, Root}`, one tag rather than
  two independent booleans. Four combinations for three meanings would make a non-PV root
  expressible, and no call site produces one. Because the tag is a template argument, the
  tests on it fold in each instantiation and it costs nothing.
- **A correction counter cannot be read through the wrong key's field.** The four counters live
  in one `CorrectionBundle`, and the accessors on `SharedHistories` return the *counter*, not
  the bundle: `pawn_correction(pos, us)` yields the pawn counter and nothing else, so pairing
  one key's row with another key's field has no expression. It used to: the accessor returned
  the row, the caller wrote `.minor`, and the result was a real counter of the wrong kind
  rather than a fault.

  ```sh
  # h.pawn_correction(pos, us).minor
  # error: StatsEntry<short int, 1024, true> has no member named 'minor'
  ./tests/negative_control.sh b5-mismatch
  ```

  **It does not stop one accessor being substituted for another.** They share a signature, so
  `minor_piece_correction` where `pawn_correction` was meant still compiles; only the bench
  signature catches that, and `./tests/negative_control.sh b5-swap` is it going red.
- **A widened domain type is caught at compile time.** `types.h` closes with the relationships
  that imply each width -- `PIECE_NB` against `COLOR_NB`, `SQUARE_NB` against the bitboard
  width -- so an assertion cannot go stale against a literal.

## Where it does not

A page that omits its own boundary invites over-trust.

**Five of the six key spaces are distinct types.** `pawn_key()`, `minor_piece_key()`,
`material_key()` and `non_pawn_key(Color)` return `TypedKey<KeySpace>` values, so one cannot
stand in for another, for a `Bitboard`, or for the transposition key:

```sh
./tests/negative_control.sh b5-keyspace
# tt.probe(pos.pawn_key())                    -- cannot convert
# Bitboard b = pos.pawn_key()                 -- cannot convert
# pos.pawn_key() == pos.minor_piece_key()     -- no match for operator==
```

The algebra is deliberately tiny: produce, store, pass, mask to an index, truncate to a tag.
**There is no `operator^`.** Keys are *built* by xor-ing Zobrist words, and
`Zobrist::psq[pc][s]` is xor-ed into the position, pawn, non-pawn and minor-piece keys alike
(`position.cpp:501-515`), so a public xor would let any space absorb any other's material --
the mixing the type exists to prevent. Construction stays on the raw `u64` inside
`position.cpp`, which is the only file that reads one, and the type begins at the accessors.

Two limits, both by design. **Masking does not distinguish spaces**: `key & mask` yields an
index for any of them, because that is how the history tables are indexed, so a swap at an
indexing site still compiles. And **the transposition key is still a bare `Key`**: typing it
cost +0.0212% and +0.0241% on two PGO lanes, because `posKey` is live across `search()` and the
wrapper perturbs register allocation there -- the cost rule's own prediction, measured. The
guarantee that matters survives anyway, since passing a typed key where the bare one belongs is
still rejected.

**One key space shares the alias.** `using Key = u64` is now the transposition key alone, reached through
`key()` and `prefetch_key()`. The other four accessors are typed --
`key()`, `prefetch_key()`, `material_key()`, `pawn_key()`, `minor_piece_key()` and
`non_pawn_key(Color)`, the last being one accessor over two spaces. The raw position key is
not among them: it is `StateInfo::key`, reached through `Position::state()`, and no file
outside `position.cpp` reads it. `Bitboard` is the same underlying type, so a `Key` where a
`Bitboard` belongs also compiles.

The sharpest pair is the position key and the transposition key. `Position::adjust_key50`
mixes the halfmove clock in only at and above a threshold, so **below it the two words are
identical** -- a confusion between them passes every position where the clock is low and is
wrong only later in a game. No perft can see it.

**Two arguments of the same type transpose in silence.** `Move(from, to)` takes two
`Square`s and is reversible, and so is any pair of `Color`s or same-typed keys. No type in
this family addresses that.

`make_square(File, Rank)` is the counter-example, and it is where the technique shows its
hand: the two arguments are *different* types, so the transposition is a compile error rather
than a silent swap.

```sh
printf '#include "types.h"\nusing namespace Stockfish;\nint main(){File f=FILE_A;Rank r=RANK_1;return make_square(r,f);}\n' > /tmp/t.cpp
g++ -std=c++20 -Isrc -fsyntax-only /tmp/t.cpp    # error: cannot convert Rank to File
```

**A wrong index that is in range.** Every enum here is a distinct type over an integer, not a
refinement over a range. It narrows which *space* an index lives in, never which *entry*. The
Syzygy prober is the sharpest case: an index computed one off returns a confident wrong
verdict rather than failing.

**`Value` is an alias, so a score and a margin are the same type.** The search is full of
margins -- futility, aspiration delta, razoring thresholds -- and each is an `int` compared
against scores that are also `int`. A wrapper would turn every arithmetic site into a
function call in the code read most directly against its own tuning history.

**`SQ_NONE` is in-band.** `Square` has a 65th value, and `is_ok(Square)` is the test. In
practice it appears almost entirely inside `assert`s, because callers know by construction
that a square is on the board -- but the type does not enforce that.

**`cutNode` is a bare `bool` passed positionally**, next to a `Depth`, in
`search(pos, ss, alpha, beta, depth, cutNode)`. Both of its values are legal, so this is a
provenance problem rather than an illegal-state one.

## Why there is no `Depth` type

Deliberate. A depth-scaled product feeds at least six different codomains:

| expression shape | scales into |
|---|---|
| a depth-scaled bonus, clamped | a history bonus |
| `alpha - c1 - c2 * depth * depth` | a `Value` margin |
| `beta - c * depth + ...` | a `Value` margin |
| `(c + depth * depth) / (c - improving)` | a move count |
| `history < -c * depth` | a history magnitude |
| `r += r * c / (c * depth + c)` | a reduction denominator |

A `Mul` returning one type leaves the other five needing an escape, and the choice that
serves all six -- depth times an int giving an int -- turns any depth into any integer.
**A type that needs six output types needs none.** Units-of-measure systems solve this with
unit polymorphism, which C++ cannot express; see [11-references.md](11-references.md).

## The cost of a type here

A wrapper is not free, and the direction is not predictable from the source.

> A newtype over a scalar is free while the value is **carried** -- produced, stored, passed,
> indexed with. It can cost when many instances are **live at once inside one large
> function**, because that is a register-allocation problem and the wrapper perturbs it.

`Search::Worker::search` is one 910-line function holding many live values, which is exactly
the shape the rule warns about. The rule is about what a function *holds*, not what it is
*parameterised by*: a template argument occupies no register, which is why `NodeType` costs
nothing on the hottest function in the engine while a runtime flag in the same position would
not.

**The rule is predictive, not exact.** Treat a type on a hot path as an experiment and
measure it -- `tests/perfbudget.sh`, both tiers and both build modes.

## Adding a type

1. Say which set it denotes, and give it constructors that are the only way into that set.
2. Give it the algebra the quantity actually has and no more. An operator added because it is
   convenient will be used where it should not be.
3. Check the value is **carried**, not computed with. If it participates in arithmetic inside
   the node body, expect a cost.

   Where a quantity is constructed by arithmetic but only carried afterwards, the type belongs
   at the boundary between the two. The keys are the case in point: every one is built by
   XOR-ing Zobrist words, and `Zobrist::psq[pc][s]` is XOR-ed into the position, pawn,
   non-pawn and minor-piece keys alike (`position.cpp:501-515`), so no typed key could permit
   the construction without also permitting the mixing. Construction stays untyped inside
   `position.cpp`; a type would begin at the accessors, which is the only place the rest of
   the tree sees a key at all. **Type at the boundary or not at all** -- typing one side of it
   reintroduces the cast at the other.
4. **Make the mutation fail.** Break the code on purpose in the way the type is meant to stop,
   build it, and confirm the compiler rejects it. Arguing that it would fail is not watching
   it fail.
5. Gate it: the bench signature must not move, and `tests/perfbudget.sh` at two tiers.
6. Add a row here -- to the table of what the compiler catches, to the boundary, or to both.
