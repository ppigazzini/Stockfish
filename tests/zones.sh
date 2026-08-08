#!/bin/bash
# The three zones of src/, as name lists, shared by tests/depcheck.sh (which
# reads includes) and tests/linkcheck.sh (which reads symbols). One definition:
# two checks that disagreed about which file is engine would be worse than
# either alone.
#
# src/ is flat, so a zone is a NAME LIST rather than a directory. That is the
# weakness both checks inherit, and why each reports files belonging to no zone.

# Zones are DIRECTORIES now, not name lists. B7 moved src/ into engine/,
# platform/ and shell/, so a file's zone is its directory and a new file joins a
# zone by where it is put -- which is the whole point of the move. The unassigned
# check below is what catches a file added outside all three.
#
# incbin/ is vendored; universal/ holds the fat-binary entry shims, which are
# build scaffolding rather than engine, platform or shell code.

zone_of_path() {
    case "$1" in
        src/engine/*)    echo engine ;;
        src/platform/*)  echo platform ;;
        src/shell/*)     echo shell ;;
        src/incbin/*)    echo vendor ;;
        src/universal/*) echo vendor ;;
        *)               echo unassigned ;;
    esac
}

# Kept for callers that have only a basename (object files, nm output).
zone_of() {
    local stem=$1 f
    f=$(git ls-files "src/*/$stem.cpp" "src/*/$stem.h" "src/*/*/$stem.cpp" "src/*/*/$stem.h" \
        "src/*/*/*/$stem.cpp" "src/*/*/*/$stem.h" 2>/dev/null | head -1)
    [ -n "$f" ] && zone_of_path "$f" || echo unassigned
}
