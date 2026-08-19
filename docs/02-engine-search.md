# The search

`src/engine/search.h`, `src/engine/search.cpp`, `src/engine/search_go.h`,
`src/engine/search_go.cpp`, `src/engine/tt.h`, `src/engine/tt.cpp`, `src/engine/history.h`,
`src/engine/movepick.h`, `src/engine/movepick.cpp`, `src/engine/timeman.h`,
`src/engine/timeman.cpp`, `src/engine/score.h`, `src/engine/score.cpp`.

Alpha-beta with a transposition table, a staged move picker, history-driven ordering and a
pruning set. Every margin, reduction and bonus named here is a tuned constant: read the value
from the source, which is the only place it is current.

Audience: search.

## Where a question lands

| question | file | symbol |
|---|---|---|
| what one node does, in order | `search.cpp` | `Worker::search<NodeType>`, 21 numbered Steps |
| what a node remembers about its ancestors | `search.h` | `Stack`, addressed `(ss - n)` |
| how deep does a late move get searched | `search.cpp` | `Worker::reduction(improving, depth, moveCount, delta)` |
| what the root loop does between iterations | `search.cpp` | `Worker::iterative_deepening` |
| when does the search stop | `search.cpp` | `SearchManager::check_time`, and the time block in `iterative_deepening` |
| how a position becomes a table slot | `tt.cpp` | `TranspositionTable::first_entry`, `probe` |
| why an entry survived a write | `tt.cpp` | `TTEntry::save`, `TTEntry::relative_age` |
| in what order are moves tried | `movepick.cpp` | `MovePicker::next_move`, `Stages` |
| which table scored this move | `movepick.cpp` | `MovePicker::score<GenType>` |
| where a history table lives and how wide | `history.h` | the `using` block, `StatsEntry<T, D, Shared>` |
| which tables are shared between threads | `history.h` | `SharedHistories` |
| what a worker is built from | `search.h` | `Search::SharedState`, `Worker::Worker` |
| how a principal variation is carried | `search.h` | `PVMoves`, `PVMoves::Capacity` |
| what a reported `cp` means | `score.cpp` | `Score`, `to_cp`, `win_rate_model` |
| search one position with no host at all | `search_go.h` | `Search::go` |

## `tt.cpp` -- the transposition table

A flat array of 32-byte `Cluster`s, three `TTEntry` of ten bytes each plus two bytes of padding.
The size is asserted:

```cpp
static constexpr int ClusterSize = 3;
static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");
```

**The cluster is sized to divide a cache line**, so probing one position touches one line. The
cluster count is `mbSize * 1024 * 1024 / sizeof(Cluster)`, and it decides which positions collide
-- two engines with the same table size and different cluster arithmetic search different trees.

**The two halves of the key do not overlap.** `first_entry` picks the cluster with
`mul_hi64(key, clusterCount)`, which is the *high* end of the key scaled into range; `probe` then
matches `u16(key)`, the low sixteen bits, inside the cluster. Making the cluster index a mask of
the low bits instead would leave the in-cluster tag correlated with it and the three ways nearly
useless.

An entry packs a 16-bit key fragment, a depth offset from `DEPTH_NONE`, a byte holding the
generation (5 bits), the bound (2) and the PV flag (1), then the move, the value and the static
eval -- **in the order `probe` reads them**, which is why the field order is not free. Sixteen bits
of key is not a full check: **collisions are accepted**. A wrong entry costs a wrong move ordering
and is caught by the search, and paying eight bytes per entry to avoid it would cost more in cache
than it saves in accuracy.

`is_occupied()` reads `depth8`, which is why `DEPTH_UNSEARCHED` and `DEPTH_NONE` are negative and
distinct -- `depth8` is stored as `d - DEPTH_NONE`, so an entry that stored no search lands on 1
and an empty slot on 0. `probe` returns `bool(depth8)` as its hit flag even on a key match, so an
entry aged down to zero reads as a miss without being erased. `TTWriter::penalize` clamps at zero
for the same reason: an unclamped decrement wraps a `u8` and makes a penalised shallow entry the
deepest in its cluster.

