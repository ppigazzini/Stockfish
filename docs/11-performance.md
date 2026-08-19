# Performance

The six axes that decide what a change costs, and `tests/fingerprint.sh` beside them.

`tests/signature.sh` proves the engine searched the same tree ([10-tooling-ci.md](10-tooling-ci.md));
it says nothing about what that tree cost. These do, and they are not interchangeable.

Audience: anyone measuring a refactor or an optimisation.

The rule the programme runs under is absolute:

> Every refactor must keep or improve performance. Even a very small regression is forbidden.

A rule like that is worth nothing without an instrument that can see a small regression, so what
each axis cannot see is stated with what it can.

## Which axis answers which claim

**There are six of them because there are six questions.** Picking the wrong one produces a
confident wrong verdict, so pick by what the change CLAIMS:

| the change claims | gate | why |
|---|---|---|
| "this is pure code motion" | `tests/textequal.sh` | a codegen-equivalence proof has no noise floor; one run settles it |
| "this costs nothing" (a refactor) | `tests/perfbudget.sh` | deterministic; an instruction increase in a behaviour-preserving change is a real red flag |
| "this is faster" (an optimisation) | `tests/npsab.sh`, and probably fishtest | the instruction axis can report the wrong sign -- see below |
| "this moved no cache line" | `tests/perfcounters.sh` | the only axis that measures a miss or a mispredict on the hardware, and the only counting axis that runs above AVX2 |
| "and if it did, where?" | `tests/perfdecomp.sh` | per-component instructions, misses and mispredicts; deterministic, and a model |
| "this scales" | `tests/npsthreads.sh` | every other axis runs one thread, so a contention change is invisible to all five |

The last two divide one question between them. `perfcounters.sh` measures the hardware and
cannot say which code moved; `perfdecomp.sh` says which code moved and is measuring a simulator.
Neither replaces the other, and where they disagree the hardware is the fact.

## `tests/perfbudget.sh`

Retired instructions under callgrind, base against head, built and measured in the same run.

```sh
./tests/perfbudget.sh HEAD~1                    # this commit against its parent
./tests/perfbudget.sh origin/master worktree    # uncommitted work
./tests/perfbudget.sh --pgo HEAD~1              # the build that actually ships
./tests/perfbudget.sh --syzygy DIR HEAD~1       # a PROBING workload, not the bench list
```

**`--syzygy` is not an option, it is a different workload.** The bench list never probes, so
without it the whole tablebase reader is absent from every figure this gate produces and a
bound placed inside `decompress_pairs` reads as free. Anything touching
`src/platform/syzygy/` quotes that cell. An empty `DIR` skips rather than measuring nothing.

**The corpus and the positions are one choice, and `--fens` is how the second half is made.**
The default list is `tests/tbprobe.fens`, which is four men, and the largest table it reaches is
148 KB; `tests/tbprobe5.fens` against the `--men 5` corpus reaches 13.7 MB. Block count scales
with table size, so a decoder cost measured on the small pair is a **lower bound** on the same
cost in the large one -- the gate prints which it measured, reading the men count off the corpus
rather than asserting it. Mismatch the two and nothing fails: 4-man positions leave a 5-man
corpus's big table unread, and 5-man positions find no table at all in the 3-4-man one. Name
both in the command and in whatever quotes it:

```sh
./tests/perfbudget.sh --syzygy resources/syzygy-5man --fens tests/tbprobe5.fens HEAD~1
```

**Measure both build modes.** `make profile-build` is the shipped recipe, and the two do not
agree on the size of a regression: forcing `Position::adjust_key50` out of line reads
materially cheaper under PGO than at `-O3`, because the profile lets the compiler make a
better job of the out-of-line call. Take both figures rather than quoting one:

```sh
./tests/perfbudget.sh HEAD~1 && ./tests/perfbudget.sh --pgo HEAD~1
```

A budget taken only at `-O3` gates a binary nobody runs.

Four properties, each deliberate:

- **No golden is stored.** An absolute instruction count is a property of the toolchain and
  the libc as much as of the code, so it cannot be reproduced by a reviewer and it drifts
  upward until it gates nothing. Only the delta is reported, and it is reproducible by
  re-running.
