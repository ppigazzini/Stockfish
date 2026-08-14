#!/bin/bash
# The bench anchor is readable, and nothing in a commit body can be mistaken for it.
#
# AGENTS.md states the rule as "the `Bench:` in the most recent commit body that
# carries one". Two things have to hold for that sentence to be operable, and
# neither was checked:
#
#   1. THERE IS ONE. A branch that stacks non-functional commits on upstream can
#      put the newest footer arbitrarily far back -- 180 commits, here -- so any
#      reader with a fixed walk depth eventually finds nothing and either fails
#      or, worse, falls back to something older.
#
#   2. NOTHING ELSE LOOKS LIKE ONE. The regex upstream's pre-push hook uses,
#      `[Bb]ench[ :]+[0-9]{6,8}`, matches a run of spaces between the word and
#      the number -- so an EVIDENCE ROW inside a body, `  bench      2829394`,
#      is indistinguishable from a footer. The CI lanes read one such row as the
#      anchor and every architecture job failed against a value that was true
#      when written and went stale at a rebase.
#
# The reader is now `git log --format=%b` with `^Bench: N$` anchored, which is
# what the rule says and what AGENTS.md's own command does. This gate holds the
# record to a shape that reader cannot misread.
#
# Scope is THIS BRANCH's commits, merge-base with master to HEAD. Upstream's
# history is not ours to police and scanning it is slow.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

BASELINE=tests/anchor.baseline

command -v git >/dev/null || { echo "anchor: SKIPPED -- no git" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "anchor: SKIPPED -- not a repository" >&2; exit 2; }

rc=0

# ---- 1. the anchor is readable
echo "== the anchor the lanes read =="
# A here-string, not a pipe from git log: `grep -m1` closes the pipe on the first
# match, git log dies of SIGPIPE, and pipefail turns finding the anchor into a
# failure. tests/lanecheck.sh carries the same note for the same reason.
HISTORY=$(git log --format=%b)
REF=$(grep -m1 -oE '^Bench: *[1-9][0-9]{5,7}$' <<< "$HISTORY" | grep -oE '[0-9]+' || true)
if [ -z "$REF" ]; then
    echo "  NONE -- no 'Bench: <n>' footer anywhere in the history"
    echo "anchor: the lanes have nothing to compare against"
    exit 1
fi
echo "  $REF"

# ---- 2. no body text can be mistaken for a footer
#
# The loose form is upstream's hook regex. Text matching it that is NOT the
# strict footer is the trap: it reads as the anchor to anything scanning bodies
# line by line.
#
# MATCH IT ANYWHERE IN THE LINE. Requiring the whole line to be footer-shaped is
# the narrower rule and it misses the shape that actually costs: a value quoted
# INSIDE a sentence -- "carries `Bench: <n>`" -- or padded into a table column
# next to a `|`. An unanchored reader finds those first and reports a number
# rather than an error, which is what makes them worse than a bare line.
#
# Reword rather than baseline. `<bench_value>` in place of the digits says the
# same thing to a human, survives a rebase, and can never be read as a value.
# `master` is a local branch here and NOT on a CI checkout, which fetches the
# pushed ref alone. Fall back to the remote-tracking ref, then to a bounded walk:
# the body scan is about this branch's own commits, and a run that cannot name the
# fork point is still worth doing over the recent past. Never exit 2 for this --
# a lane reads a skip as a failure, and the scan is not the optional half.
BASE=$(git merge-base HEAD master 2>/dev/null \
       || git merge-base HEAD origin/master 2>/dev/null \
       || git merge-base HEAD upstream/master 2>/dev/null || true)
if [ -n "$BASE" ]; then
    RANGE="$BASE..HEAD"
    SCOPE="since the fork point"
else
    RANGE="-200"
    SCOPE="the last 200 commits -- no master ref to find the fork point from"
fi

echo
echo "== commit bodies whose text reads as a footer ($SCOPE) =="
offenders=$(
git log --format='%H' $RANGE | while read -r f; do
    hit=$(git show -s --format='%b' "$f" \
          | grep -o '\b[Bb]ench[ :]\+[1-9][0-9]\{5,7\}\b' || true)
    hit=$(printf '%s\n' "$hit" | sed -n '1p')
    [ -n "$hit" ] || continue
    # A real footer is fine. Anything else with that shape is not.
    body=$(git show -s --format='%b' "$f")
    grep -qE '^Bench: *[1-9][0-9]{5,7}$' <<< "$body" && continue
    echo "$(git rev-parse --short=8 "$f")"
done
)

# tests/negative_control.sh mutates FILES and restores them, and a commit body is
# not a file, so no row can plant the defect this half exists to catch. It hands
# one in through here instead: a body read from ANCHOR_EXTRA_BODY is scanned by
# the same two greps and reported as `fixture`.
#
# It can only ADD an offender, never drop one, so nothing set in the environment
# can quiet this gate -- and nothing outside that one row sets it.
if [ -n "${ANCHOR_EXTRA_BODY:-}" ] && [ -f "$ANCHOR_EXTRA_BODY" ]; then
    fixture=$(cat "$ANCHOR_EXTRA_BODY")
    if grep -q '\b[Bb]ench[ :]\+[1-9][0-9]\{5,7\}\b' <<< "$fixture" \
       && ! grep -qE '^Bench: *[1-9][0-9]{5,7}$' <<< "$fixture"; then
        offenders=$(printf '%s\nfixture\n' "$offenders" | grep -v '^$')
    fi
fi

if [ -f "$BASELINE" ]; then
    known=$(grep -vE '^\s*(#|$)' "$BASELINE" | awk '{print $1}' | sort -u)
else
    known=""
fi

new=$(comm -23 <(printf '%s\n' "$offenders" | grep -v '^$' | sort -u) \
               <(printf '%s\n' "$known" | grep -v '^$'))
gone=$(comm -13 <(printf '%s\n' "$offenders" | grep -v '^$' | sort -u) \
                <(printf '%s\n' "$known" | grep -v '^$'))

if [ -z "$offenders" ]; then
    echo "  none"
else
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        # `fixture` is the row ANCHOR_EXTRA_BODY hands in, and it is not a
        # revision: asking git to resolve it prints `fatal: ambiguous argument`
        # into a gate's own report, which reads as the gate breaking rather than
        # as the finding it is.
        if [ "$c" = "fixture" ]; then
            subject="the body named by ANCHOR_EXTRA_BODY"
            body=$(cat "$ANCHOR_EXTRA_BODY")
        else
            subject=$(git log -1 --format='%s' "$c" | cut -c1-58)
            body=$(git show -s --format='%b' "$c")
        fi
        printf '  %-10s %s\n' "$c" "$subject"
        grep -o '\b[Bb]ench[ :]\+[1-9][0-9]\{5,7\}\b' <<< "$body" \
          | sed 's/^/               [/; s/$/]/'
    done <<< "$offenders"
fi

echo
echo "== new =="
if [ -n "$new" ]; then
    printf '%s\n' "$new" | sed 's/^/  NEW      /'
    echo "  a body line reads as a bench footer -- reword it, or a lane will read it as the anchor"
    rc=1
else
    echo "  ok"
fi

echo
echo "== baseline entries that no longer happen =="
if [ -n "$gone" ]; then
    printf '%s\n' "$gone" | sed 's/^/  STALE    /'
    echo "  remove these from $BASELINE"
    rc=1
else
    echo "  ok"
fi

echo
[ "$rc" = 0 ] && echo "anchor: clean" || echo "anchor: FINDINGS"
exit "$rc"
