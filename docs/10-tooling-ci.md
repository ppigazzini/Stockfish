# Tooling and CI

`tests/`, `scripts/`, `.github/workflows/`.

Every gate in the tree, what it proves, and -- the half that matters more -- what it cannot
see. For the source layout see [00-architecture.md](00-architecture.md).

Audience: anyone adding or running a gate.

## Check the exit code, never a piped fragment

```sh
./tests/perfbudget.sh HEAD~1 | tail -1     # WRONG -- reads 0 from tail while the gate is red
./tests/perfbudget.sh HEAD~1; echo $?      # right
```

A gate that SKIPPED for a missing tool has proven **nothing** and must never be reported as a
pass. Both perf gates and the documentation lint distinguish the three outcomes by exit code:
0 clean, 1 findings, 2 could not run.

## Which gate settles which claim

Pick by what the change CLAIMS, not by what is cheap to run. Every row's third column is the
reason the row above it is not a substitute: a gate quoted without its blind spot is a gate
being over-trusted.

| the claim | the gate | what it cannot see |
|---|---|---|
| "it searches the same tree" | `tests/signature.sh` | cost; and anything off the bench position list |
| "move generation is right" | `tests/perft.sh` | a key that desyncs and resyncs -- perft counts leaves |
| "`ucinewgame` resets what a search reads" | `tests/reprosearch.sh` | whether those node counts are the right ones; a second thread |
| "it still SAYS the same thing" | `tests/golden.sh` | a command no `.uci` case sends; every field the filter drops |
| "the CLI still works" | `tests/instrumented.py` | the full text of a session -- it asserts substrings |
| "it still answers mid-search" | `tests/liveness.sh` | the move, the score, the node count. It is blind to everything a hang is not |
| "the unhosted search runs on the same parameters" | `tests/optiondefaults.sh` | an option the engine has no field for |
| "the call graph is unchanged" | `tests/fingerprint.sh` ([11-performance.md](11-performance.md)) | a callee inlined INTO its caller; and any code the workload never reaches |
| "no host dependency leaked into `engine/`" | `tests/depcheck.sh`, then `tests/linkcheck.sh`, then `tests/enginelink.sh` | each is blind where the next sees: includes miss a template edge, symbols miss an inline header body, the link misses what nothing calls |
| "every source is built" | `tests/buildcoverage.sh` | a header no unit includes; whether the object reaches the binary at a given `ARCH` |
| "the include set is minimal" | `tests/iwyu.sh` | a use behind another host's `#ifdef`; and in shim mode, any absolute verdict |
| "a known-bad table is still refused" | `tests/malformed.sh` | a field nobody has broken yet |
| "the weight reader matches the FORMAT" | `tests/leb128.sh` | the engine -- it builds one translation unit and no binary |
| "the PV extension respects its array" | `tests/tbpv.py` | anything but the one seeded sequence over the one corpus |
| "nothing NEW breaks it" | `tests/fuzz.py`, `tests/fuzzsearch.sh` | a correctly-read corrupt table; and the run's own budget bounds the claim |
| "the engine plays" | `tests/match.sh` | strength; and any defect both binaries share |
| "it costs the same" / "it is faster" / "it scales" | the six axes in [11-performance.md](11-performance.md) | each other -- see that page's selector |
| "this gate can still fail" | `tests/negative_control.sh` | a gate with no row, which is simply absent from it |
| "every gate runs somewhere" | `tests/lanecheck.sh` | whether the gate asserts anything once it runs |
| "the docs are not rotten" | `tests/docslint.sh` | whether a sentence is false |
| "the citations resolve" | `tests/devcite.sh` | whether the SHA names the commit the sentence means |
| "the actions are pinned" | `tests/actionpins.sh` | whether a pin is the latest release -- reported by `--latest`, never gated |
| "the commit record is readable by a lane" | `tests/anchor.sh` | bodies a shallow clone did not fetch |
| "the gate scripts are sound shell" | `tests/shellcheck.sh` | whether a gate checks the thing it claims to |

