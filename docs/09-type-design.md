# The value domain

What the engine's quantities mean, which of them the compiler can tell apart, and which of
them it cannot.

`src/engine/types.h` owns most of it; `src/engine/basetypes.h` owns `TypedKey` and the
`KeySpace` enumerators, `src/engine/history.h` the history clamps, and
`src/engine/position.h` the key accessors. The theory each family rests on is linked in
[12-references.md](12-references.md).

Audience: anyone adding a type or changing an encoding.

## Where to look

| question | file | symbol |
|---|---|---|
| the board vocabulary and the move encoding | `src/engine/types.h` | `Color`, `Square`, `Piece`, `Move`, `DirtyThreat` |
| the key spaces | `src/engine/basetypes.h`, `src/engine/types.h` | `KeySpace`, `TypedKey`, `NonPawnKey` |
| what a key can be asked for | `src/engine/position.h` | `pawn_key`, `minor_piece_key`, `material_key`, `non_pawn_key` |
| the history clamps and the shared-bank types | `src/engine/history.h` | `StatsEntry`, `PowerOfTwo`, `InCheck`, `Capture`, `WorkerShare` |
| the tablebase flags | `src/engine/tb_source.h` | `Rule50`, `RankDTZ` |
| the gate rows that hold all of it | `tests/negative_control.sh` | `b5-*`, `b13-*`, `b20-*` |

## The instruments C++ gives, and they are not equally strong

| instrument | what it is | strength | arithmetic |
|---|---|---|---|
| a class with a private constructor and a named factory | exactly the set the factory can produce | the invariant has no false spelling | whatever the class chooses to give |
| `enum class X : T` | a distinct scoped type | a hard error on enum-to-enum **and** on `T` itself | none without a cast |
| `enum X : T` | a distinct type with a fixed underlying width | a hard error on enum-to-enum | promotes to `int` freely |
| `using X = T` | an alias | none at all | unrestricted |

**The top tier is the only one that can refuse a wrong value rather than a wrong type.**
`PowerOfTwo` in `history.h` is the instance: `SharedHistories` masks a key with `size - 1`, so
any count that is not a power of two selects a row the array does not hold. The constructor is
private and `PowerOfTwo::ceil` is the only factory, and it rounds -- so there is no
unrounded count for an assert to catch, which matters because `-DNDEBUG` is what ships.

**Reach for `enum class : bool` where a one-bit value is an index or a flag and does no
arithmetic.** Four in the tree -- `InCheck` and `Capture`, the two subscripts of the
continuation-history block, and `Rule50` and `RankDTZ`, the two flags a root probe takes:

```sh
grep -rn 'enum class [A-Za-z0-9_]* *: *bool' src/
```

Each costs nothing -- a scoped enum over `bool` is one byte and its conversion to an index is
the zero-extend the `bool` already needed -- and each leaves the transposition of its pair no
spelling at all. The underlying type is written because a fixed one makes an out-of-range
enumerator ill-formed, the same reason the enums in `types.h` carry theirs.

Almost every domain quantity here is in the third tier: `Color`, `Square`, `File`, `Rank`,
`Piece`, `PieceType`, `Direction`, `CastlingRights`, `Bound`, `MoveType`. Passing a
`Direction` where a `Square` belongs does not compile, which is why `operator+(Square,
Direction)` exists as a named operation rather than as integer addition.

`Move` is a fourth shape, between the first and the second: a class over a `u16` with an
`explicit` raw constructor and named accessors, so a raw 16-bit value does not become a move
without a visible cast. It is weaker than `PowerOfTwo` because the raw constructor is public --
the keyword stops a *conversion*, not a *construction*. `DirtyThreat` is the same shape over a
`u32` and for the same reason: `position.cpp` reads `dt_template.raw()` into
`_mm512_set1_epi32`, so the raw form is a real part of the type's use and the constructor has
to stay. What the keyword does not buy is the five-argument constructor beside it, which takes
two `Piece`s and two `Square`s and will transpose either pair in silence. That is the boundary
below, and no keyword addresses it.

**A plain alias is documentation, not a type.** `Value`, `Key`, `Bitboard` and `Depth` are
aliases, and a `Key` where a `Bitboard` belongs compiles silently.

