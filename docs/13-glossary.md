# Glossary

The vocabulary the rest of the set uses. Owns no source.

The words the rest of this set uses without stopping to define them, in tiers that must not
be confused:

- **Section 1 is the engine's vocabulary.** Chess-programming or Stockfish terms; the entry
  says which symbol carries the word here. It does not teach the concept -- the domain
  reference is a link in [11-references.md](11-references.md).
- **Section 2 is this repository's own vocabulary.** Words for the gates and the build that
  no chess-programming reference will define.
- **Section 3 is the words that mean two things here.** Each entry is a disambiguation
  rather than a definition.
- **Section 4 is the testing field's vocabulary.** The literature owns it, which is what
  makes it worth using: a term there is searchable outside this repository and a step name
  is not.

Audience: all contributors.

Every entry names the file, symbol or step that owns it, and none quotes a number a gate
computes.

## 1. The engine's vocabulary

| term | what carries it here |
|---|---|
| **bench** | the fixed position list and depth in `src/shell/benchmark.cpp`, run by `bench` in `src/shell/uci.cpp`. The transposition table is cleared between positions, so the total does not depend on their order |
| **the bench signature** | the node total `bench` prints, asserted by `tests/signature.sh`. The number lives in the commit record, in the `Bench:` line of the last functional commit; `tests/docslint.sh` refuses a page that quotes it |
| **node** | one execution of `Search::Worker::search<NodeType>` (or `qsearch`). **Not** a NUMA node -- see Section 3 |
| **ply** | one half-move. `ss->ply` counts from the root of the current search; `Position::game_ply()` counts from the start of the game. They are both `int` and they measure from different origins |
| **depth** | `using Depth = int`, deliberately. A depth-scaled product feeds a history bonus, two score margins, a move count, a history magnitude and a reduction denominator, so a type carrying it would need six output types |
| **`Value`** | the search's score domain, `using Value = int`. The band above `VALUE_TB_WIN_IN_MAX_PLY` is reserved for tablebase verdicts and mates, which is why `evaluate.cpp` clamps into it |
| **key** | a `u64` Zobrist hash. Seven distinct spaces share the alias: the position key, the transposition key (`Position::adjust_key50` mixes the halfmove clock in), the pawn, minor-piece, material and two non-pawn keys |
| **the transposition table** | `src/engine/tt.cpp`: clusters of three `TTEntry` in 32 bytes, shared across threads without a lock. `depth8` is the occupancy test, which is why `DEPTH_UNSEARCHED` and `DEPTH_NONE` are negative and distinct |
| **cluster** | the 32-byte unit the table is an array of, sized to divide a cache line so one probe touches one line |
| **the history tables** | `src/engine/history.h`. Every one is a gravity table: `operator<<` moves the stored value toward the bonus in proportion to its distance from the clamp `D`, which is a template parameter, one per table |
| **continuation history** | a plane per (piece, destination) of the *previous* move, each plane a history over the current move. `ContinuationHistory` in `src/engine/history.h` |
| **correction history** | tables recording how far the static evaluation of positions sharing a pawn structure, minor-piece configuration or non-pawn material count has been from what the search found. The node starts from the corrected value |
| **the move picker** | `src/engine/movepick.cpp`, staged: each stage is generated only when the previous one runs out. Four sequences -- main, evasion, probcut, quiescence |
| **stand-pat** | the static evaluation used as a lower bound in quiescence, before any capture is tried |
| **SEE** | static exchange evaluation, `Position::see_ge`. Answers whether an exchange on a square is worth at least a threshold, without searching it |
| **the optimum and the maximum** | the two numbers `src/engine/timeman.cpp` produces. The optimum is the point past which a new iteration is not started; the maximum is the point past which the search stops wherever it is |
| **nodestime** | the mode in which the whole clock model is denominated in nodes rather than milliseconds. The `time` reported to the GUI stays real milliseconds |
| **the accumulator** | the NNUE first layer's output for the current position, updated per move rather than recomputed. `src/engine/nnue/nnue_accumulator.cpp` |
| **refresh** | recomputing an accumulator rather than updating it, forced by a king move under a king-bucketed feature set. The refresh cache diffs against the last accumulator computed in that bucket |
| **dirty piece / dirty threats** | the record `Position::do_move` leaves of exactly what changed, so the accumulator update knows which features to subtract and add. `DirtyPiece` and `DirtyThreats` in `src/engine/types.h` |
| **psqt and positional** | the network's two output heads. Their sum is the raw evaluation; their difference is the complexity term `evaluate.cpp` blends with |
| **optimism** | the per-worker search disposition blended into the evaluation, one of the three reasons Lazy SMP threads diverge |
| **Lazy SMP** | the threading model: N workers on one root, sharing the transposition table, with no work queue and no split points |
| **the vote** | `ThreadPool::get_best_thread`, which picks the answer by weighted agreement across threads rather than by taking the deepest or highest-scoring |
| **WDL, DTZ** | the two Syzygy results -- win/draw/loss, and distance to a zeroing move. `src/platform/syzygy/tbprobe.cpp` |
| **cursed win, blessed loss** | a win the fifty-move rule takes away, and a loss it rescues. `WDLCursedWin` and `WDLBlessedLoss` in `syzygy/tbprobe.h` exist because the tables are generated under two rules at once |
| **cardinality** | the largest piece count the loaded tablebases cover. Zero with no `SyzygyPath`, which is what makes the Step 6 probe one predictable branch for a user with no tables |