Most of these can SKIP -- for a missing tool, a missing corpus, a missing PMU -- and a skip
answers nothing. Read the exit code, and for `negative_control.sh` read the skipped count
besides, because a skipped row leaves its status at 0.

## `tests/signature.sh`

The anchor. `bench` must reproduce a reference node count.

```sh
cd src && ../tests/signature.sh <reference>
```

**Read the reference from the commit record, never from memory or from a page here** -- it
moves with every functional commit, which is why `docslint` refuses a page that quotes it.

`tests.yml`, `arm_compilation.yml`, `wasm_compilation.yml`, `universal_compilation.yml` and
`platformbattery.yml` each invoke it after every architecture they build:

```sh
grep -c signature.sh .github/workflows/*.yml
```

That is the tree's ISA-divergence coverage, and it is what catches a change that behaves
differently at one vector width.

**It says nothing about cost.** A change can shed no nodes and run measurably slower.

## `tests/match.sh`

Play this branch against upstream and report whether the engine **played**.

```sh
./tests/match.sh                       # merge-base with master, against HEAD
./tests/match.sh --games 200 --tc 10+0.1
./tests/match.sh --syzygy tests/syzygy-34man   # both engines probe
```

**`--syzygy` is the only way the tablebase reader is exercised under a clock.** The bench list
opens no table, so every other gate reaches that code either not at all or under callgrind, where
nothing has a deadline. Both engines get the same `SyzygyPath`, because a match that gave one side
tables would measure the tables. The path is made **absolute** before it is passed: fastchess runs
the engines from its own working directory, so a relative one resolves to nothing there and the
match reads as clean while probing no table. A missing directory and a directory with no `.rtbw`
both **skip**.

It builds both revisions with `profile-build`, fetches and builds fastchess at the revision
`games.yml` already pins, and plays a match at a fixed time control. Every other gate here
compares the engine against a recorded answer; this one is the only thing in the tree that puts
it in front of an opponent.

**It does not measure strength, and it is not a substitute for fishtest.** At the sizes it
runs, the error bar fastchess prints beside the Elo is wider than any refactor could move --
read the two together or quote neither. What it does establish is liveness: no crash, no
disconnect, no illegal move, no forfeit on time.

**It judges no move.** A game that completes is a pass however badly it was played, and a
defect both binaries share is invisible to it exactly as it is to every other differential
gate here.

**A timeout is a rig fault, not a result.** A forfeit on time is a game the loser did not play,
and on a busy box both sides forfeit at random, so a non-zero timeout count is reported apart
from the score rather than folded into it. A background build invalidates a match exactly as it
invalidates `npsab.sh`.

**No workflow runs it**, and `tests/lanecheck.sh` carries the excuse for that: a hosted runner
is not idle, so a match run there forfeits on time and scores the box rather than the engine.
It runs when someone remembers it.

## The build and packaging scripts

| Script | Job |
|---|---|
| `scripts/net.sh` | download and verify the network the build expects |
| `scripts/get_native_properties.sh` | detect the host ISA and name the matching `ARCH` |
| `scripts/check_universal.sh` | verify the x86-64 runtime-dispatch binary |
| `scripts/check_universal_arm.sh` | the same for aarch64 |
| `scripts/check_universal_macos.sh` | the same for the macOS universal binary |
| `scripts/check_universal_riscv.sh` | the same for riscv64 |

## `tests/actionpins.sh`

Holds every third-party GitHub Action to a commit, a stated version, and one version.

```sh
./tests/actionpins.sh            # the three gated properties
./tests/actionpins.sh --latest   # and report which pins are behind a release
```

Three properties, and only the last needs the network:

- **pinned to a SHA**, not a tag or a branch. A tag is mutable by whoever owns the action, so
  `@v4` means "run whatever they publish next" on a runner holding this repository's token;
- **carrying its version** in a trailing comment. A bare 40-hex string is unreadable, so nobody
  can see a pin has gone stale;
- **one action, one version** across the tree. This is the one that needs no network and no
  release feed, and it is the one that was missing: `actions/cache` sat at v4.2.0 in one workflow
  and v6.1.0 in two others, and the tree said nothing. It surfaced as a Node 20 deprecation
  warning on a runner -- a message from GitHub about their schedule rather than a check of ours.

