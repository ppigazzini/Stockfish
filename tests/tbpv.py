#!/usr/bin/env python3
"""Walk the tablebase PV extension against the array that has to hold it.

syzygy_extend_pv appends one move per iteration to RootMove::pv, which is a
PVMoves -- a fixed Move[MAX_PLY + 1] whose push_back checks its bound with an
assert. -DNDEBUG is what ships, so a walk longer than the array writes into the
next RootMove of the vector holding it, and the first symptom is a SIGSEGV in a
position nothing in the sweep distinguishes.

WHAT THIS ASSERTS, in order of how long it will keep being true:

  no PV longer than MAX_PLY   read out of src/engine/types.h, not pinned here.
                              A cap that is removed shows up as an over-long PV
                              on the very first extension that would have needed
                              one, whatever the search does around it.
  the engine answers          every position gets its bestmove. A walk with no
                              bound either overruns the array or does not
                              terminate, and this catches the second.

THE SWEEP IS A REPRODUCTION AND REPRODUCTIONS ROT. tests/tbpv.fens is a seeded
sweep of KNNvKP positions, and it crashed a pre-fix binary at position 350 --
but only through the corpus tbfetch.sh --men 5 fetches. Add stems and the same
sweep passes on the same defect, because richer tables hand the search different
scores and a different PV to extend. So a clean run means "this sequence found
nothing", never "the bound holds"; the length assertion above is what carries a
claim, and it is the one that does not depend on the search still producing the
PV it produced the day the file was written.

Syzygy50MoveRule is off because that is what disarms the loop's other exit:
`rule50 && pos.is_draw(0)` is constant-false with it off, and time_abort() is
constant-false whenever use_time_management() is -- `go depth` here, `go
infinite` and `go movetime` in a GUI.

Stdlib only, single thread, no ucinewgame between positions: the search state
one position leaves is part of what the next one is driven with.

Exit codes:  0 clean   1 findings   2 skipped
"""

import argparse
import re
import subprocess
import sys
import threading
import time
from pathlib import Path
from queue import Empty, Queue

REPO = Path(__file__).resolve().parents[1]
DEFAULT_BIN = REPO / "src" / "stockfish"
DEFAULT_TB = REPO / "resources" / "syzygy-5man"
DEFAULT_FENS = Path(__file__).resolve().parent / "tbpv.fens"

# The corpus this sweep reproduces through, as the engine counts it. A different
# count is a different corpus, and a different corpus is a different test.
EXPECTED_TABLES = 5


def max_ply():
    """Read MAX_PLY from the engine rather than pinning it beside the engine."""
    src = (REPO / "src" / "engine" / "types.h").read_text()
    m = re.search(r"^constexpr int MAX_PLY\s*=\s*(\d+);", src, re.M)
    return int(m.group(1)) if m else None


