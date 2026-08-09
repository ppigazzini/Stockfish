#!/bin/bash
# Compare two revisions on the CPU's own counters, across architecture tiers.
#
# tests/perfbudget.sh owns the instruction axis and is deterministic, but it
# simulates: callgrind cannot see a cache miss, a mispredicted branch or a
# stalled cycle, and it refuses AVX-512 outright. tests/npsab.sh owns wall clock
# but resolves only a few percent. This axis reports what the hardware actually
# did: it is the only one that reads a miss or a mispredict off the machine
# rather than off a model, and the only one that reports either at the AVX-512
# tiers callgrind refuses to run.
#
# It answers a different question from either: not "did the work change" but
# "did the machine execute it differently". A refactor that keeps instructions
# and loses IPC has moved a cache line; one that keeps both has moved nothing.
#
# THE NODE COUNT MUST MATCH. Two revisions that searched different trees are not
# comparable on any axis, and this refuses rather than prices the difference --
# the same rule perfbudget.sh and npsab.sh already carry.
#
# WHAT THIS AXIS CANNOT DO. Instructions are near-deterministic; cycles, IPC and
# both miss counts are not. They move with frequency scaling, with what else the
# machine is doing, and with where the scheduler puts the process. Rounds are
# interleaved and alternated and the median is reported with its spread, but a
# ratio whose spread straddles 1.000 has established no direction. Run it on an
# idle box; a background build forfeits the measurement.
#
# Exit codes:  0 measured   1 VOID (the node counts differ)   2 skipped
#
# Not 0-means-clean: this reports what the hardware did and leaves the judgement
# to the reader. The one thing it decides by itself is that a comparison between
# two different searches is meaningless.

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

# Span what players build, from the portable baseline up to a tier callgrind
# cannot measure at all. Name every ARCH: `native` picks the vector width from
# whatever host is compiling, so a number filed under that label describes a
# different binary on the next machine and is reproducible nowhere.
TIERS=${TIERS:-"x86-64 x86-64-sse41-popcnt x86-64-avx2 x86-64-vnni512"}
ROUNDS=${ROUNDS:-5}
DEPTH=${DEPTH:-13}
TT=${TT:-16}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
COMP=${COMP:-gcc}
PGO=${PGO:-0}

usage() {
    cat <<'EOF'
usage: tests/perfcounters.sh [<base-rev>] [<head-rev>] [options]

  <base-rev>    default: the merge-base with master, which IS the upstream pin
  <head-rev>    default: HEAD

  --rounds N    interleaved paired rounds per tier (default 5)
  --depth N     bench depth (default 13)
  --tiers "..." space-separated ARCH list (default: the TIERS list in this file)
  --comp C      gcc or clang (default gcc)
  --jobs N      parallel build jobs (default: nproc)
  --pgo         build both sides with profile-build, which is what ships

The default base needs no pin file. `master` tracks upstream/master, so
`git merge-base HEAD master` is the upstream commit this branch actually forked
from, and it stays true when master moves. A recorded SHA does not.
EOF
}

POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --rounds) ROUNDS=$2; shift 2 ;;
        --depth)  DEPTH=$2; shift 2 ;;
        --tiers)  TIERS=$2; shift 2 ;;
        --comp)   COMP=$2; shift 2 ;;
        --jobs)   JOBS=$2; shift 2 ;;
        --pgo)    PGO=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "perfcounters: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done

command -v git >/dev/null || { echo "perfcounters: SKIPPED -- no git" >&2; exit 2; }
command -v g++ >/dev/null || { echo "perfcounters: SKIPPED -- no g++" >&2; exit 2; }
command -v python3 >/dev/null || { echo "perfcounters: SKIPPED -- no python3" >&2; exit 2; }

BASE=${POS[0]:-}
HEAD_REV=${POS[1]:-HEAD}
if [ -z "$BASE" ]; then
    BASE=$(git merge-base HEAD master 2>/dev/null)
    [ -n "$BASE" ] || { echo "perfcounters: SKIPPED -- no merge-base with master" >&2; exit 2; }
fi

BASE_SHA=$(git rev-parse --short "$BASE" 2>/dev/null) || {
    echo "perfcounters: SKIPPED -- unknown revision $BASE" >&2; exit 2; }
HEAD_SHA=$(git rev-parse --short "$HEAD_REV" 2>/dev/null) || {
    echo "perfcounters: SKIPPED -- unknown revision $HEAD_REV" >&2; exit 2; }

# A container or a hardened host refuses the counters entirely. Find that out
# now, against a trivial child, rather than after building every tier twice.
PARANOID=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 9)

