#!/bin/bash
# Lint the shell the gates are written in.
#
# WHAT THIS PROVES. Every shell script this branch wrote or edited is free of
# the defect classes shellcheck knows, at the `style` severity, with every
# suppression carrying a written reason. Nothing else.
#
# WHAT IT CANNOT SEE. Whether a gate checks the thing it claims to. shellcheck
# reads syntax and idiom; `negative_control.sh` is what proves a gate can fail,
# and the two are not substitutes. A script can be shellcheck-clean and assert
# nothing.
#
# WHY IT EXISTS. 8,446 lines of hand-written bash decide every claim this branch
# makes, and until this landed no tool had read them. The pre-commit config
# lints, formats and type-checks the Python; the language the gates are actually
# written in had nothing. `lanecheck.sh:78` already names the failure mode for a
# different case -- "the hole gets laundered into a pass" -- and an unread gate
# script is that one level down.
#
# SCOPE IS BY AUTHORSHIP, NOT BY DIRECTORY, and the rule is self-maintaining.
#
# tests/ and scripts/ hold both upstream's scripts and this branch's. Fixing a
# style finding in a file the branch has never touched buys nothing and costs a
# rebase conflict forever. But "upstream file" is the wrong line, because the
# branch has already modified four of the five upstream scripts that had
# findings -- the conflict is already being paid there, so those are in scope.
#
# So: a script is IN SCOPE unless it is byte-identical to the fork point. The
# excuse evaporates the moment the branch touches it, which is exactly when the
# argument for excusing it stops holding. Nothing is listed by name and nothing
# has to be maintained.
#
# NO BASELINE. Every other debt register on this branch expires in both
# directions -- depcheck's, linkcheck's, lanecheck's excuses. A shellcheck
# baseline would be the only one that could not, in the one place where the
# findings are cheapest to fix, so the in-scope set is held at zero instead and
# a suppression is a comment at the site with the reason beside it.
#
# Exit codes:  0 clean   1 findings   2 skipped

set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

SEVERITY=style

usage() {
    cat <<EOF
Usage: $0 [--severity error|warning|info|style]

  --severity LEVEL   minimum severity to report (default: $SEVERITY)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --severity) SEVERITY=$2; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "shellcheck.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# PINNED, and the pin is asserted rather than hoped for. A lint's finding set is
# version-dependent: 0.9.0 reports a trap-invoked cleanup function as SC2317 and
# 0.11.0 reports it as SC2329, so a suppression written against one version is
# not a suppression under the other. Run unpinned, this gate produced 0 findings
# on a developer box and 65 on a runner from the same tree -- "the gate went red
# and nobody changed a script", which is the most expensive false positive a
# lint has.
#
# resources/ FIRST, PATH second. resources/ is the scratch directory .gitignore
# covers wholesale and is where the lane installs the pin; a distro shellcheck on
# PATH is whatever that image happens to ship.
SC_PIN=$(tr -d ' \t\n' < "$ROOT/tests/shellcheck.version" 2>/dev/null)
[ -n "$SC_PIN" ] || { echo "shellcheck: SKIPPED -- tests/shellcheck.version is missing" >&2; exit 2; }

SC=""
[ -x "$ROOT/resources/shellcheck/shellcheck" ] && SC="$ROOT/resources/shellcheck/shellcheck"
[ -n "$SC" ] || SC=$(command -v shellcheck 2>/dev/null)
if [ -z "$SC" ]; then
    echo "shellcheck: SKIPPED -- no shellcheck in resources/ or on PATH" >&2
    echo "  ./resources/shellcheck-setup.sh   fetches the pinned $SC_PIN" >&2
    exit 2
fi

SC_HAVE=$("$SC" --version | awk '/^version:/{print $2}')
if [ "$SC_HAVE" != "$SC_PIN" ]; then
    echo "shellcheck: SKIPPED -- found $SC_HAVE, this tree is written against $SC_PIN" >&2
    echo "  A different version reports a different finding set, so its verdict" >&2
    echo "  is not this tree's. ./resources/shellcheck-setup.sh fetches the pin." >&2
    exit 2
fi

git rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "shellcheck: SKIPPED -- not a git repository" >&2; exit 2; }

