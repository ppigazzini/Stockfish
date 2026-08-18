#!/usr/bin/env python3
"""Drive the Stockfish binary over UCI without tripping the stdin-EOF trap.

The engine is a REPL on stdin. A shell pipe closes stdin as soon as the last
command is written, the UCI loop reads EOF, and it quits MID-SEARCH -- returning
a depth-1 move in a millisecond and exit code 0. Nothing in the output says the
search was cut short. Every command here writes to a pipe that stays open until
`quit`, and waits for the sentinel line that command actually produces.

Stdlib only. No pip install, no venv.

    python3 driver.py smoke                 # everything, exit 0 or 1
    python3 driver.py go --depth 12
    python3 driver.py bench                 # and check it against the anchor
    python3 driver.py raw 'position startpos' 'go movetime 500'
"""

import argparse
import ast
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import NoReturn

REPO = Path(__file__).resolve().parents[1]
DEFAULT_BIN = REPO / "src" / "stockfish"
SCRATCH = Path(tempfile.gettempdir()) / "stockfish-driver"

# resources/ is the scratch directory .gitignore covers wholesale -- see the rule
# there. Nothing fetches these two for you: `games` says what is missing and how
# to point at it, and tests/match.sh will build a fastchess of its own.
# SF_FASTCHESS and SF_BOOK override, as does --fastchess / --book.
FASTCHESS = Path(os.environ.get("SF_FASTCHESS", REPO / "resources" / "fastchess"))
BOOK = Path(os.environ.get("SF_BOOK", REPO / "resources" / "UHO_Lichess_4852_v1.epd"))

# Sentinel: the line that means "this command is finished". A command with no
# sentinel is followed by `isready`, whose `readyok` cannot arrive early --
# the UCI loop is single-threaded for everything except an active search.
SENTINELS = [
    (re.compile(r"^\s*uci\s*$"), re.compile(r"^uciok\b")),
    (re.compile(r"^\s*isready\s*$"), re.compile(r"^readyok\b")),
    (re.compile(r"^\s*go\s+perft\b"), re.compile(r"^Nodes searched:")),
    (re.compile(r"^\s*go\b"), re.compile(r"^bestmove\b")),
    (re.compile(r"^\s*bench\b"), re.compile(r"^Nodes searched\s+:")),
    (re.compile(r"^\s*eval\s*$"), re.compile(r"^Final evaluation")),
    (re.compile(r"^\s*d\s*$"), re.compile(r"^Checkers:")),
]


def sentinel_for(cmd):
    for pattern, done in SENTINELS:
        if pattern.match(cmd):
            return done
    return None


