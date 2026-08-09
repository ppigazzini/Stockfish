#!/bin/bash
# Link the engine ALONE. No platform object, no shell object, a stub main and
# nothing else. Fail on any undefined symbol.
#
# This is the strong form of the boundary check, and it is a different question
# from the one tests/linkcheck.sh asks. That one intersects symbol sets: "does
# any engine object name a symbol some platform object defines?" It cannot see a
# reference to a symbol that nothing in the tree defines, and it cannot see an
# INLINE call at all -- an inlined platform function leaves no symbol reference,
# so both of that gate's baselines read zero while the engine calls it.
#
# The linker closes the first of those: either every symbol an engine object
# needs is resolved by another engine object or by the language runtime, or the
# link fails and names what is missing, whether or not anything else defines it.
#
# It does NOT close the second. An inlined host function emits no symbol either,
# so a link that succeeds says nothing about an inline call reaching the
# platform. That edge belongs to tests/depcheck.sh, which reads includes, and to
# keeping each reader pointed at its seam by hand -- see the clock seam, whose
# header says so.
#
# WHAT COUNTS AS RESOLVED. libstdc++, libc and pthread are the language runtime,
# not host services, so they are allowed to resolve. Everything else must come
# from engine/ itself or from an injection seam's DEFAULT -- and that is what
# this gate is really for: a seam's default is a claim until something links
# without the host that would override it.
#
# IT ALSO RUNS. A link resolves a symbol without ever calling it, so linking
# alone says every seam default is REACHABLE and nothing about whether it works.
# tests/enginelink_main.cpp is the host: it links against engine/ only,
# registers NOTHING, and drives depth-limited searches through Search::go -- so
# the arena's fallback actually allocates, the parallel-for actually clears the
# transposition table inline, the clock is actually read, and the tablebase
# source actually answers "none loaded".
#
# LTO MUST BE OFF, and turning it off is not what it looks like. Under LTO a GCC
# object holds IR; the linker needs the plugin to read it, and WITHOUT the plugin
# `ld` prints "plugin needed to handle lto object" and STILL EXITS 0 -- it links
# a binary that resolved nothing. A gate reading that exit code reports a clean
# standalone engine while the engine calls whatever it likes.
#
# `EXTRACXXFLAGS=-fno-lto` does not turn it off. src/Makefile interpolates
# EXTRACXXFLAGS into its CXXFLAGS assignment, and the per-compiler block below
# that APPENDS `-flto` after it, so the Makefile's flag is last and wins.
# tests/negative_control.sh's `enginelink` row plants a platform call in an
# engine file and fails if this gate stays green.
#
# So this builds through COMPCXX, a wrapper that drops every -flto argument and
# passes the rest through untouched. Every other flag stays exactly what ships,
# which is the point -- the answer is about the real build, not a reduced one.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2
source "$(dirname "${BASH_SOURCE[0]}")/zones.sh"

ARCH=${ARCH:-x86-64-avx2}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
CXX=${CXX:-g++}

command -v "$CXX" >/dev/null || { echo "enginelink: SKIPPED -- no $CXX" >&2; exit 2; }
command -v c++filt >/dev/null || { echo "enginelink: SKIPPED -- no c++filt" >&2; exit 2; }

BUILD=$(mktemp -d) || exit 2
trap 'rm -rf "$BUILD"' EXIT

echo "enginelink: building objects at $ARCH with LTO off ..."
# See the header: this wrapper, not EXTRACXXFLAGS, is what actually disables LTO.
cat > "$BUILD/nolto" <<WRAP
#!/bin/bash
args=()
for a in "\$@"; do
    case "\$a" in
        -flto|-flto=*|-flto-*|-fwhole-program-vtables) ;;
        *) args+=("\$a") ;;
    esac