# The fork point, tried against every ref a checkout might actually have. A CI
# clone has no LOCAL master: `actions/checkout` leaves the branch checked out and
# the other branches as remote-tracking refs, so `git merge-base HEAD master`
# fails there and this gate SKIPped with exit 2 on every run -- which `docs.yml`
# reports as a failed step and `refish.yml` asserts on besides.
BASE=""
for cand in master origin/master refs/remotes/origin/master upstream/master; do
    if BASE=$(git merge-base HEAD "$cand" 2>/dev/null) && [ -n "$BASE" ]; then
        break
    fi
    BASE=""
done

# NOT a skip when the fork point cannot be found. A skip proves nothing, and the
# question the base answers is only "which scripts may be excused" -- so with no
# base every script is in scope, which is the strict direction. Getting this
# wrong permissively would hide a finding; getting it wrong strictly at worst
# reports one that is upstream's, and it says which case it is in.
NARROWED=1
if [ -z "$BASE" ]; then
    NARROWED=0
    echo "shellcheck: no merge-base with master; EVERY script is in scope" >&2
fi

echo "shellcheck: $SC_HAVE (pinned), severity=$SEVERITY, base=$([ "$NARROWED" = 1 ] && git rev-parse --short "$BASE" || echo '<none, all in scope>')"

INSCOPE=() EXCUSED=()
for f in tests/*.sh scripts/*.sh; do
    [ -f "$f" ] || continue
    if [ "$NARROWED" = 0 ]; then
        INSCOPE+=("$f")
        continue
    fi
    # A file that does not EXIST at the fork point was created by this branch and
    # is in scope, full stop. Testing only for a diff gets this wrong in the
    # worst direction: `git diff BASE HEAD -- <untracked>` reports no difference
    # because the path is absent on both sides, so a NEW gate script would excuse
    # itself. This gate did exactly that on its first run and reported clean over
    # a set that excluded itself.
    if ! git cat-file -e "$BASE:$f" 2>/dev/null; then
        INSCOPE+=("$f")
    # Byte-identical to the fork point in both HEAD and the working tree? Then
    # the branch has never touched it and a finding is upstream's to fix.
    elif git diff --quiet "$BASE" HEAD -- "$f" 2>/dev/null \
         && git diff --quiet HEAD -- "$f" 2>/dev/null; then
        EXCUSED+=("$f")
    else
        INSCOPE+=("$f")
    fi
done

echo
echo "== scope =="
echo "  in scope   ${#INSCOPE[@]} script(s) the branch wrote or edited"
echo "  excused    ${#EXCUSED[@]} byte-identical to the fork point:"
for f in "${EXCUSED[@]}"; do echo "      $f"; done

if [ ${#INSCOPE[@]} -eq 0 ]; then
    echo "shellcheck: SKIPPED -- nothing in scope" >&2
    exit 2
fi

echo
echo "== findings in scope =="
out=$("$SC" --severity="$SEVERITY" --format=gcc -- "${INSCOPE[@]}" 2>&1) || true
if [ -n "$out" ]; then
    printf '%s\n' "$out" | sed 's/^/  /'
    n=$(printf '%s\n' "$out" | grep -c .)
    echo
    echo "shellcheck: $n finding(s) in scripts this branch owns"
    echo "  Fix it, or suppress it AT THE SITE with the reason on the next line:"
    echo "      # shellcheck disable=SC2086"
    echo "      # \$objs is an object LIST and must split into separate arguments."
    echo "  A directive must sit before the whole command, not before a"
    echo "  continuation line, and it takes no trailing text on its own line."
    exit 1
fi
echo "  none"

# The excused set is reported, never gated. It is upstream's code and this
# branch does not churn it -- but a count printed every run is what stops the
# excuse becoming invisible, and a real defect found there belongs in the
# upstream defect register with a reproducer, not in a style sweep.
if [ ${#EXCUSED[@]} -gt 0 ]; then
    echo
    echo "== findings in excused (upstream, untouched) -- reported, not gated =="
    eout=$("$SC" --severity="$SEVERITY" --format=gcc -- "${EXCUSED[@]}" 2>&1)
    if [ -n "$eout" ]; then
        printf '%s\n' "$eout" | sed 's/^/  /'
    else
        echo "  none"
    fi
fi

echo
echo "shellcheck: clean"
exit 0
