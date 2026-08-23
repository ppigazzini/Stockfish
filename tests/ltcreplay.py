#!/usr/bin/env python3
"""Replay a fixed game at a fixed depth -- the workload a long clock reaches.

WHY THIS EXISTS. Every speed axis in tests/ runs `bench`, and `bench` is a COLD
search: a short fixed-depth probe of an unrelated position with a table and a
history bank that the previous position barely warmed. A move at 10+0.1 is the
opposite workload. It runs at ply 40 of one game, on a transposition table that
has been written end to end a dozen times, on history and correction banks that
every earlier move of that game populated, and it reaches depth 20 to 25 rather
than the 8 or 13 the gates default to.

The two regimes do not cost the same per node, and a ratio measured in the first
does not transfer to the second. This driver runs the second one, and it is
DETERMINISTIC: the move list is fixed input, every search is `go depth D`, and
one thread makes the node count a function of the position and the table alone.
Two binaries that search the same tree must report the SAME node count at every
ply -- that equality is the fidelity check, and a run that breaks it is void
rather than slow.

Stdlib only, per AGENTS.md.

    # record a move list once, from any binary (deterministic given depth+hash)
    python3 tests/ltcreplay.py record --bin src/stockfish --depth 14 --plies 80 \\
        > /tmp/game.moves

    # replay it, per-ply TSV on stdout, summary on the last line
    python3 tests/ltcreplay.py replay --bin src/stockfish --depth 20 \\
        --moves /tmp/game.moves --hash 16

    # the same replay with the accumulated state thrown away before every move:
    # the direct measurement of what a warm table and a warm history bank buy
    python3 tests/ltcreplay.py replay ... --cold

    # with hardware counters, if tests/perf_counters is built
    python3 tests/ltcreplay.py replay ... --counters tests/perf_counters
"""

import argparse
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


class Engine:
    """A UCI process that stays alive until `quit`.

    A shell pipe closes stdin after the last command, the UCI loop reads EOF and
    quits MID-SEARCH -- returning a depth-1 move and exit code 0, with nothing in
    the output saying the search was cut short. tests/uci_driver.py carries the
    same warning; this class exists so a replay cannot fall into it.
    """

    def __init__(self, argv, options):
        self.proc = subprocess.Popen(
            argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1
        )
        # Popen types both pipes as optional because they are absent unless
        # asked for. They were asked for, so bind them once and let every later
        # use be unconditional rather than sprinkling assertions down the class.
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.stdin = self.proc.stdin
        self.stdout = self.proc.stdout
        self.send("uci")
        self.until(r"^uciok\b")
        for key, value in options.items():
            self.send(f"setoption name {key} value {value}")
        self.ready()

    def send(self, line):
        self.stdin.write(line + "\n")
        self.stdin.flush()

    def until(self, pattern):
        rx, lines = re.compile(pattern), []
        while True:
            line = self.stdout.readline()
            if not line:
                raise SystemExit("ltcreplay: the engine died mid-command")
            lines.append(line.rstrip("\n"))
            if rx.search(line):
                return lines

    def ready(self):
        self.send("isready")
        self.until(r"^readyok\b")

    def go(self, command):
        """Return (lines, wall_us). The wall clock spans the whole `go`."""
        start = time.perf_counter_ns()
        self.send(command)
        lines = self.until(r"^bestmove\b")
        return lines, (time.perf_counter_ns() - start) // 1000

    def quit(self):
        try:
            self.send("quit")
            self.proc.wait(timeout=20)
        except Exception:
            self.proc.kill()
        return self.proc.returncode


def field(line, name, cast=int):
    match = re.search(rf"\b{name} (\S+)", line)
    return cast(match.group(1)) if match else None


def summarise(lines):
    """The last `info` line carrying a node count, plus the bestmove."""
    infos = [x for x in lines if x.startswith("info ") and " nodes " in x]
    best = next((x.split()[1] for x in lines if x.startswith("bestmove")), None)
    return (infos[-1] if infos else ""), best


def open_engine(args, counters_out=None):
    argv = [str(args.bin)]
    if counters_out:
        argv = [str(args.counters), "-o", str(counters_out), *argv]
    if args.wrap:
        # A launcher prefix -- valgrind, taskset, a sanitizer runner. It goes
        # OUTSIDE the counter harness so the harness still measures the child it
        # spawned rather than the launcher.
        argv = shlex.split(args.wrap) + argv
    options = {"Threads": args.threads, "Hash": args.hash}
    if args.multipv != 1:
        options["MultiPV"] = args.multipv
    for pair in args.setoption:
        name, _, value = pair.partition("=")
        if not _:
            raise SystemExit(f"ltcreplay: --setoption wants NAME=VALUE, got '{pair}'")
        options[name] = value
    return Engine(argv, options)


def position_command(start, moves):
    head = "position startpos" if start == "startpos" else f"position fen {start}"
    return head + (" moves " + " ".join(moves) if moves else "")


