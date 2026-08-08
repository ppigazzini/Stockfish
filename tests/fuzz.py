#!/usr/bin/env python3
"""Bounded, seeded fuzzing of the three inputs the engine did not produce.

Three harnesses, because they fail differently and none substitutes for another:

  uci  mutated command text at the shipped binary. Finds parser defects and
       essentially never reaches the search behind them, because a mutated line
       is overwhelmingly rejected at the first token.
  tb   mutated Syzygy table bytes. The highest-consequence reader in the tree:
       an index computed one off returns a CONFIDENT WRONG VERDICT the search
       believes, so "did not crash" is not the property that matters.
  net  a mutated network file through EvalFile. The engine embeds a network, so
       the failure mode is a REPLACEMENT net rather than a missing one.

The seed prints first. The value of a fuzz run is a reproducible failure.

Not a merge gate. A clean run means "nothing failed inside that budget", never
"there is nothing to find".

Exit codes:  0 no finding   1 a finding   2 skipped
"""

import argparse
import contextlib
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.environ.get("EXE", os.path.join(ROOT, "src", "stockfish"))
TB = os.path.join(ROOT, "tests", "syzygy-3man")

# Hash and Threads are the only options whose fuzzed value the engine turns
# straight into an allocation, so they are the only ones whose value can exhaust
# the machine rather than the process -- and that kill takes the harness with
# it, leaving a dead runner and no finding to read.
#
# Draw them from a bounded pool and emit the line VERBATIM. Mangling defeats a
# bound, and truncation is the specific defeat: it rewrites a value the spin
# parser refuses into one it honours, so `Hash value 99999999` becomes 9999 --
# a table the box actually backs. Bound each in its own units; one shared pool
# would read 16 as both megabytes and worker counts.
HASH_VALUES = ["1", "16", "0", "-1", "abc", "33554433"]
THREAD_VALUES = ["1", "2", "0", "-1", "abc", "1025"]

VERBATIM = (
    [f"setoption name Hash value {v}" for v in HASH_VALUES]
    + [f"setoption name Threads value {v}" for v in THREAD_VALUES]
    + ["go depth 3", "go nodes 500", "go movetime 20", "go mate 1", "go infinite", "go"]
)

TOKENS = [
    "uci",
    "isready",
    "ucinewgame",
    "position",
    "startpos",
    "fen",
    "moves",
    "go",
    "stop",
    "ponderhit",
    "setoption",
    "name",
    "value",
    "d",
    "eval",
    "flip",
    "compiler",
    "depth",
    "nodes",
    "movetime",
    "wtime",
    "btime",
    "winc",
    "binc",
    "movestogo",
    "searchmoves",
    "perft",
    "infinite",
    "mate",
    "e2e4",
    "e7e5",
    "0",
    "-1",
    "99999999999999999999",
    "",
    "@#$",
    "1e9",
]

# A LEGAL 3-man position the fetched tables cover (tbhits 4 on a clean run).
# An illegal one makes the engine refuse the `position` command, and a harness
# that cannot tell that apart from a defect reports a rig fault as a finding --
# which this one did on its first run.
TB_FEN = "8/8/8/8/3k4/8/3Q4/3K4 b - - 0 1"


def run(cmds, timeout=25, extra_env=None):
    """Feed lines to a fresh engine. Return (returncode, output) or None on hang."""
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    try:
        p = subprocess.run(
            [EXE],
            input="\n".join(cmds) + "\nquit\n",
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=os.path.join(ROOT, "src"),
            env=env,
        )
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return None, "TIMEOUT"


def gen_uci(rng):
    """A script of mostly-nonsense with some whole lines kept intact."""
    lines = ["uci", "isready"]
    for _ in range(rng.randint(2, 14)):
        if rng.random() < 0.35:
            lines.append(rng.choice(VERBATIM))
        else:
            n = rng.randint(1, 5)
            lines.append(" ".join(rng.choice(TOKENS) for _ in range(n)))
        # A burst can start several unbounded searches, and commands queued
        # behind the first are not dispatched until it returns. Writing every
        # stop at once puts them all in the buffer before the first search
        # starts, where they collapse into the single flag that search consumes
        # -- and the next unbounded `go` then runs forever. One stop per line.
        # lstrip before the test: a generated line can start with an empty
        # token, and " go" does not startswith("go") while the engine reads it
        # as one. That gap left an unbounded search with no stop behind it, and
        # the harness reported the resulting hang as an engine defect.
        if lines[-1].lstrip().startswith("go"):
            lines.append("stop")
    lines.append("isready")
    return lines


