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
  "ltcab.sh	a warm game replayed at depth; it wants an idle box for its wall clock and its counter columns, and one depth-20 replay is 34.6 M nodes per side per round -- a hosted runner measures the hypervisor and times out"
  "ltcreplay.py	the replay driver ltcab.sh invokes, and the node-clock instrument, rather than a gate run on its own"
  "npsthreads.sh	thread scaling; it needs an idle box AND real cores, and a hosted runner has two shared vCPUs -- a scaling curve measured there describes the hypervisor"
  "testing.py	a harness imported by instrumented.py rather than a gate"
  "get_native_properties.sh	invoked by the Makefile, not by a workflow"
  "net.sh	invoked by the Makefile's net target"
  "fingerprint.sh	callgrind over the whole call graph, far costlier than the budget gate; run by hand before a decomposition"
  "zones.sh	the zone table, sourced by depcheck.sh, linkcheck.sh, enginelink.sh and fuzzsearch.sh rather than run"
  "perfcounters.sh	reads the CPU's hardware counters; a virtualised hosted runner exposes no PMU, so a lane would skip every run"
  "perfcounters_report.py	the aggregation half of perfcounters.sh, invoked by it rather than run"
  "perfdecomp.sh	callgrind with the cache and branch simulators, roughly 50x; run by hand when a component moves"
  "perfdecomp.py	the decomposition half of perfdecomp.sh, invoked by it rather than run"
  "match.sh	plays games under a time control; a hosted runner is not idle, so it forfeits on time and scores the box"
  "devcite.sh	checks citations in __DEV/, which is gitignored -- a clone carries nothing for it to read, so a lane would have an empty corpus and pass. Run by hand before quoting a figure out of those pages"
)

# The same list, for WORKFLOWS that cannot start on this branch. It exists
# because branch filters made two of them unreachable here the moment this gate
# learned to read filters, and both are unreachable BY DESIGN rather than by
# neglect. Expires in both directions exactly as the script list does: an excused
# workflow that IS reachable is reported as a stale excuse.
#
# What it does NOT excuse is a gate going undispatched. Every gate this branch
# owns is dispatched by refish.yml, which is why teaching this gate about filters
# cost no coverage -- that is B10's claim, and this is the run that tested it.
EXCUSED_WORKFLOWS=(
  "stockfish.yml	upstream's orchestrator, master-only by upstream's choice. refish.yml is this branch's equivalent and calls the same reusable lanes; naming refish here is neither upstreamable nor removable once merged"
  "official_release.yml	upstream's tagged-release pipeline, and a release is a human decision: it takes a tag and a title as dispatch inputs, so no trigger can supply them. It calls the same reusable build lanes every other umbrella does and dispatches no gate of its own, so nothing is out of a lane because of it"
  "clang-format.yml	pull_request_target on master, and it comments on a pull request. A fork-private branch opens none, so there is nothing for it to run on. Formatting is held by the pre-commit hook, and CI's own clang-format step is continue-on-error even upstream, so no blocking gate is lost"
)

for e in "${EXCUSED_WORKFLOWS[@]}"; do
    case "$e" in
        *"	"*) : ;;
        *) echo "lanecheck: workflow excuse carries no reason: $e" >&2; exit 1 ;;
    esac
done