- **Startup is subtracted by measurement**, per binary. Net load plus magic-table
  construction is a large share of the whole-process count at the depth the gate uses, so an
  unsubtracted ratio describes the network loader as much as the engine.
- **A node count that moved makes the comparison VOID**, not expensive. That is a behaviour
  change and `signature.sh` owns it.
- **The tolerance is set from measurement**: the A/A floor across independent builds, against
  a mutation that forces `Position::adjust_key50` out of line. Never raise it to fit a change.

**The limit that matters, and it is not theoretical.** Upstream `ee72cf49f` "Optimize
RankAttacks" is marked *No functional change* and passed an SPRT on fishtest. It shrinks a
table 4x, trading retired instructions for cache footprint. This gate scores it a
**regression** -- it does not merely miss the win, it reports the wrong sign. An instruction
count cannot see a latency or locality win and is not neutral about one; the same applies to
extra accumulator chains, unrolling for ILP, and software prefetch, which callgrind does not
model at all.

So: **never let this gate alone veto a change whose claim is locality, prefetch or latency
hiding.**

**And the verdict on that class is compiler-dependent.** Three upstream commits, each marked
*No functional change*, under both compilers the tree builds with:

```sh
for c in d70dec7d6 a255ad59e ee72cf49f; do
  for comp in gcc clang; do ./tests/perfbudget.sh --comp "$comp" "$c~1" "$c"; done
done
```

`d70dec7d6` "Optimize attacks" and `a255ad59e` "Optimize evasions" genuinely retire fewer
instructions, and both compilers agree they are improvements. `ee72cf49f` is the locality
change, and the two disagree about its sign. That gives a usable rule: **a sign that flips
between gcc and clang means the change is not an instruction-count change at all**, and the
instruction axis is the wrong instrument for it.

callgrind implements no AVX-512 and dies on the first instruction it does not know, so the
instruction axis stops at avx2/bmi2 -- below the tier a player builds. An `--arch` matching
`avx512` or `vnni` **SKIPs at exit 2** rather than producing a number, so a grid loop that reads
only "not a failure" records the tier as measured when nothing measured it.

Dispatched by `perfbudget.yml` at two tiers, base against head.

## Moving a body out of a header is not free, and its size barely matters

**This is the trap a decomposition walks into, and it was measured on this tree.** Take a
function that is defined in a header, move it into a `.cpp`, and the compiler must now emit it
where before it could inline it away. That is a change to the whole-program inliner's budget,
and with LTO on the budget is global -- so what comes back different is not the moved code but
whatever the inliner decided to stop inlining elsewhere, which on this tree is
`Search::Worker::search`.

| what moved | search, gcc 13.3 `x86-64-avx2` |
|---|---|
| A/A control, same revision both sides | +286 Ir |
| two once-per-process functions out of `shm_unix.h` | **+175,341 Ir (+0.0133%)** |
| a whole 137-line mapper out of `tbprobe.cpp` | **+303,067 Ir (+0.0229%)** |

Neither change moves code the bench executes -- the bench opens no tablebase and reads no
shared-memory root -- and `textequal.sh` with LTO off reports **no symbol body changed** across
the second one. Folding that mapper back into a single translation unit left the cost unchanged,
so it is not the file boundary either.

**Three consequences for anyone restructuring a header here.**

1. **Measure the bench list even when the change has nothing to do with it.** A slice whose
   claim is about tablebase code still has to answer for a workload that never opens one.
2. **The gate's tolerance is a noise allowance, not a budget.** 0.0133% passes and is still six
   hundred times the A/A floor. A refactor that spends it has spent something.
3. **Templates are the exception, and the reason is precise.** A template must be visible where
   it is *instantiated*, not everywhere its class is named -- so a member template whose
   instantiations all live in one translation unit can move into that unit and the compiler sees
   the same code in the same place. Moving two such templates out of `numa.h` read flat or
   better in all six cells.

So: move templates whose instantiations all live in one unit; leave non-template bodies in the
header unless the measurement says otherwise.

