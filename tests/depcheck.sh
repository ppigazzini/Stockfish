#!/bin/bash
# Enforce the declared dependency direction between the three zones of src/.
#
# The stack is shell -> platform -> engine, engine at the bottom. `platform/` is
# not a layer beneath the engine: it is the runtime that HOSTS the engine, so it
# may depend on engine types and not the other way round.
#
# THREE edges are checked, because each is a defect rather than a choice.
#
# Two out of the engine: an engine file that includes a SHELL header, and one that
# includes a PLATFORM header. The engine is the chess library; a library that
# reaches into the process driving it cannot be linked without that process, and
# cannot be reasoned about without reading it.
#
# One out of the platform: a PLATFORM file that includes a SHELL header. This is
# the direction nothing looked at for the longest, and it was not empty when the
# rule was added -- two edges existed. platform/thread.cpp reached shell/uci.h to
# turn a `searchmoves` token into a Move, because the engine's own LimitsType
# carried UCI wire format; platform/syzygy/tbprobe.cpp reached shell/console.h for
# one `info string`. Severing the TYPE closed the first and the output-sink seam
# closed the second, so the baseline ships empty.
#
# Both were found by this rule on its first run, and one of them had been reported
# as already-severed by an audit whose grep was anchored on `../shell` and could
# not see `../../shell`. That is the trap the basename resolution below exists to
# avoid, walked into by a hand-rolled command in the same week the note was
# written.
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
# Its one limit is not depth but ambiguity, and that is checked here rather than
# left as a note. zone_of refuses a stem that names files in more than one zone,
# returning `ambiguous`; every caller compares against a zone name, so an
# ambiguous stem would match none of them and be SILENTLY EXEMPT. Ambiguity is a
# property of the tree rather than of one lookup, so it is asserted once, below,
# and the other callers can then never meet one on a green tree.
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
BASELINE_PLATFORM_SHELL=tests/depcheck-platform-shell.baseline

# Through $ROOT, and NOT through $(dirname "${BASH_SOURCE[0]}"). The cd above
# has already run, so a relative invocation path no longer resolves: AGENTS.md
# says to run the gates from src/ as ../tests/<gate>.sh, and that spells
# ../tests/zones.sh, which from the repository root is one directory too high.
# The source then fails and every zone lookup in this file is an undefined
# command that expands to nothing.
source "$ROOT/tests/zones.sh" || exit 2

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
# One stem, one zone. Two same-named sources also break the BUILD, and more
# quietly: `OBJS = $(notdir $(SRCS:.cpp=.o))` flattens every object into one name
# space and VPATH is a flat search path, so the pair competes for one object and
# one of them is never compiled. tests/buildcoverage.sh asserts that half; this
# one is about classification, and the two are separate because a header pair
# breaks classification without breaking the build.
echo "== stems that name more than one zone =="
ambiguous=0
while IFS= read -r stem; do
    if [ "$(zone_of "$stem")" = ambiguous ]; then
        echo "  AMBIGUOUS   $stem -- named in more than one zone"
        ambiguous=$((ambiguous+1))
    fi
done < <(git ls-files 'src/*/*.cpp' 'src/*/*.h' 'src/*/*/*.cpp' 'src/*/*/*.h' \
                      'src/*/*/*/*.cpp' 'src/*/*/*/*.h' \
         | while IFS= read -r f; do b=$(basename "$f"); echo "${b%.*}"; done | sort -u)
[ "$ambiguous" = 0 ] && echo "  ok"

echo
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

# One rule, applied three times. A second copy of this loop is how two checks
# come to disagree about which file is engine.
edges_out_of() {
    local from=$1 want=$2 f inc istem
    for f in $FILES; do
        [ "$(zone_of_path "$f")" = "$from" ] || continue
        grep -oE '^[[:space:]]*#include "[^"]+"' "$f" 2>/dev/null \
        | sed 's/.*"\(.*\)"/\1/' | while read -r inc; do
            istem=$(basename "$inc"); istem=${istem%.*}
            [ "$(zone_of "$istem")" = "$want" ] && echo "$(basename "$f") -> $(basename "$inc")"
        done
    done | sort -u
}

rc=0

# $1 source zone   $2 target zone   $3 baseline path
check_rule() {
    local from=$1 want=$2 baseline=$3 violations known new gone n_known
    local label="$from -> $want"
    echo
    echo "== $from files that include a $want header =="
    violations=$(edges_out_of "$from" "$want")

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

# ---------------------------------------------------------------- friends
#
# A fourth question, and the only one here that no include and no symbol can
# answer. `friend class Stockfish::ThreadPool;` in engine/search.h named a
# PLATFORM type from an engine header and granted it every private member of
# Search::Worker. A forward declaration emits no symbol, so linkcheck.sh and
# enginelink.sh are structurally blind to it; it is not an #include, so the three
# rules above cannot see it either. It survived every zone gate this branch has.
#
# So it is checked TEXTUALLY, which is the only form available: extract the type
# each `friend` names, ask where that type is declared, and refuse a declaration
# outside engine/. A type declared in more than one zone is reported rather than
# resolved, for the same reason zone_of refuses an ambiguous stem.
echo
echo "== engine friends that name a type from another zone =="
friend_bad=0
friend_n=0
for f in $FILES; do
    [ "$(zone_of_path "$f")" = engine ] || continue
    case "$f" in *.h) : ;; *) continue ;; esac
    while read -r ty; do
        [ -n "$ty" ] || continue
        friend_n=$((friend_n + 1))
        # Every file that declares or defines it, anywhere under src/.
        while read -r d; do
            [ -n "$d" ] || continue
            dz=$(zone_of_path "$d")
            [ "$dz" = engine ] && continue
            echo "  $(basename "$f") befriends $ty, declared in $d ($dz)"
            friend_bad=$((friend_bad + 1))
        done < <(git grep -lE "^[[:space:]]*(class|struct)[[:space:]]+$ty([[:space:]]*[:{;]|\$)" \
                     -- 'src/*' 2>/dev/null)
    done < <(grep -oE '^[[:space:]]*friend[[:space:]]+(class|struct)[[:space:]]+[A-Za-z_][A-Za-z_0-9:]*' "$f" 2>/dev/null \
             | sed 's/.*[[:space:]]//; s/^.*:://')
done
if [ "$friend_bad" -gt 0 ]; then
    echo "  a friend declaration is the one zone edge no symbol gate can see"
    rc=1
else
    echo "  ok ($friend_n friend declaration(s), all naming engine types)"
fi

check_rule engine   shell    "$BASELINE"
check_rule engine   platform "$BASELINE_PLATFORM"

# The THIRD direction, and the one that went unwatched longest. The two rules
# above leave the runtime free to reach into the CLI, which is the same drift
# class in the one direction nothing looked at: platform/thread.cpp included
# shell/uci.h to turn a `searchmoves` token into a Move, because the engine's own
# LimitsType carried UCI wire format. Severing the TYPE closed the include, and
# this baseline ships EMPTY and is meant to stay that way.
check_rule platform shell    "$BASELINE_PLATFORM_SHELL"

echo
[ "$unassigned" = 0 ] || { echo "depcheck: $unassigned file(s) in no zone -- move them into a zone directory"; rc=1; }
[ "$ambiguous" = 0 ] || { echo "depcheck: $ambiguous stem(s) in more than one zone -- rename one, or every zone gate classifies it by whichever git lists first"; rc=1; }
[ "$rc" = 0 ] && echo "depcheck: clean" || echo "depcheck: FINDINGS"
exit "$rc"