excuse_for_workflow() {
    local n=$1 e
    for e in "${EXCUSED_WORKFLOWS[@]}"; do
        [ "${e%%	*}" = "$n" ] && { printf '%s' "${e#*	}"; return 0; }
    done
    return 1
}

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
# Does an automatic trigger admit THIS branch?
#
# A branch filter is an unexpiring, invisible excuse: clang-format.yml is
# `pull_request_target: branches: [master]`, so on any other branch it can never
# start and every gate it names is dispatched by nothing -- while reachability
# computed from triggers alone reports it wired. That is the hole this gate
# exists to refuse, one level up from a missing lane.
#
# PER TRIGGER, not per workflow, and that distinction is the whole correctness of
# this function. codeql.yml carries `push: branches: [master]` AND a weekly
# `schedule:`. Judging the workflow on its push filter alone calls it unreachable
# here and invents a hole; the schedule has no branch filter and fires regardless.
#
#   push, pull_request, pull_request_target -- admit a branch their `branches:`
#       list matches, or every branch when they carry no list.
#   schedule, release -- carry no branch filter. They fire on the repository's
#       DEFAULT branch, which this gate cannot determine locally: origin/HEAD is
#       a cached ref and this repository's is stale (it says master while the
#       default moved to refish). So they are treated as admitting, and the run
#       says so rather than pretending to know.
#
# Getting this wrong in the permissive direction hides a hole; in the strict
# direction it invents one. Where the answer is unknowable the gate states the
# assumption instead of choosing silently.
#
# `branches-ignore` is not understood, and a workflow using it is reported as
# reachable with the same disclosure.
branch_admits() {
    local w=$1 body trig list f
    body=$(sed 's/[[:space:]]*#.*$//' "$w")

    case "$body" in *branches-ignore:*) SCHEDULED_ASSUMED=1; return 0 ;; esac

    # One record per automatic trigger: `<trigger><TAB><space-separated branches>`,
    # empty second field when the trigger carries no `branches:` key. Both list
    # forms the tree uses are read -- inline `["master"]` and a block of `- x`.
    while IFS=$'\t' read -r trig list; do
        [ -n "$trig" ] || continue
        case "$trig" in
            schedule|release) SCHEDULED_ASSUMED=1; return 0 ;;
        esac
        [ -n "$list" ] || return 0          # unfiltered push/PR: every branch
        for f in $list; do
            case "$f" in '*'|'**') return 0 ;; esac
            # shellcheck disable=SC2254
            # $f is a glob PATTERN out of the workflow and must stay unquoted.
            case "$BRANCH" in $f) return 0 ;; esac
        done
    done <<< "$(printf '%s\n' "$body" | awk '
        # Only inside the top-level `on:` block; a `push:` deeper in is not a
        # trigger. Triggers sit at exactly two spaces.
        /^on:/            { inon = 1; next }
        /^[^[:space:]]/   { inon = 0 }
        !inon             { next }
        /^  (push|pull_request|pull_request_target|schedule|release):/ {
            if (trig != "") { print trig "\t" branches }
            trig = $1; sub(/:.*/, "", trig); branches = ""; next
        }
        /^  [A-Za-z_]+:/  { if (trig != "") { print trig "\t" branches; trig = "" } next }
        trig != "" && /^[[:space:]]*branches:[[:space:]]*\[/ {
            line = $0; gsub(/.*\[|\].*/, "", line); gsub(/[",'"'"']/, " ", line)
            branches = branches " " line; next
        }
        trig != "" && /^[[:space:]]*branches:[[:space:]]*$/ { inlist = 1; next }
        inlist && /^[[:space:]]*-[[:space:]]*/ {
            line = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/[",'"'"']/, "", line); branches = branches " " line; next
        }
        inlist && /^[[:space:]]*[A-Za-z_-]+:/ { inlist = 0 }
        END { if (trig != "") print trig "\t" branches }
    ')"
    return 1
}

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
SCHEDULED_ASSUMED=0
echo "== workflows and their reachability (branch: $BRANCH) =="
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
    # shellcheck disable=SC2126
    # grep -c exits 1 on a zero count; the COUNT is wanted here, not the status.
    called=$(grep -l "workflows/$b" .github/workflows/*.yml 2>/dev/null \
             | grep -v "/$b$" | wc -l)
    # An automatic trigger that this branch is filtered out of is not a trigger
    # here, so it does not count. A `uses:` from another workflow still does --
    # that caller's own reachability is judged on its own row.
    if [ "$auto" -gt 0 ] && ! branch_admits "$w"; then
        auto=0
        filtered=" (its branch filters exclude $BRANCH)"
    else
        filtered=""
    fi
    if [ "$auto" -gt 0 ] || [ "$called" -gt 0 ]; then
        echo "  reachable    $w"
        if why=$(excuse_for_workflow "$b"); then
            note "STALE EXCUSE: $b is reachable but excused -- remove the excuse"
        fi
    elif [ "$manual" -gt 0 ] && why=$(excuse_for_workflow "$b"); then
        # Manual-only is a finding for the same reason UNREACHABLE is -- nothing it
        # names is in a lane -- so it answers to the same excuse, and to the same
        # rule that an excuse naming nothing is itself a finding.
        echo "  excused      $w (manual dispatch only) -- $why"
        UNREACHABLE="$UNREACHABLE $b"
    elif [ "$manual" -gt 0 ]; then
        echo "  MANUAL ONLY  $w"
        note "$w runs only on a manual dispatch, so nothing it names is in a lane"
        UNREACHABLE="$UNREACHABLE $b"
    elif why=$(excuse_for_workflow "$b"); then
        echo "  excused      $w$filtered -- $why"
        UNREACHABLE="$UNREACHABLE $b"
    else
        echo "  UNREACHABLE  $w$filtered"
        note "$w can never start here: no usable trigger and no workflow calls it$filtered"
        UNREACHABLE="$UNREACHABLE $b"
    fi
done

if [ "$SCHEDULED_ASSUMED" = 1 ]; then
    echo "  note: a schedule or release trigger was read as admitting this branch."
    echo "        Those fire on the repository's DEFAULT branch, which cannot be"
    echo "        determined here -- origin/HEAD is a cached ref and this one is"
    echo "        stale. Stated rather than guessed at silently."
fi

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
