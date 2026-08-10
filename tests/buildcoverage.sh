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
if [ "$missing" != 0 ]; then
    echo "buildcoverage: $missing source(s) in the tree and not in the build"
    echo "buildcoverage: FINDINGS"
    exit 1
fi
echo "buildcoverage: $count source(s), all named"
echo "buildcoverage: clean"
exit 0
