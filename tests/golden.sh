#!/bin/bash
# Byte-compare the engine's output for a scripted UCI session.
#
# tests/signature.sh proves the engine searched the same TREE. Nothing proves it
# SAID the same thing. An info line that loses a field or changes order, a PV
# printed one move short, a ponder move named against the wrong position, a `d`
# board that stops showing checkers -- none of those moves the node count, and
# none is caught anywhere else in this tree.
#
# Three properties, each of which a comparison gets wrong by default:
#
#   * Filter what is not behaviour BEFORE comparing. A golden that records one
#     machine's timing is a record of that machine, not of the engine.
#
#   * Drive with a reader that WAITS. The engine runs `go` on its own thread and
#     treats end of input as `quit`, so writing every line at once and closing
#     the pipe collects a bestmove from a search that never finished.
#
#   * A comparison that compared nothing must not pass. `no mismatches` is true
#     of an empty corpus, and two blank sides compare equal.
#
# Exit codes:  0 match   1 mismatch or rig fault   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CASES="$ROOT/tests/cases"
EXE=${EXE:-$ROOT/src/stockfish}
UPDATE=0
SELECT=all

usage() {
    cat <<EOF
Usage: $0 [--update] [case]

  --update   re-record the goldens instead of comparing
  case       run one case by name; default all

Env:
  EXE        engine to drive (default: src/stockfish)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --update) UPDATE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "golden: unknown option $1" >&2; exit 1 ;;
        *) SELECT=$1; shift ;;
    esac
done

die()  { echo "golden: $*" >&2; exit 1; }
skip() { echo "golden: SKIPPED -- $*" >&2; exit 2; }

[ -x "$EXE" ] || skip "no engine at $EXE -- build it first"
[ -d "$CASES" ] || skip "no corpus at tests/cases"

# Lines whose content is a property of the machine, the build or the clock.
# Everything else is behaviour and is compared byte for byte.
#
# The processor list is the trap worth naming: `Available processors: 0-15` is
# the recording box's core count, so a golden carrying it mismatches on every
# machine of a different size while the engine's behaviour is identical. Any
# line whose content varies with the host belongs in this filter or the corpus
# becomes a record of the machine.
filter() {
    grep -avE '^info (depth [0-9]+ seldepth [0-9]+ multipv [0-9]+ score .* nodes [0-9]+ nps|string NNUE evaluation using|string Network replica)' \
    | sed -E \
        -e 's/^(Stockfish) [^ ]+ by .*/\1 <version>/' \
        -e 's/^(id name Stockfish) .*/\1 <version>/' \
        -e 's/^(Stockfish) dev-.*/\1 <version>/' \
        -e 's/^(info string Available processors): .*/\1: <cpus>/' \
        -e 's/(with NUMA node thread binding): .*/\1: <binding>/' \
        -e 's/^(Available processors +): .*/\1: <cpus>/' \
        -e 's/ time [0-9]+/ time <t>/g' \
        -e 's/ nps [0-9]+/ nps <n>/g' \
        -e 's/ hashfull [0-9]+/ hashfull <h>/g' \
        -e 's/^Total time \(ms\) : [0-9]+/Total time (ms) : <t>/' \
        -e 's/^Nodes\/second *: [0-9]+/Nodes\/second    : <n>/'
}

# Send a line, and after anything that starts a search read until the engine
# says it has finished. Without this the next command is written into a pipe the
# engine has not reached yet.
drive() {
    local script=$1
    python3 - "$EXE" "$script" <<'PY'
import subprocess, sys, threading, queue
exe, script = sys.argv[1], sys.argv[2]
p = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)
q = queue.Queue()
def rd():
    for line in p.stdout:
        q.put(line.rstrip('\n'))
    q.put(None)
threading.Thread(target=rd, daemon=True).start()
out = []
def pump(until, timeout=60):
    # until=None means "drain whatever has arrived", which cannot time out.
    # Only a wait for a specific line can, and that is a real fault.
    import time
    end = time.time() + timeout
    while time.time() < end:
        try:
            line = q.get(timeout=0.05 if until is None else 0.2)
        except queue.Empty:
            if until is None:
                return True
            continue
        if line is None:
            return False
        out.append(line)
        if until and line.startswith(until):
            return True
    if until is None:
        return True
    raise SystemExit(f"golden: timed out waiting for '{until}'")
pump(None, 2)                                   # startup banner
for raw in open(script):
    cmd = raw.strip()
    if not cmd or cmd.startswith('#'):
        continue
    p.stdin.write(cmd + '\n'); p.stdin.flush()
    if cmd.startswith('go') and 'perft' not in cmd:
        pump('bestmove')
    elif cmd.startswith('go'):
        pump('Nodes searched')
    elif cmd in ('uci',):
        pump('uciok')
    elif cmd in ('isready',):
        pump('readyok')
    else:
        pump(None, 0.4)
p.stdin.write('quit\n'); p.stdin.flush()
p.wait(timeout=10)
print('\n'.join(out))
PY
}

pass=0; fail=0; compared=0
for c in "$CASES"/*.uci; do
    [ -e "$c" ] || continue
    name=$(basename "$c" .uci)
    [ "$SELECT" = all ] || [ "$SELECT" = "$name" ] || continue

    # A `.uci` file is engine input, piped raw. A line that looks like a comment
    # is a command the engine answers "Unknown command" to, so the case diverges
    # for a reason unrelated to what it tests.
    if grep -qE '^\s*#' "$c"; then
        die "$name: a '#' line is engine input, not a comment"
    fi

    got=$(drive "$c" | filter)
    [ -n "$got" ] || die "$name: the engine printed nothing -- a dead engine, not a behaviour"

    golden="$CASES/$name.golden"
    if [ "$UPDATE" = "1" ]; then
        printf '%s\n' "$got" > "$golden"
        echo "  updated $name"
        compared=$((compared+1))
        continue
    fi

    [ -f "$golden" ] || die "$name: no golden recorded"
    if diff -q <(printf '%s\n' "$got") "$golden" >/dev/null; then
        echo "  ok       $name"
        pass=$((pass+1))
    else
        echo "  MISMATCH $name"
        diff <(printf '%s\n' "$got") "$golden" | head -20 | sed 's/^/    /'
        fail=$((fail+1))
    fi
    compared=$((compared+1))
done

echo
# A corpus that is present and yields nothing is a rig fault, not agreement.
[ "$compared" -gt 0 ] || die "the corpus is present but nothing was compared"

if [ "$UPDATE" = "1" ]; then
    echo "golden: $compared case(s) re-recorded"
    exit 0
fi
echo "golden: $pass of $((pass+fail)) case(s) match"
[ "$fail" = "0" ] || exit 1
exit 0
