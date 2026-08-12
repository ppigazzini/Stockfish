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

# ---- the SHA is the tag it claims, and optionally the tag is current
echo
echo "== each pin against its own claimed release =="
if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then
    echo "  SKIPPED -- no authenticated gh; the network half was not checked"
    echo "  (the three checks above ran and their result stands)"
else
    while IFS=$'\t' read -r action ver sha; do
        [ -n "$action" ] || continue
        base=$(printf '%s' "$action" | cut -d/ -f1-2)
        real=$(gh api "repos/$base/commits/$ver" --jq .sha 2>/dev/null)
        if [ -z "$real" ]; then
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
fi

echo
echo "actionpins: $count use(s) of a third-party action"
[ "$rc" = 0 ] && echo "actionpins: clean" || echo "actionpins: FINDINGS"
exit "$rc"
