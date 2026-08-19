# Endgame tablebases

`src/platform/syzygy/tbprobe.h`, `src/platform/syzygy/tbprobe.cpp`, and the seam that reaches them,
`src/engine/tb_source.h`.

Syzygy tablebases give a **proven** result for positions with few enough pieces: whether the
side to move wins, draws or loses, and under DTZ how many moves until an irreversible move
must be made. Where a table answers, the search does not have to.

Audience: tablebase probing.

## Where each thing lives

| Question | File | Symbol |
|---|---|---|
| what the engine is allowed to ask | `engine/tb_source.h` | `TbSource`, `Config`, `WDLScore`, `ProbeState`, `Rule50`, `RankDTZ` |
| who fills the seam | `shell/engine.cpp` | `tb_probe_wdl`, `tb_max_cardinality`, `tb_rank_root` |
| ranking the root move list | `platform/thread.cpp` | `ThreadPool::start_thinking` |
| ranking, and the cardinality clamp | `platform/syzygy/tbprobe.cpp` | `Tablebases::rank_root_moves` |
| the DTZ and WDL root passes | `platform/syzygy/tbprobe.cpp` | `root_probe`, `root_probe_wdl` |
| the in-search probe | `engine/search.cpp` | Step 6 of `Worker::search` |
| extending a PV to mate | `engine/search.cpp` | `syzygy_extend_pv` |
| finding and opening a file | `platform/syzygy/tbprobe.cpp` | `TBFile`, `TBFile::map`, `TBTables` |
| parsing a table header | `platform/syzygy/tbprobe.cpp` | `set` (the template), `set_groups`, `set_sizes`, `set_dtz_map` |
| decoding a symbol | `platform/syzygy/tbprobe.cpp` | `decompress_pairs` |
| refusing a bad file | `tests/malformed.sh` | one fixture per field |

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
gets played, and `Tablebases::probe_dtz` carries the sign and off-by-one rules in a comment
above itself that is longer than most functions here. Read it before touching the ranking.

## Where the search uses them

**At the root**, before any thread starts: `ThreadPool::start_thinking` builds `rootMoves` and calls
`Tablebases::rank_root_moves` **directly**, not through the seam -- both are platform code. The
result is one `Tablebases::Config` copied into every `Worker` as `w.tbConfig`.

`rank_root_moves` **ranks; it does not filter**. `root_probe` writes a `tbRank` and a `tbScore` onto
each root move and nothing is erased, then `rank_root_moves` stable-sorts by `tbRank`. The narrowing
happens in the MultiPV loop of `iterative_deepening`, which walks forward only while `tbRank` is
equal to the first move's, so the lines actually searched are the top-rank group. That is why a
tablebase win is played correctly even at depth 1, and it is also why `Skill::pick_best` recomputes
its score range explicitly: with tablebases at the root the list is ordered by rank, not by score.

**The root result usually turns the in-search probe off.** When `config.rootInTB` holds and either
DTZ was available or the root is not winning, `rank_root_moves` sets `config.cardinality = 0` -- so
Step 6 below short-circuits for the whole search. Probing during the search is what happens when the
DTZ tables are missing and the side to move is winning, which is the only case where the search
still has to find the conversion itself.

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

A WDL hit scores as `VALUE_TB - ss->ply` -- above any evaluation, below any mate -- so the
search can tell a proven result from an estimate. `VALUE_TB` and the
`VALUE_TB_WIN_IN_MAX_PLY` band in `types.h` reserve that range, and
[03-engine-eval.md](03-engine-eval.md) shows the evaluation clamped to stay out of it.
`tbConfig.useRule50` decides the threshold the verdict is compared against: set, `WDLCursedWin`
falls in the draw arm and scores `VALUE_DRAW + 2`; clear, it clears the threshold and scores as a
proven win.

**`probe_wdl` must write `*result` on every path.** The Step 6 caller branches on it to decide
whether the returned `WDLScore` is a verdict at all, so a prober that returns without writing turns
an unrelated value into a cutoff and stores a fabricated score in the transposition table. The
caller seeds `err = FAIL` before the call for exactly that reason; the bundled prober writes `OK`
first and the seed is what protects an injected one. Nothing else catches it -- see below on why
`bench` cannot.

## The seam

The prober is **platform code the engine reaches through a seam**. `engine/tb_source.h`
declares the three hooks the search needs -- `max_cardinality`, `probe_wdl`, `rank_root_moves`
-- along with the types they speak (`Config`, `WDLScore`, `ProbeState`, `Rule50`, `RankDTZ`),
and `platform/syzygy/tbprobe.h` re-exports those types by including it, so the prober and its
callers agree on one definition.

`Rule50` and `RankDTZ` are scoped enums over `bool`, and they live in the engine header rather than
the prober's because `rankDTZ` is in `rank_root_moves`'s function-pointer type: it crosses the seam,
so the search names it. **Neither converts to the other and neither converts to `bool`**, which is
the property that matters at the call site. `root_probe` takes both, adjacent; inverting the first
changes the verdict a table gives, inverting the second changes whether DTZ ranking happens at all,
and a pair of plain `bool`s in that position would let a transposition compile.