Dispatched by `docs.yml`, which caches the resolved pins so the network half does not refetch
every run.

**Being the latest release is deliberately not gated.** It is true until the action's next
release and false afterwards through no change here, so gating it reddens the lane on someone
else's schedule. `--latest` reports it for a human to act on. Nothing in this repository keeps
pins current automatically; there is no dependabot configuration, and adding one is a decision
about repository-wide automation rather than about a gate.

The network half -- that a pin's SHA really is the release its comment claims -- skips loudly
without an authenticated `gh`, and says so rather than folding into the pass.

## `tests/negative_control.sh`

Breaks the engine on purpose and requires each gate to notice.

```sh
./tests/negative_control.sh            # every row
./tests/negative_control.sh docslint   # one row
./tests/negative_control.sh static     # the rows that need no build
```

**The `static` group is what a per-push lane can afford**, and it is the only group any
workflow runs -- `refish.yml`'s `NegativeControl` job. The full set builds the engine once per
row and is hours; a static row reads the tree or compiles a syntax-only probe, and the group
finishes in minutes. Membership is a tag on the row's own declaration -- `row docslint static`
-- rather than a list kept elsewhere, because a list kept elsewhere goes stale the first time a
row is added, and a row that quietly leaves the group is a row the lane stops running while
still reporting a pass. A `static` selector that names no row refuses, the same as a rotted
anchor.

```sh
grep -c '^row ' tests/negative_control.sh          # every row
grep -c '^row .* static' tests/negative_control.sh # the group the lane runs
```

A gate's power to detect a defect is an assumption until something breaks the code and the
gate is watched going red. A gate that has quietly stopped being able to fail is invisible,
because it reports success.

Every mutation perturbs a **value** rather than removing a bound: a mutant that hands the
search an evaluation with no ceiling produces an experiment that never terminates, and a
timeout is a rig fault rather than a detection.

**One class of row mutates nothing, and it is where a new type's row goes.** A type introduced
so that a wrong spelling stops compiling has no gate to redden -- the compiler is the gate. Such
a row writes a probe translation unit, compiles it against the real headers, and asserts the
illegal form is REFUSED:

```sh
printf '#include "history.h"\nusing namespace Stockfish;\n%s\n' \
    'HistoryBankIndex f(usize n) { return n; }' > probe.cpp
( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only probe.cpp )   # must FAIL
```

`-Iengine` as well as `-I.` is load-bearing: the probes include engine headers by bare name and
`src/` is zone directories, so `-I.` alone fails to find them -- which makes the illegal form
AND the legal one fail, and scores a broken rig as a detection. So each of these rows asserts
both halves, and the second is what catches it: every legal spelling must still compile. A row
that only checked the refusal would be satisfied by a header that stopped compiling at all.

These rows are `static` by construction -- they build no engine -- and they restore nothing,
because they never touched the tree.

Three ways the rig itself can be wrong, and all three refuse rather than return a verdict: an
anchor string that has rotted (the tree is never mutated, the gate greens, and that reads as
a gate failing to detect), a mutation that does not compile, and a selector naming no row.
The tree is restored from a trap, and the run ends by executing a gate green rather than by
asserting the sources were put back.

Rows that cannot run report SKIPPED and are counted separately. **A skipped row proves nothing,
and it leaves the script's exit status at 0** -- so a lane that reads only the status reports a
pass for a run that checked nothing. The `Refish` workflow reads the skipped count as well as
the status, and treats a count it cannot parse as a failure rather than as zero.

**It reports its own coverage, script by script**, because the failure this script exists to
prevent applies to itself: a gate with no row is simply absent from it, and absence is quiet.
`lanecheck.sh` asks whether a gate is dispatched and `docslint.sh` asks whether it is
documented; **neither asks whether it can fail**, so a merge gate can be fully wired, fully
described and inert, and nothing in the tree says so.