**An alias is documentation the compiler will not hold you to, and the failure is quiet.**
`HistoryBankIndex` is the case that shows what that costs. It denotes an index into the
engine's own `std::map<HistoryBankIndex, SharedHistories>` and not a handle on the host's
topology, and the only thing that separates it from `NumaIndex` is that claim -- both are
`usize` underneath. As aliases the two are one type, so `shell/engine.h` could declare the
owning map keyed one way while `engine/search.h` bound it the other, and both declarations of
the one map are well-formed. Scoping the enum makes those two declarations disagree at compile
time. **Prose cannot report a violation of itself; only a type can.**

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
- **The continuation-history quadrant cannot be transposed.** `ContinuationHistoryBlock`
  (`history.h`) holds a private `ContinuationHistory[2][2]` indexed by in-check then capture,
  and the only way in is `ContinuationHistoryBlock::operator()(InCheck, Capture)`, which inlines
  to the same two subscripts. Two `bool`s as array *subscripts* would be strictly worse than two
  `bool` parameters, because a transposed argument still has a parameter name at its declaration
  to read against and a subscript has nothing: `[capture][inCheck]` compiles, reads a real table
  and returns plausible statistics, so the search continues, returns a legal move, and is simply
  worse. Nothing sees that -- no assert, no bound, no diagnostic -- only the bench anchor.

  ```sh
  grep -n 'continuationHistory(' src/engine/search.cpp
  ```

- **A root probe's two flags cannot be swapped.** `Tablebases::root_probe` takes `Rule50` and
  `RankDTZ`, adjacent, where inverting the first changes the verdict a table gives and inverting
  the second changes whether DTZ ranking happens at all. They are declared in
  `engine/tb_source.h` rather than in the prober because `rankDTZ` crosses the seam: it is in
  `TbSource::rank_root_moves`'s function-pointer type, so the engine has to be able to name it
  without naming the prober.
- **An enumerator that outgrows its enum is a hard error**, and no assertion is needed for it.
  Every enum in `types.h` fixes an underlying type -- `Color : u8`, `Square : u8`,
  `Direction : i8`, `MoveType : u16` -- and a fixed underlying type makes an enumerator outside
  its range ill-formed, not silently truncated. The widths are written on the enums rather than
  restated in a `static_assert`, and a restatement is the thing that could go stale.
  `types.h` carries exactly one `static_assert`, and it holds a relation no width can:
  `NonPawnKey` maps a `Color` to a `KeySpace` by addition, so `NonPawnWhite` and `NonPawnBlack`
  have to stay adjacent and in colour order.

  ```sh
  grep -n 'static_assert' src/engine/types.h
  ```

## Where a name is all you get

Two pairs were closed by bundling rather than by typing, and the difference is worth being
exact about: a struct of two same-typed members gives the pair **names at the declaration and at
every consumer**, and refuses nothing. Positional braced initialisation still transposes.

- `Search::BestMove` (`search.h`) holds two `std::string_view`s, `bestmove` and `ponder`, and
  travels through `UpdateContext::onBestmove` -- a `std::function`, so type erasure sits between
  producer and consumer and no point on that path can refuse anything. What the struct buys is a
  name at the far end: the consumer reads `bm.bestmove`. The producer still writes
  `onBestmove({bestmove, ponder})`, which is positional.
- `WorkerShare` (`history.h`) holds `index` and `total`, both `usize`, for `shared_slice` and
  `clear_range`. As two adjacent parameters the transposition keeps the arithmetic working and
  hands every worker a different slice -- and a partial cover leaves part of a history table
  holding the previous game's statistics rather than faulting. One value with two names is
  better to read; the initialiser is exactly as easy to get wrong.

Both transpositions still compile, which is why neither has a `tests/negative_control.sh` row:

```sh
printf '#include "history.h"\nusing namespace Stockfish;\n%s\n' \
  'auto f(usize i, usize n){ return shared_slice(64, {n, i}); }' > /tmp/ws.cpp
g++ -std=c++20 -Isrc/engine -fsyntax-only /tmp/ws.cpp && echo "transposes silently"
```

Closing them for real needs two different types -- `WorkerIndex` and `WorkerTotal` -- which is
the `make_square` shape below, and nothing has measured whether that is worth it here.

## Where it does not

**`KeySpace` has five enumerators and `Position` has four accessors for them**: `Pawn`,
`MinorPiece` and `Material` take one accessor each, and `NonPawnWhite` / `NonPawnBlack` are
reached through one template, `non_pawn_key<Color>()` -- a template argument and not a runtime
parameter, which is the whole point of the pair below. Each returns a `TypedKey<KeySpace>`, so
one cannot stand in for another, for a `Bitboard`, or for the transposition key:

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
for the `explicit` on `DirtyThreat(u32)`. `b20-conthist` carries `InCheck`/`Capture`,
`b20-rootprobe` `Rule50`/`RankDTZ`, `b20-powtwo` `PowerOfTwo` and `b20-bank`
`HistoryBankIndex`. Every one requires the illegal form to be refused **and** the legal ones to
build.

```sh
grep -n '^row b[0-9]' tests/negative_control.sh
```

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

