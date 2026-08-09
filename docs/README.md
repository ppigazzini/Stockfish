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
| [06-platform.md](06-platform.md) | `memory`, `numa`, `shm`, `thread_native`, `universal/` | porting, threading, allocation, dispatch | hot |
| [07-shell.md](07-shell.md) | `main`, `uci`, `ucioption`, `engine`, `benchmark`, `tune` | the UCI surface and options | hot |
| [09-type-design.md](09-type-design.md) | the value domain: what each quantity means and which are distinguishable | anyone adding a type or changing an encoding | cold |
| [10-tooling-ci.md](10-tooling-ci.md) | `tests/`, `scripts/`, `.github/workflows/` | anyone adding or running a gate | hot |
| [11-references.md](11-references.md) | external links: chess programming, C++17, Make, LTO, gates | all developers | cold |
| [12-writing.md](12-writing.md) | technical writing: pages, code comments, commit messages | anyone writing prose about this code | cold |
| [13-glossary.md](13-glossary.md) | the vocabulary, in tiers | all contributors | cold |

Numbered by reading order. A contributor works down from the architecture into a zone.
Building, usage, UCI commands and user-facing terminology are the
[wiki](https://github.com/official-stockfish/Stockfish/wiki)'s.

```sh
./tests/docslint.sh
```

checks a dead link, a named path that does not exist, a pinned bench signature, a gate no
page names, and a tracked file pointing into the untracked working area. **It cannot tell you
a sentence has become false**, which is the half that decides whether this set is worth
reading -- [12-writing.md](12-writing.md) is how that half is bought.

**The zone boundary is checked, not described.** `src/` is `engine/`, `platform/` and `shell/`,
the engine depends on neither of the others, and four gates hold that: `tests/depcheck.sh` at
the include, `tests/linkcheck.sh` at the symbol, `tests/enginelink.sh` at the link, and
`tests/fuzzsearch.sh` by running the engine with no host at all. Both symbol baselines are
empty and are meant to stay that way.
