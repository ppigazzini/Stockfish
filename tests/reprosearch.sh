#!/bin/bash
# verify reproducible search

error()
{
  echo "reprosearch testing failed on line $1"
  exit 1
}
trap 'error ${LINENO}' ERR

echo "reprosearch testing started"

# repeat two short games, separated by ucinewgame.
# with go nodes $nodes they should result in exactly
# the same node count for each iteration.
# A Python driver rather than expect, for the reason given in tests/perft.sh:
# python3 is already required by the suite and expect is not always installed.
# The session is unchanged -- two short games, a ucinewgame, then the same two
# again -- so every `nodes N` line must appear an even number of times.
cat << 'EOF' > repeat.py
import subprocess, sys, threading, queue, time
nodes = sys.argv[1]
p = subprocess.Popen(["./stockfish"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)
q = queue.Queue()
def rd():
    for line in p.stdout:
        q.put(line.rstrip("\n"))
    q.put(None)
threading.Thread(target=rd, daemon=True).start()
out = []
def until(tok, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        try:
            line = q.get(timeout=0.2)
        except queue.Empty:
            continue
        if line is None:
            sys.exit("EOF: Stockfish crashed")
        out.append(line)
        if tok in line:
            return
    sys.exit(f"TIMEOUT waiting for {tok}")
def send(c):
    p.stdin.write(c + "\n"); p.stdin.flush()
send("uci"); until("uciok")
for _ in range(2):
    send("ucinewgame")
    send("position startpos");                  send(f"go nodes {nodes}"); until("bestmove")
    send("position startpos moves e2e4 e7e6");   send(f"go nodes {nodes}"); until("bestmove")
send("quit")
try:
    p.wait(timeout=10)
except Exception:
    p.kill()
print("\n".join(out))
EOF

# to increase the likelihood of finding a non-reproducible case,
# the allowed number of nodes are varied systematically
for i in `seq 1 20`
do

  nodes=$((100*3**i/2**i))
  echo "reprosearch testing with $nodes nodes"

  # each line should appear exactly an even number of times
  python3 repeat.py $nodes 2>&1 | grep -o "nodes [0-9]*" | sort | uniq -c | awk '{if ($1%2!=0) exit(1)}'

done

rm repeat.py

echo "reprosearch testing OK"
