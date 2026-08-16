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
#
# A SKIP IS NOT A PASS, and eight of the fifteen fixtures below need the 3-man
# corpus. Reaching the end with any of them unrun exits 2, the code this header
# has always named: a gate that returns 0 over half its cases counts in a lane
# summary as coverage it did not provide.

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

ARCH=${ARCH:-x86-64-avx2}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
EXE=${EXE:-}

# The corpus is fetched, never committed -- .gitignore covers tests/syzygy-3man
# -- so a GIT WORKTREE starts without it while the checkout it was cut from has
# it already. `git rev-parse --git-common-dir` names that checkout's .git, and
# its parent is where tbfetch.sh put the tables, so a worktree finds them
# instead of skipping eight fixtures a metre from the files.
corpus_default() {
    local common
    [ -d "$ROOT/tests/syzygy-3man" ] && { echo "$ROOT/tests/syzygy-3man"; return; }
    common=$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null) || true
    if [ -n "$common" ]; then
        common=$(cd "$ROOT" && cd "$(dirname "$common")" && pwd)
        [ -d "$common/tests/syzygy-3man" ] && { echo "$common/tests/syzygy-3man"; return; }
    fi
    echo "$ROOT/tests/syzygy-3man"
}
CORPUS=${CORPUS:-$(corpus_default)}

usage() {
    cat <<'EOF'
usage: tests/malformed.sh [--exe PATH] [--arch ARCH] [--jobs N] [--corpus DIR]

  --exe PATH    test this binary instead of building a sanitized one. It is then
                YOUR claim that it was built with the sanitizers; the gate cannot
                tell, and a clean run over an unsanitized binary proves less than
                it appears to.
  --arch ARCH   build architecture (default x86-64-avx2)
  --jobs N      parallel build jobs (default: nproc)
  --corpus DIR  3-man Syzygy tables for the eight corpus fixtures. Defaults to
                tests/syzygy-3man in this tree, then in the checkout a worktree
                was cut from. Without them the gate exits 2, not 0.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --exe)     EXE=$2; shift 2 ;;
        --arch)    ARCH=$2; shift 2 ;;
        --jobs)    JOBS=$2; shift 2 ;;
        --corpus)  CORPUS=$2; shift 2 ;;
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
    # blockLengthSize is blocksNum + padding and set_sizes refuses zero, since
    # decompress_pairs' clamp computes blockLengthSize - 1 on an unsigned. One
    # padding entry with no blocks keeps that refusal off the path so each
    # fixture below is still refused for ITS OWN reason and not for this one.
    b[13] = 1                                  # padding = 1
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


def symlen_past_domain():
    """More symbols than a twelve-bit Sym can name, in a file with ROOM for them.

    btree_past_end above declares 65535 in 80 bytes, and the space check refuses
    it before the copy: 65535 * 3 does not fit. That is why the count was never
    compared against the domain it indexes, and why no table in the corpus can
    show it -- they are all too small. This one is 19,216 bytes (st_size % 64 is
    still 16) so 5000 * 3 fits, and btreeBuf[] holds 4096.
    """
    b = base()
    b.extend(bytearray(64 * 300 - 64))
    b[22] = 0x88; b[23] = 0x13                 # 5000 symbols
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
  "symlen-past-domain|symlen_past_domain"
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