**Do not read for candidates by eye -- let the compiler name them.** A template instantiated in
one translation unit leaves a weak symbol in exactly one object file, so build with LTO off and
ask which weak symbols have a single definer:

```sh
for o in *.o; do nm --defined-only -C "$o" | awk -v o="$o" '$2=="W"||$2=="V"{   $1="";$2="";print o"	"substr($0,3)}'; done   | awk -F'	' '{c[$2]++; own[$2]=$1} END{for (k in c) if (c[k]==1) print own[k]"	"k}'
```

`tests/textequal.sh` shows how to get LTO-free objects: `EXTRACXXFLAGS=-fno-lto` does not work,
because `src/Makefile` appends `-flto` after it, so the gates build through a `COMPCXX` wrapper
that strips the flag.

A single definer makes a template a candidate and nothing more. Ask three questions before
moving one: is it on the per-node path, does an explicit instantiation pin argument types a
future caller would have to add to, and does anything but the file it already lives beside
include the header?

## Which lane is binding

`perfbudget.sh` runs at plain `-O3` or with `--pgo`, and on header restructuring the two do
not agree. Take the whole grid rather than one cell of it -- two tiers, two compilers, both
build modes:

```sh
for arch in x86-64-avx2 x86-64-bmi2; do
  for comp in gcc clang; do
    ./tests/perfbudget.sh --arch "$arch" --comp "$comp" HEAD~1
    ./tests/perfbudget.sh --arch "$arch" --comp "$comp" --pgo HEAD~1
  done
done
```

**PGO is the binding lane.** It is upstream's own recipe, it is what ships, and it is what
fishtest measures; a refactor that is free there and costs under a build nobody distributes has
not cost a player anything. The plain `-O3` figure is advisory: record it in the commit body,
investigate it when it is large, and do not let it alone veto a change. That is a decision
about which measurement answers the question, not a licence to skip one. A change still reports
both, and a regression under PGO still does not land.

**One `-O3` lane is not evidence; the pattern across lanes is.** A header change can exceed
tolerance at one (tier, compiler) pair and be free at every other, and which pair that is does
not repeat from change to change. A reading that changes sign or vanishes when the compiler or
the tier changes is not an instruction-count change at all.

**A startup probe that moves makes the subtracted search figure move the other way.** The gate
reports `total - startup`, so a change whose whole process retires fewer instructions can still
read as a regression when its separately measured startup probe got cheaper by more. The number
is real and its sign is not the change's, which is the same class of trap as the locality case
above.

**Startup carries its own verdict, at its own tolerance.** Two deltas are printed and both are
reported before either exits, so a run that regressed on both does not send the reader to fix
one and rediscover the other. `--startup-tolerance` defaults to 1%, against the search
tolerance's 0.02%, because startup is paid ONCE per process and the search is not: a tenth of a
percent in the loader is invisible to a player who then searches for minutes, and the same tenth
in the search is the whole subject of this gate. It is a real quantity either way -- this tree
has moved it by a sixth -- and before it was gated it was measured, printed, and decided by
nobody in either direction.

## `tests/textequal.sh`

Per-symbol machine-code equivalence, LTO disabled.

```sh
./tests/textequal.sh HEAD~1
```

The strongest evidence a pure code-motion change can carry: not a benchmark with a noise
floor but a proof that the compiler emitted the same instructions.

**It does not prove the shipped binary unchanged**, and the reason is worth carrying: the
tree links with `-flto=full` (clang) or `-flto -flto-partition=one` (gcc) by default, and LTO
is exactly where a moved function changes an inlining decision. The gate also clears the
build stamp (`GIT_SHA`, `GIT_DATE`, `GIT_DIFFINDEX`) on both sides so the version string
cannot shift rodata under it -- another reason it is not a statement about the shipped
binary, which carries its stamp.

A green run narrows what `perfbudget.sh` has to catch. It does not replace it.

`perfbudget.yml` runs it after the budget under **`continue-on-error`**: the codegen comparison
informs and does not block, so a red run there is a comment on a merge nobody stopped.

