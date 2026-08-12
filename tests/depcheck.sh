#!/bin/bash
# Enforce the declared dependency direction between the three zones of src/.
#
# The stack is shell -> platform -> engine, engine at the bottom. `platform/` is
# not a layer beneath the engine: it is the runtime that HOSTS the engine, so it
# may depend on engine types and not the other way round.
#
# TWO edges are checked, both out of the engine, because both are defects rather
# than choices: an engine file that includes a SHELL header, and one that includes
# a PLATFORM header. The engine is the chess library; a library that reaches into
# the process driving it cannot be linked without that process, and cannot be
# reasoned about without reading it.
#
# The platform rule exists because tests/linkcheck.sh cannot see this class.
# linkcheck reasons about symbols an object leaves undefined, and a dependency
# carried by a header leaves none: an inline function, a class used only as a
# member, a constexpr that folds. Three of those were found by reading rather than
# by a gate -- the clock (f6d25a02), HugePageSize, and NumaReplicatedAccessToken --
# so both linkcheck baselines read empty while engine/ could not be parsed without
# platform/. This is the check that would have reported them.
#
# THE INCLUDE TARGET IS RESOLVED BY BASENAME, through zone_of, and NOT by matching
# the include path. zone_of asks git which zone directory holds that stem, so it is
# indifferent to how many `../` the include carries -- files under engine/nnue/ and
# engine/nnue/features/ reach the same headers through `../../` and `../../../`, and
# a rule anchored on `../platform/` would report two thirds of the edges and read as
# an answer. It also catches an include written with no zone prefix at all, which a
# path rule cannot.
#
# Its one limit is not depth but ambiguity: zone_of takes the FIRST match for a
# stem, so two same-named files in two zones would classify as whichever git lists
# first. No stem is ambiguous today, and the flat `OBJS = $(notdir ...)` in
# src/Makefile means such a pair would break the build before it reached this gate.
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
BASELINE_PLATFORM=tests/depcheck-platform.baseline

source "$(dirname "${BASH_SOURCE[0]}")/zones.sh"

command -v git >/dev/null || { echo "depcheck: SKIPPED -- no git" >&2; exit 2; }

FILES=$(git ls-files 'src/*.h' 'src/*.cpp' 'src/**/*.h' 'src/**/*.cpp')
[ -n "$FILES" ] || { echo "depcheck: SKIPPED -- no sources listed" >&2; exit 2; }

# Ask the zone question of EVERY tracked file under src/, not only of the ones
# carrying a source extension. A file in no zone is precisely what this check
# exists to catch, so filtering the corpus by extension exempts the case: an
# extensionless file dropped in src/ joins no zone, is named by no build list,
# and is reported by nothing. src/Makefile is the one tracked file that belongs
# at the root of src/ by necessity.
#
# Read the list NUL-separated. A path with a space in it is exactly the shape
# that gets dropped in by accident, and word-splitting reports it under three
# names none of which exist.
echo "== files with no zone =="
unassigned=0
while IFS= read -r -d '' f; do
    [ "$f" = src/Makefile ] && continue
    if [ "$(zone_of_path "$f")" = unassigned ]; then
        echo "  UNASSIGNED  $f"
        unassigned=$((unassigned+1))
    fi
done < <(git ls-files -z src)
[ "$unassigned" = 0 ] && echo "  ok"

# One rule, applied twice. A second copy of this loop is how two checks come to
# disagree about which file is engine.
edges_out_of_engine() {
    local want=$1 f inc istem
    for f in $FILES; do
        [ "$(zone_of_path "$f")" = engine ] || continue
        grep -oE '^[[:space:]]*#include "[^"]+"' "$f" 2>/dev/null \
        | sed 's/.*"\(.*\)"/\1/' | while read -r inc; do
            istem=$(basename "$inc"); istem=${istem%.*}
            [ "$(zone_of "$istem")" = "$want" ] && echo "$(basename "$f") -> $(basename "$inc")"
        done
    done | sort -u
}

rc=0

# $1 label   $2 target zone   $3 baseline path
check_rule() {
    local label=$1 want=$2 baseline=$3 violations known new gone n_known
    echo
    echo "== engine files that include a $label header =="
    violations=$(edges_out_of_engine "$want")

    if [ -f "$baseline" ]; then
        known=$(grep -vE '^\s*(#|$)' "$baseline" | sort -u)
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

    echo
    echo "== new $label violations =="
    if [ -n "$new" ]; then
        printf '%s\n' "$new" | sed 's/^/  NEW      /'
        rc=1
    else
        echo "  ok"
    fi

    echo
    echo "== $label baseline entries that no longer happen =="
    if [ -n "$gone" ]; then
        printf '%s\n' "$gone" | sed 's/^/  STALE    /'
        echo "  remove these from $baseline -- a fixed edge listed as debt is an excuse"
        rc=1
    else
        echo "  ok"
    fi

    echo "depcheck: $n_known baselined $label edge(s)"
}

check_rule shell    shell    "$BASELINE"
check_rule platform platform "$BASELINE_PLATFORM"

echo
[ "$unassigned" = 0 ] || { echo "depcheck: $unassigned file(s) in no zone -- move them into a zone directory"; rc=1; }
[ "$rc" = 0 ] && echo "depcheck: clean" || echo "depcheck: FINDINGS"
exit "$rc"