class Engine:
    """A live engine process with a pipe that is not closed until quit()."""

    def __init__(self, binary=DEFAULT_BIN, echo=False, transcript=None):
        self.binary = Path(binary).resolve()
        # The Makefile writes stockfish.exe on Windows and this default carries
        # no suffix, so an msys2 run died naming a path that was right except
        # for four characters. Fall back rather than branch on the platform:
        # the question is which file is there, not which OS this is.
        if not self.binary.exists() and self.binary.with_suffix(".exe").exists():
            self.binary = self.binary.with_suffix(".exe")
        if not self.binary.exists():
            die(f"no binary at {self.binary} -- run: cd src && make -j build ARCH=x86-64-avx2")
        self.echo = echo
        # Deliberately not a context manager: the handle outlives __init__ and
        # is closed by quit(), which runs from __exit__.
        self.transcript = open(transcript, "w") if transcript else None  # noqa: SIM115
        # cwd does NOT decide where the default net is found -- Engine resolves
        # it from the binary's own directory (shell/engine.cpp binaryDirectory).
        # It DOES decide where a relative `setoption name EvalFile` resolves,
        # and where `export_net` writes, so run from the binary's directory.
        self.proc = subprocess.Popen(
            [str(self.binary)],
            cwd=str(self.binary.parent),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        # Popen types both handles Optional; PIPE above is what makes them
        # real, and every method below writes to one. Narrow once, here, rather
        # than at each of the six use sites.
        if self.proc.stdin is None or self.proc.stdout is None:
            die("the engine process came up with no pipe")
        self.stdin = self.proc.stdin
        self.stdout = self.proc.stdout
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._pump, daemon=True)
        self.reader.start()

    def _pump(self):
        for line in self.stdout:
            line = line.rstrip("\n")
            if self.echo:
                print(f"  < {line}", flush=True)
            if self.transcript:
                self.transcript.write(line + "\n")
            self.lines.put(line)
        self.lines.put(None)  # EOF

    def send(self, cmd, timeout=30.0):
        """Write one command, collect output up to its sentinel, return lines."""
        if self.echo:
            print(f"  > {cmd}", flush=True)
        if self.transcript:
            self.transcript.write(f"> {cmd}\n")
        done = sentinel_for(cmd)
        try:
            self.stdin.write(cmd + "\n")
            self.stdin.flush()
        except BrokenPipeError:
            die(f"engine died before it could be sent: {cmd}")
        if done is None:
            # No sentinel of its own; fence it with isready.
            return self.send("isready", timeout=timeout)[:-1]
        return self._collect(done, timeout, cmd)

    def write(self, cmd):
        """Send without waiting. The only way to reach the engine DURING a
        search -- send() is request/response and would block on the sentinel."""
        if self.echo:
            print(f"  > {cmd}", flush=True)
        if self.transcript:
            self.transcript.write(f"> {cmd}\n")
        self.stdin.write(cmd + "\n")
        self.stdin.flush()

    def wait_for(self, pattern, timeout):
        """Collect until `pattern` matches. Returns None on timeout instead of
        dying, so a caller can report a wedge as a finding rather than a crash."""
        done = re.compile(pattern)
        out, deadline = [], time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                line = self.lines.get(timeout=deadline - time.monotonic())
            except (queue.Empty, ValueError):
                break
            if line is None:
                return out
            out.append(line)
            if done.match(line):
                return out
        return None

    def _collect(self, done, timeout, cmd):
        out, deadline = [], time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                die(
                    f"timed out after {timeout}s waiting for the reply to: {cmd}\n"
                    f"  last line: {out[-1] if out else '(nothing)'}"
                )
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                continue
            if line is None:
                die(
                    f"engine exited (rc={self.proc.poll()}) while running: {cmd}\n"
                    f"  last line: {out[-1] if out else '(nothing)'}"
                )
            out.append(line)
            if done.match(line):
                return out

    def quit(self):
        if self.proc.poll() is None:
            try:
                self.stdin.write("quit\n")
                self.stdin.flush()
                self.stdin.close()
            except (BrokenPipeError, ValueError):
                pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self.transcript:
            self.transcript.close()
        return self.proc.returncode

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.quit()


def die(msg) -> NoReturn:
    # NoReturn, and not decoration: it is what lets the pipe narrowing in
    # Engine.__init__ hold for every use site below it.
    print(f"driver: {msg}", file=sys.stderr)
    sys.exit(1)


def anchor_bench():
    """The node count the most recent commit body claims. Never hardcode it --
    it moves with every functional commit.

    errors="replace" is load-bearing: this history is 20 years long and some
    commit bodies are not UTF-8 (a 0xd6 byte at the time of writing), so the
    default strict decode raises UnicodeDecodeError and the anchor check dies
    before the engine is even started. The shell one-liner in AGENTS.md does not
    hit this because grep is byte-oriented."""
    body = subprocess.run(
        ["git", "log", "-n", "500", "--format=%b"], cwd=str(REPO), capture_output=True, check=True
    ).stdout.decode("utf-8", errors="replace")
    m = re.search(r"Bench:\s*([0-9]+)", body)
    return int(m.group(1)) if m else None


