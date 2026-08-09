#!/bin/bash
# Enforce the dependency direction at the LINK, not at the include.
#
# tests/depcheck.sh reads `#include` lines. That misses every edge an include
# does not spell: a shell type reached through a template parameter, a shell
# symbol reached transitively through a platform header, a function whose
# declaration arrives from somewhere the grep does not attribute to the shell.
# This one asks the linker's question instead -- does any object compiled from
# an engine file reference a symbol that only a shell object defines?
#
# The sibling C port does this by linking its engine alone against an empty
# baseline and failing on any undefined symbol. That is stronger and is not
# available here: src/ is one flat directory with one link step, and the engine
# genuinely calls into the platform, so "any undefined symbol" would be every
# symbol. The reachable version is the pairwise one -- engine objects against
# shell-defined symbols -- with a baseline for what exists today.
#
# Built with LTO OFF on purpose: under LTO the object holds IR and the symbol
# table is not the one the final link resolves. That makes this a statement
# about the non-LTO build, which is the honest limit and is stated in the docs.
#
# `EXTRACXXFLAGS=-fno-lto` CANNOT turn LTO off. src/Makefile:502 interpolates
# EXTRACXXFLAGS into CXXFLAGS and line 964 APPENDS `-flto` after it, so the
# Makefile's flag is last and wins and the objects hold IR. Build through
# COMPCXX, a wrapper that drops every -flto argument and passes the rest through.
#
# This check would answer correctly even on LTO objects, because GCC writes a
# plugin-readable symbol table into one and `nm` reads it. tests/enginelink.sh
# would not: `ld` without the plugin cannot resolve them, warns, and still exits
# 0. Keep the two consistent -- they share the wrapper for that reason.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2
source "$(dirname "${BASH_SOURCE[0]}")/zones.sh"

BASELINE=tests/linkcheck.baseline
BASELINE_PLATFORM=tests/linkcheck-platform.baseline
ARCH=${ARCH:-x86-64-avx2}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}

command -v nm >/dev/null || { echo "linkcheck: SKIPPED -- no nm" >&2; exit 2; }
command -v c++filt >/dev/null || { echo "linkcheck: SKIPPED -- no c++filt" >&2; exit 2; }

BUILD=$(mktemp -d) || exit 2
trap 'rm -rf "$BUILD"' EXIT

echo "linkcheck: building objects at $ARCH with LTO off ..."
# See the header: this wrapper, not EXTRACXXFLAGS, is what actually disables LTO.
CXXBIN=${CXX:-g++}
cat > "$BUILD/nolto" <<WRAP
#!/bin/bash
args=()
for a in "\$@"; do
    case "\$a" in
        -flto|-flto=*|-flto-*|-fwhole-program-vtables) ;;
        *) args+=("\$a") ;;
    esac
