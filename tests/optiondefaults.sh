#!/bin/bash
# The engine's own option defaults must equal the UCI ones the shell registers.
#
# engine/searchoptions.h is a VALUE the shell fills before a search, which is what
# lets the engine be driven with no option model behind it. Its header states the
# invariant and names the failure:
#
#   EVERY FIELD DEFAULTS TO A WORKING VALUE, matching the option the shell
#   registers for it in Engine::Engine. Keep the two in step: a default that
#   drifts makes an unhosted search run with different parameters from the UCI
#   engine, and both still produce a plausible number.
#
# Nothing held them there. That failure is the expensive class: no gate sees it.
# The bench runs hosted, so it reads the UCI defaults; tests/enginelink.sh runs
# unhosted, so it reads the struct's -- and it asserts only that the node count is
# non-zero, never a value, because a node count is signature.sh's claim. A drifted
# default therefore moves the numbers a gate prints while every gate stays green.
#
# THE MAPPING IS NOT HAND-KEPT. Engine::search_options() already assigns each
# field from its option, so this reads the mapping out of that function rather
# than restating it here. A restatement is a third copy of a fact two files
# already disagree about, and it would go stale in the same way.
#
# THE UCI SIDE COMES FROM THE RUNNING ENGINE, not from parsing options.add().
# Those calls take four different Option shapes and one default is a named
# constant (Skill::LowestElo), so a parser would have to resolve C++ to answer.
# The engine prints what it registered; that is the fact this gate is about.
#
# What it does NOT check: options the engine has no field for -- Hash, EvalFile,
# SyzygyPath, UCI_Chess960, Debug Log File. Those are the shell's alone and there
# is no second copy to drift against.
#
# Exit codes:  0 every mapped default agrees   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

BIN=${1:-src/stockfish}
HDR=src/engine/searchoptions.h
SRC=src/shell/engine.cpp

die()  { echo "optiondefaults: $*" >&2; exit 1; }
skip() { echo "optiondefaults: SKIPPED -- $*" >&2; exit 2; }

[ -x "$BIN" ] || skip "no engine at $BIN -- build it first"
[ -f "$HDR" ] || skip "no $HDR"
[ -f "$SRC" ] || skip "no $SRC"

# ---- the mapping, read from Engine::search_options()
# `o.field = <cast>(options["Name"]);`
MAP=$(sed -n '/^SearchOptions Engine::search_options() const {/,/^}/p' "$SRC" \
      | sed -n 's/^[[:space:]]*o\.\([A-Za-z0-9_]*\)[[:space:]]*=.*options\["\([^"]*\)"\].*/\1\t\2/p')
[ -n "$MAP" ] || die "could not read the field-to-option mapping from $SRC"

# ---- the engine-side defaults, read from the struct
# `<type> field = <value>;`, with the trailing comment and semicolon removed.
DEFS=$(sed -n '/^struct SearchOptions {/,/^};/p' "$HDR" \
       | sed -n 's/^[[:space:]]*[A-Za-z_:<>]*[[:space:]][[:space:]]*\([A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*\(.*\);[[:space:]]*$/\1\t\2/p')
[ -n "$DEFS" ] || die "could not read the defaults from $HDR"

# ---- the UCI defaults, from the engine that registered them
UCI=$(printf 'uci\nquit\n' | "$BIN" 2>/dev/null \
      | sed -n 's/^option name \(.*\) type \(check\|spin\|string\) default \([^ ]*\).*$/\1\t\3/p')
[ -n "$UCI" ] || die "the engine printed no option lines -- is $BIN an engine?"

field_default() { printf '%s\n' "$DEFS" | awk -F'\t' -v f="$1" '$1==f{print $2; exit}'; }
uci_default()   { printf '%s\n' "$UCI"  | awk -F'\t' -v o="$1" '$1==o{print $2; exit}'; }

# A C++ literal and a UCI value spell the same thing differently in exactly two
# ways: a std::string default carries quotes, and an empty one prints <empty>.
normalise() { printf '%s' "$1" | sed 's/^"//; s/"$//; s/^<empty>$//'; }

echo "== engine field, shell option, default =="
checked=0; bad=0; unmapped=0

# Every field in the struct must be mapped. A new field the shell never assigns
# is one the engine reads and no host sets, which is the drift this gate exists
# to catch arriving before either side has a value to disagree about.
while IFS=$'\t' read -r f _; do
    [ -n "$f" ] || continue
    if ! printf '%s\n' "$MAP" | cut -f1 | grep -qx "$f"; then
        echo "  UNMAPPED    $f -- in SearchOptions and assigned by no option"
        unmapped=$((unmapped+1))
    fi
done <<< "$DEFS"

while IFS=$'\t' read -r field opt; do
    [ -n "$field" ] || continue
    d=$(field_default "$field")
    [ -n "$d" ] || die "$field is assigned from \"$opt\" but has no default in $HDR"
    u=$(uci_default "$opt")
    [ -n "$u" ] || die "\"$opt\" is assigned to $field but the engine registered no such option"
    dn=$(normalise "$d"); un=$(normalise "$u")
    checked=$((checked+1))
    if [ "$dn" = "$un" ]; then
        printf '  ok          %-18s %-20s %s\n' "$field" "$opt" "$un"
    else
        printf '  MISMATCH    %-18s %-20s engine=%s uci=%s\n' "$field" "$opt" "$dn" "$un"
        bad=$((bad+1))
    fi
done <<< "$MAP"

# A comparison that compared nothing is not a pass. Both parsers can succeed and
# still produce an empty intersection.
[ "$checked" -gt 0 ] || die "compared nothing -- the mapping and the defaults did not meet"

echo
echo "optiondefaults: $checked default(s) compared"
[ "$unmapped" = 0 ] || echo "optiondefaults: $unmapped field(s) in SearchOptions that no option fills"
[ "$bad" = 0 ]      || echo "optiondefaults: $bad default(s) disagree -- an unhosted search runs different parameters"
if [ "$bad" = 0 ] && [ "$unmapped" = 0 ]; then
    echo "optiondefaults: clean"
    exit 0
fi
echo "optiondefaults: FINDINGS"
exit 1
