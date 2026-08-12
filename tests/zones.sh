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
# REFUSE AN AMBIGUOUS STEM rather than resolving it. Taking the first match would
# classify two same-named files in two zones as whichever git lists first, and
# every caller here would then misclassify the survivor the SAME wrong way --
# which is the outcome the one-definition rule at the top of this file exists to
# prevent, arriving through the resolver instead of through a second copy.
#
# The build breaks first, and more quietly: `OBJS = $(notdir $(SRCS:.cpp=.o))` in
# src/Makefile flattens every object into one name space and VPATH is a flat
# search path, so two sources with one stem compete for one object and one of them
# is never compiled -- while tests/buildcoverage.sh stays green, because both
# files ARE named by SRCS and that is all it asks. That half is asserted there.
#
# `ambiguous` is a third answer, distinct from `unassigned`. A caller that treats
# an unknown answer as "not my zone" would silently exempt the file, so both
# callers must report it rather than skip it.
zone_of() {
    local stem=$1 matches n
    matches=$(git ls-files "src/*/$stem.cpp" "src/*/$stem.h" "src/*/*/$stem.cpp" "src/*/*/$stem.h" \
        "src/*/*/*/$stem.cpp" "src/*/*/*/$stem.h" 2>/dev/null \
        | while IFS= read -r f; do zone_of_path "$f"; done | sort -u)
    n=$(printf '%s\n' "$matches" | grep -c .)
    case "$n" in
        0) echo unassigned ;;
        1) printf '%s\n' "$matches" ;;
        *) echo ambiguous ;;
    esac
}