def harness_uci(rng, deadline, findings):
    n = 0
    while time.time() < deadline:
        n += 1
        script = gen_uci(rng)
        rc, out = run(script)
        if rc is None:
            findings.append(("uci", "hang", script))
            return n
        # The engine must still be answering. A script that leaves it wedged is
        # a finding even when the process eventually exits.
        if "readyok" not in out:
            findings.append(("uci", "no readyok", script))
            return n
        if rc < 0:
            findings.append(("uci", f"killed by signal {-rc}", script))
            return n
    return n


def tb_verdict(out):
    """The engine's answer, as the pair a caller would act on."""
    best = next(
        (
            line.split()[1]
            for line in out.splitlines()
            if line.startswith("bestmove") and len(line.split()) > 1
        ),
        None,
    )
    hits = 0
    for line in out.splitlines():
        if " tbhits " in line:
            with contextlib.suppress(IndexError, ValueError):
                hits = int(line.split(" tbhits ")[1].split()[0])
    return best, hits


def harness_tb(rng, deadline, findings):
    src = [f for f in sorted(os.listdir(TB))] if os.path.isdir(TB) else []
    if not src:
        return None

    # The reference answer, from the UNMUTATED tables. Without it the harness can
    # only ask whether the engine survived; with it, it can ask whether the
    # engine was RIGHT -- which is the failure that does not announce itself. A
    # corrupt table that still answers, still reports tbhits, and returns a
    # different move than the clean tables did is a confident wrong verdict, and
    # nothing else in this tree looks for one.
    rc, out = run(
        [
            f"setoption name SyzygyPath value {TB}",
            "isready",
            f"position fen {TB_FEN}",
            "go depth 8",
        ]
    )
    if rc != 0 or "bestmove" not in out:
        raise SystemExit("fuzz: RIG FAULT -- the clean tables gave no reference verdict")
    ref_move, ref_hits = tb_verdict(out)
    if not ref_hits:
        raise SystemExit("fuzz: RIG FAULT -- the reference run probed no tablebase")

    n = 0
    with tempfile.TemporaryDirectory() as d:
        while time.time() < deadline:
            n += 1
            for f in src:
                shutil.copy(os.path.join(TB, f), os.path.join(d, f))
            victim = os.path.join(d, rng.choice(src))
            size = os.path.getsize(victim)
            with open(victim, "r+b") as fh:
                for _ in range(rng.randint(1, 8)):
                    fh.seek(rng.randrange(size))
                    fh.write(bytes([rng.randrange(256)]))
            rc, out = run(
                [
                    f"setoption name SyzygyPath value {d}",
                    "isready",
                    f"position fen {TB_FEN}",
                    "go depth 8",
                ]
            )
            if rc is None:
                findings.append(("tb", "hang on a corrupt table", victim))
                return n
            if rc < 0:
                findings.append(("tb", f"killed by signal {-rc}", victim))
                return n
            # Three ways the rig can be wrong, and all three refuse rather than
            # return a verdict: the fixture is illegal, the tables were not
            # loaded, or the engine never reached the search. Reporting any of
            # them as a finding credits the harness for an experiment it did
            # not run.
            if "CRITICAL ERROR" in out:
                raise SystemExit(
                    f"fuzz: RIG FAULT -- the engine refused the fixture:\n{out.strip()[-300:]}"
                )
            if "Found 0 WDL" in out:
                raise SystemExit("fuzz: RIG FAULT -- no tablebase was loaded")
            # Refusing a corrupt file is correct. Answering from it is correct
            # only if the engine accepted it. Crashing or hanging is not.
            if "bestmove" not in out:
                findings.append(("tb", "no bestmove", victim))
                return n

            # The property that matters. If the engine still probed a table and
            # still answered, the answer must be the one the clean tables gave:
            # this position's value does not depend on the bytes we corrupted
            # being right, only on them being READ right. A different move here
            # is the search believing a table that lied to it.
            move, hits = tb_verdict(out)
            if hits and move != ref_move:
                findings.append(
                    (
                        "tb",
                        f"wrong verdict from a corrupt table: {move}, clean tables say {ref_move}"
                        f" (tbhits {hits})",
                        victim,
                    )
                )
                return n
    return n


