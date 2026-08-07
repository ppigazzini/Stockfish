#!/bin/bash
# Per-symbol machine-code equivalence between two revisions, LTO disabled.
#
# The strongest evidence a pure code-motion refactor can carry: not a benchmark
# with a noise floor, but a proof that the compiler emitted the same
# instructions. One run settles a whole class of change that would otherwise
# need a measurement.
#
# WHAT IT PROVES, AND WHAT IT DOES NOT
#
#   Proves: with LTO off, at this arch and compiler, every function in the
#   binary compiles to the same instruction sequence. Moving a definition
#   between files, splitting a header, or reordering members did not change
#   what the compiler produced.
#
#   Does NOT prove the shipped build is unchanged. Stockfish links with
#   -flto=full (clang) or -flto -flto-partition=one (gcc) by default, and LTO is
#   exactly where a moved function changes an inlining decision. A green run
#   here narrows what tests/perfbudget.sh has to catch; it does not replace it.
#
#   Quote both halves. A check whose limits are unstated will be quoted past
#   them.
#
#   Known false positive: GCC renumbers its .isra/.constprop/.part/.cold clones,
#   so an unrelated edit can make a symbol appear on one side only while being
#   the same code. A DIFFERS report counts that class separately.
#
# Why LTO has to be off rather than worked around: with LTO the per-TU objects
# hold IR, not machine code, so there is nothing to disassemble until the link,
# and the linked image renumbers every address when a translation unit moves.
#
# Exit codes:  0 identical   1 differs   2 skipped (could not build or compare)

set -u
set -o pipefail

ARCH=x86-64-avx2
COMP=gcc
KEEP=0
JOBS=$(nproc 2>/dev/null || echo 4)

SRC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)

usage() {
    cat <<EOF
Usage: $0 [options] <base-rev> [<head-rev>]

  <base-rev>   git revision to compare against
  <head-rev>   git revision to compare; default HEAD.
               The literal 'worktree' compares the current working tree.

Options:
  --arch ARCH   build architecture (default: $ARCH)
  --comp COMP   compiler, gcc or clang (default: $COMP)
  --jobs N      parallel build jobs (default: $JOBS)
  --keep        keep the build directories and the normalised listings
  -h, --help    this text
EOF
}

