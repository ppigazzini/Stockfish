# The platform layer

`src/platform/memory.h`, `src/platform/memory.cpp`, `src/platform/numa.h`,
`src/platform/numa.cpp`, `src/platform/numa_shared.h`, `src/platform/shm.h`,
`src/platform/shm_unix.h`, `src/platform/thread_native.h`, `src/universal/`.

Everything the engine needs from the operating system: aligned and large-page allocation, CPU
topology and thread binding, cross-process shared memory, native threads with a chosen stack
size, and runtime ISA dispatch.

Why a `Search::Worker` takes a `HistoryBankIndex` rather than a topology handle, and what the
search sees of any of it, is [04-multithreading.md](04-multithreading.md)'s.

Audience: anyone porting to a new OS, or changing threading, allocation or the build's
dispatch.

## Where to look

| question | file | symbol |
|---|---|---|
| how the engine asks for memory | `src/engine/arena.h` | `Arena`, `arena_alloc`, `arena_free` |
| what fills that in for a hosted engine | `src/shell/engine.cpp` | `Engine::ArenaInstallerTag` |
| what actually calls the OS | `src/platform/memory.cpp` | `aligned_large_pages_alloc_with_hint` |
| which CPUs are on which node | `src/platform/numa.cpp` | `NumaConfig::from_system` |
| whether to bind at all, and where | `src/platform/numa.cpp` | `suggests_binding_threads`, `distribute_threads_among_numa_nodes` |
| one copy of a network per node | `src/platform/numa.h` | `NumaReplicated`, `LazyNumaReplicated` |
| one copy per machine | `src/platform/numa_shared.h`, `src/platform/shm.h` | `LazyNumaReplicatedSystemWide`, `SystemWideSharedConstant` |
| the POSIX segment, the socket, the temp root | `src/platform/shm_unix.h` | `UniqueFd`, `InitLock`, `TempRoot` |
| a thread with a stack the search fits in | `src/platform/thread_native.h` | `NativeThread` |
| which ISA tier this CPU runs | `src/universal/entry_x86.cpp` | `dispatch` |

It is the largest per-platform surface in the tree and the one `bench` exercises least: a
single-threaded run on one node touches the allocator and nothing else here. `numa.h` alone is
the largest header in `src/`, and `shm.h` plus `shm_unix.h` come to more again:

```sh
wc -l $(git ls-files 'src/platform/*.h' 'src/platform/*.cpp') | sort -n
```

## `memory.cpp` -- allocation

Three things the engine needs that `new` does not give:

| function | what it guarantees |
|---|---|
| `std_aligned_alloc` / `std_aligned_free` | alignment the NNUE vector kernels require |
| `aligned_large_pages_alloc` | the same, backed by huge pages where the OS offers them |
| `aligned_large_pages_alloc_with_hint(size, hugePageHint)` | the caller says whether huge pages are worth requesting |

`HugePageSize` in `memory.h` is `usize(1) << 30` -- one gigabyte -- and it is the platform's
own copy of a number the engine also needs. `TranspositionTable::resize` passes the hint only
when the table is at least eight huge pages per NUMA node, so a small table does not reserve
gigabyte pages it cannot fill and cause memory oversubscription. **It reads the size from
`arena().hugePageBytes`, not from here**: the page size is a fact about the machine and belongs
to the seam, while how many pages per node are worth asking for is a property of the table and
stays in `tt.cpp`.

```sh
grep -n 'hugePageHint' src/engine/tt.cpp
```

**The engine does not call these.** It allocates through `src/engine/arena.h`, whose `Arena`
struct carries three function pointers and one number:

| member | filled by a host with | when nothing is registered |
|---|---|---|
| `alloc` | `aligned_large_pages_alloc` | plain aligned allocation |
| `alloc_hinted` | `aligned_large_pages_alloc_with_hint` | the same, hint ignored |
| `free` | `aligned_large_pages_free` | the matching plain free |
| `hugePageBytes` | `HugePageSize` | `DefaultHugePageBytes`, the same value |

`hugePageBytes` has a **default member initialiser** because every registration site uses
braced aggregate initialisation, so a host that forgets the field would otherwise register
zero -- and zero is not a small huge page, it is a comparison that is true for every size, so
the hint would be set on every allocation and the run would still produce a number.

