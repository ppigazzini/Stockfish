#!/bin/bash
# Decompose the cost of two revisions per component, deterministically.
#
# tests/perfcounters.sh says WHETHER the machine executed the program
# differently. This says WHERE. It runs callgrind with the cache and branch
# simulators on both sides, sums self cost per symbol, groups the symbols into
# components (tests/perfcomponents.tsv) and prints instructions, D1 read misses
# and branch mispredicts for each -- with the winner named.
#
# EVERY NUMBER HERE IS DETERMINISTIC. callgrind simulates, so two runs of the
# same binary give the same counts; a 0.1% component difference is real and not
# thermal noise. That is the whole reason to pay its ~50x slowdown.
#
# AND EVERY NUMBER HERE IS A MODEL. The cache simulator is a two-level
# approximation with a fixed geometry -- it is not this machine's cache, it
# cannot see the prefetcher, and it knows nothing about out-of-order execution.
# It ranks locality; it does not predict time. When the two axes disagree,
# tests/perfcounters.sh is measuring the hardware and this one is measuring a
# model of it.
#
# callgrind implements no AVX-512, so this tops out at avx2 -- which is exactly
# why perfcounters.sh exists beside it.
#
# Exit codes:  0 reported   1 VOID (the node counts differ)   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

ARCH=${ARCH:-x86-64-avx2}
DEPTH=${DEPTH:-8}
TT=${TT:-16}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
COMP=${COMP:-gcc}
COMPONENTS=${COMPONENTS:-tests/perfcomponents.tsv}

usage() {
    cat <<'EOF'
usage: tests/perfdecomp.sh [<base-rev>] [<head-rev>] [options]

  <base-rev>    default: the merge-base with master, which IS the upstream pin
  <head-rev>    default: HEAD

  --depth N     bench depth (default 8; callgrind is ~50x, so keep it small)
  --arch ARCH   build architecture (default x86-64-avx2; avx512 is not available
                to callgrind at all)
  --comp C      gcc or clang (default gcc)
EOF
}

POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --depth) DEPTH=$2; shift 2 ;;
        --arch)  ARCH=$2; shift 2 ;;
        --comp)  COMP=$2; shift 2 ;;
        --jobs)  JOBS=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "perfdecomp: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done

command -v valgrind >/dev/null || { echo "perfdecomp: SKIPPED -- valgrind is not installed" >&2; exit 2; }
command -v python3 >/dev/null || { echo "perfdecomp: SKIPPED -- no python3" >&2; exit 2; }
[ -f "$COMPONENTS" ] || { echo "perfdecomp: SKIPPED -- no $COMPONENTS" >&2; exit 2; }

case "$ARCH" in
    *avx512*|*vnni512*)
        echo "perfdecomp: SKIPPED -- callgrind implements no AVX-512; use perfcounters.sh there" >&2
        exit 2 ;;
esac

BASE=${POS[0]:-}
HEAD_REV=${POS[1]:-HEAD}
if [ -z "$BASE" ]; then
    BASE=$(git merge-base HEAD master 2>/dev/null)
    [ -n "$BASE" ] || { echo "perfdecomp: SKIPPED -- no merge-base with master" >&2; exit 2; }
fi
BASE_SHA=$(git rev-parse --short "$BASE") || exit 2
HEAD_SHA=$(git rev-parse --short "$HEAD_REV") || exit 2

WORK=$(mktemp -d) || exit 2
cleanup() {
    for d in "$WORK"/wt-*; do
        [ -d "$d" ] && git worktree remove --force "$d" >/dev/null 2>&1
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "perfdecomp: base=$BASE_SHA head=$HEAD_SHA arch=$ARCH comp=$COMP depth=$DEPTH"
echo

profile() {  # side -> writes $WORK/cg.$side, echoes the node count
    local side=$1
    local rev
    local dir
    rev=$([ "$side" = base ] && echo "$BASE_SHA" || echo "$HEAD_SHA")
    dir="$WORK/wt-$side/src"
    git worktree add --detach "$WORK/wt-$side" "$rev" >/dev/null 2>&1 || return 1
    cp src/*.nnue "$WORK/wt-$side/src/" 2>/dev/null
    ( cd "$dir" && make -j"$JOBS" build ARCH="$ARCH" COMP="$COMP" ) \
      > "$WORK/build-$side.log" 2>&1 || return 1
    ( cd "$dir" && valgrind --tool=callgrind --callgrind-out-file="$WORK/cg.$side" \
        --cache-sim=yes --branch-sim=yes ./stockfish bench "$TT" 1 "$DEPTH" ) \
      > "$WORK/run-$side.log" 2>&1 || return 1
    grep -oE 'Nodes searched *: *[0-9]+' "$WORK/run-$side.log" | grep -oE '[0-9]+$'
}

echo "  profiling base ($BASE_SHA) under callgrind ..."
nb=$(profile base) || { echo "perfdecomp: SKIPPED -- base did not build or profile" >&2; exit 2; }
echo "  profiling head ($HEAD_SHA) under callgrind ..."
nh=$(profile head) || { echo "perfdecomp: SKIPPED -- head did not build or profile" >&2; exit 2; }

if [ -z "$nb" ] || [ -z "$nh" ]; then
    echo "perfdecomp: SKIPPED -- a profile produced no node count" >&2
    exit 2
fi
if [ "$nb" != "$nh" ]; then
    echo "  VOID -- base searched $nb nodes, head searched $nh."
    echo "  A different tree is not a cheaper one. Fix the behaviour change first."
    exit 1
fi
echo "  nodes $nb on both sides"
echo

# Whole-program totals, from valgrind's own summary rather than re-derived.
echo "== whole program (arch=$ARCH, depth=$DEPTH) =="
for ev in "I   refs" "D1  misses" "LLd misses" "Branches" "Mispredicts"; do
    # Strip valgrind's `==PID==` prefix FIRST. Without that the first number on
    # the line is the process id, and every row reports the pid of each side --
    # which looks like a plausible near-1.0 ratio.
    # Take the number AFTER the colon. `D1  misses` contains a digit, so
    # matching the first number on the whole line reports 1 for that row.
    b=$(sed 's/^==[0-9]*== //' "$WORK/run-base.log" | grep -m1 "^$ev:" \
        | sed 's/^[^:]*: *//' | grep -oE '[0-9,]+' | head -1 | tr -d ',')
    h=$(sed 's/^==[0-9]*== //' "$WORK/run-head.log" | grep -m1 "^$ev:" \
        | sed 's/^[^:]*: *//' | grep -oE '[0-9,]+' | head -1 | tr -d ',')
    [ -n "$b" ] && [ -n "$h" ] && [ "$b" != 0 ] && \
      awk -v e="$ev" -v b="$b" -v h="$h" 'BEGIN{
        r=h/b; w=(r<0.9995)?"refish":((r>1.0005)?"upstream":"tie");
        printf "  %-13s %16d %16d  %.4f  %s\n", e, b, h, r, w }'
done

echo
echo "== per component =="
python3 tests/perfdecomp.py "$WORK/cg.base" "$WORK/cg.head" "$COMPONENTS"
rcpy=$?

echo
echo "perfdecomp: base=$BASE_SHA head=$HEAD_SHA arch=$ARCH"
if [ "$rcpy" != 0 ]; then
    echo "perfdecomp: SKIPPED -- the decomposition could not be produced" >&2
    exit 2
fi
echo "perfdecomp: reported -- every figure is deterministic and every figure is a model"
exit 0