cleanup() {
    [ "$KEEP" = "1" ] && { echo "kept: $WORK"; return; }
    for d in "$WORK"/*/; do
        [ -e "$d/.git" ] && git -C "$SRC_ROOT" worktree remove --force "$d" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

die()  { echo "textequal: $*" >&2; exit 1; }
skip() { echo "textequal: SKIPPED -- $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH=$2; shift 2 ;;
        --comp) COMP=$2; shift 2 ;;
        --jobs) JOBS=$2; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done

[ $# -ge 1 ] || { usage >&2; exit 1; }
BASE_REV=$1
HEAD_REV=${2:-HEAD}


# A numeric option that is not a number is a silently wrong verdict, and a
# tolerance nobody bounds is the "raise it until the change fits" failure this
# gate exists to prevent.
num() {
    case "$2" in
        ''|*[!0-9.]*|*.*.*) die "$1 must be a number, got '$2'" ;;
    esac
}
num --jobs "$JOBS"

command -v objdump >/dev/null || skip "objdump is not installed"

prepare_tree() {
    local rev=$1 dir=$2
    if [ "$rev" = "worktree" ]; then
        mkdir -p "$dir"
        tar -C "$SRC_ROOT" -cf - \
            --exclude='.git' --exclude='src/stockfish*' --exclude='*.o' \
            --exclude='*.nnue' --exclude='src/.depend' src tests scripts \
            2>/dev/null | tar -C "$dir" -xf - || die "could not copy the working tree"
    else
        git -C "$SRC_ROOT" rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
            || die "not a revision: $rev"
        git -C "$SRC_ROOT" worktree add --detach --quiet "$dir" "$rev" \
            || die "could not create a worktree for $rev"
    fi
    local n found=0
    for n in "$SRC_ROOT"/src/*.nnue; do
        [ -e "$n" ] || continue
        ln -sf "$n" "$dir/src/$(basename "$n")" && found=1
    done
    [ "$found" = "1" ] || skip "no .nnue in $SRC_ROOT/src -- run 'make net' there first"
}

# The build stamp is neutralised on BOTH sides. `misc.o` is compiled with
# -DGIT_SHA=<sha> -DGIT_DATE=<date> -DGIT_DIFFINDEX=<n>, so two revisions embed
# different version strings -- which is not a codegen difference but shifts
# every rodata offset after it, and therefore every rip-relative displacement in
# the whole binary. Worse, an empty GIT_SHA compiles a DIFFERENT branch of
# engine_version_info, so a `worktree` side (no .git) and a revision side were
# not even compiling the same code.
#
# Forcing all three empty on both sides makes the stamp identical and the
# comparison about the code. It is why this gate must never be used to argue
# that the SHIPPED binary is unchanged: the shipped binary carries its stamp.
build_nolto() {
    local dir=$1 label=$2
    echo "  building $label (LTO off, build stamp neutralised) ..." >&2
    ( cd "$dir/src" && make -j"$JOBS" build ARCH="$ARCH" COMP="$COMP" \
        GIT_SHA= GIT_DATE= GIT_DIFFINDEX= \
        EXTRACXXFLAGS=-fno-lto EXTRALDFLAGS=-fno-lto ) > "$dir/build.log" 2>&1 \
        || { tail -25 "$dir/build.log" >&2; die "$label failed to build"; }
    [ -x "$dir/src/stockfish" ] || die "$label produced no binary"
}

# Normalise a disassembly so that only the INSTRUCTIONS remain comparable:
#
#   - drop the instruction address at the start of each line;
#   - drop objdump's trailing "# <addr> <sym+off>" annotation, which restates an
#     absolute address;
#   - rewrite an absolute branch/call target to its symbol alone, so a callee
#     that moved does not diff every one of its call sites;
#   - key each instruction by its enclosing symbol and its position within that
#     symbol, then sort by that key. Order WITHIN a function is preserved and
#     compared; order BETWEEN functions is not, because a link-order change is
#     not a codegen change.
# Symbols are NOT demangled. A demangled C++ name contains spaces, commas and
# angle brackets, which breaks both the field split below and the sort key --
# and two template instantiations can demangle to the same string while being
# distinct symbols, which would silently merge two functions' bodies.
#
# `\b` is not a word boundary in awk (POSIX ERE has no such escape; awk reads it
# as a backspace), so the address-stripping pattern is written out explicitly.
# The first version of this function used `\b` and matched nothing at all --
# every call target kept its absolute address and the gate could never have
# reported IDENTICAL for anything that moved.
normalise() {
    local bin=$1 out=$2
    objdump -d --no-show-raw-insn "$bin" \
    | awk '
        /^[0-9a-f]+ </ {
            s = index($0, "<")
            sym = substr($0, s + 1, length($0) - s - 2)   # drop "<" and ">:"
            n = 0; next
        }
        /^[ \t]*[0-9a-f]+:/ {
            sub(/^[ \t]*[0-9a-f]+:[ \t]*/, "")      # leading address

            # objdump names the target of a rip-relative access in the trailing
            # "# <addr> <sym>" comment. Move that NAME into the operand and drop
            # the numeric displacement: the displacement is a layout fact, not a
            # codegen fact, and one shifted string constant moves every one of
            # them in the binary. Not doing this made the gate report DIFFERS
            # for a byte-identical source tree.
            target = ""
            h = index($0, "#")
            if (h > 0) {
                c  = substr($0, h)
                lt = index(c, "<")
                gt = index(c, ">")
                if (lt > 0 && gt > lt) target = substr(c, lt, gt - lt + 1)
                $0 = substr($0, 1, h - 1)
            }
            if (target == "") target = "<?>"
            gsub(/0x[0-9a-f]+\(%rip\)/, target "(%rip)")

            gsub(/[0-9a-f]+[ \t]+</, "<")           # absolute target -> symbol
            gsub(/\+0x[0-9a-f]+>/, ">")             # symbol+offset -> symbol
            sub(/[ \t]+$/, "")
            if (length($0) == 0) next
            printf "%s\t%08d\t%s\n", sym, n++, $0
        }
    ' | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 > "$out"
    [ -s "$out" ] || die "objdump produced no instructions for $bin"
}