def options(eng, threads=None, hash_mb=None, multipv=None, chess960=None, syzygy=None):
    if threads:
        eng.send(f"setoption name Threads value {threads}")
    if hash_mb:
        eng.send(f"setoption name Hash value {hash_mb}")
    if multipv:
        eng.send(f"setoption name MultiPV value {multipv}")
    if chess960:
        eng.send("setoption name UCI_Chess960 value true")
    if syzygy:
        eng.send(f"setoption name SyzygyPath value {syzygy}")


# --------------------------------------------------------------- subcommands


def cmd_go(a):
    with Engine(a.bin, echo=a.verbose) as eng:
        eng.send("uci")
        options(eng, a.threads, a.hash, a.multipv, a.chess960, a.syzygy)
        eng.send("isready")
        eng.send(f"position fen {a.fen}" if a.fen else "position startpos")
        if a.movetime:
            limit, budget = f"go movetime {a.movetime}", a.movetime / 1000 + 30
        elif a.nodes:
            limit, budget = f"go nodes {a.nodes}", 300
        else:
            limit, budget = f"go depth {a.depth}", 300
        out = eng.send(limit, timeout=budget)
        info = [ln for ln in out if ln.startswith("info depth")]
        if info:
            print(info[-1])
        print("\n".join(ln for ln in out if ln.startswith("bestmove")))
    return 0


def cmd_bench(a):
    expected = anchor_bench()
    with Engine(a.bin, echo=a.verbose) as eng:
        out = eng.send(f"bench {a.hash or 16} {a.threads or 1} {a.depth}", timeout=600)
    nodes = None
    for line in out:
        m = re.match(r"^Nodes searched\s+:\s*([0-9]+)", line)
        if m:
            nodes = int(m.group(1))
    if nodes is None:
        die("bench produced no 'Nodes searched' line")
    print(f"bench nodes: {nodes}")
    if a.depth != 13:
        print(f"note: depth {a.depth} is not the anchor depth, so no comparison is made")
        return 0
    if expected is None:
        print("note: no 'Bench:' line in any commit body -- nothing to compare against")
        return 0
    print(f"anchor      : {expected}   (from git log)")
    if nodes != expected:
        print("MISMATCH -- this is a behaviour change, not a performance question")
        return 1
    print("MATCH")
    return 0


def cmd_raw(a):
    with Engine(a.bin, echo=True) as eng:
        for cmd in a.commands:
            eng.send(cmd, timeout=a.timeout)
    return 0


