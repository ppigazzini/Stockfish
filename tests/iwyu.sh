#!/bin/bash
# The include lane, runnable off a hosted runner -- and honest about when it is
# not the lane.
#
# .github/workflows/iwyu.yml used to carry its whole invocation inline, so the
# only way to run it locally was to retype it. Retyped, it does not work: this
# is the second time a local reconstruction reported something the lane would
# not, and the first time cost a commit message that claimed a green lane it had
# not seen.
#
# TWO MODES, AND THEY DO NOT PROVE THE SAME THING
#
#   native -- clang finds libc++ on its own search path, which is what a runner
#   with libc++-17-dev installed looks like. IWYU detects libc++, auto-loads its
#   own libcxx.imp, and the flags are exactly the workflow's. A finding is a
#   finding: this mode returns an ABSOLUTE verdict.
#
#   shim -- there is no libc++ package and the only one available is the copy
#   under resources/iwyu/llvm, reached with -nostdinc++ -isystem. Two things
#   then break. IWYU needs -resource-dir or clang rejects libc++'s own headers
#   with "reference to unresolved using declaration"; and -stdlib=libc++ becomes
#   an unused argument, so IWYU stops detecting libc++ and its default mapping
#   has to be passed by hand. The rig runs, but it reports findings the lane does
#   not -- on this tree, fourteen <sstream>/<fstream> removals in files nobody
#   had touched. So this mode returns a DIFFERENTIAL only: base and head through
#   one rig, finding sets compared. Asked for an absolute verdict it SKIPS,
#   because the alternative is a green that means nothing.
#
# The mode is printed on every run. A report that does not say which mode
# produced it is not a report.
#
# THREE TIERS by default, because the include set of a file holding #if is a
# property of the tier and not of the file: the generic scalar path, the AVX2
# path, and the AVX-512 one. attacks.cpp needs prng.h in the first and not in
# the other two, and one tier alone would have missed it.
#
# WHAT NEITHER MODE CAN SEE: a use behind another host's #ifdef. Three includes
# on this tree are needed only under _WIN32 or under a packager knob, and all
# three read as unused here. They carry `// IWYU pragma: keep` and a reason.
# Adding a finding to that list is a decision to make by reading, not by
# deleting what the tool named.
#
# Exit codes:  0 clean (or no new findings)   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)

ARCHES=(x86-64 x86-64-avx2 x86-64-avx512icl)
ARCHES_SET=0
BASE_REV=
HEAD_REV=worktree
KEEP=0
JOBS=$(nproc 2>/dev/null || echo 4)

usage() {
    cat <<EOF
Usage: $0 [options] [<base-rev>]

  <base-rev>   compare the findings against this revision instead of judging
               them absolutely. Required in shim mode, where an absolute
               verdict is not available; optional in native mode, where it
               narrows a red run to what the head actually added.

Options:
  --arch ARCH   analyse this tier only; repeatable (default: ${ARCHES[*]})
  --head REV    revision to analyse (default: worktree)
  --iwyu PATH   the include-what-you-use binary
  --jobs N      parallel jobs (default: $JOBS)
  --keep        keep the work directory and the finding sets
  -h, --help    this text

Examples:
  $0                     # native mode: is the tree clean?
  $0 HEAD~1              # what did this commit add?
  $0 --arch x86-64-avx2 HEAD~1
EOF
}

