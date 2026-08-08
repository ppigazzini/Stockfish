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
make -j build ARCH=x86-64-avx2       # ~16 s on 16 cores
make -j profile-build ARCH=...       # PGO+LTO -- what actually ships
make help                            # every ARCH
```

The Python gates need one dependency the tree did not used to declare. `tests/testing.py`
imports `requests`, and CI worked only because the hosted runner ships it -- on a fresh
checkout the gate died with `ModuleNotFoundError` and therefore proved nothing:

```sh
uv sync                                                  # ruff, ty, pre-commit
uv run --with requests python ../tests/instrumented.py --none ./stockfish   # from src/
pre-commit install                                       # optional, hooks below
```

`pyproject.toml` declares it in a `gates` group, so `uv sync --group gates` works too.

The net is downloaded by the `net` target, which `build` depends on. Run the binary from
`src/`: it resolves `EvalFile` relative to the working directory, and a run from the repo root
finds no net and produces an unrelated but entirely plausible number.

**`ARCH=native` is not a tier.** It silently changes which vector width the NNUE loops lower
to, so two hosts reporting the same label ship different binaries and no measurement taken
under it is reproducible anywhere. Always name an enumerated ARCH.

## The anchor

`bench` prints a node count that must equal the `Bench:` in the most recent commit body that
carries one. **Read it from `git log`, never from memory or a doc** -- it moves with every
functional commit.

```sh
cd src && ../tests/signature.sh $(git log -20 --format=%b | grep -m1 -oE 'Bench: *[0-9]+' | grep -oE '[0-9]+')
```

**A byte-changing edit is not done until a gate says so.**

```sh
../tests/signature.sh <ref>   # the anchor, per arch
../tests/perft.sh             # movegen, incl. 5 Chess960 rows (needs `expect`)
../tests/reprosearch.sh       # node counts repeat across ucinewgame (needs `expect`)
python3 ../tests/instrumented.py --none ./stockfish
```

Touching anything more than one thread reads or writes -- the TT, the shared histories, the
per-Worker counters, the thread pool lifecycle -- also needs the sanitizer lanes. `bench` is
single-threaded, so every gate above stays green while a data race is present.

```sh
make -j build ARCH=x86-64-avx2 sanitize=thread && python3 ../tests/instrumented.py --sanitizer-thread ./stockfish
```

## Performance: the three axes, and which one answers what

`signature.sh` proves the engine searched the SAME TREE. It says nothing about what that tree
cost. These three do, and they are not interchangeable.

```sh
../tests/perfbudget.sh <base-rev> [<head-rev>]   # retired instructions, deterministic
../tests/textequal.sh  <base-rev> [<head-rev>]   # per-symbol codegen equivalence, LTO off
../tests/npsab.sh      <base-rev> [<head-rev>]   # interleaved paired wall clock
```

**Measure with gcc AND clang, and let PGO decide.** One compiler cannot distinguish a change
from its own codegen. Run `perfbudget.sh` with `--comp gcc` and `--comp clang`, and with
`--pgo`, and put all of them in the commit body.

A sign that **flips between gcc and clang** means the change is not an instruction-count change
at all -- it is one compiler's layout. Measured here: taking `shm.h` out of `numa.h` reads
+0.0367% under gcc -O3 and **-0.0124% under clang**, on identical source with an identical node
count.

`make profile-build` is what ships and what fishtest measures, so PGO is the binding lane: a
refactor free under PGO and costly under plain `-O3` on one compiler has cost no player
anything. A regression under PGO still does not land.

**Pick by what the change CLAIMS.**

| the change claims | gate | why |
|---|---|---|
| "this is pure code motion" | `textequal.sh` first | a codegen-equivalence proof has no noise floor. One run settles it. |
| "this costs nothing" (a refactor) | `perfbudget.sh` | deterministic to ~0.001% here; an instruction increase in a refactor is a genuine red flag |
| "this is faster" (an optimisation) | `npsab.sh` | see the trap below -- the instruction axis can invert the sign |

**The trap, measured on this repository.** `ee72cf49f` "Optimize RankAttacks" is marked *No
functional change* and passed a 212,800-game SPRT. It shrinks a table 4x, trading instructions
for cache footprint. `perfbudget.sh` scores it **+0.16%, a regression**. The instruction axis
is not merely blind to a locality win -- it reports it with the wrong sign. Never let
`perfbudget.sh` alone veto a change whose claim is locality, prefetch, or latency hiding.

What each gate proves and what it cannot see is in
[docs/10-tooling-ci.md](docs/10-tooling-ci.md).

**Check the gate's EXIT CODE, never a piped fragment.** `cmd | tail -1` reads 0 from `tail`
while the gate is red. A gate that SKIPPED for a missing tool proves nothing -- never report
it as a pass.

## Traps that cost real time

| trap | detail |
|---|---|
| **Startup is 42% of a depth-8 bench** (1.15e9 of 2.72e9 Ir): net load plus magic tables. A whole-process instruction ratio describes the loader as much as the engine. Subtract startup by measurement, and only on the instruction axis. | `tests/perfbudget.sh` does it per binary |
| **A node count that moved makes the comparison VOID**, not expensive. Fix the behaviour change first; `signature.sh` owns it. | both perf gates refuse |
| **callgrind implements no AVX-512** and dies on the first instruction it does not know. The instruction axis tops out at avx2/bmi2, below the tier a player builds. Instructions at avx2, time at native; never quote one tier's instruction ratio beside another tier's time ratio. | `perfbudget.sh` refuses an avx512 ARCH |
| **LTO is on by default** (`-flto=full` clang, `-flto -flto-partition=one` gcc). Per-TU objects hold IR, so there is nothing to disassemble until the link, and the linked image renumbers every address when a TU moves. `textequal.sh` builds with `EXTRACXXFLAGS=-fno-lto` for that reason -- and therefore does NOT prove the shipped build unchanged. | quote both halves |
| **PGO is what ships.** `make profile-build` is upstream's own recipe and what fishtest measures. A refactor free at plain `-O3` can cost real work under PGO, because splitting a function changes what the profile can attribute. | measure both |
| **An instruction count cannot see a latency win and is not neutral about one.** Extra accumulator chains, unrolling for ILP, software prefetch -- all can only ADD retired instructions. callgrind is blind to prefetch outright. | decide the axis before optimising |
| **nps cannot resolve a few percent.** A cold first run reads far low; a batched best-of-N measures the order as much as the binaries, because the second batch runs on a hotter core. Interleave, alternate the order, report the median of the paired ratios AND its spread. A spread straddling 1.000 has established no direction. | `tests/npsab.sh` |
| **`src/stockfish*` is gitignored**, so stale binaries accumulate in `src/`. Any oracle or A/B tooling must verify the binary it measured -- a leftover build from an older commit reports a clean pass against the wrong engine. | build into a worktree, as the perf gates do |
| **`perft.sh` counts are facts about chess**, not a golden. A mismatch is always a movegen bug, never an update candidate. | `tests/perft.sh` |
| **`tune.h` requires tunable constants to be non-`const`**, and `types.h` includes it outside its own include guard for global visibility. Any constant-naming or header-splitting work must check TUNE first or it gets reverted the first time someone runs SPSA. | `src/types.h:498` |
| **A type is free while a value is CARRIED** -- produced, stored, passed, indexed with -- and can cost when many are LIVE AT ONCE in one large function, because that is a register-allocation problem. Type an index space whose swap would not fault; do not type a quantity that is computed with. `using Depth = int` is correct and deliberate. | not yet documented in `docs/` |
| **The bench is a fixed position list.** A divergence off those positions is invisible to the anchor, and perft cannot see a key that desyncs and resyncs. | neither gate is a faithfulness proof |

## Fleets and subagents

Multi-agent perf and refactor fleets are a standing pattern here. Every rule below closes a
failure that has actually occurred:

- **Never `git stash`** -- the stash is repo-wide across worktrees; parallel agents racing it
  corrupt each other. Recover by SHA instead.
- **Charter disjoint FILES, not just disjoint metrics** -- two agents once shipped the same
  change from opposite charters.
- **Unique scratch filenames, and pin every measured binary by hash** -- a shared scratchpad
  collision once turned a SIGILL-dead half-run into a fake 20% win. Reject any callgrind
  output missing its `Nodes searched` line.
- **Agents write nothing outside their own worktree.** Measurements travel in the report; the
  integrator records them.
- **A worktree starts where its branch last was, not at your HEAD.** Reset it to the intended
  base and verify with `git log` before building any baseline.
- **Worktree commits are candidates, not integrations.** The integrator cherry-picks onto a
  clean HEAD, re-runs the gates there, and owns the evidence.

## Commits

**One logical change per commit** -- a commit that touches three modules cannot be bisected
when the node count moves.

Conventional subject 72 characters or fewer, blank line, body wrapped at 80 carrying the
evidence: gate output and exit code, not "should work". A change that moves the bench
signature must say what moved it and carry the new `Bench:`.

**No trailers.** The body ends with the evidence and nothing after it: no `Co-Authored-By:`
for a tool or an assistant, and no generated-by advertisement of any kind. A trailer naming a
non-author is a false claim about who wrote the change, and every blame view repeats it
forever. Tooling that appends one by default must be configured not to, rather than having it
stripped in a later rewrite.

**Don't** `git push` -- commit locally and stop unless asked.
