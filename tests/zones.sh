#!/bin/bash
# The three zones of src/, sourced by every gate that has to ask which zone a
# file or an object belongs to: tests/depcheck.sh (which reads includes),
# tests/linkcheck.sh (which reads symbols), and tests/enginelink.sh and
# tests/fuzzsearch.sh (which select the engine objects to link). ONE definition:
# checks that disagreed about which file is engine would be worse than any of
# them alone.
#
# A zone is a DIRECTORY under src/, so a file joins a zone by where it is put and
# a file added outside all three joins none. Both callers must therefore report
# `unassigned` rather than skip it, or a new file is silently exempt from both.
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

# For callers holding only a basename (object files, nm output): resolve the
# stem to a tracked path first, because a bare name carries no zone.
zone_of() {
    local stem=$1 f
    f=$(git ls-files "src/*/$stem.cpp" "src/*/$stem.h" "src/*/*/$stem.cpp" "src/*/*/$stem.h" \
        "src/*/*/*/$stem.cpp" "src/*/*/*/$stem.h" 2>/dev/null | head -1)
    [ -n "$f" ] && zone_of_path "$f" || echo unassigned
}
