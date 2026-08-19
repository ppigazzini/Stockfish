#!/bin/bash
# Break the engine on purpose and require each gate to notice.
#
# A gate's power to detect a defect is an assumption until something breaks the
# code and the gate is watched going red. A gate that has quietly stopped being
# able to fail is invisible, because it reports success -- which is what everyone
# was hoping for.
#
# No mutation here removes a SEARCH BOUND. A mutant that hands the search an
# evaluation with no ceiling produces an experiment that never terminates, and a
# timeout is a rig fault, never a detection.
#
# Three ways the rig itself can be wrong, and all three refuse rather than
# return a verdict:
#
#   * the anchor string has rotted -- the tree is never mutated, the gate greens,
#     and that reads as "the gate failed to detect it";
#   * the mutation does not compile -- not a behavioural change;
#   * a selector names no row -- mutated nothing, proved nothing.
#
# The tree is restored from a trap, so an error or an interrupt anywhere still
# puts the sources back. The run ends by executing a gate green rather than by
# asserting the tree is clean.
#
# Exit codes:  0 every selected row detected its mutation   1 a row did not, or
# the rig refused   2 the repository root could not be entered. A row that
# SKIPPED leaves the status at 0, so read the skipped count and never the status
# alone -- the run below prints it for that reason.

# shellcheck disable=SC2016
# Every mutation anchor in this file is source text quoted VERBATIM -- shell
# stubs with $vars, markdown with backticks, YAML with ${{ }}. If any of it
# expanded the anchor would not match the file it is meant to cut. That is the
# file's entire design, so the directive is file-scoped rather than repeated
# thirteen times.

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

SELECT=${1:-all}
BACKUP=$(mktemp -d)
MUTATED=()

