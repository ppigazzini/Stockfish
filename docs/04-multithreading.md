# Multithreading

`src/thread.h`, `src/thread.cpp`, `src/thread_native.h`, and the shared state they hand to
`Search::Worker`.

Audience: threading and NUMA.

## Lazy SMP

Every thread runs the same iterative deepening loop on the same root position. Nothing splits
the tree, there is no work queue, and no thread waits for another.

The threads diverge for three reasons, all of them in the code:

- they share the transposition table, so a position one thread has already searched returns a
  cutoff to another;
- each worker carries its own `optimism` values, which `evaluate.cpp` blends into the returned
  value, so their evaluations differ;
- they start at staggered depths, so they reach different nodes in different orders.

The speedup comes from the shared table: work one thread did is work another does not repeat.

## What is shared, and what is not

**Per worker** -- the position, the search stack, the root move list, the history tables
(mostly), the accumulator stack and refresh cache, the node counter.

**Shared** -- the transposition table, the continuation-history planes, the stop flag, and
the pooled counters.

```cpp
std::atomic_bool stop, increaseDepth;
```

and every shared counter is a `RelaxedAtomic<u64>` (`src/misc.h`), summed on demand:

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
finding a mate all set it, and every worker checks it through the throttled `check_time`
path rather than at every node.

## Choosing the answer

The threads finish with different best moves. `get_best_thread` runs a **vote** rather than
taking the deepest or the highest-scoring:

```cpp
votes[th->worker->rootMoves[0].pv[0]] += th->worker->rootMoves[0].score - minScore + 14;
```

Each thread votes for its best move with a weight derived from its score, shifted so the
weakest thread's score is the origin and offset by a constant so that a thread which found
nothing still votes. A move several threads agree on beats a move one thread scored slightly
higher.

The vote is then overridden in the cases where a score is a fact rather than an estimate: a
proven mate wins regardless of votes, and a shorter mate beats a longer one. Aborted searches
at depth 1 can produce inexact win or loss scores, which the comparison accounts for
specifically.

## NUMA

`src/numa.h` carries the topology detection, the thread binding and the network replication.
On a multi-socket machine, a thread reading a network resident on another socket pays
cross-node memory latency on every evaluation, which is most of what the engine does.

The network is therefore **replicated per NUMA node**, and threads are bound so each uses the
copy local to it. `LazyNumaReplicated` defers the copy until a node actually has a thread on
it, so a single-socket machine pays for one.

`src/shm.h` and `src/shm_unix.h` back `SystemWideSharedConstant`, which lets several engine
processes on one machine share one copy of a replicated network rather than each loading its
own -- relevant when a test harness runs many engines at once.

**This is the largest platform-specific surface in the tree** and the least covered by the
gates: the topology paths differ per OS, and `bench` exercises one thread on one node.

## Determinism

A single-threaded search is deterministic and `tests/reprosearch.sh` holds it to that: the
same node limit from the same position must produce the same node count, twice, across a
`ucinewgame`.

**A multi-threaded search is not deterministic and is not meant to be.** The divergence is
the mechanism -- threads that searched identically would contribute nothing to each other.
The bench signature is therefore a single-threaded number.

