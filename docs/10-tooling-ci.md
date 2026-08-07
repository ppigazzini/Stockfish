# Tooling and CI

Every gate in the tree, what it proves, and -- the half that matters more -- what it cannot
see. For the source layout see [00-architecture.md](00-architecture.md).

## Check the exit code, never a piped fragment

```sh
./tests/perfbudget.sh HEAD~1 | tail -1     # WRONG -- reads 0 from tail while the gate is red
./tests/perfbudget.sh HEAD~1; echo $?      # right
```

A gate that SKIPPED for a missing tool has proven **nothing** and must never be reported as a
pass. Both perf gates and the documentation lint distinguish the three outcomes by exit code:
0 clean, 1 findings, 2 could not run.

## The value gates

These answer "does the engine still do the same thing?".

### `tests/signature.sh`

The anchor. `bench` must reproduce a reference node count.

```sh
cd src && ../tests/signature.sh <reference>
```

**Read the reference from the commit record, never from memory or from a page here** -- it
moves with every functional commit, which is why `docslint` refuses a page that quotes it.

It is invoked ~27 times across `tests.yml`, `arm_compilation.yml`, `wasm_compilation.yml` and
`universal_compilation.yml`, after roughly twenty separate architecture builds. That is the
tree's ISA-divergence coverage and it is unusually strong: it is what catches a change that
behaves differently at one vector width.

**It says nothing about cost.** A change can shed no nodes and run measurably slower.

### `tests/perft.sh`

Move generation, by node count at depth, including five Chess960 rows. Needs `expect`.

The counts are **facts about chess**, not a golden. A mismatch is always a movegen bug and
never an update candidate.

It cannot see a key that desyncs and resyncs, because perft counts leaves.

### `tests/reprosearch.sh`

Node counts repeat across `ucinewgame` at varying node limits. Needs `expect`.

### `tests/instrumented.py`

The CLI and interactive suite, driven under valgrind, TSan, UBSan and
`-D_GLIBCXX_ASSERTIONS` by `sanitizers.yml`. `tests/testing.py` is its harness.

It asserts that expected **substrings** appear. It does not pin the full text of a session,
so an `info` line format change, a PV rendered one move short, or a changed ponder move
passes.

## The performance gates

These answer "does it still cost the same?", which no value gate above can.

**There are three of them because there are three questions.** Picking the wrong one produces
a confident wrong verdict, so pick by what the change CLAIMS:

| the change claims | gate | why |
|---|---|---|
| "this is pure code motion" | `tests/textequal.sh` | a codegen-equivalence proof has no noise floor; one run settles it |
| "this costs nothing" (a refactor) | `tests/perfbudget.sh` | deterministic; an instruction increase in a behaviour-preserving change is a real red flag |
| "this is faster" (an optimisation) | `tests/npsab.sh`, and probably fishtest | the instruction axis can report the wrong sign -- see below |

### `tests/perfbudget.sh`

Retired instructions under callgrind, base against head, built and measured in the same run.

```sh
./tests/perfbudget.sh HEAD~1                    # this commit against its parent
./tests/perfbudget.sh origin/master worktree    # uncommitted work
./tests/perfbudget.sh --pgo HEAD~1              # the build that actually ships
```

**Measure both build modes.** `make profile-build` is the shipped recipe, and the two do
not agree on the size of a regression: forcing `Position::adjust_key50` out of line costs
**+0.1000% at -O3 and +0.0477% under PGO**, because the profile lets the compiler make a
better job of the out-of-line call. The PGO binary is also about 4.8% cheaper overall on
this bench. A budget taken only at -O3 gates a binary nobody runs.

Four properties, each deliberate:

- **No golden is stored.** An absolute instruction count is a property of the toolchain and
  the libc as much as of the code, so it cannot be reproduced by a reviewer and it drifts
  upward until it gates nothing. Only the delta is reported, and it is reproducible by
  re-running.
- **Startup is subtracted by measurement**, per binary. It is over 40% of the whole-process
  count at the depth the gate uses, so an unsubtracted ratio describes the network loader as
  much as the engine.
