#!/bin/bash
# obtain and optionally verify Bench / signature
# if no reference is given, the output is deliberately limited to just the signature

STDOUT_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

error()
{
  echo "running bench for signature failed on line $1"
  echo "===== STDOUT ====="
  cat "$STDOUT_FILE"
  echo "===== STDERR ====="
  cat "$STDERR_FILE"
  rm -f "$STDOUT_FILE" "$STDERR_FILE"
  exit 1
}
trap 'error ${LINENO}' ERR

# obtain
EXE=${EXE:-./stockfish}
eval "$RUN_PREFIX $EXE bench" > "$STDOUT_FILE" 2> "$STDERR_FILE" || error ${LINENO}
signature=$(grep "Nodes searched  : " "$STDERR_FILE" | awk '{print $4}')

rm -f "$STDOUT_FILE" "$STDERR_FILE"

if [ $# -gt 0 ]; then
   # An EMPTY reference is the caller's lookup having failed, not a mismatch.
   # `git log -20 ... | grep -m1 'Bench:'` yields nothing on a branch with more
   # than twenty non-functional commits, and reporting that as "reference
   # obtained: N" sends the reader hunting a behaviour change that did not
   # happen.
   case "$1" in
      *[!0-9]*|"")
         echo "signature: refusing a non-numeric reference: '$1'" >&2
         echo "  the caller's anchor lookup produced nothing; widen the git log window" >&2
         exit 2
         ;;
   esac
   # compare to given reference
   if [ "$1" != "$signature" ]; then
      if [ -z "$signature" ]; then
         echo "No signature obtained from bench. Code crashed or assert triggered ?"
      else
         echo "signature mismatch: reference $1 obtained: $signature ."
      fi
      exit 1
   else
      echo "signature OK: $signature"
   fi
else
   # just report signature
   # shellcheck disable=SC2086
   # the split is deliberate: this expands a LIST into separate arguments
   echo $signature
fi
