#!/bin/bash
# Fuzz the search in-process, against engine objects only, under sanitizers.
#
# tests/fuzz.py's uci harness drives the shipped binary's stdin, so it spends
# most of a mutation's budget in the command parser; this one spends all of it
# in the node body. The two are complementary and neither replaces the other.
#
# WHAT MAKES A FINDING HERE TRUSTWORTHY. The input is a WALK -- each byte picks
# one of the legal moves available -- so every position searched is legal and
# reachable. There is no illegal-board false positive to triage, which is the
# failure mode that makes a fuzzer get switched off.
#
# It links src/engine/ ONLY and registers no seam, exactly as
# tests/enginelink.sh does. Any crash is therefore in the engine, with no host
# to blame.
#
# Requires clang (libFuzzer). It is not built by the shipped Makefile and adds
# nothing to the binary a player runs.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2
source "$(dirname "${BASH_SOURCE[0]}")/zones.sh"

ARCH=${ARCH:-x86-64-avx2}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
SECONDS_TO_RUN=${SECONDS_TO_RUN:-120}
CLANG=${CLANG:-clang++}
CORPUS=${CORPUS:-}

usage() {
    cat <<'EOF'
usage: tests/fuzzsearch.sh [--seconds N] [--arch ARCH] [--jobs N] [--corpus DIR]

  --seconds N   fuzz for N seconds (default 120)
  --arch ARCH   build architecture (default x86-64-avx2)
  --jobs N      parallel build jobs (default: nproc)
  --corpus DIR  keep the corpus here and reuse it next time

A corpus is the fuzzer's memory. Without --corpus every run starts from an empty
one and spends its budget rediscovering the same shallow coverage, so a nightly
job never gets deeper than its first night. With it, each run begins where the
last one stopped. Point it at a cached directory in CI.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_RUN=$2; shift 2 ;;
        --corpus)  CORPUS=$2; shift 2 ;;
        --arch)    ARCH=$2; shift 2 ;;
        --jobs)    JOBS=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "fuzzsearch: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v "$CLANG" >/dev/null || { echo "fuzzsearch: SKIPPED -- no $CLANG (libFuzzer needs clang)" >&2; exit 2; }
echo 'int main(){return 0;}' > /tmp/.fuzzprobe.$$.cpp
if ! "$CLANG" -fsanitize=fuzzer-no-link -c -o /dev/null /tmp/.fuzzprobe.$$.cpp >/dev/null 2>&1; then
    rm -f /tmp/.fuzzprobe.$$.cpp
    echo "fuzzsearch: SKIPPED -- this clang has no libFuzzer" >&2
    exit 2
fi
rm -f /tmp/.fuzzprobe.$$.cpp

BUILD=$(mktemp -d) || exit 2
trap 'rm -rf "$BUILD"' EXIT

echo "fuzzsearch: building the engine at $ARCH with clang, LTO off, sanitized ..."
# The same COMPCXX wrapper tests/enginelink.sh uses, and for the same reason: the
# Makefile appends -flto AFTER EXTRACXXFLAGS, so -fno-lto passed that way is
# ignored, and a fuzzer linked from LTO objects is not a fuzzer.
#
# The sanitizers ride in the same wrapper. -fsanitize=fuzzer-no-link on the
# engine objects gives libFuzzer its coverage instrumentation without giving
# each of them a main.
cat > "$BUILD/fzcxx" <<WRAP
#!/bin/bash
args=()
for a in "\$@"; do
    case "\$a" in
        -flto|-flto=*|-flto-*|-fwhole-program-vtables) ;;
        *) args+=("\$a") ;;
    esac
done
exec $CLANG -fsanitize=fuzzer-no-link,address,undefined -fno-omit-frame-pointer "\${args[@]}"
WRAP
chmod +x "$BUILD/fzcxx"

git ls-files -z src scripts | tar --null -T - -cf - | ( mkdir -p "$BUILD/w" && tar -xf - -C "$BUILD/w" )
cp src/*.nnue "$BUILD/w/src/" 2>/dev/null
if ! ls "$BUILD/w/src"/*.nnue >/dev/null 2>&1; then
    echo "fuzzsearch: SKIPPED -- no net in src/; run 'make net' first" >&2
    exit 2
fi

if ! ( cd "$BUILD/w/src" && make -j"$JOBS" build ARCH="$ARCH" COMP=clang COMPCXX="$BUILD/fzcxx" ) \
     > "$BUILD/build.log" 2>&1; then
    echo "fuzzsearch: SKIPPED -- the sanitized engine build failed" >&2
    tail -8 "$BUILD/build.log" >&2
    exit 2
fi

objs=""
for o in "$BUILD"/w/src/*.o; do
    [ -e "$o" ] || continue
    [ "$(zone_of "$(basename "$o" .o)")" = engine ] && objs="$objs $(basename "$o")"
done
[ -n "$objs" ] || { echo "fuzzsearch: SKIPPED -- no engine object was built" >&2; exit 2; }

mkdir -p "$BUILD/w/tests"
cp tests/fuzz_search.cpp "$BUILD/w/tests/"
# THE DRIVER MUST BE COMPILED WITH THE ENGINE'S OWN FLAGS, not a plausible
# subset. It includes engine headers whose layout depends on -DUSE_AVX2 and
# friends, so a driver built with different ones links happily and then
# disagrees about where the members are -- a fuzzer that reports garbage.
#
# Taken verbatim from the line make actually ran, with the compiler, the -c/-o
# pair and LTO removed. Reconstructing a plausible subset instead risks both a
# flag clang rejects in that position and, worse, a silently different layout.
cxxline=$(grep -m1 -E ' -c -o search\.o engine/search\.cpp$' "$BUILD/build.log")
if [ -z "$cxxline" ]; then
    echo "fuzzsearch: SKIPPED -- could not recover the engine's compile flags" >&2
    exit 2
fi
ENGFLAGS=$(printf '%s' "$cxxline" \
  | sed -E 's/^[^ ]+ //; s/ -c -o [^ ]+ [^ ]+$//; s/-flto[^ ]*//g')