def cmd_smoke(a):
    """One real session per surface the engine exposes. Exit 1 on any failure."""
    fails, checks = [], 0
    SCRATCH.mkdir(parents=True, exist_ok=True)
    log = Path(a.transcript) if a.transcript else SCRATCH / "smoke.log"

    def check(name, ok, detail=""):
        nonlocal checks
        checks += 1
        print(f"  {'PASS' if ok else 'FAIL'}  {name}{'  -- ' + detail if detail else ''}")
        if not ok:
            fails.append(name)

    print(f"smoke: {Path(a.bin).resolve()}")
    print(f"       transcript -> {log}")
    with Engine(a.bin, echo=a.verbose, transcript=log) as eng:
        out = eng.send("uci")
        check("uci handshake", any(ln.startswith("uciok") for ln in out))
        check(
            "id name",
            any(ln.startswith("id name Stockfish") for ln in out),
            next((ln for ln in out if ln.startswith("id name")), ""),
        )

        out = eng.send("isready")
        check("isready", any(ln.startswith("readyok") for ln in out))

        out = eng.send("position startpos") + eng.send("go depth 12", timeout=120)
        bestmove = next((ln for ln in out if ln.startswith("bestmove")), "")
        check(
            "search from startpos", re.match(r"^bestmove [a-h][1-8][a-h][1-8]", bestmove), bestmove
        )
        check(
            "net loaded",
            any("NNUE evaluation using" in ln for ln in out)
            or any("NNUE evaluation using" in ln for ln in eng.send("eval")),
        )

        out = eng.send("eval")
        check(
            "eval",
            any(ln.startswith("Final evaluation") for ln in out),
            next((ln for ln in out if ln.startswith("Final evaluation")), ""),
        )

        out = eng.send("d")
        start_fen = "Fen: rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq"
        check("d prints the start FEN", any(ln.startswith(start_fen) for ln in out))

        out = eng.send("go perft 4", timeout=60)
        perft = next((ln for ln in out if ln.startswith("Nodes searched:")), "")
        check("perft(startpos, 4) == 197281", perft.endswith("197281"), perft)

        # A fact about chess, not a golden: 197281 is what depth 4 IS.
        kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        eng.send(f"position fen {kiwipete}")
        out = eng.send("go perft 3", timeout=60)
        perft = next((ln for ln in out if ln.startswith("Nodes searched:")), "")
        check("perft(kiwipete, 3) == 97862", perft.endswith("97862"), perft)

        eng.send("setoption name MultiPV value 3")
        eng.send("position startpos")
        out = eng.send("go depth 10", timeout=120)
        depths = [ln for ln in out if " multipv 3 " in ln]
        check("MultiPV 3 reports a third line", len(depths) > 0)
        eng.send("setoption name MultiPV value 1")

        eng.send("setoption name UCI_Chess960 value true")
        eng.send("position fen bqnb1rkr/pp3ppp/3ppn2/2p5/5P2/P2P4/NPP1P1PP/BQ1BNRKR w HFhf - 2 9")
        out = eng.send("go depth 10", timeout=120)
        bestmove = next((ln for ln in out if ln.startswith("bestmove")), "")
        check("Chess960 search", bestmove.startswith("bestmove "), bestmove)
        eng.send("setoption name UCI_Chess960 value false")

        eng.send("setoption name Threads value 4")
        eng.send("setoption name Hash value 64")
        eng.send("ucinewgame")
        eng.send("isready")
        eng.send("position startpos moves e2e4 e7e5")
        t0 = time.monotonic()
        out = eng.send("go movetime 1000", timeout=60)
        elapsed = time.monotonic() - t0
        bestmove = next((ln for ln in out if ln.startswith("bestmove")), "")
        check(
            "4 threads, movetime 1000 honoured",
            bestmove.startswith("bestmove ") and 0.8 < elapsed < 5.0,
            f"{elapsed:.2f}s -- {bestmove}",
        )

        # The trap this driver exists for: a search must NOT come back instantly.
        check("search was not cut short by EOF", elapsed > 0.8, f"{elapsed:.2f}s")

        out = eng.send("stop")  # legal while idle; must not wedge
        check("stop while idle does not wedge", True)

    rc = eng.proc.returncode
    check("clean exit on quit", rc == 0, f"rc={rc}")

    print(f"\nsmoke: {checks - len(fails)}/{checks} passed")
    if fails:
        print("failed: " + ", ".join(fails))
        return 1
    return 0


