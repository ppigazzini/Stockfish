#!/bin/bash
# verify reproducible search

error()
{
  echo "reprosearch testing failed on line $1"
  exit 1
}
trap 'error ${LINENO}' ERR

# expect drives the engine below, and its absence used to read as a PASS: the
# comparison is a pipeline whose exit status is awk's, so a missing interpreter
# left grep with nothing to match, awk with no lines to reject, and the script
# printing "reprosearch testing OK" having checked nothing. Refuse instead.
# Exit 2 is SKIPPED -- it proves nothing, which is the honest answer.
if ! command -v expect >/dev/null; then
  echo "reprosearch: SKIPPED -- expect is not installed" >&2
  exit 2
fi

echo "reprosearch testing started"

# The driver script is written into the working directory, so remove it on EVERY
# exit and not only on the successful one. Leaving it behind on a failure drops
# an untracked file into src/, which is the shape tests/depcheck.sh's zone check
# now refuses.
trap 'rm -f repeat.exp' EXIT

# repeat two short games, separated by ucinewgame.
# with go nodes $nodes they should result in exactly
# the same node count for each iteration.
cat << EOF > repeat.exp
 set timeout 10
 spawn ./stockfish
 lassign \$argv nodes

 send "uci\n"
 expect "uciok"

 send "ucinewgame\n"
 send "position startpos\n"
 send "go nodes \$nodes\n"
 expect "bestmove"

 send "position startpos moves e2e4 e7e6\n"
 send "go nodes \$nodes\n"
 expect "bestmove"

 send "ucinewgame\n"
 send "position startpos\n"
 send "go nodes \$nodes\n"
 expect "bestmove"

 send "position startpos moves e2e4 e7e6\n"
 send "go nodes \$nodes\n"
 expect "bestmove"

 send "quit\n"
 expect eof
EOF

# to increase the likelihood of finding a non-reproducible case,
# the allowed number of nodes are varied systematically
for i in `seq 1 20`
do

  nodes=$((100*3**i/2**i))
  echo "reprosearch testing with $nodes nodes"

  # each line should appear exactly an even number of times
  counts=$(expect repeat.exp $nodes 2>&1 | grep -o "nodes [0-9]*" | sort | uniq -c)

  # A round that reported no node counts at all compared nothing, and the
  # even-count test below is vacuously satisfied by an empty input. Treat it as
  # the failure it is: the driver died, timed out, or the engine printed no
  # bestmove.
  if [ -z "$counts" ]; then
    echo "reprosearch: no node counts from the driver at $nodes nodes"
    exit 1
  fi

  printf '%s\n' "$counts" | awk '{if ($1%2!=0) exit(1)}'

done

echo "reprosearch testing OK"
