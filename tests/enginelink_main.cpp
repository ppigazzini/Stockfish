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

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <set>
#include <string>

#include "../src/engine/attacks.h"
#include "../src/engine/hashing.h"
#include "../src/engine/nnue/network.h"
#include "../src/engine/nnue/nnue_misc.h"
#include "../src/engine/position.h"
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
// WHAT THIS DOES NOT COVER, stated so the next reader does not think it does: a
// headless run with two workers ACTUALLY REGISTERED. That needs concurrency,
// not a bigger assertion -- a non-main worker ignores the depth cap
// (search.cpp:430 tests `mainThread`) and is terminated by the main worker's
// stopFlag after it finishes, so a set whose start_searching runs one inline
// never returns. That needs a worker count on Search::go and a caller that owns
// threads, which is a design change and not a test.
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
    return 0;
}
