# Multithreading

`src/platform/thread.h`, `src/platform/thread.cpp`, `src/platform/thread_native.h`, and the
shared state they hand to `Search::Worker`.

Audience: threading and NUMA.

The mechanism that replicates -- `NumaConfig`, the policy parser, the shared mapping -- is
[06-platform.md](06-platform.md)'s.

## Where to look

| question | file | symbol |
|---|---|---|
| what a native thread runs between searches | `src/platform/thread.cpp` | `Thread::idle_loop` |
| how a job is handed to a parked thread | `src/platform/thread.cpp` | `Thread::run_custom_job` |
| how a search is launched | `src/platform/thread.cpp` | `ThreadPool::start_thinking` |
| what the workers share | `src/engine/search.h` | `Search::SharedState` |
| which bank a worker draws from | `src/engine/history.h` | `HistoryBankIndex`, `SharedHistories` |
| how the engine reaches the workers at all | `src/engine/worker_set.h` | `WorkerSet` |
| how the engine reaches the host's threads | `src/engine/parallel.h` | `ParallelFor` |
| a multi-worker search with no pool | `src/engine/search_go.cpp` | `Search::HeadlessRunner::run` |
| which thread's move is played | `src/engine/search.cpp` | `Search::best_worker` |

## Lazy SMP

Every thread runs the same iterative deepening loop on the same root position. Nothing splits
the tree, there is no work queue, and no thread waits for another.

The threads diverge for three reasons, all of them in the code:

- they share the transposition table, so a position one thread has already searched returns a
  cutoff to another;
- each worker carries its own `optimism` values, which `Search::Worker::evaluate` passes into
  `Eval::evaluate` to be blended with the network's output, so their evaluations differ;
- each opens its aspiration window at a width derived from `threadIdx`, so the same root move
  fails high or low on different threads at different iterations
  ([02-engine-search.md](02-engine-search.md)).

```sh
grep -n 'threadIdx % 8\|optimism\[' src/engine/search.cpp
```

The speedup comes from the shared table: work one thread did is work another does not repeat.

## What is shared, and what is not

**Per worker** -- the position, the search stack, the root move list, the history tables
(mostly), the accumulator stack and refresh cache, the node counter.

**Shared** -- the transposition table, the stop flag, the pooled counters, and the three
tables `SharedHistories` owns: the continuation-history block, the pawn history and the
unified correction history. The transposition table is shared across the whole pool; a
`SharedHistories` is shared only between the workers in one **bank**.

**The host decides which workers share a bank, and the engine cannot ask why.** A worker is
handed a `HistoryBankIndex`, which is an index into the engine's own
`std::map<HistoryBankIndex, SharedHistories>` and nothing more; `ThreadPool::set` puts one bank
per NUMA node, to keep a bank off a remote node. A host that groups differently gets a different
sharing pattern and needs no engine change, and an engine that read the topology here would be
naming a host type on the path a worker takes.

`HistoryBankIndex` is `enum class HistoryBankIndex : usize` (`src/engine/history.h`) for that
reason and not for tidiness. Both values that reach it are a `NumaIndex`, which is also `usize`:

```sh
grep -rn 'HistoryBankIndex(' src/platform/thread.cpp src/engine/search_go.cpp
```

An alias would make the two interchangeable and the separation would hold in this paragraph
alone. Scoped, each of those sites has to write the conversion out. See
[09-type-design.md](09-type-design.md) for what that caught.

**A bank's size is a `PowerOfTwo`, not a count.** `SharedHistories` sizes its correction and
pawn tables as a multiple of the worker count and indexes them by masking a key with
`size - 1`, so a count that is not a power of two selects a row the array does not hold.
`PowerOfTwo` (`src/engine/history.h`) has a private constructor and one factory,
`PowerOfTwo::ceil`, which rounds -- so the rounding cannot be skipped at a call site and there
is no state left for an assert to check. That matters because `-DNDEBUG` is what ships: an
assert here would be checking the shipped build's most consequential index and be compiled out
of it.

```sh
grep -rn 'PowerOfTwo::ceil' src/
```

## The counters

```cpp
std::atomic_bool stop, increaseDepth;   // ThreadPool
```

and every shared counter is a `RelaxedAtomic<u64>` (`src/engine/basetypes.h`), summed on
demand by `ThreadPool::nodes_searched` and `ThreadPool::tb_hits`.

**Both are explicit loops over `Worker::nodes_searched()` rather than one `accumulate` over a
pointer-to-member.** `Worker`'s counters are private and the aggregation goes through the two
accessors; a *pointer* to one of those is a runtime value the compiler need not devirtualise,
where a direct call inlines to the same relaxed load the member access was. The total is not
free to compute: `SearchManager::check_time` asks for it, and asks through the `WorkerSet`
seam, which is a function pointer -- so the loop body is the one part of that path a compiler
can still see through, and handing it an indirect call as well is what this avoids.

