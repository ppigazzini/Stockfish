# Stockfish developer documentation

The index. Each page owns one subject -- a part of `src/`, the gates, or a discipline -- and
is the claim this set makes about it.

| Page | Owns | Audience | Temperature |
|---|---|---|---|
| [00-architecture.md](00-architecture.md) | the file layout, the startup order, how a search flows, the seams, what depends on what | anyone changing more than one file | hot |
| [01-engine-board.md](01-engine-board.md) | `engine/types.h`, `bitboard`, `attacks`, `position`, `movegen` | board and movegen | hot |
| [02-engine-search.md](02-engine-search.md) | `engine/search`, `search_go`, `tt`, `history`, `movepick`, `timeman`, `score` | search | hot |
| [03-engine-eval.md](03-engine-eval.md) | `engine/evaluate`, `engine/nnue/` | evaluation and NNUE | hot |
| [04-multithreading.md](04-multithreading.md) | `platform/thread`; replication as the search sees it | threading and NUMA | hot |
| [05-tablebases.md](05-tablebases.md) | `platform/syzygy/` | tablebase probing | hot |
| [06-platform.md](06-platform.md) | `platform/memory`, `numa`, `shm`, `thread_native`, `src/universal/`; the replication mechanism | porting, threading, allocation, dispatch | hot |
| [07-shell.md](07-shell.md) | `shell/main`, `uci`, `ucioption`, `engine`, `benchmark`, `perft`, `tune` | the UCI surface and options | hot |
| [09-type-design.md](09-type-design.md) | the value domain: what each quantity means and which are distinguishable | anyone adding a type or changing an encoding | cold |
| [10-tooling-ci.md](10-tooling-ci.md) | `tests/`, `scripts/`, `.github/workflows/` | anyone adding or running a gate | hot |
| [11-performance.md](11-performance.md) | the six axes, what each proves and what it cannot see; `fingerprint.sh` | anyone measuring a refactor or an optimisation | hot |
| [12-references.md](12-references.md) | external links: chess programming, C++17, Make, LTO, gates | all developers | cold |
| [13-writing.md](13-writing.md) | technical writing: pages, code comments, commit messages | anyone writing prose about this code | cold |
| [14-glossary.md](14-glossary.md) | the vocabulary, in tiers | all contributors | cold |

**The zone pages do not cover every file, and [00-architecture.md](00-architecture.md)'s layout
table is what routes the rest.** The seam headers, `engine/host`, `engine/basetypes.h`,
`engine/hashing.h`, `engine/prng.h`, `engine/compiler.h`, `platform/text`, `platform/misc` and
`shell/console` are named there and nowhere else, so a search that starts at a zone page finds
nothing for them. To find the owner of any file:

```sh
grep -n 'prng\.h' docs/*.md      # substitute any basename under src/
```

`numa` and `shm` appear once each, under `06`. The split from `04` is by question rather than
by file: `06` owns **how** replication works -- `NumaConfig`, the policy parser, the shared
mapping -- and `04` owns **why the search is shaped around it**, which is why a worker takes a
`HistoryBankIndex` rather than a topology handle. Each links to the other for the half it does
not own.

Numbered by reading order; a contributor works down from the architecture into a zone.

Building, usage, UCI commands and user-facing terminology are the
[wiki](https://github.com/official-stockfish/Stockfish/wiki)'s.

```sh
./tests/docslint.sh
```

runs seven checks -- `grep -n 'head_check "' tests/docslint.sh` is the list in order: a dead
link, a named path that does not exist, a pinned bench signature, a gate no page names, a
tracked file pointing into the untracked working area, the two copies of the performance-gate
selector table naming different gates, and the CI table naming gates the workflows do not run.
**It cannot tell you a sentence has become false**, which is the half that decides whether this set is worth reading --
[13-writing.md](13-writing.md) is how that half is bought.

**The zone boundary is checked, not described.** `src/` is `engine/`, `platform/` and `shell/`,
and the engine depends on neither of the others. The gates that hold it, the five baselines they
read and the one entry that is deliberate rather than debt are
[00-architecture.md](00-architecture.md)'s.

**Each page ends with `## The gates`**, naming what holds its claims. `owned by` reads
`this page` where the mechanics live there and names the page otherwise, so a gate is described
once and reachable from everywhere it matters.
