#!/bin/bash
# Does the engine still answer? -- the defect class no other gate can express.
#
# WHAT THIS PROVES. For each case below, an engine that has been given a command
# mid-search returns a bestmove within a deadline this script owns. Nothing else:
# it does not look at the move, the score or the node count.
#
# WHAT IT CANNOT SEE. A wrong answer. Every other gate here compares against a
# known-good result and is blind to a hang; this one is blind to everything a
# hang is not. `golden.sh` compares text and `instrumented.py` looks for
# substrings -- to both of them a wedged engine is the harness timing out, and a
# harness timeout is a rig fault rather than a detection unless something owns
# the deadline and calls it a hang.
#
# WHY A DEADLINE IS THE WHOLE GATE. Four defects on this branch's register are
# "the engine does not come back": a setoption during `go infinite`, an
# export_net under live workers, a `go movetime 0`, and a critical error raised
# while search threads sit inside a tablebase probe. None changes an answer.
# Each one stops there being an answer, and the only instrument that can tell
# that from a slow search is a clock the harness holds.
#
# The cases are the reproducers from the branch's upstream defect register, and
# every one of them was red on the commit before its fix.
#
# Exit codes:  0 every case answered   1 a case hung   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

BIN=${1:-src/stockfish}
DEADLINE=${DEADLINE:-20}

[ -x "$BIN" ] || { echo "liveness: SKIPPED -- no engine at $BIN" >&2; exit 2; }
command -v python3 >/dev/null || { echo "liveness: SKIPPED -- no python3" >&2; exit 2; }

# The tablebase cases need a corpus. Absent, they SKIP rather than pass: a case
# that silently did not run is the hole this gate exists to refuse.
TB=""
for d in resources/syzygy-345-plus5 tests/syzygy-34man resources/syzygy; do
    [ -d "$d" ] && { TB=$(cd "$d" && pwd); break; }
done

FAIL=0
SKIPPED=0
PASSED=0

# name | search | mid-search command | needs tablebases
run_case() {
    local name=$1 search=$2 cmd=$3 needtb=${4:-no}
    if [ "$needtb" = yes ] && [ -z "$TB" ]; then
        echo "  SKIPPED  $name -- no syzygy corpus"
        SKIPPED=$((SKIPPED + 1))
        return
    fi
    local out rc
    out=$(python3 tests/uci_driver.py --bin "$BIN" during \
              --search "$search" --then "$cmd" --deadline "$DEADLINE" 2>&1)
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "  ok       $name"
        PASSED=$((PASSED + 1))
    else
        echo "  HANG     $name -- no bestmove within ${DEADLINE}s"
        printf '%s\n' "$out" | sed 's/^/             /' | tail -6
        FAIL=1
    fi
}

echo "liveness: $BIN, deadline ${DEADLINE}s${TB:+, syzygy $TB}"
echo
echo "== a command that mutates state a worker holds, sent mid-search =="
run_case "defect 3   setoption during go infinite"  "go infinite" "setoption name Hash value 32"
run_case "defect 3b  a numa policy, same shape"     "go infinite" "setoption name NumaPolicy value none"
run_case "defect 4   export_net under live workers" "go infinite" "export_net /tmp/liveness_net.nnue"

echo
echo "== a search whose own limit is the defect =="
run_case "defect 25  go movetime 0"                 "go movetime 0" "setoption name Hash value 32"

echo
echo "== a critical error raised while workers are inside a probe =="
run_case "defect 30  SyzygyPath set mid-search"     "go infinite" \
         "setoption name SyzygyPath value $TB" yes

rm -f /tmp/liveness_net.nnue

echo
echo "liveness: $PASSED answered, $SKIPPED skipped, $((FAIL ? 1 : 0)) hung"
[ "$SKIPPED" -gt 0 ] && echo "liveness: a SKIP is not a pass -- the corpus decides those cases"
[ "$FAIL" = 0 ] && echo "liveness: clean" || echo "liveness: FINDINGS"
exit "$FAIL"
