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

#ifndef SEARCH_GO_H_INCLUDED
#define SEARCH_GO_H_INCLUDED

#include <optional>
#include <string_view>

#include "basetypes.h"
#include "types.h"

namespace Stockfish {

namespace Eval::NNUE {
class Network;
}

namespace Search {

// Run ONE depth-limited, single-threaded search with NO host registered.
//
// In a hosted run the platform's thread pool constructs each Worker and
// populates its root state before iterative_deepening runs, so this is the only
// way to search one position at one depth without the pool -- and therefore the
// only way to EXERCISE the seam defaults. tests/enginelink.sh proves every seam
// symbol resolves without the host; a link resolves a symbol, it does not call
// it. This is what calls them.
//
// Everything it touches self-defaults: the arena falls back to plain aligned
// allocation, the output sink prints, the parallel-for runs the transposition
// table's clear inline, the tablebase source answers "none loaded" -- which is
// exactly true -- and the clock reads std::chrono. The one seam that cannot
// honestly default is the worker set, because fewer workers is a different
// answer rather than a slower one; here there genuinely is one worker, and the
// search is depth-limited so no time management asks the set anything.
//
// Not reentrant: the Worker and its scaffolding are process-static and reused
// across calls, so two callers at once share one root position. Load the net
// before calling; the caller owns it.
struct GoResult {
    Move  bestMove;
    Value score;
    u64   nodes;
};

std::optional<GoResult>
go(const Eval::NNUE::Network& net, std::string_view fen, bool chess960, int depth);

}  // namespace Search
}  // namespace Stockfish

#endif  // #ifndef SEARCH_GO_H_INCLUDED