**The table is shared across threads with no lock.** Entries are written and read concurrently; a
torn entry is possible and tolerated. `RelaxedAtomic` in `src/engine/basetypes.h` is what keeps
that defined rather than undefined behaviour. See [04-multithreading.md](04-multithreading.md).

Replacement weighs depth against age -- `depth8 - 8 * relative_age(generation8)`, lowest loses --
so a shallow entry from an old generation is the cheapest thing to lose. `new_search` increments
the generation and masks it back to five bits, and `relative_age` is a modular subtraction under
the same mask: generations are counted the way clocks count hours, so `0 - 1 == 31` and the table
never needs a sweep.

`hashfull` **samples the first 1000 clusters and nothing else**, whatever the table size, and
reports permille. It is a UCI display number, not a measurement: do not build a decision on it and
do not read a small table's figure as more precise than a large one's.

`value_to_tt` / `value_from_tt` convert a mate score between root-relative and node-relative form.
A mate score stored at one ply means a different thing when read at another, and the conversion is
what makes the stored number reusable.

## `history.h` -- the ordering tables

Every table is a **gravity** table, and one operator is the whole mechanism:

```cpp
void operator<<(int bonus) {
    int clampedBonus = std::clamp(bonus, -D, D);
    T   val          = *this;
    *this            = val + clampedBonus - val * std::abs(clampedBonus) / D;
}
```

The update moves the stored value toward the signed clamp by an amount proportional to how far it
still is from it. **A value saturates smoothly instead of pinning.** A table that simply added and
clamped would lose the ordering between two moves that had both reached the ceiling, and that
ordering is most of what the table is for.

`D` is a template parameter, one per table, so a bonus and the clamp it belongs to cannot be
transposed at a call site. `StatsEntry` `static_assert`s `D <= INT_MAX / D`, because the product
`val * |clampedBonus|` is computed in `int`.

| table | indexed by |
|---|---|
| `ButterflyHistory` | colour, from-to |
| `LowPlyHistory` | ply, up to `LOW_PLY_HISTORY_SIZE`, and from-to |
| `CapturePieceToHistory` | moving piece, destination, captured type |
| `PieceToHistory` (a continuation plane) | moving piece, destination |
| `PawnHistoryEntry` / `PawnHistory` | one plane per pawn-key row; then piece, destination |
| `UnifiedCorrectionHistory` | a key row, then colour, giving one `CorrectionBundle` |
| `CorrectionHistory<PieceTo>` / `<Continuation>` | moving piece and destination, and a plane of those per previous move |
| `TTMoveHistory` | a single entry |

Each table's `D` is a tuned constant and moves with tuning patches, so read it from the
declaration rather than from here:

```sh
grep -nE 'using [A-Za-z]+History' src/engine/history.h
```

The four correction counters share one `CorrectionBundle` per row, and `SharedHistories` hands out
the **counter** rather than the row: `pawn_correction(pos, us)`, `minor_piece_correction(pos, us)`,
and `nonpawn_correction<c>(pos, us)`, which is templated on the colour whose key selects the row
and so yields the remaining two counters. Each picks the key and the field in one place, so a
caller cannot pair one key's row with another key's field. `Position::do_move` prefetches the four
counters, written out at the call site.

`Search::Worker::do_move` prefetches two more, and they are a different pair: the
continuation-correction entries the *child* will read, taken from the parent's `(ss - 1)` and
`(ss - 3)`. The child reads `(ss - 2)` and `(ss - 4)` in `correction_value`, and child `ss` is
parent `ss + 1`, so the addresses match exactly for a normal move -- castling and promotion
prefetch an approximation and land on an unused line. Keep the two offsets in step with the reads
in `correction_value`: shifting one without the other costs the prefetch silently, because a
prefetch to the wrong line is not a fault and no gate can see it.

