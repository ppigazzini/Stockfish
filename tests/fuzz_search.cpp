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

// Fuzz the real search IN-PROCESS: no shell, no UCI text, no subprocess.
//
// tests/fuzz.py's uci harness already fuzzes the shipped binary's stdin. That is
// a real gate, but it drives a subprocess with text, so a mutation spends most
// of its budget inside the command parser rather than inside the search. This
// driver puts nothing between the fuzzer and the node body.
//
// THE INPUT IS A WALK, NOT A POSITION. Each byte selects one of the legal moves
// available, modulo their count, and the walk plays it. So every position
// reached is legal and reachable by construction -- no byte is spent on FEN
// syntax, no finding is a false positive from an impossible board, and the
// positions land where no bench list and no golden corpus goes.
//
// It links against src/engine/ ONLY, exactly as tests/enginelink.sh does, and
// registers no seam. That is not a convenience: it means every crash this finds
// is in the engine, with no host to blame, and it is proof by construction that
// the search runs without one.
//
// Built by tests/fuzzsearch.sh. Not part of the shipped build.

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string>

#include "../src/engine/attacks.h"
#include "../src/engine/movegen.h"
#include "../src/engine/nnue/network.h"
#include "../src/engine/nnue/nnue_misc.h"
#include "../src/engine/position.h"
#include "../src/engine/search_go.h"
#include "../src/engine/types.h"

using namespace Stockfish;

namespace {

// Deep enough to reach positions no fixed list covers, shallow enough that a
// short input still reaches a SEARCH rather than spending its whole budget
// walking.
constexpr int MaxWalkPlies = 40;

// Fixed and shallow on purpose. libFuzzer wants thousands of iterations per
// second, and a defect in the node body is found as reliably at depth 3 as at
// depth 8 -- a deeper search buys more nodes through the same code, not more
// code.
constexpr int SearchDepth = 3;

std::unique_ptr<Eval::NNUE::Network> gNet;

const char* StartFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

}  // namespace

extern "C" int LLVMFuzzerInitialize(int* argc, char*** argv);
extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size);

extern "C" int LLVMFuzzerInitialize(int*, char***) {
    // The same order shell/main.cpp uses, and for the same reason: a Position
    // built before the attack tables are filled reads zeros.
    Attacks::init();
    Position::init();

    // The net is REQUIRED, not best-effort: this engine has no classical
    // fallback, so a run without one would evaluate garbage and every finding
    // would be noise. The runner passes the directory through the environment
    // because libFuzzer owns argv.
    const char* dir = std::getenv("SF_FUZZ_NET_DIR");
    gNet            = std::make_unique<Eval::NNUE::Network>();
    Eval::NNUE::EvalFile evalFile{std::nullopt, ""};
    gNet->load(std::filesystem::path(dir ? dir : "."), std::filesystem::path{}, evalFile);
    if (!evalFile.current.has_value())
    {
        // Abort rather than continue: a silent no-net run looks exactly like a
        // clean fuzz run and proves nothing.
        std::fputs("fuzz_search: no net loaded; set SF_FUZZ_NET_DIR\n", stderr);
        std::abort();
    }
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    Position  pos;
    StateInfo rootState;
    StateInfo walkStates[MaxWalkPlies];

    if (pos.set(std::string(StartFEN), false, &rootState) != std::nullopt)
        return 0;

    size_t cursor = 0;
    for (int ply = 0; ply < MaxWalkPlies && cursor < size; ++ply)
    {
        MoveList<LEGAL> legal(pos);
        const size_t    count = legal.size();
        if (count == 0)
            break;  // mate or stalemate: nowhere left to walk

        auto it = legal.begin();
        std::advance(it, data[cursor++] % count);
        pos.do_move(*it, walkStates[ply], nullptr);
    }

    // Through the FEN, deliberately. It makes the reached position a FRESH root
    // with no pre-root history, which is the same shape a `position fen` command
    // produces -- and it keeps this driver on the engine's one public headless
    // entry rather than a second one built for testing.
    Search::go(*gNet, pos.fen(), false, SearchDepth);
    return 0;
}
