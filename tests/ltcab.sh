#!/bin/bash
# Paired A/B in the regime a LONG clock reaches: a warm game, at depth.
#
# The seventh axis, and the one the other six structurally cannot cover.
#
# tests/npsab.sh, tests/perfbudget.sh, tests/perfcounters.sh and
# tests/perfdecomp.sh all measure `bench`, and `bench` is a COLD search of an
# unrelated position at depth 8 or 13. A move at 10+0.1 is a different workload
# in three ways at once:
#
#   * it runs at ply 40 of ONE game, on a transposition table every earlier move
#     of that game has already written end to end, and on history, pawn and
#     correction banks those moves populated;
#   * it reaches depth 20 to 25, not 8 or 13;
#   * and the tree it searches is therefore far smaller per ply than a cold
#     one's, because the move ordering it inherits is already good.
#
# A per-node ratio measured in the first regime does not transfer to the second.
# On this tree the difference has a measured shape: the per-node cycle advantage
# of `refish` over its fork point walks from 0.946 at depth 11->13 to 0.984 at
# depth 18->20, and every gate above sits at the end of that range, which is the
# end that overstates the branch. This script measures the other one.
#
# DETERMINISM. The move list is fixed input, every search is `go depth D`, and
# one thread makes the node count a function of the position and the table
# alone. Two binaries that search the same tree MUST report the same node total.
# That equality is the fidelity check -- and it is a stronger one than the bench
# anchor, which only ever visits its own fixed position list from a cold table.
# A run whose node totals differ is VOID, not slow.
#
# --cold sends `ucinewgame` before every move, which throws the table and the
# history bank away and leaves everything else identical. The difference between
# a --cold run and a warm one is what the accumulated state of a game is worth,
# in nodes, at a depth the long clock reaches. It is the one number that says
# how much of a speed advantage a long game can still spend.
#
# Exit codes:  0 ran (read the verdict)   1 void or failed   2 skipped

set -u
set -o pipefail

ARCH=x86-64-avx2
COMP=gcc
PGO=0
HASH=16
DEPTHS=12,16,20
RECORD_DEPTH=14
PLIES=60
ROUNDS=3
JOBS=$(nproc 2>/dev/null || echo 4)
KEEP=0
COLD=0
COUNTERS=0
MOVES=
START=startpos

SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPLAY=$SRC_ROOT/tests/ltcreplay.py
WORK=$(mktemp -d)

usage() {
    cat <<EOF
Usage: $0 [options] <base-rev> [<head-rev>]

Options:
  --arch ARCH     build architecture (default: $ARCH)
  --comp COMP     gcc or clang (default: $COMP)
  --pgo           build both sides with make profile-build -- the binding lane
  --hash MB       Hash for the replay (default: $HASH; fishtest LTC uses 64)
  --depths LIST   comma-separated fixed depths (default: $DEPTHS)
  --plies N       plies of the game to replay (default: $PLIES)
  --record-depth D depth used to RECORD the move list (default: $RECORD_DEPTH)
  --moves FILE    replay this move list instead of recording one
  --start FEN     start position, 'startpos' or a FEN (default: $START)
  --cold          ucinewgame before every move -- the state-value control
  --counters      also count RETIRED INSTRUCTIONS with tests/perf_counters and
                  report them per node, with each binary's own startup measured
                  and subtracted. Instructions are near-deterministic, so that
                  column has no A/A band to fight -- which is the only way this
                  axis resolves a few percent on a box that is not a lab
  --rounds N      paired rounds per depth, order alternating (default: $ROUNDS)
  --jobs N        parallel build jobs (default: $JOBS)
  --keep          keep the build directories and the move list
  -h, --help      this text

A move at 10+0.1 reaches depth 20 to 25 on a modern core; --depths 20,22 is that
regime and --depths 12,13 is the one every other gate in tests/ measures.

Run it on an IDLE box. A background build forfeits the measurement exactly as it
forfeits tests/npsab.sh.
EOF
}

