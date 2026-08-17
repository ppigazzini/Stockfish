#!/bin/bash
# Citation hygiene for the untracked working area, __DEV/.
#
# WHAT THIS PROVES. Every commit SHA cited in __DEV/*.md names a commit that is
# an ANCESTOR OF HEAD, and every relative markdown link resolves. Nothing else.
#
# WHAT IT CANNOT SEE. Whether the commit a SHA names is the commit the sentence
# means. A remap that rewrites a citation to a reachable but WRONG commit passes
# this gate cleanly -- SPEEDUP.md records exactly that happening, to a table that
# then asserted a commit which IS an ancestor is not one.
#
# WHY EXISTENCE IS THE WRONG TEST, and it is the reason this script exists.
#
#     git cat-file -e "$sha^{commit}"        # WRONG
#
# That asks whether the object is in THIS clone. A branch that has been rebased
# leaves its pre-rebase commits in the object store, and backup refs
# (refish-backup-762dd1da, refish-pre-rebase-5062aee5, pre-squash) pin them
# indefinitely. So a citation to a pre-rebase identity resolves on the author's
# machine, forever, and resolves nowhere else. Two consecutive audits of this
# tree ran the existence test: the first could not size the problem, the second
# used it to RETRACT a correct finding. The reachability test is the one that
# answers the question, and SPEEDUP.md wrote it down before either of them:
#
#     git merge-base --is-ancestor "$sha" HEAD
#
# THREE TIERS, because two would report the wrong thing. A SHA that is reachable
# only from a tag is not necessarily a defect: perf-2026-08-11 and
# perf-2026-08-13 are sitting heads that are MEANT to be off-branch, and that is
# why they were tagged. So an off-branch SHA is a WARNING and only a SHA
# reachable from nothing at all is a finding -- the latter is one `git gc
# --prune` from unresolvable even here.
#
# THE DURABLE FIX IS NOT A REMAP. It is a subject beside every SHA:
#
#     `46944a92` "fix(shell): stop the search before the critical-error exit"
#
# The subject survives any rebase and is greppable; the SHA is a convenience.
# This gate prints the subject of everything it reports so the repair is a paste
# rather than an archaeology exercise.
#
# NO CI LANE, and the reason is not that nobody wired one. __DEV/ is gitignored
# (.gitignore:49) and a clone does not carry it, so a hosted runner has nothing
# to read. tests/lanecheck.sh carries the matching excuse. Run it by hand before
# quoting any figure out of __DEV/.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

INTERNAL='__DEV'

FAIL=0
note() { echo "devcite: $*"; FAIL=1; }
head_check() { echo; echo "== $* =="; }

[ -d "$INTERNAL" ] || { echo "devcite: SKIPPED -- no $INTERNAL/ in this tree" >&2; exit 2; }

