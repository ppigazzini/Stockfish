#!/bin/bash
# Every third-party GitHub Action is pinned to a commit, says which release that
# commit is, and says the same thing everywhere.
#
# Three properties, and only the third needs the network:
#
#   1. PINNED TO A SHA, not to a tag or a branch. A tag is mutable by whoever
#      owns the action, so `@v4` is "run whatever they publish next" on a runner
#      holding this repository's token.
#   2. CARRIES ITS VERSION. A bare 40-hex string is unreadable, so nobody can see
#      that a pin has gone stale -- which is how one sat four major versions
#      behind until a runner deprecation warning surfaced it.
#   3. ONE ACTION, ONE VERSION across the tree. This is the one that needed no
#      network and no release feed to catch: actions/cache was pinned at v4.2.0
#      in one workflow and v6.1.0 in two others, and nothing said so.
#
# The fourth property -- that the pin is the LATEST release -- is deliberately not
# gated. It is true until the action's next release and false afterwards through
# no change of ours, so gating it reddens the lane on someone else's schedule.
# `--latest` reports it, for a human to act on.
#
# Local workflow calls (`./.github/workflows/x.yml`) are not actions and are not
# pinned: they are this repository's own files at this repository's own commit.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

CHECK_LATEST=0
[ "${1:-}" = "--latest" ] && CHECK_LATEST=1

[ -d .github/workflows ] || { echo "actionpins: SKIPPED -- no .github/workflows" >&2; exit 2; }

rc=0
note() { echo "actionpins: $*"; rc=1; }