**The colour is the third limit, and it is closed rather than open** -- which is what a
discriminated pair costs and buys. A single `NonPawnKey` with the colour as a runtime argument
separates the two non-pawn keys from every other space and not from each other, so
`non_pawn_key(WHITE)` where `BLACK` was meant type-checks. `NonPawnKey<Color>` in `types.h`
picks between `KeySpace::NonPawnWhite` and `KeySpace::NonPawnBlack` by adding the colour to the
first, which is why `types.h`'s one `static_assert` holds them adjacent and in colour order.
**The reader lost a parameter rather than gaining one**: `SharedHistories::nonpawn_correction`
is already `template<Color c>` and already selects the matching field with `if constexpr`, so
the key side is the half that had no discriminator. `tests/negative_control.sh`'s `b13-colour`
row requires the swap to be rejected and both legal forms to compile.

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

**Only two different types close a pair.** A struct bundling two same-typed members names them
and refuses nothing; the table says which of the two each pair got:

| pair | verdict |
|---|---|
| `move_piece(Square, Square)`, `Move::make(Square, Square, ...)` | **open.** `from` and `to` are bitfields inside `Move`, packed and unpacked on the per-node path; a `From`/`To` pair would have to survive that packing, which makes it a layout change wearing a type's clothes |
| `search`/`qsearch`'s `Value alpha, Value beta` | **open**, and it is the `Depth` argument below applied to its sibling: the window is negated, added to and compared across every recursion, so a wrapper needs unit polymorphism that C++ has not got |
| `Network::load_external`'s leading `const std::filesystem::path&` pair -- a directory and an eval-file path | **open.** One call site, at startup, and the fix has nowhere to live: the standard library has no `directory_path`, and the function needs the bare filename separately for `evalFile.current` |
| `Tablebases::root_probe`'s `rule50, rankDTZ` | **closed**, `Rule50` and `RankDTZ`: two distinct types |
| `ContinuationHistoryBlock`'s two subscripts | **closed**, `InCheck` and `Capture`: a subscript pair rather than a parameter pair -- see the case above |
| `onBestmove`'s two `string_view`s | **named**, `BestMove`. The braced initialiser still transposes |
| `shared_slice`/`clear_range`'s two `usize`s | **named**, `WorkerShare`. The braced initialiser still transposes |

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

A hypothetical `Depth::operator*` returning one type leaves the other five needing an
escape, and the choice that serves all six -- depth times an int giving an int -- turns any
depth into any integer.
**A type that needs six output types needs none.** Units-of-measure systems solve this with
unit polymorphism, which C++ cannot express; see [12-references.md](12-references.md).

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
   Without it an integer becomes a random generator and a context handle becomes an owner, at a
   call site that reads as if it passed the thing it named. `PRNG`, `AccumulatorCaches`,
   `NumaReplicated`, `LazyNumaReplicated` and `OptionalThreadToNumaNodeBinder` all take it.

   **Nothing enforces this and the tree is not uniform.** `SearchManager(const UpdateContext&)`,
   `NumaConfig(EmptyNodeTag)`, `NumaReplicationContext(NumaConfig&&)` and
   `UCIEngine(CommandLine)` are single-argument and not `explicit`. None is reached by a
   conversion today, which is a fact about their call sites rather than about the types.
   `RelaxedAtomic(T)` is the one that is implicit on purpose -- it stands in for the scalar it
   wraps. No gate row covers the keyword, so an audit is a grep over the class bodies, and it
   returns base-class initialisers and Win32 calls alongside the constructors:

   ```sh
   grep -rn --include=*.h -E '^\s+[A-Z][A-Za-z]*\([A-Za-z_:<>& ]+\)\s*(:|;|\{)' src/ | grep -v explicit
   ```

7. Add a row here -- to the table of what the compiler catches, to the boundary, or to both.

## The gates

| gate | what it proves here | owned by |
|---|---|---|
| `tests/negative_control.sh` | a type introduced so that a wrong spelling stops compiling actually refuses it -- and every legal spelling still compiles | [10-tooling-ci.md](10-tooling-ci.md) |

**One class of row mutates nothing, and it is where a new type's row goes.** A type introduced
so that a wrong spelling stops compiling has no gate to redden -- the compiler is the gate. Such
a row writes a probe translation unit, compiles it against the real headers, and asserts the
illegal form is REFUSED:

```sh
printf '#include "history.h"\nusing namespace Stockfish;\n%s\n' \
    'HistoryBankIndex f(usize n) { return n; }' > probe.cpp
( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only probe.cpp )   # must FAIL
```

`-Iengine` as well as `-I.` is load-bearing: the probes include engine headers by bare name and
`src/` is zone directories, so `-I.` alone fails to find them -- which makes the illegal form
AND the legal one fail, and scores a broken rig as a detection. So each of these rows asserts
both halves, and the second is what catches it: every legal spelling must still compile. A row
that only checked the refusal would be satisfied by a header that stopped compiling at all.

These rows are `static` by construction -- they build no engine -- and they restore nothing,
because they never touched the tree.

So a type added here is not finished until it has a row. The compiler is the gate, and a gate
nobody has watched refuse is a gate nobody has shown can fail.
