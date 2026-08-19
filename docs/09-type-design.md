# The value domain

What the engine's quantities mean, which of them the compiler can tell apart, and which of
them it cannot.

`src/engine/types.h` owns most of it; `src/engine/basetypes.h` owns `TypedKey` and the
`KeySpace` enumerators, `src/engine/history.h` the history clamps, and
`src/engine/position.h` the key accessors. The theory each family rests on is linked in
[11-references.md](11-references.md).

Audience: anyone adding a type or changing an encoding.

## The instruments C++ gives, and they are not equally strong

| instrument | what it is | strength | arithmetic |
|---|---|---|---|
| a class with a private constructor and a named factory | exactly the set the factory can produce | the invariant has no false spelling | whatever the class chooses to give |
| `enum class X : T` | a distinct scoped type | a hard error on enum-to-enum **and** on `T` itself | none without a cast |
| `enum X : T` | a distinct type with a fixed underlying width | a hard error on enum-to-enum | promotes to `int` freely |
| `using X = T` | an alias | none at all | unrestricted |

**The top tier is the only one that can refuse a wrong value rather than a wrong type.**
`PowerOfTwo` in `history.h` is the instance: `SharedHistories` masks a key with `size - 1`, so
any count that is not a power of two selects a row the array does not hold, and that used to be
a comment in capitals over an assert in a build that does not ship. The parameter is a
`PowerOfTwo` now, its constructor is private, and its only factory rounds -- so the assert did
not move, it stopped existing.

**Reach for `enum class : bool` where a one-bit value is an index or a flag and does no
arithmetic.** Four in the tree: `InCheck` and `Capture`, the two subscripts of the
continuation-history block, and `Rule50` and `RankDTZ`, the two flags a root probe takes. Each
costs nothing -- a scoped enum over `bool` is one byte and its conversion to an index is the
zero-extend the `bool` already needed -- and each closes a swap that used to compile. The
underlying type is written because a fixed one makes an out-of-range enumerator ill-formed, the
same reason the enums in `types.h` carry theirs.

Almost every domain quantity here is in the third tier: `Color`, `Square`, `File`, `Rank`,
`Piece`, `PieceType`, `Direction`, `CastlingRights`, `Bound`, `MoveType`. Passing a
`Direction` where a `Square` belongs does not compile, which is why `operator+(Square,
Direction)` exists as a named operation rather than as integer addition.

`Move` is a fourth shape, between the first and the second: a class over a `u16` with an
`explicit` raw constructor and named
accessors, so a raw 16-bit value does not become a move without a visible cast. It is weaker
than `PowerOfTwo` because the raw constructor is public -- it stops being a *conversion*, not a
*construction*. `DirtyThreat`
is the same shape over a `u32` and for the same reason -- `position.cpp` reads
`dt_template.raw()` into `_mm512_set1_epi32`, so the raw form is a real part of the type's use
and the constructor stays; it just stops being a *conversion*. What the keyword does not buy is
the five-argument constructor beside it, which takes two `Piece`s and two `Square`s and will
transpose either pair in silence. That is the boundary below, and no keyword addresses it.

**A plain alias is documentation, not a type.** `Value`, `Key`, `Bitboard` and `Depth` are
aliases, and a `Key` where a `Bitboard` belongs compiles silently.

**An alias is also documentation the compiler will not hold you to, and the failure is quiet.**
`HistoryBankIndex` carried six lines arguing it is an index into the engine's own map and not a
handle on the host's topology -- and it was `using HistoryBankIndex = usize` while
`using NumaIndex = usize` sat in `numa.h`, so the two were one type. `shell/engine.h` declared
the owning map `std::map<NumaIndex, SharedHistories>` and `engine/search.h` binds it as
`std::map<HistoryBankIndex, SharedHistories>&`: two declarations of one map, disagreeing about
what keys it, both well-formed, nothing said. Scoping the enum turned that into an error on the
next build. **The prose had already failed and only a type could report it.**

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
- **A history bonus cannot be transposed with its clamp.** `StatsEntry<T, D, Shared>` takes the
  clamp as a *template parameter*, one per table, so `operator<<(int bonus)` has nothing beside
  the bonus to swap it with. A design that passed the limit as a second argument would make both
  directions of the swap compile.
