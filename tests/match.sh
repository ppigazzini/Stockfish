#!/bin/bash
# Play this branch against upstream at a fixed time control.
#
# The perf axes measure the engine's cost. This measures the only thing a player
# experiences: games. It builds both revisions, fetches and builds fastchess at
# the revision CI already pins, and plays a match at a fixed time control.
#
# WHAT A MATCH THIS SIZE ESTABLISHES. Not Elo. fastchess prints the error bar
# beside it; compare the two before quoting the figure, because at the game
# counts this gate is meant for the bar is wider than any refactor could move.
# What it does prove is that the engine PLAYS: no crash, no disconnect, no
# illegal move, no forfeit on time, over positions no bench list and no golden
# corpus contains.
#
# Read the liveness lines first and the score last. A score computed over games
# that did not play is a number about the box, not about the engine.
#
# TIMEOUTS ARE THE MEASUREMENT'S HEALTH, NOT A DETAIL. A forfeit on time is a
# game the loser did not play, and on a busy box both sides forfeit at random.
# A background build invalidates a match exactly as it invalidates npsab.sh.
# Any non-zero timeout count is reported as a rig fault, not folded into the
# score.
#
# For an actual strength claim, use fishtest. This is a gate, not a substitute.
#
# Exit codes:  0 played clean   1 a game failed to play   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

GAMES=${GAMES:-100}
TC=${TC:-4+0.04}
CONCURRENCY=${CONCURRENCY:-4}
ARCH=${ARCH:-x86-64-avx2}
COMP=${COMP:-gcc}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
THREADS=${THREADS:-1}
HASH=${HASH:-16}
# Pin the revision .github/workflows/games.yml pins. A match played against a
# different fastchess is comparing tool behaviour as well as engines, and there
# is one place to bump when CI moves.
FASTCHESS_REF=${FASTCHESS_REF:-894616028492ae6114835195f14a899f6fa237d3}
CACHE=${CACHE:-${TMPDIR:-/tmp}/refish-fastchess}

usage() {
    cat <<'EOF'
usage: tests/match.sh [<base-rev>] [<head-rev>] [options]

  <base-rev>       default: the merge-base with master, which IS the upstream pin
  <head-rev>       default: HEAD

  --games N        total games, rounded up to an even number (default 100)
  --tc SPEC        fastchess time control (default 4+0.04)
  --concurrency N  parallel games (default 4; more than the box has forfeits games)
  --arch ARCH      build architecture (default x86-64-avx2)
  --comp C         gcc or clang (default gcc)
  --threads N      UCI Threads per engine (default 1)
  --jobs N         parallel build jobs (default: nproc)

A match cannot measure strength at the sizes this runs. It measures whether the
engine plays. Compare the Elo against the error bar fastchess prints beside it.
EOF
}

POS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --games)       GAMES=$2; shift 2 ;;
        --tc)          TC=$2; shift 2 ;;
        --concurrency) CONCURRENCY=$2; shift 2 ;;
        --arch)        ARCH=$2; shift 2 ;;
        --comp)        COMP=$2; shift 2 ;;
        --threads)     THREADS=$2; shift 2 ;;
        --jobs)        JOBS=$2; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        -*) echo "match: unknown argument: $1" >&2; usage >&2; exit 2 ;;
        *) POS+=("$1"); shift ;;
    esac
done

command -v git >/dev/null || { echo "match: SKIPPED -- no git" >&2; exit 2; }
command -v make >/dev/null || { echo "match: SKIPPED -- no make" >&2; exit 2; }

BASE=${POS[0]:-}
HEAD_REV=${POS[1]:-HEAD}
if [ -z "$BASE" ]; then
    BASE=$(git merge-base HEAD master 2>/dev/null)
    [ -n "$BASE" ] || { echo "match: SKIPPED -- no merge-base with master" >&2; exit 2; }
fi
BASE_SHA=$(git rev-parse --short "$BASE") || exit 2
HEAD_SHA=$(git rev-parse --short "$HEAD_REV") || exit 2

# Rounds of two, so each opening is played once from each side. An odd game
# count would give one side an extra white.
ROUNDS=$(( (GAMES + 1) / 2 ))

