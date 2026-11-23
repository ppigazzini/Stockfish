#!/bin/bash
# Every third-party GitHub Action names a release, and says the same release
# everywhere.
#
# The commit it runs is not this gate's question any more. Every `uses:` names a
# release tag, and .github/workflows/actions.lock, which `gh actions-lock`
# writes, names the commit that tag resolved to when it was locked and the
# repository behind it; the runner runs that commit. `gh actions-lock --verify`,
# the docs lane's next step, asks GitHub whether each tag still names its locked
# commit -- the network half this gate used to carry, with its own cache and its
# own rate-limit handling, now asked by GitHub's own checker. What is left needs
# no network, so this gate is deterministic:
#
#   1. NAMES A RELEASE: a full version tag, `vN.N` or `vN.N.N`. Not a bare SHA,
#      which is unreadable, so nobody can see that a pin has gone stale -- which
#      is how one sat four major versions behind until a runner deprecation
#      warning surfaced it. Not a major tag like `@v7` or a branch: either moves
#      with the action's next release, the commit locked for it falls off it,
#      and the lock check reddens on someone else's schedule.
#   2. ONE ACTION, ONE VERSION across the tree. This is the one that needed no
#      network and no release feed to catch: actions/cache was pinned at v4.2.0
#      in one workflow and v6.1.0 in two others, and nothing said so.
#
# Being the LATEST release is deliberately not gated. It is true until the
# action's next release and false afterwards through no change of ours, so
# gating it reddens the lane on someone else's schedule. Dependabot proposes it.
#
# Local workflow calls (`$/.github/workflows/x.yml`, the self-repository form
# zizmor asks for, or the older `./.github/workflows/x.yml`) are not actions and
# name no release: they are this repository's own files at its own commit.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

[ -d .github/workflows ] || { echo "actionpins: SKIPPED -- no .github/workflows" >&2; exit 2; }

rc=0
note() { echo "actionpins: $*"; rc=1; }

# Every `uses:` line, with the workflow it came from. A trailing comment is not
# part of the ref, so it is cut here.
USES=$(grep -nHoE '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*[^[:space:]#]+' \
       .github/workflows/*.yml | sed 's/[[:space:]]*uses:[[:space:]]*/\t/; s/^[[:space:]]*//')
[ -n "$USES" ] || { echo "actionpins: SKIPPED -- no uses: lines found" >&2; exit 2; }

echo "== releases =="
count=0
PAIRS=""
while IFS= read -r line; do
    where=${line%%$'\t'*}
    ref=${line#*$'\t'}

    # This repository's own reusable workflows are not actions.
    case "$ref" in ./* | '$/'*) continue ;; esac
    count=$((count + 1))

    action=${ref%@*}
    at=${ref#*@}

    if [ "$action" = "$ref" ]; then
        echo "  UNPINNED   $where  $ref"
        note "$action is used with no @ref at all"
        continue
    fi
    if printf '%s' "$at" | grep -qE '^[0-9a-f]{40}$'; then
        echo "  BARE SHA   $where  $ref"
        note "$action names a bare commit; name its release tag and let the lockfile hold the commit"
        continue
    fi
    if ! printf '%s' "$at" | grep -qE '^v[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        echo "  MOVING REF $where  $ref"
        note "$action names '$at', which moves with the next release; name the full release tag"
        continue
    fi
    printf '  ok         %-40s %s\n' "$action" "$at"
    PAIRS="$PAIRS$action	$at
"
done <<< "$USES"

[ "$count" -gt 0 ] || { echo "actionpins: SKIPPED -- no third-party actions" >&2; exit 2; }

# ---- one action, one version
echo
echo "== actions named at more than one version =="
split=$(printf '%s' "$PAIRS" | sort -u | cut -f1 | uniq -d)
if [ -n "$split" ]; then
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        echo "  SPLIT      $a"
        printf '%s' "$PAIRS" | sort -u | awk -F'\t' -v a="$a" '$1==a{printf "               %s\n", $2}'
    done <<< "$split"
    note "an action is named at two versions; the older one is the one nobody is watching"
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
# during go infinite, a movetime of zero, a crafted net -- and the lanes
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

echo
echo "actionpins: $count use(s) of a third-party action"
[ "$rc" = 0 ] && echo "actionpins: clean" || echo "actionpins: FINDINGS"
exit "$rc"