def cmd_record(args):
    engine = open_engine(args)
    engine.send("ucinewgame")
    engine.ready()
    moves = []
    for _ in range(args.plies):
        engine.send(position_command(args.start, moves))
        lines, _ = engine.go(f"go depth {args.depth}")
        _, best = summarise(lines)
        if best in (None, "(none)", "0000"):
            break
        moves.append(best)
    engine.quit()
    print(" ".join(moves))
    return 0


def cmd_replay(args):
    moves = Path(args.moves).read_text().split()
    if args.plies:
        moves = moves[: args.plies]

    counters_out = Path(args.counters_out) if args.counters else None
    engine = open_engine(args, counters_out)
    engine.send("ucinewgame")
    engine.ready()

    rows = []
    played = []
    for ply, move in enumerate(moves):
        if args.cold:
            engine.send("ucinewgame")
            engine.ready()
        engine.send(position_command(args.start, played))
        lines, wall = engine.go(f"go depth {args.depth}")
        info, best = summarise(lines)
        if not info:
            raise SystemExit(f"ltcreplay: no info line at ply {ply}")
        rows.append(
            dict(
                ply=ply,
                depth=field(info, "depth") or 0,
                seldepth=field(info, "seldepth") or 0,
                nodes=field(info, "nodes") or 0,
                ms=field(info, "time") or 0,
                hashfull=field(info, "hashfull") or 0,
                wall_us=wall,
                best=best or "-",
            )
        )
        played.append(move)

    code = engine.quit()
    if code not in (0, None):
        raise SystemExit(f"ltcreplay: the engine exited {code}")

    print("ply\tdepth\tseldepth\tnodes\tms\twall_us\thashfull\tbest")
    for r in rows:
        print(
            f"{r['ply']}\t{r['depth']}\t{r['seldepth']}\t{r['nodes']}\t"
            f"{r['ms']}\t{r['wall_us']}\t{r['hashfull']}\t{r['best']}"
        )

    nodes = sum(int(r["nodes"]) for r in rows)
    ms = sum(int(r["ms"]) for r in rows)
    wall = sum(int(r["wall_us"]) for r in rows)
    # The engine's own clock starts inside `go`, so `ms` excludes whatever the
    # `position` command and the search setup cost. `wall_us` includes both.
    # Their difference IS the per-`go` fixed cost this branch spent three commits
    # shrinking, and it is the term that decays as the move lengthens.
    print(
        f"replay: plies={len(rows)} nodes={nodes} ms={ms} wall_us={wall} "
        f"fixed_us={wall - ms * 1000} "
        f"nps={int(nodes * 1000 / ms) if ms else 0} "
        f"maxdepth={max(r['depth'] for r in rows)} "
        f"hashfull_last={rows[-1]['hashfull']}"
    )

    if counters_out and counters_out.exists():
        print(counters_out.read_text().strip())
    return 0