- **A node count that moved makes the comparison VOID**, not expensive. That is a behaviour
  change and `signature.sh` owns it.
- **The tolerance is set from measurement**: the A/A floor across independent builds, against
  a mutation that forces `Position::adjust_key50` out of line. Never raise it to fit a change.

**The limit that matters, and it is not theoretical.** Upstream `ee72cf49f` "Optimize
RankAttacks" is marked *No functional change* and passed a 212,800-game SPRT. It shrinks a
table 4x, trading retired instructions for cache footprint. This gate scores it **+0.16%, a
regression** -- it does not merely miss the win, it reports the wrong sign. An instruction
count cannot see a latency or locality win and is not neutral about one; the same applies to
extra accumulator chains, unrolling for ILP, and software prefetch, which callgrind does not
model at all.

So: **never let this gate alone veto a change whose claim is locality, prefetch or latency
hiding.**

callgrind implements no AVX-512 and dies on the first instruction it does not know, so the
instruction axis stops at avx2/bmi2 -- below the tier a player builds. The script refuses
such an `--arch` rather than producing a number.

### `tests/textequal.sh`

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

### `tests/npsab.sh`

Interleaved paired wall-clock A/B, reporting the median of the paired ratios and its spread.

```sh
./tests/npsab.sh HEAD~1
```

Three rules are built in, each of which has produced a published wrong number somewhere:
alternate which binary runs first, because the second slot in a round runs on a hotter core;
report the spread, not just the median; and read the engine's own bench clock, which starts
after the network load and so contains no startup.

**A spread that straddles 1.000 has established no direction**, and the tool says so rather
than reporting the median as a result. On an ordinary developer box that is the expected
outcome for anything under roughly ten percent -- which is why the instruction axis exists.

## The build and packaging scripts

| Script | Job |
|---|---|
| `scripts/net.sh` | download and verify the network the build expects |
| `scripts/get_native_properties.sh` | detect the host ISA and name the matching `ARCH` |
| `scripts/check_universal.sh` | verify the x86-64 runtime-dispatch binary |
| `scripts/check_universal_arm.sh` | the same for aarch64 |
| `scripts/check_universal_macos.sh` | the same for the macOS universal binary |
| `scripts/check_universal_riscv.sh` | the same for riscv64 |

## `tests/fingerprint.sh`

Per-function **call counts** between two revisions.

```sh
./tests/fingerprint.sh HEAD~1
```

Every other gate here compares values -- a node total, an instruction count, a disassembly.
This one asks whether the engine still gets to its answer by calling what it called, as
often. A change that claims to be a decomposition is exactly where that can move while every
value stays put, which makes this the instrument for splitting a large function.

A call count is inlining-immune **at the callee**: it does not care how the callee was
reached, only that it was. It is **not** immune at the caller -- a function inlined into its
caller disappears from the profile -- so read the one-sided list as inlining differences and
the changed list as the signal.

Scope is the engine's own symbols. The allocator and glibc's thread-cancellation counters
(`_int_malloc`, `sbrk`, `munmap`, the pthread cancel pair) move between two runs of one
binary, so they are reported apart from the verdict rather than folded into it. Functions
callgrind can only name by address are excluded: two builds place them differently, so they
have no comparable identity.

Deterministic: three A/A runs report IDENTICAL across 206 engine symbols. Forcing
`Position::adjust_key50` out of line makes it appear as a called symbol with 105296 calls.

## `tests/negative_control.sh`

Breaks the engine on purpose and requires each gate to notice.

```sh
./tests/negative_control.sh            # every row
./tests/negative_control.sh docslint   # one row
```

A gate's power to detect a defect is an assumption until something breaks the code and the
gate is watched going red. A gate that has quietly stopped being able to fail is invisible,
because it reports success.

Every mutation perturbs a **value** rather than removing a bound: a mutant that hands the
search an evaluation with no ceiling produces an experiment that never terminates, and a
timeout is a rig fault rather than a detection.

