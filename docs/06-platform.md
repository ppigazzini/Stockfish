# The platform layer

`src/platform/memory.h`, `src/platform/memory.cpp`, `src/platform/numa.h`, `src/platform/numa.cpp`, `src/platform/numa_shared.h`,
`src/platform/shm.h`, `src/platform/shm_unix.h`, `src/platform/thread_native.h`, `src/universal/`.

Everything the engine needs from the operating system: aligned and large-page allocation, CPU
topology and thread binding, cross-process shared memory, native threads with a chosen stack
size, and runtime ISA dispatch.

It is the largest per-platform surface in the tree and the one `bench` exercises least: a
single-threaded run on one node touches the allocator and nothing else here.

```sh
wc -l src/platform/memory.h src/platform/memory.cpp src/platform/numa.h src/platform/numa.cpp src/platform/numa_shared.h \
     src/platform/shm.h src/platform/shm_unix.h src/platform/thread_native.h src/universal/entry_x86.cpp
```

Audience: anyone porting to a new OS, or changing threading, allocation or the build's
dispatch.

## `memory.cpp` -- allocation

Three things the engine needs that `new` does not give:

| function | what it guarantees |
|---|---|
| `std_aligned_alloc` / `std_aligned_free` | alignment the NNUE vector kernels require |
| `aligned_large_pages_alloc` | the same, backed by huge pages where the OS offers them |
| `aligned_large_pages_alloc_with_hint(size, hugePageHint)` | the caller says whether huge pages are worth requesting |

`HugePageSize` is `1 << 30` -- one gigabyte. `TranspositionTable::resize` passes the hint only
when the table is at least eight huge pages per NUMA node, so a small table does not reserve
gigabyte pages it cannot fill and cause memory oversubscription.

Large pages need privilege on Windows (`OpenProcessToken`, `LookupPrivilegeValueA`, resolved
as function pointers) and `MADV_HUGEPAGE` on Linux. `has_large_pages()` reports whether the
request succeeded; the engine runs either way.

`memory_deleter` and `memory_allocator` are the templates that pair a custom allocator with a
`unique_ptr`, so an aligned block is freed by the function that allocated it. **Mixing them is
heap corruption with no diagnostic**, which is why the pairing is a template rather than a
convention.

## `numa.h`, `numa.cpp` -- topology, binding and replication

Still the largest single header in the tree, but no longer all of it: the cold half of
`NumaConfig` is in `numa.cpp`. The split is by temperature, not by subject -- everything that
runs before the first search is in the `.cpp`, and what stays in the header is template-bound
and could not move, including the namespace-scope `STARTUP_PROCESSOR_AFFINITY` initializer,
whose initialisation order is a property of living there.

### Discovering the topology

`NumaConfig::from_system(policy, respectProcessAffinity)` builds the map of which CPUs belong
to which node; `respectProcessAffinity` defaults to true. The policy is a variant:

| policy | grouping |
|---|---|
| `SystemNumaPolicy` | the nodes the OS reports |
| `L3DomainsPolicy` | one domain per L3 cache |
| `BundledL3Policy` | L3 domains bundled to a target count |

L3 grouping exists because the OS's idea of a node is not always the boundary that matters:
on a CPU where several L3 domains sit inside one reported node, treating each L3 as a domain
places threads closer to the memory they touch.

`respectProcessAffinity` makes the config honour an affinity mask set before the engine
started, so a harness pinning the process to a subset is not overridden. The startup mask is
captured once, at namespace scope, before anything can change it.

Windows needs two code paths, selected by whether the OS exposes `Cache.GroupCount` --
detected with a `HasGroupCount` SFINAE trait rather than a version check, so a build runs on
both.

### Binding threads

`distribute_threads_among_numa_nodes(numThreads)` returns which node each thread should bind
to. A **single thread is not bound at all**: binding it would restrict its memory to one node
for no benefit, since there is no second thread to be near.

`NumaReplicatedAccessToken` is what a worker holds to read the copy of a replicated object
belonging to its own node.

### Replication

Three shapes, differing in when the copy is made:

| class | copies |
|---|---|
| `NumaReplicated<T>` | one copy per node, eagerly |
| `LazyNumaReplicated<T>` | one copy per node, on first access from that node |
| `LazyNumaReplicatedSystemWide<T>` | the same, in shared memory so other processes attach instead of copying |

The subject is the NNUE network. A thread evaluating against a network resident on another
socket pays cross-node latency on every leaf, which is most of what the engine does. Lazy
replication means a single-socket machine pays for one copy.

`NumaReplicationContext` owns the set and the tokens; `NumaReplicatedBase` is the non-template
base it tracks them through.

## `shm.h`, `shm_unix.h` -- cross-process sharing

`LazyNumaReplicatedSystemWide` is backed by `SystemWideSharedConstant<T>`, which is where
`shm.h` enters. Several engine processes on one machine -- which is what a test harness
runs -- would otherwise each load their own copy of the network.

`SharedMemoryBackend<T>` has three specialisations (Windows, POSIX, and a
`SharedMemoryBackendFallback` that simply allocates locally), so a platform without shared
memory still works and simply does not share.

The segment is named from `getExecutablePathHash()`: two different builds must not attach to
each other's segment, and the executable's path is what distinguishes them.

`shm_unix.h` carries the POSIX implementation:

- `UniqueFd` is a move-only file-descriptor owner. Every `open` in this file goes through it,
  because a leaked descriptor in a process that spawns threads is not recoverable.
- `InitLock` serialises creation with a lock file, so two processes starting simultaneously do
  not both create the segment.
- One process acts as **server** and holds the segment; others attach as clients. The server
  runs a thread to serve them, which is why `SIGPIPE` has to be handled: a client disappearing
  mid-write would otherwise kill the server process.
- `memfd_create` is used where available and checked for at runtime rather than assumed.

## `thread_native.h` -- threads with a chosen stack

On most platforms `NativeThread` is `std::thread`. On macOS it is not:

```cpp
class NativeThread {
    pthread_t thread;
```

because threads other than the main thread are created there with a reduced stack, and the
search needs more than that. The wrapper calls `pthread_create` with an explicit stack size.

`std::thread` gives no way to set a stack size, which is the entire reason this file exists.

## `universal/` -- runtime ISA dispatch

A universal binary contains the engine compiled several times, once per instruction-set tier,
and picks at startup. `entry_x86.cpp`, `entry_arm64.cpp` and `entry_riscv64.cpp` are the
per-architecture entry points that do the picking -- `__builtin_cpu_supports` and `cpuid` on
x86, `sysctl` and hwcaps elsewhere.

Each tier's objects are compiled into a distinct namespace, so several copies of the whole
engine coexist in one image. `Makefile`'s `arch-namespace` and `arch-mac-section` functions
generate the names, and on Mach-O each tier gets its own initializer section.

`universal/nnue_embed.cpp` holds the embedded network for these builds; see
[03-engine-eval.md](03-engine-eval.md) for the three embedding mechanisms and why this
translation unit compiles at a different standard from the rest of the engine.

## What the gates reach

`bench` is single-threaded, runs on one node, sets no `SyzygyPath` and needs no shared memory.
It therefore exercises the allocator and nothing else described here.

The topology paths, the binding, the replication and the shared-memory server are covered by
the compile matrix -- which proves they build on every target -- and by whatever a developer
runs by hand. `tests/instrumented.py` drives multi-threaded searches under the sanitizer
lanes, which is the only automated coverage the threading path gets.

A change here is therefore a change whose correctness the gates largely do not establish.