WORK=$(mktemp -d) || exit 2
cleanup() {
    for d in "$WORK"/wt-*; do
        [ -d "$d" ] && git worktree remove --force "$d" >/dev/null 2>&1
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- fastchess
if [ ! -x "$CACHE/fastchess" ]; then
    command -v curl >/dev/null || { echo "match: SKIPPED -- no curl to fetch fastchess" >&2; exit 2; }
    echo "match: fetching and building fastchess at $FASTCHESS_REF ..."
    rm -rf "$CACHE"
    mkdir -p "$CACHE" || exit 2
    if ! curl -fsSL "https://github.com/Disservin/fastchess/archive/${FASTCHESS_REF}.tar.gz" \
         | tar xz -C "$CACHE" --strip-components=1 > "$WORK/fetch.log" 2>&1; then
        echo "match: SKIPPED -- could not fetch fastchess (no network?)" >&2
        exit 2
    fi
    if ! ( cd "$CACHE" && make -j"$JOBS" ) > "$WORK/fcbuild.log" 2>&1; then
        echo "match: SKIPPED -- fastchess did not build" >&2
        tail -10 "$WORK/fcbuild.log" >&2
        exit 2
    fi
fi
BOOK="$CACHE/app/tests/data/openings.epd"
[ -f "$BOOK" ] || { echo "match: SKIPPED -- no opening book at $BOOK" >&2; exit 2; }

# ---------------------------------------------------------------- engines
build_side() {
    local side=$1
    local rev
    local dir
    rev=$([ "$side" = base ] && echo "$BASE_SHA" || echo "$HEAD_SHA")
    dir="$WORK/wt-$side"
    git worktree add --detach "$dir" "$rev" >/dev/null 2>&1 || return 1
    cp src/*.nnue "$dir/src/" 2>/dev/null
    ( cd "$dir/src" && make -j"$JOBS" profile-build ARCH="$ARCH" COMP="$COMP" ) \
      > "$WORK/build-$side.log" 2>&1 || return 1
    [ -x "$dir/src/stockfish" ]
}

echo "match: base=$BASE_SHA (upstream)  head=$HEAD_SHA (refish)"
echo "match: $((ROUNDS * 2)) games, tc=$TC, concurrency=$CONCURRENCY, arch=$ARCH, comp=$COMP, threads=$THREADS"
echo "match: building both sides with profile-build, which is what ships ..."
build_side base || { echo "match: SKIPPED -- base did not build" >&2; tail -5 "$WORK/build-base.log" >&2; exit 2; }
build_side head || { echo "match: SKIPPED -- head did not build" >&2; tail -5 "$WORK/build-head.log" >&2; exit 2; }

hb=$(sha256sum "$WORK/wt-base/src/stockfish" | cut -c1-12)
hh=$(sha256sum "$WORK/wt-head/src/stockfish" | cut -c1-12)
echo "match: binaries  upstream $hb   refish $hh"
if [ "$hb" = "$hh" ] && [ "$BASE_SHA" != "$HEAD_SHA" ]; then
    echo "match: SKIPPED -- both sides are the same binary" >&2
    exit 2
fi

# Both engines get the same options; a match that changed Hash between sides
# would measure the option, not the code.
echo
echo "match: playing ..."
set +e
"$CACHE/fastchess" \
    -engine name=refish   cmd="$WORK/wt-head/src/stockfish" \
    -engine name=upstream cmd="$WORK/wt-base/src/stockfish" \
    -each proto=uci tc="$TC" option.Threads="$THREADS" option.Hash="$HASH" \
    -rounds "$ROUNDS" -games 2 -repeat \
    -concurrency "$CONCURRENCY" \
    -openings file="$BOOK" format=epd order=random \
    -srand "$(od -An -N4 -tu4 < /dev/urandom | tr -d ' ')" \
    -ratinginterval 0 -report penta=true \
    -log file="$WORK/match.log" \
    > "$WORK/match.out" 2>&1
rc=$?
set -e

# ---------------------------------------------------------------- liveness
echo
echo "== did every game actually get played? =="
fail=0
report() {  # label pattern file
    local n
    n=$(grep -ci "$2" "$3" 2>/dev/null || true)
    if [ "$n" = 0 ]; then
        printf "  ok      %-22s none\n" "$1"
    else
        printf "  FAULT   %-22s %s\n" "$1" "$n"
        fail=1
    fi
}
report "crashes / assertions" "assertion\|segmentation\|terminate called" "$WORK/match.log"
report "disconnects"          "disconnect"                                "$WORK/match.out"
report "illegal moves"        "illegal"                                   "$WORK/match.out"
report "timeouts"             "timeout"                                   "$WORK/match.out"

if [ "$rc" != 0 ]; then
    echo "  FAULT   fastchess exited $rc"
    tail -15 "$WORK/match.out" | sed 's/^/    /'
    fail=1
fi

# ---------------------------------------------------------------- score
echo
echo "== score =="
grep -E 'Score of|Elo|LOS|Games:|Points:|Ptnml' "$WORK/match.out" | tail -12 | sed 's/^/  /'

echo
echo "match: base=$BASE_SHA head=$HEAD_SHA, $((ROUNDS * 2)) games at $TC"
if [ "$fail" != 0 ]; then
    echo "match: FINDINGS -- at least one game did not play cleanly"
    echo "match: the log is the evidence; re-run on an idle box before blaming the engine"
    exit 1
fi
echo "match: every game played -- no crash, no disconnect, no illegal move, no timeout"
echo "match: read the Elo against the error bar beside it before quoting either"
exit 0
