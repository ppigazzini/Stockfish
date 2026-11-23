# Stockfish developer documentation

The index. Each page owns one subject -- a part of `src/`, the gates, or a discipline -- and
is the claim this set makes about it.

| Page | Owns | Audience | Temperature |
|---|---|---|---|
| [architecture.md](architecture.md) | the file layout, the startup order, how a search flows, the seams, what depends on what | anyone changing more than one file | hot |
| [engine-board.md](engine-board.md) | `engine/types.h`, `bitboard`, `attacks`, `position`, `movegen` | board and movegen | hot |
| [engine-search.md](engine-search.md) | `engine/search`, `search_go`, `tt`, `history`, `movepick`, `timeman`, `score` | search | hot |
| [engine-eval.md](engine-eval.md) | `engine/evaluate`, `engine/nnue/` | evaluation and NNUE | hot |
| [multithreading.md](multithreading.md) | `platform/thread`; replication as the search sees it | threading and NUMA | hot |
| [tablebases.md](tablebases.md) | `platform/syzygy/` | tablebase probing | hot |
| [platform.md](platform.md) | `platform/memory`, `numa`, `shm`, `thread_native`, `src/universal/`; the replication mechanism | porting, threading, allocation, dispatch | hot |
| [shell.md](shell.md) | `shell/main`, `uci`, `ucioption`, `engine`, `benchmark`, `perft`, `tune` | the UCI surface and options | hot |
| [idiomatic-cpp.md](idiomatic-cpp.md) | the C++17 this tree commits to, the spellings that measured, and the detector for each | hot-path and build contributors | hot |
| [type-design.md](type-design.md) | the value domain: what each quantity means and which are distinguishable | anyone adding a type or changing an encoding | cold |
| [performance.md](performance.md) | the seven axes, what each proves and what it cannot see; `fingerprint.sh` | anyone measuring a refactor or an optimisation | hot |
| [tooling-ci.md](tooling-ci.md) | `tests/`, `scripts/`, `.github/workflows/` | anyone adding or running a gate | hot |
| [references.md](references.md) | external links: chess programming, C++17, Make, LTO, gates | all developers | cold |
| [writing.md](writing.md) | technical writing: pages, code comments, commit messages; the site they are published as | anyone writing prose about this code | cold |
| [glossary.md](glossary.md) | the vocabulary, in tiers | all contributors | cold |

**The zone pages do not cover every file, and [architecture.md](architecture.md)'s layout
table is what routes the rest.** The seam headers, `engine/host`, `engine/basetypes.h`,
`engine/hashing.h`, `engine/prng.h`, `engine/compiler.h`, `platform/text`, `platform/misc` and
`shell/console` are named there and nowhere else, so a search that starts at a zone page finds
nothing for them. To find the owner of any file -- search the stem, because a page names a
file as `engine/arena` or `platform/text` about as often as it writes the extension:

```sh
grep -n 'prng' docs/*.md      # substitute any basename under src/, WITHOUT its extension
```

`numa` and `shm` appear once each, under `platform.md`. The split from `multithreading.md` is
by question rather than by file: `platform.md` owns **how** replication works -- `NumaConfig`,
the policy parser, the shared mapping -- and `multithreading.md` owns **why the search is shaped
around it**, which is why a worker takes a `HistoryBankIndex` rather than a topology handle.
Each links to the other for the half it does not own.

Each page is named for what it holds, and the order a reader meets them in is the site's nav,
which this table follows: a contributor works down from the architecture into a zone. The set
is published as a site with `llms.txt`; [writing.md](writing.md) says how.

Building, usage, UCI commands and user-facing terminology are the
[wiki](https://github.com/official-stockfish/Stockfish/wiki)'s.

```sh
./tests/docslint.sh
```

runs eight checks -- `grep -n 'head_check "' tests/docslint.sh` is the list in order: a dead
link, a named path that does not exist, a pinned bench signature, a gate no page names, a
tracked file pointing into the untracked working area, the two copies of the performance-gate
selector table naming different gates, the CI table naming gates the workflows do not run, and a
page with no `## The gates` section or a section routing a gate to a page that does not carry
it.
**It cannot tell you a sentence has become false**, which is the half that decides whether this set is worth reading --
[writing.md](writing.md) is how that half is bought.

**The zone boundary is checked, not described.** `src/` is `engine/`, `platform/` and `shell/`,
and the engine depends on neither of the others. The gates that hold it, the five baselines they
read and the one entry that is deliberate rather than debt are
[architecture.md](architecture.md)'s.

**Each page ends with `## The gates`**, naming what holds its claims. `owned by` reads
`this page` where the mechanics live there and names the page otherwise, so a gate is described
once and reachable from everywhere it matters.
