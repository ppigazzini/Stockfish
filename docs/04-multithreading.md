# Multithreading

`src/platform/thread.h`, `src/platform/thread.cpp`, `src/platform/thread_native.h`, and the shared state they hand to
`Search::Worker`.

Audience: threading and NUMA.

This page owns why the search is shaped around replication. The mechanism that replicates --
`NumaConfig`, the policy parser, the shared mapping -- is
[06-platform.md](06-platform.md)'s, and neither page repeats the other.

## Lazy SMP

Every thread runs the same iterative deepening loop on the same root position. Nothing splits
the tree, there is no work queue, and no thread waits for another.

The threads diverge for three reasons, all of them in the code:

- they share the transposition table, so a position one thread has already searched returns a
  cutoff to another;
- each worker carries its own `optimism` values, which `evaluate.cpp` blends into the returned
  value, so their evaluations differ;
- each opens its aspiration window at a width derived from `threadIdx`, so the same root move
  fails high or low on different threads at different iterations
  ([02-engine-search.md](02-engine-search.md)).

The speedup comes from the shared table: work one thread did is work another does not repeat.

## What is shared, and what is not

**Per worker** -- the position, the search stack, the root move list, the history tables
(mostly), the accumulator stack and refresh cache, the node counter.

**Shared** -- the transposition table, the stop flag, the pooled counters, and the three
tables `SharedHistories` owns: the continuation-history planes, the pawn history and the
unified correction history. The transposition table is shared across the whole pool; a
`SharedHistories` is shared only between the workers in one **bank**.

**The host decides which workers share a bank, and the engine cannot ask why.** A worker is
handed a `HistoryBankIndex`, which is an index into the engine's own
`std::map<HistoryBankIndex, SharedHistories>` and nothing more; `ThreadPool` sets one bank per
NUMA node, to keep a bank off a remote node. A host that groups differently gets a different
sharing pattern and needs no engine change, and an engine that read the topology here would be
naming a host type on the path a worker takes.

```cpp
std::atomic_bool stop, increaseDepth;
```

and every shared counter is a `RelaxedAtomic<u64>` (`src/engine/basetypes.h`), summed on demand:

```cpp
u64 accumulate(RelaxedAtomic<u64> Search::Worker::* member) const;
```

**The races are intentional and are typed rather than avoided.** A transposition entry can be
read while another thread writes it, and a torn entry is possible. Making that safe would
need a lock per cluster, which would cost more than the occasional wrong entry -- and a wrong
entry is already tolerated, because a 16-bit key check does not exclude collisions either.

What `RelaxedAtomic` buys is that the race is **defined**. A plain `u64` written by one thread
and read by another is undefined behaviour, which a compiler may optimise on the assumption it
cannot happen. `relaxed` ordering costs nothing on the architectures this engine targets and
makes the program's meaning well defined.

`bench` is single-threaded, so **every value gate in this tree stays green while a data race
is present**. The sanitizer lanes are the only thing that covers this -- see
[10-tooling-ci.md](10-tooling-ci.md).

## The pool

`Thread` owns a native thread that runs `idle_loop()`, waiting for a signal, running a
search, and returning to wait. Threads are created when `Threads` is set and live until it
changes -- creating a thread per search would put thread creation on the move latency path.

`ThreadPool::start_thinking` copies the root position into every worker, hands each the same
limits, and releases them together. Every worker gets its own copy of the position and its
own `StateInfo` chain, because `do_move` mutates both.

`stop` is the one flag everything watches. Time management, a `stop` command, and a thread
finding a mate all set it.

**The engine does not reach the pool to read it.** `ThreadPool::stop` is handed to each
`Search::Worker` as a `std::atomic<bool>&` through `SharedState`, so the search names no host
type on the path that matters. Workers read it two ways, and both are deliberate:

- **Per node**, relaxed, twice inside `search()` and nowhere in `qsearch()`: Step 2 aborts
  before doing any work, and Step 20 discards the value a recursive call returned, because a
  search that stopped mid-move returns a number that must not reach the best move, the PV or
  the transposition table.
- **Throttled**, through `check_time`, which is where the time budget and the info-line cadence
  are decided.

