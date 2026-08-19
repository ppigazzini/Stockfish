# Endgame tablebases

`src/platform/syzygy/tbprobe.h`, `src/platform/syzygy/tbprobe.cpp`.

Syzygy tablebases give a **proven** result for positions with few enough pieces: whether the
side to move wins, draws or loses, and under DTZ how many moves until an irreversible move
must be made. Where a table answers, the search does not have to.

Audience: tablebase probing.

## Two questions, two tables

**WDL** -- win, draw or loss, five values including the cursed variants:

```cpp
WDLLoss = -2, WDLBlessedLoss = -1, WDLDraw = 0, WDLCursedWin = 1, WDLWin = 2
```

A *cursed* win is a win the fifty-move rule takes away; a *blessed* loss is a loss the rule
rescues. They exist because the tables are generated under two rules at once, and an engine
that collapsed them would claim wins it cannot convert.

**DTZ** -- distance to zeroing move. WDL says who wins; DTZ says how to make progress without
running the halfmove clock out. The search only needs DTZ at the root, where the move actually
gets played.

## Where the search uses them

Two places, and they are deliberately different.

**At the root**, `rank_root_moves` filters and ranks the move list before the search starts.
If the position is in the tables, the engine already knows the result, and the search's job
becomes choosing among moves that preserve it. This is why a tablebase win is played
correctly even at depth 1.

**Inside the search**, Step 6:

```cpp
if (!rootNode && !excludedMove && tbConfig.cardinality)
{
    int piecesCount = pos.count<ALL_PIECES>();
    if (piecesCount <= tbConfig.cardinality
        && (piecesCount < tbConfig.cardinality || depth >= tbConfig.probeDepth)
        && pos.rule50_count() == 0 && !pos.can_castle(ANY_CASTLING))
```

Every clause is load-bearing:

- `tbConfig.cardinality` is zero when no `SyzygyPath` is set, so with no tables configured
  the probe costs one predictable branch per node and nothing else.
- `rule50_count() == 0` -- the tables are generated ignoring the fifty-move rule, so a verdict
  is only sound when the clock has just been reset.
- `!can_castle(ANY_CASTLING)` -- the tables do not model castling rights at all.
- The `probeDepth` clause probes shallower positions only at the exact cardinality, because a
  probe is a disk read and doing it at every shallow node costs more than it saves.

A WDL hit returns a score at a fixed magnitude -- above any evaluation, below any mate -- so
the search can tell a proven result from an estimate. `VALUE_TB` and the
`VALUE_TB_WIN_IN_MAX_PLY` band in `types.h` reserve that range, and
[03-engine-eval.md](03-engine-eval.md) shows the evaluation being clamped to stay out of it.

## The prober

The prober is **platform code the engine reaches through a seam**. `engine/tb_source.h`
declares the three hooks the search needs -- `max_cardinality`, `probe_wdl`, `rank_root_moves`
-- along with the types they speak (`Config`, `WDLScore`, `ProbeState`, `Rule50`, `RankDTZ`),
and `platform/syzygy/tbprobe.h` re-exports those types by including it, so the prober and its
callers agree on one definition.

`Rule50` and `RankDTZ` are scoped enums over `bool` and are in the engine header rather than the
prober's for the reason the paragraph above gives: `rankDTZ` is in `rank_root_moves`'s
function-pointer type, so it crosses the seam and the search names it. They were `bool rule50,
bool rankDTZ`, adjacent in `root_probe`'s parameter list, where argument position was the only
thing separating them -- inverting the first changes the verdict a table gives, inverting the
second changes whether DTZ ranking happens at all, and transposing them compiled.

Unregistered the source answers **no tablebases loaded**, which is exactly true of an engine
with none: the search's `tbConfig.cardinality != 0` guard short-circuits before the call. That
is why `bench` cannot measure this seam -- with `SyzygyPath` empty it measures the guard. See
[00-architecture.md](00-architecture.md).

Most of `tbprobe.cpp` sits inside one anonymous namespace, and it is the only part of the
engine that **parses a file the project did not write**.

The tables are memory-mapped, indexed by a material key, and decompressed on demand: the data
is stored with a Huffman-style scheme and a pairs table, so a probe walks a compressed block
rather than reading an entry directly. That is why the code is dense -- it is a decompressor,
not a lookup.

## What a probe costs, and which axis can see it

`decompress_pairs` is the hottest symbol a probing search has, ahead of `Network::evaluate`.
Nothing on the bench list reaches it, so measure it on the position list written for it:

```sh
./tests/perfbudget.sh --syzygy tests/syzygy-34man --comp gcc --pgo <base-rev>
valgrind --tool=callgrind --dump-instr=yes ./stockfish bench 16 1 14 <bench-file> depth
```

The second is what makes the cost attributable per instruction rather than per function, and it
is the reason to reach for it before optimising: **the loop's shape is not what its source
suggests.** Decoding one symbol needs its length, and finding that length by walking `base64[]`
cost more than everything else in the function put together.

The length comes from one load. A code no longer than K bits owns a whole number of buckets of
the bitstream word's top K bits, because `base64[]` is right-padded to 64 bits -- so `lenTab[]`
maps those bits straight to a length, exactly rather than approximately. K is the
table's own `maxSymLen` under a cap, and the lengths past the cap keep the walk and say so.

