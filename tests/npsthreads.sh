#!/bin/bash
# How the two revisions SCALE, base against head, across thread counts.
#
# THE GAP THIS FILLS. Every other axis in this tree runs `bench <tt> 1 <depth>`:
# perfbudget.sh, perfcounters.sh, perfdecomp.sh and npsab.sh are all
# single-threaded, and tests/match.sh defaults to Threads 1. A player runs eight
# or sixteen. So nothing here has ever measured the thing that decides real
# speed on a real machine -- whether a change contends worse on the shared last
# level, on the transposition table, or on the counters the manager polls.
#
# WHY THE OTHER AXES CANNOT SIMPLY BE POINTED AT --threads. Every one of them
# refuses a comparison whose node counts differ, and it is right to: a count
# taken over a different tree is not comparable. But a multi-threaded search at
# a FIXED DEPTH is not reproducible even against itself. Measured on this tree,
# three runs of `bench 128 8 10 default depth`:
#
#     4,214,870   4,775,340   4,098,171      <- a 16.5% spread
#
# against a 0.02% tolerance. Every existing gate reports VOID, correctly, and
# learns nothing. The single-threaded run beside it repeats exactly.
#
# WHAT MAKES IT MEASURABLE. Make the node count the INPUT instead of the output.
# With `nodes` as the limit type the search stops on a node budget rather than a
# depth, so the workload is fixed by construction and only the overshoot varies.
# The same three runs at `bench 128 8 3000000 default nodes`:
#
#     147,141,383   147,141,788   147,146,570   <- a 0.0035% spread
#
# That is why this gate takes a node budget and not a depth, and why it carries
# a tolerance where npsab.sh carries an equality: the residue is real, it is
# threads overshooting a shared budget, and it is four orders of magnitude below
# the effect being measured.
#
# WHAT IS ACTUALLY REPORTED. Not the threaded nps ratio -- that conflates
# single-thread speed, which three other axes already measure, with scaling,
# which none of them do. The headline is
#
#     r(T) / r(1)     where r(T) is the median paired nps ratio at T threads
#
# which is identically the ratio of the two sides' scaling efficiencies, with
# the single-thread difference divided out. Below 1.000 means head scales worse.
#
# Exit codes:  0 measured   1 VOID (the workloads differ)   2 skipped

set -u
set -o pipefail

ARCH=x86-64-avx2
COMP=gcc
NODES=1500000        # per position, TOTAL across threads
HASH=256             # MB, FIXED across thread counts -- see below
ROUNDS=3
THREADS=
TOLERANCE=0.5        # percent, on the node total
JOBS=$(nproc 2>/dev/null || echo 4)
KEEP=0

SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
NPROC=$(nproc 2>/dev/null || echo 1)