- **A non-PV root cannot be named.** `NodeType` is `{NonPV, PV, Root}`, one tag rather than
  two independent booleans. Four combinations for three meanings would make a non-PV root
  expressible, and no call site produces one. Because the tag is a template argument, the
  tests on it fold in each instantiation and it costs nothing.
- **A correction counter cannot be read through the wrong key's field.** The four counters live
  in one `CorrectionBundle`, and the accessors on `SharedHistories` return the *counter*, not
  the bundle: `pawn_correction(pos, us)` yields the pawn counter and nothing else, so pairing
  one key's row with another key's field has no expression. An accessor returning the *row*
  would leave that pairing spelled `.minor` on a row the pawn key selected, and the result
  would be a real counter of the wrong kind rather than a fault.

  ```sh
  printf '#include "history.h"\n#include "position.h"\nusing namespace Stockfish;\n%s\n' \
    'int f(SharedHistories& h, const Position& p, Color us){ return h.pawn_correction(p,us).minor; }' \
    > /tmp/t.cpp
  g++ -std=c++20 -Isrc/engine -fsyntax-only /tmp/t.cpp   # StatsEntry<...> has no member 'minor'
  ```

  `./tests/negative_control.sh b5-mismatch` is the same check as a gate row.

  **It does not stop one accessor being substituted for another.** They share a signature, so
  `minor_piece_correction` where `pawn_correction` was meant still compiles; only the bench
  signature catches that, and `./tests/negative_control.sh b5-swap` is it going red.
- **The continuation-history quadrant cannot be transposed.** `ContinuationHistoryBlock` holds a
  `ContinuationHistory[2][2]` indexed by in-check then capture, and it used to be reached as
  `continuationHistory[ss->inCheck][capture]` -- two `bool`s as array *subscripts*. That is
  strictly worse than two `bool` parameters, because a transposed argument still has a parameter
  name at its declaration to read against and a subscript has nothing: `[capture][inCheck]`
  compiles, reads a real table and returns plausible statistics, so the search continues, returns
  a legal move, and is simply worse. Nothing sees it -- no assert, no bound, no diagnostic -- only
  the bench anchor. The table is private now and the only way in is
  `block(InCheck, Capture)`, which inlines to the same two subscripts.
- **A root probe's two flags cannot be swapped.** `root_probe` took `bool rule50, bool rankDTZ`
  adjacent, where inverting the first changes the verdict a table gives and inverting the second
  changes whether DTZ ranking happens at all. They are `Rule50` and `RankDTZ` now, declared in
  `engine/tb_source.h` rather than in the prober because `rankDTZ` crosses the seam -- it is in
  `TbSource::rank_root_moves`'s function-pointer type, and the engine used to pass a bare `false`
  and a bare `true` at two call sites.
- **A bestmove cannot be swapped with its ponder move.** The pair crossed a
  `std::function<void(std::string_view, std::string_view)>` into a generic lambda, so it was
  untyped at the declaration, untyped through the erased boundary and untyped at the consumer --
  no point on the path could have refused it. It is a `BestMove` struct, which is the convention
  the other four callbacks in `UpdateContext` already followed.
- **A worker's index cannot be swapped with the count it is out of.** `shared_slice` and
  `clear_range` ended in two adjacent `usize`s, and transposing them keeps the arithmetic working
  while handing every worker a different slice. One `WorkerShare{index, total}` instead.
- **An enumerator that outgrows its enum is a hard error**, and no assertion is needed for it.
  Every enum in `types.h` fixes an underlying type -- `Color : u8`, `Square : u8`,
  `Direction : i8`, `MoveType : u16` -- and a fixed underlying type makes an enumerator outside
  its range ill-formed, not silently truncated. That is why the widths are written on the enums
  and not restated in a `static_assert`: `types.h` contains none, and a restatement is the thing
  that could go stale.

## Where it does not

**Four key spaces are distinct types**, one per `KeySpace` enumerator. `pawn_key()`,
`minor_piece_key()`, `material_key()` and `non_pawn_key(Color)` return `TypedKey<KeySpace>`
values, so one cannot stand in for another, for a `Bitboard`, or for the transposition key:

