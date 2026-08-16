#!/bin/bash
# Every gate must be dispatched by something, or it is not a gate.
#
# A check nobody runs is a claim about the tree rather than a check on it. It
# reports nothing, so it never goes red, so nobody notices it stopped working --
# and it still looks like coverage in a directory listing.
#
# A script qualifies as dispatched when a REACHABLE workflow names it, or when
# it appears in EXCUSED below with a reason. Being run by another local gate
# does not qualify -- see dispatch_corpus. The excuse list is the hole, so it
# expires in its own direction: an excused script that IS dispatched is reported
# as a stale excuse, and an excuse naming a script the tree does not carry fails
# too.
#
# Two extraction traps, both of which produce a false green:
#   * a script named only in a COMMENT is not a script the workflow runs;
#   * a match that ignores what surrounds the name lets `subnet.sh` in a
#     workflow satisfy `net.sh`, and `net.shx` satisfy it too.
#
# Exit codes:  0 every gate dispatched   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

# The excuse list: a script that runs nowhere, and the reason.
#
# ONE array of `name<TAB>reason`, not two parallel ones. Two index-parallel
# arrays desynchronise the first time a name is removed without its reason, and
# nothing here would notice: every excuse below the removed index shifts up by
# one, the gate prints a reason belonging to a different script, and it still
# exits 0 because it only ever tested membership. That happened -- fingerprint.sh
# was excused as "invoked by the Makefile's net target" on a green run. A single
# array cannot express the state.
EXCUSED=(
  "npsab.sh	wall-clock A/B; a hosted runner is not an idle box, so a ratio measured there is noise"
  "npsthreads.sh	thread scaling; it needs an idle box AND real cores, and a hosted runner has two shared vCPUs -- a scaling curve measured there describes the hypervisor"
  "testing.py	a harness imported by instrumented.py rather than a gate"
  "uci_driver.py	an operator harness for driving the engine by hand; every check it can make is owned by a gate that IS dispatched -- signature.sh the bench, perft.sh the movegen -- and a lane running it would assert them twice"
  "get_native_properties.sh	invoked by the Makefile, not by a workflow"
  "net.sh	invoked by the Makefile's net target"
  "fingerprint.sh	callgrind over the whole call graph, far costlier than the budget gate; run by hand before a decomposition"
  "zones.sh	the zone table, sourced by depcheck.sh, linkcheck.sh, enginelink.sh and fuzzsearch.sh rather than run"
  "perfcounters.sh	reads the CPU's hardware counters; a virtualised hosted runner exposes no PMU, so a lane would skip every run"
  "perfcounters_report.py	the aggregation half of perfcounters.sh, invoked by it rather than run"
  "perfdecomp.sh	callgrind with the cache and branch simulators, roughly 50x; run by hand when a component moves"
  "perfdecomp.py	the decomposition half of perfdecomp.sh, invoked by it rather than run"
  "match.sh	plays games under a time control; a hosted runner is not idle, so it forfeits on time and scores the box"
)

# An entry with no reason excuses a script while saying nothing, which is the
# shape an excuse list rots into. Refuse rather than report a verdict.
for e in "${EXCUSED[@]}"; do
    case "$e" in
        *"	"*) : ;;
        *) echo "lanecheck: excuse entry carries no reason: $e" >&2; exit 1 ;;
    esac
done

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
    local n=$1 e
    for e in "${EXCUSED[@]}"; do
        [ "${e%%	*}" = "$n" ] && { printf '%s' "${e#*	}"; return 0; }
    done
    return 1
}

# A name is dispatched only when it appears with a path separator in front and
# a non-name character after, so `perft.sh` cannot be satisfied by `xperft.sh`
# and `net.sh` cannot be satisfied by `subnet.sh` or by `net.shx`.
# A here-string, not a pipe. With `set -o pipefail`, `grep -q` exits on the
# first match and the producer dies of SIGPIPE, whose status pipefail then
# propagates -- so an EARLY match reads as no match while a late one does not,
# and the answer depends on where in the corpus the name happens to appear.
dispatched() {
    local pat
    pat=$(printf '%s' "$1" | sed 's/\./\\./g')
    grep -qE "[/[:space:]\"']${pat}([[:space:]\"';)|&]|$)" <<< "$CORPUS"
}

# A workflow is REACHABLE when something can start it without a human: a push, a
# pull request, a schedule, a release, or a `uses:` from another workflow. A
# workflow that is only `workflow_call` and that nobody calls can never run, so
# every script it names is dispatched by nothing.
#
# The limit: a `uses:` counts whoever writes it, reachable or not, so a chain of
# unstartable callers would satisfy this test. The chain's head is still
# reported, because every workflow is judged on its own triggers here.
#
# This is the same failure the check exists to catch, one level up: without the
# reachability pass a gate named only by an unstartable lane reports as
# dispatched, and the hole is laundered into a pass.
echo "== workflows and their reachability =="
UNREACHABLE=""
for w in .github/workflows/*.yml; do
    [ -f "$w" ] || continue
    b=$(basename "$w")
    # `workflow_dispatch` is deliberately NOT an automatic trigger. A workflow
    # only a human can click does not gate a change, so a gate it names is not
    # in a lane. Counting it as reachable lets a lane report as wired while
    # nothing on a push or a pull request can start it.
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
for entry in "${EXCUSED[@]}"; do
    e=${entry%%	*}
    # Two separate tests, because a script lives in one directory or the other,
    # never both: `ls tests/$e scripts/$e` fails when EITHER is missing and
    # would report every excused name as absent.
    if [ ! -e "tests/$e" ] && [ ! -e "scripts/$e" ]; then
        echo "  $e is excused but does not exist"; stale=1
    fi
done
[ "$stale" = "1" ] && note "an excuse names a script the tree no longer has"
[ "$stale" = "0" ] && echo "  ok"

echo
if [ "$FAIL" = "0" ]; then echo "lanecheck: clean"; else echo "lanecheck: FINDINGS"; fi
exit "$FAIL"