`ContinuationHistory` is a `MultiArray<PieceToHistory, PIECE_NB, SQUARE_NB>`: a plane per
(piece, destination) of the *previous* move, each plane itself a history over the current move.
That is what lets the ordering say "after a knight lands on f3, this reply has worked".

Four of them live in a `ContinuationHistoryBlock`, a `[2][2]` selected by whether the side to move
was in check and whether the move was a capture. **The array is private and the only way in is
`ContinuationHistoryBlock::operator()(InCheck, Capture)`**, which reads at a call site as
`continuationHistory(InCheck(ss->inCheck), Capture(capture))`. Both indices are one bit and both
subscripts are spelled the same way, so `[capture][inCheck]` compiles, reads a real table and
returns plausible statistics -- a search that continues, returns a legal move, and is quietly
worse. There is no assert to hit and no bound to exceed; the bench signature is the only thing that
would notice. `InCheck` and `Capture` are scoped enums over `bool`, so the transposition has no
spelling; the accessor inlines to the same two subscripts
([09-type-design.md](09-type-design.md)).

Two members are spelled `continuationHistory` and they are not the same thing:
`SharedHistories::continuationHistory()` is a function returning the block,
and `Worker::continuationHistory` is a reference to it, bound in the constructor's unpack list.

```sh
git grep -n 'continuationHistory(' -- src
```

`PawnHistory` is a `DynStats` sized from `PAWN_HISTORY_BASE_SIZE`, which is asserted to be a power
of two because the index is a mask of the pawn key rather than a modulus. The same requirement on
the per-bank size is a type rather than an assert: `SharedHistories` takes a `PowerOfTwo`, whose
constructor is private and whose only factory is `PowerOfTwo::ceil`
([04-multithreading.md](04-multithreading.md)).

**The split between per-worker and shared decides the entry type.** `mainHistory`, `lowPlyHistory`,
`captureHistory`, `continuationCorrectionHistory` and `ttMoveHistory` are `Worker` members, touched
by one thread. The rest arrive through `SharedHistories&`, shared between the workers the host put
in the same bank -- which bank is a `HistoryBankIndex`, an index into the engine's own map and not
a handle on the host's topology ([04-multithreading.md](04-multithreading.md)). Those are the ones
whose entries carry `StatsEntry`'s `Shared = true`, reached as `AtomicStats` for the continuation
and pawn planes and spelled out inside `CorrectionBundle` for the four correction counters. That
makes the entry a `RelaxedAtomic<T>`, so the race is defined rather than undefined. Moving a table
across that line means changing its type, not just its owner.

Clearing a shared table is the exception: `DynStats::clear_range` takes a `WorkerShare` -- an index
and a total as one value -- and `shared_slice` cuts the disjoint slice that worker owns. The whole
array is covered only if every index in `[0, total)` calls exactly once with the same total; a
missing index leaves its slice holding the previous game's statistics, and nothing refuses it.

## `movepick.cpp` -- the staged picker

Moves are produced in the order the search wants to try them, and **each stage is generated only
when the previous one runs out**. Most nodes cut off on the transposition move or the first good
capture, so generating the quiet moves for those nodes would be most of the generator's cost spent
on moves nobody looks at.

Four sequences, chosen by what the node is:

```
main search   MAIN_TT -> CAPTURE_INIT -> GOOD_CAPTURE -> QUIET_INIT
                      -> GOOD_QUIET -> BAD_CAPTURE -> BAD_QUIET
in check      EVASION_TT -> EVASION_INIT -> EVASION
probcut       PROBCUT_TT -> PROBCUT_INIT -> PROBCUT
quiescence    QSEARCH_TT -> QCAPTURE_INIT -> QCAPTURE
```

In check there is no capture/quiet split: every evasion is generated at once, because there are
few of them and skipping any is unsound.

The stage is entered by arithmetic rather than a branch:

```cpp
stage = EVASION_TT + !(ttm && pos.pseudo_legal(ttm));
```

A transposition move that is not pseudo-legal in this position -- which a 16-bit key collision can
produce -- skips the stage rather than being played.

