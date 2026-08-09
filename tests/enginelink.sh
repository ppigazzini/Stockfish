#!/bin/bash
# Link the engine ALONE. No platform object, no shell object, a stub main and
# nothing else. Fail on any undefined symbol.
#
# This is the strong form of the boundary check, and it is a different question
# from the one tests/linkcheck.sh asks. That one intersects symbol sets: "does
# any engine object name a symbol some platform object defines?" It cannot see a
# reference to a symbol that nothing in the tree defines, and it cannot see an
# inline call at all -- the platform clock was reached by three inline calls
# while both baselines read zero.
#
# The linker's question has neither blind spot. Either every symbol an engine
# object needs is resolved by another engine object or by the language runtime,
# or the link fails and names what is missing.
#
# WHAT COUNTS AS RESOLVED. libstdc++, libc and pthread are the language runtime,
# not host services, so they are allowed to resolve. Everything else must come
# from engine/ itself or from an injection seam's DEFAULT -- and that is what
# this gate is really for: a seam's default is a claim until something links
# without the host that would override it.
#
# WHAT IT STILL DOES NOT PROVE. That the defaults RUN. A link resolves the
# symbol; it does not call it. An in-process smoke test that searches with no
# host registered is the next step, and it is not this script.
#
# LTO MUST BE OFF, and turning it off is not what it looks like. Under LTO a GCC
# object holds IR; the linker needs the plugin to read it, and WITHOUT the plugin
# `ld` prints "plugin needed to handle lto object" and STILL EXITS 0 -- it links
# a binary that resolved nothing. A gate reading that exit code reports a clean
# standalone engine while the engine calls whatever it likes.
#
# `EXTRACXXFLAGS=-fno-lto` does not turn it off. src/Makefile:502 interpolates
# EXTRACXXFLAGS into CXXFLAGS and then APPENDS `-flto` at line 964, so the
# Makefile's flag is last and wins. That was found here by a negative control:
# an engine file calling aligned_large_pages_free linked clean.
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
# The nets are copied in so the build never reaches the network, and they must
# be present at LINK time too -- incbin embeds one through an .s file that opens
# it relative to the working directory.
git ls-files -z src scripts | tar --null -T - -cf - | ( mkdir -p "$BUILD/w" && tar -xf - -C "$BUILD/w" )
cp src/*.nnue "$BUILD/w/src/" 2>/dev/null
if ! ( cd "$BUILD/w/src" && make -j"$JOBS" build ARCH="$ARCH" COMPCXX="$BUILD/nolto" ) \
     > "$BUILD/build.log" 2>&1; then
    echo "enginelink: SKIPPED -- the non-LTO build failed" >&2
    tail -5 "$BUILD/build.log" >&2
    exit 2
fi

# Objects are flattened by notdir, so a zone is looked up from the stem.
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

printf 'int main() { return 0; }\n' > "$BUILD/w/src/enginelink_stub.cpp"
if ! ( cd "$BUILD/w/src" && "$CXX" -c -o enginelink_stub.o enginelink_stub.cpp ) \
     > "$BUILD/stub.log" 2>&1; then
    echo "enginelink: SKIPPED -- the stub would not compile" >&2
    tail -5 "$BUILD/stub.log" >&2
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
    echo "enginelink: the engine links alone"
    echo "enginelink: clean"
    exit 0
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