**It proves nothing about a change to a SIGNATURE**, which is the limit to know before reaching
for it on a typing change. A parameter's type is part of the mangled name, so replacing a `bool`
parameter with a scoped enum renames every symbol that mentions it -- including the ones a caller
instantiated, `std::stable_sort`'s comparator chain among them. The gate matches bodies by name,
so each renamed symbol appears once under *only in base* and once under *only in head*, and its
body is never compared. Typing two `bool` parameters in one prototype renamed 14 symbols here and
left the verdict at DIFFERS with nothing established either way. Use `perfbudget.sh` for those;
`textequal.sh` answers only for changes that keep every signature byte-for-byte.

**The trailing run of alignment padding is dropped from each symbol**, and the word trailing is
load-bearing. objdump attributes the nops that align the NEXT function to the end of the current
one, so adding or removing a function anywhere shifts what follows it against a 16-byte boundary
and changes that run's length in symbols the change never touched. Without this the gate reported
two changed bodies for a commit that deleted five unused includes -- three `cs nopw` becoming one
`nopl` in one symbol, one becoming four in another, no instruction different in either, and
neither file touched.

A nop in the MIDDLE of a body is not padding: it is branch-target alignment the compiler chose to
emit, and dropping those would hide a real codegen change. So the run is peeled from the end and
stops at the first instruction that is not a filler.

The instruction totals this gate prints therefore exclude padding, and are a few thousand lower
than a raw disassembly count for that reason.

When a verdict still says DIFFERS, `--keep` retains the normalised listings and a per-symbol diff
says which symbol and which instruction:

```sh
./tests/textequal.sh --comp gcc --keep <base> <head>
cd <kept dir> && diff <(grep '^<mangled>	' base.txt | cut -f2-) \
                      <(grep '^<mangled>	' head.txt | cut -f2-)
```

## `tests/npsab.sh`

Interleaved paired wall-clock A/B, reporting the median of the paired ratios and its spread.

```sh
./tests/npsab.sh HEAD~1
```

Three rules are built in, and each closes a way a wall-clock A/B reports a number that is not
the change: alternate which binary runs first, because the second slot in a round runs on a
hotter core; report the spread, not just the median; and read the engine's own bench clock,
which starts after the network load and so contains no startup.

**A spread that straddles 1.000 has established no direction**, and the tool says so rather
than reporting the median as a result. On a box doing anything else at the same time that is
the expected outcome for a change of the size a refactor makes -- which is why the instruction
axis exists.

## `tests/npsthreads.sh`

How the two revisions SCALE, across thread counts.

```sh
./tests/npsthreads.sh 5062aee5                       # 1 2 4 8 ... up to nproc
./tests/npsthreads.sh --threads "1 16" --rounds 5 HEAD~1
```

**Every other axis in this tree is single-threaded.** `perfbudget.sh`, `perfcounters.sh`,
`perfdecomp.sh` and `npsab.sh` all run `bench <tt> 1 <depth>`, and `match.sh` defaults to
`Threads 1`. A player runs eight or sixteen, so nothing else here measures contention on the
shared last level, on the transposition table, or on the counters the search manager polls.

**The other axes cannot simply be pointed at more threads, and the reason is not effort.** They
all refuse a comparison whose node counts differ, correctly -- a count over a different tree is
not comparable. But a multi-threaded search at a fixed DEPTH is not reproducible against itself.
Three runs of `bench 128 8 10 default depth` on this tree gave 4,214,870, 4,775,340 and
4,098,171 nodes: a **16.5% spread** against a 0.02% tolerance. The single-threaded run beside it
repeats exactly. Every existing gate reports VOID and learns nothing.

**So the node count becomes the input.** With `nodes` as the limit type the search stops on a
node budget rather than a depth, and the workload is fixed by construction; only the overshoot
past the budget varies. The same three runs at `bench 128 8 3000000 default nodes` gave
147,141,383, 147,141,788 and 147,146,570 -- a **0.0035% spread**. That is why this gate takes
`--nodes` and not `--depth`, and why it carries a tolerance where `npsab.sh` carries an
equality.