Three ways the rig itself can be wrong, and all three refuse rather than return a verdict: an
anchor string that has rotted (the tree is never mutated, the gate greens, and that reads as
a gate failing to detect), a mutation that does not compile, and a selector naming no row.
The tree is restored from a trap, and the run ends by executing a gate green rather than by
asserting the sources were put back.

Rows that cannot run report SKIPPED and are counted separately. A skipped row proves nothing.

## `tests/lanecheck.sh`

Every gate must be dispatched by a workflow, or carry an excuse saying what runs it.

A check nobody runs is a claim about the tree rather than a check on it: it never reports, so
it never goes red, so nobody notices it stopped working -- and it still looks like coverage in
a directory listing.

Dispatch is counted from **workflows only**. A gate invoked solely by another local gate is
not dispatched: if that gate runs nowhere the chain bottoms out at nothing and the hole is
laundered into a pass.

The excuse list is the hole, so it expires in its own direction -- an excused script that IS
dispatched is reported as a stale excuse, and an excuse naming a script the tree no longer has
fails too. A script named only in a comment does not count as dispatched, and the name match
requires a separator on both sides so `net.sh` cannot be satisfied by `subnet.shx`.

## `tests/docslint.sh`

Five mechanical checks over this documentation set:

1. every markdown link resolves;
2. every `src/`, `tests/`, `scripts/` or `.github/` path named in prose exists;
3. no page quotes a bench signature -- it moves every functional commit and nobody greps
   documentation when it does;
4. every script in `tests/` and `scripts/` is named by some page, because a gate nobody can
   discover is a gate nobody runs;
5. no **tracked** file references the untracked working area, `.gitignore` excepted.

Check 5 sweeps every tracked file rather than every page, and that scope is load-bearing: a
source comment or a workflow file dangles for a reader exactly as a doc line does. Check 2
exempts a path that `.gitignore` names, since a page legitimately describes the tool that
writes an ignored artifact -- and that exemption is exactly why check 5 must exist separately,
because an ignored directory lands in it and reports clean.

**It settles the mechanical half of documentation rot and no more.** It cannot tell you a
sentence has become false. Three classes it will pass: a real symbol attributed to the wrong
file, a list with the wrong count or order, and a behaviour described as absent from a build
that has it. That half is yours.

## CI

| Workflow | Gates |
|---|---|
| `stockfish.yml` | the umbrella: calls the rest |
| `tests.yml` | the compile matrix -- 13 platform/compiler configurations, ~20 architecture builds, each benching the signature |
| `sanitizers.yml` | TSan, UBSan, valgrind, valgrind-thread, uninstrumented, glibcxx assertions |
| `matetrack.yml` | mate-finding over a position suite |
| `games.yml` | 8 self-play games on a debug build; fails on an assertion or a disconnect |
| `avx2_compilers.yml` | a compiler sweep at one architecture |
| `arm_compilation.yml`, `universal_compilation.yml`, `wasm_compilation.yml` | the remaining targets |
| `iwyu.yml`, `clang-format.yml`, `codeql.yml` | include hygiene, formatting, static analysis |
| `upload_binaries.yml` | release artifacts |
| `perfbudget.yml` | the instruction budget, base against head, at two tiers |

`tests/perft.sh` and `tests/reprosearch.sh` run at exactly one step of `tests.yml`, gated on
the 64-bit configurations, after an avx2 build.

## What no gate here covers

Worth stating, because a long list of green checks reads as coverage:

- **No fuzzing of any kind.** The UCI parser, the Syzygy table reader and the shared-memory
  layer all consume input the process did not write, and none of them has a harness.
- **No byte-golden of engine output.** `instrumented.py` checks substrings.
- **No negative control.** No gate here except `docslint` has been demonstrated to fail. A
  gate's power to detect a defect is an assumption until something breaks the engine on
  purpose and the gate is watched going red -- and a gate that has quietly stopped being able
  to fail is invisible, because it reports success.
- **The bench is a fixed position list.** A divergence off those positions is invisible to the
  anchor.