**Every generating stage sorts, and they do not sort alike.** `partial_insertion_sort` orders
descending down to a limit and leaves everything below it unspecified. `CAPTURE_INIT`,
`PROBCUT_INIT`, `QCAPTURE_INIT` and `EVASION_INIT` pass `INT_MIN`, which is a full sort of a short
list; `QUIET_INIT` passes a limit scaled by depth, so at low depth most quiets are never ordered at
all. `select` then walks that array one element per call, so the cost of a stage nobody finishes is
the sort, not the generation.

```sh
grep -n 'partial_insertion_sort(' src/engine/movepick.cpp
```

Under `USE_AVX512` the first sixteen elements go through `MoveSorter`, a register-resident
insertion sort, and the scalar loop finishes the rest. **The two must produce the same order**,
ties included, or that tier disagrees with every other tier on move ordering; nothing local checks
it and the bench signature across the compile matrix is the whole proof
([10-tooling-ci.md](10-tooling-ci.md)).

The `skipQuiets` flag is a member `next_move` re-reads on every call rather than an argument fixed
at construction, because the search sets it mid-node through `MovePicker::skip_quiet_moves`, called
from Step 14, and the picker has to honour that from the next call on. It is monotone -- only ever
set -- which is what lets `BAD_CAPTURE` decide whether `endGenerated` was written by a `QUIET_INIT`
that may have been skipped.

## What a worker is given

`Search::SharedState` is everything a `Search::Worker` is built from. Six members: a
`const SearchOptions&` snapshot, the transposition table, the shared history banks, a
**`const Host&`**, and the two `std::atomic<bool>&` flags every worker watches. The seams are in
[00-architecture.md](00-architecture.md); what this page owns is what the search does with them.

**The `Host` does not stop here.** `Worker` holds no `SharedState` -- it unpacks one at
construction, and `host` is unpacked with the rest onto `Worker::host`, which is the whole point of
carrying it. A reference member's binding is fixed at construction, so a handle that reached only
`SharedState` would leave every node dereferencing through the pool's copy; unpacked, the compiler
can hoist the address out of the node loop. `search.h`'s own comment states it, and names
`tests/perfbudget.sh` as what to run before turning any of them into pointers.

**The lifetime rule follows from the copy.** A `SharedState` is copied by value into
`ThreadPool::set` and dropped there, so every referent it holds must outlive the *Workers*, not the
pool. That is the same rule `shell/engine.h` states for the option snapshot, for the same reason,
and it is a third constraint on declaration order in that file.

The shape is affordable because of where the seams sit on the clock. Only the tablebase source is
on the node path; the worker set is second, at one node in 512 through `check_time`; the other five
are setup or info-line cadence. A seam whose cadence is a search rather than a node costs nothing
measurable however it is reached.

**A worker is legal before a network exists.** `Engine` sizes the pool while `EvalFile` is still
empty, so `Worker::network` is a `const Eval::NNUE::Network*` that starts null and `Worker::clear`
skips the refresh cache while it is. The cache is seeded from the net's feature-transformer biases,
so it is the one part that cannot be filled early; `ensure_network_replicated` fills it after a
load, and `Worker::evaluate` cannot be reached before then.

**`SearchManager` is valid the moment it exists.** Its constructor binds only `updates`, so every
other member carries an initial value in the declaration: `originalTimeAdjust`, `callsCnt`,
`lastInfoTime`, `ponder`, `previousTimeReduction`, `bestPreviousScore`, `bestPreviousAverageScore`,
`stopOnPonderhit`.

```sh
sed -n '/^class SearchManager/,/^};/p' src/engine/search.h | grep -nE '^ *[A-Za-z].*;'
```

Two members carry none, for different reasons. `iterValue` needs none: `iterative_deepening` fills
it with `bestPreviousScore` or `VALUE_ZERO` before the first read. `tm` is a class and gets its
default constructor, which is enough **only because `TimeManagement` carries its own initialisers**
-- `startTime`, `availableNodes`, `useNodesTime`, and `optimumTime` and `maximumTime` at `NoBound`.
Leave the scalars to the caller and a manager searched without `ThreadPool::start_thinking` reads
indeterminate storage; `ponder` is a `std::atomic_bool`, for which a byte that is neither 0 nor 1 is
undefined behaviour rather than a wrong answer.