```sh
for probe in 'auto f(TranspositionTable& t, const Position& p){ return t.probe(p.pawn_key()); }' \
             'Bitboard f(const Position& p){ return p.pawn_key(); }' \
             'bool f(const Position& p){ return p.pawn_key() == p.minor_piece_key(); }'; do
  printf '#include "position.h"\n#include "tt.h"\nusing namespace Stockfish;\n%s\n' "$probe" > /tmp/k.cpp
  g++ -std=c++20 -Isrc/engine -fsyntax-only /tmp/k.cpp && echo "ACCEPTED (should not be): $probe"
done
```

`./tests/negative_control.sh b5-keyspace` runs the same three probes as a gate row, plus the
legal form -- because a row that only checked the rejections would pass if the header stopped
compiling at all. `b13-colour` is the same shape for `NonPawnKey<Color>`, and `b13-dirtythreat`
for the `explicit` on `DirtyThreat(u32)`; `b20-conthist`, `b20-rootprobe`, `b20-powtwo` and
`b20-bank` carry the four types above. Every one requires the illegal form to be refused **and**
the legal ones to build.

The algebra is deliberately tiny: produce, store, pass, compare against a key of the same
space, mask to an index, truncate to a tag. **There is no `operator^`.** Keys are *built* by
xor-ing Zobrist words, and one
`Zobrist::psq[pc][s]` is xor-ed into the position, pawn, non-pawn and minor-piece keys alike:

```sh
grep -n 'Zobrist::psq\[pc\]\[s\]' src/engine/position.cpp
```

A public xor would therefore let any space absorb any other's material -- the mixing the type
exists to prevent. Construction stays on the raw `u64` inside `position.cpp`, which is the only
file that reads one, and the type begins at the accessors.

Two limits. **Masking does not distinguish spaces**: `key & mask` yields an index for any of
them, because that is how the history tables are indexed, so a swap at an indexing site still
compiles. And **the transposition key is a bare `Key`**: `posKey` is live across `search()`,
which is the shape the cost rule below warns about, so wrapping it is an experiment to re-run
with `tests/perfbudget.sh --pgo` under both compilers rather than a tidy-up to apply. The
guarantee that matters survives anyway, since passing a typed key where the bare one belongs is
still rejected.

**The colour used to be a third**, and it is the one that shows what the fix costs. The two
non-pawn keys shared `NonPawnKey`, so `non_pawn_key(WHITE)` where `BLACK` was meant compiled --
the type separated spaces and the colour was an argument. `KeySpace` has `NonPawnWhite` and
`NonPawnBlack` now and `NonPawnKey<Color>` picks between them by adding the colour to the first,
which a `static_assert` holds adjacent. **The reader lost a parameter rather than gaining one**:
`HistoryBundle::nonpawn_correction` was already `template<Color c>` and already selected the
matching field with `if constexpr`, so the key side was the half that had not been discriminated
yet. `tests/negative_control.sh`'s `b13-colour` row requires the swap to be rejected and both
legal forms to compile.

**`using Key = u64` is the transposition key alone**, reached through `key()` and
`prefetch_key()`. `Bitboard` is the same underlying type, so a transposition key where a
`Bitboard` belongs still compiles -- and so does the reverse.

The raw position key is not an accessor at all: it is `StateInfo::key`, reachable from outside
only through the public `Position::state()`, and nothing takes that route. The two readers are
`Position::key` in `position.h` and `position.cpp` itself.

The sharpest pair is the raw position key and the transposition key, and the type does not
separate them -- both are `Key`. `Position::adjust_key50` mixes the halfmove clock in only at
and above a threshold, so **below it the two words are identical**: a confusion between them
passes every position where the clock is low and is wrong only later in a game, and no perft
can see it, because perft counts leaves and a key that desyncs and resyncs produces the same
count.

What limits the exposure is scope rather than typing. `adjust_key50` is templated on
`AfterMove` for exactly this reason, and all three call sites choose correctly: `Position::key`
and the transposition prefetch inside `do_move` take the default, because `st->rule50` has
already been advanced by the time either runs, and `prefetch_key` takes `<true>` because it
runs before the move -- and returns the key unadjusted on a capture or a pawn move, where the
child's clock resets below the threshold.

**Two arguments of the same type transpose in silence.** `Move(from, to)` takes two
`Square`s and is reversible, and so is any pair of `Color`s or same-typed keys. No type in
this family addresses that.

