#!/bin/bash
# Deterministic instruction-count A/B between two revisions of Stockfish.
#
# Answers the question no other gate in this tree answers: did this change cost
# work? tests/signature.sh proves the engine searched the SAME TREE and says
# nothing about what that tree cost.
#
# Design notes, each of which is load-bearing:
#
#   * There is NO stored golden. Both sides are built and measured in the same
#     run on the same machine, and only the DELTA is reported. A stored absolute
#     count is a property of the toolchain, the libc and the box as much as of
#     the code, so it cannot be reproduced by a reviewer and it drifts upward.
#
#   * Startup is subtracted BY MEASUREMENT. The net load and the magic-table
#     build are a large share of a short bench -- measured at ~42% of the
#     whole-process count at depth 8 -- so a whole-process ratio describes the
#     loader as much as the engine.
#
#   * The node count must MATCH. A count taken over a different tree is not
#     comparable, and this reports that as a void comparison rather than as cost.
#
#   * callgrind counts retired instructions by simulation, not by sampling, so
#     the answer is deterministic. It implements no AVX-512 and dies on the
#     first instruction it does not know, so the tiers here stop at avx2.
#
#   * An instruction count cannot see a latency win. Anything whose purpose is
#     to hide dependency latency -- extra accumulator chains, unrolling for ILP
#     -- can only ADD retired instructions and will read as a regression here.
#     Decide which quantity a change should move before quoting this gate.
#
# Exit codes:  0 pass   1 fail   2 skipped (could not measure)

set -u
set -o pipefail

ARCH=x86-64-avx2
DEPTH=8
TT=16
TOLERANCE=0.02     # percent
REPEAT=1
COMP=gcc
PGO=0
KEEP=0
JOBS=$(nproc 2>/dev/null || echo 4)

SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)

usage() {
    cat <<EOF
Usage: $0 [options] <base-rev> [<head-rev>]

  <base-rev>   git revision to measure against
  <head-rev>   git revision to measure; default HEAD.
               The literal 'worktree' measures the current working tree.

Options:
  --arch ARCH        build architecture (default: $ARCH; callgrind cannot run avx512)
  --comp COMP        compiler, gcc or clang (default: $COMP)
  --depth D          bench depth (default: $DEPTH)
  --tt MB            bench hash size (default: $TT)
  --pgo              build both sides with profile-guided optimisation, which is
                     what ships; roughly 3x slower to build
  --tolerance PCT    fail above this percent regression (default: $TOLERANCE)
  --repeat N         measure each side N times, report the median and the spread
  --jobs N           parallel build jobs (default: $JOBS)
  --keep             keep the build directories
  -h, --help         this text

Examples:
  $0 HEAD~1                      # this commit against its parent
  $0 origin/master worktree      # uncommitted work against master
  $0 --repeat 3 HEAD~1 HEAD      # with a measured spread
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

die()  { echo "perfbudget: $*" >&2; exit 1; }
skip() { echo "perfbudget: SKIPPED -- $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)      ARCH=$2; shift 2 ;;
        --comp)      COMP=$2; shift 2 ;;
        --depth)     DEPTH=$2; shift 2 ;;
        --tt)        TT=$2; shift 2 ;;
        --tolerance) TOLERANCE=$2; shift 2 ;;
        --repeat)    REPEAT=$2; shift 2 ;;
        --jobs)      JOBS=$2; shift 2 ;;
        --pgo)       PGO=1; shift ;;
        --keep)      KEEP=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die "unknown option $1" ;;
        *)           break ;;
    esac
done

[ $# -ge 1 ] || { usage >&2; exit 1; }
BASE_REV=$1
HEAD_REV=${2:-HEAD}


# A numeric option that is not a number is a silently wrong verdict, and a
# tolerance nobody bounds is the "raise it until the change fits" failure this
# gate exists to prevent.
num() {
    case "$2" in
        ''|*[!0-9.]*|*.*.*) die "$1 must be a number, got '$2'" ;;
    esac
}
num --depth "$DEPTH"; num --tt "$TT"; num --repeat "$REPEAT"; num --jobs "$JOBS"
num --tolerance "$TOLERANCE"
[ "$REPEAT" -ge 1 ] 2>/dev/null || die "--repeat must be at least 1"
[ "$DEPTH" -ge 1 ] 2>/dev/null || die "--depth must be at least 1"
awk -v t="$TOLERANCE" 'BEGIN{exit !(t > 0 && t <= 1)}' \
    || die "--tolerance must be in (0, 1] percent; $TOLERANCE would gate nothing"