**Read `r(T)/r(1)`, not the nps column.** The threaded nps ratio conflates single-thread speed,
which three other axes already measure more precisely, with scaling, which none of them do. The
headline divides the first out:

> `r(T)/r(1)`, where `r(T)` is the median paired nps ratio at T threads

which is identically the ratio of the two sides' scaling efficiencies. Below 1.000 means head
scales worse. A value inside the A/A half-width printed beside it has established no direction,
and that control widens with thread count on every box.

**The hash is held FIXED across thread counts**, because a game has one hash size whatever the
thread count. Growing it with T is the standard way to make a scaling curve look good, and it
hides exactly the contention this gate exists to find.

It refuses `ARCH=native`, warns when asked for more threads than the host has cores -- above
that it measures the scheduler -- and warms both binaries at the WIDEST thread count, so the
pool spin-up and the hash faulting are not paid inside round 1 of the row most likely to be
quoted.

## `tests/fingerprint.sh`

Per-function **call counts** between two revisions.

```sh
./tests/fingerprint.sh HEAD~1
```

**No workflow runs it.** `lanecheck.sh` excuses it on cost -- callgrind over the whole call
graph -- not on capability, so a lane could exist and does not; it runs when someone remembers
it before a decomposition.

Every other gate here compares values -- a node total, an instruction count, a disassembly.
This one asks whether the engine still gets to its answer by calling what it called, as
often. A change that claims to be a decomposition is exactly where that can move while every
value stays put, which makes this the instrument for splitting a large function.

A call count is inlining-immune **at the callee**: it does not care how the callee was
reached, only that it was. It is **not** immune at the caller -- a function inlined into its
caller disappears from the profile -- so read the one-sided list as inlining differences and
the changed list as the signal.

### The workload decides what the fingerprint can see

The bench list never opens a tablebase, so every call inside the reader is absent from a
default profile and a change routed through `decompress_pairs` reports no call-count change at
all. `--syzygy` points `SyzygyPath` at a directory and drives `tests/tbprobe.fens` instead:

```sh
./tests/fingerprint.sh --syzygy tests/syzygy-3man HEAD~1
```

The difference is the whole reason the option exists. A depth-8 bench run reports `tbhits 0`
and 215 engine symbols; the probing run reports `tbhits` above zero, 245 engine symbols, and
`decompress_pairs` called 243,166 times. A missing directory, a directory with no `.rtbw` and
an empty FEN file all **skip**, because a probing measurement taken with no tables loaded is
the bench list wearing a different name.

Depth defaults to 14 rather than 8 under `--syzygy`, matching `perfbudget.sh`, so a call count
from this gate and an instruction count from that one describe one workload rather than two.

What the probing profile carries that the search does not: the `SyzygyPath` line runs as the
first bench command, so mapping the tables is inside the measured region. `perfbudget.sh`
subtracts that through a startup probe; this gate has nothing to subtract, because a call count
is not a difference of two totals. A change to the table **loader** therefore moves counts here
too.

### Scope, and the two classes outside the verdict

Scope is the engine's own symbols. The allocator and glibc's thread-cancellation counters
(`_int_malloc`, `sbrk`, `munmap`, the pthread cancel pair) move between two runs of one
binary, so they are reported apart from the verdict rather than folded into it. Functions
callgrind can only name by address are excluded: two builds place them differently, so they
have no comparable identity.

**One engine symbol is outside it too, and the reason is a limit on the determinism claim.**
`SearchManager::check_time` fires the debug dump on `tick - lastInfoTime >= 1000` -- a
wall-clock millisecond count, not a node count -- so `dbg_print` is called once per second of
*real* elapsed time. callgrind runs the engine roughly 50x slower than the metal and the factor
moves with machine load, so that one count differs between two runs of the same binary. It is
listed below the verdict with its count rather than dropped. Add a symbol to `CLOCK_DRIVEN`
only when its call sits under a branch on elapsed **time**; that it moved in an A/A is the
symptom every real defect has too.

It is otherwise deterministic: an A/A run reports IDENTICAL across every engine symbol, on the
bench list and on a probing workload alike, so any changed count is the change and not the
machine. `tests/negative_control.sh fingerprint` is that property going red -- it forces
`Position::adjust_key50` out of line, which turns an inlined body into a called symbol with a
count of its own.