`lastInfoTime` is the info-line throttle, and it is per manager rather than per process on purpose:
two concurrent searches sharing one would each set its info cadence from the other's clock, and a
wrong cadence is a plausible number rather than a fault.

## `Search::go` -- searching without a host

`Search::go` (`src/engine/search_go.h`) runs one depth-limited search from a FEN and needs no host
registered. It exists so the defaults can be **run**, not merely linked: `tests/enginelink.sh` and
`tests/fuzzsearch.sh` are both built on it.

Each call is independent. `HeadlessRunner::run` resets the manager's cross-search state per call --
`ThreadPool::clear`'s reset plus `start_thinking`'s two per-`go` fields -- because carrying it seeds
the aspiration window from whatever was searched last. That is right for successive `go` commands
on one engine and wrong for a driver that walks to an unrelated position each iteration, where it
costs whole seconds on a search that should take milliseconds.

Worker 0 holds the `SearchManager` and is the main worker: only the main worker applies the depth
cap and drives the aspiration loop. The rest hold a `NullSearchManager`, exactly as the pool builds
them.

**A `Worker` holds the manager twice, and the second one is the typed view.** `ManagerSlot` pairs
the owning `unique_ptr<ISearchManager>` with a `SearchManager*` that is null on every worker but the
main one, and `main_manager()` reads that pointer behind an assert. A `static_cast` down the
hierarchy guarded on `threadIdx` would not survive `-DNDEBUG`, which is what ships: it hands any
other worker a `SearchManager*` aimed at a `NullSearchManager`, whose members do not exist, and
reading time out of it is a plausible number rather than a fault. The pair is filled by
`make_main_manager` or `make_null_manager` and by nothing else, at the one point where the type is
still known, so the two halves cannot disagree.

`Worker` stores the `unique_ptr` at its original offset and the typed pointer **last in the class**.
That is deliberate: every member between them is on the per-node path, and storing the pair where
the `unique_ptr` sat shifted all of them by eight bytes.  A type that enforces an invariant does not
have to be the storage layout.

**Both implementations are `final`, and that is a codegen decision rather than a style one.**
Nothing derives from either, and without it the compiler cannot prove what a `SearchManager*` points
at: the call in `search()` is a direct call at all three of its inlined copies and an indirect
vtable dispatch without it.

**`NullSearchManager::check_time` is never called.** The only call site is guarded by
`is_mainthread()` -- which is the branch the Null Object Pattern exists to remove, so here both the
branch and the null object are present. The hierarchy stays because removing it is a taste argument,
but do not credit it with work it is not doing.

The heavy blocks are process-static and reused, so it is **not reentrant**: one search at a time,
and two callers at once share one root position. Changing the worker count rebuilds them, which is
not cheap -- a `Worker` embeds the NNUE refresh cache -- so alternating counts per call is not a
pattern to build on.

### More than one worker

It takes a worker count, and **a count it cannot honour is refused rather than attempted** --
`std::nullopt` for zero and for anything above `parallel_for().num_threads()`.

The non-main workers are dispatched through the parallel-for seam, which is where the host's threads
already are. That seam is two calls rather than a fork-join:

```cpp
void (*run_on)(usize thread, std::function<void()> fn);
void (*wait_on)(usize thread);
```

so a helper can be started before the main worker searches and waited for after it has raised the
stop flag -- which is the order `Worker::start_searching` requires. Host thread 0 is skipped,
because the caller is running the main worker on it, exactly as `ThreadPool::start_searching`
skips its own.

The built-in parallel-for runs the job **inline**, and an inline helper never returns: the depth cap
tests `mainThread` (`search.cpp`), a non-main worker has none, so it searches to `MAX_PLY` waiting
for a stop the caller cannot reach the line to raise. Attempting it hangs rather than degrades, and
**a hang is not a report**: it would take a gate down instead of failing it.