command -v valgrind >/dev/null || skip "valgrind is not installed"

case "$ARCH" in
    *avx512*|*vnni*) skip "callgrind implements no AVX-512; ARCH=$ARCH cannot be measured" ;;
esac

# ---------------------------------------------------------------- build a side

# A revision is built in its own git worktree so neither side can see the
# other's objects. The nets are symlinked from the main checkout: they are
# gitignored, so a worktree has none, and `make net` would otherwise try to
# download one.
prepare_tree() {
    local rev=$1 dir=$2
    if [ "$rev" = "worktree" ]; then
        mkdir -p "$dir"
        # Copy tracked sources plus any uncommitted edits; never the binaries.
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

# `make profile-build` is the shipped recipe: PGO on top of LTO, trained on the
# engine's own bench. It is what a player runs and what a strength test
# measures, and it is where a refactor can cost work that plain -O3 does not
# show -- splitting a function changes what a profile can attribute to it. A
# budget taken only at -O3 gates a binary nobody runs.
build_side() {
    local dir=$1 label=$2 target=build
    [ "$PGO" = "1" ] && target=profile-build
    echo "  building $label ($target) ..." >&2
    ( cd "$dir/src" && make -j"$JOBS" "$target" ARCH="$ARCH" COMP="$COMP" ) \
        > "$dir/build.log" 2>&1 \
        || { tail -25 "$dir/build.log" >&2; die "$label failed to build"; }
    [ -x "$dir/src/stockfish" ] || die "$label produced no binary"
}

# ------------------------------------------------------------------- measure

# Total retired instructions for one invocation. callgrind writes the figure as
# both `summary:` and `totals:`; either is the whole-run count.
callgrind_ir() {
    local bin=$1 out=$2; shift 2
    valgrind --tool=callgrind --callgrind-out-file="$out" \
             --cache-sim=no --branch-sim=no \
             "$bin" "$@" > "$out.stdout" 2> "$out.stderr"
    grep -m1 -E '^(summary|totals):' "$out" | awk '{print $2}'
}

# The startup probe loads the network and builds the attack tables, then quits
# without searching. It is measured per BINARY, so a startup difference between
# the two sides is attributed correctly rather than cancelled out.
# A node count and an instruction count are properties of the NET as much as of
# the search, so the two sides must have loaded the same one. This is not
# hypothetical here: c8b91a2b9 is a net update, and comparing across it puts two
# different networks on the two sides of the ratio.
#
# The net is read from the binary's own announcement rather than from the
# presence of a file. Note that this build EMBEDS the net (a ~96 MB binary
# carrying a ~95 MB network via incbin), so a run can never lack one and the
# check earns its place on the mismatch case alone.
net_of() {
    grep -ao 'NNUE evaluation using [^ ]*' "$1" | head -1 | awk '{print $4}'
}

measure_side() {
    local dir=$1 label=$2 i
    local -a search_ir
    local nodes= startup= net=

    startup=$(printf 'isready\nquit\n' > "$dir/probe.in";
              valgrind --tool=callgrind --callgrind-out-file="$dir/cg.startup" \
                       --cache-sim=no --branch-sim=no \
                       "$dir/src/stockfish" < "$dir/probe.in" \
                       > /dev/null 2> "$dir/startup.stderr"
              grep -m1 -E '^(summary|totals):' "$dir/cg.startup" | awk '{print $2}')
    [ -n "$startup" ] || die "$label: no startup count from callgrind"

    for i in $(seq 1 "$REPEAT"); do
        local total
        total=$(callgrind_ir "$dir/src/stockfish" "$dir/cg.$i" bench "$TT" 1 "$DEPTH")
        [ -n "$total" ] || die "$label: no instruction count from callgrind"
        local n
        n=$(grep -a 'Nodes searched' "$dir/cg.$i.stderr" | awk -F': *' '{print $2}' | tr -d ' \r')
        [ -n "$n" ] || die "$label: bench produced no node count (crash or assert?)"
        if [ -z "$nodes" ]; then nodes=$n
        elif [ "$n" != "$nodes" ]; then die "$label: node count is not stable across runs"
        fi

        local thisnet
        thisnet=$(net_of "$dir/cg.$i.stdout")
        [ -n "$thisnet" ] || die \
            "$label: bench announced no 'NNUE evaluation using' -- measured without a net"
        if [ -z "$net" ]; then net=$thisnet
        elif [ "$thisnet" != "$net" ]; then die "$label: the net changed between runs"
        fi

        search_ir+=( $(( total - startup )) )
    done

    # median, min, max
    local sorted median
    sorted=$(printf '%s\n' "${search_ir[@]}" | sort -n)
    median=$(printf '%s\n' "$sorted" | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}')
    echo "$median $nodes $startup $(printf '%s\n' "$sorted" | head -1) $(printf '%s\n' "$sorted" | tail -1) $net"
}

# ---------------------------------------------------------------------- run

MODE=-O3; [ "$PGO" = "1" ] && MODE=PGO
echo "perfbudget: arch=$ARCH comp=$COMP mode=$MODE depth=$DEPTH tt=$TT repeat=$REPEAT tolerance=${TOLERANCE}%"
echo "perfbudget: base=$BASE_REV head=$HEAD_REV"

prepare_tree "$BASE_REV" "$WORK/base"
prepare_tree "$HEAD_REV" "$WORK/head"
build_side   "$WORK/base" base
build_side   "$WORK/head" head

# measure_side runs in a command substitution, so a `die` inside it exits the
# SUBSHELL. Capturing into a variable first is what propagates the status:
# `read x <<< "$(f)"` reports read's status, not f's, so a failed measurement
# would otherwise arrive as empty fields and a green exit -- a gate laundering
# its own failure.
echo "  measuring base ..." >&2
B_OUT=$(measure_side "$WORK/base" base) || exit 1
echo "  measuring head ..." >&2
H_OUT=$(measure_side "$WORK/head" head) || exit 1

read -r B_IR B_NODES B_START B_MIN B_MAX B_NET <<< "$B_OUT"
read -r H_IR H_NODES H_START H_MIN H_MAX H_NET <<< "$H_OUT"
for v in "$B_IR" "$B_NODES" "$B_START" "$B_NET" "$H_IR" "$H_NODES" "$H_START" "$H_NET"; do
    [ -n "$v" ] || die "internal: a measurement field came back empty"
done

echo
printf '%-10s %16s %16s %14s  %s\n' "" "search Ir" "startup Ir" "nodes" "net"
printf '%-10s %16s %16s %14s  %s\n' "base" "$B_IR" "$B_START" "$B_NODES" "$B_NET"
printf '%-10s %16s %16s %14s  %s\n' "head" "$H_IR" "$H_START" "$H_NODES" "$H_NET"
if [ "$REPEAT" -gt 1 ]; then
    printf '%-10s %16s\n' "base range" "$B_MIN .. $B_MAX"
    printf '%-10s %16s\n' "head range" "$H_MIN .. $H_MAX"
fi
echo

if [ "$B_NET" != "$H_NET" ]; then
    echo "perfbudget: VOID -- the two sides loaded different networks"
    echo "  base $B_NET, head $H_NET."
    echo "  A node count and an instruction count are properties of the net as much as"
    echo "  of the search. Put both revisions on the same net before comparing."
    exit 1
fi

if [ "$B_NODES" != "$H_NODES" ]; then
    echo "perfbudget: VOID -- the two sides searched different trees"
    echo "  base $B_NODES nodes, head $H_NODES nodes."
    echo "  An instruction count over a different tree is not comparable. This is a"
    echo "  behaviour change, and tests/signature.sh is the gate that owns it."
    exit 1
fi

DELTA=$(awk -v b="$B_IR" -v h="$H_IR" 'BEGIN{printf "%.4f", (h-b)*100.0/b}')
ABS=$((H_IR - B_IR))

printf 'delta: %+d Ir  (%+.4f%%)\n' "$ABS" "$DELTA"

VERDICT=$(awk -v d="$DELTA" -v t="$TOLERANCE" 'BEGIN{print (d > t) ? "FAIL" : "PASS"}')
if [ "$VERDICT" = "FAIL" ]; then
    echo "perfbudget: FAIL -- regression of ${DELTA}% exceeds the ${TOLERANCE}% tolerance"
    exit 1
fi

IMPROVED=$(awk -v d="$DELTA" -v t="$TOLERANCE" 'BEGIN{print (d < -t) ? "yes" : "no"}')
if [ "$IMPROVED" = "yes" ]; then
    echo "perfbudget: PASS -- improvement of ${DELTA}%"
else
    echo "perfbudget: PASS -- within the ${TOLERANCE}% tolerance"
fi
exit 0