**The build stamp is neutralised on both sides**, for the reason `textequal.sh` carries the same
line: `misc.o` is compiled with `-DGIT_SHA`, `-DGIT_DATE` and `-DGIT_DIFFINDEX`, an empty
`GIT_SHA` selects a different branch of `engine_version_info`, and under LTO that moves inlining
decisions elsewhere in the binary -- which moves a call count with them.

**It was not, and the way that hid is worth knowing before trusting any two-path gate.** This
script prepares a *revision* with `git worktree add`, which carries `.git` and therefore a
populated stamp, and prepares `worktree` from a `tar` copy that excludes `.git` and stamps empty.
Same revision down the two paths produced different binaries, so `worktree` mode -- the mode a
developer uses on uncommitted work -- compared a stamped binary against an unstamped one and
attributed the difference to the change under test. It reported a per-node function at 91487 to
35884 calls for a working tree in which that function was byte-size identical with the same three
call sites in the same caller.

Neither of the two controls available could see it. An A/A run is quiet, but only in the mode it
runs in. A null perturbation over two revisions with identical `src/` -- a docs-only commit --
reports IDENTICAL, because both sides get a populated stamp. **A gate with two build paths needs a
control per path**, and this one had one control and two paths.

## `tests/perfcounters.sh`

What the hardware actually did, base against head, at every architecture tier in `--tiers`.

```sh
./tests/perfcounters.sh                      # merge-base with master, against HEAD
./tests/perfcounters.sh --rounds 7 --comp clang
./tests/perfcounters.sh --tiers "x86-64-avx2" --pgo
./tests/perfcounters.sh --syzygy resources/syzygy-5man --fens tests/tbprobe5.fens
```

`perfbudget.sh` simulates and `npsab.sh` times. This one reads the CPU's counters:
instructions, cycles, cache misses and references, branch misses and branches, plus IPC and the
two miss rates derived from them. It reaches what neither other axis can.

**It is the only counting axis that runs above AVX2.** callgrind implements no AVX-512 and dies
on the first instruction it does not know, so `perfbudget.sh` and `perfdecomp.sh` refuse those
tiers outright -- and those are tiers players build. `npsab.sh` builds whatever `--arch` it is
given, but it times rather than counts and cannot resolve a small difference. The default tier
set spans plain `x86-64` up to an AVX-512 tier; `TIERS` at the top of the script is the current
list.

**It answers a question the instruction axis cannot even ask.** A change that keeps
instructions and loses IPC has moved a cache line; the budget scores that as free. This is the
same asymmetry that makes `perfbudget.sh` report a locality win with the wrong sign.

It uses `perf_event_open` directly through `tests/perf_counters.cpp`, not the `perf` CLI, which
is a separate package and absent on plenty of machines that can still count. That needs
`perf_event_paranoid` at 2 or lower -- the usual default -- and a container needs `CAP_PERFMON`;
without it the script skips rather than reporting zeroes.

`tests/perfcounters_report.py` does the aggregation. It reports the median of the **paired**
ratios, not the ratio of the medians: a pair is one round, and a round is the only comparison in
which both sides saw the same machine state.

**Read the spread, not the median.** Instructions and branches are near-deterministic; cycles,
IPC and both miss counts are not, and they move with frequency scaling, with what else the
machine is doing, and with where the scheduler puts the process. A ratio whose spread straddles
1.000 has established no direction, and the report says so in those words rather than printing a
median that looks decisive.

**A counter's meaning belongs to the microarchitecture, not to the tool.** What
`PERF_COUNT_HW_CACHE_MISSES` counts differs between CPUs and under a hypervisor may be
approximated or unavailable. The ratio is between two binaries measured on one box in one run,
and it is comparable to nothing else -- never quote one machine's miss rate beside another's.

Exit 0 means measured, not clean -- whether a moved miss rate is acceptable is a judgement the
table informs rather than makes. Exit 1 is reserved for the one thing the script can decide
alone: the two sides searched a different number of nodes, so the comparison is VOID.

