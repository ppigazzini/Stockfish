# Stockfish developer documentation

The index. Each page owns one part of `src/` and is the claim this set makes about it.

| Page | Owns | Audience | Temperature |
|---|---|---|---|
| [00-architecture.md](00-architecture.md) | the file layout, the startup order, how a search flows, what depends on what | anyone changing more than one file | hot |
| [01-engine-board.md](01-engine-board.md) | `types.h`, `bitboard`, `attacks`, `position`, `movegen` | board and movegen | hot |
| [02-engine-search.md](02-engine-search.md) | `search`, `tt`, `history`, `movepick`, `timeman`, `score` | search | hot |
| [03-engine-eval.md](03-engine-eval.md) | `evaluate`, `nnue/` | evaluation and NNUE | hot |
| [04-multithreading.md](04-multithreading.md) | `thread`, `numa`, `shm` | threading and NUMA | hot |
| [05-tablebases.md](05-tablebases.md) | `syzygy/` | tablebase probing | hot |
| [07-shell.md](07-shell.md) | `main`, `uci`, `ucioption`, `engine`, `benchmark`, `tune` | the UCI surface and options | hot |
| [09-type-design.md](09-type-design.md) | the value domain: what each quantity means and which are distinguishable | anyone adding a type or changing an encoding | cold |
| [10-tooling-ci.md](10-tooling-ci.md) | `tests/`, `scripts/`, `.github/workflows/` | anyone adding or running a gate | hot |
| [11-references.md](11-references.md) | external links: chess programming, C++17, Make, LTO, gates | all developers | cold |
| [12-writing.md](12-writing.md) | the rules for these pages and for code comments | anyone editing a page | cold |
| [13-glossary.md](13-glossary.md) | the vocabulary, in tiers | all contributors | cold |

Numbered by reading order. A contributor works down from the architecture into a zone.

`06-platform` is unwritten: `src/numa.h`, `src/shm.h` and `src/memory.h` are described only
where [04-multithreading.md](04-multithreading.md) needs them. A reader working on the
platform layer reads the source.

The wiki covers building, usage, UCI commands and terminology for users. Nothing here
duplicates it.

```sh
./tests/docslint.sh
```

checks a dead link, a named path that does not exist, a pinned bench signature, a gate no
page names, and a tracked file pointing into the untracked working area. It cannot tell you a
sentence has become false.