Unregistered the source answers **no tablebases loaded**, which is exactly true of an engine
with none: the search's `tbConfig.cardinality != 0` guard short-circuits before the call. That
is why `bench` cannot measure this seam -- with `SyzygyPath` empty it measures the guard. See
[00-architecture.md](00-architecture.md).

## The files

Most of `tbprobe.cpp` sits inside one anonymous namespace, and it is the only part of the
engine that **parses a file the project did not write**.

`Tablebases::init` splits `SyzygyPath` on `:` (`;` on Windows) into `TBFile::Paths`, builds the
indexing tables, and then enumerates every material combination up to `TBPIECES` pieces, adding a
`TBTable` for each name a path holds. Nothing is mapped yet: `MaxCardinality` is a count of files
found. The mapping happens on the first probe, in `TBFile::map`, and three things are checked there
before a byte of content is read:

| Check | Value | On failure |
|---|---|---|
| file name | `KQvK.rtbw` for WDL, `.rtbz` for DTZ | the file is not found, so the table is absent |
| size | `st_size % 64 == 16` | "Corrupt tablebase file", `baseAddress` left null |
| magic, first 4 bytes | `71 E8 23 5D` WDL, `D7 66 0C A5` DTZ | "Corrupted table in file", unmapped, null |

**A refusal here is not fatal, and that is deliberate.** The size test is all this reader can say
about an interrupted download, and it runs on the first *probe* -- so ending the process there would
end it mid-search with a GUI waiting on a `bestmove`. A refused table is a table the engine does not
have, which is a state it already knows how to be in.

The mapping is `MAP_SHARED`, `PROT_READ`, with `madvise(MADV_RANDOM)`: the tables are paged in on
demand and never read end to end.

Past the magic, the data is a header describing a compressed body. The template `set` drives the
whole parse -- `grep -n 'bool set(T& e' src/platform/syzygy/tbprobe.cpp` -- and returns false the
moment a span leaves the mapping. Under it, `set_groups` reads the piece order and computes the
index space, `set_sizes` reads the block geometry and the Huffman alphabet,
`set_dtz_map` reads the DTZ value map, and the three span arrays -- `sparseIndex[]`, `blockLength[]`
and the data blocks themselves -- are bounded once against the end of the mapping and then used
through the pointer and size stored beside them. A probe therefore walks a compressed block rather
than reading an entry directly. That is why the code is dense: it is a decompressor, not a lookup.

## What a probe costs, and which axis can see it

`decompress_pairs` is the hottest symbol a probing search has. Nothing on the bench list reaches it,
so it has to be measured on a corpus and a position list written for that:

```sh
./tests/tbfetch.sh --men 4     # -> tests/syzygy-34man,   pairs with tests/tbprobe.fens
./tests/tbfetch.sh --men 5     # -> resources/syzygy-5man, pairs with tests/tbprobe5.fens
```

**The corpus and the positions must match.** Every gate below defaults `--fens` to
`tests/tbprobe.fens`, which is 4-man: running those against a 5-man corpus probes the small tables
and leaves the big one unread, which measures the decoder on the wrong data.

```sh
cd src && ../tests/perfbudget.sh --syzygy ../tests/syzygy-34man --comp gcc --pgo <base-rev>
valgrind --tool=callgrind --dump-instr=yes ./stockfish bench 16 1 14 <bench-file> depth
```

The second is what makes the cost attributable per instruction rather than per function, and it
is the reason to reach for it before optimising: **the loop's shape is not what its source
suggests.** Decoding one symbol needs its length, and finding that length by walking `base64[]`
cost more than everything else in the function put together.

The length comes from one load. A code no longer than K bits owns a whole number of buckets of
the bitstream word's top K bits, because `base64[]` is right-padded to 64 bits -- so `lenTab[]`
maps those bits straight to a length, exactly rather than approximately. K is `lenTabBits`, the
table's own `maxSymLen` under the `LenTabMaxBits` cap, and the lengths past the cap keep the walk
and say so with `NoFastLen`.

**The walk that remains does not start over.** A length under the cap owns a whole number of
buckets, so a bucket `lenTab[]` declined holds no word of any length the table covers.
`escapeLen` is where the scan resumes: `lenTabBits - minSymLen + 1`, floored at 0 and **clamped to
the last `base64[]` entry**, which `resize` leaves zero and which is therefore what stops the walk.
The clamp is what makes the index safe; there is no argument that the escape cannot be reached.
Everything else the loop needs per symbol is a function of that length alone and is held per length,
inline in `PairsData` as `symBaseOf[]` and `shiftOf[]`.

**Inline is a register decision, not a style one.** The loop holds fifteen registers with
nothing spare, so a table behind a pointer costs it one and a spill costs more than the table
saves; reached off `d` each folds into its own load's addressing. Treat any change here as an
experiment and measure it: a per-length table that reads as free costs 5% when the compiler
materialises the address instead of folding it, and freeing a register gets it spent elsewhere
rather than banked.