A tier that fails to build measured nothing and is recorded as exit 2, because `continue` alone
would leave the exit code at 0 and a grid in which every tier failed to compile would read as a
pass. **A skip demotes, it never overwrites**: the status variable is last-writer-wins, so a
late tier failing to build would otherwise bury a VOID an earlier tier already found, and exit 1
has to survive everything that follows it to mean what the paragraph above says.

**Two rig faults it refuses rather than reports.** A counter the kernel multiplexed carries only
part of the run, so the tool scales it and flags `scaled=1`, and the script drops the reading
rather than quote it. And both binaries hashing identically means one side was measured twice --
which yields a ratio of 1.0000 that means nothing -- so equal hashes at different revisions are
a skip, not a result.

**`--syzygy` is what makes this the only REAL-cache view of the tablebase reader.** The bench
list opens no tablebase, so without it the reader never executes and a locality claim about it
can be checked against nothing but `perfdecomp.sh`'s simulated two-level model -- which has a
fixed geometry and knows nothing about this machine's prefetcher. `--fens` names the positions
and defaults to `tests/tbprobe.fens`; the corpus and the positions are one choice, and the two
wrong pairings both run clean while measuring something other than what the report says. The
depth defaults to 14 with `--syzygy`, matching the other two axes.

**Three tables, because the whole-process figure cannot be read as a search figure.** Every
counter here covers the whole process, and the largest single mispredict mover on this tree is
the network reader, which runs once. So each tier prints the whole process, then startup alone
-- a probe that loads the net, builds the magic tables, maps any tablebases and quits without
searching -- then the difference, paired within each round. The split is not cosmetic: on the
bench list the whole process reads 0.86 on branch misses and the search alone reads 1.0044, so
the entire apparent win is the loader and the search is fractionally worse.

**Only the instruction row of that difference is clean.** The startup probe is a separate
process, so it pays its own cold-cache and cold-predictor cost where in the measured run that
same work WARMS both for the search behind it. Retired instructions are the same work either
way; cycles, misses and mispredicts are over-charged to startup, and the search rows for those
read worse than the truth by that much. The script prints this above the table rather than
leaving it to be inferred.

The two extra tables are outside the exit code deliberately. They split the first table rather
than adding a verdict to it, and a tier whose startup probe did not pair still has a
whole-process result that is not in doubt. A round in which any counter came back smaller in
the run than in its own startup probe is dropped from the search table rather than clamped to
zero, because a clamped zero reports noise as a measurement.

## `tests/perfdecomp.sh`

Where the cost is, per component, deterministically.

```sh
./tests/perfdecomp.sh                       # merge-base with master, against HEAD
./tests/perfdecomp.sh --depth 8 --comp clang
./tests/perfdecomp.sh --syzygy tests/syzygy-34man   # reaches the tablebase reader
./tests/perfdecomp.sh --syzygy resources/syzygy-5man --fens tests/tbprobe5.fens
./tests/perfdecomp.sh --pgo                 # the lane that ships
```

**Two flags decide which program is decomposed at all.** Without `--syzygy` the bench list opens
no tablebase, so every tablebase row reports MATCHED NOTHING and the reader a probing search
spends a large share of its time in is absent from the table entirely -- a decomposition of the
engine minus the code the branch's largest result came from. With it, `tablebase probe` is a
component like any other. Without `--pgo` the decomposition is of `-O3`, and the lane a player
runs is decomposed nowhere; splitting a function changes what a profile can attribute, so the two
modes can disagree about where cost sits.

The same three refusals `perfbudget.sh` makes apply: no such directory, no `.rtbw` in it, no
positions in the FEN file, all **skip**. The probing depth defaults to 14, matching
`perfbudget.sh` and `fingerprint.sh`, so a component split, an instruction ratio and a call count
describe one workload rather than three.

