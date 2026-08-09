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
// Deliberately not a test framework: it must build from the engine sources
// alone.

#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>

#include "../src/engine/attacks.h"
#include "../src/engine/nnue/network.h"
#include "../src/engine/nnue/nnue_misc.h"
#include "../src/engine/position.h"
#include "../src/engine/search_go.h"
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

}  // namespace

int main(int argc, char** argv) {
    if (argc < 2)
        return fail("usage: enginelink_main <dir-holding-the-net>");

    const std::filesystem::path netDir(argv[1]);
    if (!std::filesystem::is_directory(netDir))
        return fail("no such directory: " + netDir.string());

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
