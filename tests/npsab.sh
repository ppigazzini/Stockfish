#!/bin/bash
# Interleaved paired wall-clock A/B between two revisions.
#
# The second axis. tests/perfbudget.sh counts retired instructions, which is
# deterministic and blind to locality: a change that trades instructions for
# cache footprint reads there as a regression while being faster. Upstream
# `ee72cf49f` ("Optimize RankAttacks") is exactly that shape -- it shrinks a
# table and pays in instructions -- and the instruction axis scores it a
# regression. When that axis says regression, THIS is the gate that decides
# whether it is real.
#
# Three rules inside the protocol, each of which decides whether the reported
# ratio means anything:
#
#   * ALTERNATE which binary runs first. The second slot in a round runs on a
#     hotter core; with a fixed order that bias is systematic and a few-percent
#     effect comes out with the wrong sign.
#
#   * Report the MEDIAN of the paired ratios and its SPREAD. A spread that
#     straddles 1.000 has established no direction and must be reported as
#     establishing none.
#
#   * Read the engine's OWN bench clock. It starts after the net load, so it
#     contains no startup -- nothing to subtract and nothing to get wrong.
#
# The node count must match, for the same reason it must in perfbudget.
#
# Exit codes:  0 ran (read the verdict)   1 void or failed   2 skipped

set -u
set -o pipefail

ARCH=x86-64-avx2
COMP=gcc
DEPTH=13
TT=16
ROUNDS=7
KEEP=0
JOBS=$(nproc 2>/dev/null || echo 4)

SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)

usage() {
    cat <<EOF
Usage: $0 [options] <base-rev> [<head-rev>]

Options:
  --arch ARCH   build architecture (default: $ARCH)
  --comp COMP   compiler, gcc or clang (default: $COMP)
  --depth D     bench depth (default: $DEPTH -- deeper is more search-dominated)
  --tt MB       bench hash size (default: $TT)
  --rounds N    paired rounds, order alternating each round (default: $ROUNDS)
  --jobs N      parallel build jobs (default: $JOBS)
  --keep        keep the build directories
  -h, --help    this text

Run it on an IDLE box. A background build forfeits the measurement.
EOF
}