**The pairs that were closed were closed by giving the two arguments different types**, and the
ones still open are open for a reason rather than by omission:

| pair | verdict |
|---|---|
| `move_piece(Square, Square)`, `Move::make(Square, Square, ...)` | **open.** `from` and `to` are bitfields inside `Move`, packed and unpacked on the per-node path; a `From`/`To` pair would have to survive that packing, which makes it a layout change wearing a type's clothes |
| `search`/`qsearch`'s `Value alpha, Value beta` | **open**, and it is the `Depth` argument below applied to its sibling: the window is negated, added to and compared across every recursion, so a wrapper needs unit polymorphism that C++ has not got |
| `Network::load_external(path, path)` | **open.** One call site, at startup, and the fix has nowhere to live: the standard library has no `directory_path`, and the function needs the bare filename separately for `evalFile.current` |
| `root_probe`'s `rule50, rankDTZ` | **closed**, `Rule50` and `RankDTZ` |
| `on_bestmove`'s two `string_view`s | **closed**, `BestMove` |
| `shared_slice`/`clear_range`'s two `usize`s | **closed**, `WorkerShare` |
| `continuationHistory[inCheck][capture]` | **closed**, and it was not a parameter pair at all -- see the subscript case above |

`make_square(File, Rank)` is the counter-example, and it is where the technique shows its
hand: the two arguments are *different* types, so the transposition is a compile error rather
than a silent swap.

```sh
printf '#include "types.h"\nusing namespace Stockfish;\nint main(){File f=FILE_A;Rank r=RANK_1;return make_square(r,f);}\n' > /tmp/t.cpp
g++ -std=c++20 -Isrc/engine -fsyntax-only /tmp/t.cpp    # error: cannot convert Rank to File
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

`Search::Worker::search` is the largest function in the tree and holds many live values, which
is exactly the shape the rule warns about -- [02-engine-search.md](02-engine-search.md) carries
the command that measures it. The rule is about what a function *holds*, not what it is
*parameterised by*: a template argument occupies no register, which is why `NodeType` costs
nothing on the hottest function in the engine while a runtime flag in the same position would
not.

**The rule is predictive, not exact.** Treat a type on a hot path as an experiment and measure
it: `tests/perfbudget.sh` with `--comp gcc` and `--comp clang`, and again with `--pgo`, because
one compiler cannot distinguish a change from its own codegen and PGO is what ships.

## Adding a type

1. Say which set it denotes, and give it constructors that are the only way into that set.
2. Give it the algebra the quantity actually has and no more. An operator added because it is
   convenient will be used where it should not be.
3. Check the value is **carried**, not computed with. If it participates in arithmetic inside
   the node body, expect a cost.

   Where a quantity is constructed by arithmetic but only carried afterwards, the type belongs
   at the boundary between the two. The keys are the case in point: every one is built by
   XOR-ing Zobrist words, and one `Zobrist::psq[pc][s]` is XOR-ed into the position, pawn,
   non-pawn and minor-piece keys alike, so no typed key could permit the construction without
   also permitting the mixing. Construction stays untyped inside
   `position.cpp`; a type would begin at the accessors, which is the only place the rest of
   the tree sees a key at all. **Type at the boundary or not at all** -- typing one side of it
   reintroduces the cast at the other.
4. **Make the mutation fail.** Break the code on purpose in the way the type is meant to stop,
   build it, and confirm the compiler rejects it. Arguing that it would fail is not watching
   it fail.
5. Gate it: the bench signature must not move, and `tests/perfbudget.sh` under both compilers
   and with `--pgo`. **Not `textequal.sh`** -- a parameter's type is part of the mangled name, so
   a typing change renames every symbol that mentions it and the gate, which matches bodies by
   name, compares none of them. It answers only for a change that keeps every signature; the
   subscript and container cases above are the ones it can settle.
6. **If it is a converting constructor, add `explicit`** unless the conversion is the point.
   `PRNG(u64)`, `AccumulatorCaches(const Network&)`, `NumaReplicated(ctx&)`,
   `LazyNumaReplicated(ctx&)` and `OptionalThreadToNumaNodeBinder(NumaIndex)` all lacked it: an
   integer became a random generator, a handle became an owner.
7. Add a row here -- to the table of what the compiler catches, to the boundary, or to both.
