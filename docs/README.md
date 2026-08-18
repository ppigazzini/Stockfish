# Stockfish developer documentation

The index. Each page owns one subject -- a part of `src/`, the gates, or a discipline -- and
is the claim this set makes about it.

| Page | Owns | Audience | Temperature |
|---|---|---|---|
| [00-architecture.md](00-architecture.md) | the file layout, the startup order, how a search flows, what depends on what | anyone changing more than one file | hot |
| [01-engine-board.md](01-engine-board.md) | `types.h`, `bitboard`, `attacks`, `position`, `movegen` | board and movegen | hot |
| [02-engine-search.md](02-engine-search.md) | `search`, `tt`, `history`, `movepick`, `timeman`, `score` | search | hot |
| [03-engine-eval.md](03-engine-eval.md) | `evaluate`, `nnue/` | evaluation and NNUE | hot |
| [04-multithreading.md](04-multithreading.md) | `thread`; replication as the search sees it | threading and NUMA | hot |
| [05-tablebases.md](05-tablebases.md) | `syzygy/` | tablebase probing | hot |
| [06-platform.md](06-platform.md) | `memory`, `numa`, `shm`, `thread_native`, `universal/`; the replication mechanism | porting, threading, allocation, dispatch | hot |
| [07-shell.md](07-shell.md) | `main`, `uci`, `ucioption`, `engine`, `benchmark`, `tune` | the UCI surface and options | hot |
| [09-type-design.md](09-type-design.md) | the value domain: what each quantity means and which are distinguishable | anyone adding a type or changing an encoding | cold |
| [10-tooling-ci.md](10-tooling-ci.md) | `tests/`, `scripts/`, `.github/workflows/` | anyone adding or running a gate | hot |
| [11-references.md](11-references.md) | external links: chess programming, C++17, Make, LTO, gates | all developers | cold |
| [12-writing.md](12-writing.md) | technical writing: pages, code comments, commit messages | anyone writing prose about this code | cold |
| [13-glossary.md](13-glossary.md) | the vocabulary, in tiers | all contributors | cold |

`numa` and `shm` appear once each, under `06`. They used to appear under both, which made the
index contradict its own first sentence -- and an index that declares an overlap is worse than
two pages that merely have one, because de-duplicating the bodies then leaves the table lying
about a tidy tree. The split is by question rather than by file: `06` owns **how** replication
works -- `NumaConfig`, the policy parser, the shared mapping -- and `04` owns **why the search
is shaped around it**, which is why a worker takes a `HistoryBankIndex` rather than a topology
handle. Each links to the other for the half it does not own.

Numbered by reading order. A contributor works down from the architecture into a zone. **There
is no `08`**: it was a reservation that was never written and never existed as a file in any
ref, so the gap is a gap and not a deletion. Renumbering would cost every inbound link its
target for nothing.
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
`tests/fuzzsearch.sh` by running the engine with no host at all. Each of the first two asks about
both edges out of the engine, so there are four baselines; three are empty and meant to stay that
way, and the fourth is `types.h -> tune.h`.