class Engine:
    def __init__(self, binary):
        self.proc = subprocess.Popen(
            [str(binary)],
            cwd=str(Path(binary).resolve().parent),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if self.proc.stdin is None or self.proc.stdout is None:
            raise RuntimeError("engine pipes not created")
        self.stdin = self.proc.stdin
        self.stdout = self.proc.stdout
        self.lines = Queue()
        self.tail = []
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        for line in self.stdout:
            line = line.rstrip()
            self.tail.append(line)
            del self.tail[:-6]
            self.lines.put(line)

    def send(self, cmd):
        if self.proc.poll() is not None:
            return False
        try:
            self.stdin.write(cmd + "\n")
            self.stdin.flush()
            return True
        except (BrokenPipeError, ValueError):
            return False

    def wait_for(self, pattern, timeout, on_line=None):
        """Collect lines until one matches, the engine dies, or time runs out."""
        deadline = time.time() + timeout
        while True:
            if self.proc.poll() is not None:
                return "died"
            try:
                line = self.lines.get(timeout=0.1)
            except Empty:
                if time.time() > deadline:
                    return "timeout"
                continue
            if on_line:
                on_line(line)
            if pattern.match(line):
                return "ok"
            if time.time() > deadline:
                return "timeout"

    def close(self):
        self.send("quit")
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--bin", default=str(DEFAULT_BIN), help="engine binary")
    ap.add_argument("--syzygy", default=str(DEFAULT_TB), help="the --men 5 corpus")
    ap.add_argument("--fens", default=str(DEFAULT_FENS), help="the sweep")
    ap.add_argument("--depth", type=int, default=8, help="search depth per position")
    ap.add_argument("--timeout", type=float, default=20.0, help="seconds a position may take")
    a = ap.parse_args()

    # The corpus path is resolved here because the engine runs with src/ as its
    # working directory -- it resolves EvalFile from there -- so a relative
    # SyzygyPath from a caller's shell would name a directory that does not
    # exist and load nothing, which reads as "0 tables" rather than as a typo.
    binary, tb, fens = Path(a.bin), Path(a.syzygy).resolve(), Path(a.fens)
    if not binary.exists():
        print(f"tbpv: SKIPPED -- no engine at {binary}", file=sys.stderr)
        return 2
    if not tb.is_dir() or not list(tb.glob("*.rtbw")):
        print(f"tbpv: SKIPPED -- no corpus at {tb}; run tests/tbfetch.sh --men 5", file=sys.stderr)
        return 2
    if not fens.exists():
        print(f"tbpv: SKIPPED -- no sweep at {fens}", file=sys.stderr)
        return 2

    limit = max_ply()
    if limit is None:
        print("tbpv: SKIPPED -- MAX_PLY not found in src/engine/types.h", file=sys.stderr)
        return 2

    positions = [ln.strip() for ln in fens.read_text().splitlines()]
    positions = [ln for ln in positions if ln and not ln.startswith("#")]

    eng = Engine(binary)
    found = re.compile(r"^info string Found (\d+) WDL and (\d+) DTZ")
    tables = []
    eng.send(f"setoption name SyzygyPath value {tb}")
    eng.send("setoption name Syzygy50MoveRule value false")
    eng.send("setoption name Threads value 1")

    def note_tables(line):
        m = found.match(line)
        if m:
            tables.append(int(m.group(1)))

    eng.send("isready")
    if eng.wait_for(re.compile(r"^readyok"), 10.0, note_tables) != "ok":
        print("tbpv: SKIPPED -- engine did not answer isready", file=sys.stderr)
        eng.close()
        return 2

    if tables and tables[0] != EXPECTED_TABLES:
        print(
            f"tbpv: SKIPPED -- {tables[0]} WDL tables at {tb}, expected {EXPECTED_TABLES}.\n"
            "      This sweep reproduces through that corpus and no other; see the\n"
            "      note in tests/tbfetch.sh before widening it.",
            file=sys.stderr,
        )
        eng.close()
        return 2

    print(f"tbpv: {len(positions)} positions, depth {a.depth}, PV bound {limit}, corpus {tb}")
    bestmove = re.compile(r"^bestmove\b")
    longest, longest_at = 0, ""
    over = []
    started = time.time()

    for i, fen in enumerate(positions, 1):
        seen = [0]

        def measure(line, seen=seen, fen=fen, i=i):
            if " pv " in line:
                n = len(line.split(" pv ", 1)[1].split())
                seen[0] = max(seen[0], n)
                if n > limit:
                    over.append((i, fen, n))

        if not eng.send(f"position fen {fen}") or not eng.send(f"go depth {a.depth}"):
            print(f"tbpv: FINDING -- engine gone before position {i}: {fen}")
            print(f"       exit code {eng.proc.returncode}")
            return 1

        why = eng.wait_for(bestmove, a.timeout, measure)
        if why == "died":
            print(f"tbpv: FINDING -- engine died at position {i}: {fen}")
            print(f"       exit code {eng.proc.returncode} (negative is a signal)")
            for line in eng.tail:
                print("       ", line[:160])
            return 1
        if why == "timeout":
            print(f"tbpv: FINDING -- no bestmove within {a.timeout}s at position {i}: {fen}")
            for line in eng.tail:
                print("       ", line[:160])
            eng.proc.kill()
            return 1
        if seen[0] > longest:
            longest, longest_at = seen[0], fen

    eng.close()
    elapsed = time.time() - started

    if over:
        i, fen, n = over[0]
        print(f"tbpv: FINDING -- {len(over)} PV(s) longer than MAX_PLY ({limit})")
        print(f"       first at position {i}: {n} moves, {fen}")
        return 1

    print(f"tbpv: clean -- longest PV {longest} moves (bound {limit}), {elapsed:.1f}s")
    print(f"      longest at {longest_at}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
