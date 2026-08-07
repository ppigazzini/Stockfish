#!/bin/bash
# Break the engine on purpose and require each gate to notice.
#
# A gate's power to detect a defect is an assumption until something breaks the
# code and the gate is watched going red. A gate that has quietly stopped being
# able to fail is invisible, because it reports success -- which is what everyone
# was hoping for.
#
# Every mutation here PERTURBS A VALUE rather than removing a bound. A mutant
# that hands the search an evaluation with no ceiling produces an experiment that
# never terminates, and a timeout is a rig fault, never a detection.
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
# Exit codes:  0 every selected row detected its mutation   1 a row did not   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

SELECT=${1:-all}
BACKUP=$(mktemp -d)
MUTATED=""

restore() {
    if [ -n "$MUTATED" ] && [ -f "$BACKUP/$(basename "$MUTATED")" ]; then
        cp "$BACKUP/$(basename "$MUTATED")" "$MUTATED"
        MUTATED=""
    fi
}
cleanup() { restore; rm -rf "$BACKUP"; }
trap cleanup EXIT INT TERM

die() { echo "negative-control: $*" >&2; exit 1; }

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
    cp "$file" "$BACKUP/$(basename "$file")"
    MUTATED=$file
    python3 - "$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(p, encoding="utf8").read()
assert t.count(a) == 1
open(p, "w", encoding="utf8").write(t.replace(a, b))
PY
}

PASS=0; FAIL=0; SKIP=0
selected() { [ "$SELECT" = "all" ] || [ "$SELECT" = "$1" ]; }
KNOWN=""

row() { KNOWN="$KNOWN $1"; }

# --------------------------------------------------------------- signature

row signature
if selected signature; then
    REF=$(git log -60 --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
    if [ -z "$REF" ]; then
        echo "negative-control: signature   SKIPPED -- no Bench: in the last 60 commit bodies"
        SKIP=$((SKIP+1))
    else
        echo "negative-control: signature   -- futility multiplier base 45 -> 46"
        mutate src/search.cpp \
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
        mutate src/position.h \
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
    mutate src/position.h \
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

row docslint
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

# --------------------------------------------------------------- fingerprint

row golden
if selected golden; then
    echo "negative-control: golden      -- an info field renamed, which the signature cannot see"
    mutate src/uci.cpp \
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

row golden-empty
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

row docslint-path
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

row docslint-bench
if selected docslint-bench; then
    REF=$(git log -60 --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
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

row docslint-gate
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

row docslint-internal
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
        mutate src/position.h \
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

row lanecheck-reach
if selected lanecheck-reach; then
    echo "negative-control: lanecheck   -- the budget lane unwired from the umbrella"
    mutate .github/workflows/stockfish.yml \
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

row lanecheck
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
        mutate src/movegen.cpp \
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
    if [ -z "$(ls tests/syzygy 2>/dev/null)" ]; then
        echo "negative-control: fuzz [tb]   SKIPPED -- no corpus; run tests/tbfetch.sh"
        SKIP=$((SKIP+1))
    else
        echo "negative-control: fuzz [tb]   -- an engine that dies on a corrupt table"
        stub tbcrash '#!/bin/bash
echo "info string Found 5 WDL and 5 DTZ tablebase files (up to 3-man)."
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
    if [ -z "$(ls tests/syzygy 2>/dev/null)" ]; then
        echo "negative-control: fuzz [rig]  SKIPPED -- no corpus; run tests/tbfetch.sh"
        SKIP=$((SKIP+1))
    else
        # The inverse of every other row: the harness must NOT claim a finding.
        # A run where no table loaded tests nothing, and reporting it as a defect
        # is how a harness earns credit for an experiment it never ran -- which
        # this one did on its first run, against an illegal fixture.
        echo "negative-control: fuzz [rig]  -- a rig with no tables must not read as a finding"
        stub norig '#!/bin/bash
echo "info string Found 0 WDL and 0 DTZ tablebase files (up to 3-man)."
cat >/dev/null
echo "bestmove a1a1"
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

row fuzz-net
if selected fuzz-net; then
    echo "negative-control: fuzz [net]  -- an engine that dies on a corrupt net"
    stub netcrash '#!/bin/bash
cat >/dev/null
kill -SEGV $$'
    if EXE="$NCSTUB/netcrash" ./tests/fuzz.py --seconds 1 --harness net >/dev/null 2>&1; then
        echo "  NOT DETECTED -- a crashing engine ran clean"; FAIL=$((FAIL+1))
    else
        echo "  ok, red (1)"; PASS=$((PASS+1))
    fi
fi

rm -rf "$NCSTUB"

# --------------------------------------------------------------------- verdict

case " $KNOWN " in
    *" $SELECT "*|*" all "*) : ;;
esac
if [ "$SELECT" != "all" ]; then
    case " $KNOWN " in
        *" $SELECT "*) : ;;
        *) die "no row named '$SELECT'; rows are:$KNOWN" ;;
    esac
fi

echo
# Prove the tree is clean by RUNNING a gate, not by asserting it.
( cd src && make -j"$(nproc)" build ARCH=x86-64-avx2 ) >/dev/null 2>&1 \
    || die "the tree does not build after restore"
REF=$(git log -60 --format='%b' | grep -oE 'Bench: *[0-9]+' | head -1 | grep -oE '[0-9]+')
if [ -n "$REF" ] && ! ( cd src && ../tests/signature.sh "$REF" ) >/dev/null 2>&1; then
    die "the tree does not reproduce $REF after restore -- sources were NOT put back"
fi

TOTAL=$((PASS+FAIL))
echo "$PASS of $TOTAL gate(s) detected their mutation, $SKIP skipped, tree restored"
[ "$SKIP" -gt 0 ] && echo "a skipped row proved nothing"
[ "$FAIL" = "0" ] || exit 1
exit 0