# shellcheck disable=SC2329
cleanup() {
    [ "$KEEP" = "1" ] && { echo "kept: $WORK"; return; }
    for d in "$WORK"/*/; do
        [ -e "$d/.git" ] && git -C "$SRC_ROOT" worktree remove --force "$d" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

die()  { echo "ltcab: $*" >&2; exit 1; }
skip() { echo "ltcab: SKIPPED -- $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH=$2; shift 2 ;;
        --comp) COMP=$2; shift 2 ;;
        --pgo) PGO=1; shift ;;
        --hash) HASH=$2; shift 2 ;;
        --depths) DEPTHS=$2; shift 2 ;;
        --plies) PLIES=$2; shift 2 ;;
        --record-depth) RECORD_DEPTH=$2; shift 2 ;;
        --moves) MOVES=$2; shift 2 ;;
        --start) START=$2; shift 2 ;;
        --cold) COLD=1; shift ;;
        --counters) COUNTERS=1; shift ;;
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

num() {
    case "$2" in
        ''|*[!0-9]*) die "$1 must be a whole number, got '$2'" ;;
    esac
}
num --hash "$HASH"; num --plies "$PLIES"; num --rounds "$ROUNDS"
num --record-depth "$RECORD_DEPTH"; num --jobs "$JOBS"
case "$DEPTHS" in ''|*[!0-9,]*) die "--depths must be a comma-separated list of numbers" ;; esac

# Fewer than three rounds cannot separate a direction from a single reading:
# with one round the A/A band collapses to a point and the straddle test is
# vacuously false, so a direction gets claimed from one sample.
[ "$ROUNDS" -ge 3 ] || die "--rounds must be at least 3"

command -v python3 >/dev/null || skip "no python3"
[ -r "$REPLAY" ] || die "missing $REPLAY"

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

# The build stamp is neutralised on BOTH sides, for the reason tests/npsab.sh
# records: an empty GIT_SHA selects a different branch of engine_version_info,
# so a tar-copied side and a revision side do not compile the same source unless
# both are forced empty.
build_side() {
    local dir=$1 label=$2 target=build
    [ "$PGO" = "1" ] && target=profile-build
    echo "  building $label ($target) ..." >&2
    ( cd "$dir/src" && make -j"$JOBS" "$target" ARCH="$ARCH" COMP="$COMP" \
        GIT_SHA= GIT_DATE= GIT_DIFFINDEX= ) > "$dir/build.log" 2>&1 \
        || { tail -25 "$dir/build.log" >&2; die "$label failed to build"; }
}

# One replay, reported as
#   "nodes ms wall_us fixed_us ir cycles cache_misses branch_misses branches".
# Everything past fixed_us is 0 unless --counters.
run_once() {
    local bin=$1 depth=$2 plies=${3:-$PLIES} out summary counted ir=0 cyc=0 mis=0 bmi=0 bra=0
    local args=(--bin "$bin" --depth "$depth" --hash "$HASH" --threads 1
                --moves "$WORK/game.moves" --plies "$plies" --start "$START")
    [ "$COLD" = "1" ] && args+=(--cold)
    if [ "$COUNTERS" = "1" ]; then
        args+=(--counters "$WORK/perf_counters" --counters-out "$WORK/counters.out")
    fi
    out=$(python3 "$REPLAY" replay "${args[@]}" 2>&1) || {
        echo "$out" | tail -5 >&2; die "replay failed for $bin at depth $depth"
    }
    summary=$(echo "$out" | grep -a '^replay:')
    [ -n "$summary" ] || die "replay produced no summary for $bin at depth $depth"
    if [ "$COUNTERS" = "1" ]; then
        counted=$(echo "$out" | grep -a '^perfcounters:')
        # A multiplexed counter covers only part of the run and reads low without
        # saying so. The harness reports scaled=; refuse the reading rather than
        # quote a fraction of it.
        case "$counted" in
            *scaled=0*) : ;;
            '') die "no counter line -- is tests/perf_counters.cpp buildable?" ;;
            *) die "a counter was multiplexed (scaled=1); the reading covers part of the run" ;;
        esac
        ir=$(echo  "$counted" | sed -E 's/.*instructions=([0-9]+).*/\1/')
        cyc=$(echo "$counted" | sed -E 's/.*cycles=([0-9]+).*/\1/')
        mis=$(echo "$counted" | sed -E 's/.*cache_misses=([0-9]+).*/\1/')
        bmi=$(echo "$counted" | sed -E 's/.*branch_misses=([0-9]+).*/\1/')
        bra=$(echo "$counted" | sed -E 's/.*branches=([0-9]+).*/\1/')
    fi
    echo "$summary" | sed -E 's/.*nodes=([0-9]+) ms=([0-9]+) wall_us=([0-9]+) fixed_us=(-?[0-9]+).*/\1 \2 \3 \4/' \
        | tr -d '\n'
    echo " $ir $cyc $mis $bmi $bra"
}

