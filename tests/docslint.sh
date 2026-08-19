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

# The exemption list, and every entry states what makes it one. The rule this
# check enforces is that nothing a clone RECEIVES may point at something the
# clone does not GET -- so the exemptions are the files whose subject IS the
# working area, for which naming it is the function rather than a leak.
#
#   .gitignore            declares it ignored; check 5's own assertion below
#                         re-reads this file to prove the exemption is real
#   tests/docslint.sh     this file, which has to name it to look for it
#   tests/devcite.sh      a gate whose entire corpus is __DEV/*.md. It SKIPS
#                         (exit 2) in a clone rather than passing on an empty
#                         set, which is what makes it safe to ship
#   tests/lanecheck.sh    carries devcite.sh's excuse, and the excuse has to say
#                         WHY there is no lane -- "a clone carries nothing for it
#                         to read" cannot be written without naming the area
#   tests/negative_control.sh  three rows that create a throwaway page under it,
#                         each guarded by `[ -d __DEV ]` and reported SKIPPED
#                         otherwise
#
# A file added here without one of those properties is a leak wearing an
# exemption. The test to apply: does it still do something useful in a clone?
offenders=$(git ls-files 2>/dev/null | while read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        .gitignore|tests/docslint.sh|tests/devcite.sh|tests/lanecheck.sh|tests/negative_control.sh)
            continue ;;
    esac
    grep -lF -- "$INTERNAL" "$f" 2>/dev/null
done)
if [ -n "$offenders" ]; then
    # shellcheck disable=SC2001
    # the substitution is line-anchored, which ${var//} cannot express
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

# ---------------------------------------------------------------- 6. selector

# THE ONE COUNT THIS GATE CAN DERIVE. The header above admits that "a list with
# the wrong count" is the rot it cannot see, and the performance-gate selector
# is where that rot actually landed: AGENTS.md grew a sixth row for
# npsthreads.sh and docs/10-tooling-ci.md kept saying "there are five of them
# because there are five questions" over a five-row copy of the same table.
#
# Two tables, one subject, so the check is set equality on the gate column and
# needs no prose parsing. It does NOT check the sentence above either table --
# nothing here can -- but a numeral over a table only goes stale when the table
# does, and this catches the table.
head_check "6. the two copies of the performance-gate selector agree"

selector_gates() {
    # From the header row to the first line that is not a table row. Column 2 is
    # the gate; a row may name more than one (npsab.sh "and probably fishtest"),
    # so every .sh token in that column counts.
    awk -F'|' '
        /^\| the change claims \| gate \| why \|/ { intable = 1; next }
        intable && !/^\|/                            { exit }
        intable && $3 ~ /\.sh/ {
            n = split($3, tok, /[^A-Za-z0-9_.\/]+/)
            for (i = 1; i <= n; i++)
                if (tok[i] ~ /\.sh$/) { sub(/^.*\//, "", tok[i]); print tok[i] }
        }
    ' "$1" | sort -u
}

sel_agents=$(selector_gates AGENTS.md)
sel_page=$(selector_gates docs/10-tooling-ci.md)

if [ -z "$sel_agents" ] || [ -z "$sel_page" ]; then
    note "one of the two selector tables was not found -- its header row moved"
elif [ "$sel_agents" != "$sel_page" ]; then
    echo "  only in AGENTS.md:"
    comm -23 <(echo "$sel_agents") <(echo "$sel_page") | sed 's/^/    /'
    echo "  only in docs/10-tooling-ci.md:"
    comm -13 <(echo "$sel_agents") <(echo "$sel_page") | sed 's/^/    /'
    note "the selector tables disagree -- and the sentence above each states a count"
else
    echo "  ok, $(echo "$sel_agents" | grep -c .) gate(s) in both"
fi

head_check "7. the CI table names the gates the workflows run"

# The one LIST this gate owns. Check 3 refuses a number the tree computes; a
# list the tree computes is the same rule, and nothing enforced it -- the table
# fell nine rows behind while the paragraph beside it told the reader that a
# list drifting by one entry reads exactly like one that has not.
#
# Both sides are emitted as `workflow<TAB>gate` pairs so the comparison is a
# `comm` rather than a diff by eye, and a workflow that runs no gate emits one
# pair with an empty gate -- which is a real entry, not an absence, so a
# workflow missing from the table cannot pass as one that runs nothing.
lane_pairs_documented() {
    awk '
        /^\| `stockfish\.yml` \|/ { intable = 1 }
        intable && !/^\|/          { exit }
        intable {
            split($0, col, "|")
            nw = split(col[2], wtok, /[^A-Za-z0-9_.-]+/)
            ng = split(col[3], gtok, /[^A-Za-z0-9_.\/-]+/)
            for (i = 1; i <= nw; i++) {
                if (wtok[i] !~ /\.yml$/) continue
                seen = 0
                for (j = 1; j <= ng; j++)
                    if (gtok[j] ~ /\.(sh|py)$/) { print wtok[i] "\t" gtok[j]; seen = 1 }
                if (!seen) print wtok[i] "\t"
            }
        }
    ' docs/10-tooling-ci.md | sort -u
}

lane_pairs_actual() {
    local w b g
    for w in .github/workflows/*.yml; do
        b=$(basename "$w")
        g=$(grep -oE 'tests/[a-z0-9_]+\.(sh|py)' "$w" | sort -u)
        g=${g//tests\//}
        if [ -z "$g" ]; then printf '%s\t\n' "$b"; else echo "$g" | awk -v b="$b" '{print b "\t" $0}'; fi
    done | sort -u
}

if [ ! -d .github/workflows ]; then
    note "no .github/workflows -- the CI table has nothing to be held to"
else
    lane_doc=$(lane_pairs_documented)
    lane_act=$(lane_pairs_actual)
    if [ -z "$lane_doc" ]; then
        note "the CI table was not found -- its first row no longer names stockfish.yml"
    elif [ "$lane_doc" != "$lane_act" ]; then
        echo "  documented, not run:"
        comm -23 <(echo "$lane_doc") <(echo "$lane_act") | sed 's/^/    /'
        echo "  run, not documented:"
        comm -13 <(echo "$lane_doc") <(echo "$lane_act") | sed 's/^/    /'
        note "the CI table is not the map the workflows are"
    else
        echo "  ok, $(echo "$lane_act" | cut -f1 | sort -u | grep -c .) workflow(s) agree"
    fi
fi

echo
if [ "$FAIL" = "0" ]; then echo "docslint: clean"; else echo "docslint: FINDINGS"; fi
exit "$FAIL"
