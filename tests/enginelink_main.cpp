/*
  Stockfish, a UCI chess playing engine derived from Glaurung 2.1
  Copyright (C) 2004-2026 The Stockfish developers (see AUTHORS file)

  Stockfish is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  Stockfish is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// The host for tests/enginelink.sh.
//
// It links against src/engine/ ONLY -- no platform object, no shell object --
// and it registers NOTHING. Every seam therefore runs on its default: the arena
// falls back to plain aligned allocation, the output sink prints, the
// parallel-for clears the transposition table inline, the tablebase source
// answers "none loaded", the clock reads std::chrono.
//
// That is the whole point. The link half of the gate proves each default is
// REACHABLE; a link resolves a symbol without ever calling it. This calls them,
// and it is the only thing in the tree that does.
//
// Usage: enginelink_main <dir-holding-the-net>  ->  0 on success, non-zero with
// a reason on stderr. A DIRECTORY, not a file: the engine knows its own default
// net name, and `**/*.nnue` is gitignored, so src/ accumulates the nets of older
// builds and naming one from outside picks a stale one that will not parse.
//
// It also carries the engine-side invariants that need no host at all, for the
// same reason: linking engine/ alone is what this program is for, and a pure
// function of the engine has nowhere else in the tree to be checked.
//
// Deliberately not a test framework: it must build from the engine sources
// alone.

#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <iostream>
#include <memory>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "../src/engine/attacks.h"
#include "../src/engine/hashing.h"
#include "../src/engine/nnue/network.h"
#include "../src/engine/nnue/nnue_misc.h"
#include "../src/engine/position.h"
#include "../src/engine/parallel.h"
#include "../src/engine/search_go.h"
#include "../src/engine/worker_set.h"
#include "../src/engine/types.h"

using namespace Stockfish;

namespace {

int fail(const std::string& why) {
    std::cerr << "enginelink_main: " << why << "\n";
    return 1;
}

// A depth-limited search from a fixed position, checked for the properties a
// working search must have rather than for an exact node count. An exact count
// would be a second bench signature to maintain, and this gate is about whether
// the defaults RUN, not about what they compute.
struct Case {
    const char* name;
    const char* fen;
    int         depth;
};

// An engine-side invariant that needs no host, checked here because this is the
// only program in the tree that links engine/ and runs it.
//
// hash_bytes' tail loop reads through `char`, and `char` is signed on the
// platforms this ships to: a tail byte >= 0x80 sign-extends and the `or` then
// sets every bit above bit 7, erasing everything already accumulated from the
// higher indices. The property is stated as a DOMAIN COUNT rather than as a
// golden hash: a golden pins the algorithm, and what has to hold is that
// distinct inputs get distinct hashes. Over all 65536 two-byte inputs the
// signed form produced 32896 distinct values.
int check_hash_domain() {
    std::set<u64> seen;
    for (int a = 0; a < 256; ++a)
        for (int b = 0; b < 256; ++b)
        {
            const char in[2] = {char(a), char(b)};
            seen.insert(hash_bytes(in, sizeof(in)));
        }

    if (seen.size() != 65536)
        return fail("hash_bytes maps 65536 two-byte inputs onto " + std::to_string(seen.size())
                    + " values");

    // The pair the report names, kept because a count can be satisfied by an
    // accident and this one cannot.
    const char x[3] = {'\x80', '\x02', '\x03'};
    const char y[3] = {'\x80', '\x02', '\x04'};
    if (hash_bytes(x, sizeof(x)) == hash_bytes(y, sizeof(y)))
        return fail("hash_bytes collides {80 02 03} with {80 02 04}");

    std::cout << "  hash_bytes: 65536 distinct values over the two-byte domain\n";
    return 0;
}

// The one seam default that cannot honestly degrade, asked what it does when
// something requests two.
//
// Every other default here answers the same question more slowly: the arena
// falls back to plain aligned allocation, the parallel-for runs the work
// inline, the clock reads std::chrono. The worker set cannot. FEWER WORKERS IS
// A DIFFERENT ANSWER, not a slower one, so its default must REFUSE rather than
// pretend -- report no workers and let the caller cope, instead of reporting
// one it does not have.
//
// That refusal has to be consistent across all six accessors, because the
// search reads them in combination: it takes count() and then indexes at() up
// to it, and sums nodes_searched() and tb_hits() over the same set. A default
// that reported one worker and handed back nullptr, or zero workers and a
// non-zero node count, would be a different kind of wrong at each call site.
// Only `count() == 0` is checked anywhere today, at search.cpp's best_worker
// guard, and that is one reading of one call site rather than a stated
// contract.
//
// A headless run with two workers actually registered is a separate question
// and check_two_workers below is where it is asked. This one is about the
// DEFAULT, and the default has to keep answering this way whatever that one
// does.
int check_worker_set_default() {
    const WorkerSet& ws = worker_set();

    if (ws.count(ws.ctx) != 0)
        return fail("the default worker set reports " + std::to_string(ws.count(ws.ctx))
                    + " workers it does not have");

    // Indexed past a count of zero on purpose: the search only indexes below
    // count(), so this asks whether the default refuses OUT of contract too,
    // which is what a host getting the registration wrong would do.
    for (usize i = 0; i < 4; ++i)
        if (ws.at(ws.ctx, i) != nullptr)
            return fail("the default worker set handed back a worker at index "
                        + std::to_string(i));

    if (ws.nodes_searched(ws.ctx) != 0 || ws.tb_hits(ws.ctx) != 0)
        return fail("the default worker set counted nodes or tb hits for workers it has none of");

    // The two that must be reachable and do nothing. A default that faulted
    // here would take down every headless caller.
    ws.start_searching(ws.ctx);
    ws.wait_for_search_finished(ws.ctx);

    std::cout << "  worker set: the default refuses, consistently, across all six accessors\n";
    return 0;
}


// A parallel-for backed by REAL THREADS, which is the only thing in this file
// that registers anything.
//
// It exists because the built-in one runs the job inline on the caller, and an
// inline non-main worker never returns: the depth cap tests `mainThread`
// (search.cpp:430) and a non-main worker has none, so it searches to MAX_PLY
// waiting for a stop flag the caller cannot reach the line to raise. That is
// not a defect in the default -- running the work inline is a correct
// parallel-for -- it is the reason a two-worker search needs a host, and the
// reason Search::go refuses the count instead of attempting it.
//
// A thread per dispatch rather than a pool. A pool is what the engine ships
// with and this is not it: the thing under test is whether the seam can start a
// helper and wait for it afterwards, and spawning is the smallest
// implementation with that shape.
namespace host {

constexpr usize THREADS = 2;

std::thread      running[THREADS];
std::atomic<int> dispatched{0};
std::atomic<int> completed{0};
std::atomic<int> waited{0};

usize              num_threads() { return THREADS; }
usize              numa_nodes() { return 1; }
std::vector<usize> thread_numa_map() { return {}; }

void run_on(usize t, std::function<void()> fn) {
    if (t >= THREADS)
    {
        fn();
        return;
    }
    if (running[t].joinable())
        running[t].join();
    dispatched.fetch_add(1);
    running[t] = std::thread([job = std::move(fn)]() {
        job();
        completed.fetch_add(1);
    });
}

void wait_on(usize t) {
    if (t >= THREADS)
        return;
    waited.fetch_add(1);
    if (running[t].joinable())
        running[t].join();
}

}  // namespace host

// The half of D2 the default-set check cannot reach: a headless search with two
// workers actually registered, running on threads the host owns.
//
// Two claims, and the refusal is the one that would rot silently. With no
// thread-owning host registered, a request for two workers must come back
// EMPTY: attempting it deadlocks rather than degrades, so a Search::go that
// tried would hang this gate instead of failing it, and a hang is not a report.
//
// The dispatch counter is what makes the second claim mean something. A search
// that returned a plausible result while quietly running one worker would
// satisfy every assertion about the RESULT -- the position is the same and one
// worker searches it perfectly well. Counting the calls to run_on asks whether
// a helper was put on another thread at all, which is the actual claim.
int check_two_workers(const Eval::NNUE::Network& net, const char* fen) {
    // Refusal first, while nothing is registered and num_threads() is 1.
    if (Search::go(net, fen, false, 6, 2).has_value())
        return fail("a two-worker search was attempted with no host to run it on");
    if (Search::go(net, fen, false, 6, 0).has_value())
        return fail("a search with zero workers returned a result");

    std::cout << "  two workers: refused with no thread-owning host registered\n";

    set_parallel_for({host::num_threads, host::numa_nodes, host::thread_numa_map, host::run_on,
                      host::wait_on});

    host::dispatched.store(0);
    host::completed.store(0);
    host::waited.store(0);

    const auto r = Search::go(net, fen, false, 6, 2);

    // Unregister BEFORE reporting: the seam reaches into this file's statics and
    // anything running after must not still be pointed at them.
    reset_parallel_for();

    if (!r.has_value())
        return fail("a two-worker search with a registered host produced no result");
    if (r->bestMove == Move::none() || r->nodes == 0)
        return fail("a two-worker search produced no move or no nodes");
    if (host::dispatched.load() < 1)
        return fail("a two-worker search dispatched no helper onto the host's threads");
    if (host::waited.load() < host::dispatched.load())
        return fail("a two-worker search waited on fewer helpers than it started");
    // The claim the whole entry turns on. A helper that never returns is the
    // failure mode here -- it ignores the depth cap and searches to MAX_PLY --
    // and it would show as a hang rather than as a red gate, so recording that
    // start_searching RETURNED is the only way this leaves evidence either way.
    if (host::completed.load() != host::dispatched.load())
        return fail("a helper was started and did not finish");

    std::cout << "  two workers: " << r->nodes << " nodes over the set, "
              << host::dispatched.load() << " helper dispatch(es), " << host::completed.load()
              << " finished, " << host::waited.load() << " wait(s)\n";

    // Back to one, so nothing after this inherits a rebuilt set. The count
    // change rebuilds the workers, which is the path a second count change
    // takes too.
    const auto back = Search::go(net, fen, false, 6);
    if (!back.has_value() || back->nodes == 0)
        return fail("the engine did not go back to one worker");

    std::cout << "  two workers: back to one, " << back->nodes << " nodes\n";
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2)
        return fail("usage: enginelink_main <dir-holding-the-net>");

    const std::filesystem::path netDir(argv[1]);
    if (!std::filesystem::is_directory(netDir))
        return fail("no such directory: " + netDir.string());

    if (const int rc = check_hash_domain(); rc != 0)
        return rc;

    if (const int rc = check_worker_set_default(); rc != 0)
        return rc;

    // Startup, engine-side only. shell/main.cpp calls exactly these two before
    // anything searches.
    Attacks::init();
    Position::init();

    // Heap, not stack: the network is tens of megabytes.
    auto             net = std::make_unique<Eval::NNUE::Network>();
    Eval::NNUE::EvalFile evalFile{std::nullopt, ""};
    // An empty path means "your default name", which is the only name that is
    // guaranteed to match the feature set these objects were compiled for.
    net->load(netDir, std::filesystem::path{}, evalFile);
    if (!evalFile.current.has_value())
        return fail("no net named " + std::string(Eval::NNUE::EvalFile::defaultName)
                    + " loaded from " + netDir.string());

    const Case cases[] = {
      {"startpos", "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", 8},
      {"midgame", "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", 7},
      {"endgame", "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", 10},
    };

    for (const Case& c : cases)
    {
        const auto r = Search::go(*net, c.fen, false, c.depth);
        if (!r.has_value())
            return fail(std::string("no result for ") + c.name);
        if (r->bestMove == Move::none())
            return fail(std::string("no best move for ") + c.name);
        if (r->nodes == 0)
            return fail(std::string("zero nodes for ") + c.name);
        if (r->score == -VALUE_INFINITE)
            return fail(std::string("unscored root for ") + c.name);
        std::cout << "  " << c.name << ": depth " << c.depth << ", " << r->nodes << " nodes\n";
    }

    // Called twice on purpose: the context is process-static and reused, so a
    // second search exercises the reset path rather than a fresh construction.
    // A worker that only works once is a worker that leaks state between
    // searches, which is exactly what ucinewgame handling gets wrong quietly.
    const auto again = Search::go(*net, cases[0].fen, false, cases[0].depth);
    if (!again.has_value() || again->nodes == 0)
        return fail("the second search on a reused context produced nothing");
    if (again->bestMove != Search::go(*net, cases[0].fen, false, cases[0].depth)->bestMove)
        return fail("repeating the same search changed the best move");

    std::cout << "  reuse: same best move on repeat\n";

    if (const int rc = check_two_workers(*net, cases[0].fen); rc != 0)
        return rc;

    return 0;
}
