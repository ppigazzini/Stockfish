#!/bin/bash
# Every gate must be dispatched by something, or it is not a gate.
#
# A check nobody runs is a claim about the tree rather than a check on it. It
# reports nothing, so it never goes red, so nobody notices it stopped working --
# and it still looks like coverage in a directory listing.
#
# A script qualifies as dispatched when a workflow runs it, another gate runs
# it, or it appears in EXCUSED below with a reason. The excuse list is the hole,
# so it expires in its own direction: an excused script that IS dispatched is
# reported as a stale excuse, and an excuse naming a script that no longer
# exists fails too.
#
# Two extraction traps, both of which produce a false green:
#   * a script named only in a COMMENT is not a script the workflow runs;
#   * a word boundary that accepts a suffix lets `foo.sh` satisfy `foobar.sh`.
#
# Exit codes:  0 every gate dispatched   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

# script            reason it runs nowhere
EXCUSED_NAMES=(
  npsab.sh
  negative_control.sh
  testing.py
  get_native_properties.sh
  net.sh
  fingerprint.sh
  zones.sh
)
EXCUSED_WHY=(
  "wall-clock A/B; a hosted runner is not an idle box, so a ratio measured there is noise"
  "mutates tracked sources and rebuilds per row, so it cannot share a checkout with a lane"
  "a harness imported by instrumented.py rather than a gate"
  "invoked by the Makefile, not by a workflow"
  "invoked by the Makefile's net target"
  "roughly 10x the cost of the budget gate; run by hand before a decomposition"
  "the zone table, sourced by depcheck.sh and linkcheck.sh rather than run"
)

FAIL=0
note() { echo "lanecheck: $*"; FAIL=1; }

[ -d .github/workflows ] || { echo "lanecheck: SKIPPED -- no .github/workflows" >&2; exit 2; }

# Strip comment lines before searching, so a script named in a `#` comment does
# not count as dispatched.
dispatch_corpus() {
    for w in .github/workflows/*.yml; do
        [ -f "$w" ] || continue
        # An unreachable workflow dispatches nothing, so it is not in the corpus.
        case " $UNREACHABLE " in *" $(basename "$w") "*) continue ;; esac
        sed 's/[[:space:]]*#.*$//' "$w"
    done
    # Workflows only. A gate invoked solely by another LOCAL gate is not
    # dispatched: if that gate runs nowhere the chain bottoms out at nothing,
    # and the hole gets laundered into a pass. Such a gate takes an excuse
    # naming what actually runs it.
}
excuse_for() {
    local n=$1 i=0
    for e in "${EXCUSED_NAMES[@]}"; do
        [ "$e" = "$n" ] && { echo "${EXCUSED_WHY[$i]}"; return 0; }
        i=$((i+1))
    done
    return 1
}

# A name is dispatched only when it appears with a path separator in front and
# a non-name character after, so `perft.sh` cannot be satisfied by `xperft.sh`
# and `net.sh` cannot be satisfied by `subnet.shx`.
# A here-string, not a pipe. With `set -o pipefail`, `grep -q` exits on the
# first match and the producer dies of SIGPIPE, whose status pipefail then
# propagates -- so an EARLY match reads as no match while a late one does not.
# That produced a matcher which reported the right answer only for scripts named
# near the end of the corpus.
dispatched() {
    local pat
    pat=$(printf '%s' "$1" | sed 's/\./\\./g')
    grep -qE "[/[:space:]\"']${pat}([[:space:]\"';)|&]|$)" <<< "$CORPUS"
}

# A workflow is REACHABLE when something can start it: a push, a pull request, a
# schedule, a manual dispatch, or a `uses:` from another reachable workflow. A
# workflow that is only `workflow_call` and that nobody calls can never run, so
# every script it names is dispatched by nothing.
#
# This is the same failure this check exists to catch, one level up, and it was
# live: the budget lane was `workflow_call` only and no umbrella job invoked it,
# so `perfbudget.sh` reported as dispatched by a workflow that could not start.
echo "== workflows and their reachability =="
UNREACHABLE=""
for w in .github/workflows/*.yml; do
    [ -f "$w" ] || continue
    b=$(basename "$w")
    # `workflow_dispatch` is deliberately NOT an automatic trigger. A workflow
    # only a human can click does not gate a change, so a gate it names is not
    # in a lane. Counting it as reachable is what let the budget lane report as
    # wired while nothing on a push or a pull request could start it.
    auto=$(sed 's/[[:space:]]*#.*$//' "$w" \
           | grep -cE '^[[:space:]]*(push|pull_request|pull_request_target|schedule|release):')
    manual=$(sed 's/[[:space:]]*#.*$//' "$w" | grep -cE '^[[:space:]]*workflow_dispatch:')
    called=$(grep -l "workflows/$b" .github/workflows/*.yml 2>/dev/null \
             | grep -v "/$b$" | wc -l)
    if [ "$auto" -gt 0 ] || [ "$called" -gt 0 ]; then
        echo "  reachable    $w"
    elif [ "$manual" -gt 0 ]; then
        echo "  MANUAL ONLY  $w"
        note "$w runs only on a manual dispatch, so nothing it names is in a lane"
        UNREACHABLE="$UNREACHABLE $b"
    else
        echo "  UNREACHABLE  $w"
        note "$w can never start: no trigger and no workflow calls it"
        UNREACHABLE="$UNREACHABLE $b"
    fi
done

CORPUS=$(dispatch_corpus)

echo
echo "== gates and their dispatch =="
for g in tests/*.sh tests/*.py scripts/*.sh; do
    [ -e "$g" ] || continue
    n=$(basename "$g")
    if dispatched "$n"; then
        if why=$(excuse_for "$n"); then
            note "STALE EXCUSE: $n is dispatched but excused -- remove the excuse"
        else
            echo "  dispatched   $g"
        fi
    else
        if why=$(excuse_for "$n"); then
            echo "  excused      $g -- $why"
        else
            echo "  UNDISPATCHED $g"
            note "$g runs nowhere and carries no excuse"
        fi
    fi
done

echo
echo "== excuses that name nothing =="
stale=0
for e in "${EXCUSED_NAMES[@]}"; do
    # `ls a b` fails when EITHER is missing, so it reported every excused name
    # as absent. A script lives in one directory or the other, never both.
    if [ ! -e "tests/$e" ] && [ ! -e "scripts/$e" ]; then
        echo "  $e is excused but does not exist"; stale=1
    fi
done
[ "$stale" = "1" ] && note "an excuse names a script the tree no longer has"
[ "$stale" = "0" ] && echo "  ok"

echo
if [ "$FAIL" = "0" ]; then echo "lanecheck: clean"; else echo "lanecheck: FINDINGS"; fi
exit "$FAIL"