def cmd_perft(a):
    """Run tests/perft.sh's position list without expect.

    perft.sh drives the engine through an `expect` script. This box has no
    expect, so every case exits 127 and the gate reports "Some tests failed"
    in a tenth of a second -- a missing interpreter reported as a movegen bug.
    The positions and counts are READ OUT OF perft.sh, never copied here: they
    are facts about chess, and a second transcription is a second thing to rot.
    """
    src = (REPO / "tests" / "perft.sh").read_text()
    cases = re.findall(r'^run_test\s+"([^"]+)"\s+(\d+)\s+(\d+)\s+"(true|false)"', src, re.M)
    if not cases:
        die("could not parse any run_test lines out of tests/perft.sh")
    picked = [c for c in cases if a.full or int(c[2]) <= a.max_nodes]
    print(
        f"perft: {len(picked)} of {len(cases)} cases "
        f"({'all' if a.full else f'those under {a.max_nodes:,} nodes'})"
    )
    fails = 0
    with Engine(a.bin, echo=a.verbose) as eng:
        eng.send("uci")
        for pos, depth, expected, c960 in picked:
            eng.send(f"setoption name UCI_Chess960 value {c960}")
            eng.send(f"position {pos}")
            t0 = time.monotonic()
            out = eng.send(f"go perft {depth}", timeout=a.timeout)
            line = next((ln for ln in out if ln.startswith("Nodes searched:")), "")
            got = line.split(":")[-1].strip()
            ok = got == expected
            fails += not ok
            print(
                f"  {'OK  ' if ok else 'FAIL'} d{depth} {pos[:44]:<44} "
                f"{got:>13} {'' if ok else '!= ' + expected} "
                f"({time.monotonic() - t0:.1f}s)"
            )
    print(f"perft: {len(picked) - fails}/{len(picked)} passed")
    return 1 if fails else 0


def _arith(node, i):
    """Evaluate the integer arithmetic reprosearch.sh writes, and nothing else.

    NOT eval(). The expression is read out of a shell script, and eval() on
    anything read from a file is a code path with no bound on what it will run.
    This walks five operators and one name; everything else is a hard error, so
    a reprosearch.sh that grows an expression this cannot handle stops the gate
    rather than being silently executed by it.
    """
    if isinstance(node, ast.Expression):
        return _arith(node.body, i)
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.Name) and node.id == "i":
        return i
    if isinstance(node, ast.BinOp):
        lhs, rhs = _arith(node.left, i), _arith(node.right, i)
        op = type(node.op)
        if op is ast.Mult:
            return lhs * rhs
        if op is ast.FloorDiv:
            return lhs // rhs
        if op is ast.Pow:
            return lhs**rhs
        if op is ast.Add:
            return lhs + rhs
        if op is ast.Sub:
            return lhs - rhs
    die(f"reprosearch.sh's node budget is not arithmetic this evaluates: {ast.dump(node)}")


def cmd_repro(a):
    """Run tests/reprosearch.sh's check without expect.

    The claim is that a search repeats: the same `go nodes N` from the same
    position must retire the same count whether or not a ucinewgame preceded
    it, so across the gate's four searches every distinct count appears an
    EVEN number of times. An odd one is state carried across ucinewgame.

    The node budgets and the command sequence are READ OUT OF reprosearch.sh,
    never copied here, for the reason cmd_perft states: a second transcription
    is a second thing to rot. What is parsed is the loop bound, the arithmetic
    that makes each round's budget, and the `send` lines of the expect script
    in the order they appear.
    """
    src = (REPO / "tests" / "reprosearch.sh").read_text()

    m = re.search(r"for i in `seq 1 (\d+)`", src)
    if not m:
        die("could not find reprosearch.sh's round count")
    rounds = int(m.group(1))

    m = re.search(r"nodes=\$\(\((.+?)\)\)", src)
    if not m:
        die("could not find reprosearch.sh's node budget expression")
    # Bash and Python agree on ** and on left-to-right * and /; the one
    # difference is that bash's / truncates, so it becomes //.
    try:
        budget = ast.parse(m.group(1).replace("/", "//"), mode="eval")
    except SyntaxError:
        die(f"could not parse reprosearch.sh's node budget: {m.group(1)}")

    # The expect heredoc, in order. `position` and `ucinewgame` set the state,
    # `go nodes` is the measurement. Every line is taken and then filtered,
    # rather than matched by prefix: expect's heredoc escapes the dollar as
    # `\$nodes` and ends each command with a literal `\n`, and a prefix pattern
    # that stops at the first backslash silently captures `go nodes ` with no
    # budget at all -- which the engine answers by exiting.
    seq = []
    for raw in re.findall(r'^\s*send "([^"]*)"', src, re.M):
        cmd = raw.replace("\\n", "").replace("\\$", "$").strip()
        if cmd.startswith(("position", "ucinewgame", "go nodes")):
            seq.append(cmd)
    if not seq:
        die("could not parse reprosearch.sh's command sequence")
    if sum(c.startswith("go nodes") for c in seq) < 2:
        die(f"reprosearch.sh has fewer than two searches to compare: {seq}")

    print(f"repro: {rounds} rounds, {len(seq)} commands per round, budget = {m.group(1)}")

    fails = 0
    with Engine(a.bin, echo=a.verbose) as eng:
        eng.send("uci")
        for i in range(1, rounds + 1):
            nodes = _arith(budget, i)
            counts = {}
            for cmd in seq:
                out = eng.send(cmd.replace("$nodes", str(nodes)), timeout=a.timeout)
                for ln in out:
                    for n in re.findall(r"\bnodes (\d+)", ln):
                        counts[n] = counts.get(n, 0) + 1
            # An empty round compared nothing, and the even test is vacuously
            # satisfied by it -- which is the failure reprosearch.sh records
            # having been bitten by.
            if not counts:
                print(f"  FAIL {nodes:>10} nodes -- the engine reported no node counts")
                fails += 1
                continue
            odd = sorted(k for k, v in counts.items() if v % 2)
            if odd:
                print(f"  FAIL {nodes:>10} nodes -- odd counts: {', '.join(odd)}")
                fails += 1
            elif a.verbose:
                print(f"  OK   {nodes:>10} nodes -- {len(counts)} distinct, all even")
    print(f"repro: {rounds - fails}/{rounds} rounds reproducible")
    return 1 if fails else 0