Above one worker a `WorkerSet` over those workers is registered for the duration of the call and
whatever was there before is put back. At one worker nothing is registered at all, which is the
configuration `enginelink.sh` exists to exercise. `nodes` is the whole search's count -- the main
worker's alone at one worker, the sum over the set above one; reporting the main worker's own would
describe a two-worker search as having done half its work.

## `search.cpp` -- the driver

`Worker::iterative_deepening` is what every thread runs, and it is three nested loops rather than
one: the depth loop, the MultiPV loop, and the aspiration re-search loop. `search<Root>` is called
from the innermost, so a single root position is searched many times.

The `Stack` array is allocated here -- `Stack stack[MAX_PLY + 10]`, with `ss = stack + 7` -- and the
seven-slot lead is what makes `(ss - 7)` legal at ply zero. `update_continuation_histories(ss - 1)`
reaches `(ss - 6)`, and node initialisation writes `(ss + 2)`. Add a read at a deeper negative
offset and the guard band has to grow with it; nothing in the type system says so.

```mermaid
flowchart TD
    D{"rootDepth+1 < MAX_PLY,<br/>not stopped,<br/>depth limit not hit?"}
    D -->|no| OUT(["report bestmove"])
    D -->|yes| INC["rootDepth++"]
    INC --> MPV{"for each PV line<br/>pvIdx < multiPV"}
    MPV --> W["delta from threadIdx and the move's<br/>meanSquaredScore; avg = averageScore<br/>alpha = avg-delta, beta = avg+delta"]
    W --> A["adjustedDepth = rootDepth<br/>- failedHighCnt - searchAgain term"]
    A --> SR["search&lt;Root&gt;(alpha, beta, adjustedDepth)"]
    SR --> SORT["stable_sort the root moves<br/>from pvIdx to pvLast"]
    SORT --> ST{"stopped?"}
    ST -->|yes| OUT
    ST -->|no| C{"bestValue vs window"}
    C -->|"<= alpha, fail low"| FL["beta = alpha<br/>alpha = bestValue - delta<br/>failedHighCnt = 0"]
    C -->|">= beta, fail high"| FH["alpha = max(beta - delta, alpha)<br/>beta = bestValue + delta<br/>failedHighCnt++"]
    C -->|inside| NEXT["next PV line"]
    FL --> WID["delta widens"]
    FH --> WID
    WID --> A
    NEXT --> MPV
    MPV -->|done| D
```

Three things the shape makes visible:

- **A fail high shrinks the depth it re-searches at.** `adjustedDepth` subtracts `failedHighCnt`, so
  each successive fail high at one root depth searches shallower. A node that keeps failing high is
  one whose value is not yet bracketed, and re-searching it at full depth repeatedly would spend the
  iteration on it.
- **A fail low does not.** It resets `failedHighCnt` to zero and moves `beta` down to the old
  `alpha`, because a fail low means the move is worse than believed and the search needs the full
  depth to find out how much. Both branches keep the window one-sided rather than reopening it: a
  fail high raises `alpha` to `beta - delta` as well as lifting `beta`, so the re-search is still
  narrow.
- **The sort must be stable.** Every root move but the first and the new best is set to
  `-VALUE_INFINITE`, so an unstable sort would reorder moves that compare equal and lose the
  ordering the previous iteration established. Under MultiPV it would also disturb the lines already
  searched, which is why the range starts at `pvIdx` rather than at `begin()`.

`delta` starts from the move's own `meanSquaredScore` and from `threadIdx % 8`, so **threads begin
with different window widths** -- one of the ways Lazy SMP diverges
([04-multithreading.md](04-multithreading.md)).

Output during a fail is throttled by node count rather than depth, and only in single-PV: a
re-search reports when `mainThread && multiPV == 1 && nodes > NODES_LIMIT_OUTPUT`, because depth is
reached quickly at the start of a search and some GUIs do not cope with the volume.

