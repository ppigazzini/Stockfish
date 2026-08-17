#!/bin/bash
# Every tracked source is named by the build.
#
# `SRCS` is an explicit list rather than a wildcard, and that is a property worth
# protecting rather than a limitation to remove: a wildcard silently absorbs
# whatever is in the directory, including a file nobody meant to ship.
#
# The cost of the explicit list is this failure: a file added to the tree and not
# to the list is not compiled, not linked, and not covered by any gate -- while
# still looking maintained. It then rots against the files that do move, and the
# first symptom is a compile error months later in a file nobody was editing.
#
# It also blinds tests/linkcheck.sh, which asks whether an ENGINE OBJECT
# references a shell symbol. A source that is compiled by nothing produces no
# object, so it can call straight into the shell and the zone check stays green.
# That is why this gate is the prerequisite for trusting that one.
#
# Comments are stripped before matching: a filename mentioned only in a comment
# is documentation, not a build rule, and would otherwise pass.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2
MAKEFILE=src/Makefile

command -v git >/dev/null || { echo "buildcoverage: SKIPPED -- no git" >&2; exit 2; }
[ -f "$MAKEFILE" ] || { echo "buildcoverage: SKIPPED -- no $MAKEFILE" >&2; exit 2; }

# Only to decide whether to skip. The loop below re-reads the list NUL-separated,
# because a command substitution DROPS null bytes: capturing `ls-files -z` in a
# variable yields one glued string, the loop then reads no records, and the gate
# reports "all 0" clean -- a green run over an empty corpus.
[ -n "$(git ls-files 'src/*.cpp' 'src/**/*.cpp')" ] \
    || { echo "buildcoverage: SKIPPED -- no sources listed" >&2; exit 2; }

# The Makefile with comments removed, in a FILE rather than a variable. A `#`
# inside a recipe is a shell comment too, so stripping from `#` to end of line is
# right for both.
#
# A file and not `printf ... | grep -q`: grep -q exits at the first match and
# closes the pipe, the writer dies of SIGPIPE, and `set -o pipefail` turns that
# into a failed pipeline. A match then reads as a MISS, so every covered source
# is reported uncovered. Keep the corpus in a file so grep has no producer to
# kill.
recipe=$(mktemp) || exit 2
trap 'rm -f "$recipe"' EXIT
sed 's/#.*$//' "$MAKEFILE" > "$recipe"

echo "== every tracked source is named by the build =="
missing=0
count=0
# NUL-separated: a source path containing a space would otherwise be split into
# words, and each word checked against the recipe under a name that is not a file.
while IFS= read -r -d '' f; do
    count=$((count + 1))
    base=$(basename "$f")
    # Named either by its path or, because OBJS flattens with notdir and VPATH
    # resolves the rest, by its bare filename.
    if ! grep -qF "$base" "$recipe"; then
        echo "  UNCOVERED  $f -- compiled by nothing"
        missing=$((missing + 1))
    fi
done < <(git ls-files -z 'src/*.cpp' 'src/**/*.cpp')
[ "$missing" = 0 ] && echo "  ok, all $count"

echo
echo "== every tracked header is named by the build =="
# HEADERS drives `make format` and nothing else, so a header missing from it is
# never compiled differently -- it is simply never formatted, and the drift shows
# up as a diff in whichever unrelated commit finally adds it. Three had gone
# missing when this check was written (engine/fatal.h, host.h, prng.h), and all
# three were added by the two milestones immediately before it: a list drifts
# exactly where the work is.
#
# Same corpus rule as the sources: vendored trees are excluded because the build
# formats none of them, and re-formatting a third-party header makes every future
# update a conflict.
hmissing=0
hcount=0
while IFS= read -r -d '' f; do
    case "$f" in src/incbin/*|src/universal/*) continue ;; esac
    hcount=$((hcount + 1))
    if ! grep -qF "$(basename "$f")" "$recipe"; then
        echo "  UNFORMATTED  $f -- named by no build variable"
        hmissing=$((hmissing + 1))
    fi
done < <(git ls-files -z 'src/*.h' 'src/**/*.h')
[ "$hmissing" = 0 ] && echo "  ok, all $hcount"
missing=$((missing + hmissing))

echo
# A second way a source ends up in the tree and not in the binary, and this one
# passes the check above. `OBJS = $(notdir $(SRCS:.cpp=.o))` flattens every object
# into ONE name space and VPATH is a flat search path across the zone
# directories, so two sources sharing a basename compete for a single .o: make
# builds one of them and the other is never compiled. Both are named by SRCS, so
# the loop above finds both covered and reports clean.
#
# This is the same defect the file argues an explicit SRCS protects against --
# present and uncompiled -- arriving from the direction an explicit list does not
# help with.
echo
echo "== source basenames that collide =="
dupes=$(git ls-files 'src/*.cpp' 'src/**/*.cpp' \
        | while IFS= read -r f; do basename "$f"; done | sort | uniq -d)
if [ -n "$dupes" ]; then
    while IFS= read -r d; do
        echo "  COLLIDES   $d"
        git ls-files "src/*/$d" "src/*/*/$d" "src/*/*/*/$d" | sed 's/^/               /'
    done <<< "$dupes"
    missing=$((missing + 1))
else
    echo "  ok"
fi

echo
if [ "$missing" != 0 ]; then
    echo "buildcoverage: $missing source(s) in the tree and not in the build"
    echo "buildcoverage: FINDINGS"
    exit 1
fi
echo "buildcoverage: $count source(s), all named"
echo "buildcoverage: clean"
exit 0