done
exec $CXXBIN "\${args[@]}"
WRAP
chmod +x "$BUILD/nolto"
# src AND scripts: the Makefile's net target shells out to ../scripts/net.sh,
# and the nets are copied in so the build never reaches the network.
git ls-files -z src scripts | tar --null -T - -cf - | ( mkdir -p "$BUILD/w" && tar -xf - -C "$BUILD/w" )
cp src/*.nnue "$BUILD/w/src/" 2>/dev/null
if ! ( cd "$BUILD/w/src" && make -j"$JOBS" build ARCH="$ARCH" COMPCXX="$BUILD/nolto" ) \
     > "$BUILD/build.log" 2>&1; then
    echo "linkcheck: SKIPPED -- the non-LTO build failed" >&2
    tail -5 "$BUILD/build.log" >&2
    exit 2
fi

OBJ=$(cd "$BUILD/w/src" && find . -name '*.o' | sed 's|^\./||')
[ -n "$OBJ" ] || { echo "linkcheck: SKIPPED -- the build left no objects" >&2; exit 2; }

# Symbols each shell object DEFINES. `nm --defined-only` lists them; the zone of
# an object is the zone of its source stem.
shell_defs="$BUILD/shell.defs"
plat_defs="$BUILD/plat.defs"
: > "$shell_defs"
: > "$plat_defs"
engine_objs=""
for o in $OBJ; do
    stem=$(basename "$o" .o)
    case "$(zone_of "$stem")" in
        shell)    nm --defined-only "$BUILD/w/src/$o" | awk '{print $3}' >> "$shell_defs" ;;
        platform) nm --defined-only "$BUILD/w/src/$o" | awk '{print $3}' >> "$plat_defs" ;;
        engine)   engine_objs="$engine_objs $o" ;;
    esac
done
sort -u -o "$shell_defs" "$shell_defs"
sort -u -o "$plat_defs" "$plat_defs"

[ -s "$shell_defs" ] || { echo "linkcheck: SKIPPED -- no shell object defined anything" >&2; exit 2; }
[ -n "$engine_objs" ] || { echo "linkcheck: SKIPPED -- no engine object was built" >&2; exit 2; }

echo
echo "== engine objects referencing a shell-defined symbol =="
found="$BUILD/found"
: > "$found"
for o in $engine_objs; do
    nm -u "$BUILD/w/src/$o" | awk '{print $2}' | sort -u > "$BUILD/u"
    comm -12 "$BUILD/u" "$shell_defs" | while read -r sym; do
        printf '%s %s\n' "$(basename "$o")" "$sym" >> "$found"
    done
done
sort -u -o "$found" "$found"

known=""
[ -f "$BASELINE" ] && known=$(grep -vE '^\s*(#|$)' "$BASELINE" | sort -u)

new=$(comm -23 <(cut -d' ' -f1,2 "$found") <(printf '%s\n' "$known" | grep -v '^$'))
gone=$(comm -13 <(cut -d' ' -f1,2 "$found") <(printf '%s\n' "$known" | grep -v '^$'))

n=$(grep -c . "$found" || true)
if [ "$n" -gt 0 ]; then
    while read -r obj sym; do
        printf '  %-22s %s\n' "$obj" "$(echo "$sym" | c++filt | cut -c1-90)"
    done < "$found"
else
    echo "  none"
fi

rc=0
echo
echo "== new =="
if [ -n "$new" ]; then
    printf '%s\n' "$new" | while read -r obj sym; do
        printf '  NEW    %-22s %s\n' "$obj" "$(echo "$sym" | c++filt | cut -c1-90)"
    done
    rc=1
else
    echo "  ok"
fi

echo
echo "== baseline entries that no longer happen =="
if [ -n "$gone" ]; then
    printf '%s\n' "$gone" | sed 's/^/  STALE  /'
    echo "  remove these from $BASELINE"
    rc=1
else
    echo "  ok"
fi

# The engine-to-PLATFORM edge. The declared stack says the engine depends on
# nothing outside itself, so this is a violation too -- and it is the one that
# decides whether engine/ can be linked alone. It is reported separately because
# its baseline is large and closing it is a different piece of work: the shell
# edge needed a value snapshot, this one needs injection seams for the tablebase
# prober and the NUMA topology.
echo
echo "== engine objects referencing a platform-defined symbol =="
pfound="$BUILD/pfound"
: > "$pfound"
for o in $engine_objs; do
    nm -u "$BUILD/w/src/$o" | awk '{print $2}' | sort -u > "$BUILD/pu"
    comm -12 "$BUILD/pu" "$plat_defs" | while read -r sym; do
        printf '%s %s\n' "$(basename "$o")" "$sym" >> "$pfound"
    done
done
sort -u -o "$pfound" "$pfound"
pknown=""
[ -f "$BASELINE_PLATFORM" ] && pknown=$(grep -vE '^\s*(#|$)' "$BASELINE_PLATFORM" | sort -u)
pnew=$(comm -23 <(cut -d' ' -f1,2 "$pfound") <(printf '%s\n' "$pknown" | grep -v '^$'))
pgone=$(comm -13 <(cut -d' ' -f1,2 "$pfound") <(printf '%s\n' "$pknown" | grep -v '^$'))
pn=$(grep -c . "$pfound" || true)
echo "  $pn reference(s), $(printf '%s\n' "$pknown" | grep -c . || true) baselined"
if [ -n "$pnew" ]; then
    printf '%s\n' "$pnew" | while read -r obj sym; do
        printf '  NEW    %-22s %s\n' "$obj" "$(echo "$sym" | c++filt | cut -c1-90)"
    done
    rc=1
fi
if [ -n "$pgone" ]; then
    printf '%s\n' "$pgone" | sed 's/^/  STALE  /'
    echo "  remove these from $BASELINE_PLATFORM"
    rc=1
fi

echo
echo "linkcheck: $n engine-to-shell symbol reference(s), $(printf '%s\n' "$known" | grep -c . || true) baselined"
[ "$rc" = 0 ] && echo "linkcheck: clean" || echo "linkcheck: FINDINGS"
exit "$rc"