# Every `uses:` line, with the workflow it came from. Comments are NOT stripped
# here: the version is IN the trailing comment, which is the point.
USES=$(grep -nHoE '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*[^[:space:]]+([[:space:]]*#[[:space:]]*[^[:space:]]+)?' \
       .github/workflows/*.yml | sed 's/[[:space:]]*uses:[[:space:]]*/\t/; s/^[[:space:]]*//')
[ -n "$USES" ] || { echo "actionpins: SKIPPED -- no uses: lines found" >&2; exit 2; }

echo "== pins =="
count=0
PAIRS=""
while IFS= read -r line; do
    where=${line%%$'\t'*}
    spec=${line#*$'\t'}
    ref=$(printf '%s' "$spec" | awk '{print $1}')
    ver=$(printf '%s' "$spec" | sed -n 's/.*#[[:space:]]*\(.*\)$/\1/p')

    # This repository's own reusable workflows are not actions.
    case "$ref" in ./*) continue ;; esac
    count=$((count + 1))

    action=${ref%@*}
    at=${ref#*@}

    if [ "$action" = "$ref" ]; then
        echo "  UNPINNED   $where  $ref"
        note "$action is used with no @ref at all"
        continue
    fi
    if ! printf '%s' "$at" | grep -qE '^[0-9a-f]{40}$'; then
        echo "  NOT A SHA  $where  $ref"
        note "$action is pinned to '$at' rather than to a commit; a tag is mutable by its owner"
        continue
    fi
    if [ -z "$ver" ]; then
        echo "  NO VERSION $where  $action@${at:0:12}"
        note "$action carries no version comment, so a stale pin is unreadable"
        continue
    fi
    printf '  ok         %-34s %-10s %s\n' "$action" "$ver" "${at:0:12}"
    PAIRS="$PAIRS$action	$ver	$at
"
done <<< "$USES"

[ "$count" -gt 0 ] || { echo "actionpins: SKIPPED -- no third-party actions" >&2; exit 2; }

# ---- one action, one version
echo
echo "== actions pinned at more than one version =="
split=$(printf '%s' "$PAIRS" | sort -u | cut -f1 | uniq -d)
if [ -n "$split" ]; then
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        echo "  SPLIT      $a"
        printf '%s' "$PAIRS" | sort -u | awk -F'\t' -v a="$a" '$1==a{printf "               %-10s %s\n", $2, substr($3,1,12)}'
    done <<< "$split"
    note "an action is pinned at two versions; the older one is the one nobody is watching"
else
    echo "  ok"
fi

# ---- every job has a deadline, and every workflow a permission floor
#
# Both are properties of the workflow FILES, so they belong beside the pin checks
# rather than in a gate of their own: this script already reads all of them.
#
# A job with no timeout-minutes inherits GitHub's six-hour default. This branch's
# defect register is largely ways an engine fails to come back -- a setoption
# during go infinite, a movetime of zero, a crafted LEB128 net -- and the lanes
# that would hit one had no deadline at all.
#
# A workflow with no permissions block takes whatever the repository default
# grants. The floor is declared at WORKFLOW level so a job added later inherits
# it; a job needing more declares it and that grant wins.
echo
echo "== every job has a deadline, every workflow a permission floor =="
gaps=0
for w in .github/workflows/*.yml; do
    [ -f "$w" ] || continue
    body=$(sed 's/[[:space:]]*#.*$//' "$w")
    # A job that only `uses:` a reusable workflow cannot carry timeout-minutes,
    # so the anchor is runs-on: exactly the jobs that CAN have one.
    want=$(printf '%s\n' "$body" | grep -cE '^[[:space:]]{4}runs-on:')
    have=$(printf '%s\n' "$body" | grep -cE '^[[:space:]]{4}timeout-minutes:')
    if [ "$want" -ne "$have" ]; then
        echo "  $(basename "$w"): $want job(s) with runs-on, $have with timeout-minutes"
        gaps=$((gaps + 1))
    fi
    if ! printf '%s\n' "$body" | grep -qE '^permissions:'; then
        echo "  $(basename "$w"): no workflow-level permissions block"
        gaps=$((gaps + 1))
    fi
done
if [ "$gaps" -gt 0 ]; then
    note "$gaps workflow(s) missing a deadline or a permission floor"
else
    echo "  ok"
fi

# ---- the SHA is the tag it claims, and optionally the tag is current
echo
echo "== each pin against its own claimed release =="
if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "  SKIPPED -- no authenticated gh; the network half was not checked"
    echo "  (the three checks above ran and their result stands)"
else
    # THREE outcomes, not two. `2>/dev/null` on the call below used to collapse
    # "upstream has no such tag" and "GitHub did not answer" into one empty
    # string, and the empty string was reported as the first. With 62 uses and up
    # to two calls each, a rate limit or a transient made this gate red without
    # the tree changing -- a merge gate that flips is a coin flip, and a red run
    # that clears on a re-run teaches the reader to re-run rather than to look.
    #
    # A 404 is upstream's answer and a finding. Anything else -- 403, 5xx, no
    # network -- is a check that did not run, and this branch's rule is that a
    # skip is not a pass. So they are counted separately and the count is printed
    # whether or not it is zero.
    unresolved=0
    err=$(mktemp) || exit 2
    trap 'rm -f "$err"' EXIT
    while IFS=$'\t' read -r action ver sha; do
        [ -n "$action" ] || continue
        base=$(printf '%s' "$action" | cut -d/ -f1-2)
        real=$(gh api "repos/$base/commits/$ver" --jq .sha 2>"$err")
        if [ -z "$real" ] && ! grep -qE 'HTTP 404|Not Found' "$err"; then
            printf '  unresolved %-34s %s -- %s\n' "$action" "$ver" \
                   "$(tr -d '\n' < "$err" | cut -c1-60)"
            unresolved=$((unresolved + 1))
        elif [ -z "$real" ]; then
            echo "  UNKNOWN    $action  $ver -- no such tag upstream"
            note "$action claims $ver and upstream has no such tag"
        elif [ "$real" != "$sha" ]; then
            echo "  LIES       $action  says $ver, but $ver is ${real:0:12} and the pin is ${sha:0:12}"
            note "$action's version comment does not describe its pin"
        elif [ "$CHECK_LATEST" = 1 ]; then
            latest=$(gh api "repos/$base/releases/latest" --jq .tag_name 2>/dev/null)
            if [ -n "$latest" ] && [ "$latest" != "$ver" ]; then
                printf '  behind     %-34s %s -> %s\n' "$action" "$ver" "$latest"
            else
                printf '  current    %-34s %s\n' "$action" "$ver"
            fi
        else
            printf '  ok         %-34s %s\n' "$action" "$ver"
        fi
    done <<< "$(printf '%s' "$PAIRS" | sort -u)"

    # Printed at zero too. A count that appears only when it is non-zero is a
    # count nobody learns to look for.
    echo "  unresolved: $unresolved (network or rate limit, not a verdict)"
    if [ "$unresolved" -gt 0 ] && [ "$rc" = 0 ]; then
        echo "  NOT a clean network half -- $unresolved pin(s) were not checked"
    fi
fi

echo
echo "actionpins: $count use(s) of a third-party action"
[ "$rc" = 0 ] && echo "actionpins: clean" || echo "actionpins: FINDINGS"
exit "$rc"