cleanup() {
    [ "$KEEP" = "1" ] && { echo "kept: $WORK"; return; }
    for d in "$WORK"/*/; do
        [ -e "$d/.git" ] && git -C "$ROOT" worktree remove --force "$d" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

die()  { echo "iwyu: $*" >&2; exit 1; }
skip() { echo "iwyu: SKIPPED -- $*" >&2; exit 2; }

IWYU=${IWYU:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) [ "$ARCHES_SET" = 1 ] || ARCHES=(); ARCHES_SET=1; ARCHES+=("$2"); shift 2 ;;
        --head) HEAD_REV=$2; shift 2 ;;
        --iwyu) IWYU=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done

[ $# -le 1 ] || { usage >&2; exit 1; }
[ $# -eq 1 ] && BASE_REV=$1

case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a number, got '$JOBS'" ;; esac

# ---------------------------------------------------------------- locate IWYU

if [ -z "$IWYU" ]; then
    if [ -x "$ROOT/resources/iwyu/install/bin/include-what-you-use" ]; then
        IWYU=$ROOT/resources/iwyu/install/bin/include-what-you-use
    elif command -v include-what-you-use >/dev/null; then
        IWYU=$(command -v include-what-you-use)
    else
        skip "include-what-you-use is not installed; resources/iwyu-setup.sh builds it"
    fi
fi
[ -x "$IWYU" ] || skip "not executable: $IWYU"

IWYU_VER=$("$IWYU" --version 2>&1 | head -1)

# --------------------------------------------------------------- pick the mode
#
# The probe compiles a translation unit that includes a libc++ header, with the
# workflow's own flags and nothing else. If that works, the runner looks like
# CI's and the workflow's flags are the right ones. Probing by asking whether a
# package is installed would answer a different question -- one that is true on
# a host whose libc++ does not match IWYU's clang, which fails later and looks
# like a finding.

MAPPING=$ROOT/.github/ci/libcxx17.imp
[ -f "$MAPPING" ] || skip "no mapping file at $MAPPING"

STD_FLAGS=(-stdlib=libc++ -Xiwyu --comment_style=long -Xiwyu "--mapping=$MAPPING")
CI_FLAGS=("${STD_FLAGS[@]}" -Xiwyu --error)

probe=$WORK/probe.cpp
printf '#include <string>\nstd::string f() { return std::string("x"); }\n' > "$probe"

# The probe asks ONE question: does a unit that includes a libc++ header
# compile? It is judged on whether the frontend errored and never on the exit
# code, and it is run WITHOUT -Xiwyu --error.
#
# The first version got both wrong and inverted the mode on every host. With
# --error, IWYU exits non-zero for a finding in the PROBE FILE -- the probe had
# one -- so the native check failed on a host where native was correct, the shim
# check then passed or failed on the unrelated question of whether the shim's
# extra mapping happened to cover the probe's own includes, and a runner with
# libc++ installed took the skip path and reported "neither libc++ compiles a
# trivial unit" while holding a working libc++.
probe_ok() {
    "$IWYU" "${STD_FLAGS[@]}" "$@" -std=c++17 -fsyntax-only "$probe" >"$WORK/probe.log" 2>&1
    ! grep -qE '(^|[[:space:]])(fatal )?error:' "$WORK/probe.log"
}

MODE=
if probe_ok; then
    MODE=native
    SHIM=()
else
    # No usable libc++ on the default path. Fall back to the pinned tree, which
    # is the same 17.0.6 IWYU itself was built against.
    LLVM=$ROOT/resources/iwyu/llvm
    RESDIR=$LLVM/lib/clang/17
    CXXV1=$LLVM/include/c++/v1
    TGTV1=$LLVM/include/x86_64-unknown-linux-gnu/c++/v1
    DEFMAP=$(dirname "$IWYU")/../share/include-what-you-use/libcxx.imp
    for p in "$RESDIR" "$CXXV1" "$TGTV1" "$DEFMAP"; do
        [ -e "$p" ] || skip "no libc++ on the default path and none pinned ($p is missing)"
    done
    SHIM=(-resource-dir="$RESDIR" -nostdinc++ -isystem "$TGTV1" -isystem "$CXXV1"
          -Xiwyu "--mapping=$DEFMAP")
    if ! probe_ok "${SHIM[@]}"; then
        tail -15 "$WORK/probe.log" >&2
        skip "neither the default libc++ nor the pinned one compiles a trivial unit"
    fi
    MODE=shim
fi

echo "iwyu: $IWYU_VER"
echo "iwyu: mode=$MODE  tiers=${ARCHES[*]}"

if [ "$MODE" = shim ] && [ -z "$BASE_REV" ]; then
    cat >&2 <<'EOF'
iwyu: SKIPPED -- shim mode gives no absolute verdict, and no base revision was
      given to compare against. This host has no libc++ on the default search
      path, so the rig reports findings the lane does not; it reports the same
      ones at every revision, which is why a differential still works and an
      absolute answer does not. Re-run as:  tests/iwyu.sh <base-rev>
EOF
    exit 2
fi

# ------------------------------------------------------------------- the trees

prepare_tree() {
    local rev=$1 dir=$2
    if [ "$rev" = "worktree" ]; then
        mkdir -p "$dir"
        tar -C "$ROOT" -cf - \
            --exclude='.git' --exclude='src/stockfish*' --exclude='*.o' \
            --exclude='*.nnue' --exclude='src/.depend' src tests scripts .github \
            2>/dev/null | tar -C "$dir" -xf - || die "could not copy the working tree"
    else
        git -C "$ROOT" rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
            || die "not a revision: $rev"
        git -C "$ROOT" worktree add --detach --quiet "$dir" "$rev" \
            || die "could not create a worktree for $rev"
    fi
    # Analysing in a copy rather than in src/ is not tidiness. `make analyze`
    # depends on objclean, so running it where the developer builds destroys
    # the objects they had and leaves no binary for signature.sh.
    # The net is linked in when there is one, and NOT skipped for when there is
    # not: `analyze` depends on `net`, so a fresh checkout fetches it into the
    # copy. Skipping here instead would turn a first run on a clean runner into
    # a silent pass -- the exact failure this gate exists to stop being possible.
    local n
    for n in "$ROOT"/src/*.nnue; do
        [ -e "$n" ] || continue
        ln -sf "$n" "$dir/src/$(basename "$n")"
    done
}

# One finding per line: "<file> <+|-> <include>", sorted and deduplicated, with
# IWYU's trailing "// for ..." annotation and any absolute path stripped. The
# annotation names the symbol that motivated the include, which changes when an
# unrelated overload does, and an absolute path differs between the two trees
# by construction -- neither is part of the finding.
extract() {
    awk -v root="$1" '
        /should add these lines:$/    { f=$0; sub(/ should.*/,"",f); act="+"; next }
        /should remove these lines:$/ { f=$0; sub(/ should.*/,"",f); act="-"; next }
        /^The full include-list/      { f=""; next }
        f && NF {
            line=$0
            sub(/^- /,"",line)
            sub(/[ \t]*\/\/.*$/,"",line)
            gsub(root"/","",line)
            gsub(/[ \t]+$/,"",line)
            if (line != "") print f" "act" "line
        }
    ' | sort -u
}