def cmd_during(a):
    """Send commands to a LIVE search and require the engine to still answer.

    This is the liveness shape the tree has no gate for. A wedged engine is
    indistinguishable from a slow one unless something owns the deadline, so
    this reports HANG explicitly rather than sitting there.
    """
    with Engine(a.bin, echo=True) as eng:
        eng.send("uci")
        options(eng, a.threads, a.hash)
        eng.send("isready")
        eng.send("position startpos")
        print(f"  # starting: {a.search}")
        eng.write(a.search)
        time.sleep(a.settle)
        for cmd in a.then:
            print(f"  # mid-search: {cmd}")
            eng.write(cmd)
            time.sleep(a.gap)
        eng.write("stop")
        got = eng.wait_for(r"^bestmove\b", a.deadline)
        if got is None:
            print(f"\nHANG -- no bestmove within {a.deadline}s after stop.")
            print("The engine is not slow, it is unreachable: the UCI reader thread is")
            print("blocked, so `stop` and `quit` are never read either. Kill it.")
            eng.proc.kill()
            return 1
        print("\nOK -- the engine answered after the mid-search commands")
    return 0


def cmd_games(a):
    """Play the engine against itself under fastchess. The only surface that
    exercises a real clock, a real GUI protocol partner and the whole game."""
    fc = Path(a.fastchess)
    if not fc.exists():
        die(f"no fastchess at {fc} -- pass --fastchess, or let tests/match.sh build one")
    book = Path(a.book)
    binary = Path(a.bin).resolve()
    SCRATCH.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(fc),
        "-engine",
        f"cmd={binary}",
        "name=A",
        "-engine",
        f"cmd={binary}",
        "name=B",
        "-each",
        f"tc={a.tc}",
        f"option.Threads={a.threads}",
        f"option.Hash={a.hash}",
        "-rounds",
        str(a.games // 2),
        "-games",
        "2",
        "-repeat",
        "-concurrency",
        str(a.concurrency),
        "-ratinginterval",
        "0",
        "-pgnout",
        f"file={SCRATCH / 'games.pgn'}",
    ]
    if book.exists():
        cmd += ["-openings", f"file={book}", "format=epd", "order=random"]
    else:
        print(f"note: no book at {book}; fastchess falls back to its own balanced one")
    print(" ".join(cmd) + "\n")
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=str(SCRATCH))
    out = r.stdout + r.stderr
    print("\n".join(out.splitlines()[-12:]))

    # The pass criterion is NOT the Elo -- at this game count the bar swamps any
    # effect. It is that the engine played every game to a legal finish.
    bad = [w for w in ("disconnect", "illegal", "timeout", "crash", "stall") if w in out.lower()]
    print(f"\npgn: {SCRATCH / 'games.pgn'}")
    if r.returncode != 0 or bad:
        print(f"FAIL -- rc={r.returncode}, flagged: {bad or 'none'}")
        return 1
    print("PASS -- every game finished legally; the Elo figure here establishes nothing")
    return 0


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--bin", default=str(DEFAULT_BIN), help="engine binary")
    p.add_argument("-v", "--verbose", action="store_true", help="echo the UCI dialogue")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("smoke", help="drive every surface, exit 1 on any failure")
    s.add_argument("--transcript", help=f"default: {SCRATCH / 'smoke.log'}")
    s.set_defaults(fn=cmd_smoke)

    s = sub.add_parser("perft", help="tests/perft.sh's list, without needing expect")
    s.add_argument("--full", action="store_true", help="every case (minutes)")
    s.add_argument(
        "--max-nodes",
        type=int,
        default=200_000_000,
        help="skip cases above this count (default 2e8)",
    )
    s.add_argument("--timeout", type=float, default=900.0)
    s.set_defaults(fn=cmd_perft)

    s = sub.add_parser("repro", help="tests/reprosearch.sh's check, without needing expect")
    s.add_argument("--timeout", type=float, default=120.0)
    s.set_defaults(fn=cmd_repro)

    s = sub.add_parser("during", help="send commands to a live search; detect a wedge")
    s.add_argument("--search", default="go infinite")
    s.add_argument(
        "--then", action="append", default=[], help="command to send mid-search; repeatable"
    )
    s.add_argument("--settle", type=float, default=1.0, help="seconds before the first")
    s.add_argument("--gap", type=float, default=0.5, help="seconds between them")
    s.add_argument("--deadline", type=float, default=10.0)
    s.add_argument("--threads", type=int, default=4)
    s.add_argument("--hash", type=int, default=16)
    s.set_defaults(fn=cmd_during)

    s = sub.add_parser("games", help="self-play under fastchess; asserts legal finishes")
    s.add_argument("--games", type=int, default=8)
    s.add_argument("--tc", default="2+0.02")
    s.add_argument("--threads", type=int, default=1)
    s.add_argument("--hash", type=int, default=16)
    s.add_argument("--concurrency", type=int, default=4)
    s.add_argument("--fastchess", default=str(FASTCHESS))
    s.add_argument("--book", default=str(BOOK))
    s.set_defaults(fn=cmd_games)

    s = sub.add_parser("go", help="one search")
    s.add_argument("--fen")
    s.add_argument("--depth", type=int, default=12)
    s.add_argument("--movetime", type=int)
    s.add_argument("--nodes", type=int)
    s.add_argument("--threads", type=int)
    s.add_argument("--hash", type=int)
    s.add_argument("--multipv", type=int)
    s.add_argument("--chess960", action="store_true")
    s.add_argument("--syzygy")
    s.set_defaults(fn=cmd_go)

    s = sub.add_parser("bench", help="bench, and compare to the Bench: anchor in git log")
    s.add_argument("--depth", type=int, default=13)
    s.add_argument("--threads", type=int, default=1)
    s.add_argument("--hash", type=int, default=16)
    s.set_defaults(fn=cmd_bench)

    s = sub.add_parser("raw", help="send arbitrary UCI commands, echoing everything")
    s.add_argument("commands", nargs="+")
    s.add_argument("--timeout", type=float, default=60.0)
    s.set_defaults(fn=cmd_raw)

    a = p.parse_args()
    sys.exit(a.fn(a))


if __name__ == "__main__":
    main()