def cmd_clock(args):
    """Play one side of a fixed game on a NODE clock, and report what the time
    manager did with it.

    THE POINT. Every question about "does a faster engine convert its speed into
    Elo at this time control" runs into the same wall: a real clock is wall time,
    wall time is not reproducible, and the answer is then an SPRT and 40,000
    games. `nodestime` removes the wall clock entirely. With it set, the engine's
    own elapsed() returns NODES (timeman.h:51-54), the budget is a node bank it
    keeps itself (timeman.cpp:37-40, 92-96), and a whole game is a deterministic
    function of the move list. Nothing here is timed and nothing here is noisy.

    A faster engine is then simply a LARGER --npmsec: at 1000 nodes per
    millisecond a 1 ms budget buys 1,000 nodes, at 1100 it buys 1,100. So two
    runs of this mode with --npmsec 1000 and --npmsec 1100 are the same engine
    playing the same game with a 10% speed advantage, with the REAL time manager
    in the loop -- and the difference in the depth it reaches is exactly how much
    of that 10% the time manager let it keep.

    Run it at a short TC and a long one and the answer stops being an opinion.
    """
    moves = Path(args.moves).read_text().split()
    if args.plies:
        moves = moves[: args.plies]

    engine = open_engine(args)
    engine.send(f"setoption name nodestime value {args.npmsec}")
    # ucinewgame resets availableNodes to -1 (timeman.cpp:34), which is what
    # makes the first `go` of the game seed the bank from wtime rather than
    # inheriting the previous game's.
    engine.send("ucinewgame")
    engine.ready()

    # The engine keeps the authoritative bank; this mirrors it so the run can
    # report what is left without reading the engine's private state. Both use
    # the same arithmetic: timeman.cpp:39 subtracts (nodes searched - increment)
    # and floors at zero, and search.cpp:363-365 is where it is called.
    bank = args.npmsec * args.base_ms
    inc_nodes = args.npmsec * args.inc_ms

    rows = []
    played = []
    flagged = -1
    for ply, move in enumerate(moves):
        # Only OUR side gets a `go`. There is one TimeManagement per manager and
        # one node bank inside it, so searching both colours out of one process
        # would spend one bank for two players.
        if ply % 2 != (0 if args.side == "white" else 1):
            played.append(move)
            continue
        engine.send(position_command(args.start, played))
        lines, wall = engine.go(
            f"go wtime {args.base_ms} btime {args.base_ms} winc {args.inc_ms} binc {args.inc_ms}"
        )
        info, best = summarise(lines)
        if not info:
            raise SystemExit(f"ltcreplay: no info line at ply {ply}")
        nodes = field(info, "nodes") or 0
        before = bank
        bank = max(0, bank - (nodes - inc_nodes))
        if bank == 0 and flagged < 0:
            flagged = ply
        rows.append(
            dict(
                ply=ply,
                depth=field(info, "depth") or 0,
                seldepth=field(info, "seldepth") or 0,
                nodes=nodes,
                budget_ms=before // args.npmsec,
                bank=bank,
                wall_us=wall,
                best=best or "-",
            )
        )
        played.append(move)

    engine.quit()

    print("ply\tdepth\tseldepth\tnodes\tbudget_ms\tbank\tbest")
    for r in rows:
        print(
            f"{r['ply']}\t{r['depth']}\t{r['seldepth']}\t{r['nodes']}\t"
            f"{r['budget_ms']}\t{r['bank']}\t{r['best']}"
        )

    nodes = sum(int(r["nodes"]) for r in rows)
    depths = [int(r["depth"]) for r in rows]
    spent = args.npmsec * args.base_ms + inc_nodes * len(rows) - bank
    print(
        f"clock: moves={len(rows)} npmsec={args.npmsec} tc={args.base_ms}+{args.inc_ms}ms "
        f"nodes={nodes} mean_depth={sum(depths) / max(1, len(depths)):.3f} "
        f"min_depth={min(depths)} max_depth={max(depths)} "
        f"bank_left={bank} granted={args.npmsec * args.base_ms + inc_nodes * len(rows)} "
        f"spent_frac={spent / max(1, args.npmsec * args.base_ms + inc_nodes * len(rows)):.4f} "
        f"flagged_at={flagged}"
    )
    return 0


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("mode", choices=("record", "replay", "clock"))
    parser.add_argument(
        "--bin",
        default=REPO / "src" / "stockfish",
        help="the engine binary (default: src/stockfish)",
    )
    parser.add_argument(
        "--depth",
        type=int,
        default=20,
        help="fixed search depth per move -- 20 to 25 is what a "
        "10+0.1 move reaches on a modern core (default: 20)",
    )
    parser.add_argument("--hash", type=int, default=16, help="Hash in MB (default: 16)")
    parser.add_argument(
        "--threads",
        type=int,
        default=1,
        help="Threads (default: 1 -- more than one is not deterministic)",
    )
    parser.add_argument("--multipv", type=int, default=1)
    parser.add_argument(
        "--plies", type=int, default=80, help="plies to record, or a prefix of the replay"
    )
    parser.add_argument("--start", default="startpos", help="'startpos' or a FEN")
    parser.add_argument("--moves", help="move-list file (replay)")
    parser.add_argument(
        "--cold",
        action="store_true",
        help="send ucinewgame before every move: throws the table "
        "and the history bank away, so the replay measures a "
        "cold search at a long-clock depth",
    )
    parser.add_argument(
        "--setoption",
        action="append",
        default=[],
        metavar="NAME=VALUE",
        help="an extra UCI option, repeatable; e.g. --setoption 'Move Overhead=0'",
    )
    parser.add_argument(
        "--npmsec",
        type=int,
        default=1000,
        help="clock mode: nodes per millisecond -- this IS the "
        "engine's simulated speed (default: 1000)",
    )
    parser.add_argument(
        "--base-ms",
        type=int,
        default=10000,
        help="clock mode: base time in ms (default: 10000, "
        "which with --inc-ms 100 is fishtest STC 10+0.1)",
    )
    parser.add_argument(
        "--inc-ms", type=int, default=100, help="clock mode: increment in ms (default: 100)"
    )
    parser.add_argument(
        "--side",
        choices=("white", "black"),
        default="white",
        help="clock mode: which side the engine plays",
    )
    parser.add_argument(
        "--wrap",
        default="",
        help="launcher prefix for the engine, e.g. "
        "'valgrind --tool=callgrind --callgrind-out-file=cg.out'",
    )
    parser.add_argument("--counters", help="path to tests/perf_counters")
    parser.add_argument("--counters-out", default="/tmp/ltcreplay.counters")
    args = parser.parse_args()

    if args.mode in ("replay", "clock") and not args.moves:
        parser.error(f"{args.mode} needs --moves")
    if args.mode == "clock" and not 1 <= args.npmsec <= 10000:
        parser.error("--npmsec must be in 1..10000 (the UCI option's range)")
    if args.threads != 1:
        print("ltcreplay: WARNING -- Threads != 1 is not deterministic", file=sys.stderr)

    return {"record": cmd_record, "replay": cmd_replay, "clock": cmd_clock}[args.mode](args)


if __name__ == "__main__":
    sys.exit(main())
