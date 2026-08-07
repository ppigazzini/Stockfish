#!/bin/bash
# verify perft numbers (positions from https://www.chessprogramming.org/Perft_Results)

TESTS_FAILED=0

error()
{
  echo "perft testing failed on line $1"
  exit 1
}
trap 'error ${LINENO}' ERR

echo "perft testing started"

# A Python driver rather than expect: python3 is already required by
# tests/instrumented.py, expect is not always installed, and a gate that cannot
# run reports nothing rather than failing. Same contract as before -- the
# arguments and the exit codes are unchanged.
EXPECT_SCRIPT=$(mktemp)

cat << 'EOF' > $EXPECT_SCRIPT
#!/usr/bin/env python3
import subprocess, sys, threading, queue, time
pos, depth, result, chess960, logfile = sys.argv[1:6]
p = subprocess.Popen(["./stockfish"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)
q = queue.Queue()
def rd():
    for line in p.stdout:
        q.put(line.rstrip("\n"))
    q.put(None)
threading.Thread(target=rd, daemon=True).start()
if chess960 == "true":
    p.stdin.write("setoption name UCI_Chess960 value true\n")
p.stdin.write(f"position {pos}\ngo perft {depth}\n")
p.stdin.flush()
want, log, end = f"Nodes searched: {result}", [], time.time() + 120
rc = 1
while time.time() < end:
    try:
        line = q.get(timeout=0.5)
    except queue.Empty:
        continue
    if line is None:
        print("EOF: Stockfish crashed"); rc = 2; break
    log.append(line)
    if want in line:
        rc = 0; break
    # The engine answered with a different count. Waiting out the timeout would
    # turn one wrong case into two minutes, and a whole suite into half an hour.
    if line.startswith("Nodes searched:"):
        print(f"WRONG: {line.strip()}, expected {result}")
        break
else:
    print(f"TIMEOUT: Expected {result} nodes")
open(logfile, "w").write("\n".join(log) + "\n")
try:
    p.stdin.write("quit\n"); p.stdin.flush(); p.wait(timeout=10)
except Exception:
    p.kill()
sys.exit(rc)
EOF

chmod +x $EXPECT_SCRIPT

run_test() {
  local pos="$1"
  local depth="$2"
  local expected="$3"
  local chess960="$4"
  local tmp_file=$(mktemp)

  echo -n "Testing depth $depth: ${pos:0:40}... "

  if $EXPECT_SCRIPT "$pos" "$depth" "$expected" "$chess960" "$tmp_file" > /dev/null 2>&1; then
    echo "OK"
    rm -f "$tmp_file"
  else
    local exit_code=$?
    echo "FAILED (exit code: $exit_code)"
    echo "===== Output for failed test ====="
    cat "$tmp_file"
    echo "=================================="
    rm -f "$tmp_file"
    TESTS_FAILED=1
  fi
}

# standard positions

run_test "startpos" 7 3195901860 "false"
run_test "fen r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq -" 5 193690690 "false"
run_test "fen 8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - -" 7 178633661 "false"
run_test "fen r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1" 6 706045033 "false"
run_test "fen rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8" 5 89941194 "false"
run_test "fen r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10" 5 164075551 "false"
run_test "fen r7/4p3/5p1q/3P4/4pQ2/4pP2/6pp/R3K1kr w Q - 1 3" 5 11609488 "false"

# chess960 positions

run_test "fen rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w AHah - 0 1" 6 119060324 "true"
run_test "fen 1rqbkrbn/1ppppp1p/1n6/p1N3p1/8/2P4P/PP1PPPP1/1RQBKRBN w FBfb - 0 9" 6 191762235 "true"
run_test "fen rbbqn1kr/pp2p1pp/6n1/2pp1p2/2P4P/P7/BP1PPPP1/R1BQNNKR w HAha - 0 9" 6 924181432 "true"
run_test "fen rqbbknr1/1ppp2pp/p5n1/4pp2/P7/1PP5/1Q1PPPPP/R1BBKNRN w GAga - 0 9" 6 308553169 "true"
run_test "fen 4rrb1/1kp3b1/1p1p4/pP1Pn2p/5p2/1PR2P2/2P1NB1P/2KR1B2 w D - 0 21" 6 872323796 "true"
run_test "fen 1rkr3b/1ppn3p/3pB1n1/6q1/R2P4/4N1P1/1P5P/2KRQ1B1 b Dbd - 0 14" 6 2678022813 "true"
run_test "fen qbbnrkr1/p1pppppp/1p4n1/8/2P5/6N1/PPNPPPPP/1BRKBRQ1 b FCge - 1 3" 6 521301336 "true"
run_test "fen rr6/2kpp3/1ppn2p1/p2b1q1p/P4P1P/1PNN2P1/2PP4/1K2R2R b E - 1 20" 2 1438 "true"
run_test "fen rr6/2kpp3/1ppn2p1/p2b1q1p/P4P1P/1PNN2P1/2PP4/1K2RR2 w E - 0 20" 3 37340 "true"
run_test "fen rr6/2kpp3/1ppnb1p1/p2Q1q1p/P4P1P/1PNN2P1/2PP4/1K2RR2 b E - 2 19" 4 2237725 "true"
run_test "fen rr6/2kpp3/1ppnb1p1/p4q1p/P4P1P/1PNN2P1/2PP2Q1/1K2RR2 w E - 1 19" 4 2098209 "true"
run_test "fen rr6/2kpp3/1ppnb1p1/p4q1p/P4P1P/1PNN2P1/2PP2Q1/1K2RR2 w E - 1 19" 5 79014522 "true"
run_test "fen rr6/2kpp3/1ppnb1p1/p4q1p/P4P1P/1PNN2P1/2PP2Q1/1K2RR2 w E - 1 19" 6 2998685421 "true"

rm -f $EXPECT_SCRIPT
echo "perft testing completed"

if [ $TESTS_FAILED -ne 0 ]; then
  echo "Some tests failed"
  exit 1
fi