shopt -s nullglob
PAGES=("$INTERNAL"/*.md)
shopt -u nullglob
[ ${#PAGES[@]} -gt 0 ] || { echo "devcite: SKIPPED -- no pages in $INTERNAL/" >&2; exit 2; }

git rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "devcite: SKIPPED -- not a git repository" >&2; exit 2; }

echo "devcite: ${#PAGES[@]} pages under $INTERNAL/, HEAD $(git rev-parse --short HEAD)"

# ------------------------------------------------------- 1. SHA reachability

head_check "1. every cited SHA is an ancestor of HEAD"

# Backticked hex of 7..12 digits. The lower bound is git's own abbreviation
# floor; the upper stops short of 40 so that full-length net hashes and the
# sibling ports' SHAs are not swept in. Anything matching that is still not
# necessarily a commit -- node counts (2884956) and net hashes match it too --
# so the FIRST filter is "is this a commit at all", and a non-commit is silently
# skipped rather than reported. A gate that reports 2884956 as a dangling
# citation is a gate nobody runs twice.
on=0 offbranch=0 dangling=0 notcommit=0

for p in "${PAGES[@]}"; do
    page_reported=0
    while read -r s; do
        [ -n "$s" ] || continue
        if ! git cat-file -e "${s}^{commit}" 2>/dev/null; then
            notcommit=$((notcommit + 1)); continue
        fi
        if git merge-base --is-ancestor "$s" HEAD 2>/dev/null; then
            on=$((on + 1)); continue
        fi

        subj=$(git log -1 --format=%s "$s" 2>/dev/null)
        refs=$(git for-each-ref --contains "$s" --format='%(refname:short)' 2>/dev/null \
               | tr '\n' ' ' | sed 's/ *$//')

        [ "$page_reported" = 0 ] && { echo "  $p"; page_reported=1; }

        if [ -n "$refs" ]; then
            offbranch=$((offbranch + 1))
            echo "    warn  $s  off-branch, held by: $refs"
            echo "          $subj"
        else
            dangling=$((dangling + 1))
            echo "    FAIL  $s  reachable from NO ref -- one gc --prune from gone"
            echo "          $subj"
        fi
    done < <(grep -ohE '`[0-9a-f]{7,12}`' "$p" | tr -d '`' | sort -u)
done

total=$((on + offbranch + dangling + notcommit))
echo
echo "  on branch    $on"
echo "  off-branch   $offbranch  (warning: resolves here, nowhere else)"
echo "  dangling     $dangling"
echo "  not a commit $notcommit  (node counts, net hashes, sibling-port SHAs)"
echo "  total        $total"

# NOT a failure on its own, and the reasoning matters. A rebase already happened;
# those commits are gone and no edit brings them back. The repairable condition
# is whether the citation still MEANS something without its SHA, which is check
# 2. A dangling SHA carrying its subject is as good as a citation to a rewritten
# history can be; a dangling SHA alone is unrecoverable information. Failing here
# too would make the gate permanently red on a state nobody can fix, and a gate
# that cannot reach zero is a gate that gets ignored at zero+1.
[ "$dangling" -gt 0 ] && echo "  ($dangling dangling -- not a failure here; check 2 owns the repair)"

# The warning tier does not fail, and saying why is load-bearing: a tagged
# sitting head is SUPPOSED to be off-branch. But a warning nobody reads is the
# shape an excuse list rots into, so a run where the off-branch tier exceeds the
# on-branch tier is reported as a finding of its own -- at that ratio the
# citations are describing a tree that no longer exists.
if [ "$offbranch" -gt "$on" ]; then
    note "more citations are off-branch ($offbranch) than on it ($on)"
fi

# ------------------------------------------------------- 2. subject annotation

head_check "2. every off-branch SHA carries its subject"

# The repair for tier 2 and 3 is not a remap -- SPEEDUP.md records a remapper
# rewriting a before/after pair into two identical values. It is a subject
# beside the SHA, which no rebase can invalidate. So once a citation is known
# rebase-fragile, this asks whether the durable half is present: a quoted string
# on the same line.
missing=0
for p in "${PAGES[@]}"; do
    while read -r s; do
        [ -n "$s" ] || continue
        git cat-file -e "${s}^{commit}" 2>/dev/null || continue
        git merge-base --is-ancestor "$s" HEAD 2>/dev/null && continue
        # Off-branch or dangling. Does at least one line citing it also carry a
        # quoted subject? A bare `*` would match every bold line in the file, so
        # the test is a DOUBLE-QUOTED run of at least ten characters -- long
        # enough that a stray quoted word cannot satisfy it and short enough to
        # accept a terse subject.
        if ! grep -F -- "\`$s\`" "$p" | grep -qE '"[^"]{10,}"'; then
            echo "  $p  $s  cited with no subject beside it"
            missing=$((missing + 1))
        fi
    done < <(grep -ohE '`[0-9a-f]{7,12}`' "$p" | tr -d '`' | sort -u)
done
[ "$missing" = 0 ] && echo "  every rebase-fragile citation carries a subject"
[ "$missing" -gt 0 ] && note "$missing rebase-fragile citation(s) carry no subject"

# ------------------------------------------------------------- 3. dead links

head_check "3. every relative markdown link resolves"

dead=0
for p in "${PAGES[@]}"; do
    d=$(dirname "$p")
    while read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
            http://*|https://*|mailto:*|'#'*) continue ;;
        esac
        t=${t%%#*}
        [ -n "$t" ] || continue
        # `Type::operator[](int)` in an inline code span is indistinguishable
        # from a link by the pattern above -- both are ](...). Require the
        # target to look like a path, which every real link here does and no
        # C++ signature does. A link to an extensionless file in the same
        # directory would be missed; none exists and one would be a bad idea.
        case "$t" in
            */*|*.*) ;;
            *) continue ;;
        esac
        [ -e "$d/$t" ] || [ -e "$t" ] || { echo "  $p -> $t"; dead=$((dead + 1)); }
    done < <(grep -ohE '\]\([^)]+\)' "$p" | sed 's/^](//; s/)$//')