A reference member and not a pointer: a reference's binding is fixed at construction, so the
compiler may hoist the address out of the node. A pointer member must be reloaded after any
call that might alias the worker.

### A multi-worker search without the pool

`ThreadPool` is the host's implementation, not the only one. The engine reaches whatever is
registered through two seams, and the split between them is the reason a second implementation
is possible at all: `worker_set.h` carries lifecycle and dispatch, and `parallel.h` carries the
threads.

```cpp
void (*run_on)(usize thread, std::function<void()> fn);
void (*wait_on)(usize thread);
```

**Start and wait are two calls, not a fork-join**, which is exactly the shape
`Worker::start_searching` needs: the main worker starts the helpers, searches itself, raises
`stop`, and only then waits. A fork-join primitive could not express that, because the helpers
must be running while the main worker searches.

`Search::go` (`engine/search_go.h`) is the second implementation. It builds N workers over one
`SharedState` and dispatches them through whatever parallel-for is registered, which is how
`tests/enginelink.sh` runs a two-worker search having linked `engine/` alone. The engine spawns
nothing; the host supplies the threads.

**The built-in parallel-for runs the job inline, and that is the one case a multi-worker search
cannot survive.** An inline helper never returns: the depth cap tests `mainThread` and a
non-main worker has none, so it searches to `MAX_PLY` waiting for a stop the caller cannot
reach the line to raise. Running the work inline is a correct parallel-for -- the transposition
table still gets cleared -- so this is not a defect in the default; it is why `Search::go`
refuses a worker count the registered parallel-for cannot supply rather than attempting it.

## Choosing the answer

The threads finish with different best moves. `Search::best_worker` runs a **vote** rather than
taking the deepest or the highest-scoring. It lives in `engine/search.cpp`, not here: choosing
between candidate lines is chess policy, and the only thing it needs from the pool is the set of
workers, which the worker-set seam hands it as a count and an index.

```cpp
votes[th->rootMoves[0].pv[0]] += th->rootMoves[0].score - minScore + 14;
```

Each thread votes for its best move with a weight derived from its score, shifted so the
weakest thread's score is the origin and offset by a tuned constant so that a thread which
found nothing still votes. A move several threads agree on beats a move one thread scored
slightly higher.

The vote is then overridden in the cases where a score is a fact rather than an estimate: a
proven mate wins regardless of votes, and a shorter mate beats a longer one. Aborted searches
at depth 1 can produce inexact win or loss scores, which the comparison accounts for
specifically.

## NUMA

`src/platform/numa.h` and `src/platform/numa.cpp` carry the topology detection, the thread
binding and the network replication. The split is by temperature rather than by subject:
everything that runs before the first search -- topology discovery, the string forms, thread
binding -- is in the `.cpp`, and what stays in the header is template-bound and cannot move.

On a multi-socket machine, a thread reading a network resident on another socket pays
cross-node memory latency on every evaluation, which is most of what the engine does.

The network is therefore **replicated per NUMA node**, and threads are bound so each uses the
copy local to it. `LazyNumaReplicated` defers the copy until a node actually has a thread on
it, so a single-socket machine pays for one.

`src/platform/shm.h` and `src/platform/shm_unix.h` back `SystemWideSharedConstant`, which lets
several engine processes on one machine share one copy of a replicated network rather than each
loading its own -- relevant when a test harness runs many engines at once. The holder that uses
it, `LazyNumaReplicatedSystemWide`, is in `src/platform/numa_shared.h` rather than `numa.h`.
`thread.h` forward-declares it and takes one by reference; only a file that owns one by value
includes `numa_shared.h`. Put it in `numa.h` instead and shared memory reaches everything that
includes `numa.h` -- which `search.h` does not, so the engine sits two steps from it rather than
one.

**This is the largest platform-specific surface in the tree** and the least covered by the
gates: the topology paths differ per OS, and `bench` exercises one thread on one node.

## Determinism

A single-threaded search is deterministic and `tests/reprosearch.sh` holds it to that: the
same node limit from the same position must produce the same node count, twice, across a
`ucinewgame`.

**A multi-threaded search is not deterministic and is not meant to be.** The divergence is
the mechanism -- threads that searched identically would contribute nothing to each other.
The bench signature is therefore a single-threaded number.