usage() {
    cat <<EOF
Usage: $0 [options] <base-rev> [<head-rev>]

  <base-rev>   git revision to measure against
  <head-rev>   git revision to measure; default HEAD

Options:
  --arch ARCH     build architecture (default: $ARCH). Never 'native'.
  --comp COMP     gcc or clang (default: $COMP)
  --threads "..." space-separated thread counts (default: 1 and the powers of
                  two up to this host's $NPROC). 1 is always included and is the
                  scaling reference.
  --nodes N       node budget PER POSITION, total across threads (default: $NODES).
                  The limit type is 'nodes', not 'depth': a fixed-depth search
                  is not reproducible above one thread.
  --hash MB       transposition table (default: $HASH). Held FIXED across thread
                  counts on purpose -- a game has one hash size whatever the
                  thread count, and growing it with T would hide exactly the
                  contention this gate exists to find.
  --rounds N      interleaved paired rounds per thread count (default: $ROUNDS)
  --tolerance PCT node-total tolerance (default: $TOLERANCE)
  --jobs N        parallel build jobs (default: $JOBS)
  --keep          keep the build directories
  -h, --help      this text

Run it on an IDLE box, and more so than the other timing gates: at T threads
this gate IS the load, and anything else running steals the cores it is trying
to measure contention on.
EOF
}

# shellcheck disable=SC2329
# invoked by `trap cleanup EXIT INT TERM` below, which shellcheck cannot see
cleanup() {
    [ "$KEEP" = "1" ] && { echo "kept: $WORK"; return; }
    for d in "$WORK"/*/; do
        [ -e "$d/.git" ] && git -C "$SRC_ROOT" worktree remove --force "$d" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

die()  { echo "npsthreads: $*" >&2; exit 1; }
skip() { echo "npsthreads: SKIPPED -- $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch)      ARCH=$2; shift 2 ;;
        --comp)      COMP=$2; shift 2 ;;
        --threads)   THREADS=$2; shift 2 ;;
        --nodes)     NODES=$2; shift 2 ;;
        --hash)      HASH=$2; shift 2 ;;
        --rounds)    ROUNDS=$2; shift 2 ;;
        --tolerance) TOLERANCE=$2; shift 2 ;;
        --jobs)      JOBS=$2; shift 2 ;;
        --keep)      KEEP=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          die "unknown option $1" ;;
        *)           break ;;
    esac
done

[ $# -ge 1 ] || { usage >&2; exit 1; }
BASE_REV=$1
HEAD_REV=${2:-HEAD}

num() { case "$2" in ''|*[!0-9.]*|*.*.*) die "$1 must be a number, got '$2'" ;; esac; }
num --nodes "$NODES"; num --hash "$HASH"; num --rounds "$ROUNDS"; num --jobs "$JOBS"
num --tolerance "$TOLERANCE"
[ "$ROUNDS" -ge 1 ] 2>/dev/null || die "--rounds must be at least 1"

# ARCH=native lowers the NNUE loops to whatever width the compiling host has, so
# two machines reporting the same label ship different binaries and no figure
# taken under it is reproducible anywhere. AGENTS.md carries the rule; this is
# the enforcement.
case "$ARCH" in
    *native*) die "ARCH=native is not a tier; name an enumerated ARCH" ;;
esac

# Default the sweep to 1 and the powers of two this host can actually run. A
# thread count above the core count measures the scheduler, not the engine.
if [ -z "$THREADS" ]; then
    THREADS=1
    t=2
    while [ "$t" -le "$NPROC" ]; do THREADS="$THREADS $t"; t=$((t * 2)); done
fi
# 1 is the scaling reference and every ratio below is divided by it, so it is
# not optional. Prepend rather than reject: a caller asking for "8 16" wants
# those measured, not a usage error.
case " $THREADS " in *" 1 "*) ;; *) THREADS="1 $THREADS" ;; esac
# ASCENDING, and this is load-bearing rather than cosmetic. The reference row is
# read back as the first row of the summary, so `--threads "8 1"` would divide
# every scaling figure by the 8-thread result and report it as efficiency.
# shellcheck disable=SC2086
# the split is deliberate: this expands a LIST into separate arguments
THREADS=$(printf '%s\n' $THREADS | sort -n -u | tr '\n' ' ')

OVER=""
for t in $THREADS; do
    num --threads "$t"
    [ "$t" -ge 1 ] 2>/dev/null || die "--threads must be positive, got '$t'"
    [ "$t" -gt "$NPROC" ] && OVER="$OVER $t"
done

command -v git >/dev/null || skip "no git"

prepare_tree() {  # rev dir
    local rev=$1 dir=$2
    git -C "$SRC_ROOT" worktree add --detach --quiet "$dir" "$rev" \
        || die "could not create a worktree for $rev"
    local n found=0
    for n in "$SRC_ROOT"/src/*.nnue; do
        [ -e "$n" ] || continue
        ln -sf "$n" "$dir/src/$(basename "$n")" && found=1
    done
    [ "$found" = "1" ] || skip "no .nnue in $SRC_ROOT/src -- run 'make net' there first"
}

# Neutralise the build stamp on both sides, for the reason npsab.sh records: an
# empty GIT_SHA selects a different branch of engine_version_info, so two sides
# do not compile the same source unless both are forced empty.
build_side() {
    local dir=$1 label=$2
    echo "  building $label ..." >&2
    ( cd "$dir/src" && make -j"$JOBS" build ARCH="$ARCH" COMP="$COMP" \
        GIT_SHA= GIT_DATE= GIT_DIFFINDEX= ) > "$dir/build.log" 2>&1 \
        || { tail -25 "$dir/build.log" >&2; die "$label failed to build"; }
    [ -x "$dir/src/stockfish" ] || die "$label produced no binary"
}

# One bench at T threads on a node budget -> "nps nodes".
run_once() {  # binary threads
    local bin=$1 t=$2 out nps nodes
    out=$("$bin" bench "$HASH" "$t" "$NODES" default nodes 2>&1)
    nps=$(echo "$out"   | grep -a 'Nodes/second'   | awk -F': *' '{print $2}' | tr -d ' \r')
    nodes=$(echo "$out" | grep -a 'Nodes searched' | awk -F': *' '{print $2}' | tr -d ' \r')
    [ -n "$nps" ] && [ -n "$nodes" ] || die "bench produced no reading at $t threads"
    echo "$nps $nodes"
}

echo "npsthreads: arch=$ARCH comp=$COMP nodes=$NODES/position hash=${HASH}MB rounds=$ROUNDS"
echo "npsthreads: base=$BASE_REV head=$HEAD_REV"
# shellcheck disable=SC2086
# the split is deliberate: this expands a LIST into separate arguments
echo "npsthreads: threads:$(printf ' %s' $THREADS)   host has $NPROC"
[ -n "$OVER" ] && echo "npsthreads: WARNING -- oversubscribed at$OVER; above $NPROC this measures the scheduler"
echo

prepare_tree "$BASE_REV" "$WORK/base"
prepare_tree "$HEAD_REV" "$WORK/head"
build_side   "$WORK/base" base
build_side   "$WORK/head" head

# PIN WHAT IS ABOUT TO BE MEASURED, BY CONTENT. Two revisions cannot produce the
# same binary once the stamp is neutralised on both -- equal hashes mean one side
# was measured twice, which yields a clean, tight, empty ratio of 1.0000.
HB=$(sha256sum "$WORK/base/src/stockfish" | cut -c1-12)
HH=$(sha256sum "$WORK/head/src/stockfish" | cut -c1-12)
echo "  base $HB  head $HH"
if [ "$HB" = "$HH" ]; then
    BR=$(git -C "$SRC_ROOT" rev-parse "$BASE_REV" 2>/dev/null || echo x)
    HR=$(git -C "$SRC_ROOT" rev-parse "$HEAD_REV" 2>/dev/null || echo y)
    [ "$BR" = "$HR" ] || die "both sides are the same binary; one side would be measured twice"
fi

# Warm both binaries at the WIDEST thread count. A cold first run pays the
# thread-pool spin-up and faults in the whole hash, and neither belongs in a
# reading; warming at 1 thread would leave both to be paid inside round 1 of the
# widest sweep, which is the row most likely to be quoted.
# shellcheck disable=SC2086
# the split is deliberate: this expands a LIST into separate arguments
WIDEST=$(printf '%s\n' $THREADS | sort -n | tail -1)
run_once "$WORK/base/src/stockfish" "$WIDEST" > /dev/null || exit 1
run_once "$WORK/head/src/stockfish" "$WIDEST" > /dev/null || exit 1

RC=0
REF_RATIO=
REF_B=
REF_H=
SUMMARY=()

med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

# TWO tests, and a row is decided only by passing BOTH.
#
# Reporting a median beside a spread and a control, and then naming only one of
# them in the verdict, is how a reader talks themselves into a result. This tree
# produced the case on its first run: at 8 threads the median read 1.0283
# against an A/A half-width of 0.0236 -- outside the control, and therefore
# "decided" by that test alone -- while the round-to-round spread ran
# 0.9616 .. 1.0405 and straddled 1.000 twice over. npsab.sh's rule is the
# straddle; this axis needs the straddle AND the control, because a threaded
# round is noisier than a single-threaded one and either test alone passes
# something the other refuses.
verdict_of() {  # median lo hi band -> a sentence
    local m=$1 lo=$2 hi=$3 band=$4
    awk -v m="$m" -v lo="$lo" -v hi="$hi" -v b="$band" 'BEGIN{
        d = m - 1; if (d < 0) d = -d;
        if (lo <= 1.0 && 1.0 <= hi) { print "no direction -- the spread straddles 1.000"; exit }
        if (d <= b) { print "no direction -- inside the A/A control"; exit }
        printf "DECIDED -- head scales %s by %.2f%%\n", (m < 1 ? "WORSE" : "better"), d * 100;
    }'
}

for T in $THREADS; do
    echo
    echo "== $T thread$([ "$T" = 1 ] || echo s) =="
    printf '%-7s %14s %14s %10s %10s %s\n' "round" "base nps" "head nps" "ratio" "A/A" "order"

    RATIOS=(); CTRL=(); BN_LIST=(); HN_LIST=()
    BNPS=(); HNPS=()
    void=0
    for r in $(seq 1 "$ROUNDS"); do
        # Alternate which side runs first: the second slot in a round runs on a
        # hotter core, and at T threads it also runs on a hotter package.
        if [ $((r % 2)) -eq 1 ]; then
            BO=$(run_once "$WORK/base/src/stockfish" "$T") || exit 1
            HO=$(run_once "$WORK/head/src/stockfish" "$T") || exit 1
            order="base,head"
        else
            HO=$(run_once "$WORK/head/src/stockfish" "$T") || exit 1
            BO=$(run_once "$WORK/base/src/stockfish" "$T") || exit 1
            order="head,base"
        fi
        read -r bn bnodes <<< "$BO"
        read -r hn hnodes <<< "$HO"

        # The control pair, adjacent to the pair it floors and the same shape as
        # it. A floor measured at a different temporal separation floors nothing,
        # and at T threads the floor is wider than at one -- which is itself part
        # of the result.
        XO=$(run_once "$WORK/base/src/stockfish" "$T") || exit 1
        YO=$(run_once "$WORK/base/src/stockfish" "$T") || exit 1
        read -r x _ <<< "$XO"; read -r y _ <<< "$YO"
        ctrl=$(awk -v a="$y" -v b="$x" 'BEGIN{printf "%.4f", a/b}')
        CTRL+=("$ctrl")

        BN_LIST+=("$bnodes"); HN_LIST+=("$hnodes")
        BNPS+=("$bn");        HNPS+=("$hn")
        ratio=$(awk -v h="$hn" -v b="$bn" 'BEGIN{printf "%.4f", h/b}')
        RATIOS+=("$ratio")
        printf '%-7s %14s %14s %10s %10s %s\n' "$r" "$bn" "$hn" "$ratio" "$ctrl" "$order"
    done

    # THE WORKLOADS MUST MATCH, and at more than one thread they match to a
    # tolerance rather than exactly. The residue is threads overshooting a shared
    # node budget before they observe it; it is measured at 0.0035% on this tree
    # and the default tolerance is 0.5%. A gate that demanded equality here would
    # VOID every threaded run, which is precisely why no existing one can be used.
    BMIN=$(printf '%s\n' "${BN_LIST[@]}" | sort -n | head -1)
    BMAX=$(printf '%s\n' "${BN_LIST[@]}" | sort -n | tail -1)
    HMIN=$(printf '%s\n' "${HN_LIST[@]}" | sort -n | head -1)
    HMAX=$(printf '%s\n' "${HN_LIST[@]}" | sort -n | tail -1)
    SPAN=$(awk -v a="$BMIN" -v b="$BMAX" -v c="$HMIN" -v d="$HMAX" \
        'BEGIN{lo=a; hi=b; if(c<lo)lo=c; if(d>hi)hi=d; printf "%.4f", (hi-lo)*100.0/lo}')
    if awk -v s="$SPAN" -v t="$TOLERANCE" 'BEGIN{exit !(s > t)}'; then
        echo "  VOID -- the node totals span ${SPAN}%, above the ${TOLERANCE}% tolerance"
        echo "  base $BMIN .. $BMAX, head $HMIN .. $HMAX."
        echo "  A speed ratio over a different amount of work is not comparable."
        RC=1
        void=1
    fi

    MR=$(med "${RATIOS[@]}")
    RLO=$(printf '%s\n' "${RATIOS[@]}" | sort -n | head -1)
    RHI=$(printf '%s\n' "${RATIOS[@]}" | sort -n | tail -1)
    MB=$(med "${BNPS[@]}"); MH=$(med "${HNPS[@]}")
    CLO=$(printf '%s\n' "${CTRL[@]}" | sort -n | head -1)
    CHI=$(printf '%s\n' "${CTRL[@]}" | sort -n | tail -1)
    CBAND=$(awk -v lo="$CLO" -v hi="$CHI" \
        'BEGIN{a=lo-1; if(a<0)a=-a; b=hi-1; if(b<0)b=-b; printf "%.4f", (a>b)?a:b}')

    echo
    printf '  nodes: base %s .. %s, head %s .. %s  (span %s%%)\n' \
        "$BMIN" "$BMAX" "$HMIN" "$HMAX" "$SPAN"
    printf '  A/A control: %.4f .. %.4f   (half-width %.4f from 1.000)\n' "$CLO" "$CHI" "$CBAND"
    printf '  nps ratio:   median %.4f   spread %.4f .. %.4f\n' "$MR" "$RLO" "$RHI"
    VERD=$(verdict_of "$MR" "$RLO" "$RHI" "$CBAND")
    printf '  verdict:     %s\n' "$VERD"

    [ "$void" = 1 ] && continue

    if [ "$T" = "1" ]; then
        REF_RATIO=$MR; REF_B=$MB; REF_H=$MH
        SUMMARY+=("$T $MB $MH $MR 1.0000 1.0000 1.0000 $CBAND|$VERD")
    elif [ -z "$REF_RATIO" ]; then
        # The reference round voided, so there is nothing to divide by. Report
        # the row and withhold the scaling columns rather than inventing them.
        echo "  scaling:     not computable -- the 1-thread reference VOIDed"
        SUMMARY+=("$T $MB $MH $MR - - - $CBAND|$VERD")
    else
        # Scaling efficiency per side, and the only number this gate exists for:
        # their ratio, which is r(T)/r(1) with the single-thread difference the
        # other three axes already measure divided straight out.
        SB=$(awk -v a="$MB" -v b="$REF_B" 'BEGIN{printf "%.4f", a/b}')
        SH=$(awk -v a="$MH" -v b="$REF_H" 'BEGIN{printf "%.4f", a/b}')
        SR=$(awk -v a="$MR" -v b="$REF_RATIO" 'BEGIN{printf "%.4f", a/b}')
        printf '  scaling:     base %sx   head %sx   ratio %s\n' "$SB" "$SH" "$SR"
        SUMMARY+=("$T $MB $MH $MR $SB $SH $SR $CBAND|$VERD")
    fi
done

echo
echo "== summary =="
printf '%-8s %13s %13s %9s %9s %9s %11s %7s  %s\n' \
    "threads" "base nps" "head nps" "nps r(T)" "base sc." "head sc." "r(T)/r(1)" "A/A" "verdict"
DECIDED=0
for row in "${SUMMARY[@]}"; do
    read -r t b h r sb sh sr cb <<< "${row%%|*}"
    v=${row#*|}
    printf '%-8s %13s %13s %9s %9s %9s %11s %7s  %s\n' "$t" "$b" "$h" "$r" "$sb" "$sh" "$sr" "$cb" "$v"
    case "$v" in DECIDED*) DECIDED=$((DECIDED + 1)) ;; esac
done

echo
echo "npsthreads: base=$BASE_REV head=$HEAD_REV"
if [ "$RC" = 1 ]; then
    echo "npsthreads: VOID -- at least one thread count compared different workloads"
    exit 1
fi
cat <<'EOF'
npsthreads: measured -- read r(T)/r(1), not the nps column.

  r(T)/r(1) below 1.000 means head SCALES WORSE than base: it is the ratio of
  the two sides' scaling efficiencies, with the single-thread speed difference
  divided out. The nps columns still carry that difference and three other axes
  already measure it more precisely than this one can.

  A value inside the A/A half-width beside it has established no direction. The
  control widens with thread count on every box; when it is wider than the
  effect, the box is saying the effect is noise.
EOF
exit 0
