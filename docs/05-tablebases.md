# Endgame tablebases

`src/syzygy/tbprobe.h`, `src/syzygy/tbprobe.cpp`.

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

Most of `tbprobe.cpp` sits inside one anonymous namespace, and it is the only part of the
engine that **parses a file the project did not write**.

The tables are memory-mapped, indexed by a material key, and decompressed on demand: the data
is stored with a Huffman-style scheme and a pairs table, so a probe walks a compressed block
rather than reading an entry directly. That is why the code is dense -- it is a decompressor,
not a lookup.

**A tablebase answer is exact, so "close" is meaningless.** An index computed one off does not
return an approximately right verdict; it returns a confident wrong one, and the search will
believe it. That property makes this the highest-consequence code in the tree per line.

The table bytes are untrusted input: they are read from disk, and nothing in the engine
produced them.

## Configuration

`SyzygyPath` sets the search path, `SyzygyProbeLimit` caps the piece count, and
`SyzygyProbeDepth` sets the depth threshold above. `Tablebases::init` is called when the path
option changes, and it is what discovers which tables actually exist -- `cardinality` is
derived from the files found, not from the option.

With no path set, nothing is discovered, no probe fires, and the bench signature is
unaffected. That is the property that keeps an unconfigured engine identical to one built
without the feature.