Every allocation goes through the free functions `arena_alloc`, `arena_alloc_hinted` and
`arena_free`, never through `arena()` directly, because those three maintain
`arena_live_blocks()` -- the count `set_arena` checks before it swaps an allocator out. That
counter is compiled only under `!NDEBUG`, so **the shipped build has nothing watching the one
failure on this seam that reports nothing at all**: a block taken from one allocator and
released by another is heap corruption with no diagnostic.

A host owes 4096-byte alignment from `alloc` and `alloc_hinted`. Nothing checks it:
`ASSERT_ALIGNED` is compiled out under `NDEBUG`, and an under-aligned block faults later inside
the NNUE's aligned vector loads with nothing pointing back at the registration.

Unregistered, the arena falls back to plain aligned allocation, which is why
`tests/enginelink.sh` can link and run the engine with no platform object at all.

The installer is the **first member declared** in `Engine`, and that position is the whole
guarantee: it runs before the transposition table or any history bank exists.
`ThreadPool threads` is declared **last** for the mirror of the same reason -- reverse
declaration order destroys the workers before the members they hold references into. Both ends
live in `src/shell/engine.h`, not in the constructor's initialiser list, which decides nothing
here.

```sh
grep -n 'arenaInstaller\|ThreadPool threads' src/shell/engine.h
```

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

The split between header and unit is by **who instantiates what**, not by how hot the code is.
`NumaConfig`'s whole construction path is in the `.cpp`: both constructors,
`add_cpu_to_node`, `add_cpu_range_to_node`, `remove_empty_numa_nodes`, and the two member
templates that walk sysfs and the L3 topology. The rule that lets a member template move is
worth stating exactly, because the obvious reading of "template-bound" gets it wrong:

> A template must be visible where it is **instantiated**, not everywhere its class is named.

`from_system_numa` and `try_get_l3_aware_config` are instantiated at exactly one place --
`NumaConfig::from_system`, in `numa.cpp` -- so they compile in the unit they moved into and the
compiler sees the same code in the same place.

What genuinely cannot follow is instantiated by consumers: `execute_on_numa_node`, which
`thread.cpp` calls with two different callables, and `NumaReplicated<T>` /
`LazyNumaReplicated<T>` / `NumaReplicationContext`, which `numa_shared.h` and `thread.h`
instantiate. The one-line accessors stay too, for the ordinary reason -- a call is worse than
an inline body for `num_cpus()`.

**The namespace-scope affinity read must be one copy per program, and the keyword that decides
that is the one it is missing:**

```
inline const auto STARTUP_PROCESSOR_AFFINITY = get_process_affinity();
```

`static` at namespace scope is internal linkage and it wins over `inline`, so writing
`inline static const` here gives every translation unit that sees the header its own copy and
its own dynamic initialiser. Each of those runs `get_process_affinity()`, which `CPU_ALLOC`s a
mask for `MaxNumCpus = 1024 * 64` processors, calls `sched_getaffinity`, and loops
`CPU_ISSET_S` over all of them -- at process startup, before anything the engine does. An
`inline` const variable does not get internal linkage from its constness, so without the
`static` there is one copy and one initialiser. The symbol is a single weak `W` rather than a
local `b` in every object that included the header:

```sh
cd src && for o in *.o; do nm -C "$o" 2>/dev/null | grep -q get_process_affinity && echo "$o"; done
./tests/perfbudget.sh --comp gcc <base> <head>   # read the startup column, not the search one
```

### Discovering the topology

`NumaConfig::from_system(policy, respectProcessAffinity)` builds the map of which CPUs belong
to which node; `respectProcessAffinity` defaults to true. The policy is a
`std::variant<SystemNumaPolicy, L3DomainsPolicy, BundledL3Policy>`:

| policy | grouping |
|---|---|
| `SystemNumaPolicy` | the nodes the OS reports |
| `L3DomainsPolicy` | one domain per L3 cache |
| `BundledL3Policy` | L3 domains bundled until each reaches `bundleSize` |

