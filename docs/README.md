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
| [10-tooling-ci.md](10-tooling-ci.md) | `tests/`, `scripts/`, `.github/workflows/` | anyone adding or running a gate | hot |
| [12-writing.md](12-writing.md) | the rules for these pages and for code comments | anyone editing a page | cold |

Numbered by reading order. A contributor works down from the architecture into a zone.

`06-platform`, `08`, `09-type-design`, `11-references` and `13-glossary` are unwritten. The
platform layer, the value domain and the vocabulary are undocumented; a reader needing them
reads the source.

The wiki covers building, usage, UCI commands and terminology for users. Nothing here
duplicates it.

```sh
./tests/docslint.sh
```

checks a dead link, a named path that does not exist, a pinned bench signature, a gate no
page names, and a tracked file pointing into the untracked working area. It cannot tell you a
sentence has become false.