cleanup() {
    [ "$KEEP" = "1" ] && { echo "kept: $WORK"; return; }
    for d in "$WORK"/*/; do
        [ -e "$d/.git" ] && git -C "$SRC_ROOT" worktree remove --force "$d" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

die()  { echo "npsab: $*" >&2; exit 1; }
skip() { echo "npsab: SKIPPED -- $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH=$2; shift 2 ;;
        --comp) COMP=$2; shift 2 ;;
        --depth) DEPTH=$2; shift 2 ;;
        --tt) TT=$2; shift 2 ;;
        --rounds) ROUNDS=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || { usage >&2; exit 1; }
BASE_REV=$1
HEAD_REV=${2:-HEAD}


# Refuse a non-numeric option rather than pass it on: `--rounds abc` would reach
# `seq 1 abc` and produce a loop that never runs, which prints an empty table
# and then divides by nothing -- a verdict shaped like a measurement.
num() {
    case "$2" in
        ''|*[!0-9.]*|*.*.*) die "$1 must be a number, got '$2'" ;;
    esac
}
num --depth "$DEPTH"; num --tt "$TT"; num --rounds "$ROUNDS"; num --jobs "$JOBS"

# Fewer than three rounds cannot separate a direction from a single reading:
# with one round LO equals HI, so the straddle test is vacuously false and a
# direction gets claimed from one sample.
[ "$ROUNDS" -ge 3 ] 2>/dev/null || die "--rounds must be at least 3"

prepare_tree() {
    local rev=$1 dir=$2
    if [ "$rev" = "worktree" ]; then
        mkdir -p "$dir"
        tar -C "$SRC_ROOT" -cf - \
            --exclude='.git' --exclude='src/stockfish*' --exclude='*.o' \
            --exclude='*.nnue' --exclude='src/.depend' src tests scripts \
            2>/dev/null | tar -C "$dir" -xf - || die "could not copy the working tree"
    else
        git -C "$SRC_ROOT" rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
            || die "not a revision: $rev"
        git -C "$SRC_ROOT" worktree add --detach --quiet "$dir" "$rev" \
            || die "could not create a worktree for $rev"
    fi
    local n found=0
    for n in "$SRC_ROOT"/src/*.nnue; do
        [ -e "$n" ] || continue
        ln -sf "$n" "$dir/src/$(basename "$n")" && found=1
    done
    [ "$found" = "1" ] || skip "no .nnue in $SRC_ROOT/src -- run 'make net' there first"
}

# The build stamp is neutralised on BOTH sides. An empty GIT_SHA selects a
# DIFFERENT branch of engine_version_info, so a `worktree` side -- a tar copy,
# which carries no .git -- and a revision side do not compile the same source
# unless both are forced empty, and under LTO that macro moves inlining
# decisions nowhere near the version string. tests/perfbudget.sh carries the
# measurement: 0.11% of its search figure, on one commit built both ways.
build_side() {
    local dir=$1 label=$2
    echo "  building $label ..." >&2
    ( cd "$dir/src" && make -j"$JOBS" build ARCH="$ARCH" COMP="$COMP" \
        GIT_SHA= GIT_DATE= GIT_DIFFINDEX= ) > "$dir/build.log" 2>&1 \
        || { tail -25 "$dir/build.log" >&2; die "$label failed to build"; }
}

# One bench, reported as the engine's own nodes-per-second and node total.
run_once() {
    local bin=$1 out
    out=$("$bin" bench "$TT" 1 "$DEPTH" 2>&1)
    local nps nodes
    nps=$(echo "$out"   | grep -a 'Nodes/second'   | awk -F': *' '{print $2}' | tr -d ' \r')
    nodes=$(echo "$out" | grep -a 'Nodes searched' | awk -F': *' '{print $2}' | tr -d ' \r')
    [ -n "$nps" ] && [ -n "$nodes" ] || die "bench produced no reading"
    echo "$nps $nodes"
}

echo "npsab: arch=$ARCH comp=$COMP depth=$DEPTH tt=$TT rounds=$ROUNDS"
echo "npsab: base=$BASE_REV head=$HEAD_REV"

prepare_tree "$BASE_REV" "$WORK/base"
prepare_tree "$HEAD_REV" "$WORK/head"
build_side   "$WORK/base" base
build_side   "$WORK/head" head

# Warm both binaries once; the first run of a cold binary is not a reading.
run_once "$WORK/base/src/stockfish" > /dev/null || exit 1
run_once "$WORK/head/src/stockfish" > /dev/null || exit 1

# The A/A control. The box's noise floor is a property of its STATE, not a
# constant of the host: the same control immediately after a heavy build reads
# far wider than a settled one. So it is measured here, adjacent in time to the
# comparison it floors, by racing the BASE binary against itself in the same
# alternating pattern. A control taken once at the start of a session floors
# nothing an hour later.
#
# When the control is wider than the effect, discard the COMPARISON, not the
# control: a wide A/A is the box saying every ratio measured beside it is noise.
echo "  A/A control (base against itself) ..." >&2
CTRL=()
for r in 1 2 3; do
    XO=$(run_once "$WORK/base/src/stockfish") || exit 1
    YO=$(run_once "$WORK/base/src/stockfish") || exit 1
    read -r x _ <<< "$XO"; read -r y _ <<< "$YO"
    CTRL+=( "$(awk -v a="$y" -v b="$x" 'BEGIN{printf "%.4f", a/b}')" )
done
CSORT=$(printf '%s\n' "${CTRL[@]}" | sort -n)
CLO=$(printf '%s\n' "$CSORT" | head -1)
CHI=$(printf '%s\n' "$CSORT" | tail -1)
# Both quantities must be displacements from 1.0 or the comparison below is a
# width against an offset. The control's half-width is the larger of the two
# ends' distances from unity.
CBAND=$(awk -v lo="$CLO" -v hi="$CHI" \
    'BEGIN{a=lo-1; if(a<0)a=-a; b=hi-1; if(b<0)b=-b; printf "%.4f", (a>b)?a:b}')
printf 'A/A control: %.4f .. %.4f   (half-width %.4f from 1.000)\n' "$CLO" "$CHI" "$CBAND"

B_NODES=; H_NODES=
RATIOS=()
echo
printf '%-7s %14s %14s %10s %s\n' "round" "base nps" "head nps" "ratio" "order"
for r in $(seq 1 "$ROUNDS"); do
    if [ $((r % 2)) -eq 1 ]; then
        BO=$(run_once "$WORK/base/src/stockfish") || exit 1
        HO=$(run_once "$WORK/head/src/stockfish") || exit 1
        read -r bn bnodes <<< "$BO"; read -r hn hnodes <<< "$HO"
        order="base,head"
    else
        HO=$(run_once "$WORK/head/src/stockfish") || exit 1
        BO=$(run_once "$WORK/base/src/stockfish") || exit 1
        read -r hn hnodes <<< "$HO"; read -r bn bnodes <<< "$BO"
        order="head,base"
    fi
    [ -z "$B_NODES" ] && B_NODES=$bnodes
    [ -z "$H_NODES" ] && H_NODES=$hnodes
    [ "$bnodes" = "$B_NODES" ] || die "base node count moved between rounds"
    [ "$hnodes" = "$H_NODES" ] || die "head node count moved between rounds"
    ratio=$(awk -v h="$hn" -v b="$bn" 'BEGIN{printf "%.4f", h/b}')
    RATIOS+=("$ratio")
    printf '%-7s %14s %14s %10s %s\n' "$r" "$bn" "$hn" "$ratio" "$order"
done
echo

if [ "$B_NODES" != "$H_NODES" ]; then
    echo "npsab: VOID -- base searched $B_NODES nodes, head $H_NODES."
    echo "  A speed ratio over a different tree is not comparable."
    exit 1
fi

SORTED=$(printf '%s\n' "${RATIOS[@]}" | sort -n)
MED=$(printf '%s\n' "$SORTED" | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')
LO=$(printf '%s\n' "$SORTED" | head -1)
HI=$(printf '%s\n' "$SORTED" | tail -1)

printf 'head/base nps ratio: median %.4f   spread %.4f .. %.4f   (nodes %s, both)\n' \
       "$MED" "$LO" "$HI" "$B_NODES"

STRADDLES=$(awk -v lo="$LO" -v hi="$HI" 'BEGIN{print (lo < 1.0 && hi > 1.0) ? "yes" : "no"}')
if [ "$STRADDLES" = "yes" ]; then
    echo "npsab: NO DIRECTION -- the spread straddles 1.000."
    echo "  This establishes nothing. Report it as establishing nothing, and adjudicate"
    echo "  on the deterministic instruction axis (tests/perfbudget.sh) instead."
    exit 0
fi

# An effect smaller than the control band is not an effect.
EFFECT=$(awk -v m="$MED" 'BEGIN{d=m-1; if(d<0)d=-d; printf "%.4f", d}')
INSIDE=$(awk -v e="$EFFECT" -v c="$CBAND" 'BEGIN{print (e < c) ? "yes" : "no"}')
if [ "$INSIDE" = "yes" ]; then
    echo "npsab: NO DIRECTION -- the effect ($EFFECT) is inside the A/A control band ($CBAND)."
    echo "  The box cannot resolve a difference this small right now. Re-run on a settled"
    echo "  box, or adjudicate on the deterministic instruction axis."
    exit 0
fi

DIR=$(awk -v m="$MED" 'BEGIN{print (m > 1.0) ? "FASTER" : "SLOWER"}')
PCT=$(awk -v m="$MED" 'BEGIN{printf "%+.2f", (m-1)*100}')
echo "npsab: head is $DIR by ${PCT}% (median of $ROUNDS paired ratios, order alternating)"
echo "  The spread does not straddle 1.000, so the direction is established at this"
echo "  arch and depth. Quote the median AND the spread; a ratio without its spread"
echo "  is not a measurement."
exit 0
