#!/bin/bash
# Fetch a small Syzygy set, verifying each file by MAGIC rather than by status.
#
# A mirror that answers a missing file with a body -- an HTML error page, a 404
# with content, a redirect to a landing page -- passes `curl -f` and is then
# stored as a table, failing much later inside the decoder where it reads as a
# corrupt table rather than as a bad download. Verify the first four bytes.
#
# Small enough to fetch in a CI job rather than commit, which is why it is
# fetched: the 3-man set is 12 KB and the 3-4-man set is 4.4 MB. Neither is
# worth carrying in git, and both are worth caching in a lane.
#
# `--men 4` adds the thirty 4-man stems. It is a different corpus and belongs in
# a different directory, because what a corpus CONTAINS is part of what a test
# that uses it records: MaxCardinality is 3 or 4 depending on this flag, and the
# engine prints the file count in its own output.
#
# NOT tests/syzygy. That name belongs to tests/testing.py, whose
# download_syzygy() skips its own fetch when the directory already exists and
# whose TestSyzygy then expects the 4-man set it would have downloaded -- so a
# 3-man corpus sitting there makes that suite block until its timeout on a line
# that cannot come.
#
# Exit codes:  0 present and verified   1 a file failed verification   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MEN=3
while [ $# -gt 0 ]; do
    case "$1" in
        --men) MEN=$2; shift 2 ;;
        -h|--help) echo "usage: tbfetch.sh [--men 3|4] [dest]"; exit 0 ;;
        *) break ;;
    esac
done
case "$MEN" in
    3) DEFAULT_DEST=$ROOT/tests/syzygy-3man ;;
    4) DEFAULT_DEST=$ROOT/tests/syzygy-34man ;;
    *) echo "tbfetch: --men must be 3 or 4" >&2; exit 2 ;;
esac
DEST=${1:-$DEFAULT_DEST}
BASE=${TB_MIRROR:-http://tablebase.sesse.net/syzygy/3-4-5}

# The values the engine itself checks -- `Magics` in
# src/platform/syzygy/tbprobe.cpp, whose mismatch is "Corrupted table in file":
#   DTZ  D7 66 0C A5      WDL  71 E8 23 5D
WDL_MAGIC=71e8235d
DTZ_MAGIC=d7660ca5

command -v curl >/dev/null || { echo "tbfetch: SKIPPED -- no curl" >&2; exit 2; }
mkdir -p "$DEST"

fail=0
have=0
STEMS="KQvK KRvK KPvK KNvK KBvK"
if [ "$MEN" = 4 ]; then
    # Syzygy names pieces in descending value order, so KQPvK and never KPQvK.
    STEMS="$STEMS KQQvK KQRvK KQBvK KQNvK KQPvK KRRvK KRBvK KRNvK KRPvK KBBvK"
    STEMS="$STEMS KBNvK KBPvK KNNvK KNPvK KPPvK KQvKQ KQvKR KQvKB KQvKN KQvKP"
    STEMS="$STEMS KRvKR KRvKB KRvKN KRvKP KBvKB KBvKN KBvKP KNvKN KNvKP KPvKP"
fi

for stem in $STEMS; do
    for ext in rtbw rtbz; do
        f="$DEST/$stem.$ext"
        want=$WDL_MAGIC; [ "$ext" = rtbz ] && want=$DTZ_MAGIC

        if [ -s "$f" ] && [ "$(head -c4 "$f" | xxd -p)" = "$want" ]; then
            have=$((have+1)); continue
        fi

        curl -sfL --max-time 60 -o "$f.part" "$BASE/$stem.$ext" 2>/dev/null
        got=$(head -c4 "$f.part" 2>/dev/null | xxd -p)
        if [ "$got" = "$want" ]; then
            mv "$f.part" "$f"; have=$((have+1))
            printf "  ok       %-12s %6s bytes\n" "$stem.$ext" "$(stat -c%s "$f")"
        else
            rm -f "$f.part"
            printf "  BAD      %-12s magic=%s want=%s\n" "$stem.$ext" "${got:-none}" "$want"
            fail=$((fail+1))
        fi
    done
done

echo
if [ "$have" = "0" ]; then
    echo "tbfetch: SKIPPED -- no table could be fetched or verified" >&2
    exit 2
fi
echo "tbfetch: $have file(s) verified in $DEST, $fail rejected"
[ "$fail" = "0" ] || exit 1
exit 0