done
exec $CXX "\${args[@]}"
WRAP
chmod +x "$BUILD/nolto"
# src AND scripts: the Makefile's net target shells out to ../scripts/net.sh.
# The nets are copied into the copied src/, not merely made reachable: the build
# must never touch the network, and `INCBIN(EmbeddedNNUE, EvalFileDefaultName)`
# in engine/nnue/network.cpp embeds the default net through an assembler
# directive whose path resolves against the directory make compiles in.
git ls-files -z src scripts | tar --null -T - -cf - | ( mkdir -p "$BUILD/w" && tar -xf - -C "$BUILD/w" )
cp src/*.nnue "$BUILD/w/src/" 2>/dev/null
if ! ( cd "$BUILD/w/src" && make -j"$JOBS" build ARCH="$ARCH" COMPCXX="$BUILD/nolto" ) \
     > "$BUILD/build.log" 2>&1; then
    echo "enginelink: SKIPPED -- the non-LTO build failed" >&2
    tail -5 "$BUILD/build.log" >&2
    exit 2
fi

# Look the zone up from the STEM: `OBJS = $(notdir ...)` flattens every object
# into src/, so an object name carries no directory to read a zone from.
objs=""
for o in "$BUILD"/w/src/*.o; do
    [ -e "$o" ] || continue
    stem=$(basename "$o" .o)
    [ "$(zone_of "$stem")" = engine ] && objs="$objs $(basename "$o")"
done
[ -n "$objs" ] || { echo "enginelink: SKIPPED -- no engine object was built" >&2; exit 2; }

if grep -q 'plugin needed to handle lto object' "$BUILD/build.log" 2>/dev/null; then
    echo "enginelink: SKIPPED -- objects still hold LTO IR; the link would prove nothing" >&2
    exit 2
fi

n=$(echo $objs | wc -w)
echo
echo "== linking $n engine object(s) with a stub main and nothing else =="

# The host is compiled with the same architecture flags the engine objects were,
# because it includes engine headers whose layout depends on them -- a host built
# at a different ARCH links happily and then disagrees about where the members
# are.
ARCHFLAGS=$(cd "$BUILD/w/src" && make ARCH="$ARCH" config-sanity 2>/dev/null | grep -oE '\-D[A-Za-z0-9_]+|-m[a-z0-9.]+' | tr '\n' ' ')
# Into a tests/ beside src/, because the host includes ../src/engine/... exactly
# as it does in the repo -- compiling it from anywhere else silently changes what
# those relative includes resolve to.
mkdir -p "$BUILD/w/tests"
cp tests/enginelink_main.cpp "$BUILD/w/tests/enginelink_main.cpp"
if ! ( cd "$BUILD/w/tests" && "$CXX" -std=c++17 -O1 -fno-exceptions $ARCHFLAGS -c \
       -o ../src/enginelink_stub.o enginelink_main.cpp ) > "$BUILD/stub.log" 2>&1; then
    echo "enginelink: SKIPPED -- the host would not compile" >&2
    tail -8 "$BUILD/stub.log" >&2
    exit 2
fi

# The exit code decides, not the presence of a matched line. A link can fail for
# reasons that produce no "undefined reference" at all -- a missing embedded net
# fails in the assembler -- and reading only the grep would score that as clean.
( cd "$BUILD/w/src" && "$CXX" -o engine-standalone $objs enginelink_stub.o -lpthread ) \
  > "$BUILD/link.log" 2>&1
rc=$?

# A link that only "succeeded" because ld could not read the objects is not a
# pass. This is the exact false green the header describes.
if grep -q 'plugin needed to handle lto object' "$BUILD/link.log"; then
    echo "enginelink: SKIPPED -- ld could not read the objects (LTO IR)" >&2
    exit 2
fi

if [ "$rc" = 0 ]; then
    echo "  ok -- every symbol resolved by engine/ or the language runtime"
    echo
    echo "== running it, with no seam registered =="
    if ! ls "$BUILD/w/src"/*.nnue >/dev/null 2>&1; then
        echo "enginelink: SKIPPED -- linked, but no net to run it with" >&2
        exit 2
    fi
    # The DIRECTORY: the engine resolves its own default net name inside it.
    if ( cd "$BUILD/w/src" && ./engine-standalone . ) > "$BUILD/run.log" 2>&1; then
        grep -E '^  ' "$BUILD/run.log"
        echo
        echo "enginelink: the engine links alone AND searches with no host"
        echo "enginelink: clean"
        exit 0
    fi
    echo "  the engine linked but did NOT run:"
    tail -12 "$BUILD/run.log" | sed 's/^/    /'
    echo
    echo "enginelink: FINDINGS"
    exit 1
fi

undef=$(grep -oE "undefined reference to \`[^']+'" "$BUILD/link.log" \
        | sed "s/undefined reference to .//;s/.$//" | sort -u)
if [ -n "$undef" ]; then
    echo "  the engine does NOT link alone. Unresolved:"
    printf '%s\n' "$undef" | c++filt | cut -c1-100 | sed 's/^/    /'
    echo
    echo "  Each is a host dependency. Route it through an injection seam -- the"
    echo "  engine declares the hook, EVERY reader in the zone goes through it,"
    echo "  and the host registers before the first search."
else
    echo "  the link failed with no undefined reference. Not a zone violation:"
    tail -10 "$BUILD/link.log" | sed 's/^/    /'
fi

echo
echo "enginelink: FINDINGS"
exit 1