Every script in `tests/` needs a row or an excuse -- a `NO ROW` line fails the run -- and the
excuse list expires in both directions as `lanecheck.sh`'s does: an excused script that has a
row is a stale excuse, and an excuse naming a script the tree no longer carries fails too. A
row counts for its script when the row name is the stem or begins with it, so `depcheck-stale`
covers `depcheck.sh`; that is how one script takes several rows without several excuses.

What is excused, each with the reason it cannot fail on its own: a report that
exits 0 for any ratio (`npsab.sh`, `npsthreads.sh`, `perfcounters.sh`, `perfdecomp.sh`), the
aggregation half another gate invokes rather than runs, the zone table, `testing.py`, which
`instrumented.py`'s row already covers, `match.sh`, whose planted defect would be scored by the
same clock the box perturbs -- and this script, which cannot be its own negative control.

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
requires a separator on both sides -- one before, so `net.sh` cannot be satisfied by
`subnet.sh`, and a non-name character after, so `net.shx` cannot satisfy it either.

Dispatched by `docs.yml`, and by the `lane-coverage` pre-commit hook on any change under
`tests/`, `scripts/` or `.github/workflows/`.

## `tests/shellcheck.sh`

Lints the shell the gates are written in.

```sh
./tests/shellcheck.sh                  # 0 clean, 1 findings, 2 skipped
./tests/shellcheck.sh --severity error # the only option it takes
```

**The tool is PINNED, and the pin is asserted rather than hoped for.** A lint's finding set is
version-dependent -- 0.9.0 reports a trap-invoked cleanup as SC2317 and 0.11.0 reports the same
line as SC2329 -- so a suppression written against one version is not a suppression under the
other. `tests/shellcheck.version` is the single owner of the number; `docs.yml` reads it,
downloads that release into `resources/shellcheck/`, and the gate asserts the version it found
equals it. **A different version is a SKIP, not a verdict**, and so is no shellcheck at all.
`resources/` is searched before `PATH`, because a distro shellcheck is whatever the image
happened to ship.

**Every claim this branch makes is decided by hand-written bash**, and until this gate landed no
tool had read a line of it:

```sh
cat tests/*.sh scripts/*.sh | wc -l
```

The pre-commit config lints, formats and type-checks the Python; the language the gates are
actually written in had nothing.

**Scope is by authorship, not by directory, and the rule maintains itself.** `tests/` and
`scripts/` hold upstream's scripts as well as this branch's, and fixing a style finding in a
file the branch has never touched buys nothing and costs a rebase conflict forever. But
"upstream file" is the wrong line: the branch has already modified four of the five upstream
scripts that had findings, so the conflict is already being paid there. So a script is in scope
unless it is **byte-identical to the fork point** -- and a script absent from the fork point is
in scope by definition, because the branch created it. The excuse evaporates the moment the
branch touches the file, nothing is listed by name, and nothing has to be maintained.

Findings in the excused set are **reported and not gated**. A real defect there belongs in the
upstream defect register with a reproducer, not in a style sweep.

**No baseline**, deliberately. Every other debt register here expires in both directions --
`depcheck`'s, `linkcheck`'s, `lanecheck`'s excuses. A shellcheck baseline could not, in the one
place where the findings are cheapest to fix. The in-scope set is held at zero and a suppression
is a comment at the site:

```sh
# shellcheck disable=SC2086
# $objs is an object LIST and must split into separate arguments.
```

The directive takes no trailing text on its own line, and it must sit before the whole command
rather than before a continuation line. Two file-scoped directives exist, both where the
property is genuinely file-wide: every SC2016 in `negative_control.sh` is a mutation anchor
quoted verbatim, and every one in `devcite.sh` is a regex matching literal backticks.

It judges scope against the fork point, so `docs.yml` checks out full history for it: with no
merge-base it puts **every** script in scope, which is the strict direction and says which case
it is in. The pre-commit hook maps its exit 2 back to 0 and prints SKIP, so a commit on a box
with no pinned shellcheck passes the hook having linted nothing; `docs.yml` is the lane that
cannot do that, because it installs the pin first.

**What it cannot see**: whether a gate checks the thing it claims to. `negative_control.sh` is
what proves a gate can fail, and a script can be shellcheck-clean and assert nothing.

## Fuzzing