# Compiled from a tests/ beside src/, because the driver includes
# ../src/engine/... exactly as it does in the repo.
if ! ( cd "$BUILD/w/tests" && "$CLANG" $ENGFLAGS \
       -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer \
       -c -o ../src/fuzz_search.o fuzz_search.cpp ) > "$BUILD/drv.log" 2>&1; then
    echo "fuzzsearch: SKIPPED -- the driver would not compile" >&2
    tail -10 "$BUILD/drv.log" >&2
    exit 2
fi

if ! ( cd "$BUILD/w/src" && "$CLANG" -fsanitize=fuzzer,address,undefined \
       -o fuzz-search $objs fuzz_search.o ) > "$BUILD/link.log" 2>&1; then
    echo "fuzzsearch: the fuzzer did not link against engine/ alone:" >&2
    grep -oE "undefined reference to \`[^']+'|undefined symbol: .*" "$BUILD/link.log" \
      | sort -u | head -20 >&2
    tail -5 "$BUILD/link.log" >&2
    exit 1
fi

echo
echo "== fuzzing the search for ${SECONDS_TO_RUN}s (walk + depth-3 search, ASan+UBSan) =="
# A persistent corpus is carried in and out; a temporary one lives and dies with
# the build directory.
if [ -n "$CORPUS" ]; then
    mkdir -p "$CORPUS"
    corpusdir=$(cd "$CORPUS" && pwd)
    echo "  corpus: $corpusdir ($(ls -1 "$corpusdir" 2>/dev/null | wc -l) inputs on entry)"
    ln -s "$corpusdir" "$BUILD/w/src/corpus"
else
    mkdir -p "$BUILD/w/src/corpus"
fi
set +e
# -print_funcs=0 IS NOT COSMETIC, IT IS THE DIFFERENCE BETWEEN FUZZING AND NOT.
# By default libFuzzer symbolizes and prints the new functions each new corpus
# unit reaches. On a statically linked, sanitized engine that llvm-symbolizer
# pass dwarfs an execution, and it is charged to -max_total_time -- so the run
# spends its whole budget symbolizing a handful of inputs and still exits 0.
# The executions guard below is what refuses that as a pass.
( cd "$BUILD/w/src" && SF_FUZZ_NET_DIR=. UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=1 \
  ./fuzz-search corpus -max_total_time="$SECONDS_TO_RUN" -print_final_stats=1 \
  -print_funcs=0 -rss_limit_mb=4096 ) \
  > "$BUILD/run.log" 2>&1
rc=$?
set -e

execs=$(grep -oE 'stat::number_of_executed_units: *[0-9]+' "$BUILD/run.log" | tail -1 | grep -oE '[0-9]+$')
rate=$(grep -oE 'stat::average_exec_per_sec: *[0-9]+' "$BUILD/run.log" | tail -1 | grep -oE '[0-9]+$')
echo "  executions: ${execs:-unknown} (${rate:-?}/s)"

if [ "$rc" != 0 ]; then
    echo
    echo "  FINDING -- the fuzzer stopped with exit $rc:"
    grep -E 'ERROR:|SUMMARY:|runtime error:|Test unit written' "$BUILD/run.log" | head -12 | sed 's/^/    /'
    crash=$(ls "$BUILD/w/src"/crash-* "$BUILD/w/src"/oom-* "$BUILD/w/src"/timeout-* 2>/dev/null | head -1)
    if [ -n "$crash" ]; then
        keep="$ROOT/fuzz-search-$(basename "$crash")"
        cp "$crash" "$keep"
        echo "    reproducer saved: $keep"
        echo "    replay: SF_FUZZ_NET_DIR=src ./fuzz-search $keep"
    fi
    echo
    echo "fuzzsearch: FINDINGS"
    exit 1
fi

# Refuse a "clean" run that executed almost nothing: it is a broken rig, not a
# pass -- the same shape as a gate that SKIPPED being reported green.
if [ -z "$execs" ] || [ "$execs" -lt 1000 ]; then
    echo "fuzzsearch: SKIPPED -- only ${execs:-0} executions; the rig is not fuzzing" >&2
    tail -8 "$BUILD/run.log" >&2
    exit 2
fi

[ -n "$CORPUS" ] && echo "  corpus: $(ls -1 "$CORPUS" 2>/dev/null | wc -l) inputs on exit"

echo
echo "fuzzsearch: no crash, no sanitizer report in ${SECONDS_TO_RUN}s"
echo "fuzzsearch: clean"
exit 0