MODE=-O3; [ "$PGO" = "1" ] && MODE=PGO
echo "ltcab: arch=$ARCH comp=$COMP mode=$MODE hash=$HASH plies=$PLIES rounds=$ROUNDS cold=$COLD"
echo "ltcab: base=$BASE_REV head=$HEAD_REV depths=$DEPTHS"

prepare_tree "$BASE_REV" "$WORK/base"
prepare_tree "$HEAD_REV" "$WORK/head"
build_side   "$WORK/base" base
build_side   "$WORK/head" head

BASE_BIN=$WORK/base/src/stockfish
HEAD_BIN=$WORK/head/src/stockfish

# The move list is RECORDED ONCE, from the base binary, and both sides then
# replay the identical input. Recording per side would hand each engine its own
# game, and two different games are two different workloads -- the comparison
# would be void and would not say so.
if [ -n "$MOVES" ]; then
    [ -r "$MOVES" ] || die "cannot read --moves $MOVES"
    cp "$MOVES" "$WORK/game.moves"
    echo "ltcab: replaying $MOVES ($(wc -w < "$WORK/game.moves") plies)"
else
    echo "ltcab: recording a $PLIES-ply game at depth $RECORD_DEPTH ..."
    python3 "$REPLAY" record --bin "$BASE_BIN" --depth "$RECORD_DEPTH" \
        --plies "$PLIES" --hash "$HASH" --start "$START" > "$WORK/game.moves" \
        || die "could not record a move list"
    [ -s "$WORK/game.moves" ] || die "recorded an empty move list"
fi
[ "$KEEP" = "1" ] && cp "$WORK/game.moves" "$SRC_ROOT/ltcab.moves"

B_FLOOR_IR=0; H_FLOOR_IR=0; B_FLOOR_CYC=0; H_FLOOR_CYC=0
B_FLOOR_MIS=0; H_FLOOR_MIS=0; B_FLOOR_BMI=0; H_FLOOR_BMI=0
B_FLOOR_BRA=0; H_FLOOR_BRA=0
if [ "$COUNTERS" = "1" ]; then
    command -v g++ >/dev/null || skip "--counters needs g++ to build tests/perf_counters"
    P=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo 9)
    [ "$P" -le 2 ] 2>/dev/null || skip "perf_event_paranoid is $P; 2 or lower is required"
    g++ -O2 -std=c++17 -o "$WORK/perf_counters" "$SRC_ROOT/tests/perf_counters.cpp" \
        2>/dev/null || skip "could not build tests/perf_counters"
    # The counters span the whole process, and the two binaries do NOT load the
    # net for the same price -- the branch removed 261 M instructions from
    # startup. Measure each side's floor and subtract it, exactly as
    # tests/perfbudget.sh does, or the ratio describes the loader.
    echo "ltcab: measuring each binary's startup floor ..."
    read -r _ _ _ _ B_FLOOR_IR B_FLOOR_CYC B_FLOOR_MIS B_FLOOR_BMI B_FLOOR_BRA \
        <<< "$(run_once "$BASE_BIN" 1 1)"
    read -r _ _ _ _ H_FLOOR_IR H_FLOOR_CYC H_FLOOR_MIS H_FLOOR_BMI H_FLOOR_BRA \
        <<< "$(run_once "$HEAD_BIN" 1 1)"
    printf 'ltcab: floor base %s Ir / %s cyc,  head %s Ir / %s cyc\n' \
        "$B_FLOOR_IR" "$B_FLOOR_CYC" "$H_FLOOR_IR" "$H_FLOOR_CYC"
fi

# Warm both binaries once. The first run of a cold binary is not a reading.
run_once "$BASE_BIN" 8 > /dev/null || exit 1
run_once "$HEAD_BIN" 8 > /dev/null || exit 1