Every gate above compares the engine against a **known-good answer**. That shape can only find
a defect in behaviour someone already described. The inputs the engine did not produce -- a
command from a GUI, a Syzygy table off a mirror, a network file named by `EvalFile`, a second
engine process on the same machine -- have no known-good answer to compare against, so nothing
above covers them.

```sh
./tests/tbfetch.sh                                  # the tb corpus, once
./tests/fuzz.py --seconds 600 --harness tb          # one harness
./tests/fuzz.py --seed 4242 --harness tb            # reproduce a finding
```

`tests/fuzz.py` runs four harnesses, which fail differently and do not substitute for one
another:

| harness | input | what it reaches |
|---|---|---|
| `uci` | mutated command text | the parser, and essentially never the search behind it -- a mutated line is rejected at the first token |
| `tb` | mutated Syzygy bytes | the decoder, the highest-consequence reader in the tree |
| `net` | a mutated file through `EvalFile` | the loader, whose failure mode is a *replacement* net rather than a missing one |
| `shm` | concurrent engine processes, some killed mid-startup | the cross-process path, whose failures need a second process rather than a mutated byte |

`shm` is the odd one: its input is not a file. `shm_unix.h` hands one process's network to
another over a Unix socket and an mmapped memfd, so its failure modes are two creators racing
and a peer dying mid-transfer. A client disappearing mid-write kills the server with `SIGPIPE`
unless the signal is handled, which is the shape of every failure in this layer. The property
is **survivorship**: a process that dies because a *peer* died is the defect; a process killed
on purpose is the stimulus.

The `tb` harness matters most because its bad outcome is not a crash. An index computed one off
returns a **confident wrong verdict** the search believes, so "did not crash" is not the
property that matters there -- and so no harness stops at liveness.

Each takes a **reference from the clean input first**, and compares against it:

| harness | the property, beyond surviving |
|---|---|
| `tb` | after a corrupt table has been probed, a probe of a table the mutation did NOT touch must return exactly what the clean corpus returned. One table's corruption reaching another's verdict is the search believing a reader that lost track of which bytes belonged to what. |
| `net` | a corrupt network must be refused, not loaded. Reporting an evaluation that differs from the shipped net's, with no error, is the engine passing off a corrupt network as an opinion. |

**`tb` probes twice per iteration, and only the second probe carries a claim.** A table is
mapped at first probe, so the only way to put the mutated bytes through the parser is to probe
the material that table holds -- and once that has happened, its answer is comparable to
nothing. The Syzygy format has no integrity field, the mutated bytes *are* the compressed
values for that material, and a reader that decodes them perfectly returns a different move
than the clean table did.

That is not a theory. The harness asserted the opposite for its whole life and never showed it,
because the crashes below fired first; with those closed, it reported a "wrong verdict" about
once every twenty iterations, every one of them a correct read of bytes the harness had itself
changed. **A property no implementation can satisfy is not a check, it is a scheduled false
alarm** -- the same objection this page makes to the `tb` lane it dropped.

So the first probe is the stimulus, judged on liveness alone, and the second reads an untouched
table and is judged on its answer. What that leaves uncovered is worth stating rather than
asserting away: **nothing in this tree can tell a correctly-read corrupt table from an
incorrectly-read one**, and with no checksum in the format nothing can. What a corrupt table
must not do is crash, hang, or contaminate a neighbour, and those three are what is checked.

The reference is what makes these checkable at all: without it there is no way to tell a
refused input from an accepted one that lies, because both leave the engine alive and both
print a number. It also means a harness that cannot obtain its reference stops with a rig
fault rather than reporting the whole run clean.

The `net` property passes because the loader validates: corrupt a net's weights and the engine
answers `ERROR: Network evaluation parameters compatible with the engine must be available` and
does not load it. That is the engine being correct, not the check being weak, and the check is
what tells the two apart.

**The seed prints first, and every finding prints the seed that produced it.** A fuzz run whose
failure cannot be replayed is an anecdote.

## Local hooks

```sh
uv sync && pre-commit install     # once
pre-commit run --all-files        # everything, now
```