**`--fens` names the positions, and the corpus alone does not.** It defaults to
`tests/tbprobe.fens`, which is 4-man. Point `--syzygy` at a 5-man corpus without moving the
positions and the big tables are never read; point 5-man positions at a 3-4-man corpus and no
table is found at all. Both combinations run clean and report a decomposition of something other
than what the caller asked for, which is why the banner names the FEN file and reads the men
count off the corpus rather than asserting it in a sentence that goes false when a bigger corpus
arrives. The cost of a block walk scales with table size, so a figure taken here bounds the same
figure on anything bigger from below.

One thing is inside the measured region on a probing run and is not on the instruction axis: the
`SyzygyPath` line runs as the first bench command, so **mapping the tables is decomposed too** and
lands in the tablebase rows beside the probing. `perfbudget.sh` subtracts that through a startup
probe; a per-component split has nothing to subtract, because the question here is where the work
is rather than what one change moved. Read `tablebase probe` on a probing profile as reader plus
loader.

`perfcounters.sh` says *whether* the machine executed the program differently. This says
*where*. It runs callgrind with the cache and branch simulators on both sides, sums self cost
per symbol, groups the symbols by `tests/perfcomponents.tsv`, and prints instructions, D1 read
misses and conditional mispredicts per component with the winner named.

**Every figure is deterministic and every figure is a model.** Two runs of one binary give the
same counts, so a component difference far below any wall-clock noise floor is real rather than
thermal -- that is what pays for the simulator's order-of-magnitude slowdown, which is also why
`lanecheck.sh` excuses this gate from a lane rather than wiring one. But the cache simulator has
one fixed geometry, is not this machine's cache, and knows nothing about the prefetcher or
out-of-order execution. It ranks locality; it does not predict time. Where the two axes
disagree, `perfcounters.sh` measured the hardware and this measured a model of it. It also
implements no AVX-512, which is why `perfcounters.sh` exists beside it.

`tests/perfdecomp.py` parses the callgrind output file rather than `callgrind_annotate`, which
wraps a long C++ symbol across output lines and cannot be column-parsed. Two properties of that
format are load-bearing: a name-compression id is defined on its **first** appearance and that
may be a `cfn=` line, and the cost line following `calls=` is the callee's **inclusive** cost,
which must be skipped or the whole NNUE evaluation is counted inside `search` and again inside
itself.

**A grouping can break in four ways, and each is reported differently** -- because the cost of
getting this wrong is a plausible-looking table that a reader quotes.

A component whose regex matches nothing **on both sides** is named rather than printed as a
zero, and the run still succeeds: a symmetric absence is an inlining fact, while a zero on one
side reads as a total win forever. Which symbols collapse is a property of the compiler *and*
the tier, so a row empty under clang at one ARCH may be populated at another; compare the
neighbouring row that absorbed the cost rather than the empty one.

A component matching **on one side only** divides a real cost by nothing. That row is marked `X`
and excluded from the verdict, the rest of the table still prints, and the run exits 1. It is
not a refusal because asymmetric inlining is the expected outcome of the refactors this gate
exists to measure -- suppressing every sound row in `tests/perfcomponents.tsv` to report one
artifact trades away the measurement.

A profile in which more than 5% of **either side's** instructions carry no symbol -- a raw
address or an unresolved name-compression id -- cannot be attributed at all, so no table is
printed and the run exits 2. A healthy profile reads 0.0% to 0.1% here, so the limit sits far
above the noise; the failure it catches reads 81.5% against 0.1%, and arises when valgrind
resolves no symbol table for one binary while the other is fine. Every row then matches on the
named side alone and the grouped total becomes arithmetic on a hole. An empty profile refuses
the same way, because a truncated callgrind file otherwise reads as a total win.

Alongside these, the largest *ungrouped* symbols are listed for both sides, and the unnamed
share is printed beside the coverage figure on every run.

**Anchor a component on a symbol that survives both compilers.** clang inlines more
aggressively, so a row naming only the narrow callee empties there while its cost reappears
inside a wider symbol. Name both: `net parse` matches `read_leb_128` and the
`read_parameters` that swallows it, and `NNUE network evaluate` matches `Network::evaluate` and
the `NetworkArchitecture::propagate` that survives at some tiers and folds in at others. Anchor
on `Name::` when widening, or a bare identifier will claim same-named methods from the rows
below it -- the file is first-match-wins.