VOID=0
echo
printf '%-7s %12s %12s %12s %10s %10s %12s\n' \
    "depth" "nodes" "base ms" "head ms" "ratio" "A/A" "fixed us/go"
for depth in ${DEPTHS//,/ }; do
    B_NODES=; H_NODES=
    RATIOS=(); CTRL=(); FIXED=(); BMS=(); HMS=(); IRR=(); CYR=(); BIRN=(); HIRN=()
    BMIS=(); HMIS=(); BBMI=(); HBMI=(); BBRA=(); HBRA=()
    for r in $(seq 1 "$ROUNDS"); do
        if [ $((r % 2)) -eq 1 ]; then
            BO=$(run_once "$BASE_BIN" "$depth") || exit 1
            HO=$(run_once "$HEAD_BIN" "$depth") || exit 1
        else
            HO=$(run_once "$HEAD_BIN" "$depth") || exit 1
            BO=$(run_once "$BASE_BIN" "$depth") || exit 1
        fi
        read -r bn bms _ bfix bir bcyc bmis bbmi bbra <<< "$BO"
        read -r hn hms _ hfix hir hcyc hmis hbmi hbra <<< "$HO"

        # The A/A control pair sits BESIDE the comparison pair it floors, not in
        # a batch of its own: the box's noise floor is a property of its state,
        # and the state after two builds is not the state ten minutes later.
        XO=$(run_once "$BASE_BIN" "$depth") || exit 1
        YO=$(run_once "$BASE_BIN" "$depth") || exit 1
        read -r _ xms _ _ _ _ _ _ _ <<< "$XO"
        read -r _ yms _ _ _ _ _ _ _ <<< "$YO"
        CTRL+=("$(awk -v a="$yms" -v b="$xms" 'BEGIN{printf "%.4f", a/b}')")

        [ -z "$B_NODES" ] && B_NODES=$bn
        [ -z "$H_NODES" ] && H_NODES=$hn
        [ "$bn" = "$B_NODES" ] || die "base node total moved between rounds at depth $depth"
        [ "$hn" = "$H_NODES" ] || die "head node total moved between rounds at depth $depth"
        RATIOS+=("$(awk -v h="$hms" -v b="$bms" 'BEGIN{printf "%.4f", h/b}')")
        BMS+=("$bms"); HMS+=("$hms")
        if [ "$COUNTERS" = "1" ]; then
            IRR+=("$(awk -v h="$hir" -v hf="$H_FLOOR_IR" -v b="$bir" -v bf="$B_FLOOR_IR" \
                        'BEGIN{printf "%.5f", (h-hf)/(b-bf)}')")
            CYR+=("$(awk -v h="$hcyc" -v hf="$H_FLOOR_CYC" -v b="$bcyc" -v bf="$B_FLOOR_CYC" \
                        'BEGIN{printf "%.5f", (h-hf)/(b-bf)}')")
            BIRN+=("$(awk -v b="$bir" -v bf="$B_FLOOR_IR" -v n="$bn" 'BEGIN{printf "%.1f", (b-bf)/n}')")
            HIRN+=("$(awk -v h="$hir" -v hf="$H_FLOOR_IR" -v n="$hn" 'BEGIN{printf "%.1f", (h-hf)/n}')")
            BMIS+=("$(awk -v b="$bmis" -v bf="$B_FLOOR_MIS" -v n="$bn" 'BEGIN{printf "%.3f", (b-bf)/n}')")
            HMIS+=("$(awk -v h="$hmis" -v hf="$H_FLOOR_MIS" -v n="$hn" 'BEGIN{printf "%.3f", (h-hf)/n}')")
            BBMI+=("$(awk -v b="$bbmi" -v bf="$B_FLOOR_BMI" -v n="$bn" 'BEGIN{printf "%.3f", (b-bf)/n}')")
            HBMI+=("$(awk -v h="$hbmi" -v hf="$H_FLOOR_BMI" -v n="$hn" 'BEGIN{printf "%.3f", (h-hf)/n}')")
            BBRA+=("$(awk -v b="$bbra" -v bf="$B_FLOOR_BRA" -v n="$bn" 'BEGIN{printf "%.1f", (b-bf)/n}')")
            HBRA+=("$(awk -v h="$hbra" -v hf="$H_FLOOR_BRA" -v n="$hn" 'BEGIN{printf "%.1f", (h-hf)/n}')")
        fi
        FIXED+=("$(awk -v h="$hfix" -v b="$bfix" -v p="$PLIES" \
                       'BEGIN{printf "%.0f/%.0f", b/p, h/p}')")
    done

    if [ "$B_NODES" != "$H_NODES" ]; then
        echo "ltcab: VOID at depth $depth -- base searched $B_NODES nodes, head $H_NODES." >&2
        echo "ltcab: the two revisions do not search the same tree off the bench list." >&2
        VOID=1
        continue
    fi

    med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
    RMED=$(med "${RATIOS[@]}")
    BMED=$(med "${BMS[@]}"); HMED=$(med "${HMS[@]}")
    CSORT=$(printf '%s\n' "${CTRL[@]}" | sort -n)
    CLO=$(echo "$CSORT" | head -1); CHI=$(echo "$CSORT" | tail -1)
    CBAND=$(awk -v lo="$CLO" -v hi="$CHI" \
        'BEGIN{a=lo-1;if(a<0)a=-a;b=hi-1;if(b<0)b=-b;printf "%.4f",(a>b)?a:b}')
    printf '%-7s %12s %12s %12s %10s %10s %12s\n' \
        "$depth" "$B_NODES" "$BMED" "$HMED" "$RMED" "+/-$CBAND" "${FIXED[0]}"
    printf '%-7s %12s   ratios: %s\n' "" "" "${RATIOS[*]}"
    if [ "$COUNTERS" = "1" ]; then
        printf '%-7s %12s   Ir/node base %s head %s   Ir ratio %s   cyc ratio %s\n' \
            "" "" "$(med "${BIRN[@]}")" "$(med "${HIRN[@]}")" \
            "$(med "${IRR[@]}")" "$(med "${CYR[@]}")"
        printf '%-7s %12s   Ir ratios: %s\n' "" "" "${IRR[*]}"
        # The last-level miss and the mispredict are the two axes an instruction
        # count cannot see, and they are the two a locality or a layout change
        # moves. They are hardware counters, so unlike Ir they are not exactly
        # reproducible -- read the per-node pair, not the fourth decimal.
        bm=$(med "${BMIS[@]}"); hm=$(med "${HMIS[@]}")
        bb=$(med "${BBMI[@]}"); hb=$(med "${HBMI[@]}")
        br=$(med "${BBRA[@]}"); hr=$(med "${HBRA[@]}")
        printf '%-7s %12s   miss/node base %s head %s (%s)   brmiss/node base %s head %s (%s)\n' \
            "" "" "$bm" "$hm" "$(awk -v a="$hm" -v b="$bm" 'BEGIN{printf "%.4f", (b>0)?a/b:0}')" \
            "$bb" "$hb" "$(awk -v a="$hb" -v b="$bb" 'BEGIN{printf "%.4f", (b>0)?a/b:0}')"
        printf '%-7s %12s   branches/node base %s head %s   mispredict rate base %s%% head %s%%\n' \
            "" "" "$br" "$hr" \
            "$(awk -v m="$bb" -v t="$br" 'BEGIN{printf "%.3f", (t>0)?100*m/t:0}')" \
            "$(awk -v m="$hb" -v t="$hr" 'BEGIN{printf "%.3f", (t>0)?100*m/t:0}')"
    fi
done
echo
echo "ltcab: ratio is head/base of summed search milliseconds at an identical node"
echo "ltcab: total, so BELOW 1.000 is head faster. A ratio inside the A/A band has"
echo "ltcab: established no direction. 'fixed us/go' is base/head of the per-go cost"
echo "ltcab: OUTSIDE the engine's own search clock -- position setup and go setup."
echo "ltcab: An A/A band wider than the effect means the run was too SHORT or the box was"
echo "ltcab: busy. A depth-8 replay of 30 plies is a plumbing check, not a reading: use"
echo "ltcab: --depths 18,20,22 --plies 100 on an idle box for a number worth quoting."

[ "$VOID" = "1" ] && exit 1
exit 0