# A LIST, not one path. A row that mutates two files -- linkcheck needs a caller
# in one zone and a callee in another -- leaves the first behind if a single
# variable holds the path: the second mutate() overwrites it and restore() puts
# back only the last. The tree then stays broken past the row that broke it, and
# every later row measures a mutant it did not create.
#
# Key the backup by ORDINAL, not by basename. Keying by basename has the same
# failure one level down: a row that mutates the SAME file twice backs it up on
# the first call and then overwrites that backup with the already-mutated
# content on the second, so restore() puts back a half-mutant and reports
# success.
restore() {
    local i
    for ((i=${#MUTATED[@]}-1; i>=0; i--)); do
        local f=${MUTATED[$i]}
        [ -f "$BACKUP/$i" ] && cp "$BACKUP/$i" "$f"
    done
    MUTATED=()
}
# shellcheck disable=SC2329
# invoked by `trap cleanup EXIT INT TERM` below, which shellcheck cannot see
cleanup() { restore; rm -rf "$BACKUP"; }
trap cleanup EXIT INT TERM

die() { echo "negative-control: $*" >&2; exit 1; }

# instrumented.py imports requests through tests/testing.py. uv supplies it
# without installing anything; fall back to a bare python3 where it is already
# importable, and to empty (skip) where neither works.
if command -v uv >/dev/null; then
    RUNPY="uv run --with requests python"
elif python3 -c 'import requests' 2>/dev/null; then
    RUNPY="python3"
else
    RUNPY=""
fi

# Apply one literal substitution, refusing if the anchor is not present exactly
# once. A rotted anchor must not silently leave the tree unmutated.
mutate() {
    local file=$1 from=$2 to=$3
    [ -f "$file" ] || die "no such file: $file"
    # Counted in python, not grep: `grep -F` with an embedded newline treats
    # each line of the pattern as a separate pattern, so a multi-line anchor is
    # counted per line and a unique anchor reads as duplicated.
    local n
    n=$(python3 -c 'import sys; print(open(sys.argv[1],encoding="utf8").read().count(sys.argv[2]))' \
        "$file" "$from")
    [ "$n" = "1" ] || die "anchor appears $n times in $file (want exactly 1): $from"
    cp "$file" "$BACKUP/${#MUTATED[@]}"
    MUTATED+=("$file")
    python3 - "$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p, encoding="utf8").read()
assert t.count(a) == 1
open(p, "w", encoding="utf8").write(t.replace(a, b))
PY
}

PASS=0; FAIL=0; SKIP=0
KNOWN=""
STATIC=""

# `all`, one row by name, or `static` -- the rows that need no build. The static
# group runs in about a minute and a half, which is what makes it affordable on
# every push while the full set, which builds the engine once per row, is not.
selected() {
    [ "$SELECT" = all ] && return 0
    [ "$SELECT" = "$1" ] && return 0
    if [ "$SELECT" = static ]; then
        case " $STATIC " in *" $1 "*) return 0 ;; esac
    fi
    return 1
}

# Declare a row, and tag it `static` when it reads the tree and never builds the
# engine. The tag lives on the declaration rather than in a list kept somewhere
# else, because a list somewhere else is what goes stale the first time a row is
# added -- and a row that quietly leaves the group is a row the per-push lane
# stops running while still reporting a pass.
row() {
    KNOWN="$KNOWN $1"
    [ "${2:-}" = static ] && STATIC="$STATIC $1"
    return 0
}

# --------------------------------------------------------------- signature

row signature
if selected signature; then
    REF=$(git log --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
    if [ -z "$REF" ]; then
        echo "negative-control: signature   SKIPPED -- no Bench: anywhere in the commit record"
        SKIP=$((SKIP+1))
    else
        echo "negative-control: signature   -- futility multiplier base 45 -> 46"
        mutate src/engine/search.cpp \
            'Value futilityMult = std::min(45 + depth * 4, 85);' \
            'Value futilityMult = std::min(46 + depth * 4, 85);'
        if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
            if ( cd src && ../tests/signature.sh "$REF" ) >/dev/null 2>&1; then
                echo "  NOT DETECTED -- the bench still reproduced $REF"; FAIL=$((FAIL+1))
            else
                echo "  ok, red (1)"; PASS=$((PASS+1))
            fi
        else
            restore; die "the signature mutant did not compile -- not a behavioural change"
        fi
        restore
    fi
fi

# --------------------------------------------------------------- perfbudget

row perfbudget
if selected perfbudget; then
    if ! command -v valgrind >/dev/null; then
        echo "negative-control: perfbudget  SKIPPED -- valgrind is not installed"; SKIP=$((SKIP+1))
    else
        echo "negative-control: perfbudget  -- adjust_key50 forced out of line"
        mutate src/engine/position.h \
            'template<bool AfterMove>
inline Key Position::adjust_key50(Key k) const {' \
            'template<bool AfterMove>
__attribute__((noinline)) Key Position::adjust_key50(Key k) const {'
        if ./tests/perfbudget.sh HEAD worktree >/dev/null 2>&1; then
            echo "  NOT DETECTED -- the budget stayed within tolerance"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
        restore
    fi
fi

# --------------------------------------------------------------- textequal

row textequal
if selected textequal; then
    echo "negative-control: textequal   -- adjust_key50 forced out of line"
    mutate src/engine/position.h \
        'template<bool AfterMove>
inline Key Position::adjust_key50(Key k) const {' \
        'template<bool AfterMove>
__attribute__((noinline)) Key Position::adjust_key50(Key k) const {'
    if ./tests/textequal.sh HEAD worktree >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the disassembly compared equal"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

# --------------------------------------------------------------- docslint

row docslint static
if selected docslint; then
    echo "negative-control: docslint    -- a dead link in the index"
    mutate docs/README.md \
        '| [00-architecture.md](00-architecture.md) |' \
        '| [00-architecture.md](99-nonexistent.md) |'
    if ./tests/docslint.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the lint reported clean"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

# --------------------------------------------------------------- golden

row golden
if selected golden; then
    echo "negative-control: golden      -- an info field renamed, which the signature cannot see"
    mutate src/shell/uci.cpp \
        '<< " multipv " << info.multiPV' \
        '<< " MULTIPV " << info.multiPV'
    if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
        if ./tests/golden.sh >/dev/null 2>&1; then
            echo "  NOT DETECTED -- the corpus matched a renamed field"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
    else
        restore; die "the golden mutant did not compile"
    fi
    restore
    ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
fi

row golden-empty static
if selected golden-empty; then
    echo "negative-control: golden      -- an empty corpus must not pass"
    mv tests/cases /tmp/nc_cases_$$
    mkdir -p tests/cases
    if ./tests/golden.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a corpus that compared nothing passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    rmdir tests/cases 2>/dev/null
    mv /tmp/nc_cases_$$ tests/cases
fi

row docslint-path static
if selected docslint-path; then
    echo "negative-control: docslint    -- a named path that is not in the tree"
    mutate docs/00-architecture.md \
        '## Startup' \
        'The scheduler lives in `src/scheduler.cpp`.

## Startup'
    if ./tests/docslint.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the lint accepted a path that does not exist"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row docslint-bench static
if selected docslint-bench; then
    REF=$(git log --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
    if [ -z "$REF" ]; then
        echo "negative-control: docslint    SKIPPED -- no Bench: in the commit record"
        SKIP=$((SKIP+1))
    else
        echo "negative-control: docslint    -- a page quoting the current bench signature"
        mutate docs/10-tooling-ci.md \
            '## `tests/perft.sh`' \
            "The reference is $REF today.

## \`tests/perft.sh\`"
        if ./tests/docslint.sh >/dev/null 2>&1; then
            echo "  NOT DETECTED -- the lint accepted a pinned signature"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
        restore
    fi
fi

row docslint-gate static
if selected docslint-gate; then
    echo "negative-control: docslint    -- a gate no page names"
    printf '#!/bin/bash\nexit 0\n' > tests/zzz_undocumented.sh
    chmod +x tests/zzz_undocumented.sh
    if ./tests/docslint.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- an undiscoverable gate passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    rm -f tests/zzz_undocumented.sh
fi

row docslint-lanes static
if selected docslint-lanes; then
    # The CI table against the workflows. This is the one LIST docslint owns,
    # and the row exists because the table fell nine rows behind the YAML while
    # the paragraph beside it told the reader that a list drifting by one entry
    # reads exactly like one that has not.
    #
    # Drop a gate from the PROSE rather than from a workflow: mutating the YAML
    # would also change what CI runs, and a row that alters the lanes it is
    # checking is testing two things at once.
    echo "negative-control: docslint [lanes] -- a CI row a gate behind must be caught"
    mutate docs/10-tooling-ci.md \
        '| `iwyu.yml` | `iwyu.sh` in native mode, which is the only mode with an absolute verdict |' \
        '| `iwyu.yml` | include hygiene |'
    if ./tests/docslint.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a row naming no gate for a lane that runs one passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row docslint-internal static
if selected docslint-internal; then
    echo "negative-control: docslint    -- a tracked file pointing into the ignored area"
    # Read the needle out of docslint.sh rather than naming it. A
    # literal here would make THIS file a tracked file pointing into it, which
    # is the thing the check catches -- and widening the check's exemption list
    # to cover the script that injects the fault weakens the check itself.
    internal=$(sed -n "s/^INTERNAL='\\(.*\\)'$/\\1/p" tests/docslint.sh)
    [ -n "$internal" ] || die "could not read the needle out of tests/docslint.sh"
    mutate AGENTS.md \
        '## Commits' \
        "See $internal/notes.md for more.

## Commits"
    if ./tests/docslint.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a dangling reference into an ignored path passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row docslint-selector static
if selected docslint-selector; then
    echo "negative-control: docslint    -- the two selector tables out of step"
    # Drop the row from the PAGE, not from AGENTS.md. That is the direction the
    # defect actually took: the six axes were added to AGENTS.md and the page's
    # copy kept five, under a sentence saying there were five because there were
    # five questions.
    mutate docs/10-tooling-ci.md \
        '| "this scales" | `tests/npsthreads.sh` | every other axis runs one thread, so a contention change is invisible to all five |
' \
        ''
    if ./tests/docslint.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a selector table missing an axis passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row fingerprint
if selected fingerprint; then
    if ! command -v valgrind >/dev/null; then
        echo "negative-control: fingerprint SKIPPED -- valgrind is not installed"; SKIP=$((SKIP+1))
    else
        echo "negative-control: fingerprint -- adjust_key50 forced out of line"
        mutate src/engine/position.h \
            'template<bool AfterMove>
inline Key Position::adjust_key50(Key k) const {' \
            'template<bool AfterMove>
__attribute__((noinline)) Key Position::adjust_key50(Key k) const {'
        if ./tests/fingerprint.sh HEAD worktree >/dev/null 2>&1; then
            echo "  NOT DETECTED -- the call graph compared equal"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
        restore
    fi
fi

# --------------------------------------------------------------- lanecheck

row lanecheck-reach static
if selected lanecheck-reach; then
    # BOTH orchestrators, and that is the point of the row rather than an
    # inconvenience. A lane is unreachable only when NOTHING calls it, so a
    # mutation that unwires it from one caller while another still names it
    # proves the gate can see a case that is not there. Two umbrellas exist --
    # stockfish.yml for the branches upstream builds and refish.yml for this one
    # -- so cutting one leaves perfbudget.yml reachable and lanecheck stays
    # correctly green. This row went NOT DETECTED the moment the second umbrella
    # landed, which is the mutation reporting on itself.
    echo "negative-control: lanecheck   -- the budget lane unwired from every umbrella"
    mutate .github/workflows/stockfish.yml \
        '  PerfBudget:
    name: Perf budget
    if: ${{ always() }}
    uses: ./.github/workflows/perfbudget.yml
' \
        ''
    mutate .github/workflows/refish.yml \
        '  PerfBudget:
    name: Perf budget
    if: ${{ always() }}
    uses: ./.github/workflows/perfbudget.yml
' \
        ''
    if ./tests/lanecheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- lanecheck called an unreachable lane reachable"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row lanecheck static
if selected lanecheck; then
    echo "negative-control: lanecheck   -- a gate with no lane and no excuse"
    printf '#!/bin/bash\nexit 0\n' > tests/zzz_unlaned.sh
    chmod +x tests/zzz_unlaned.sh
    if ./tests/lanecheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- lanecheck reported clean"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    rm -f tests/zzz_unlaned.sh
fi

# --------------------------------------------------------------- depcheck

row lanecheck-branchfilter static
if selected lanecheck-branchfilter; then
    echo "negative-control: lanecheck   -- a branch filter that excludes this branch"
    # A branch filter is an unexpiring, invisible excuse: before this gate could
    # read one, codeql.yml and clang-format.yml reported as reachable on a branch
    # neither could ever start on. docs.yml is used here because it dispatches
    # gates nothing else does, so cutting it off is visible downstream too.
    # refish.yml, because NOTHING calls it: a workflow another one `uses:` stays
    # reachable through its caller no matter what its own filters say, so
    # mutating a called workflow would test nothing. This is also the umbrella
    # that dispatches most gates here, so cutting it off is visible downstream.
    mutate .github/workflows/refish.yml \
        '  push:
    branches:
      - refish' \
        '  push:
    branches:
      - no-such-branch'
    if ./tests/lanecheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a workflow filtered off this branch read as reachable"
        FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row lanecheck-stale-workflow-excuse static
if selected lanecheck-stale-workflow-excuse; then
    echo "negative-control: lanecheck   -- a workflow excuse that has stopped being true"
    # The excuse list expires in BOTH directions, the same rule the script list
    # follows. Giving stockfish.yml a trigger this branch matches must report the
    # excuse as stale rather than quietly keeping it.
    mutate .github/workflows/stockfish.yml \
        '    branches:
      - master
      - tools
      - github_ci' \
        '    branches:
      - master
      - tools
      - github_ci
      - refish'
    # Captured, then matched against a here-string. NOT `lanecheck.sh | grep -q`:
    # under `set -o pipefail` grep exits at the first match, the producer dies of
    # SIGPIPE, and pipefail propagates that status -- so a MATCH reads as no
    # match and the row reports NOT DETECTED for a gate that worked. lanecheck.sh
    # documents this trap in its own dispatched(); this row was written straight
    # into it.
    out=$(./tests/lanecheck.sh 2>&1)
    if grep -q 'STALE EXCUSE: stockfish.yml' <<< "$out"; then
        echo "  ok, red (1)"; PASS=$((PASS+1))
    else
        echo "  NOT DETECTED -- a reachable workflow kept its excuse"; FAIL=$((FAIL+1))
    fi
    restore
fi

row actionpins-pin static
if selected actionpins-pin; then
    # A CACHE THAT HIDES A FINDING IS WORSE THAN THE FLAKINESS IT CURED. The
    # network half now answers from resources/actionpins-cache.tsv when it can,
    # so this row runs with that cache WARM and requires the gate to still catch
    # a pin whose SHA is not the tag it claims -- which is the point of the
    # cache: it stores what the tag resolves to, and the comparison against the
    # pin is unchanged.
    echo "negative-control: actionpins  -- a pin whose SHA is not its claimed tag"
    ./tests/actionpins.sh >/dev/null 2>&1 || true   # warm the cache first
    mutate .github/workflows/golden.yml \
        'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' \
        'actions/cache@0000000000000000000000000000000000000000 # v6.1.0'
    if ./tests/actionpins.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a pin that lies about its tag passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row actionpins-guards static
if selected actionpins-guards; then
    echo "negative-control: actionpins  -- a job with no deadline, a workflow with no floor"
    mutate .github/workflows/docs.yml \
        '    timeout-minutes: 10
' \
        ''
    if ./tests/actionpins.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a job with no timeout passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
    mutate .github/workflows/docs.yml \
        'permissions:
  contents: read
' \
        ''
    if ./tests/actionpins.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a workflow with no permissions block passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (2)"; PASS=$((PASS+1))
    fi
    restore
fi

row actionpins-unresolved static
if selected actionpins-unresolved; then
    echo "negative-control: actionpins  -- an unanswered API must not read as a verdict"
    # An INVERSE row, like optiondefaults-rig: the property is not that the gate
    # goes red, it is that a check which did not run cannot be reported as one
    # that did. The gate used to run `gh api ... 2>/dev/null` and treat the empty
    # result as "upstream has no such tag", so a rate limit produced a screenful
    # of findings and the gate flipped without the tree changing.
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        fake=$(mktemp -d)
        printf '#!/bin/bash\ncase "$1" in\n  auth) exit 0 ;;\n  api) echo "gh: API rate limit exceeded (HTTP 403)" >&2; exit 1 ;;\nesac\n' \
            > "$fake/gh"
        chmod +x "$fake/gh"
        out=$(PATH="$fake:$PATH" ./tests/actionpins.sh 2>&1)
        if printf '%s' "$out" | grep -q 'unresolved: [1-9]'; then
            if printf '%s' "$out" | grep -q 'no such tag upstream'; then
                echo "  NOT DETECTED -- a 403 was reported as a missing tag"; FAIL=$((FAIL+1))
            else
                echo "  ok, red (1)"; PASS=$((PASS+1))
            fi
        else
            echo "  NOT DETECTED -- the gate did not count the unanswered calls"; FAIL=$((FAIL+1))
        fi
        rm -rf "$fake"
    else
        echo "  SKIPPED -- no authenticated gh, so the network half does not run"
    fi
fi

row depcheck-friend static
if selected depcheck-friend; then
    echo "negative-control: depcheck    -- an engine header befriending a platform type"
    # The edge that survived every zone gate this branch has. A forward
    # declaration emits no symbol, so linkcheck and enginelink cannot see it, and
    # it is not an include, so the three include rules cannot either. If this row
    # ever goes NOT DETECTED the textual check has stopped being the only thing
    # holding that boundary.
    mutate src/engine/search.h \
        '    friend struct HeadlessRunner;' \
        '    friend class Stockfish::ThreadPool;
    friend struct HeadlessRunner;'
    if ./tests/depcheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- depcheck passed an engine friend naming a platform type"
        FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row depcheck-platform-shell static
if selected depcheck-platform-shell; then
    echo "negative-control: depcheck    -- a platform file reaching into the shell"
    # Written with TWO levels of `../`, deliberately. The rule resolves an include
    # by basename through zone_of rather than by matching the path, and this row
    # is what holds that: a rule anchored on `../shell` would pass this mutation
    # while the edge is live. An audit of this tree made exactly that mistake and
    # reported an existing edge as severed.
    mutate src/platform/thread.cpp \
        '#include "numa_shared.h"' \
        '#include "numa_shared.h"
#include "../../shell/console.h"'
    if ./tests/depcheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- depcheck passed a live platform -> shell include"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

# --------------------------------------------------------------- shellcheck

row shellcheck static
if selected shellcheck; then
    echo "negative-control: shellcheck  -- an unquoted expansion in an in-scope script"
    # A NEW script, which is also the row's second job: the gate's scope rule
    # says a file absent from the fork point is in scope, and this row is what
    # proves it. The first version of shellcheck.sh got that backwards --
    # `git diff BASE HEAD -- <untracked>` reports no difference because the path
    # is on neither side, so the gate excused itself and reported clean over a
    # set that did not contain it.
    printf '#!/bin/bash\nd=$1\nls $d\n' > tests/zzz_lint.sh
    chmod +x tests/zzz_lint.sh
    out=$(./tests/shellcheck.sh 2>&1); rc=$?
    if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'zzz_lint\.sh'; then
        echo "  ok, red (1)"; PASS=$((PASS+1))
    elif [ "$rc" = 2 ]; then
        echo "  SKIPPED -- shellcheck not available"
    else
        echo "  NOT DETECTED -- shellcheck.sh rc=$rc and did not name the new script"
        FAIL=$((FAIL+1))
    fi
    rm -f tests/zzz_lint.sh
fi

# --------------------------------------------------------------- devcite

# Three rows, because devcite.sh makes three separable claims and a single row
# would leave two of them able to pass while broken.
#
# NONE of these uses mutate/restore, and that is forced rather than chosen:
# `__DEV/` is gitignored, `restore` copies a backup over a file it recorded, and
# the corpus these rows need does not exist in a clone at all. So each row
# CREATES a throwaway page, asserts red, and removes it -- the same shape as the
# `zzz_unlaned.sh` row above, for the same reason.
#
# A missing `__DEV/` makes devcite.sh SKIP (exit 2), and a skip is not a red. The
# rows therefore assert `rc == 1` rather than `rc != 0`, or a clone without the
# working area would report three passes it never earned.
#
# AND EACH ROW GREPS FOR ITS OWN FINDING rather than resting on the exit code.
# That is not belt-and-braces: on the tree these rows were written against,
# devcite.sh was ALREADY red -- check 5 had found real content loss in
# Stockfish-bugs.md. Three rows testing `rc == 1` would all have passed without
# the mutations doing anything, which is `optiondefaults-rig`'s failure exactly:
# a comparison that passes on an empty field set. A row must fail when its own
# mutation is reverted, and only naming the throwaway page proves that.

row devcite static
if selected devcite; then
    echo "negative-control: devcite     -- a rebase-fragile citation with no subject"
    if [ -d __DEV ]; then
        # A commit object reachable from NO ref, made here rather than borrowed
        # from the repo's backup branches. Borrowing one would tie the row to
        # this machine's refs: on a clone without them the SHA is not a commit,
        # devcite skips it, and the row reports NOT DETECTED for the wrong
        # reason.
        ncsha=$(git commit-tree 'HEAD^{tree}' -p HEAD \
                -m 'negative-control: unreferenced commit' </dev/null 2>/dev/null)
        if [ -n "$ncsha" ]; then
            printf '# negative control\n\nCited: `%s` and nothing else.\n' \
                   "${ncsha:0:8}" > __DEV/zzz_negctl.md
            out=$(./tests/devcite.sh 2>&1); rc=$?
            if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'zzz_negctl\.md'; then
                echo "  ok, red (1)"; PASS=$((PASS+1))
            else
                echo "  NOT DETECTED -- devcite rc=$rc and did not name the page"
                FAIL=$((FAIL+1))
            fi
            rm -f __DEV/zzz_negctl.md
        else
            echo "  SKIPPED -- git commit-tree produced nothing"
        fi
    else
        echo "  SKIPPED -- no __DEV/ in this tree"
    fi
fi

row devcite-placeholder static
if selected devcite-placeholder; then
    echo "negative-control: devcite     -- a citation placeholder left in a table"
    if [ -d __DEV ]; then
        printf '# negative control\n\n| 1 | done | `SHA99` |\n' > __DEV/zzz_negctl2.md
        out=$(./tests/devcite.sh 2>&1); rc=$?
        if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'zzz_negctl2\.md'; then
            echo "  ok, red (1)"; PASS=$((PASS+1))
        else
            echo "  NOT DETECTED -- devcite rc=$rc and did not name the page"
            FAIL=$((FAIL+1))
        fi
        rm -f __DEV/zzz_negctl2.md
    else
        echo "  SKIPPED -- no __DEV/ in this tree"
    fi
fi

row devcite-fence static
if selected devcite-fence; then
    echo "negative-control: devcite     -- an unclosed code fence"
    if [ -d __DEV ]; then
        # The check that found real content loss on this tree: an unmatched
        # opener makes every line after it read as code, which silently disables
        # the line-oriented checks above it.
        printf '# negative control\n\n```sh\necho unterminated\n' > __DEV/zzz_negctl3.md
        out=$(./tests/devcite.sh 2>&1); rc=$?
        if [ "$rc" = 1 ] && printf '%s' "$out" | grep -q 'zzz_negctl3\.md'; then
            echo "  ok, red (1)"; PASS=$((PASS+1))
        else
            echo "  NOT DETECTED -- devcite rc=$rc and did not name the page"
            FAIL=$((FAIL+1))
        fi
        rm -f __DEV/zzz_negctl3.md
    else
        echo "  SKIPPED -- no __DEV/ in this tree"
    fi
fi

# --------------------------------------------------------------- liveness

row liveness
if selected liveness; then
    # Defect 3's fix, removed. UCIEngine::apply_idle stops the search before it
    # waits for it; without the stop, the UCI reader thread waits on a search
    # only that same thread could end, so `stop` and `quit` are never read
    # again. The engine does not crash and returns no wrong answer -- it stops
    # answering, which is the one failure every other gate here reads as its own
    # timeout.
    echo "negative-control: liveness    -- the wait that no longer stops the search"
    mutate src/shell/uci.cpp \
        '    engine.stop();
    engine.wait_for_search_finished();
    mutate();' \
        '    engine.wait_for_search_finished();
    mutate();'
    if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
        # A short deadline: the mutant wedges forever, so waiting the default 20s
        # per case buys nothing and the row is run on every static sweep.
        if DEADLINE=8 ./tests/liveness.sh >/dev/null 2>&1; then
            echo "  NOT DETECTED -- a wedged engine reported as answering"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
    else
        restore; die "the liveness mutant did not compile"
    fi
    restore
    ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
fi

# --------------------------------------------------------------- arena

row arena-swap
if selected arena-swap; then
    # engine/arena.h states the ordering invariant in prose -- set_arena "must
    # never be called while anything allocated from the previous arena is still
    # live" -- and until the block counter landed nothing in the tree could see a
    # violation. A block taken from one allocator and released by another is heap
    # corruption with no diagnostic, so the failure this guards reports NOTHING
    # on its own: no crash at the swap, no wrong answer, just a free through the
    # wrong allocator later.
    #
    # The mutation takes a block from the DEFAULT arena and then swaps, which is
    # the exact sequence ArenaInstallerTag exists to make impossible by running
    # before every allocating member.
    #
    # Asserts-only, so this row builds `debug=yes`: under NDEBUG the counter and
    # its updates do not exist, which is what keeps the shipped allocation path a
    # bare indirect call.
    echo "negative-control: arena       -- the arena swapped under a live block"
    mutate src/shell/engine.cpp \
        '    set_arena({aligned_large_pages_alloc, aligned_large_pages_alloc_with_hint,
               aligned_large_pages_free, HugePageSize});' \
        '    void* ncLive = arena_alloc(64);
    (void) ncLive;
    set_arena({aligned_large_pages_alloc, aligned_large_pages_alloc_with_hint,
               aligned_large_pages_free, HugePageSize});'
    # objclean first: `debug=yes` also turns on _GLIBCXX_DEBUG, which changes the
    # standard library's ABI, and a flag change alone does not force a rebuild.
    # Linking debug objects against release ones fails on a std::__debug:: symbol
    # and says nothing about the mode, which is a confusing way to lose a row.
    if ( cd src && make objclean >/dev/null 2>&1;
         make -j"$(nproc)" build ARCH=x86-64-avx2 debug=yes ) >/dev/null 2>&1; then
        out=$( ( cd src && printf 'quit\n' | ./stockfish ) 2>&1 )
        rc=$?
        if [ "$rc" != 0 ] && grep -q 'arena_live_blocks() == 0' <<< "$out"; then
            echo "  ok, red (1)"; PASS=$((PASS+1))
        else
            echo "  NOT DETECTED -- the swap under a live block was not reported (rc=$rc)"
            FAIL=$((FAIL+1))
        fi
    else
        restore; die "the arena mutant did not compile"
    fi
    restore
    ( cd src && make objclean >/dev/null 2>&1; make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
fi

# --------------------------------------------------------------- perft

row perft
if selected perft; then
    if false; then :
    else
        echo "negative-control: perft       -- no knight under-promotion"
        mutate src/engine/movegen.cpp \
            '*moveList++ = Move::make<PROMOTION>(from, to, KNIGHT);' \
            ''
        if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
            if ( cd src && ../tests/perft.sh ) >/dev/null 2>&1; then
                echo "  NOT DETECTED -- perft still matched"; FAIL=$((FAIL+1))
            else
                echo "  ok, red (1)"; PASS=$((PASS+1))
            fi
        else
            restore; die "the perft mutant did not compile"
        fi
        restore
    fi
fi

# --------------------------------------------------------------- instrumented

row instrumented
if selected instrumented; then
    # instrumented.py is a merge gate -- sanitizers.yml and matetrack.yml both
    # run it -- so it needs a row that watches it fail. The mutation targets the
    # contract its assertions actually rest on: _expect_critical requires a
    # non-zero exit AND the literal "CRITICAL ERROR" in the output, so renaming
    # the banner leaves the exit code alone and breaks only the string. Removing
    # the validation instead would leave the engine dying for some other reason
    # and the test passing for the wrong one.
    if [ -z "$RUNPY" ]; then
        echo "negative-control: instrumented SKIPPED -- no requests and no uv to supply it"
        SKIP=$((SKIP+1))
    else
        echo "negative-control: instrumented -- the CRITICAL ERROR contract renamed"
        mutate src/shell/uci.cpp \
            'sync_cout << "info string CRITICAL ERROR: Command `" << currentCmd' \
            'sync_cout << "info string SEVERE PROBLEM: Command `" << currentCmd'
        if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
            if ( cd src && $RUNPY ../tests/instrumented.py --none ./stockfish ) >/dev/null 2>&1; then
                echo "  NOT DETECTED -- the suite passed a renamed error contract"; FAIL=$((FAIL+1))
            else
                echo "  ok, red (1)"; PASS=$((PASS+1))
            fi
        else
            restore; die "the instrumented mutant did not compile"
        fi
        restore
        ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
    fi
fi

# --------------------------------------------------------------- tbfetch

row tbfetch
if selected tbfetch; then
    # tbfetch verifies by MAGIC rather than by HTTP status, because a mirror
    # that answers a missing file with a body -- an error page, a redirect to a
    # landing page -- would otherwise be stored as a table and fail much later
    # inside the decoder, reading as corruption rather than as a bad download.
    # Serve exactly that from a file:// mirror, so the row needs no network.
    echo "negative-control: tbfetch     -- a mirror serving a body that is not a table"
    NCMIRROR=$(mktemp -d); NCDEST=$(mktemp -d)
    for stem in KQvK KRvK KPvK KNvK KBvK; do
        for ext in rtbw rtbz; do
            printf '<!DOCTYPE html><title>404</title>' > "$NCMIRROR/$stem.$ext"
        done
    done
    if TB_MIRROR="file://$NCMIRROR" ./tests/tbfetch.sh "$NCDEST" >/dev/null 2>&1; then
        echo "  NOT DETECTED -- an HTML body was accepted as a tablebase"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    # And the inverse: nothing was left behind for a later run to trust.
    if [ -n "$(ls -A "$NCDEST" 2>/dev/null)" ]; then
        echo "  NOT DETECTED -- a rejected download was still stored"; FAIL=$((FAIL+1))
    fi
    rm -rf "$NCMIRROR" "$NCDEST"
fi

# --------------------------------------------------------------- malformed

row malformed
if selected malformed; then
    # malformed.sh's claim is that a file refused yesterday is refused today, so
    # the mutation has to be a BOUND rather than a behaviour beside it. Every
    # other decision in set() stays exactly where it was; only the answer to
    # "does the file hold this span" is removed, by putting the mapping's end a
    # million times further out than the file.
    #
    # Two fixtures ride on that answer alone -- the btree the file declares 65535
    # symbols for, and the real table whose flags byte sends the parser down the
    # full decode path -- and both go back to reading past the mapping.
    echo "negative-control: malformed   -- the mapping end pushed past the file"
    mutate src/platform/syzygy/tbprobe.cpp \
        'if (data && !set(e, data, (const u8*) e.baseAddress + size))' \
        'if (data && !set(e, data, (const u8*) e.baseAddress + size * 1024 * 1024))'
    ./tests/malformed.sh >/dev/null 2>&1; NCRC=$?
    restore
    if [ "$NCRC" = "2" ]; then
        # Exit 2 is SKIPPED, and reading it as a detection is the whole failure
        # this file exists to prevent one level up.
        echo "  SKIPPED -- malformed.sh could not build or run"; SKIP=$((SKIP+1))
    elif [ "$NCRC" = "0" ]; then
        echo "  NOT DETECTED -- a table describing more than the file holds was accepted"
        FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
fi

# --------------------------------------------------------------- leb128

# STATIC, and it is the only row in that group that compiles anything. The group
# is defined as rows that never build the ENGINE, not rows that never invoke a
# compiler: this gate builds one translation unit against a header, which is
# seconds, and leaving it out of the per-push lane would leave the network
# reader controlled only by a lane nobody runs on a push.
#
# The shift step is the mutation because it is the reader's arithmetic rather
# than one of its refusals: a decoder that advances the exponent by six bits
# reads every multi-group value wrong and still accepts every stream, so nothing
# but a value comparison can see it. It takes 7 of the gate's 12 cases with it.
row leb128 static
if selected leb128; then
    echo "negative-control: leb128      -- the LEB128 shift step, 7 bits to 6"
    mutate src/engine/nnue/nnue_common.h \
        'shift += 7;' \
        'shift += 6;'
    ./tests/leb128.sh --iter 5 --no-sanitize >/dev/null 2>&1; NCRC=$?
    restore
    if [ "$NCRC" = "2" ]; then
        echo "  SKIPPED -- leb128.sh could not compile or run"; SKIP=$((SKIP+1))
    elif [ "$NCRC" = "0" ]; then
        echo "  NOT DETECTED -- a reader that decodes every multi-group value wrong passed"
        FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
fi

# --------------------------------------------------------------- uci_driver

row uci_driver
if selected uci_driver; then
    # The driver is an operator harness rather than a lane, so what has to be
    # shown is narrower than for a gate: that the one thing it ASSERTS can go
    # red. `bench` reads the anchor out of git log and compares -- the same
    # mutation the signature row uses moves the node count, so a driver that had
    # stopped comparing would still print MATCH.
    echo "negative-control: uci_driver  -- futility multiplier base 45 -> 46"
    mutate src/engine/search.cpp \
        'Value futilityMult = std::min(45 + depth * 4, 85);' \
        'Value futilityMult = std::min(46 + depth * 4, 85);'
    if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
        if python3 ./tests/uci_driver.py bench >/dev/null 2>&1; then
            echo "  NOT DETECTED -- the driver still reported MATCH"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
    else
        restore; die "the uci_driver mutant did not compile"
    fi
    restore
    ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
fi

# --------------------------------------------------------------- reprosearch

row reprosearch
if selected reprosearch; then
    # reprosearch is a merge gate -- tests.yml runs it and AGENTS.md lists it --
    # so it needs a row that watches it go red. What it asserts is that
    # ucinewgame resets the search completely: the same two short games,
    # replayed after it, must return the same node counts. Leaving the
    # transposition table warm across the reset is the smallest change that
    # breaks exactly that and nothing else.
    echo "negative-control: reprosearch -- ucinewgame leaves the TT warm"
    mutate src/shell/engine.cpp \
        '    tt.clear();
    threads.clear();' \
        '    threads.clear();'
    if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
        ( cd src && ../tests/reprosearch.sh ) >/dev/null 2>&1; NCRC=$?
        if [ "$NCRC" = "2" ]; then
            # SKIPPED, because expect is not installed. Scoring that as a
            # detection is the exact confusion this file exists to prevent one
            # level up: the gate did not catch the mutation, it never ran.
            echo "  SKIPPED -- reprosearch could not run (no expect)"; SKIP=$((SKIP+1))
        elif [ "$NCRC" = "0" ]; then
            echo "  NOT DETECTED -- node counts still repeated across ucinewgame"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
    else
        restore; die "the reprosearch mutant did not compile"
    fi
    restore
    ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
fi

row repro-driver
if selected repro-driver; then
    # The same mutation as the row above, through the driver instead of expect.
    #
    # THIS ROW EXISTS BECAUSE THE ONE ABOVE SKIPS. reprosearch.sh needs expect,
    # this box has none, and a control that reports SKIPPED forever has never
    # shown that anything can go red -- which is the confusion this file exists
    # to prevent one level up. `uci_driver.py repro` reads its rounds, its node
    # budgets and its command sequence out of reprosearch.sh, so the two cannot
    # drift, and it needs nothing but python3. That is also what makes it the
    # check a Windows or ARM runner can carry.
    echo "negative-control: repro [drv] -- ucinewgame leaves the TT warm"
    mutate src/shell/engine.cpp \
        '    tt.clear();
    threads.clear();' \
        '    threads.clear();'
    if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
        if ( cd src && python3 ../tests/uci_driver.py repro ) >/dev/null 2>&1; then
            echo "  NOT DETECTED -- node counts still repeated across ucinewgame"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
    else
        restore; die "the repro-driver mutant did not compile"
    fi
    restore
    ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
fi

# ------------------------------------------------------------------- iwyu

row iwyu
if selected iwyu; then
    # An include nothing in the file uses. It is the finding IWYU is most sure
    # about, which is what a control wants: the row asks whether the GATE
    # reports, not whether the tool is clever.
    #
    # A base revision is passed even though native mode does not need one,
    # because it is the only invocation that works in both of the gate's modes.
    # On a host with no libc++ package the absolute verdict is unavailable and
    # the gate skips rather than answer -- correctly -- so a row written without
    # a base would score that skip as "not detected" on exactly the hosts where
    # the gate is behaving.
    #
    # One tier, not three. The mutation is in a file every tier compiles, so the
    # other two would re-prove it at the cost of two more full analyses.
    echo "negative-control: iwyu        -- an include the file does not use"
    mutate src/engine/bitboard.cpp \
        '#include "bitboard.h"' \
        '#include "bitboard.h"
#include <regex>'
    ./tests/iwyu.sh --arch x86-64 HEAD >/dev/null 2>&1
    NCRC=$?
    if [ "$NCRC" = "2" ]; then
        echo "  SKIPPED -- iwyu.sh could not run"; SKIP=$((SKIP+1))
    elif [ "$NCRC" = "0" ]; then
        echo "  NOT DETECTED -- an unused include passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

# --------------------------------------------------------------- depcheck

row depcheck-new static
if selected depcheck-new; then
    echo "negative-control: depcheck    -- an engine file reaching into the shell"
    mutate src/engine/bitboard.cpp \
        '#include "bitboard.h"' \
        '#include "bitboard.h"
#include "uci.h"'
    if ./tests/depcheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a new engine -> shell edge passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row depcheck-stale static
if selected depcheck-stale; then
    # The inverse direction. A baseline that only ever grows stops being a debt
    # register and becomes a permanent excuse, so an entry describing an edge
    # that no longer happens has to fail too.
    echo "negative-control: depcheck    -- a baseline entry that no longer happens"
    # Anchor on the newline-prefixed data line: the same text also appears in the
    # file's header prose, and mutate() refuses an anchor it finds twice.
    mutate tests/depcheck.baseline \
        '
types.h -> tune.h' \
        '
types.h -> tune.h
movegen.cpp -> uci.h'
    if ./tests/depcheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a stale baseline entry passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row depcheck-platform static
if selected depcheck-platform; then
    # The rule linkcheck cannot replace. A header-carried dependency leaves no
    # undefined symbol, so both linkcheck baselines read empty while nineteen of
    # these edges existed. Mutate at THREE levels deep: a rule anchored on
    # `../platform/` rather than resolving the stem would pass this.
    echo "negative-control: depcheck    -- an engine file reaching into the platform"
    mutate src/engine/nnue/nnue_common.h \
        '#include "../compiler.h"' \
        '#include "../compiler.h"
#include "../../platform/memory.h"'
    out=$(./tests/depcheck.sh 2>&1); drc=$?
    if [ "$drc" = 0 ]; then
        echo "  NOT DETECTED -- a new engine -> platform edge passed"; FAIL=$((FAIL+1))
    elif ! printf '%s' "$out" | grep -q 'NEW      nnue_common.h -> memory.h'; then
        echo "  NOT DETECTED -- red, but the platform rule did not name the edge"; FAIL=$((FAIL+1))
    elif printf '%s' "$out" | sed -n '/new shell violations/,/^$/p' | grep -q 'NEW'; then
        # Both halves, the way the buildcoverage row does it. A single rule that
        # reddens for either zone is one check wearing two names, and it would
        # report a platform edge as a shell edge.
        echo "  NOT DETECTED -- the SHELL rule also reddened; the two rules are one"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1) on the platform rule, shell rule still green"; PASS=$((PASS+1))
    fi
    restore
fi

row depcheck-platform-stale static
if selected depcheck-platform-stale; then
    # The platform baseline expires in both directions too. It ships empty, so the
    # only way to go stale is to add an entry describing an edge that does not
    # happen -- which is exactly how an empty baseline would start growing.
    echo "negative-control: depcheck    -- a platform baseline entry that no longer happens"
    mutate tests/depcheck-platform.baseline \
        '# rather than joining a list.' \
        '# rather than joining a list.
search.h -> numa.h'
    if ./tests/depcheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a stale platform baseline entry passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row zone-ambiguous static
if selected zone-ambiguous; then
    # A stem in two zones. zone_of resolves a basename, so it would classify the
    # pair by whichever git lists first and every zone gate would then agree on
    # the wrong answer -- which is what the one-definition rule in zones.sh exists
    # to prevent, arriving through the resolver rather than through a second copy.
    #
    # A HEADER pair, deliberately: it breaks classification without breaking the
    # build, so this row and the buildcoverage one below are not the same check
    # wearing two names.
    echo "negative-control: depcheck    -- one stem naming two zones"
    # `git add -N`, because every check here iterates `git ls-files`: an
    # untracked copy is invisible to the gate and the row would report NOT
    # DETECTED for a mutation that never reached it.
    cp src/engine/score.h src/platform/score.h
    git add -N src/platform/score.h >/dev/null 2>&1
    out=$(./tests/depcheck.sh 2>&1); drc=$?
    if [ "$drc" = 0 ]; then
        echo "  NOT DETECTED -- an ambiguous stem passed"; FAIL=$((FAIL+1))
    elif ! printf '%s' "$out" | grep -q 'AMBIGUOUS   score'; then
        echo "  NOT DETECTED -- red, but not for the ambiguity"; FAIL=$((FAIL+1))
    elif ./tests/buildcoverage.sh >/dev/null 2>&1; then
        echo "  ok, red (1) on depcheck, buildcoverage green -- a header, so no object collides"
        PASS=$((PASS+1))
    else
        echo "  NOT DETECTED -- buildcoverage also reddened; the two checks are one"; FAIL=$((FAIL+1))
    fi
    git rm -q --cached src/platform/score.h >/dev/null 2>&1
    rm -f src/platform/score.h
fi

row buildcoverage-collision static
if selected buildcoverage-collision; then
    # The other half. Two SOURCES with one basename compete for one object,
    # because OBJS flattens with notdir, so one of them is never compiled -- and
    # the covered-by-the-build loop finds both named by SRCS and reports clean.
    echo "negative-control: buildcoverage -- two sources competing for one object"
    cp src/engine/score.cpp src/platform/score.cpp
    git add -N src/platform/score.cpp >/dev/null 2>&1
    if ./tests/buildcoverage.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a colliding object name passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    git rm -q --cached src/platform/score.cpp >/dev/null 2>&1
    rm -f src/platform/score.cpp
fi

row optiondefaults
if selected optiondefaults; then
    # The failure the header of searchoptions.h names and nothing held: a default
    # that drifts makes an unhosted search run with different parameters from the
    # UCI engine, and BOTH still produce a plausible number. The bench runs
    # hosted so it reads the UCI side; enginelink runs unhosted so it reads the
    # struct, and asserts only that the node count is non-zero.
    echo "negative-control: optiondef   -- Move Overhead drifted from its option"
    mutate src/engine/searchoptions.h \
        'int         moveOverhead     = 10;' \
        'int         moveOverhead     = 11;'
    if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
        if ./tests/optiondefaults.sh >/dev/null 2>&1; then
            echo "  NOT DETECTED -- a drifted default passed"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
        # And the inverse, which is the whole argument for the gate: every other
        # check stays GREEN on the same tree. The bench reads the UCI side, so the
        # signature does not move.
        REF=$(git log --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
        if [ -n "$REF" ] && ( cd src && ../tests/signature.sh "$REF" ) >/dev/null 2>&1; then
            echo "  signature green on the same tree, as expected -- the bench runs hosted"
        else
            echo "  NOTE: the signature moved too; this mutation is not purely unhosted"
        fi
    else
        restore; die "the optiondefaults mutant did not compile"
    fi
    restore
fi

row optiondefaults-unmapped static
if selected optiondefaults-unmapped; then
    # A field no option fills. The engine reads it and no host ever sets it, so it
    # is the same drift arriving before either side has a value to disagree about.
    # No rebuild: the check reads the header, and the running engine is only asked
    # about options that ARE mapped.
    echo "negative-control: optiondef   -- a SearchOptions field no option fills"
    mutate src/engine/searchoptions.h \
        '    bool        ponder           = false;' \
        '    bool        ponder           = false;
    int         nc_unfilled      = 7;'
    if ./tests/optiondefaults.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- an unmapped field passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row optiondefaults-rig static
if selected optiondefaults-rig; then
    # The rig's own third failure: a parser that stops matching compares nothing
    # and reports clean. Rename the mapping function so the sed finds no
    # assignments; the gate must REFUSE rather than pass an empty comparison.
    echo "negative-control: optiondef   -- the mapping the gate reads, made unreadable"
    mutate src/shell/engine.cpp \
        'SearchOptions Engine::search_options() const {' \
        'SearchOptions Engine::search_options_renamed_by_negative_control() const {'
    if ./tests/optiondefaults.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the gate passed having compared nothing"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row actionpins static
if selected actionpins; then
    # The defect this gate was written for, replayed: actions/cache pinned at
    # v4.2.0 in one workflow and v6.1.0 in two others. Nothing in the tree said
    # so, and it surfaced as a Node 20 deprecation warning on a runner -- which
    # is a message from GitHub about their schedule, not a check of ours.
    #
    # No network needed for this row. The split is visible in the files.
    echo "negative-control: actionpins  -- one action pinned at two versions"
    mutate .github/workflows/golden.yml \
        'uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' \
        'uses: actions/cache@1bd1e32a3bdc45362d1e726936510720a7c30a57 # v4.2.0'
    if ./tests/actionpins.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a split pin passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row actionpins-mutable static
if selected actionpins-mutable; then
    # A tag rather than a commit. `@v7` is "run whatever they publish next" on a
    # runner holding this repository's token, so this is the supply-chain half
    # rather than the freshness half.
    echo "negative-control: actionpins  -- an action pinned to a mutable tag"
    mutate .github/workflows/golden.yml \
        'uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' \
        'uses: actions/checkout@v7'
    if ./tests/actionpins.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a tag pin passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

row anchor static
if selected anchor; then
    # The defect that reddened every architecture lane: a body line shaped like a
    # bench footer. Upstream's hook regex spans the run of spaces between the word
    # and the number, so an evidence row quoting a gate result is
    # indistinguishable from the anchor to anything scanning bodies line by line.
    #
    # A row mutates files and restores them, and a commit body is neither, so the
    # body is handed to the gate through ANCHOR_EXTRA_BODY. That path can only add
    # an offender, so a row using it cannot make the gate greener than it is.
    echo "negative-control: anchor      -- a body line that reads as a footer"
    printf '  bench                                                2829394\n' \
        > "$BACKUP/anchor-body"
    if ANCHOR_EXTRA_BODY="$BACKUP/anchor-body" ./tests/anchor.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a body line reading as a footer passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi

    # The same line as a REAL footer must not be a finding, or the gate reports
    # every functional commit on the branch.
    printf 'Bench: 2884956\n' > "$BACKUP/anchor-body"
    if ANCHOR_EXTRA_BODY="$BACKUP/anchor-body" ./tests/anchor.sh >/dev/null 2>&1; then
        echo "  ok, green on a real footer (2)"; PASS=$((PASS+1))
    else
        echo "  NOT DETECTED -- a real Bench: footer read as a finding"; FAIL=$((FAIL+1))
    fi
    rm -f "$BACKUP/anchor-body"
    restore
fi

row anchor-stale static
if selected anchor-stale; then
    # The other direction. An entry excusing a commit whose body is fine is an
    # excuse that outlived its reason, and a baseline that only grows is a
    # permanent exemption rather than a record.
    echo "negative-control: anchor      -- a baseline entry that no longer happens"
    mutate tests/anchor.baseline \
        '# file already spent.
' \
        '# file already spent.
2db500a7
'
    if ./tests/anchor.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a stale baseline entry passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

# --------------------------------------------------------------- type design

row b5-mismatch static
if selected b5-mismatch; then
    # The INVERSE of every other row: this one passes when the compiler REFUSES.
    # Each accessor in SharedHistories selects the row with one key AND returns
    # that key's field, so the pairing cannot be split. An accessor returning
    # the whole bundle for the caller to index would let one key's row be read
    # through another key's field -- which compiles, returns a real counter of
    # the wrong kind, and no gate but the bench signature can see it.
    # -Iengine as well as -I.: these probes include the engine headers by bare
    # name, and src/ is zone directories, so -I. alone fails to find them -- which
    # makes the mismatch AND the correct form fail, scoring the rejection half as
    # a pass. The correct-form probe below is what catches that.
    echo "negative-control: b5 [type]   -- a key/field mismatch must not compile"
    cat > /tmp/nc_b5_mismatch.cpp <<'CPP'
#include "history.h"
#include "position.h"
using namespace Stockfish;
int probe(SharedHistories& h, const Position& pos, Color us) {
    return h.pawn_correction(pos, us).minor;
}
CPP
    if ( cd src && g++ -std=c++20 -I. -Iengine -fsyntax-only /tmp/nc_b5_mismatch.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the mismatch still compiles"; FAIL=$((FAIL+1))
    else
        echo "  ok, rejected by the compiler"; PASS=$((PASS+1))
    fi
    # A row that only checked the rejection would also pass if the header stopped
    # compiling at all, so require the correct form to build.
    cat > /tmp/nc_b5_ok.cpp <<'CPP'
#include "history.h"
#include "position.h"
using namespace Stockfish;
int probe(SharedHistories& h, const Position& pos, Color us) {
    return h.pawn_correction(pos, us);
}
CPP
    if ! ( cd src && g++ -std=c++20 -I. -Iengine -fsyntax-only /tmp/nc_b5_ok.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the correct form does not compile either"; FAIL=$((FAIL+1))
    fi
    rm -f /tmp/nc_b5_mismatch.cpp /tmp/nc_b5_ok.cpp
fi

row b5-keyspace static
if selected b5-keyspace; then
    # The other inverse row: the compiler must REFUSE a key from one space where
    # another belongs. Three shapes, because one alone would pass if the header
    # simply stopped compiling.
    echo "negative-control: b5 [keys]   -- a key from the wrong space must not compile"
    ok=1
    mk() { printf '#include "position.h"\n#include "tt.h"\nusing namespace Stockfish;\n%s\n' "$1" > /tmp/nc_b5_key.cpp; }
    for probe in \
        'auto f(TranspositionTable& t, const Position& p) { return t.probe(p.pawn_key()); }' \
        'Bitboard f(const Position& p) { return p.pawn_key(); }' \
        'bool f(const Position& p) { return p.pawn_key() == p.minor_piece_key(); }'
    do
        mk "$probe"
        if ( cd src && g++ -std=c++20 -I. -Iengine -fsyntax-only /tmp/nc_b5_key.cpp ) >/dev/null 2>&1; then
            echo "  NOT DETECTED -- accepted: $probe"; ok=0
        fi
    done
    # and the legal form must still build, so a broken header cannot pass this row
    mk 'usize f(const Position& p, usize m) { return p.pawn_key() & m; }'
    if ! ( cd src && g++ -std=c++20 -I. -Iengine -fsyntax-only /tmp/nc_b5_key.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the legal form does not compile either"; ok=0
    fi
    if [ "$ok" = 1 ]; then echo "  ok, rejected by the compiler"; PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); fi
    rm -f /tmp/nc_b5_key.cpp
fi

row b13-colour static
if selected b13-colour; then
    # The colour half of the key pairing. Before B13.2 the two non-pawn keys
    # shared one type and the colour was an argument, so non_pawn_key(WHITE)
    # where BLACK was meant compiled -- exactly what b5-swap below records as
    # the limit of the typing. This row is the case that stopped being one, so
    # it must go red on the swap AND green on both legal forms; a header that
    # simply stopped compiling would satisfy the first alone.
    echo "negative-control: b13 [colour] -- a non-pawn key of the wrong colour must not compile"
    ok=1
    printf '#include "position.h"\nusing namespace Stockfish;\nNonPawnKey<WHITE> f(const Position& p) { return p.non_pawn_key<BLACK>(); }\n' \
        > /tmp/nc_b13_colour.cpp
    if ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b13_colour.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a BLACK key was accepted where WHITE was declared"; ok=0
    fi
    printf '#include "position.h"\nusing namespace Stockfish;\nNonPawnKey<WHITE> f(const Position& p) { return p.non_pawn_key<WHITE>(); }\nusize g(const Position& p, usize m) { return p.non_pawn_key<BLACK>() & m; }\n' \
        > /tmp/nc_b13_colour.cpp
    if ! ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b13_colour.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the legal forms do not compile either"; ok=0
    fi
    if [ "$ok" = 1 ]; then echo "  ok, rejected by the compiler"; PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); fi
    rm -f /tmp/nc_b13_colour.cpp
fi

row b13-dirtythreat static
if selected b13-dirtythreat; then
    # One keyword, and the same two-sided shape: a raw u32 must stop becoming a
    # DirtyThreat with no cast, and the named construction must still work.
    echo "negative-control: b13 [dt]     -- a raw u32 must not become a DirtyThreat"
    ok=1
    printf '#include "types.h"\nusing namespace Stockfish;\nDirtyThreat f(u32 raw) { return raw; }\n' \
        > /tmp/nc_b13_dt.cpp
    if ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b13_dt.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the implicit conversion was accepted"; ok=0
    fi
    printf '#include "types.h"\nusing namespace Stockfish;\nDirtyThreat f(u32 raw) { return DirtyThreat(raw); }\n' \
        > /tmp/nc_b13_dt.cpp
    if ! ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b13_dt.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the explicit form does not compile either"; ok=0
    fi
    if [ "$ok" = 1 ]; then echo "  ok, rejected by the compiler"; PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); fi
    rm -f /tmp/nc_b13_dt.cpp
fi

row b20-conthist static
if selected b20-conthist; then
    # The continuation-history quadrant, which was two bools as ARRAY
    # SUBSCRIPTS -- no parameter name to read against, and [capture][inCheck]
    # read a real table and returned plausible statistics. This row is what
    # makes the accessor a guarantee rather than a convention: the swap must be
    # rejected AND both legal spellings must still compile, so a header that
    # merely stopped compiling cannot satisfy it.
    echo "negative-control: b20 [conth] -- a transposed history quadrant must not compile"
    ok=1
    printf '#include "history.h"\nusing namespace Stockfish;\nContinuationHistory& f(ContinuationHistoryBlock& b) { return b(Capture::No, InCheck::No); }\n' \
        > /tmp/nc_b20_conthist.cpp
    if ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_conthist.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the subscripts were accepted transposed"; ok=0
    fi
    printf '#include "history.h"\nusing namespace Stockfish;\nContinuationHistory& f(ContinuationHistoryBlock& b) { return b(InCheck::Yes, Capture::No); }\nContinuationHistory& g(ContinuationHistoryBlock& b) { return b(InCheck::No, Capture::Yes); }\n' \
        > /tmp/nc_b20_conthist.cpp
    if ! ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_conthist.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the legal forms do not compile either"; ok=0
    fi
    if [ "$ok" = 1 ]; then echo "  ok, rejected by the compiler"; PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); fi
    rm -f /tmp/nc_b20_conthist.cpp
fi

row b20-rootprobe static
if selected b20-rootprobe; then
    # root_probe's two adjacent flags. Both were bool, so the only thing
    # separating them was argument position: rule50 inverted changes the
    # verdict a table gives, rankDTZ inverted changes whether DTZ ranking
    # happens at all.
    echo "negative-control: b20 [rootp] -- a root-probe flag of the wrong kind must not compile"
    ok=1
    printf '#include "tb_source.h"\nusing namespace Stockfish::Tablebases;\nRule50 f() { return RankDTZ::Yes; }\n' \
        > /tmp/nc_b20_rootprobe.cpp
    if ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_rootprobe.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a RankDTZ was accepted where Rule50 was declared"; ok=0
    fi
    # And a bare bool, which is what both parameters used to be.
    printf '#include "tb_source.h"\nusing namespace Stockfish::Tablebases;\nRule50 f(bool b) { return b; }\n' \
        > /tmp/nc_b20_rootprobe.cpp
    if ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_rootprobe.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a bare bool was accepted as Rule50"; ok=0
    fi
    printf '#include "tb_source.h"\nusing namespace Stockfish::Tablebases;\nRule50 f(bool b) { return Rule50(b); }\nRankDTZ g() { return RankDTZ::No; }\n' \
        > /tmp/nc_b20_rootprobe.cpp
    if ! ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_rootprobe.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the legal forms do not compile either"; ok=0
    fi
    if [ "$ok" = 1 ]; then echo "  ok, rejected by the compiler"; PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); fi
    rm -f /tmp/nc_b20_rootprobe.cpp
fi

row b20-powtwo static
if selected b20-powtwo; then
    # SharedHistories masks a key with size - 1, so a count that is not a power
    # of two masks to an index the array does not hold. The guard used to be an
    # assert, and -DNDEBUG is what ships. PowerOfTwo is the parameter now, and
    # its only constructor is private.
    echo "negative-control: b20 [pow2]  -- an unrounded thread count must not compile"
    ok=1
    printf '#include "history.h"\nusing namespace Stockfish;\nSharedHistories f() { return SharedHistories(6); }\n' \
        > /tmp/nc_b20_powtwo.cpp
    if ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_powtwo.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a raw count was accepted"; ok=0
    fi
    printf '#include "history.h"\nusing namespace Stockfish;\nSharedHistories f() { return SharedHistories(PowerOfTwo::ceil(6)); }\n' \
        > /tmp/nc_b20_powtwo.cpp
    if ! ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_powtwo.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the rounded form does not compile either"; ok=0
    fi
    if [ "$ok" = 1 ]; then echo "  ok, rejected by the compiler"; PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); fi
    rm -f /tmp/nc_b20_powtwo.cpp
fi

row b20-bank static
if selected b20-bank; then
    # HistoryBankIndex and NumaIndex were both usize, so the distinction the
    # header argues for in six lines of prose -- an index into the engine's own
    # map, not a handle on the host's topology -- was held by the prose alone.
    # The two declarations of the map disagreed on which one keyed it and
    # nothing said anything.
    echo "negative-control: b20 [bank]  -- a bare usize must not become a bank index"
    ok=1
    printf '#include "history.h"\nusing namespace Stockfish;\nHistoryBankIndex f(usize n) { return n; }\n' \
        > /tmp/nc_b20_bank.cpp
    if ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_bank.cpp ) >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the implicit conversion was accepted"; ok=0
    fi
    printf '#include "history.h"\nusing namespace Stockfish;\nHistoryBankIndex f(usize n) { return HistoryBankIndex(n); }\n' \
        > /tmp/nc_b20_bank.cpp
    if ! ( cd src && g++ -std=c++17 -I. -Iengine -fsyntax-only /tmp/nc_b20_bank.cpp ) >/dev/null 2>&1; then
        echo "  RIG FAULT -- the named form does not compile either"; ok=0
    fi
    if [ "$ok" = 1 ]; then echo "  ok, rejected by the compiler"; PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); fi
    rm -f /tmp/nc_b20_bank.cpp
fi

row b5-swap
if selected b5-swap; then
    # What the type does NOT buy, recorded as a test so no page can imply
    # otherwise. The accessors share a signature, so substituting one for
    # another still compiles and no type check can refuse it; the bench
    # signature is the only thing that catches it. Do not describe the typing
    # above as closing this case.
    REF=$(git log --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
    if [ -z "$REF" ]; then
        echo "negative-control: b5 [swap]  SKIPPED -- no Bench: in the commit record"
        SKIP=$((SKIP+1))
    else
        echo "negative-control: b5 [swap]   -- one accessor substituted for another"
        mutate src/engine/search.cpp \
            '    const int   pcv    = shared.pawn_correction(pos, us);
    const int   micv   = shared.minor_piece_correction(pos, us);' \
            '    const int   pcv    = shared.minor_piece_correction(pos, us);
    const int   micv   = shared.pawn_correction(pos, us);'
        if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
            if ( cd src && ../tests/signature.sh "$REF" ) >/dev/null 2>&1; then
                echo "  NOT DETECTED -- the bench reproduced $REF with the accessors swapped"
                FAIL=$((FAIL+1))
            else
                echo "  ok, red (1) -- the compiler accepts it, the bench does not"; PASS=$((PASS+1))
            fi
        else
            restore; die "the accessor swap did not compile -- it is supposed to"
        fi
        restore
        ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
    fi
fi

# --------------------------------------------------------------- buildcoverage

row buildcoverage static
if selected buildcoverage; then
    # SRCS is an explicit list, so a file can be in the tree and in no build.
    # It is then not compiled, not linked, and covered by no gate -- while still
    # looking maintained. It also blinds linkcheck.sh, which reasons about
    # OBJECTS: a source compiled by nothing produces none, so it could call
    # straight into the shell with the zone check green.
    echo "negative-control: buildcov    -- a source the build names nowhere"
    printf '// negative control\nnamespace Stockfish { int nc_unbuilt() { return 0; } }\n' \
        > src/engine/zzz_unbuilt.cpp
    git add -N src/engine/zzz_unbuilt.cpp >/dev/null 2>&1
    if ./tests/buildcoverage.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- an uncompiled source passed"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    # And the inverse: depcheck stays GREEN, because it reads includes in FILES
    # and the file is there. The gate an uncompiled source blinds is linkcheck,
    # which reasons about OBJECTS and gets none -- which is why buildcoverage is
    # linkcheck's prerequisite rather than a duplicate of either.
    if ./tests/depcheck.sh >/dev/null 2>&1; then
        echo "  depcheck green, as expected -- it reasons about files, not builds"
    fi
    git rm -q --cached src/engine/zzz_unbuilt.cpp >/dev/null 2>&1
    rm -f src/engine/zzz_unbuilt.cpp
fi

# --------------------------------------------------------------- linkcheck

row linkcheck
if selected linkcheck; then
    # The row that justifies linkcheck existing beside depcheck. It adds a
    # symbol to a SHELL object and calls it from an ENGINE object through a
    # forward declaration, so no #include announces the edge.
    #
    # It therefore asserts two things: depcheck stays GREEN, because reading
    # includes cannot see this, and linkcheck goes RED. A row that only checked
    # the second would not show why the second gate is needed.
    echo "negative-control: linkcheck   -- an engine-to-shell call with no include"
    # A control has to start GREEN. This row asserts that depcheck stays green
    # and that linkcheck goes red, but never that linkcheck was green to begin
    # with -- so on a tree where it is already red it prints "ok, red (1)" for a
    # reason its own mutation did not supply, and silently stops controlling
    # anything. Not hypothetical: the rebase onto upstream 5062aee5 reddened
    # both link gates on its own.
    nc_link_baseline=1
    ./tests/linkcheck.sh >/dev/null 2>&1 || nc_link_baseline=0
    if [ "$nc_link_baseline" = 0 ]; then
        echo "  NO BASELINE -- linkcheck is already red; this row can attribute nothing"
        FAIL=$((FAIL+1))
    fi
    mutate src/shell/benchmark.cpp \
        'namespace Stockfish::Benchmark {' \
        'namespace Stockfish {
int nc_link_probe() { return 0; }
}

namespace Stockfish::Benchmark {'
    mutate src/engine/bitboard.cpp \
        'namespace Stockfish {' \
        'namespace Stockfish {

int nc_link_probe();
namespace { const int nc_link_sink = nc_link_probe(); }'
    if ./tests/depcheck.sh >/dev/null 2>&1; then
        echo "  depcheck green, as expected -- an include-reader cannot see this"
    else
        echo "  NOT AS DESIGNED -- depcheck reported it; the row no longer isolates the gap"
        FAIL=$((FAIL+1))
    fi
    if ./tests/linkcheck.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- linkcheck passed an engine object calling a shell symbol"
        FAIL=$((FAIL+1))
    elif [ "$nc_link_baseline" = 1 ]; then
        echo "  ok, red (1)"; PASS=$((PASS+1))
    else
        echo "  red, but it was red before the mutation -- not scored"
    fi
    restore
fi

row enginelink
if selected enginelink; then
    # The row that justifies enginelink existing beside linkcheck, and the row
    # that keeps its LTO handling honest on every run.
    #
    # An engine file calling a PLATFORM symbol. This must fail the link, and it
    # only does so while the objects hold machine code: `EXTRACXXFLAGS=-fno-lto`
    # cannot turn LTO off (src/Makefile interpolates EXTRACXXFLAGS into its
    # CXXFLAGS assignment and then appends -flto after it), and `ld` without
    # the plugin warns on an IR object and STILL EXITS 0. A gate built that way
    # reports CLEAN on exactly this mutation, so this row is what proves the
    # COMPCXX wrapper is still stripping the flag.
    echo "negative-control: enginelink  -- an engine object calling a platform symbol"
    # Green before the mutation, for the reason spelled out in the linkcheck row.
    nc_englink_baseline=1
    ./tests/enginelink.sh >/dev/null 2>&1 || nc_englink_baseline=0
    if [ "$nc_englink_baseline" = 0 ]; then
        echo "  NO BASELINE -- enginelink is already red; this row can attribute nothing"
        FAIL=$((FAIL+1))
    fi
    mutate src/engine/search.cpp \
        'void Search::Worker::start_searching() {' \
        'void aligned_large_pages_free(void*);
namespace { void nc_enginelink_probe() { aligned_large_pages_free(nullptr); } }

void Search::Worker::start_searching() {
    if (threadIdx == 12345)
        nc_enginelink_probe();
'
    # The platform symbol is FORWARD-DECLARED in the mutation, not included, so
    # depcheck stays green exactly as it does for the linkcheck row -- an
    # include-reader cannot see an edge no include spells.
    #
    # The call is guarded by a condition that is never true, so the mutant still
    # searches normally. It only has to EXIST: an unreferenced function in an
    # anonymous namespace is dead code the optimiser deletes, taking the symbol
    # reference with it and turning the row green for the wrong reason.
    if ./tests/enginelink.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the engine linked alone while calling a platform symbol"
        FAIL=$((FAIL+1))
    elif [ "$nc_englink_baseline" = 1 ]; then
        echo "  ok, red (1)"; PASS=$((PASS+1))
    else
        echo "  red, but it was red before the mutation -- not scored"
    fi
    restore
fi

row enginelink-seam
if selected enginelink-seam; then
    # The substitution half, and the failure it exists for.
    #
    # clock.h's claim is that "a host substitutes ONE function and both views
    # move together". The failure that breaks it is not a seam nobody reads --
    # that is loud -- it is now() quietly reading a real clock while now_us()
    # stays substituted. Every assertion about now_us() alone still passes, and
    # a replay harness gets a deterministic search with one wall-clock component
    # in it. No other gate in the tree can see that: an inline call to
    # std::chrono leaves no undefined symbol for enginelink or linkcheck, and
    # depcheck reads includes, which clock.cpp legitimately has.
    echo "negative-control: enginelink  -- now() reading a clock the host did not supply"
    nc_seam_baseline=1
    ./tests/enginelink.sh >/dev/null 2>&1 || nc_seam_baseline=0
    if [ "$nc_seam_baseline" = 0 ]; then
        echo "  NO BASELINE -- enginelink is already red; this row can attribute nothing"
        FAIL=$((FAIL+1))
    fi
    # The quotient is the mutation target, NOT the seam read. Cutting the seam
    # out of now_us() would be caught by the read counter too, so the row would
    # pass without establishing that the coherence assertion works.
    mutate src/engine/clock.cpp \
        'TimePoint now() { return TimePoint(now_us() / 1000); }' \
        'TimePoint now() {
    return TimePoint(std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::steady_clock::now().time_since_epoch())
                       .count());
}'
    if ./tests/enginelink.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- now() left the seam and the gate stayed green"
        FAIL=$((FAIL+1))
    elif [ "$nc_seam_baseline" = 1 ]; then
        echo "  ok, red (1)"; PASS=$((PASS+1))
    else
        echo "  red, but it was red before the mutation -- not scored"
    fi
    restore
fi

row tbpv
if selected tbpv; then
    # The PV extension's length bound, which is the ONLY unconditional exit the
    # walk has: `rule50 && is_draw` is constant-false with Syzygy50MoveRule off
    # and time_abort() is constant-false under `go depth`, so removing the bound
    # leaves a loop whose termination depends entirely on where the tables run
    # out. PVMoves checks its capacity with an assert alone, and -DNDEBUG is what
    # ships, so the overrun is a write into the next RootMove, not a diagnostic.
    #
    # Mutate the bound WIDER rather than deleting it. A row that hangs is a rig
    # fault and never a detection, which is the rule this file opens with about
    # search bounds; MAX_PLY * 4 still terminates and still overruns the array.
    echo "negative-control: tbpv        -- a PV walk bounded past the array that holds it"
    if [ -z "$RUNPY" ]; then
        echo "  SKIPPED -- no python3 with requests importable"; SKIP=$((SKIP+1))
    elif ! $RUNPY tests/tbpv.py >/dev/null 2>&1; then
        # Almost always the 5-man corpus, which tbfetch.sh --men 5 writes and a
        # developer may not have. A row that was not green before the mutation
        # can attribute nothing, so report it rather than scoring it.
        echo "  SKIPPED -- tbpv is not green before the mutation (corpus absent?)"
        SKIP=$((SKIP+1))
    else
        mutate src/engine/search.cpp \
            '    while (rootMove.pv.size() < MAX_PLY && !(rule50 && pos.is_draw(0)))' \
            '    while (rootMove.pv.size() < MAX_PLY * 4 && !(rule50 && pos.is_draw(0)))'
        # REBUILD. tbpv.py drives src/stockfish rather than building one, so a
        # mutated source that is not compiled reaches the sweep as nothing at
        # all and the row reports NOT DETECTED for a mutation the engine never
        # saw. The instrumented row above is the same shape for the same reason.
        if ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1; then
            if $RUNPY tests/tbpv.py >/dev/null 2>&1; then
                echo "  NOT DETECTED -- a PV past MAX_PLY ran clean"; FAIL=$((FAIL+1))
            else
                echo "  ok, red (1)"; PASS=$((PASS+1))
            fi
        else
            restore; die "the tbpv mutant did not compile"
        fi
        restore
        # Put the real binary back: every later row and the caller's own tree
        # would otherwise keep the mutant.
        ( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1
    fi
fi

row enginelink-fatal
if selected enginelink-fatal; then
    # The fatal seam has two halves and only one of them is a compile error if
    # broken. Dropping the [[noreturn]] guarantee -- letting engine_abort fall
    # off its end -- does not compile, so -Werror already holds that half. The
    # half nothing holds is the CALLOUT: a wrapper that terminates without
    # giving the host its say still satisfies every type in the header, still
    # ends the process, and silently turns the seam back into the exit() it
    # replaced.
    echo "negative-control: enginelink  -- terminating without giving the host its say"
    nc_fatal_baseline=1
    ./tests/enginelink.sh >/dev/null 2>&1 || nc_fatal_baseline=0
    if [ "$nc_fatal_baseline" = 0 ]; then
        echo "  NO BASELINE -- enginelink is already red; this row can attribute nothing"
        FAIL=$((FAIL+1))
    fi
    # (void) reason, because -Wextra -Werror makes an unused parameter an error
    # and a mutation that does not compile is not a behavioural change.
    mutate src/engine/fatal.cpp \
        '    fatal_source().abort_now(reason);' \
        '    (void) reason;'
    if ./tests/enginelink.sh >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the host handler was skipped and the gate stayed green"
        FAIL=$((FAIL+1))
    elif [ "$nc_fatal_baseline" = 1 ]; then
        echo "  ok, red (1)"; PASS=$((PASS+1))
    else
        echo "  red, but it was red before the mutation -- not scored"
    fi
    restore
fi

# --------------------------------------------------------------- fuzz
#
# A fuzz harness has two ways to be useless, and only one of them is visible in
# a normal run: it can fail to notice a broken engine, and it can bank a broken
# RIG as a finding. Both are checked here by pointing the harness at a stub
# engine through EXE, which needs no rebuild.

NCSTUB=$(mktemp -d)
stub() { printf '%s\n' "$2" > "$NCSTUB/$1"; chmod +x "$NCSTUB/$1"; }

row fuzz-uci
if selected fuzz-uci; then
    echo "negative-control: fuzz [uci]  -- an engine that never answers isready"
    stub silent '#!/bin/bash
cat >/dev/null
exit 0'
    if EXE="$NCSTUB/silent" ./tests/fuzz.py --seconds 1 --harness uci >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a wedged engine ran clean"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
fi

row fuzz-tb
if selected fuzz-tb; then
    if [ -z "$(ls tests/syzygy-3man 2>/dev/null)" ]; then
        echo "negative-control: fuzz [tb]   SKIPPED -- no corpus; run tests/tbfetch.sh"
        SKIP=$((SKIP+1))
    else
        # LIMIT, and it is not the whole harness: the stub crashes BEFORE it
        # reads the mutated table, so what this row exercises is harness_tb's
        # `killed by signal` branch inside the mutation loop, never the prober.
        # It also needs src/stockfish built -- a failed exec leaves the reference
        # run with no verdict, harness_tb raises its rig fault, and the row reads
        # that non-zero status as a detection it never made.
        echo "negative-control: fuzz [tb]   -- an engine that dies on a corrupt table"
        # Serve the REFERENCE run from the real engine, then crash. A stub that
        # dies on its first invocation never reaches the mutation loop: the
        # harness refuses at its reference run with a rig fault, the row sees a
        # non-zero status and credits itself with a detection it never made.
        rm -f "$NCSTUB/tbcrash.n"
        stub tbcrash '#!/bin/bash
n=$(cat "'"$NCSTUB"'/tbcrash.n" 2>/dev/null || echo 0)
echo $((n + 1)) > "'"$NCSTUB"'/tbcrash.n"
[ "$n" -eq 0 ] && exec "'"$ROOT"'/src/stockfish" "$@"
cat >/dev/null
kill -SEGV $$'
        if EXE="$NCSTUB/tbcrash" ./tests/fuzz.py --seconds 1 --harness tb >/dev/null 2>&1; then
            echo "  NOT DETECTED -- a crashing engine ran clean"; FAIL=$((FAIL+1))
        else
            echo "  ok, red (1)"; PASS=$((PASS+1))
        fi
    fi
fi

row fuzz-rig
if selected fuzz-rig; then
    if [ -z "$(ls tests/syzygy-3man 2>/dev/null)" ]; then
        echo "negative-control: fuzz [rig]  SKIPPED -- no corpus; run tests/tbfetch.sh"
        SKIP=$((SKIP+1))
    else
        # The inverse of every other row: the harness must NOT claim a finding.
        # A run where no table loaded tests nothing, and reporting it as a
        # defect is how a harness earns credit for an experiment it never ran.
        # The required answer is RIG FAULT, not FINDING and not clean.
        echo "negative-control: fuzz [rig]  -- a rig with no tables must not read as a finding"
        # One bestmove per stem the harness probes in its reference run, all with
        # no tbhits. Answering FEWER would stop the harness one check earlier, on
        # "no reference verdict" -- also a rig fault, but not the one this row is
        # about.
        stub norig '#!/bin/bash
echo "info string Found 0 WDL and 0 DTZ tablebase files (up to 3-man)."
cat >/dev/null
for _ in 1 2 3 4 5; do echo "bestmove a1a1"; done
exit 0'
        out=$(EXE="$NCSTUB/norig" ./tests/fuzz.py --seconds 1 --harness tb 2>&1)
        if printf '%s' "$out" | grep -q 'RIG FAULT'; then
            echo "  ok, red (1)"; PASS=$((PASS+1))
        elif printf '%s' "$out" | grep -q 'FINDING'; then
            echo "  NOT DETECTED -- a dead rig was reported as a defect"; FAIL=$((FAIL+1))
        else
            echo "  NOT DETECTED -- a dead rig ran clean"; FAIL=$((FAIL+1))
        fi
    fi
fi

row fuzz-shm
if selected fuzz-shm; then
    # The shm harness's claim is survivorship: a process that dies because a
    # PEER died is the defect, a process killed on purpose is the stimulus. The
    # stub dies on its own, so every survivor reads as one that did not survive.
    echo "negative-control: fuzz [shm]  -- a peer death taking a survivor with it"
    stub shmdie '#!/bin/bash
cat >/dev/null &
sleep 0.4
kill -TERM $$'
    if EXE="$NCSTUB/shmdie" ./tests/fuzz.py --seconds 2 --harness shm >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a survivor dying by signal ran clean"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
fi

row fuzz-verdict
if selected fuzz-verdict; then
    if [ -z "$(ls tests/syzygy-3man 2>/dev/null)" ]; then
        echo "negative-control: fuzz [vrd] SKIPPED -- no corpus; run tests/tbfetch.sh"
        SKIP=$((SKIP+1))
    else
        # The property that is not liveness: an engine that survives a corrupt
        # table and then cannot probe a table the mutation never touched. That
        # is one table's corruption reaching another's mapping, and no mutation
        # of a real table reliably produces it -- keeping the two apart is what
        # the reader is for -- so the detector is driven directly, the way the
        # other fuzz rows drive theirs.
        #
        # The stub answers the reference run with one verdict per stem, then
        # zeroes tbhits on the SECOND probe of each mutation round, which is the
        # only one the harness makes a claim about. A stub that diverged on the
        # first would be exercising nothing: that probe reads the mutated table
        # and is judged on liveness alone.
        #
        # IT ANSWERS INCREMENTALLY, one reply per `go`, and that is not a style
        # choice. The harness now drives the engine with a runner that waits for
        # each `bestmove` before sending the next command, so a stub that reads
        # to EOF before replying deadlocks it -- and the deadline then reports a
        # hang, which this row would read as "the reference run itself was
        # refused". A stub is a fake engine and has to keep the protocol.
        echo "negative-control: fuzz [vrd]  -- one table's corruption reaching another's mapping"
        rm -f "$NCSTUB/count"
        stub verdict '#!/bin/bash
C="$(dirname "$0")/count"
n=$(cat "$C" 2>/dev/null || echo 0); echo $((n+1)) > "$C"
echo "info string Found 5 WDL and 5 DTZ tablebase files (up to 3-man)."
g=0
while IFS= read -r line; do
    case "$line" in
        go*)
            g=$((g+1))
            if [ "$n" != "0" ] && [ "$g" = "2" ]; then
                echo "info depth 8 tbhits 0"
            else
                echo "info depth 8 tbhits 4"
            fi
            echo "bestmove d2d4"
            ;;
        quit*) exit 0 ;;
    esac
done'
        out=$(EXE="$NCSTUB/verdict" ./tests/fuzz.py --seconds 1 --harness tb 2>&1)
        if printf '%s' "$out" | grep -q 'unprobed'; then
            echo "  ok, red (1)"; PASS=$((PASS+1))
        elif printf '%s' "$out" | grep -q 'RIG FAULT'; then
            echo "  NOT DETECTED -- the reference run itself was refused"; FAIL=$((FAIL+1))
        else
            echo "  NOT DETECTED -- a corrupt table reaching another's mapping ran clean"; FAIL=$((FAIL+1))
        fi
    fi
fi

row fuzz-net
if selected fuzz-net; then
    # The same limit the tb row carries: the stub crashes before it reads the
    # mutated net, so this exercises harness_net's `killed by signal` branch and
    # says nothing about what the net parser does with corrupt bytes.
    echo "negative-control: fuzz [net]  -- an engine that dies on a corrupt net"
    # Same shape as the tb row: the reference evaluation has to come from a
    # working engine, or the harness refuses before any mutation is tried.
    rm -f "$NCSTUB/netcrash.n"
    stub netcrash '#!/bin/bash
n=$(cat "'"$NCSTUB"'/netcrash.n" 2>/dev/null || echo 0)
echo $((n + 1)) > "'"$NCSTUB"'/netcrash.n"
[ "$n" -eq 0 ] && exec "'"$ROOT"'/src/stockfish" "$@"
cat >/dev/null
kill -SEGV $$'
    if EXE="$NCSTUB/netcrash" ./tests/fuzz.py --seconds 1 --harness net >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a crashing engine ran clean"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
fi

rm -rf "$NCSTUB"

row fuzzsearch
if selected fuzzsearch; then
    # The in-process fuzzer's FINDING path has never been observed. Its
    # executions guard already refuses a run that fuzzed nothing -- that exits 2,
    # not 0 -- so what is left to distrust is the expensive case: a rig that
    # builds, links and executes and still cannot carry a defect out of the
    # engine reports clean. Plant one every input reaches: a null STORE in the
    # headless runner behind Search::go, which the driver calls at depth 3
    # whatever the walk produced, so it fires on the first input rather than on
    # a lucky one.
    echo "negative-control: fuzzsearch  -- a defect on the first search"
    mutate src/engine/search_go.cpp \
        '        w.limits = LimitsType();' \
        '        if (depth > 0)
            *(volatile int*) nullptr = 0;
        w.limits = LimitsType();'
    if ./tests/fuzzsearch.sh --seconds 20 >/dev/null 2>&1; then
        echo "  NOT DETECTED -- the fuzzer reported clean over a null dereference"
        FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
    restore
fi

# --------------------------------------------------------------- coverage
#
# The gap this closes: a gate with no row here is simply ABSENT, and absence is
# quiet. lanecheck.sh asks whether a gate is dispatched and docslint.sh asks
# whether it is documented; neither asks whether it CAN FAIL, so a gate can be
# fully wired, fully described and inert while every listing counts it as
# coverage. Every gate therefore needs a row or a written excuse.
#
# The excuse list expires in both directions, as lanecheck's does: an excused
# script that HAS a row is a stale excuse, and an excuse naming a script the
# tree no longer carries fails too.

COVERAGE_EXCUSED_NAMES=(
  npsab.sh
  npsthreads.sh
  negative_control.sh
  testing.py
  zones.sh
  perfcounters.sh
  perfcounters_report.py
  perfdecomp.sh
  perfdecomp.py
  match.sh
)
COVERAGE_EXCUSED_WHY=(
  "a wall-clock measurement rather than a pass/fail gate; it carries its own A/A control, which is the same check from the inside"
  "a scaling measurement rather than a pass/fail gate: it exits 0 for any ratio and 1 only when the node totals span more than the tolerance, and that refusal is the one perfbudget's row already covers. Its own A/A control is the check from the inside, as npsab's is"
  "this script -- it cannot be its own negative control"
  "a harness imported by instrumented.py rather than a gate; instrumented.py's row covers it"
  "the zone table, sourced by the four zone-aware gates; it asserts nothing itself"
  "a report rather than a pass/fail gate: it exits 0 for any ratio, and 1 only when the node counts differ or perfcounters_report.py could not report, so the only thing to control is the VOID refusal, which perfbudget's row already covers"
  "the aggregation half of perfcounters.sh, invoked by it rather than run"
  "a report rather than a pass/fail gate, and its VOID refusal is the same one perfbudget's row covers"
  "the decomposition half of perfdecomp.sh, invoked by it rather than run"
  "plays games under a time control; a planted defect would be scored by the same clock the box perturbs, so a control here measures the runner"
)

echo
echo "== gates whose failure has been observed =="
cov_rc=0
for g in tests/*.sh tests/*.py; do
    [ -e "$g" ] || continue
    name=$(basename "$g"); stem=${name%.*}
    covered=no
    for r in $KNOWN; do
        case "$r" in "$stem"|"$stem"-*) covered=yes ;; esac
    done
    excused=""; i=0
    for e in "${COVERAGE_EXCUSED_NAMES[@]}"; do
        [ "$e" = "$name" ] && excused=${COVERAGE_EXCUSED_WHY[$i]}
        i=$((i+1))
    done
    if [ "$covered" = yes ] && [ -n "$excused" ]; then
        echo "  STALE EXCUSE: $name has a row but is excused -- remove the excuse"
        cov_rc=1
    elif [ "$covered" = yes ]; then
        echo "  covered    $name"
    elif [ -n "$excused" ]; then
        echo "  excused    $name -- $excused"
    else
        echo "  NO ROW     $name -- add one, or an excuse saying why it cannot fail"
        cov_rc=1
    fi
done

for e in "${COVERAGE_EXCUSED_NAMES[@]}"; do
    [ -e "tests/$e" ] || { echo "  DEAD EXCUSE: tests/$e is not in the tree"; cov_rc=1; }
done
[ "$cov_rc" = 0 ] || FAIL=$((FAIL+1))

# --------------------------------------------------------------------- verdict

case " $KNOWN " in
    *" $SELECT "*|*" all "*) : ;;
esac
if [ "$SELECT" = static ]; then
    # A group that names no row mutated nothing and proved nothing, which is the
    # third way this rig can be wrong about itself. Refuse rather than report a
    # verdict, the same as a rotted anchor or a selector naming no row.
    [ -n "$STATIC" ] || die "the static group is empty; tag rows with 'row <name> static'"
elif [ "$SELECT" != "all" ]; then
    case " $KNOWN " in
        *" $SELECT "*) : ;;
        *) die "no row named '$SELECT'; rows are:$KNOWN" ;;
    esac
fi

echo
# Prove the tree is clean by RUNNING a gate, not by asserting it.
( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1 \
    || die "the tree does not build after restore"
REF=$(git log --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
if [ -n "$REF" ] && ! ( cd src && ../tests/signature.sh "$REF" ) >/dev/null 2>&1; then
    die "the tree does not reproduce $REF after restore -- sources were NOT put back"
fi

TOTAL=$((PASS+FAIL))
echo "$PASS of $TOTAL gate(s) detected their mutation, $SKIP skipped, tree restored"
[ "$SKIP" -gt 0 ] && echo "a skipped row proved nothing"
[ "$FAIL" = "0" ] || exit 1
exit 0