## 2. This repository's vocabulary

None of this is chess-programming vocabulary.

| term | what carries it here |
|---|---|
| **gate** | a script under `tests/` that answers one question and exits 0, 1 or 2. Listed in [10-tooling-ci.md](10-tooling-ci.md) |
| **lane** | a workflow job that runs a gate. `tests/lanecheck.sh` holds every gate to having one, or to carrying an excuse that says what runs it |
| **reachable** | of a workflow: something can start it -- a push, a pull request, a schedule, a release, or a `uses:` from another reachable workflow. `workflow_dispatch` alone is not reachable, because a lane only a human can click does not gate a change |
| **excuse** | a recorded reason a gate has no lane, in `tests/lanecheck.sh`. It expires in both directions: an excused gate that *is* dispatched is a stale excuse, and an excuse naming a script the tree no longer has fails |
| **the budget** | `tests/perfbudget.sh`: retired instructions, base against head, both built and measured in one run with no stored golden |
| **the floor** | the delta between two builds of identical source. What the budget's tolerance must sit above |
| **startup subtraction** | measuring the network load and table build separately and subtracting them, because they are a large share of a short bench |
| **VOID** | a comparison the gates refuse rather than price: the two sides searched a different number of nodes, or loaded different networks |
| **codegen equivalence** | `tests/textequal.sh`: the same instructions per symbol, LTO off and the build stamp cleared. Evidence for pure code motion, and not a statement about the shipped binary |
| **the fingerprint** | `tests/fingerprint.sh`: per-function call counts. Asks whether the engine still reaches its answer by calling what it called, as often -- which no value gate can see |
| **the negative control** | `tests/negative_control.sh`: breaking the engine on purpose and requiring each gate to notice |
| **rig fault** | a negative-control run that proved nothing rather than detecting something -- a rotted anchor, a mutation that did not compile, a timeout. Never credited as a detection |
| **the build stamp** | `GIT_SHA`, `GIT_DATE` and `GIT_DIFFINDEX`, compiled into `misc.o`. Two revisions embed different strings, which shifts rodata and therefore every rip-relative displacement |
| **tier** | an enumerated `ARCH=` value. A performance number without its tier is not a number |
| **the counters** | `tests/perfcounters.sh`: the CPU's own PMU events -- instructions, cycles, cache and branch misses -- read through `perf_event_open`. The only axis that runs above AVX2, because callgrind implements no AVX-512 |
| **the decomposition** | `tests/perfdecomp.sh`: per-component instructions, D1 read misses and mispredicts, grouped by `tests/perfcomponents.tsv`. Answers *where*, where the counters answer *whether* |
| **self cost** | a symbol's own instructions, excluding its callees. The cost line after callgrind's `calls=` is the callee's *inclusive* cost and is skipped; summing it counts the NNUE evaluation inside `search` and again inside itself |
| **paired ratio** | head over base within ONE round, then the median across rounds -- not the ratio of the medians. A round is the only comparison in which both sides saw the same machine state |
| **the spread** | the min and max of those per-round ratios. A ratio whose spread straddles 1.000 has established no direction, whatever its median reads |
| **multiplexing** | the kernel time-slicing more events than the PMU has slots, so a counter covers only part of the run. The read format carries enabled/running to scale it; an unscaled reading under-reports silently |
| **hot / cold** | of a page: whether it describes code that moves. [12-writing.md](12-writing.md) |
| **zone** | one of `src/engine/`, `src/platform/`, `src/shell/`. A file's zone is its directory, so a new file joins one by where it is put. `tests/zones.sh` is the single mapping both zone checks read |
| **seam** | a struct of function pointers the engine declares, reads through a getter, and the host fills once before the first search. The engine names no host type; the host names the engine's. Catalogued in [00-architecture.md](00-architecture.md) |
| **the composition root** | `src/shell/engine.cpp`: the one file that calls a seam's setter. Nothing else does |
| **the arena** | `src/engine/arena.h`, the allocation seam. Unregistered it falls back to plain aligned allocation, which is why a block must never be taken from one allocator and released by the other |
| **a default that refuses** | a seam whose unregistered behaviour would be a *different* answer rather than a slower one, so it declines instead. The worker set refuses a count above one; a silent single-threaded search would still print a number |
| **headless** | running the engine with no seam registered. `Search::go` (`src/engine/search_go.h`) is the entry; `tests/enginelink.sh` and `tests/fuzzsearch.sh` are the two callers |
| **the standalone link** | `tests/enginelink.sh`: compile `src/engine/` alone, link with a stub `main` and nothing else, fail on any undefined symbol. Stronger than a symbol-set intersection, which cannot see an inline call |
| **the corpus** | the inputs a fuzzer keeps because they reached new coverage. Without one persisted across runs, a nightly job re-derives the same shallow coverage every night |

