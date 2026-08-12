# The platform layer

`src/platform/memory.h`, `src/platform/memory.cpp`, `src/platform/numa.h`, `src/platform/numa.cpp`, `src/platform/numa_shared.h`,
`src/platform/shm.h`, `src/platform/shm_unix.h`, `src/platform/thread_native.h`, `src/universal/`.

Everything the engine needs from the operating system: aligned and large-page allocation, CPU
topology and thread binding, cross-process shared memory, native threads with a chosen stack
size, and runtime ISA dispatch.

It is the largest per-platform surface in the tree and the one `bench` exercises least: a
single-threaded run on one node touches the allocator and nothing else here. `numa.h` alone is
the largest header in `src/`, and `shm.h` plus `shm_unix.h` come to more again:

```sh
wc -l $(git ls-files 'src/platform/*.h' 'src/platform/*.cpp') | sort -n
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

`HugePageSize` is `1 << 30` -- one gigabyte -- and it is the platform's own copy of a number the
engine also needs. `TranspositionTable::resize` passes the hint only when the table is at least
eight huge pages per NUMA node, so a small table does not reserve gigabyte pages it cannot fill
and cause memory oversubscription. **It reads the size from `arena().hugePageBytes`, not from
here**: the page size is a fact about the machine and belongs to the seam, while how many pages
per node are worth asking for is a property of the table and stays in `tt.cpp`. `Engine::
ArenaInstallerTag` registers this constant, so a hosted engine computes what it always did and an
unhosted one reaches the same answer from `DefaultHugePageBytes`.

**The engine does not call these.** It allocates through `engine/arena.h`, a struct of three
function pointers it declares and `Engine::ArenaInstallerTag` fills with
`aligned_large_pages_alloc`, `aligned_large_pages_alloc_with_hint` and
`aligned_large_pages_free`. Unregistered the arena falls back to plain aligned allocation,
which is why `tests/enginelink.sh` can link and run the engine with no platform object at all.

The installer is the **first member declared** in `Engine`, and that position is the whole
guarantee: a block taken from the fallback allocator and released by the host's is heap
corruption with no diagnostic. `ThreadPool threads` is declared **last** for the mirror of the
same reason -- reverse declaration order destroys the workers before the members they hold
references into. Both ends live in `src/shell/engine.h`, not in the constructor's initialiser
list, which decides nothing here.

Large pages need privilege on Windows (`OpenProcessToken`, `LookupPrivilegeValueA`, resolved
as function pointers) and `MADV_HUGEPAGE` on Linux. `has_large_pages()` reports whether the
request succeeded; the engine runs either way.

`memory_deleter` and `memory_allocator` are the templates that pair a custom allocator with a
`unique_ptr`, so an aligned block is freed by the function that allocated it. They live in
`src/engine/arena.h`, not here, because they are pure pointer arithmetic with no OS in them;
`memory.h` builds `LargePagePtr` and `AlignedPtr` from them, and `arena.h` builds `ArenaPtr`.
**Crossing the two is heap corruption with no diagnostic** -- `ArenaPtr` releases through
`arena_free`, `LargePagePtr` bakes `aligned_large_pages_free` into every instantiation -- which
is why the pairing is in the type rather than in a convention.

## `numa.h`, `numa.cpp` -- topology, binding and replication

The largest single header in the tree, and it carries only half of `NumaConfig`: the cold half
is in `numa.cpp`. The split is by temperature, not by subject -- everything that runs before the
first search is in the `.cpp`, and what stays in the header is template-bound and cannot move,
including the namespace-scope `STARTUP_PROCESSOR_AFFINITY` initializer, whose initialisation
order is a property of living there.

**That initializer runs once per translation unit, not once per process**, and it is the most
expensive thing this header does:

```
inline static const auto STARTUP_PROCESSOR_AFFINITY = get_process_affinity();
```

`static` at namespace scope is internal linkage and it wins over `inline`, so every TU that sees
the header gets its own copy and its own dynamic initialiser. `get_process_affinity()` `CPU_ALLOC`s
a 64K-CPU mask, calls `sched_getaffinity`, and loops `CPU_ISSET_S` over `MaxNumCpus = 1024 * 64`.
Priced on the instruction axis at roughly 607,000 retired instructions per copy:

```sh
cd src && for o in *.o; do nm -C "$o" 2>/dev/null | grep -q get_process_affinity && echo "$o"; done
./tests/perfbudget.sh --comp gcc <before> <after>   # read the startup column, not the search one
```

Dropping the `static` -- `inline const auto`, which keeps external linkage because an *inline*
const variable does not get internal linkage from its constness -- makes it one copy per program.
Nothing has done that yet.

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

`suggests_binding_threads(numThreads)` decides *whether* to bind at all and
`distribute_threads_among_numa_nodes(numThreads)` then decides *which* node each thread gets.
Two answers are fixed rather than derived: a user-set affinity that disagrees with the OS
always binds, and **a single thread never does** -- there is nothing to distribute. The cost of
not binding is stated in the same function: unbound threads can only use the replica on the
first node, so the engine takes the hit whenever the OS schedules elsewhere.

`NumaReplicatedAccessToken` is what a **`Thread`** holds to read the copy of a replicated object
belonging to its own node. The `Search::Worker` it drives does not hold one and never sees the
type: `thread.cpp` reduces the token to a `HistoryBankIndex` at construction, and
`thread.cpp`'s own `Thread::numa_access_token()` is what reads it back for
`ensure_network_replicated`. The engine indexes its history map; the host owns the topology.

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

`SharedMemoryBackend<T>` is defined three times over, one per `#if` arm: Windows, POSIX under
`USE_UNIX_SHM`, and a dummy whose `is_valid()` is always false, so a platform with no shared
memory compiles and simply does not share. `SharedMemoryBackendFallback<T>` is a fourth type
and a different thing -- it allocates a local large-page copy, and it is what
`SystemWideSharedConstant<T>` falls back to when the real backend reports invalid.

`SystemWideSharedConstant<T>` static-asserts `T` trivially destructible and trivially
copy/move-constructible: the object lives in a segment another process may outlive, so nobody
can run its destructor and it must contain no pointer into the process that wrote it.

The segment is named from a hash of the content, plus `getExecutablePathHash()` as a
discriminator: two different builds must not attach to each other's segment, and the
executable's path is what distinguishes them.

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
