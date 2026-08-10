#!/bin/bash
# Assert that a KNOWN-BAD input is still refused.
#
# Every other gate in this tree measures the engine computing the right answer
# from well-formed input. `signature.sh` is the anchor and it is green with every
# parser defect this file covers live, because the bench never reads a file the
# engine did not ship with. `fuzz.py` looks for input that is bad in a way nobody
# has described yet -- a different job, on a nightly budget, and explicitly not a
# merge gate. Neither asks whether a file that was refused yesterday is refused
# today, so nothing did.
#
# A fixture here is a GENERATOR, not a committed blob. The bytes are eight lines
# of Python and the interesting thing about them is which field is wrong; a blob
# hides that and rots the moment the format is read differently.
#
# THESE NEED NO SYNTHETIC MUTATION: the defect is the mutation. Every fixture was
# red on the tree that carried the defect it covers, and the commit that closed
# it records that output.
#
# What a refusal means here, and all four parts are checked:
#
#   * the process exits 0 -- not a signal, not an abort;
#   * it prints a diagnostic naming the file, so an operator can act;
#   * no sanitizer reports anything;
#   * it still answers. A parser that takes the engine down with it has not
#     refused the file, it has been defeated by it.
#
# Built under `sanitize="address undefined" debug=yes`, so an out-of-bounds
# access that the shipped build would absorb into mmap page padding is reported
# rather than survived. A gate for refusals must be stricter than the binary it
# is protecting, or it certifies the reads it cannot see.
#
# Exit codes:  0 every fixture refused   1 a fixture was not   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

ARCH=${ARCH:-x86-64-avx2}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
EXE=${EXE:-}
CORPUS=${CORPUS:-$ROOT/tests/syzygy-3man}

usage() {
    cat <<'EOF'
usage: tests/malformed.sh [--exe PATH] [--arch ARCH] [--jobs N]

  --exe PATH    test this binary instead of building a sanitized one. It is then
                YOUR claim that it was built with the sanitizers; the gate cannot
                tell, and a clean run over an unsanitized binary proves less than
                it appears to.
  --arch ARCH   build architecture (default x86-64-avx2)
  --jobs N      parallel build jobs (default: nproc)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --exe)     EXE=$2; shift 2 ;;
        --arch)    ARCH=$2; shift 2 ;;
        --jobs)    JOBS=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "malformed: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

# ------------------------------------------------------------------ the binary