`.pre-commit-config.yaml` runs file hygiene, `ruff` (lint and format), `ty`, `make format`, and
four of the static gates above -- `docslint.sh`, `lanecheck.sh`, `shellcheck.sh` and
`depcheck.sh`, each on the file globs its subject lives under. **CI does not run these.** The
workflows stay the authority; this catches the same classes before the commit exists, which is
the only difference that matters when a gate takes seconds.

**Two hooks turn a skip into a pass, and both do it deliberately.** `pre-commit` reads any
non-zero status as a failure, so `shell-lint` maps `shellcheck.sh`'s exit 2 back to 0 and prints
SKIP; a commit on a box with no pinned shellcheck therefore passes a hook that linted nothing.
`docs.yml` is what cannot be fooled that way, because it installs the pin first.

`pyproject.toml` holds the `ruff` and `ty` configuration and declares the dependency the gates
need. The lint set is curated rather than `ALL`: these are operator tools, so `print` IS their
output and `subprocess` IS their job, and a rule family the tools violate by design would force
`--exit-zero` -- an advisory hook is a laundered gate.

Two scopes are narrowed on purpose, and both are named rather than left to be discovered.
`ty` skips `tests/instrumented.py` and `tests/testing.py`: its diagnostics there are unannotated
upstream code reached without narrowing, and silencing them means adding asserts to code this
fork does not own. `E501` is ignored in those same two files, where every overlong line is a
single string literal -- a search-output regex, a FEN with its move list, ANSI-coloured
f-strings. Editing a regex to satisfy a line limit is how a gate quietly stops matching.

**The `clang-format` hook runs only if `clang-format-20` is present**, the version CI pins. A
different major reformats the whole tree to its own house style, rewriting files nobody touched.
`make format` refuses outright without the pinned major, so the hook's guard chooses what
happens instead of that refusal: a loud SKIP rather than a failed commit. It weakens nothing --
CI's own `clang-format` step is `continue-on-error` and comments rather than blocks.

## CI

**Column two names every script under `tests/` that the workflow invokes, and `docslint.sh`
holds it to the YAML.** A row that falls a gate behind is the failure this page describes two
sections down -- a list that drifts by one entry reads exactly like one that has not -- so it is
welded rather than proofread. A workflow that runs no gate names none, and that is the honest
entry for the six that build or publish rather than check.

| Workflow | Gates |
|---|---|
| `stockfish.yml` | the umbrella: calls the rest, and runs nothing itself |
| `refish.yml` | this branch's umbrella, calling the same reusable lanes; `negative_control.sh` is its alone |
| `tests.yml` | the compile matrix: every platform/compiler configuration in its `config:` list, several architectures each, running `signature.sh`, `perft.sh` and `reprosearch.sh` |
| `sanitizers.yml` | four jobs: `instrumented.py` under TSan, UBSan, valgrind, valgrind-thread, uninstrumented and glibcxx assertions; then `malformed.sh`, `leb128.sh` and `tbpv.py`, one job each, the last over the corpus `tbfetch.sh` writes |
| `matetrack.yml` | mate-finding over a position suite, then `instrumented.py --none` |
| `games.yml` | a short self-play match on a debug build; fails on an assertion or a disconnect |
| `avx2_compilers.yml` | a compiler sweep at one architecture |
| `arm_compilation.yml`, `universal_compilation.yml`, `wasm_compilation.yml` | the remaining targets, each benching `signature.sh` |
| `iwyu.yml` | `iwyu.sh` in native mode, which is the only mode with an absolute verdict |
| `clang-format.yml`, `codeql.yml` | formatting and static analysis; neither runs a gate under `tests/` |
| `upload_binaries.yml` | release artifacts |
| `perfbudget.yml` | `perfbudget.sh` at two tiers, base against head, then `textequal.sh` as `continue-on-error` -- the codegen comparison informs, it does not block |
| `golden.yml` | `optiondefaults.sh`, then `golden.sh` against the corpus `tbfetch.sh --men 4` fetches, then `liveness.sh` |
| `docs.yml` | `docslint.sh`, `lanecheck.sh`, `shellcheck.sh`, `buildcoverage.sh`, `depcheck.sh`, `actionpins.sh`, `anchor.sh`, then `linkcheck.sh` and `enginelink.sh` |
| `fuzz.yml` | nightly: all four `fuzz.py` harnesses -- `uci`, `tb`, `net`, `shm` -- one job each, then `fuzzsearch.sh`, over the corpus `tbfetch.sh` writes |
| `platformbattery.yml` | the functional battery on Linux arm64 and Windows arm64: `signature.sh` on both, `uci_driver.py`, `instrumented.py` and `malformed.sh` on Linux only, over the corpus `tbfetch.sh` writes |