def net_eval(out):
    """The static evaluation the engine reports, in its own units."""
    for line in out.splitlines():
        if line.startswith("Final evaluation"):
            for tok in line.split():
                try:
                    return float(tok)
                except ValueError:
                    continue
    return None


def harness_net(rng, deadline, findings):
    nets = sorted(
        (os.path.getsize(os.path.join(ROOT, "src", f)), f)
        for f in os.listdir(os.path.join(ROOT, "src"))
        if f.endswith(".nnue")
    )
    if not nets:
        return None
    smallest = nets[0][1]

    # The reference evaluation, from the SHIPPED net. The property here is not
    # "did it crash" -- it is that a corrupt net must be REFUSED rather than
    # loaded into an evaluation that looks plausible. Without a reference there
    # is no way to tell a refused net from an accepted one that lies, because
    # both print a number.
    rc, out = run(["position startpos", "eval"])
    ref = net_eval(out)
    if rc != 0 or ref is None:
        raise SystemExit("fuzz: RIG FAULT -- no reference evaluation from the shipped net")

    n = 0
    with tempfile.TemporaryDirectory() as d:
        victim = os.path.join(d, "fuzz.nnue")
        while time.time() < deadline:
            n += 1
            shutil.copy(os.path.join(ROOT, "src", smallest), victim)
            size = os.path.getsize(victim)
            with open(victim, "r+b") as fh:
                for _ in range(rng.randint(1, 6)):
                    fh.seek(rng.randrange(size))
                    fh.write(bytes([rng.randrange(256)]))
            rc, out = run(
                [
                    f"setoption name EvalFile value {victim}",
                    "isready",
                    "position startpos",
                    "eval",
                    "go depth 4",
                ]
            )
            if rc is None:
                findings.append(("net", "hang on a corrupt net", victim))
                return n
            if rc < 0:
                findings.append(("net", f"killed by signal {-rc}", victim))
                return n

            # Three outcomes are fine and one is not. Refusing the file is fine.
            # Failing to load it and keeping the old net is fine. Loading it and
            # reporting the same evaluation is fine -- the mutated bytes did not
            # reach this position. Loading it, saying nothing, and reporting a
            # DIFFERENT evaluation is the engine passing off a corrupt network
            # as an opinion.
            got = net_eval(out)
            if got is not None and got != ref and "ERROR" not in out:
                findings.append(
                    (
                        "net",
                        f"corrupt net accepted silently: eval {got}, shipped net says {ref}",
                        victim,
                    )
                )
                return n
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--harness", choices=["uci", "tb", "net", "all"], default="all")
    a = ap.parse_args()

    seed = a.seed if a.seed is not None else random.randrange(1 << 30)
    print(f"fuzz: seed {seed}  harness {a.harness}  budget {a.seconds}s")
    if not os.access(EXE, os.X_OK):
        print(f"fuzz: SKIPPED -- no engine at {EXE}", file=sys.stderr)
        return 2

    chosen = ["uci", "tb", "net"] if a.harness == "all" else [a.harness]
    # Locally the budget is split; the workflow gives each harness a job of its
    # own with the whole budget, because they run at throughputs orders of
    # magnitude apart and one shared budget is really a budget for the fastest.
    per = max(1, a.seconds // len(chosen))
    findings, ran, skipped = [], {}, []

    for name in chosen:
        rng = random.Random(seed)
        fn = {"uci": harness_uci, "tb": harness_tb, "net": harness_net}[name]
        n = fn(rng, time.time() + per, findings)
        if n is None:
            skipped.append(name)
            print(f"  {name:4s} SKIPPED -- no corpus")
        else:
            ran[name] = n
            print(f"  {name:4s} {n} iteration(s)")

    print()
    for h, what, ctx in findings:
        print(f"fuzz: FINDING [{h}] {what}")
        print(f"  reproduce with --seed {seed} --harness {h}")
        if isinstance(ctx, list):
            for line in ctx:
                print(f"    > {line}")
    if skipped:
        print(f"fuzz: {', '.join(skipped)} skipped -- proved nothing")
    if findings:
        return 1
    if not ran:
        print("fuzz: SKIPPED -- no harness could run", file=sys.stderr)
        return 2
    print(f"fuzz: no finding in {a.seconds}s at seed {seed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