**The between-iterations time decision lives here, not in `timeman.cpp`.** `tm.optimum()` is
multiplied by four factors computed in this function, and the product is compared against
`min(totalTime, tm.maximum())`:

| factor | reads | direction |
|---|---|---|
| `fallingEval` | `bestPreviousAverageScore`, `iterValue[iterIdx]` against `bestValue` | a falling evaluation buys time |
| `reduction` | `timeReduction` from `rootDepth - lastBestMoveDepth` | a best move stable across iterations sells it back |
| `bestMoveInstability` | `totBestMoveChanges` pooled over all workers | best-move churn buys time |
| `highBestMoveEffort` | `rootMoves[0].effort` as a fraction of `nodes` | a move that already owns the tree has little left to displace it |

The pooled divisor is `std::max<usize>(1, workers)` and the floor is load-bearing: the worker-set
seam's own default reports zero, and a zero makes the factor NaN, then `totalTime` NaN, and then
every `elapsed > min(totalTime, maximum)` false -- a search that never stops on time.

## `search.cpp` -- the node

`Worker::search<NodeType>` is a single function structured as 21 numbered Steps, and it is the
largest in the tree:

```sh
awk '/^Value Search::Worker::search\(/{s=NR} s && NR>s && /^}/{print NR-s+1; exit}' \
  src/engine/search.cpp
grep -n '// Step ' src/engine/search.cpp
```

`NodeType` is a template parameter -- `NonPV`, `PV`, `Root` -- so the PV-only bookkeeping is
compiled out of the zero-window instantiation, which is the overwhelming majority of nodes.

The Steps, in the order the node applies them:

| Step | What |
|---|---|
| 1 | initialise the node |
| 2 | aborted search, immediate draw |
| 3 | mate-distance pruning |
| 4 | transposition lookup |
| 5 | static evaluation, corrected |
| 6 | tablebase probe |
| 7 | razoring |
| 8 | futility pruning (child node) |
| 9 | null-move search with verification |
| 10 | internal iterative reduction |
| 11-12 | ProbCut |
| 13 | the move loop |
| 14 | pruning at shallow depth |
| 15 | extensions, including singular |
| 16 | make the move |
| 17 | late move reduction |
| 18 | full-depth search when LMR is skipped |
| 19 | undo |
| 20 | new best move |
| 21 | mate and stalemate |

What each pruning rule assumes, since that is what decides when it is unsound:

- **Razoring** -- so far below alpha at low depth that a quiescence search is enough to confirm it.
- **Futility** -- so far above beta that giving away material could not bring it below.
- **Null move** -- if passing still fails high, the real move will too. The assumption fails in
  zugzwang, which is why it is skipped when the side to move has no non-pawn material.
- **Internal iterative reduction** -- a node with no transposition move has no ordering to work
  with, so searching it at full depth mostly wastes the effort.
- **ProbCut** -- a capture that beats beta by a margin at reduced depth probably beats it at full
  depth.
- **Singular extension** -- if the transposition move is much better than every alternative, the
  node hinges on it and it is searched a ply deeper. "Much better" is measured by re-searching with
  that move *excluded*, through `ss->excludedMove`. The same search yields multi-cut when the node
  fails high anyway.
- **LMR** -- late moves in a well-ordered list are unlikely to be best, so they are searched
  shallower, with a re-search at full depth if the reduced search beats alpha. How much shallower is
  `Worker::reduction(improving, depth, moveCount, delta)`, off the `reductions` table plus a
  `rootDelta`-relative term.

**The static evaluation is corrected before any of this.** Correction-history tables record how far
the evaluation of positions sharing a pawn structure, a minor-piece configuration or a non-pawn
material count has historically been from what the search actually found, and the node starts from
the corrected value; `correction_value` in `search.cpp` is the one place the five terms are weighed.

`qsearch` is the same shape in 9 Steps: stand-pat, then captures and promotions only, until the
position is quiet enough for the evaluation to mean something. It never reads `stopFlag`.

## `timeman.cpp` -- the budget