**`arm_compilation.yml` and `universal_compilation.yml` take a `publish` input, and `refish.yml`
passes false.** Both end by uploading a (pre)-release artifact, and this branch calls no release
job and downloads no artifact, so each upload was produced by a lane and consumed by nothing.
False also drops the strip and clean steps, which exist to package that artifact. What either
lane proves is unchanged: the target still compiles and `signature.sh` still runs against the
anchor. The default is true, so `stockfish.yml` passes nothing and is unaffected.

**`universal_compilation.yml` is the only lane that compiles `src/universal/`**, which is the
runtime dispatch `06-platform.md` owns -- `grep -rlE 'ARCH=[a-z0-9-]*universal' .github/workflows`
returns it alone -- and the only one running `scripts/check_universal.sh`, which asks whether the
binary selects the right architecture at run time rather than whether it built. Dropping it to
save CI would leave the dispatch layer with no coverage of either kind.

`docs.yml` builds, despite the name: `linkcheck.sh` and `enginelink.sh` both compile the tree.
The zone checks live there rather than in a lane of their own so a reader looking for one finds
the others beside it.

`tests/perft.sh` and `tests/reprosearch.sh` run at exactly one step of `tests.yml`, gated on
the 64-bit configurations, after an avx2 build.

**That step is x86-64 Linux and nothing else, which is what `platformbattery.yml` is for.** The
compile matrix runs `signature.sh` on Windows arm64, Windows Mingw-w64, macOS, Android, ppc64
and loongarch64, so the bench anchor already travels; movegen, search reproducibility, the UCI
surface and the malformed-table refusal did not. The battery carries the movegen and the
reproducibility check through `tests/uci_driver.py`, which speaks UCI directly, needs no
`expect`, and is plain subprocess pipes -- which is what makes it portable at all.

**Two checks stop at the Linux target and the reasons differ.** `malformed.sh` builds under
AddressSanitizer and UBSan and Mingw-w64 ships no runtime for either. `instrumented.py` is
upstream's harness and no lane has ever run it off Linux, so putting it on a new target in the
same commit that adds the target would leave two things to explain if it went red. Both are
stated in the lane rather than left as silent gaps.

It runs on two arm64 targets rather than a wide matrix because it is answering one question --
does this engine SEARCH correctly off x86-64 -- and because the three subsystems this branch
changed most, `shm`, `numa` and `thread_native`, are the three that diverge most across
platforms. **It asserts behaviour and never performance**: a performance figure is per-host by
construction, so a second host's numbers would not pool with the first's.

### Reachability

A gate runs only if something can start the workflow that names it. **Two** entry points fan
out: `stockfish.yml` for the branches upstream builds and `refish.yml` for this one.
`clang-format.yml` and `codeql.yml` trigger themselves, and `fuzz.yml` hangs off a cron. Every
other workflow declares `workflow_call`, so it runs when an umbrella calls it and never
otherwise -- `docs.yml`, `golden.yml`, `perfbudget.yml` and `platformbattery.yml` add a
`workflow_dispatch` on top, which `lanecheck.sh` deliberately does not count, because a lane
only a human can click gates no change.

The two umbrellas call the same reusable lanes, and the difference between them is three jobs:
`refish.yml` adds `platformbattery.yml` and the static half of `negative_control.sh`, and omits
the release plumbing -- `Prerelease` and the two `upload_binaries.yml` jobs -- which publishes
artifacts rather than checking anything and self-excludes on a fork anyway.

