#!/bin/bash
# Decide the NNUE LEB128 reader against the format rather than against the net.
#
# tests/signature.sh proves the engine searched the same tree, which proves the
# net decoded to the same 23 M weights it did before -- on ONE file, whose every
# value is 16-bit and minimally encoded. The reader is specified for more: 32-bit
# values, five-group payloads, redundant encodings, a value split across a
# refill, a truncated stream. None of that is in any net in the tree, so no gate
# here sees it and a decoder that got all of it wrong still prints the anchor.
#
# tests/leb128_main.cpp round-trips against write_leb_128 -- the writer is in the
# same header and is the format's other half -- and hand-builds the streams the
# writer will never emit.
#
# THE ARCH FLAGS ARE NOT OPTIONAL. The reader's word decoder is selected by
# __BYTE_ORDER__ and by the compiler, not by the tier, but the header it lives in
# includes the NNUE intrinsic set and will not compile without a tier's defines.
# A run at the wrong tier compiles a different header.
#
# Exit codes:  0 every case passed   1 a case failed   2 skipped, or the rig failed

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

ARCH=${ARCH:-x86-64-avx2}
CXX=${CXX:-g++}
ITER=${ITER:-200}
SAN=${SAN:-yes}

usage() {
    cat <<'EOF'
usage: tests/leb128.sh [options]

  --arch ARCH   tier whose defines the header is compiled with (default x86-64-avx2)
  --comp CXX    compiler (default g++)
  --iter N      random round-trip iterations (default 200)
  --no-sanitize skip the second, sanitized run
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH=$2; shift 2 ;;
        --comp) CXX=$2; shift 2 ;;
        --iter) ITER=$2; shift 2 ;;
        --no-sanitize) SAN=no; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "leb128: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v "$CXX" >/dev/null || { echo "leb128: SKIPPED -- no $CXX" >&2; exit 2; }

# The tier's own defines, taken from the Makefile rather than restated here: a
# second copy of this list is a second thing to keep in step with src/Makefile.
ARCHFLAGS=$(cd "$ROOT/src" && make ARCH="$ARCH" config-sanity 2>/dev/null \
            | grep -oE '\-D[A-Za-z0-9_]+|-m[a-z0-9.]+' | sort -u | tr '\n' ' ')
if [ -z "$ARCHFLAGS" ]; then
    echo "leb128: SKIPPED -- the Makefile named no flags for ARCH=$ARCH" >&2
    exit 2
fi

WORK=$(mktemp -d) || exit 2
trap 'rm -rf "$WORK"' EXIT

echo "leb128: $ARCH, $($CXX --version | head -1)"

if ! "$CXX" -std=c++17 -O2 -Wall -Wextra -Wshadow $ARCHFLAGS \
     -o "$WORK/leb128" tests/leb128_main.cpp > "$WORK/build.log" 2>&1; then
    echo "leb128: SKIPPED -- the fixture would not compile" >&2
    tail -12 "$WORK/build.log" >&2
    exit 2
fi

"$WORK/leb128" "$ITER"
RC=$?
[ $RC -eq 0 ] || exit 1

# A wrong window read is a read of memory the fixture owns, so it produces a
# right answer far more often than it produces a wrong one. The sanitized run is
# what turns that into a report.
if [ "$SAN" = yes ]; then
    if "$CXX" -std=c++17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
         $ARCHFLAGS -o "$WORK/leb128-san" tests/leb128_main.cpp > "$WORK/san.log" 2>&1; then
        echo "leb128: re-running under address+undefined ..."
        ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
            "$WORK/leb128-san" "$ITER" > "$WORK/san.out" 2>&1
        RC=$?
        grep -E "runtime error|ERROR: AddressSanitizer|FAIL" "$WORK/san.out" && RC=1
        [ $RC -eq 0 ] || { tail -20 "$WORK/san.out" >&2; exit 1; }
        echo "leb128: sanitized run clean"
    else
        echo "leb128: sanitizers unavailable, unsanitized result stands" >&2
    fi
fi

exit 0