analyse() {
    local dir=$1 label=$2 out=$3
    : > "$out"
    local arch rc log
    for arch in "${ARCHES[@]}"; do
        echo "  analysing $label at $arch ..." >&2
        log=$dir/iwyu-$arch.log
        ( cd "$dir/src" && make -k -j"$JOBS" analyze \
            ARCH="$arch" COMP=clang CXX="$IWYU" \
            EXTRACXXFLAGS="${CI_FLAGS[*]} ${SHIM[*]-}" ) > "$log" 2>&1
        rc=$?
        # A tier that could not even compile is not a tier with no findings.
        # IWYU exits non-zero for BOTH "I have findings" (--error) and "this
        # did not parse", and the difference is the whole verdict.
        if grep -q 'fatal error:' "$log"; then
            tail -20 "$log" >&2
            die "$label did not compile at $arch"
        fi
        # A tier that analysed nothing is not a tier with no findings, and the
        # two are indistinguishable downstream: both contribute zero lines and
        # read as clean. IWYU prints one "The full include-list for" per file it
        # analysed, so requiring at least one turns a make that died for a
        # reason other than a compile error -- a net that would not download, a
        # target that does not exist -- into a red run instead of a green one.
        if ! grep -q '^The full include-list for' "$log"; then
            tail -20 "$log" >&2
            die "$label analysed no files at $arch (exit $rc)"
        fi
        [ "$rc" = 0 ] || true
        extract "$dir" < "$log" | sed "s|^|$arch |" >> "$out"
    done
    sort -u -o "$out" "$out"
}

prepare_tree "$HEAD_REV" "$WORK/head"
analyse "$WORK/head" head "$WORK/head.set"

if [ -z "$BASE_REV" ]; then
    n=$(grep -c . "$WORK/head.set" || true)
    if [ "$n" = 0 ]; then
        echo "iwyu: clean -- 0 findings across ${#ARCHES[@]} tier(s)"
        exit 0
    fi
    echo
    sed 's/^/  /' "$WORK/head.set"
    echo
    echo "iwyu: $n finding(s). A finding needed only behind another host's #ifdef"
    echo "      takes a '// IWYU pragma: keep' and a reason, not a deletion."
    exit 1
fi

prepare_tree "$BASE_REV" "$WORK/base"
analyse "$WORK/base" base "$WORK/base.set"

NEW=$(comm -23 "$WORK/head.set" "$WORK/base.set")
GONE=$(comm -13 "$WORK/head.set" "$WORK/base.set")
nb=$(grep -c . "$WORK/base.set" || true)
nh=$(grep -c . "$WORK/head.set" || true)

echo
printf '%-8s %s\n' base "$nb finding(s)   ($BASE_REV)"
printf '%-8s %s\n' head "$nh finding(s)   ($HEAD_REV)"
echo

[ -n "$GONE" ] && { echo "fixed by head:"; printf '%s\n' "$GONE" | sed 's/^/  - /'; echo; }

if [ -n "$NEW" ]; then
    echo "added by head:"
    printf '%s\n' "$NEW" | sed 's/^/  + /'
    echo
    echo "iwyu: $(printf '%s\n' "$NEW" | grep -c .) new finding(s)"
    exit 1
fi

if [ "$MODE" = shim ]; then
    echo "iwyu: no new findings -- head and base report the same $nb, so the change adds"
    echo "      nothing at any tier. This is NOT a green lane: $nb findings are the rig,"
    echo "      not the tree, and only CI's native mode can tell them apart."
else
    echo "iwyu: no new findings"
fi
exit 0