echo "textequal: arch=$ARCH comp=$COMP (LTO disabled)"
echo "textequal: base=$BASE_REV head=$HEAD_REV"

prepare_tree "$BASE_REV" "$WORK/base"
prepare_tree "$HEAD_REV" "$WORK/head"
build_nolto  "$WORK/base" base
build_nolto  "$WORK/head" head

normalise "$WORK/base/src/stockfish" "$WORK/base.txt"
normalise "$WORK/head/src/stockfish" "$WORK/head.txt"

B_INSN=$(wc -l < "$WORK/base.txt")
H_INSN=$(wc -l < "$WORK/head.txt")
B_SYM=$(cut -f1 "$WORK/base.txt" | uniq | wc -l)
H_SYM=$(cut -f1 "$WORK/head.txt" | uniq | wc -l)

echo
printf '%-10s %14s %10s\n' "" "instructions" "symbols"
printf '%-10s %14s %10s\n' "base" "$B_INSN" "$B_SYM"
printf '%-10s %14s %10s\n' "head" "$H_INSN" "$H_SYM"
echo

if diff -q "$WORK/base.txt" "$WORK/head.txt" > /dev/null; then
    echo "textequal: IDENTICAL -- $B_INSN instructions across $B_SYM symbols"
    echo "  This is a codegen-equivalence proof for the LTO-off build at $ARCH/$COMP."
    echo "  It does NOT prove the shipped -flto build is unchanged; run"
    echo "  tests/perfbudget.sh for that."
    exit 0
fi

echo "textequal: DIFFERS"
echo

# GCC numbers its clones -- .isra.0, .constprop.1, .part.0 -- and an unrelated
# edit can RENUMBER them, so a symbol can appear on one side only while being
# the same code. This binary carries 181 such symbols, so the effect is not
# marginal. The count below separates that class from a genuine difference; it
# is reported rather than normalised away, because collapsing the index would
# also merge two distinct clones of one function.
b_only=$(comm -23 <(cut -f1 "$WORK/base.txt" | uniq) <(cut -f1 "$WORK/head.txt" | uniq))
h_only=$(comm -13 <(cut -f1 "$WORK/base.txt" | uniq) <(cut -f1 "$WORK/head.txt" | uniq))
strip_clone() { sed -E 's/\.(isra|constprop|part|cold)\.[0-9]+$/.\1/'; }
renumbered=$(comm -12 <(printf '%s\n' "$b_only" | strip_clone | sort -u) \
                      <(printf '%s\n' "$h_only" | strip_clone | sort -u) | wc -l)
if [ "$renumbered" -gt 0 ]; then
    echo "note: $renumbered symbol name(s) differ only by a compiler clone index"
    echo "  (.isra/.constprop/.part/.cold renumbering, not a codegen change)"
    echo
fi
echo "symbols only in base:"
comm -23 <(cut -f1 "$WORK/base.txt" | uniq) <(cut -f1 "$WORK/head.txt" | uniq) | head -20
echo "symbols only in head:"
comm -13 <(cut -f1 "$WORK/base.txt" | uniq) <(cut -f1 "$WORK/head.txt" | uniq) | head -20
echo
echo "symbols whose body changed (first 20):"
comm -12 <(cut -f1 "$WORK/base.txt" | uniq) <(cut -f1 "$WORK/head.txt" | uniq) \
| while read -r s; do
    if ! diff -q <(awk -F'\t' -v s="$s" '$1==s' "$WORK/base.txt") \
                 <(awk -F'\t' -v s="$s" '$1==s' "$WORK/head.txt") > /dev/null; then
        echo "  $s"
    fi
done | head -20
echo
echo "  A difference is not automatically a defect -- it means this change is not"
echo "  pure code motion, so it needs tests/perfbudget.sh rather than this gate."
exit 1
