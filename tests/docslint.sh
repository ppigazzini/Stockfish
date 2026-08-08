#!/bin/bash
# Mechanical checks over the shipped documentation set.
#
# It settles the MECHANICAL half of documentation rot and no more. It cannot
# tell you a sentence has become false, and in practice that is the half that
# actually rots: a real symbol attributed to the wrong file, a list with the
# wrong count, a behaviour described as absent from a build that has it. All
# three pass this gate. Do not read a green run as a correctness proof.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

# The shipped documentation surface.
PAGES=(docs/*.md README.md CONTRIBUTING.md AGENTS.md)

# The untracked working area. This script and .gitignore are the only tracked
# files permitted to name it -- see check 5.
INTERNAL='__DEV'

FAIL=0
note() { echo "docslint: $*"; FAIL=1; }
head_check() { echo; echo "== $* =="; }

exists_pages=()
for p in "${PAGES[@]}"; do [ -f "$p" ] && exists_pages+=("$p"); done
[ ${#exists_pages[@]} -gt 0 ] || { echo "docslint: SKIPPED -- no pages found" >&2; exit 2; }

# ---------------------------------------------------------------- 1. links

head_check "1. every markdown link resolves"
n=0
for p in "${exists_pages[@]}"; do
    d=$(dirname "$p")
    # [text](target) -- skip external schemes and pure anchors
    grep -oE '\]\([^)]+\)' "$p" | sed 's/^](//; s/)$//' | while read -r t; do
        case "$t" in
            http://*|https://*|mailto:*|'#'*) continue ;;
        esac
        t=${t%%#*}
        [ -n "$t" ] || continue
        if [ ! -e "$d/$t" ] && [ ! -e "$t" ]; then
            echo "  $p -> $t"
        fi
    done
done > /tmp/docslint.$$.links
n=$(wc -l < /tmp/docslint.$$.links)
if [ "$n" -gt 0 ]; then cat /tmp/docslint.$$.links; note "$n dead link(s)"; else echo "  ok"; fi
rm -f /tmp/docslint.$$.links

# ---------------------------------------------------------------- 2. paths

# A path named in prose must exist. A path .gitignore names is exempt: a page
# legitimately describes the tool that writes an ignored artifact. That
# exemption is exactly why check 5 exists separately -- the internal area is
# ignored, so every reference into it would land here and report clean.
head_check "2. every named src/ tests/ scripts/ .github/ path exists"
for p in "${exists_pages[@]}"; do
    # Strip URLs first. A fishtest link carries `tests/view/<id>`, which is not a
    # path in this tree, and every functional commit message quotes one.
    sed -E 's#https?://[^ )>"]*##g' "$p" \
    | grep -oE '(src|tests|scripts|\.github)/[A-Za-z0-9_./-]*[A-Za-z0-9_]' \
    | sort -u | while read -r t; do
        [ -e "$t" ] && continue
        git check-ignore -q "$t" 2>/dev/null && continue
        echo "  $p -> $t"
    done
done > /tmp/docslint.$$.paths
n=$(wc -l < /tmp/docslint.$$.paths)
if [ "$n" -gt 0 ]; then cat /tmp/docslint.$$.paths; note "$n missing path(s)"; else echo "  ok"; fi
rm -f /tmp/docslint.$$.paths

# --------------------------------------------------------------- 3. signature

# The bench signature moves with every functional commit and nobody greps the
# documentation when it does. The subject is read from its owner -- the commit
# record -- rather than restated here.
head_check "3. no page pins the bench signature"
BENCH=$(git log --format='%b' 2>/dev/null | grep -oE 'Bench: *[0-9]{5,}' | head -1 | grep -oE '[0-9]+')
found=0
for p in "${exists_pages[@]}"; do
    if grep -qE 'Bench: *[0-9]{5,}' "$p"; then
        echo "  $p contains a literal 'Bench: <n>'"; found=1
    fi
    if [ -n "$BENCH" ] && grep -q "$BENCH" "$p"; then
        echo "  $p contains the current signature $BENCH"; found=1
    fi
done
if [ "$found" = "1" ]; then note "a page pins the bench signature"
elif [ -z "$BENCH" ]; then echo "  ok (no signature found anywhere in the commit record)"
else echo "  ok (current signature $BENCH appears in no page)"; fi

# --------------------------------------------------------------- 4. coverage

# A gate nobody can discover is a gate nobody runs.
head_check "4. every gate in tests/ and scripts/ is named by some page"
missing=0
for g in tests/*.sh tests/*.py scripts/*.sh; do
    [ -e "$g" ] || continue
    b=$(basename "$g")
    if ! grep -qlF "$b" "${exists_pages[@]}" >/dev/null 2>&1; then
        echo "  $g is named by no page"; missing=$((missing+1))
    fi
done
if [ "$missing" -gt 0 ]; then note "$missing undiscoverable gate(s)"; else echo "  ok"; fi

# --------------------------------------------------------------- 5. internal

# Sweeps every TRACKED file, not every page: a source comment or a workflow
# file dangles for a reader exactly as a doc line does, and a clone carries
# neither the internal area nor any way to know what was meant.
head_check "5. no tracked file references the untracked working area"
offenders=$(git ls-files 2>/dev/null | while read -r f; do
    [ -f "$f" ] || continue
    case "$f" in .gitignore|tests/docslint.sh) continue ;; esac
    grep -lF -- "$INTERNAL" "$f" 2>/dev/null
done)
if [ -n "$offenders" ]; then
    echo "$offenders" | sed 's/^/  /'
    note "tracked file(s) reference $INTERNAL/, which a clone does not carry"
else
    echo "  ok"
fi

# Assert the exemption rather than assuming it: .gitignore must actually ignore
# the directory, or check 5 is excusing a path that ships.
if ! git check-ignore -q "$INTERNAL/" 2>/dev/null; then
    note "$INTERNAL/ is NOT gitignored -- check 5's exemption list is wrong"
fi

echo
if [ "$FAIL" = "0" ]; then echo "docslint: clean"; else echo "docslint: FINDINGS"; fi
exit "$FAIL"