**Both cache-aware gates can probe**, and both resolve their default `--fens` relative to the
current directory, so run them from the repository root rather than from `src/`:

```sh
./tests/perfdecomp.sh   --syzygy tests/syzygy-34man   # per-component Ir and misses
./tests/perfcounters.sh --syzygy tests/syzygy-34man   # the PMU, all tiers
```

They load the tables and search a position list that reaches this code, so a change here that trades
footprint for instructions is measured on the axis that can see the trade rather than on the one
that reports it with the wrong sign. `tests/perfcomponents.tsv` carries the `tablebase probe` row
they decompose into, and on a default profile that row reports MATCHED NOTHING -- which is the
point: it makes the absence visible instead of letting a bound placed inside `decompress_pairs`
read as free.

One component in isolation still wants the hand recipe:

```sh
valgrind --tool=callgrind --cache-sim=yes --branch-sim=yes ./stockfish bench 16 1 14 <f> depth
```

## Untrusted input

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
`tests/malformed.sh` is what holds that, one fixture per field. It builds under
`sanitize="address undefined" debug=yes`, so an out-of-bounds read the shipped build would absorb
into mmap page padding is reported rather than survived, and it exits 2 rather than 0 when the 3-man
corpus is absent -- a skip is not a pass.

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

**Two different flags bytes are claims about the parse, and they are checked separately.**

The **table** flags byte is the first byte after the magic. Its `Split` and `HasPawns` bits are a
claim about a layout the reader has already sized from the material it asked for -- `sides` and
`maxFile` come from `e.key != e.key2` and `e.hasPawns` -- so `set` refuses a file whose flags
disagree with its own name rather than parsing on. `tests/malformed.sh`'s `flags-vs-material`
fixture is that byte, at offset 4 of the smallest table.

The **`PairsData`** flags byte is `set_sizes`'s first read, and `TBFlag::SingleValue` is 128: a
table storing one value for its whole material stops the parse after two bytes -- the flags and
the value -- so on the smallest table nothing after offset 11 is read at all. Clear that bit and
an 80-byte file goes down the full decode path, where every span it then describes lies past the
mapping.
`tests/malformed.sh`'s `corpus-flags` fixture clears it in a real `KNvK.rtbw`, which is the shape a
bad download actually produces.

## Extending a PV into the tables

`syzygy_extend_pv` (`src/engine/search.cpp`) runs from `output_pv` for any root move with a
tablebase score that is not a mate. It has two steps and they answer different questions.

**Step 1 truncates.** It walks the search's own PV and, at each ply, calls `rank_root_moves` on the
legal moves and keeps going only while the PV move's `tbRank` equals the best one's. The first ply
where they differ ends the PV. A repetition or a fifty-move draw along the way also ends it, because
a shown PV that draws is not a PV for a win.

**Step 2 extends to mate**, playing the top-ranked (minimal-DTZ) move each ply until there are no
legal moves. The result is *a possible continuation, not a proven mating line*: DTZ-optimal play
gives optimal mates only for simple endgames. The loop's own
`while (rootMove.pv.size() < MAX_PLY)` is what keeps it inside `PVMoves`'s `Capacity`, which is
`MAX_PLY + 1`. That guard is the only bound: `PVMoves::push_back` checks its own with an `assert`
alone, so nothing in the shipped build would catch a relaxation of it.

This is where the prober meets the clock. The whole function budgets itself against `Move Overhead`,
whose range starts at 0, so it compares in microseconds through the `clock.h` seam: at
whole-millisecond resolution `2 * 0 > 0` is false and the abort overruns its deadline by a
millisecond. See [00-architecture.md](00-architecture.md). The budget is only armed when
`limits.use_time_management()` holds, so under `go infinite`, `go depth` and `go movetime` it never
fires and the only bounds are the tables running out and `MAX_PLY`.

## Configuration

`SyzygyPath` sets the search path, `SyzygyProbeLimit` caps the piece count,
`SyzygyProbeDepth` sets the `probeDepth` the Step 6 guard compares against, and
`Syzygy50MoveRule` reaches Step 6 as `tbConfig.useRule50` and `root_probe` as `Rule50`. All four are
registered in `Engine::Engine` ([07-shell.md](07-shell.md)).

`Tablebases::init` runs on the `SyzygyPath` option's `OnChange` callback and again from
`Engine::search_clear`, and it is what discovers which tables actually exist. **The option is
a ceiling, not the value.** `rank_root_moves` starts `config.cardinality` at
`SyzygyProbeLimit` and then clamps it down to `MaxCardinality`, which `init` derived from the
files it found, so asking for 7-man tables that are not on disk configures 0 rather than a
probe that fails per node. The clamp also zeroes `probeDepth`, so tables smaller than the limit are
searched from depth 0.

With no path set, nothing is discovered, no probe fires, and the bench signature is
unaffected. That is the property that keeps an unconfigured engine identical to one built
without the feature.