if [ -z "$EXE" ]; then
    # Build from the WORKING TREE, not from HEAD: this gate exists to be run on
    # a change before it is a commit, and `git ls-files` piped through tar reads
    # each tracked path's working-tree content.
    # scripts/ too: the Makefile's `build` target depends on `net`, which runs
    # scripts/net.sh. The net is copied in below and the target then verifies it
    # rather than fetching, but the script has to be there for it to run at all.
    git ls-files -z src scripts | tar --null -T - -cf - \
      | ( mkdir -p "$WORK/w" && tar -xf - -C "$WORK/w" )
    cp src/*.nnue "$WORK/w/src/" 2>/dev/null
    if ! ls "$WORK/w/src"/*.nnue >/dev/null 2>&1; then
        echo "malformed: SKIPPED -- no net in src/; run 'make net' first" >&2
        exit 2
    fi

    echo "malformed: building $ARCH under address+undefined, asserts on ..."
    if ! ( cd "$WORK/w/src" \
           && make -j"$JOBS" build ARCH="$ARCH" debug=yes sanitize="address undefined" ) \
         > "$WORK/build.log" 2>&1; then
        echo "malformed: SKIPPED -- the sanitized build failed" >&2
        tail -12 "$WORK/build.log" >&2
        exit 2
    fi
    EXE="$WORK/w/src/stockfish"
fi

[ -x "$EXE" ] || { echo "malformed: SKIPPED -- no engine at $EXE" >&2; exit 2; }
EXEDIR=$(cd "$(dirname "$EXE")" && pwd)
EXE="$EXEDIR/$(basename "$EXE")"

# ---------------------------------------------------------------- the fixtures

# One WDL table for KQvK, 80 bytes: `st_size % 64 == 16` and a correct magic are
# the only two things TBFile::map checks, and mmap zero-pads the rest of the
# page, so this is the smallest input that reaches the parser at all.
#
# Field offsets, all of them read straight out of the file:
#   4      Split | HasPawns          10  flags       11  log2 sizeofBlock
#   12     log2 span                 13  padding     14  blocksNum (u32)
#   18     maxSymLen                 19  minSymLen   20  lowestSym[]
#   22     symlen count (u16)        24  btree[0]
cat > "$WORK/gen.py" <<'PY'
import os
import sys


def base():
    b = bytearray(80)
    b[0:4] = bytes([0x71, 0xE8, 0x23, 0x5D])   # WDL magic
    b[4] = 0x01                                # Split = 1, HasPawns = 0
    b[11] = 6; b[12] = 6                       # sizeofBlock = span = 64
    b[18] = 1; b[19] = 1                       # maxSymLen = minSymLen = 1
    b[22] = 1                                  # one Huffman symbol declared
    return b


def symbol_oob():
    """A child symbol the declared alphabet does not contain."""
    b = base()
    b[24] = 0x00; b[25] = 0x00; b[26] = 0x80   # btree[0].Right = 2048
    return b


def negative_resize():
    """minSymLen above maxSymLen: base64 is resized to their difference."""
    b = base()
    b[18] = 0; b[19] = 0xFF
    return b


def block_shift():
    """A block size of 1 << 200."""
    b = base()
    b[11] = 200
    return b


def base64_shift():
    """minSymLen 0, which right-pads base64 by exactly 64 bits."""
    b = base()
    b[18] = 0; b[19] = 0
    return b


def btree_past_end():
    """65535 symbols declared by a file that holds 80 bytes."""
    b = base()
    b[22] = 0xFF; b[23] = 0xFF
    return b


dest = sys.argv[2]
os.makedirs(dest, exist_ok=True)
with open(os.path.join(dest, "KQvK.rtbw"), "wb") as fh:
    fh.write(bytes(globals()[sys.argv[1]]()))
PY

# Every synthetic fixture is a KQvK table, so they all take the same probe.
KQVK_FEN="4k3/8/8/8/8/8/8/3QK3 w - - 0 1"

# name            | generator
FIXTURES=(
  "symbol-oob     |symbol_oob"
  "negative-resize|negative_resize"
  "block-shift    |block_shift"
  "base64-shift   |base64_shift"
  "btree-past-end |btree_past_end"
)

PASS=0; FAIL=0; SKIP=0
note() { echo "  $*"; }

# Drive one probe and judge the four parts of a refusal.
#
# Hold stdin open past the search. Piping the commands in closes it, the UCI loop
# reads EOF and quits mid-search, and every fixture then "passes" by returning
# before it reached the decoder.
check() {
    local name=$1 dir=$2 fen=$3 out rc
    out=$( ( printf 'setoption name SyzygyPath value %s\nisready\n' "$dir"; sleep 0.4;
             printf 'position fen %s\ngo depth 8\n' "$fen"; sleep 4;
             printf 'quit\n'; sleep 0.3 ) \
           | ( cd "$EXEDIR" && timeout -s KILL 60 "$EXE" ) 2>&1 )
    rc=$?

    local bad=0
    if [ "$rc" != "0" ]; then
        note "exit $rc -- a refusal exits 0"; bad=1
    fi
    if grep -qE 'AddressSanitizer|runtime error:|LeakSanitizer|UndefinedBehaviorSanitizer' \
       <<< "$out"; then
        note "a sanitizer reported:"
        grep -m2 -E 'AddressSanitizer|runtime error:' <<< "$out" | sed 's/^/    /'
        bad=1
    fi
    if grep -qE 'terminate called|Assertion|attempt to subscript|Aborted' <<< "$out"; then
        note "the process aborted:"
        grep -m2 -E 'terminate called|Assertion|attempt to subscript' <<< "$out" | sed 's/^/    /'
        bad=1
    fi
    # A silent refusal is half a refusal: the operator has a table that is not
    # being used and nothing saying so.
    if ! grep -qi 'corrupt' <<< "$out"; then
        note "no diagnostic -- the file was refused without saying so, or accepted"; bad=1
    fi
    if ! grep -q '^bestmove' <<< "$out"; then
        note "no bestmove -- the engine stopped answering"; bad=1
    fi

    if [ "$bad" = "0" ]; then
        echo "malformed: $name  refused"; PASS=$((PASS+1))
    else
        echo "malformed: $name  NOT REFUSED"; FAIL=$((FAIL+1))
    fi
}

echo
for row in "${FIXTURES[@]}"; do
    IFS='|' read -r name gen <<< "$row"
    dir="$WORK/fx/${gen}"
    if ! python3 "$WORK/gen.py" "$gen" "$dir"; then
        echo "malformed: SKIPPED -- the $gen generator failed" >&2
        exit 2
    fi
    check "$name" "$dir" "$KQVK_FEN"
done

# ------------------------------------------------------- the corpus fixture
#
# One byte of a REAL table, which is the shape a mirror or a bad download
# actually produces -- every synthetic fixture above is a file no generator would
# emit. Byte 10 of KNvK.rtbw is the flags byte: the shipped 128 says the table
# stores a single value, and clearing that bit sends the parser down the full
# decode path on an 80-byte file.
#
# It SKIPS loudly without the corpus rather than passing. A fixture that silently
# does nothing is worse than no fixture: it counts as coverage in every listing.
if [ -f "$CORPUS/KNvK.rtbw" ]; then
    dir="$WORK/fx/corpus-flags"
    mkdir -p "$dir"
    cp "$CORPUS"/*.rtb? "$dir/"
    printf '\x00' | dd of="$dir/KNvK.rtbw" bs=1 seek=10 count=1 conv=notrunc 2>/dev/null
    check "corpus-flags   " "$dir" "8/8/8/8/8/4k3/4n3/4K3 w - - 0 1"
else
    echo "malformed: corpus-flags    SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

echo
echo "malformed: $PASS refused, $FAIL not refused, $SKIP skipped"
[ "$FAIL" = "0" ] || exit 1
exit 0