L3 grouping exists because the OS's idea of a node is not always the boundary that matters:
on a CPU where several L3 domains sit inside one reported node, treating each L3 as a domain
places threads closer to the memory they touch.

`respectProcessAffinity` makes the config honour an affinity mask set before the engine
started, so a harness pinning the process to a subset is not overridden. The startup mask is
captured once, at namespace scope, before anything can change it.

Windows needs two `readCacheMembers` overloads, chosen by whether the SDK's cache-info struct
has a `Cache.GroupCount` field. The `HasGroupCount` SFINAE trait is what picks, rather than a
version macro, so one source tree builds against either SDK -- and the older layout is still
handled at runtime, because Windows 10 reports a `GroupCount` of zero and the newer overload
clamps it to one.

**`add_cpu_to_node` and `add_cpu_range_to_node` are `[[nodiscard]]`.** They return false when
the CPU is already present and leave the structure unmodified, and every caller in the tree
discards that answer -- but each discards it for a different reason: a system enumeration that
cannot repeat an index, a merge over disjoint domains, an empty config nothing can collide
with. `[[nodiscard]]` is what forces each site to write `(void)` and say which reason applies,
so a new caller cannot inherit the silence.

```sh
grep -n '(void) .*add_cpu' src/platform/numa.cpp
```

### Binding threads

`suggests_binding_threads(numThreads)` decides *whether* to bind at all and
`distribute_threads_among_numa_nodes(numThreads)` then decides *which* node each thread gets.
Two answers are fixed rather than derived: a user-set affinity that disagrees with the OS
always binds (`customAffinity`), and **a single thread never does** -- there is nothing to
distribute. The cost of not binding is stated in the same function: unbound threads can only
use the replica on the first node, so the engine takes the hit whenever the OS schedules
elsewhere.

`NumaReplicatedAccessToken` is what a **`Thread`** holds to read the copy of a replicated
object belonging to its own node. The `Search::Worker` it drives does not hold one and never
sees the type: `thread.cpp` reduces the token to a `HistoryBankIndex` at construction --
explicitly, since the scoped enum admits no other way -- and `Thread::numa_access_token()` is
what reads it back for `ensure_network_replicated`. The engine indexes its history map; the
host owns the topology.

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
base it tracks them through. `NumaReplicated` and `LazyNumaReplicated` both take that context
by `explicit` constructor: a handle is not a thing that should silently become an owner.

## `shm.h`, `shm_unix.h` -- cross-process sharing

`LazyNumaReplicatedSystemWide` is backed by `SystemWideSharedConstant<T>`, which is where
`shm.h` enters. Several engine processes on one machine -- which is what a test harness
runs -- would otherwise each load their own copy of the network.

`SharedMemoryBackend<T>` is defined three times over, one per `#if` arm: Windows, POSIX under
`USE_UNIX_SHM`, and a dummy whose `is_valid()` is always false, so a platform with no shared
memory compiles and simply does not share. `SharedMemoryBackendFallback<T>` is a fourth type
and a different thing -- it allocates a local large-page copy, and it is what
`SystemWideSharedConstant<T>` falls back to when the real backend reports invalid.

```sh
grep -n 'class SharedMemoryBackend\|^#if\|^#elif\|^#else' src/platform/shm.h
```

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

**Where the per-user root lives is an environment question, not a constant.** `TempRoot`
proposes `<base>/stockfish-<uid>` at mode 0700 and reads the base from `XDG_RUNTIME_DIR`, then
`TMPDIR`, then `/tmp`. The first is per-user, 0700 and tmpfs by construction, which is what this
wants; the second is what a container or a hardened host sets when `/tmp` is not writable, or is
mounted per-user so that two engines see different directories under one name. Absolute paths
only, and whichever base wins the directory is still `lstat`'d for owner and mode -- an
attacker-controlled `TMPDIR` is a directory like any other, and a root that fails the check is
refused rather than used.

**Peers that disagree about the environment do not meet**, and that is the intended behaviour:
they land in different roots, find no peer, and each map their own copy, which is the no-sharing
path the code already takes when it is first to start. Picking a root one process can reach and
another cannot write would be the fault.