# ------------------------------------------------ resource-exhaustion fixtures
#
# Not a malformed FILE, but the same question asked of a different input: the
# engine is told to acquire something the host will not give it. The acceptable
# answers are a diagnostic and an exit; the answers this section exists to
# refuse are a signal, an abort, and a hang. A hang is the one a timeout in the
# harness would otherwise report as a rig fault, so every case owns a deadline.
#
# THE FAILURE IS INJECTED THROUGH THE SANITIZER, not through `ulimit -v`. ASan
# reserves a shadow mapping measured in terabytes before main, so an address
# space limit small enough to fail an engine allocation kills the sanitized
# binary at startup and proves nothing. `max_allocation_size_mb` fails exactly
# the allocations above a chosen size, and `allocator_may_return_null` makes
# that failure a null return rather than the sanitizer's own abort -- which is
# what the engine has to survive. The limit sits above the net (46 MB) and below
# the pawn history at 16 threads (256 MiB), so startup completes and the
# setoption is what fails.
check_resource() {
    local name=$1 asan=$2 deadline=$3; shift 3
    local out rc
    out=$( ( printf '%s\n' "$@"; sleep 0.5 ) \
           | ( cd "$EXEDIR" && ASAN_OPTIONS="$asan" \
               timeout -s KILL "$deadline" "$EXE" ) 2>&1 )
    rc=$?

    local bad=0
    if [ "$rc" = "137" ]; then
        note "no answer inside ${deadline}s -- a wedge, which is the worst answer"; bad=1
    elif [ "$rc" -ge 128 ]; then
        note "exit $rc -- killed by a signal"; bad=1
    fi
    if grep -qE 'AddressSanitizer:|runtime error:|terminate called|Assertion' <<< "$out"; then
        note "the process did not survive its own failure:"
        grep -m2 -E 'AddressSanitizer:|runtime error:|terminate called|Assertion' <<< "$out" \
          | sed 's/^/    /'
        bad=1
    fi
    if ! grep -qiE 'failed to allocate|failed to create|cannot' <<< "$out"; then
        note "no diagnostic -- it failed without saying so, or did not fail at all"; bad=1
    fi

    if [ "$bad" = "0" ]; then
        echo "malformed: $name  reported"; PASS=$((PASS+1))
    else
        echo "malformed: $name  NOT REPORTED"; FAIL=$((FAIL+1))
    fi
}

# ------------------------------------------------- the block-walk fixture
#
# A DIFFERENT SHAPE OF REFUSAL, and the difference is the point. Every fixture
# above is refused with a diagnostic, because what is wrong with it is visible
# at load time. This one is not: byte 90 of KQvK.rtbw is inside sparseIndex[],
# a 4-byte block index whose only constraint is that it points at a block, and
# the Syzygy format carries nothing that says which value was meant. The reader
# cannot know it is wrong and must not pretend to. What it must do is stay
# inside blockLength[] and keep answering.
#
# So the judge here asks for survival, not for a diagnostic: exit 0, a
# bestmove, and nothing from the sanitizers. Asking for the word "corrupt"
# would be asking the parser to detect what the format does not record.
check_survives() {
    local name=$1 dir=$2 fen=$3 out rc
    out=$( ( printf 'setoption name SyzygyPath value %s\nisready\n' "$dir"; sleep 0.4;
             printf 'position fen %s\ngo depth 12\n' "$fen"; sleep 6;
             printf 'quit\n'; sleep 0.3 ) \
           | ( cd "$EXEDIR" && timeout -s KILL 90 "$EXE" ) 2>&1 )
    rc=$?

    local bad=0
    [ "$rc" = "0" ] || { note "exit $rc -- survival means exiting 0"; bad=1; }
    if grep -qE 'AddressSanitizer|runtime error:|UndefinedBehaviorSanitizer' <<< "$out"; then
        note "a sanitizer reported:"
        grep -m2 -E 'AddressSanitizer|runtime error:' <<< "$out" | sed 's/^/    /'
        bad=1
    fi
    if grep -qE 'terminate called|Assertion|attempt to subscript|Aborted' <<< "$out"; then
        note "the process aborted:"
        grep -m2 -E 'terminate called|Assertion|attempt to subscript' <<< "$out" | sed 's/^/    /'
        bad=1
    fi
    grep -q '^bestmove' <<< "$out" || { note "no bestmove -- it stopped answering"; bad=1; }
    grep -q 'Found 0 WDL' <<< "$out" \
        && { note "no table was loaded -- the fixture probed nothing"; bad=1; }

    if [ "$bad" = "0" ]; then
        echo "malformed: $name  survived"; PASS=$((PASS+1))
    else
        echo "malformed: $name  NOT SURVIVED"; FAIL=$((FAIL+1))
    fi
}