done
[ "$dead" = 0 ] && echo "  all links resolve"
[ "$dead" -gt 0 ] && note "$dead dead link(s)"

# -------------------------------------------------------------- 4. placeholders

head_check "4. no citation placeholders left behind"

# A literal SHA-shaped placeholder announces itself and is therefore the EASY
# half of this gate's subject -- but it is also the half a human writing a table
# row in one sitting actually produces, so it is worth one grep.
#
# Only inside a BACKTICKED span and only OUTSIDE a fenced code block. Both
# exclusions are load-bearing and both were found by running this gate on this
# tree: a page quoting another page's grep output reproduces the placeholder
# faithfully inside a fence, and a page discussing the placeholder in prose
# names it without backticks. Neither is a citation, and a gate that reports
# its own audit trail is one nobody keeps.
ph=0
for p in "${PAGES[@]}"; do
    while IFS=: read -r ln text; do
        [ -n "$ln" ] || continue
        echo "  $p:$ln  $(echo "$text" | sed 's/^ *//' | cut -c1-100)"
        ph=$((ph + 1))
    done < <(awk '/^[[:space:]]*```/ {f = !f; next} !f' "$p" \
             | grep -nE '`(SHA|TODO|FIXME|XXX)[A-Z0-9_-]*`')
done
[ "$ph" = 0 ] && echo "  none"
[ "$ph" -gt 0 ] && note "$ph citation placeholder(s)"

# -------------------------------------------------------- 5. fence balance

head_check "5. every fenced code block is closed"

# An odd number of ``` markers means one block never closes, and from that point
# the rest of the file is inside a code block as far as any tool is concerned.
# That is worth a check of its own rather than a footnote, because of HOW it was
# found: check 1 reported five citations in this tree as unannotated after a
# repair pass had annotated 159, and the reason was that the repair skipped
# fenced blocks and half the file looked fenced. **An unbalanced fence silently
# disables every other line-oriented check downstream of it**, including this
# gate's own.
#
# On this tree it also turned out not to be a formatting slip. The unmatched
# opener in Stockfish-bugs.md was a TEXT SPLICE -- a blockquote line welded to
# the middle of a shell reproducer, with the opening fence and part of the
# command gone. So this check's real subject is content loss, and a page that
# reports which line opened the unclosed block is pointing at it.
unbal=0
for p in "${PAGES[@]}"; do
    n=$(grep -cE '^[[:space:]]*```' "$p")
    [ $((n % 2)) -eq 0 ] && continue
    # Name the opener. A block containing a markdown heading cannot be code, so
    # the first such mis-paired block locates the damage.
    where=$(awk '
        /^[[:space:]]*```/ { if (op == 0) { op = NR; next } else { op = 0; next } }
        op && /^#{2,3} / && !found { print op; found = 1 }
    ' "$p")
    echo "  $p  $n fence markers (odd)${where:+ -- unmatched opener at or before line $where}"
    unbal=$((unbal + 1))
done
[ "$unbal" = 0 ] && echo "  all balanced"
[ "$unbal" -gt 0 ] && note "$unbal page(s) with an unclosed code fence"

echo
[ "$FAIL" = 0 ] && echo "devcite: clean" || echo "devcite: findings above"
exit "$FAIL"