Two numbers, both written by `TimeManagement::init` at the top of every search. The **optimum** is
the point past which a new iteration should not be started -- stopping between iterations is free,
because the last completed one already has a best move. The **maximum** is the point past which the
search stops wherever it is. What scales the optimum between iterations is in `iterative_deepening`,
above; `timeman.cpp` sets the starting pair and nothing else.

**`init` writes both budgets on every path, including the one that returns early.** A side with no
clock of its own gets `NoBound` -- a search that runs until something stops it -- rather than
whatever the previous search left there. `use_time_management()` does *not* exclude that case: it is
true when only the opposing side has a clock, so `go btime N` with White to move reaches both
budgets on the early-return path. Leaving them unwritten is not "no time management", it is the
previous search's time management, and it is an uninitialised read the first time round.

**Under `nodestime` the clock is not a clock.** Remaining time, increment, move overhead and
`limits.movetime` are all multiplied into node counts, and `TimeManagement::elapsed` returns nodes
instead of milliseconds. The `time` a GUI is told stays real milliseconds, because `output_pv` calls
`elapsed_time()` rather than `elapsed()` -- the GUI asked how long the engine thought, not how the
engine chose to count.

**No clock read is on the per-node path.** The hottest goes through `TimeManagement::elapsed_time`
from `check_time`, which returns on every call but one in at most 512 -- `callsCnt` is reset to
`min(512, limits.nodes / 1024)` under a node limit and to 512 otherwise. The others on that route
are `Worker::elapsed` once per depth iteration and `output_pv` once per info line. The rest are
colder still and do not go through `elapsed_time` at all: one reading per `go` for
`LimitsType::startTime`, a few around the bench loop, and one function-local static,
`static PRNG rng(now())` in `search.cpp`. Reading a clock is a syscall on some platforms, and at
millions of nodes per second the granularity is well under a millisecond either way. A new reader in
the node body would turn the `clock.h` seam into a per-node indirect call.

```sh
git grep -n 'now()' -- src | grep -v clock
```

## `score.cpp` -- what a reported score means

The search works in units whose scale is a property of the network. Reporting them raw would make
`cp 200` mean something different after every net change, so the reported centipawn is defined
through a model fitted to real game results -- `win_rate_model`, whose two parameters come from
`win_rate_params(pos)` and therefore depend on the material left on the board. `to_cp` is the
inverse the info line prints. The same internal evaluation reports lower in an endgame, where there
is less left to convert it with. `UCI_ShowWDL` reads the same model through `wdl_to_string`.

Three kinds of score stay distinct rather than being flattened, and the type is what keeps them
apart: `Score` holds a `std::variant<Mate, Tablebase, InternalUnits>` and is read with
`is<T>()` / `get<T>()` / `visit`. A **mate** is a distance in plies, a **tablebase verdict** is a
fact reported above any evaluation and below any mate, and everything else is an estimate. Only
`InternalUnits` goes through the model; a consumer that wants a number out of the other two has to
name which it is asking for.

## `Skill` -- playing below full strength

A weakened engine must not simply search less deeply, because that produces an opponent that
blunders at random -- no easier to plan against and no more fun to play. The engine searches at full
strength and forces `multiPV` up to at least four when `Skill::enabled()`, picks among those lines
in `Skill::pick_best` with a bias that widens as the level drops, and swaps the chosen line to the
front at the end of `iterative_deepening`. `output_pv` still reports `options.multiPV` lines, so the
extra lines are the engine's own working set and never reach the GUI; every move it plays is one it
genuinely considered.

`UCI_Elo` wins over `Skill Level` when `UCI_LimitStrength` is set -- literally
`Skill(options.skillLevel, options.limitStrength ? options.elo : 0)`, and a zero Elo is what selects
the level. A GUI asking for a rating has asked the more specific question. The polynomial mapping
one to the other is a fit against real games played against the Stash engine and bounded by
`Skill::LowestElo` and `Skill::HighestElo`, so the ratings mean ratings rather than being a scale of
the engine's own invention.