# Two fixtures the tb fuzz harness found, replayed as the exact byte edits it
# made rather than as a seed. A seed is a reproducer for the harness; a byte
# list is a reproducer for the DEFECT, and it survives the harness changing.
#
#   huffman-noncanon  KRvK.rtbw, 8 bytes: lowestSym[] stops descending, so the
#                     base64[] table decompress_pairs searches is not a
#                     canonical Huffman code. Upstream states that with an
#                     assert, which -DNDEBUG deletes from every shipped binary.
#   symbol-past-end   KQvK.rtbw, 8 bytes: the symbol decompress_pairs computes
#                     from the compressed stream lands outside the 12-bit
#                     alphabet symlen[] and btree[] are sized for.
patch_bytes() {
    local file=$1; shift
    while [ $# -ge 2 ]; do
        printf "$(printf '\\x%02x' "$2")" \
          | dd of="$file" bs=1 seek="$1" count=1 conv=notrunc 2>/dev/null
        shift 2
    done
}

if [ -f "$CORPUS/KRvK.rtbw" ]; then
    dir="$WORK/fx/huffman-noncanon"
    mkdir -p "$dir"; cp "$CORPUS"/*.rtb? "$dir/"
    patch_bytes "$dir/KRvK.rtbw" 32 220 108 111 29 250 109 40 189 0 65 158 113 213 163 212
    check_survives "huffman-noncanon" "$dir" "4k3/8/8/8/8/8/8/3RK3 w - - 0 1"
else
    echo "malformed: huffman-noncanon SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

if [ -f "$CORPUS/KQvK.rtbw" ]; then
    dir="$WORK/fx/symbol-past-end"
    mkdir -p "$dir"; cp "$CORPUS"/*.rtb? "$dir/"
    patch_bytes "$dir/KQvK.rtbw" 144 1 222 248 35 189 268 220 66 15 228 85 229 65 108 212
    check_survives "symbol-past-end " "$dir" "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"
else
    echo "malformed: symbol-past-end  SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

if [ -f "$CORPUS/KNvK.rtbw" ]; then
    dir="$WORK/fx/flags-vs-material"
    mkdir -p "$dir"; cp "$CORPUS"/*.rtb? "$dir/"
    # Byte 4 is the flags byte, and its Split and HasPawns bits are a claim
    # about the material the file holds. The engine derives `sides` and
    # `maxFile` from the material it ASKED for, so a file whose flags disagree
    # is laid out to one plan and read to another. Upstream states that with an
    # assert, which -DNDEBUG deletes.
    patch_bytes "$dir/KNvK.rtbw" 4 192 41 124 33 37 5 7 61 88 54 110
    check_survives "flags-vs-material" "$dir" "4k3/8/8/8/8/8/8/3NK3 w - - 0 1"
else
    echo "malformed: flags-vs-material SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

if [ -f "$CORPUS/KRvK.rtbw" ]; then
    dir="$WORK/fx/cyclic-btree"
    mkdir -p "$dir"; cp "$CORPUS"/*.rtb? "$dir/"
    # A Huffman tree that closes a loop. set_symlen's own comment used to say
    # "we can set it now because tree is acyclic" -- a claim about the file --
    # and decompress_pairs' expansion walk takes `sym = left` WITHOUT decreasing
    # `offset`, so a cycle spins it forever. This fixture is the one that has to
    # own a deadline: the failure it covers is a HANG, and a harness that waits
    # for a wedged engine reports nothing at all.
    patch_bytes "$dir/KRvK.rtbw" 100 132 53 183 119 76 185 57 183 198
    check_survives "cyclic-btree   " "$dir" "4k3/8/8/8/8/8/8/3RK3 w - - 0 1"
else
    echo "malformed: cyclic-btree    SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

if [ -f "$CORPUS/KQvK.rtbw" ]; then
    dir="$WORK/fx/bitstream-walk"
    mkdir -p "$dir"; cp "$CORPUS"/*.rtb? "$dir/"
    # The Huffman stream that decompress_pairs walks forward four bytes at a
    # time, with the block index it starts from taken out of the padded region
    # of blockLength[]. Both ends leave the mapping. The fault is ASLR-dependent
    # -- it needs the page after the table to be unmapped -- so this fixture is
    # a probability, not a certainty, and it is here because a sanitizer turns
    # that probability into a report.
    patch_bytes "$dir/KQvK.rtbw" 144 1 222 248 35 189 268 220 66 15 228 85 229 65 108 212
    check_survives "bitstream-walk " "$dir" "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"
else
    echo "malformed: bitstream-walk  SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

if [ -f "$CORPUS/KQvK.rtbw" ]; then
    dir="$WORK/fx/sparse-block"
    mkdir -p "$dir"
    cp "$CORPUS"/*.rtb? "$dir/"
    # Offset 90 is the first SparseEntry of the non-single-value side, and its
    # first four bytes are the block index. 0xFFFFFFFF against a table whose
    # blockLengthSize is 2 walks decompress_pairs off the end of blockLength[]
    # in the unbounded reader, and `--block` on the way down wraps past zero.
    printf '\xff\xff\xff\xff' \
      | dd of="$dir/KQvK.rtbw" bs=1 seek=90 count=4 conv=notrunc 2>/dev/null
    check_survives "sparse-block   " "$dir" "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"
else
    echo "malformed: sparse-block    SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

if [ -f "$CORPUS/KQvK.rtbw" ]; then
    dir="$WORK/fx/truncated-table"
    mkdir -p "$dir"
    cp "$CORPUS"/*.rtb? "$dir/"
    # One byte short, which is what an interrupted download leaves. Every Syzygy
    # table is 16 bytes past a multiple of 64 and TBFile::map has always tested
    # that -- but the test ran on the first PROBE, because Tablebases::init
    # counts files and maps none, and it ended the process there: no bestmove,
    # mid-search, on a file the load had already reported as found. The engine
    # must refuse the table and keep playing without it.
    truncate -s -1 "$dir/KQvK.rtbw"
    check "truncated-table" "$dir" "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"
else
    echo "malformed: truncated-table  SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

if [ -f "$CORPUS/KQvK.rtbw" ]; then
    dir="$WORK/fx/empty-blocklength"
    mkdir -p "$dir"
    cp "$CORPUS"/*.rtb? "$dir/"
    # Bytes 16..19 are blocksNum for the non-single-value side -- the same side
    # sparse-block above reaches at offset 90 -- and its padding byte at 15 is
    # already 0 in the shipped table. Zeroing the four makes blockLengthSize 0,
    # and the block clamp then computes 0 - 1 on an unsigned and indexes
    # blockLength[] eight gibibytes past its end. Unlike the fixtures above this
    # one is refused with a diagnostic, because an empty block-length array is
    # visible at load time; before the refusal it was `exit 139, core dumped`.
    printf '\x00\x00\x00\x00' \
      | dd of="$dir/KQvK.rtbw" bs=1 seek=16 count=4 conv=notrunc 2>/dev/null
    check "empty-blocklength" "$dir" "4k3/8/8/8/8/8/8/3QK3 w - - 0 1"
else
    echo "malformed: empty-blocklength SKIPPED -- no 3-man corpus; run tests/tbfetch.sh"
    SKIP=$((SKIP+1))
fi

echo
check_resource "alloc-failure  " "allocator_may_return_null=1:max_allocation_size_mb=128" 60 \
    "setoption name Threads value 16" "isready" "quit"

echo
echo "malformed: $PASS refused, $FAIL not refused, $SKIP skipped"
[ "$FAIL" = "0" ] || exit 1
if [ "$SKIP" != "0" ]; then
    echo "malformed: SKIPPED -- $SKIP fixtures did not run; no corpus at $CORPUS" >&2
    echo "malformed: fetch it with tests/tbfetch.sh, or name one with --corpus" >&2
    exit 2
fi
exit 0