**The walk that remains does not start over.** A length under the cap owns a whole number of
buckets, so a bucket `lenTab[]` declined holds no word of any length the table covers: every word
in it is at least `lenTabBits - minSymLen + 1` long, and `escapeLen` is where the scan resumes.
The index is clamped to the last `base64[]` entry, which `resize` leaves zero and which is what
stops the walk -- the clamp is what makes the index safe, rather than an argument that the escape
cannot be reached.
Everything else the loop needs per symbol is a function of that length alone and is held per
length, inline in `PairsData`.

**Inline is a register decision, not a style one.** The loop holds fifteen registers with
nothing spare, so a table behind a pointer costs it one and a spill costs more than the table
saves; reached off `d` each folds into its own load's addressing. Treat any change here as an
experiment and measure it: a per-length table that reads as free costs 5% when the compiler
materialises the address instead of folding it, and freeing a register gets it spent elsewhere
rather than banked.

**Both cache-aware gates can probe.** `tests/perfcounters.sh --syzygy DIR` and
`tests/perfdecomp.sh --syzygy DIR` load the tables and search a position list that reaches this
code, so a change here that trades footprint for instructions is measured on the axis that can
see the trade rather than on the one that reports it with the wrong sign:

```sh
../tests/perfdecomp.sh   --syzygy resources/syzygy-345-plus5   # per-component Ir and misses
../tests/perfcounters.sh --syzygy resources/syzygy-345-plus5   # the PMU, all tiers
```

The hand recipe below is what this page said to use before those options existed, and it is kept
only because a reader may need one component in isolation rather than the gate's whole table:

```sh
valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes ./stockfish bench 16 1 14 <f> depth
```

**A tablebase answer is exact, so "close" is meaningless.** An index computed one off does not
return an approximately right verdict; it returns a confident wrong one, and the search will
believe it. That property makes this the highest-consequence code in the tree per line.

The table bytes are untrusted input: they are read from disk, and nothing in the engine
produced them. Syzygy files come off public mirrors, so a bad one is something a user reaches
without doing anything wrong.

**Every field the reader takes from the file is bounded before it is used**, and one flipped
byte in a downloaded table is a case the reader has to answer rather than crash on. The header
is checked at load; the block walk and both bitstream reads are clamped; and a `base64[]` table
that is not a canonical Huffman code, a pairing that closes a loop, a flags byte contradicting
the material, a declared symbol count larger than the domain that indexes it, an empty
`blockLength[]` and a block narrower than the bitstream word are all refused.
`tests/malformed.sh` is what holds that, one fixture per field.

**Prefer a refusal at load to a test in a loop, and the alphabet is the example.** A symbol is
built from `base64[]` and `lowestSym[]`, both file data, so it can name an entry past
`symlen[]`. `set_sizes` derives the largest symbol each length can reach -- the walk stops at
the first length whose base the word clears, which bounds the word, and both tables are in hand
-- and refuses a table that could leave the domain. The decode loop then indexes with the value
straight from the file and tests nothing. **The two refusals above it exist for the same
reason and one of them is why the clamp is safe**: `blockLength[]`'s size is `blocksNum +
padding`, two file bytes, so a reader that clamps with `size - 1` on an unsigned needs the zero
refused rather than assumed.

An assert cannot carry any of this. `-DNDEBUG` deletes it from every shipped binary, so the
configuration that checks is the debug one and the configuration that walks off the end is the
one players run.

**The bounds are O(1) in the file's size, and that is a constraint rather than an
optimisation.** The tables are mmapped and paged in on demand, so a pass that walked
`sparseIndex[]` or `blockLength[]` would force a whole 6-man table resident and defeat the
laziness the reader is built on. Compare the ends, never the contents -- with a division, since
`count * stride` in `u64` wraps for a pair a crafted file can name, and a bound that wraps is a
bound the file walks straight through.

**A flags byte is a claim about the parse, not a detail.** `TBFlag::SingleValue` is 128: a
table storing one value for its whole material stops the parse after two bytes, so clearing
that bit sends an 80-byte file down the full decode path, where every span it then describes
lies past the mapping. That is why the flags byte is checked against the material the engine
asked for, and why nothing after byte 11 is read at all on the `SingleValue` path.

The PV extension is where the prober meets the clock. `syzygy_extend_pv`
(`src/engine/search.cpp`) budgets itself against `Move Overhead`, whose range starts at 0, so
it compares in microseconds through the `clock.h` seam: at whole-millisecond resolution the
abort overruns its deadline by a millisecond. See [00-architecture.md](00-architecture.md).

## Configuration

`SyzygyPath` sets the search path, `SyzygyProbeLimit` caps the piece count,
`SyzygyProbeDepth` sets the `probeDepth` the Step 6 guard compares against, and
`Syzygy50MoveRule` reaches Step 6 as `tbConfig.useRule50`, which sets the threshold the WDL
verdict is compared against: set, a cursed win scores as a nudged draw; clear, it scores as a
proven win.

`Tablebases::init` runs on the `SyzygyPath` option's `OnChange` callback and again from
`Engine::search_clear`, and it is what discovers which tables actually exist. **The option is
a ceiling, not the value.** `rank_root_moves` starts `config.cardinality` at
`SyzygyProbeLimit` and then clamps it down to `MaxCardinality`, which `init` derived from the
files it found, so asking for 7-man tables that are not on disk configures 0 rather than a
probe that fails per node.

With no path set, nothing is discovered, no probe fires, and the bench signature is
unaffected. That is the property that keeps an unconfigured engine identical to one built
without the feature.
