#!/bin/bash
# Enforce the declared dependency direction between the three zones of src/.
#
# The stack is shell -> platform -> engine, engine at the bottom. `platform/` is
# not a layer beneath the engine: it is the runtime that HOSTS the engine, so it
# may depend on engine types and not the other way round.
#
# Only one edge is checked, because only one is a defect rather than a choice:
# an engine file that includes a shell header. The engine is the chess library;
# a library that reaches into the process driving it cannot be linked without
# that process, and cannot be reasoned about without reading it.
#
# A zone is a DIRECTORY under src/ (tests/zones.sh). A file added outside all
# three joins no zone, so the unassigned-file check below has to fail on it: a
# file in no zone matches no rule here and would otherwise be silently exempt.
#
# The baseline expires in both directions. A violation not in it fails, and an
# entry in it that no longer happens fails too -- a fixed edge that stays listed
# is how a baseline turns from a debt register into a permanent excuse.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2
BASELINE=tests/depcheck.baseline

source "$(dirname "${BASH_SOURCE[0]}")/zones.sh"

command -v git >/dev/null || { echo "depcheck: SKIPPED -- no git" >&2; exit 2; }

FILES=$(git ls-files 'src/*.h' 'src/*.cpp' 'src/**/*.h' 'src/**/*.cpp')
[ -n "$FILES" ] || { echo "depcheck: SKIPPED -- no sources listed" >&2; exit 2; }

echo "== files with no zone =="
unassigned=0
for f in $FILES; do
    if [ "$(zone_of_path "$f")" = unassigned ]; then
        echo "  UNASSIGNED  $f"
        unassigned=$((unassigned+1))
    fi
done
[ "$unassigned" = 0 ] && echo "  ok"

echo
echo "== engine files that include a shell header =="
violations=$(
for f in $FILES; do
    [ "$(zone_of_path "$f")" = engine ] || continue
    grep -oE '^[[:space:]]*#include "[^"]+"' "$f" 2>/dev/null \
    | sed 's/.*"\(.*\)"/\1/' | while read -r inc; do
        istem=$(basename "$inc"); istem=${istem%.*}
        [ "$(zone_of "$istem")" = shell ] && echo "$(basename "$f") -> $(basename "$inc")"
    done
done | sort -u
)

if [ -f "$BASELINE" ]; then
    known=$(grep -vE '^\s*(#|$)' "$BASELINE" | sort -u)
else
    known=""
fi

new=$(comm -23 <(printf '%s\n' "$violations" | grep -v '^$') <(printf '%s\n' "$known" | grep -v '^$'))
gone=$(comm -13 <(printf '%s\n' "$violations" | grep -v '^$') <(printf '%s\n' "$known" | grep -v '^$'))

n_known=0
[ -n "$known" ] && n_known=$(printf '%s\n' "$known" | grep -c .)
if [ -n "$violations" ]; then
    printf '%s\n' "$violations" | sed 's/^/  known    /' | head -40
fi
[ -n "$violations" ] || echo "  none"

rc=0
echo
echo "== new violations =="
if [ -n "$new" ]; then
    printf '%s\n' "$new" | sed 's/^/  NEW      /'
    rc=1
else
    echo "  ok"
fi

echo
echo "== baseline entries that no longer happen =="
if [ -n "$gone" ]; then
    printf '%s\n' "$gone" | sed 's/^/  STALE    /'
    echo "  remove these from $BASELINE -- a fixed edge listed as debt is an excuse"
    rc=1
else
    echo "  ok"
fi

echo
[ "$unassigned" = 0 ] || { echo "depcheck: $unassigned file(s) in no zone -- add them to a zone list"; rc=1; }
echo "depcheck: $n_known baselined edge(s)"
[ "$rc" = 0 ] && echo "depcheck: clean" || echo "depcheck: FINDINGS"
exit "$rc"