WORK=$(mktemp -d) || exit 2
cleanup() {
    for d in "$WORK"/wt-*; do
        [ -d "$d" ] && git worktree remove --force "$d" >/dev/null 2>&1
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

MEASURE="$WORK/perf_counters"
if ! g++ -O2 -std=c++17 -Wall -Wextra -Wshadow -Werror -o "$MEASURE" tests/perf_counters.cpp \
     > "$WORK/build-tool.log" 2>&1; then
    echo "perfcounters: SKIPPED -- tests/perf_counters.cpp did not build" >&2
    tail -5 "$WORK/build-tool.log" >&2
    exit 2
fi

if ! "$MEASURE" -o "$WORK/probe.txt" /bin/true >/dev/null 2>"$WORK/probe.err"; then
    echo "perfcounters: SKIPPED -- the counters are not readable here" >&2
    echo "perfcounters: perf_event_paranoid is $PARANOID; 2 or lower is required," >&2
    echo "perfcounters: and a container needs CAP_PERFMON." >&2
    sed 's/^/  /' "$WORK/probe.err" >&2
    exit 2
fi

echo "perfcounters: base=$BASE_SHA head=$HEAD_SHA comp=$COMP mode=$([ "$PGO" = 1 ] && echo PGO || echo -O3)"
echo "perfcounters: rounds=$ROUNDS depth=$DEPTH tt=$TT paranoid=$PARANOID"
echo "perfcounters: tiers: $TIERS"
echo

# One worktree per side, reused across tiers: a worktree starts where its branch
# last was, so it is created detached at the exact revision and never reset.
for side in base head; do
    rev=$([ "$side" = base ] && echo "$BASE_SHA" || echo "$HEAD_SHA")
    if ! git worktree add --detach "$WORK/wt-$side" "$rev" >/dev/null 2>&1; then
        echo "perfcounters: SKIPPED -- could not create a worktree at $rev" >&2
        exit 2
    fi
    cp src/*.nnue "$WORK/wt-$side/src/" 2>/dev/null
done

build() {  # side arch -> binary path, or empty
    # Declare one variable per `local`. `local a=$1 b="...$a..."` expands the
    # whole line before it assigns, so the second reference reads whatever `a`
    # held in the CALLER, not the argument -- which silently builds and measures
    # one side twice.
    local side=$1
    local arch=$2
    local dir="$WORK/wt-$side/src"
    local target=build
    [ "$PGO" = 1 ] && target=profile-build
    ( cd "$dir" && make clean >/dev/null 2>&1 \
      && make -j"$JOBS" "$target" ARCH="$arch" COMP="$COMP" ) > "$WORK/build-$side-$arch.log" 2>&1 \
      || return 1
    printf '%s\n' "$dir/stockfish"
}

rc=0
RESULTS="$WORK/results.tsv"
: > "$RESULTS"

for arch in $TIERS; do
    echo "== $arch =="

    binbase=$(build base "$arch") || { echo "  SKIPPED -- base did not build at $arch"; continue; }
    binhead=$(build head "$arch") || { echo "  SKIPPED -- head did not build at $arch"; continue; }

    # PIN WHAT IS ABOUT TO BE MEASURED, BY CONTENT. Two different revisions
    # cannot produce the same binary: the build stamp alone embeds a different
    # GIT_SHA. Equal hashes therefore mean one side was measured twice, which
    # yields a ratio of 1.0000 that is tight, clean and empty. Refuse it as a
    # rig fault rather than reporting it as a result.
    hb=$(sha256sum "$binbase" | cut -c1-12)
    hh=$(sha256sum "$binhead" | cut -c1-12)
    echo "  base $hb  head $hh"
    if [ "$hb" = "$hh" ] && [ "$BASE_SHA" != "$HEAD_SHA" ]; then
        echo "  SKIPPED -- both sides are the same binary; one side was measured twice" >&2
        rc=2
        echo
        continue
    fi

    nodes_base=""; nodes_head=""; bad=0
    for r in $(seq 1 "$ROUNDS"); do
        # Alternate which side runs first. The second slot in a round runs on a
        # hotter core, so a fixed order measures the order as much as the code.
        if [ $((r % 2)) -eq 1 ]; then order="base head"; else order="head base"; fi
        for side in $order; do
            bin=$([ "$side" = base ] && echo "$binbase" || echo "$binhead")
            dir=$(dirname "$bin")
            ( cd "$dir" && "$MEASURE" -o "$WORK/c-$side-$r.txt" ./stockfish bench "$TT" 1 "$DEPTH" ) \
              > "$WORK/o-$side-$r.txt" 2>&1
            n=$(grep -oE 'Nodes searched *: *[0-9]+' "$WORK/o-$side-$r.txt" | grep -oE '[0-9]+$')
            if [ -z "$n" ]; then
                echo "  SKIPPED -- $side produced no node count in round $r"
                bad=1; break
            fi
            if [ "$side" = base ]; then nodes_base=$n; else nodes_head=$n; fi
            if grep -q 'scaled=1' "$WORK/c-$side-$r.txt"; then
                echo "  SKIPPED -- counters were multiplexed; the reading is not trustworthy"
                bad=1; break
            fi
            printf '%s\t%s\t%s\t%s\n' "$arch" "$side" "$r" "$(cat "$WORK/c-$side-$r.txt")" \
              >> "$RESULTS"
        done
        [ "$bad" = 1 ] && break
    done
    [ "$bad" = 1 ] && { rc=2; echo; continue; }

    if [ "$nodes_base" != "$nodes_head" ]; then
        echo "  VOID -- base searched $nodes_base nodes, head searched $nodes_head."
        echo "  A different tree is not a slower or faster one. Fix the behaviour change first."
        rc=1
        echo
        continue
    fi
    echo "  nodes $nodes_base on both sides"

    python3 tests/perfcounters_report.py "$RESULTS" "$arch" || rc=1
    echo
done

echo "perfcounters: base=$BASE_SHA head=$HEAD_SHA"
if [ "$rc" = 0 ]; then
    echo "perfcounters: measured -- read the table; a spread straddling 1.000 decided nothing"
elif [ "$rc" = 2 ]; then
    echo "perfcounters: SKIPPED -- at least one tier could not be measured" >&2
else
    echo "perfcounters: FINDINGS"
fi
exit "$rc"