**The `.sock` litter is self-limiting.** `cleanup_at_exit` runs on a normal exit only -- taking
its mutex in a signal handler is not async-signal-safe -- so a Ctrl-C leaves the socket behind.
The next process reaps it: `try_receive_memfd` unlinks any socket whose `connect` returns
`ECONNREFUSED` or `ENOENT`. A connect to a socket with no listener is refused immediately, so
reaping on the next start costs nothing measurable even against thousands of stale sockets --
the one-second timeouts on that path are `SO_SNDTIMEO` and `SO_RCVTIMEO`, which apply to send
and recv, not to connect.

## `thread_native.h` -- threads with a chosen stack

`NativeThread` is `std::thread` **only under `_MSC_VER`**, and a `pthread_t` wrapper
everywhere else -- Linux, macOS and every other non-MSVC target take the wrapper:

```cpp
class NativeThread {
    pthread_t thread;
    static constexpr usize TH_STACK_SIZE = 8 * 1024 * 1024;
```

macOS is the platform that forces it: threads other than the main thread are created there with
a 512 KB stack, and a deep search needs more than 1 MB. The wrapper calls `pthread_create` with
`TH_STACK_SIZE`, which is the Linux default rather than the minimum that works. MSVC-compatible
toolchains do not ship pthreads, which is why that one arm is different rather than that one
arm being the general case.

`std::thread` gives no way to set a stack size, which is the entire reason this file exists.

**A failed spawn exits the process rather than returning.** Nothing else can clear the caller's
`searching` flag, so `Thread`'s own `wait_for_search_finished()` would block forever -- silently,
on the thread that would have read the `quit`. `pthread_create` failing prints and calls
`std::exit`, which is the same answer the MSVC arm reaches by letting `std::thread` throw.

## `universal/` -- runtime ISA dispatch

A universal binary contains the engine compiled several times, once per instruction-set tier,
and picks at startup. `entry_x86.cpp`, `entry_arm64.cpp` and `entry_riscv64.cpp` are the
per-architecture entry points that do the picking -- `__builtin_cpu_supports` and `cpuid` on
x86, `getauxval`/hwcaps and `sysctl` elsewhere.

`dispatch` in `entry_x86.cpp` is an ordered ladder from `x86-64` up to `x86-64-avx512icl`, and
two rungs are decided by something other than a feature bit: `has_slow_bmi2()` sends a CPU with
microcoded `pext` back to the avx2 tier, and an AVX512 machine without the full Icelake-client
suite stops at `vnni512`. Read the ladder rather than the feature list:

```sh
awk '/^static int dispatch/,/^}/' src/universal/entry_x86.cpp
```

Each tier's objects are compiled into a distinct namespace, so several copies of the whole
engine coexist in one image. `Makefile`'s `arch-namespace` and `arch-mac-section` functions
generate the names, and on Mach-O each tier gets its own initializer section.
`src/universal/rewrite_asm_sections.awk` does the same job for clang on Windows, and
`src/universal/patch_x86_slice.sh` rewrites `gUniversalNNUEOffset` and `gUniversalNNUESize` in
the x86 slice so they address the embedded net inside the full executable rather than inside
the slice.

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

## The gates

| gate | what it proves here | owned by |
|---|---|---|
| `scripts/check_universal.sh` | the x86-64 runtime-dispatch binary selects the right architecture at run time, not merely that it built | this page |
| `scripts/check_universal_arm.sh` | the same for aarch64 | this page |
| `scripts/check_universal_macos.sh` | the same for the macOS universal binary | this page |
| `scripts/check_universal_riscv.sh` | the same for riscv64 | this page |
| `scripts/get_native_properties.sh` | the host ISA is detected and named as an enumerated `ARCH` | this page |
| `scripts/net.sh` | the network the build expects is downloaded and verified | this page |
| `tests/fuzz.py --harness shm` | a process that dies because a *peer* died is the defect; one killed on purpose is the stimulus | [10-tooling-ci.md](10-tooling-ci.md) |

`universal_compilation.yml` is the only lane that compiles `src/universal/` and the only one
running `scripts/check_universal.sh`, so dropping it would leave the dispatch layer with no
coverage of either kind.