```mermaid
flowchart LR
    P(["push / pull_request"]) --> SF["stockfish.yml"]
    R(["push to refish"]) --> RF["refish.yml"]
    P --> CF["clang-format.yml"]
    P --> CQ["codeql.yml"]
    SF --> T["tests.yml"]
    SF --> SAN["sanitizers.yml"]
    SF --> PB["perfbudget.yml"]
    SF --> D["docs.yml"]
    SF --> GO["golden.yml"]
    SF --> OTH["iwyu, games, matetrack, avx2_compilers,<br/>arm, wasm, universal"]
    SF --> UB["upload_binaries.yml<br/>(official repo only)"]
    RF --> T
    RF --> SAN
    RF --> PB
    RF --> D
    RF --> GO
    RF --> OTH
    RF --> PBAT["platformbattery.yml"]
    RF --> NC["negative_control.sh<br/>(static rows)"]
    PBAT --> G8["signature.sh<br/>uci_driver.py perft<br/>uci_driver.py repro<br/>instrumented.py<br/>malformed.sh (Linux only)"]
    N(["nightly cron"]) --> FZ["fuzz.yml"]
    T --> G1["signature.sh<br/>perft.sh<br/>reprosearch.sh"]
    D --> G5["docslint.sh<br/>lanecheck.sh<br/>shellcheck.sh<br/>buildcoverage.sh<br/>depcheck.sh<br/>actionpins.sh<br/>anchor.sh<br/>linkcheck.sh<br/>enginelink.sh"]
    GO --> G6["optiondefaults.sh<br/>golden.sh<br/>liveness.sh"]
    FZ --> G7["fuzz.py (uci, tb, net, shm)<br/>fuzzsearch.sh"]
    SAN --> G3["instrumented.py<br/>malformed.sh<br/>leb128.sh<br/>tbpv.py"]
    PB --> G4["perfbudget.sh<br/>textequal.sh"]
    L(["no trigger -- by hand only"]) --> G2["negative_control.sh<br/>(the rows that build)<br/>fingerprint.sh<br/>npsab.sh<br/>npsthreads.sh<br/>match.sh<br/>perfcounters.sh<br/>perfdecomp.sh<br/>devcite.sh"]
    style G2 stroke-dasharray: 5 5
    style L stroke-dasharray: 5 5
```

The dashed box is the point: those gates are reached by no workflow, so they run when a
developer remembers them or not at all. `tests/lanecheck.sh` holds each to carrying an excuse
that names what runs it instead, and the excuse list in that script is the current one -- one
array of name and reason, because two index-parallel arrays print a reason belonging to a
different script the first time a name is removed without its reason, and exit 0 while doing it.

**`refish.yml` exists so that this branch runs the gates it built.** It is a separate entry
point rather than a branch name added to `stockfish.yml`: `refish` is a fork-private branch, and
naming it in upstream's orchestrator is neither upstreamable nor removable once merged. It calls
the same reusable lanes, so the two umbrellas cannot drift, and it adds the one gate
`stockfish.yml` has no reason to carry -- the static half of the negative control.

Five of the seven by-hand gates have a reason a lane cannot fix. `npsab.sh`, `match.sh` and
`npsthreads.sh` need an idle box -- `npsthreads.sh` needs real cores besides, and a hosted
runner has two shared vCPUs, so a scaling curve taken there describes the hypervisor.
`perfcounters.sh` needs a PMU, which a virtualised runner does not expose. `devcite.sh` reads the
untracked working area, so a clone gives it an empty corpus and it would pass by having nothing
to read -- the worst of the five, because that one looks green.

`fingerprint.sh` and `perfdecomp.sh` are callgrind and deterministic, so their excuse is cost
rather than capability, and the rows of `negative_control.sh` that build the engine are the
same. **Say which of the two it is when reading that list**, because "cannot run here" and
"nobody wired it" look identical in a directory listing.

`fuzz.yml` hangs off the cron rather than the umbrella because it is not a merge gate. A
workflow with only a `workflow_call` trigger and no caller is in the same position -- it cannot
start, so nothing it names is in a lane, which is what `lanecheck` checks before it looks at any
script.
