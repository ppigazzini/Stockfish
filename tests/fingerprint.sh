#!/bin/bash
# Per-function CALL COUNTS between two revisions.
#
# Every other gate here compares VALUES -- a node total, an instruction count,
# a disassembly. This one asks a different question: does the engine still get
# there by calling what it called, as often. A refactor that claims to be a
# decomposition is exactly the change where that can move while every value
# stays put, which is why this is the instrument for splitting a large function.
#
# Why call counts and not cost. A call count is inlining-immune AT THE CALLEE:
# it does not care how the callee was reached, only that it was. That is what
# makes it comparable across two builds whose inlining decisions differ, where a
# cost claim would have to argue attribution first.
#
# It is NOT immune at the CALLER. A function the compiler inlined into its
# caller disappears from the profile entirely, so a symbol vanishing from one
# side is usually an inlining change rather than a deleted call. Read the
# ONLY-IN-ONE-SIDE list as a list of inlining differences, and the CHANGED list
# as the one that carries the signal.
#
# A side that yields no symbol at all is VOID and fails, never equal: two empty
# profiles compare identical, so a rig that profiled nothing would otherwise
# report the strongest result this gate can give.
#
# Only symbols carrying `Stockfish` are in the verdict. The allocator and the
# thread runtime move with the environment rather than with the code, and are
# printed apart from it.
#
# callgrind simulates rather than samples, so the counts are deterministic --
# for every symbol whose call count is a function of the PROGRAM. One class is
# not: a symbol reached from a wall-clock branch is called a number of times
# that depends on how long the run took, and under callgrind that is roughly
# 50x real time and varies with machine load. Those are listed below the verdict
# rather than inside it; see CLOCK_DRIVEN.
#
# Exit codes:  0 no call-count change   1 changed or void   2 skipped

set -u
set -o pipefail

ARCH=x86-64-avx2
COMP=gcc
DEPTH=8
TT=16
TOP=25
SYZYGY=
DEPTH_GIVEN=0
KEEP=0
JOBS=$(nproc 2>/dev/null || echo 4)

SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)

usage() {
    cat <<EOF
Usage: $0 [options] <base-rev> [<head-rev>]

  <base-rev>   git revision to compare against
  <head-rev>   git revision to compare; default HEAD.
               The literal 'worktree' compares the current working tree.

Options:
  --arch ARCH   build architecture (default: $ARCH)
  --comp COMP   compiler (default: $COMP)
  --depth D     bench depth (default: $DEPTH, or 14 with --syzygy)
  --tt MB       bench hash size (default: $TT)
  --syzygy DIR  profile a PROBING workload instead of the bench list, with
                SyzygyPath pointed at DIR. The bench list never probes, so
                without this every call inside the tablebase reader is absent
                from the fingerprint and a seam routed through decompress_pairs
                shows no call-count change at all. An empty DIR SKIPS.
  --top N       how many changed symbols to list (default: $TOP)
  --jobs N      parallel build jobs (default: $JOBS)
  --keep        keep the build directories and the extracted counts
  -h, --help    this text
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

die()  { echo "fingerprint: $*" >&2; exit 1; }
skip() { echo "fingerprint: SKIPPED -- $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH=$2; shift 2 ;;
        --comp) COMP=$2; shift 2 ;;
        --depth) DEPTH=$2; DEPTH_GIVEN=1; shift 2 ;;
        --syzygy) SYZYGY=$2; shift 2 ;;
        --tt) TT=$2; shift 2 ;;
        --top) TOP=$2; shift 2 ;;
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

num() { case "$2" in ''|*[!0-9]*) die "$1 must be a number, got '$2'" ;; esac; }
# A probing run wants depth, not breadth: the positions are four men and the
# search converges early, so a depth-8 run barely reaches the reader it exists
# to measure. Only the DEFAULT moves; --depth still wins. Keep this the same
# number tests/perfbudget.sh uses, so a call count from this gate and an
# instruction count from that one describe one workload rather than two.
[ -n "$SYZYGY" ] && [ "$DEPTH_GIVEN" = "0" ] && DEPTH=14

num --depth "$DEPTH"; num --tt "$TT"; num --top "$TOP"; num --jobs "$JOBS"

command -v valgrind >/dev/null || skip "valgrind is not installed"
case "$ARCH" in
    *avx512*|*vnni*) skip "callgrind implements no AVX-512; ARCH=$ARCH cannot be measured" ;;
