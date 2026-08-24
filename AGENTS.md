# AGENTS.md

Stockfish is a UCI chess engine. Chess strength is decided by
[fishtest](https://tests.stockfishchess.org), not by opinion: a functional change lands only
with an SPRT result behind it, and the commit body carries the new `Bench:`.

**Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing code**, and the
[wiki](https://github.com/official-stockfish/Stockfish/wiki) for build and usage. This file is
only what an agent gets wrong before it has read either.

This branch also carries a refactoring programme. Its analysis and roadmap are kept out of
the distribution; what ships is [docs/](docs/README.md) and the gates. The rule that
programme runs under is absolute:

> **Every refactor must keep or improve performance. Even a very small regression is
> forbidden.**

## Setup

```sh
cd src
make -j build ARCH=x86-64-avx2       # the working build
make -j profile-build ARCH=...       # PGO+LTO -- what actually ships, far slower
make help                            # every ARCH
```

The Python gates need no third-party package. They used to: `tests/testing.py` imported
`requests` for one download, so a fresh checkout got `ModuleNotFoundError` from a gate that then
proved nothing rather than reporting a finding. It is `urllib.request` now, so a bare `python3`
is enough:

```sh
uv sync                                       # ruff, ty, pre-commit -- for the hooks, not the gates
python3 ../tests/instrumented.py --none ./stockfish        # from src/
pre-commit install                            # optional, hooks below
```

The net is downloaded by the `net` target, which `build` depends on, and then **embedded into
the binary** -- `network.cpp` has `INCBIN(EmbeddedNNUE, EvalFileDefaultName)`, and `Network::load`
takes `load_internal` for the default name and skips its directory loop, so a default build opens
no net file at any working directory. `bench` reads the same signature from `src/`, from the repo
root and from `/`.

**A non-default `EvalFile` is the case that moves.** `Network::load` searches the working
directory first, then the binary's own directory, then `DEFAULT_NNUE_DIRECTORY` -- so a relative
`EvalFile` resolves against wherever the process was started, and a run from the wrong directory
falls through to the embedded default and produces an unrelated but entirely plausible number.

**`ARCH=native` is not a tier.** It silently changes which vector width the NNUE loops lower
to, so two hosts reporting the same label ship different binaries and no measurement taken
under it is reproducible anywhere. Always name an enumerated ARCH.

## The anchor

`bench` prints a node count that must equal the `Bench:` in the most recent commit body that
carries one. **Read it from `git log`, never from memory or a doc** -- it moves with every
functional commit.

```sh
cd src && ../tests/signature.sh \
  "$(git log --format=%b | grep -m1 -oE '^Bench: [1-9][0-9]{5,7}$' | grep -oE '[0-9]+')"
```

**Anchor the regex to the whole line and never bound the walk.** Both halves are load-bearing,
and `tests/anchor.sh` is what holds them: a body that quotes the footer in prose or as a gate
result is what an unanchored `Bench: *[0-9]+` finds first, and the newest footer sits as far
back as the non-functional commits stacked on top of it.

```sh
git rev-list --count "$(git log -1 --format=%H -E --grep='^Bench: [1-9][0-9]{5,7}$')..HEAD"
```

**A byte-changing edit is not done until a gate says so.**

```sh
../tests/signature.sh <ref>   # the anchor, per arch
../tests/perft.sh             # movegen, standard and Chess960
../tests/reprosearch.sh       # node counts repeat across ucinewgame
python3 ../tests/instrumented.py --none ./stockfish
```

Touching anything more than one thread reads or writes -- the TT, the shared histories, the
per-Worker counters, the thread pool lifecycle -- also needs the sanitizer lanes. `bench` is
single-threaded, so every gate above stays green while a data race is present.

```sh
make -j build ARCH=x86-64-avx2 sanitize=thread && python3 ../tests/instrumented.py --sanitizer-thread ./stockfish
```

## Performance: the seven axes, and which one answers what

`signature.sh` proves the engine searched the SAME TREE. It says nothing about what that tree
cost. These seven do, and they are not interchangeable.

```sh
../tests/perfbudget.sh   <base-rev> [<head-rev>]  # retired instructions, deterministic
../tests/textequal.sh    <base-rev> [<head-rev>]  # per-symbol codegen equivalence, LTO off
../tests/npsab.sh        <base-rev> [<head-rev>]  # interleaved paired wall clock
../tests/perfcounters.sh [<base>] [<head>]        # PMU: cycles, IPC, cache/branch, ALL tiers
../tests/perfdecomp.sh   [<base>] [<head>]        # per-component Ir/misses, deterministic
../tests/npsthreads.sh   <base-rev> [<head-rev>]  # SCALING across thread counts
../tests/ltcab.sh        <base-rev> [<head-rev>]  # a WARM game, at a long clock's depth
```

`perfcounters.sh` and `perfdecomp.sh` default their base to `git merge-base HEAD master`, which
is the upstream commit this branch forked from; the other four require it. Keep local `master`
at `upstream/master` and never commit on it: there is no pin file to drift, so a commit of your
own on `master` silently moves the baseline those two gates measure against, and every earlier
number stops being comparable.

**Measure with gcc AND clang, and let PGO decide.** One compiler cannot distinguish a change
from its own codegen. Run `perfbudget.sh` with `--comp gcc` and `--comp clang`, and with
`--pgo`, and put all of them in the commit body. **`ltcab.sh --counters` takes `--comp` too, and
a single-compiler campaign does not announce itself**: a loop peel reading -0.92% under clang
reads +7.2% under gcc at the same tier, deterministically, reproducibly, and with nothing in the
clang column to hint at it.

**Assess in this order**, cheapest first, each step having killed candidates on its own:
count how often the code runs; predict the taken-rate of any branch you add and treat 20-80% as
a regression; measure instructions on both compilers; diff symbol sizes when a small change
moves the number a lot; prove neutrality with a preprocessor hash where a guard makes it
possible; and only then reach for cycles.
[docs/11-performance.md](docs/11-performance.md) carries each step with its command.

A sign that **flips between gcc and clang** means the change is not an instruction-count change
at all -- it is one compiler's layout. A header change on this tree reads as a regression under
gcc `-O3` and an improvement under clang, on identical source with an identical node count.
Measure the grid -- two tiers, two compilers, both build modes -- rather than one cell of it;
[docs/11-performance.md](docs/11-performance.md) carries the loop that does it.

`make profile-build` is what ships and what fishtest measures, so PGO is the binding lane: a
refactor free under PGO and costly under plain `-O3` on one compiler has cost no player
anything. A regression under PGO still does not land.

**Pick by what the change CLAIMS.**

| the change claims | gate | why |
|---|---|---|
| "this is pure code motion" | `textequal.sh` first | a codegen-equivalence proof has no noise floor. One run settles it. |
| "this costs nothing" (a refactor) | `perfbudget.sh` | deterministic to ~0.001% here; an instruction increase in a refactor is a genuine red flag |
| "this is faster" (an optimisation) | `npsab.sh` | see the trap below -- the instruction axis can invert the sign |
| "this moved no cache line" | `perfcounters.sh` | the ONLY axis that sees a miss or a mispredict, and the only one that runs above avx2 |
| "and if it did, where?" | `perfdecomp.sh` | per-component instructions and misses, deterministic -- but a simulated cache, not this one |
| "this scales" -- anything touching the TT, the histories or the pool | `npsthreads.sh` | every other axis runs ONE thread, so a contention change is invisible to all five. It needs a node budget, not a depth: a threaded fixed-depth bench is not reproducible against itself |
| "this still pays at a LONG clock" | `ltcab.sh` | every other axis runs `bench`, which is a COLD search at depth 8 or 13. A played 10+0.1 move is a WARM one at depth 20 to 25, on a table the game has already filled, and the two do not cost the same per node |

**An instruction ratio is a claim about work, not about time.** Eleven commits took 1.8% off
clang's retired instructions on an idle box and moved the clock not at all, with misses and
mispredicts both at their control values: the instructions removed were not on the critical
path. The same source moved gcc's clock. A `perf` commit claiming speed needs `npsab.sh` or
`ltcab.sh` without `--counters`, or a named mechanism -- and a wall-clock difference near one
percent is not resolved by this workload however narrow the printed band is, so repeat the whole
measurement rebuilt and take the spread across repeats as the floor.

**The trap, measured on this repository.** `ee72cf49f` "Optimize RankAttacks" is marked *No
functional change* and passed a 212,800-game SPRT. It shrinks a table 4x, trading instructions
for cache footprint. `perfbudget.sh` scores it **+0.16%, a regression**. The instruction axis
is not merely blind to a locality win -- it reports it with the wrong sign. Never let
`perfbudget.sh` alone veto a change whose claim is locality, prefetch, or latency hiding.

What each axis proves and what it cannot see is in
[docs/11-performance.md](docs/11-performance.md); every other gate is in
[docs/10-tooling-ci.md](docs/10-tooling-ci.md) or on the page whose subject it holds.

**Check the gate's EXIT CODE, never a piped fragment.** `cmd | tail -1` reads 0 from `tail`
while the gate is red. A gate that SKIPPED for a missing tool proves nothing -- never report
it as a pass.

## Traps that cost real time

| trap | detail |
|---|---|
| **Startup is a large share of a depth-8 bench**: net load plus magic tables. A whole-process instruction ratio describes the loader as much as the engine. Subtract startup by measurement, and only on the instruction axis. | `tests/perfbudget.sh` does it per binary |
| **A node count that moved makes the comparison VOID**, not expensive. Fix the behaviour change first; `signature.sh` owns it. | both perf gates refuse |
| **callgrind implements no AVX-512** and dies on the first instruction it does not know. The instruction axis tops out at avx2/bmi2, below the tier a player builds. Instructions at avx2, time at native; never quote one tier's instruction ratio beside another tier's time ratio. | `perfbudget.sh` refuses an avx512 ARCH |
| **LTO is on by default** (`-flto=full` clang, `-flto -flto-partition=one` gcc), and **`EXTRACXXFLAGS=-fno-lto` CANNOT TURN IT OFF**: `src/Makefile` interpolates `EXTRACXXFLAGS` into `CXXFLAGS` and appends `-flto` after it, so the Makefile's flag is last and wins. Passing the flag changes nothing and reports nothing, so a gate that passes it measures the LTO build while believing it did not. Every gate needing LTO off builds through a `COMPCXX` wrapper that strips the argument. | `textequal.sh`, `linkcheck.sh`, `enginelink.sh`, `fuzzsearch.sh` |
| **PGO is what ships.** `make profile-build` is upstream's own recipe and what fishtest measures. A refactor free at plain `-O3` can cost real work under PGO, because splitting a function changes what the profile can attribute. | measure both |
| **An instruction count cannot see a latency win and is not neutral about one.** Extra accumulator chains, unrolling for ILP, software prefetch -- all can only ADD retired instructions. callgrind is blind to prefetch outright. | decide the axis before optimising |
| **nps cannot resolve a few percent.** A cold first run reads far low; a batched best-of-N measures the order as much as the binaries, because the second batch runs on a hotter core. Interleave, alternate the order, report the median of the paired ratios AND its spread. A spread straddling 1.000 has established no direction. | `tests/npsab.sh` |
| **A build mode or an ARCH change recompiles only what the edit touched.** `make build` after `make profile-build` relinks the stale PGO objects; `make build ARCH=x86-64-avx512icl` after an avx2 build relinks the stale avx2 objects. Both mongrels link, run, and PASS `signature.sh` -- behaviour is unaffected, so the anchor is green and every instruction figure taken from the binary describes two build modes at once. `make clean` between them. | any A/B that changes ARCH or build mode |
| **A gate run from the wrong directory reports a defect it did not find.** `tests/perft.sh` exits 1 from the repository root and 0 from `src/`, and exit 1 there reads as a movegen bug. Run the gates from `src/` and check the exit code of the gate, not of a pipeline. | `tests/perft.sh`, `tests/reprosearch.sh` |
| **`src/stockfish*` is gitignored**, so stale binaries accumulate in `src/`. Any oracle or A/B tooling must verify the binary it measured -- a leftover build from an older commit reports a clean pass against the wrong engine. | build into a worktree, as the perf gates do |
| **`perfbudget.sh` drops options written AFTER the revisions**, rather than refusing them, so a run asked for in clang PGO measures gcc `-O3` and reports it under the label the caller wrote down. The gate echoes what it resolved in its first line, before it builds. Options first, always. | `./tests/perfbudget.sh --comp clang --pgo HEAD~1` |
| **A default `perfcounters.sh` run may never execute the tier a player builds.** `x86-64-avx512icl` is a separate ARCH from `x86-64-vnni512` -- GFNI, VBMI, VBMI2, BITALG, VPOPCNTDQ -- and code guarded on those compiles out below it. Read the default before trusting it, and name the tier beside any match. | `grep -m1 '^TIERS=' tests/perfcounters.sh` |
| **`perft.sh` counts are facts about chess**, not a golden. A mismatch is always a movegen bug, never an update candidate. | `tests/perft.sh` |
| **`tune.h` requires tunable constants to be non-`const`**, and `types.h` includes it after its own `#endif`, outside the guard, for global visibility. No committed file uses `TUNE(...)`, so a grep for consumers finds none -- and removing the include on that evidence taxes every future SPSA run. | `src/engine/types.h` |
| **A type is free while a value is CARRIED** -- produced, stored, passed, indexed with -- and can cost when many are LIVE AT ONCE in one large function, because that is a register-allocation problem. Type an index space whose swap would not fault; do not type a quantity that is computed with. `using Depth = int` is correct and deliberate. | `docs/09-type-design.md` |
| **The bench is a fixed position list.** A divergence off those positions is invisible to the anchor, and perft cannot see a key that desyncs and resyncs. | neither gate is a faithfulness proof |

## Fleets and subagents

Multi-agent perf and refactor fleets are a standing pattern here, and each rule below names
the failure it prevents:

- **Never `git stash`** -- the stash is repo-wide across worktrees; parallel agents racing it
  corrupt each other. Recover by SHA instead.
- **Never `pkill -f`** -- the pattern reaches every agent's processes, not the caller's. One
  agent stopping its own measurement that way killed a sibling's mid-run. Stop jobs by PID.
- **Count how often it runs before writing the change.** A cost per call times a call rate is a
  claim about both, and the second half is the one that fails: an ABI cost priced at a
  source-level call rate was worth nothing because the callee was inlined at every hot site. One
  `callgrind` call census, or two atomics and a bench, settles it before any code exists.
- **`git switch --detach <sha>`** when the permission classifier refuses `git reset --hard` or
  `git checkout -b` inside an agent worktree.
- **Charter disjoint FILES, not just disjoint metrics** -- two charters phrased by metric can
  both reach the same file, and then two agents ship the same change.
- **Unique scratch filenames, and pin every measured binary by hash** -- a scratchpad
  collision makes one agent read another's output, and a run that died on SIGILL leaves a
  truncated file that reads as an enormous win. Reject any callgrind output missing its
  `Nodes searched` line.
- **Agents write nothing outside their own worktree.** Measurements travel in the report; the
  integrator records them.
- **A worktree starts where its branch last was, not at your HEAD.** Reset it to the intended
  base and verify with `git log` before building any baseline.
- **Worktree commits are candidates, not integrations.** The integrator cherry-picks onto a
  clean HEAD, re-runs the gates there, and owns the evidence.
- **A fleet's ratios are all against one base, so none of them is the stack's.** Every agent
  measures from the base it was chartered on, and those figures do not add: the assembled stack
  is a separate measurement, on both compilers, and it belongs to the integrator. On disjoint
  files the product has landed within a tenth of a percent here, which is a reason to assemble
  and measure, not a reason to skip it.

## Commits

**One logical change per commit** -- a commit that touches three modules cannot be bisected
when the node count moves.

**Conventional Commits v1.0.0.** The subject is `type(scope): description`, 72 characters or
fewer, lower case after the colon, no full stop:

```
refactor(engine): seam the clock, the dependency no gate can see
test: link the engine alone, and fix the LTO flag that did nothing
fix: repair the -Werror errors and the stale WASM path
```

| type | use for |
|---|---|
| `feat` | a capability the engine or a host did not have |
| `fix` | a defect a user or a host can hit |
| `perf` | a change whose claim is speed -- carries its measurement |
| `refactor` | behaviour-preserving structure: a zone move, a seam, a header split |
| `test` | anything under `tests/`, including a new gate |
| `ci` | anything under `.github/` |
| `docs` | `docs/`, `AGENTS.md`, `README.md`, and comment-only source changes |
| `build` | `Makefile`, `pyproject.toml`, `.gitignore`, the pre-commit config |

Scope is the zone -- `engine`, `platform`, `shell` -- or a subsystem, and is omitted when the
change is not confined to one. A breaking change to a UCI option or an exported interface takes
`!` before the colon and says what breaks in the body.

Body wrapped at 80, carrying the evidence: gate output and exit code, not "should work". A
change that moves the bench signature must say what moved it and carry the new `Bench:`.

**Write the body to the rules in [docs/13-writing.md](docs/13-writing.md).** A commit message is
the one surface where history is the subject rather than the contamination, and that licence
covers the change -- not the prose. No capitalised shouting to mark a section, no paragraph
describing what the commit does or does not establish, no summary of the body above it. State
the fact and stop.

**No footer names a non-author.** The footers this branch writes are `Bench:` and
`BREAKING CHANGE:`; `closes` and a human `Co-authored-by:` follow
[docs/13-writing.md](docs/13-writing.md). Never a `Co-Authored-By:` for a tool or an assistant,
and never a generated-by advertisement of any kind: a footer naming a non-author is a false
claim about who wrote the change, and every blame view repeats it forever. Configure tooling
that appends one by default not to, rather than stripping it in a later rewrite.

**Don't** `git push` -- commit locally and stop unless asked.