`check_time` throttles to one call in 512 nodes, or to 0.1% of a node limit when one is set:

```sh
awk '/^void SearchManager::check_time/,/^}/' src/engine/search.cpp
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

`Thread` owns a native thread that runs `idle_loop()`: it clears `searching`, notifies anyone
waiting, and blocks until `searching` is set again. Threads are created when `Threads` is set
and live until it changes -- creating a thread per search would put thread creation on the move
latency path.

**One job at a time, and the handover is the wait.** `Thread::run_custom_job` waits for
`searching` to fall before it stores the new `jobFunc`, so queuing a second job on a busy
thread blocks the caller rather than replacing the first. `Thread::wait_for_search_finished`
waits on the same condition and nothing else: it orders *this thread's current job has
returned*, not *the search has ended*. The name is `thread.h`'s own and it predates the thread
running jobs that are not searches.

`ThreadPool::wait_for_search_finished` and `ThreadPool::start_searching` both **skip
`threads.front()`**, because the caller is running the main worker on its own thread. A helper
loop written over all of `threads` deadlocks on the main thread's own job.

`ThreadPool::start_thinking` resolves the root moves once, ranks them against the tablebases,
copies the root position into every worker, waits for all of those jobs, and only then wakes
the main thread. Every worker gets its own copy of the position and its own `StateInfo` chain,
because `do_move` mutates both.

**The setup job is handed over as one pointer, and that is a heap allocation avoided.** The
five things a worker needs to be given a root position travel as a `Search::RootSetup`
(`src/engine/search.h`) -- a bundle of pointers, which it must stay. `run_custom_job` takes a
`std::function<void()>`, and libstdc++ holds a callable inline only while it fits a **16-byte
buffer**; a closure over the five referents is 48 bytes, so each worker's setup job would be an
`operator new` and a matching free. One pair per thread per `go`, on the move-latency path,
before any thread starts searching. Capturing one pointer to the bundle plus the thread pointer
is 16 bytes and fits. The bundle lives on `start_thinking`'s frame and every job reading it has
finished by the wait that follows, which is the same lifetime the references had.

`Worker::set_root` is the public operation that consumes it. It is public rather than reached
through friendship because a friend declaration emits no symbol, so `depcheck`, `linkcheck` and
`enginelink` are all structurally blind to one.

`stop` is the one flag everything watches. Time management, a `stop` command, and a thread
finding a mate all set it.

**The engine does not reach the pool to read it.** `ThreadPool::stop` is handed to each
`Search::Worker` as a `std::atomic<bool>&` through `SharedState::stopFlag`, so the search names
no host type on the path that matters. Workers read it two ways, and both are deliberate:

- **Per node**, relaxed, twice inside `search()` and nowhere in `qsearch()`: Step 2 aborts
  before doing any work, and Step 20 discards the value a recursive call returned, because a
  search that stopped mid-move returns a number that must not reach the best move, the PV or
  the transposition table.

  ```sh
  grep -n 'stopFlag.load(std::memory_order_relaxed)' src/engine/search.cpp
  ```

- **Throttled**, through `check_time`, which is where the time budget and the info-line cadence
  are decided.

A reference member and not a pointer: a reference's binding is fixed at construction, so the
compiler may hoist the address out of the node. A pointer member must be reloaded after any
call that might alias the worker.

### A multi-worker search without the pool

`ThreadPool` is the host's implementation, not the only one. The engine reaches whatever is
registered through two seams, and the split between them is the reason a second implementation
is possible at all.

`WorkerSet` (`src/engine/worker_set.h`) is the one the search itself calls:

```cpp
void (*start_searching)(void* ctx);
void (*wait_for_search_finished)(void* ctx);
u64 (*nodes_searched)(void* ctx);
u64 (*tb_hits)(void* ctx);
usize (*count)(void* ctx);
Search::Worker* (*at)(void* ctx, usize index);
```

**Start and wait are two calls, not a fork-join**, which is exactly the shape
`Worker::start_searching` needs: the main worker starts the helpers, searches itself, busy-waits
out a ponder or an infinite search, raises `stop`, and only then waits. A fork-join primitive
could not express that, because the helpers must be running while the main worker searches.

`ParallelFor` (`src/engine/parallel.h`) is the narrower one, and its `run_on`/`wait_on` pair
has the same two-call shape. Its callers are `TranspositionTable::resize` and `::clear`, which
is why it exposes the NUMA map and not just a thread count.

**The registered worker set is process-wide.** `current` in `worker_set.cpp` is a single
global, so a second `set_worker_set` replaces the first engine's set and the first engine then
dispatches onto the second engine's pool. Two engines in one process do not work, and giving
the seam an owner rather than a `ctx` is what would fix it.

`Search::go` (`src/engine/search_go.h`) is the second implementation. It builds N workers over
one `SharedState`, registers a `WorkerSet` over them for the duration of the call, and
dispatches the helpers through whatever parallel-for is registered -- which is how
`tests/enginelink.sh` runs a two-worker search having linked `engine/` alone. The engine spawns
nothing; the gate's own `run_on`/`wait_on` supply the threads.

**The built-in parallel-for runs the job inline, and that is the one case a multi-worker search
cannot survive.** An inline helper never returns: the depth cap tests `mainThread` and a
non-main worker has none, so it searches to `MAX_PLY` waiting for a stop the caller cannot
reach the line to raise. Running the work inline is a correct parallel-for -- the transposition
table still gets cleared -- so this is not a defect in the default. It is why `Search::go`
returns `std::nullopt` for a worker count above `parallel_for().num_threads()` rather than
attempting it: fewer workers than asked for is a different answer, not a slower one.

## Choosing the answer

The threads finish with different best moves. `Search::best_worker` runs a **vote** rather than
taking the deepest or the highest-scoring. It lives in `src/engine/search.cpp`, not in the pool:
choosing between candidate lines is chess policy, and the only thing it needs from the workers
is the set of them, which `WorkerSet::count` and `WorkerSet::at` hand it.

```sh
awk '/^Search::Worker\* Search::best_worker/,/^}/' src/engine/search.cpp
```

Each thread votes for its best move with a weight derived from its score, shifted so the
weakest thread's score is the origin and offset by a tuned constant so that a thread which
found nothing still votes. A move several threads agree on beats a move one thread scored
slightly higher.

The vote is overridden where a score is a fact rather than an estimate: a **decisive** score --
`is_decisive`, so a mate or a tablebase conversion -- wins regardless of votes, and the shorter
one of two decisive scores wins. A score that is a bound, or `-VALUE_INFINITE`, is not treated
as decisive: an aborted depth-1 search produces exactly those, and taking one at face value
would play a move on an unproven mate.

## NUMA

`src/platform/numa.h` and `src/platform/numa.cpp` carry the topology detection, the thread
binding and the network replication. Which half a function lives in is decided by where it is
instantiated, not by how hot it is; [06-platform.md](06-platform.md) states that rule.

On a multi-socket machine, a thread reading a network resident on another socket pays
cross-node memory latency on every evaluation, which is most of what the engine does.

The network is therefore **replicated per NUMA node**, and threads are bound so each uses the
copy local to it. `LazyNumaReplicated` defers the copy until a node actually has a thread on
it, so a single-socket machine pays for one.

**What the search sees of that is one reference.** `ThreadPool::ensure_network_replicated`
takes a `LazyNumaReplicatedSystemWide<Network>&`, and `thread.h` reaches it through a forward
declaration rather than by including `src/platform/numa_shared.h` where it is defined. Only a
file that owns one by value needs that header. Put the class in `numa.h` instead and shared
memory reaches everything that includes `numa.h` -- which `search.h` does not, so the engine
sits two steps from it rather than one.

**This is the largest platform-specific surface in the tree** and the least covered by the
gates: the topology paths differ per OS, and `bench` exercises one thread on one node.

## Determinism

A single-threaded search is deterministic and `tests/reprosearch.sh` holds it to that: the
same node limit from the same position must produce the same node count, twice, across a
`ucinewgame`.

**A multi-threaded search is not deterministic and is not meant to be.** The divergence is
the mechanism -- threads that searched identically would contribute nothing to each other.
The bench signature is therefore a single-threaded number.

## The gates

`bench` is single-threaded, so every gate that reads a node count stays green while a data race
is live and while contention is getting worse. These are the ones that do not.

| gate | what it proves here | owned by |
|---|---|---|
| `tests/npsthreads.sh` | the two revisions scale the same across thread counts -- the only axis that measures contention on the shared last level, the transposition table and the counters | [11-performance.md](11-performance.md) |
| `tests/enginelink.sh` | a search asked for two workers actually dispatches two, and the host's worker set is restored afterwards; the only place the concurrent search runs under a sanitizer with no host pool | [00-architecture.md](00-architecture.md) |
| `tests/instrumented.py` | the shipped engine under ThreadSanitizer, with the pool the host owns | [07-shell.md](07-shell.md) |

A change to anything more than one thread reads or writes needs the sanitizer lanes as well as
the value gates:

```sh
make -j build ARCH=x86-64-avx2 sanitize=thread \
  && python3 ../tests/instrumented.py --sanitizer-thread ./stockfish
```
