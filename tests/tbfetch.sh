#!/bin/bash
# Fetch the 3-man Syzygy set, verifying each file by MAGIC rather than by status.
#
# A mirror that answers a missing file with a body -- an HTML error page, a 404
# with content, a redirect to a landing page -- would otherwise be stored as a
# table and fail much later inside the decoder, reported as a corrupt table
# rather than as a bad download. Both mirrors tried here do exactly that.
#
# The set is ten files and about 26 KiB, which is what makes it affordable to
# fetch in a fuzz job rather than commit.
#
# Exit codes:  0 present and verified   1 a file failed verification   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEST=${1:-$ROOT/tests/syzygy}
BASE=${TB_MIRROR:-http://tablebase.sesse.net/syzygy/3-4-5}

# The values the engine itself checks, at src/syzygy/tbprobe.cpp:323:
#   DTZ  D7 66 0C A5      WDL  71 E8 23 5D
WDL_MAGIC=71e8235d
DTZ_MAGIC=d7660ca5

command -v curl >/dev/null || { echo "tbfetch: SKIPPED -- no curl" >&2; exit 2; }
mkdir -p "$DEST"

fail=0
have=0
for stem in KQvK KRvK KPvK KNvK KBvK; do
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