esac

# ------------------------------------------------------- the probing workload
#
# BENCH_ARGS is empty for the default list and names a file for --syzygy. The
# file is assembled here rather than committed, because its first line has to
# name a directory only the caller knows, and a committed absolute path is a
# file that works on exactly one machine.
#
# An empty or missing corpus SKIPS. It must not pass: a probing profile taken
# with no tables loaded is the bench list wearing a different name, and a gate
# that reports "no call-count change" over a reader it never entered is the
# strongest wrong answer this instrument can give.
#
# WHAT IS IN THE PROFILE THAT IS NOT THE SEARCH. The SyzygyPath line runs as the
# first bench command, so mapping the tables is INSIDE the measured region;
# tests/perfbudget.sh subtracts it through a startup probe and this gate has
# nothing to subtract, because a call count is not a difference of two totals.
# So a change to the table LOADER moves counts here too. That is a real change
# and not noise -- but read a moved count against both readers, not against
# decompress_pairs alone.
BENCH_ARGS=()
if [ -n "$SYZYGY" ]; then
    # Resolve into a second name: assigning to SYZYGY first would leave the
    # diagnostic below naming the empty string it just became.
    SYZYGY_ABS=$(cd "$SYZYGY" 2>/dev/null && pwd) \
        || skip "--syzygy: no such directory: $SYZYGY"
    SYZYGY=$SYZYGY_ABS
    ls "$SYZYGY"/*.rtbw >/dev/null 2>&1 \
        || skip "--syzygy: no .rtbw in $SYZYGY -- run tests/tbfetch.sh"
    FENS=$SRC_ROOT/tests/tbprobe.fens
    [ -f "$FENS" ] || skip "--syzygy: $FENS is missing"

    BENCH_FILE=$WORK/tbprobe.bench
    {
        echo "setoption name SyzygyPath value $SYZYGY"
        grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$FENS"
    } > "$BENCH_FILE"
    [ "$(grep -cve '^setoption' "$BENCH_FILE")" != "0" ] \
        || skip "--syzygy: $FENS holds no positions"

    BENCH_ARGS=( "$BENCH_FILE" depth )
fi

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

# The build stamp is neutralised on BOTH sides, for the reason tests/textequal.sh
# has documented since it was written and a868d607 fixed in perfbudget.sh and
# npsab.sh. misc.o is compiled with -DGIT_SHA=<sha> -DGIT_DATE=<date>
# -DGIT_DIFFINDEX=<n>, and an empty GIT_SHA selects a DIFFERENT branch of
# engine_version_info -- so under LTO the stamp moves inlining decisions
# elsewhere in the binary and a CALL COUNT moves with them.
#
# This gate reached both build paths asymmetrically and nothing here noticed.
# `prepare_tree` builds a revision with `git worktree add`, which carries .git and
# therefore a populated stamp, and builds `worktree` from a tar copy that
# EXCLUDES .git, which stamps empty. Same revision down both paths produces
# different binaries:
#
#   git worktree:  .build_sha.txt = <sha>
#   tar copy:      .build_sha.txt = (empty)
#
# A two-revision comparison could not see it -- both sides get a populated stamp,
# and a docs-only pair (f0b87a46 -> a16f4beb, identical src/) reports IDENTICAL.
# Only `worktree` mode was contaminated, which is the mode a developer uses on
# uncommitted work, and it reported partial_insertion_sort at 91487 -> 35884 calls
# for a change that altered neither that function nor its three call sites.
build_side() {
    local dir=$1 label=$2
    echo "  building $label (build stamp neutralised) ..." >&2
    ( cd "$dir/src" && make -j"$JOBS" build ARCH="$ARCH" COMP="$COMP" \
        GIT_SHA= GIT_DATE= GIT_DIFFINDEX= ) \
        > "$dir/build.log" 2>&1 \
        || { tail -25 "$dir/build.log" >&2; die "$label failed to build"; }
    [ -x "$dir/src/stockfish" ] || die "$label produced no binary"
}

# callgrind names each called function on a `cfn=` line and the count on the
# `calls=` line immediately after. Names are interned and ONE id space is shared
# between `fn=` (the function being executed) and `cfn=` (a function it calls):
# `fn=(12) name` defines id 12, and a later bare `cfn=(12)` refers back to it.
# So the name table must be built from BOTH line kinds. A parser that records
# only `cfn=` definitions loses every call whose id was first defined by an
# `fn=` line, and which ids those are depends on the order the profile reaches
# them -- which thread scheduling perturbs, so two runs of the SAME binary then
# report different call graphs.
extract_calls() {
    local cg=$1 out=$2
    python3 - "$cg" "$out" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
names, counts, pending = {}, {}, None
define = re.compile(r'^(?:c?fn)=\((\d+)\)(?:\s+(.*))?$')
for line in open(src, encoding="utf8", errors="replace"):
    line = line.rstrip('\n')
    m = define.match(line)
    if m:
        fid, nm = m.group(1), m.group(2)
        if nm:
            names[fid] = nm
        # Only a `cfn=` names a CALLEE; an `fn=` just defines the current
        # function and must not arm the pending counter.
        pending = names.get(fid) if line.startswith('cfn=') else None
        # An unnamed function is reported by ADDRESS, and two builds place it
        # differently, so it has no comparable identity.
        if pending is not None and re.fullmatch(r'0x[0-9a-fA-F]+', pending):
            pending = None
        continue
    if pending is not None and line.startswith('calls='):
        counts[pending] = counts.get(pending, 0) + int(line.split('=', 1)[1].split()[0])
        pending = None
with open(dst, 'w', encoding='utf8') as fh:
    for k in sorted(counts):
        fh.write(f"{counts[k]}\t{k}\n")
PYEOF
    [ -s "$out" ] || die "no call counts extracted from $cg"
}

measure_side() {
    local dir=$1 label=$2
    valgrind --tool=callgrind --callgrind-out-file="$dir/cg.out" \
             --cache-sim=no --branch-sim=no \
             "$dir/src/stockfish" bench "$TT" 1 "$DEPTH" "${BENCH_ARGS[@]}" \
             > "$dir/bench.stdout" 2> "$dir/bench.stderr"
    local n net
    n=$(grep -a 'Nodes searched' "$dir/bench.stderr" | awk -F': *' '{print $2}' | tr -d ' \r')
    net=$(grep -ao 'NNUE evaluation using [^ ]*' "$dir/bench.stdout" | head -1 | awk '{print $4}')
    [ -n "$n" ] || die "$label: bench produced no node count"
    [ -n "$net" ] || die "$label: bench announced no network"
    extract_calls "$dir/cg.out" "$dir/calls.txt"
    echo "$n $net"
}

echo "fingerprint: arch=$ARCH comp=$COMP depth=$DEPTH tt=$TT workload=${SYZYGY:+probing }${SYZYGY:-bench-list}"
echo "fingerprint: base=$BASE_REV head=$HEAD_REV"

prepare_tree "$BASE_REV" "$WORK/base"
prepare_tree "$HEAD_REV" "$WORK/head"
build_side   "$WORK/base" base
build_side   "$WORK/head" head

echo "  profiling base ..." >&2
B_OUT=$(measure_side "$WORK/base" base) || exit 1
echo "  profiling head ..." >&2
H_OUT=$(measure_side "$WORK/head" head) || exit 1
read -r B_NODES B_NET <<< "$B_OUT"
read -r H_NODES H_NET <<< "$H_OUT"

if [ "$B_NET" != "$H_NET" ]; then
    echo "fingerprint: VOID -- the two sides loaded different networks"
    echo "  base $B_NET, head $H_NET."
    exit 1
fi
if [ "$B_NODES" != "$H_NODES" ]; then
    echo "fingerprint: VOID -- base searched $B_NODES nodes, head $H_NODES."
    echo "  A call-count comparison over a different tree is not comparable."
    exit 1
fi

B_SYM=$(wc -l < "$WORK/base/calls.txt")
H_SYM=$(wc -l < "$WORK/head/calls.txt")
echo
printf '%-8s %10s %14s\n' "" "symbols" "total calls"
printf '%-8s %10s %14s\n' "base" "$B_SYM" "$(awk -F'\t' '{s+=$1} END{print s}' "$WORK/base/calls.txt")"
printf '%-8s %10s %14s\n' "head" "$H_SYM" "$(awk -F'\t' '{s+=$1} END{print s}' "$WORK/head/calls.txt")"
echo

# A comparison that compared nothing must not pass.
[ "$B_SYM" -gt 0 ] && [ "$H_SYM" -gt 0 ] \
    || die "one side produced no symbols -- the comparison is void, not equal"

python3 - "$WORK/base/calls.txt" "$WORK/head/calls.txt" "$TOP" <<'PY'
import sys
def load(p):
    d = {}
    for line in open(p, encoding='utf8'):
        c, n = line.rstrip('\n').split('\t', 1)
        d[n] = int(c)
    return d
b, h, top = load(sys.argv[1]), load(sys.argv[2]), int(sys.argv[3])
# Keep the unfiltered maps: the clock-driven report prints counts for symbols
# the filters below remove from b and h.
b_all, h_all = dict(b), dict(h)

# The subject is the engine's own call graph. libc's allocator and glibc's
# thread-cancellation counters move with the environment rather than with the
# code -- _int_malloc, sbrk, munmap and the pthread cancel pair all differ
# between two runs of one binary -- so they are reported apart from the verdict.
def engine(k): return 'Stockfish' in k

# AND ONE ENGINE SYMBOL IS NOT A FUNCTION OF THE PROGRAM EITHER.
# SearchManager::check_time fires the debug dump on `tick - lastInfoTime >= 1000`
# -- a WALL-CLOCK millisecond count, not a node count -- so dbg_print is called
# once per second of real elapsed time. callgrind runs the engine roughly 50x
# slower than the metal and the factor moves with machine load, so the count
# differs between two runs of ONE binary. An A/A on a probing workload reports
# it as a changed call count, which is the strongest wrong answer this gate can
# give: it is the same binary twice.
#
# The bench list at depth 8 is short enough to hide this; a --syzygy run at
# depth 14 is not. Listing it apart is not a silent cap -- it is printed below
# with its count, so a reader sees what was set aside.
#
# ADD A SYMBOL HERE ONLY IF ITS COUNT IS DRIVEN BY THE CLOCK. The test is not
# "it moved in an A/A" -- that is the symptom every real defect also has. It is
# whether the call sits under a branch on elapsed TIME rather than on nodes,
# depth or position.
CLOCK_DRIVEN = {'Stockfish::dbg_print()'}
def clock_driven(k): return k in CLOCK_DRIVEN

clock_changed = sorted((k for k in b.keys() & h.keys()
                        if b[k] != h[k] and clock_driven(k)))
env_changed = sorted((k for k in b.keys() & h.keys() if b[k] != h[k] and not engine(k)))
b = {k: v for k, v in b.items() if engine(k) and not clock_driven(k)}
h = {k: v for k, v in h.items() if engine(k) and not clock_driven(k)}
changed = sorted(((abs(h[k] - b[k]), k, b[k], h[k]) for k in b.keys() & h.keys() if b[k] != h[k]),
                 reverse=True)
only_b = sorted(b.keys() - h.keys())
only_h = sorted(h.keys() - b.keys())

if changed:
    print(f"CHANGED call counts ({len(changed)} symbol(s), top {min(top,len(changed))}):")
    for _, k, x, y in changed[:top]:
        print(f"  {x:>12} -> {y:<12} {y-x:+d}  {k[:80]}")
    print()
if only_b or only_h:
    print(f"ONLY IN ONE SIDE -- usually an inlining difference, not a deleted call")
    for k in only_b[:top]:
        print(f"  base only  {b[k]:>10}  {k[:80]}")
    for k in only_h[:top]:
        print(f"  head only  {h[k]:>10}  {k[:80]}")
    print()

if clock_changed:
    print(f"clock-driven ({len(clock_changed)} symbol(s)): called once per second of REAL")
    print(f"  elapsed time, so the count tracks how long callgrind took; not part of")
    print(f"  the verdict")
    for k in clock_changed:
        print(f"  {b_all[k]:>12} -> {h_all[k]:<12} {h_all[k]-b_all[k]:+d}  {k[:80]}")
    print()

if env_changed:
    print(f"outside the engine ({len(env_changed)} symbol(s)): allocator and thread-runtime")
    print(f"  counts move with the environment, not the code; not part of the verdict")
    print()

if not changed and not only_b and not only_h:
    print(f"fingerprint: IDENTICAL -- {len(b)} engine symbols, every call count equal")
    sys.exit(0)
print("fingerprint: CALL GRAPH MOVED")
print("  For a refactor this is the finding: the engine reaches its answer by")
print("  calling something a different number of times. For a change that")
print("  deliberately moves code between functions, read the one-sided list as")
print("  inlining and the changed list as the signal.")
sys.exit(1)
PY
