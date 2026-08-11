#!/usr/bin/env python3
"""Bounded, seeded fuzzing of what the engine consumes but did not produce.

Four harnesses, because they fail differently and none substitutes for another:

  uci  mutated command text at the shipped binary. Finds parser defects and
       essentially never reaches the search behind them, because a mutated line
       is overwhelmingly rejected at the first token.
  tb   mutated Syzygy table bytes. The highest-consequence reader in the tree:
       an index computed one off returns a CONFIDENT WRONG VERDICT the search
       believes, so "did not crash" is not the property that matters. It probes
       twice per iteration and makes its verdict claim on the table it did NOT
       mutate; harness_tb says why the other one cannot carry a claim.
  net  a mutated network file through EvalFile. The engine embeds a network, so
       the failure mode is a REPLACEMENT net rather than a missing one.
  shm  concurrent engines contending for the shared network segment. The only
       stimulus here that is not a file: it needs a SECOND PROCESS, so nothing
       single-process reaches its shape at all.

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

# One LEGAL 3-man position per stem the fetched corpus carries, so a clean run
# reports tbhits for each. An illegal one makes the engine refuse the `position`
# command, and a harness that cannot tell a refused fixture from a defect banks
# its own rig fault as a finding -- which is why every reference verdict below is
# checked for tbhits before any mutation is tried.
#
# One per stem, rather than one position, because the tb harness probes TWICE per
# iteration and the two probes ask different questions: see harness_tb.
TB_FENS = {
    "KQvK": "4k3/8/8/8/8/8/8/3QK3 w - - 0 1",
    "KRvK": "4k3/8/8/8/8/8/8/3RK3 w - - 0 1",
    "KBvK": "4k3/8/8/8/8/8/8/3BK3 w - - 0 1",
    "KNvK": "4k3/8/8/8/8/8/8/3NK3 w - - 0 1",
    "KPvK": "4k3/8/8/8/8/8/3P4/4K3 w - - 0 1",
}


def run(cmds, timeout=25, extra_env=None):
    """Feed lines to a fresh engine. Return (returncode, output); returncode is None on a hang."""
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


def run_scripted(cmds, timeout=90):
    """Like run(), but never lets `quit` cut a search short.

    run() hands the engine every line at once, INCLUDING `quit`, and `quit`
    calls engine.stop(). A `go` in that buffer is therefore aborted at whatever
    depth it had reached when the reader thread got to the next line, so its
    bestmove is a function of the scheduler. Measured on this tree: the same
    two-probe session, clean tables, returned d1c2 and e1f1 on different runs
    through run(), and one move on six runs through this.

    A harness that compares verdicts cannot use a runner like that -- it reports
    the scheduler as a defect. tests/uci_driver.py exists for the same reason
    and cannot be reused here: it is an operator tool that raises on a wedge,
    where a wedge is exactly what this has to return as a finding.

    Returns (returncode, output); returncode is None on a hang, as run() does.
    """
    p = subprocess.Popen(
        [EXE],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        cwd=os.path.join(ROOT, "src"),
    )
    # ty cannot see that Popen(stdin=PIPE, stdout=PIPE) makes these non-None.
    assert p.stdin is not None and p.stdout is not None
    stdin, stdout = p.stdin, p.stdout

    out = []
    deadline = time.time() + timeout

    def feed(line):
        """Write one command. False once the engine has stopped reading."""
        try:
            stdin.write(line + "\n")
            stdin.flush()
        except (BrokenPipeError, ValueError):
            return False
        return True

    alive = True
    for c in cmds:
        if not feed(c):
            alive = False
            break
        if not c.lstrip().startswith("go"):
            continue
        # Wait for the sentinel this command produces. An empty read means the
        # engine is GONE, which is a crash and not a hang: stop feeding and let
        # the returncode below say which signal. Running out of time is the hang.
        while True:
            if time.time() > deadline:
                p.kill()
                p.wait(timeout=10)
                return None, "TIMEOUT"
            line = stdout.readline()
            if not line:
                alive = False
                break
            out.append(line)
            if line.startswith("bestmove"):
                break
        if not alive:
            break

    if alive:
        feed("quit")
    try:
        rest, _ = p.communicate(timeout=max(1.0, deadline - time.time()))
        out.append(rest)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait(timeout=10)
        return None, "TIMEOUT"
    return p.returncode, "".join(out)


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
        # as one. Without the lstrip such a line gets no stop behind it, runs
        # forever, and the harness banks its own hang as an engine defect.
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


def tb_verdicts(out):
    """One (move, tbhits) pair per search in the session, in order.

    Per search, not per session: the tb harness runs two searches in one engine
    and the pair it can make a claim about is the second. Reading the first
    `bestmove` and the last `tbhits` -- which is what a session-wide reader does
    -- crosses the two and compares an answer to a count from the other search.
    """
    verdicts, hits = [], 0
    for line in out.splitlines():
        if " tbhits " in line:
            with contextlib.suppress(IndexError, ValueError):
                hits = int(line.split(" tbhits ")[1].split()[0])
        if line.startswith("bestmove") and len(line.split()) > 1:
            verdicts.append((line.split()[1], hits))
            hits = 0
    return verdicts


def harness_tb(rng, deadline, findings):
    """Mutated Syzygy bytes, with two probes per iteration and a claim on one.

    WHY TWO PROBES, AND WHY THE CLAIM IS ON THE SECOND. A table is mmapped at
    first probe, so the only way to put the mutated bytes through the parser is
    to probe the material that table holds. But once that probe has happened, its
    answer is not comparable to anything: the Syzygy format carries no checksum,
    the mutated bytes ARE the compressed values for that material, and a reader
    that decodes them perfectly returns a different move than the clean table
    did. Asserting otherwise makes the harness red on its own stimulus -- which
    it was, at about one iteration in twenty, once the crashes that hid it were
    fixed.

    So the first probe is the STIMULUS and is judged on liveness alone, and the
    second probe reads a table the mutation did not touch and must STILL HIT IT.
    The claim is tbhits, not the move: see the comment on the reference below
    for the two measurements that rule the move out. It is not vacuous -- it
    fails if a corrupt table's parse spills into a neighbour or leaves the
    reader's shared state wrong.

    What is left uncovered is stated rather than asserted away: nothing here can
    tell a correctly-read corrupt table from an incorrectly-read one, because
    with no integrity field in the format nothing can.
    """
    corpus = sorted(os.listdir(TB)) if os.path.isdir(TB) else []
    stems = sorted({f.split(".")[0] for f in corpus} & set(TB_FENS))
    # Two, not one: the claim below needs a stem to leave alone.
    if len(stems) < 2:
        return None
    victims = [f for f in corpus if f.split(".")[0] in stems]

    # The reference answers, from the UNMUTATED tables, one per stem. Without
    # them the harness can only ask whether the engine survived; with them it can
    # ask whether the engine was RIGHT -- which is the failure that does not
    # announce itself.
    # THE CLAIM IS THAT THE INTACT TABLE STILL WORKS, NOT THAT IT ANSWERS THE
    # SAME MOVE, and the difference is the whole soundness of this harness.
    #
    # A bestmove comparison was tried and cannot be made sound here. Two
    # independent reasons, both measured on clean tables:
    #
    #   * A stem's bestmove depends on WHERE IN THE SESSION it was searched.
    #     These positions are decided by the tables, so every legal move carries
    #     the same tablebase rank and the choice among them falls to the search,
    #     which inherits a transposition table and histories from whatever ran
    #     before it. KBvK answers e1f2 as the first search of a session and
    #     d1e2 as the second, with nothing corrupted at all.
    #
    #   * Fixing that by taking the reference per ORDERED PAIR still fails,
    #     because the stimulus changes the first search itself: a corrupt table
    #     that gets REFUSED makes the first probe search without tablebases, and
    #     the second search inherits that instead. The reference cannot hold the
    #     first search fixed, because the first search is the experiment.
    #
    # What survives both is TBHITS ON THE SECOND PROBE. The intact stem's files
    # were copied in clean and never touched, so a probe of them must still hit
    # a table. Zero there is a corrupt table's parse reaching a neighbour, or
    # the reader's shared state left wrong -- which is the failure this harness
    # exists to catch and the one that does not announce itself.
    #
    # What is left uncovered is stated rather than asserted away: nothing here
    # can tell a correctly-read corrupt table from an incorrectly-read one,
    # because with no integrity field in the format nothing can.
    probes = [c for s in stems for c in (f"position fen {TB_FENS[s]}", "go depth 8")]
    rc, out = run_scripted([f"setoption name SyzygyPath value {TB}", "isready", *probes])
    ref = tb_verdicts(out)
    if rc != 0 or len(ref) != len(stems):
        raise SystemExit("fuzz: RIG FAULT -- the clean tables gave no reference verdict")
    if not all(hits for _, hits in ref):
        raise SystemExit("fuzz: RIG FAULT -- a reference run probed no tablebase")

    n = 0
    with tempfile.TemporaryDirectory() as d:
        while time.time() < deadline:
            n += 1
            for f in corpus:
                shutil.copy(os.path.join(TB, f), os.path.join(d, f))
            name = rng.choice(victims)
            victim = os.path.join(d, name)
            hurt = name.split(".")[0]
            intact = rng.choice([s for s in stems if s != hurt])
            size = os.path.getsize(victim)
            with open(victim, "r+b") as fh:
                for _ in range(rng.randint(1, 8)):
                    fh.seek(rng.randrange(size))
                    fh.write(bytes([rng.randrange(256)]))
            rc, out = run_scripted(
                [
                    f"setoption name SyzygyPath value {d}",
                    "isready",
                    f"position fen {TB_FENS[hurt]}",
                    "go depth 8",
                    f"position fen {TB_FENS[intact]}",
                    "go depth 8",
                ]
            )
            if rc is None:
                findings.append(("tb", f"hang on a corrupt {hurt} table", victim))
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
            # only if the engine accepted it. Crashing or hanging is not, and
            # neither is stopping between the two probes.
            got = tb_verdicts(out)
            if len(got) < 2:
                findings.append(("tb", f"no bestmove after a corrupt {hurt} table", victim))
                return n

            # The property that matters, on the probe that can carry it. INTACT's
            # tables were copied in clean and never touched, so a probe of them
            # must still reach a table. Zero hits is one table's corruption
            # reaching another's mapping.
            if got[1][1] == 0:
                findings.append(
                    (
                        "tb",
                        f"a corrupt {hurt} table left the intact {intact} tables unprobed",
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


def feed(p, text):
    """Write to a child that may already be gone, and may have no stdin at all."""
    if p.stdin is None:
        return
    try:
        p.stdin.write(text)
        p.stdin.flush()
    except (BrokenPipeError, ValueError):
        pass


def harness_shm(rng, deadline, findings):
    """Concurrent engines contending for the shared network segment.

    The only input here that is not a file. shm_unix.h hands one process's
    network to another over a Unix socket and an mmapped memfd, so its failures
    need a SECOND PROCESS rather than a mutated byte: two creators racing, and a
    peer dying mid-transfer. A client disappearing must not take the server down
    with SIGPIPE, and no single-process test can reach that shape at all.

    The property is survivorship. A process that dies because a PEER died is the
    defect; a process killed on purpose is the stimulus.
    """
    n = 0
    while time.time() < deadline:
        n += 1
        k = rng.randint(2, 5)
        procs = []
        for _ in range(k):
            procs.append(
                subprocess.Popen(
                    [EXE],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    cwd=os.path.join(ROOT, "src"),
                )
            )
        for p in procs:
            feed(p, "uci\nisready\nposition startpos\ngo depth 6\n")

        # Kill a strict subset, at a random moment during startup, so at least
        # one survivor is always left to make a claim about.
        victims = rng.sample(range(k), rng.randint(1, k - 1))
        time.sleep(rng.uniform(0.0, 0.30))
        for i in victims:
            procs[i].kill()

        for i, p in enumerate(procs):
            if i in victims:
                p.wait(timeout=20)
                continue
            feed(p, "quit\n")
            try:
                out, _ = p.communicate(timeout=40)
            except subprocess.TimeoutExpired:
                p.kill()
                findings.append(("shm", f"a survivor hung after {len(victims)} peer(s) died", EXE))
                return n
            if p.returncode < 0:
                why = f"died by signal {-p.returncode} after {len(victims)} peer kill(s)"
                findings.append(("shm", f"a survivor {why}", EXE))
                return n
            if "bestmove" not in out:
                findings.append(
                    ("shm", f"a survivor stopped answering after {len(victims)} peer(s) died", EXE)
                )
                return n
            if "Unknown status" in out:
                findings.append(("shm", "the allocator reported an unknown status", EXE))
                return n
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--harness", choices=["uci", "tb", "net", "shm", "all"], default="all")
    a = ap.parse_args()

    seed = a.seed if a.seed is not None else random.randrange(1 << 30)
    print(f"fuzz: seed {seed}  harness {a.harness}  budget {a.seconds}s")
    if not os.access(EXE, os.X_OK):
        print(f"fuzz: SKIPPED -- no engine at {EXE}", file=sys.stderr)
        return 2

    chosen = ["uci", "tb", "net", "shm"] if a.harness == "all" else [a.harness]
    # Locally the budget is split; the workflow gives each harness a job of its
    # own with the whole budget, because they run at throughputs orders of
    # magnitude apart and one shared budget is really a budget for the fastest.
    per = max(1, a.seconds // len(chosen))
    findings, ran, skipped = [], {}, []

    for name in chosen:
        rng = random.Random(seed)
        fn = {"uci": harness_uci, "tb": harness_tb, "net": harness_net, "shm": harness_shm}[name]
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
