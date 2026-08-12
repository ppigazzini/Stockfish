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
        '    w.limits          = LimitsType();' \
        '    if (depth > 0)
        *(volatile int*) nullptr = 0;
    w.limits          = LimitsType();'
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