## 3. Words that mean two things

| word | the two meanings |
|---|---|
| **node** | a search node (`Worker::search`), or a **NUMA node** (`src/platform/numa.h`). Both appear on the same page in [04-multithreading.md](04-multithreading.md) |
| **depth** | the search depth of a node, or the `--depth` argument to the perf gates, which is a bench depth |
| **key** | a Zobrist hash, or the 16-bit fragment of one stored in a `TTEntry` |
| **generation** | the transposition table's age counter, or the act of producing moves (`movegen`) |
| **stage** | a move picker stage, or a step in a CI job |
| **bound** | `BOUND_UPPER`/`BOUND_LOWER`/`BOUND_EXACT` on a stored score, or the alpha-beta window bounds |
| **history** | an ordering table (`src/engine/history.h`), or git history |
| **cluster** | the 32-byte transposition unit, or a machine cluster running fishtest |
| **check** | the king being attacked, or a gate assertion |
| **magic** | the multiplier in magic bitboards, or `DualMagic`, which despite the name uses hyperbola quintessence at avx2 and above |

## 4. The testing field's vocabulary

Neither this repository nor Stockfish owns these; the literature does, and
[11-references.md](11-references.md) links it.

| term | as used here |
|---|---|
| **SPRT** | the sequential probability ratio test fishtest runs. A functional change ships with one |
| **Elo** | the strength scale an SPRT reports in. No gate in this tree measures it |
| **mutation testing** | crediting a test only when a deliberately introduced defect makes it fail. What `tests/negative_control.sh` implements |
| **differential testing** | comparing two builds against each other rather than against an expected value. What every perf gate does |
| **A/A** | comparing something against itself to establish a noise floor. Both `perfbudget` and `npsab` do it |
| **golden** | a recorded expected output. The perf gates deliberately have none; `tests/perft.sh`'s counts are facts about chess rather than a golden, so a mismatch is never an update candidate |
| **flake** | a gate whose verdict varies without the subject changing. A flaky gate is worse than no gate, because its green runs are also uninformative |
| **negative control** | an experiment run to confirm the instrument can detect anything at all |
| **blast radius** | how many files a change forces to be re-checked |
