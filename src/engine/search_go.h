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
#include "tb_source.h"
#include "types.h"

namespace Stockfish {

namespace Eval::NNUE {
class Network;
}

namespace Search {

// Run ONE depth-limited search with NO host registered, on `workers` workers.
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
// ASKING FOR MORE THAN ONE IS A REQUEST FOR THREADS, AND IT CAN BE REFUSED.
// The non-main workers are dispatched through the parallel-for seam, which is
// where the host's threads already are -- `run_on` and `wait_on` are two calls,
// not a fork-join, so a helper can be started here and waited for after the
// main worker has finished and raised the stop flag. The BUILT-IN parallel-for
// runs the job inline on the caller, and an inline helper never returns: the
// depth cap tests `mainThread` and a non-main worker has none, so it searches
// to MAX_PLY waiting for a stop the caller cannot reach the line to raise.
//
// So a count above what `parallel_for().num_threads()` reports returns
// std::nullopt rather than being attempted, and a count of zero does too. Same
// rule the worker-set default follows: fewer workers is a DIFFERENT answer, not
// a slower one, so refuse instead of quietly searching with what is available.
//
// With one worker nothing is registered and every seam still runs on its
// default, which is what tests/enginelink.sh is for. Above one, a worker set
// over those workers is registered for the duration of the call and whatever
// was there before is put back.
//
// `nodes` is the whole search's node count: the main worker's alone when there
// is one worker, the sum over the set when there are more. Anything else would
// report a two-worker search as having done half its work.
//
// Not reentrant: the Workers and their scaffolding are process-static and
// reused across calls, so two callers at once share one root position. Changing
// the worker count rebuilds them, which is not cheap -- a Worker embeds the
// NNUE refresh cache -- so alternating counts per call is not a pattern to
// build on. Load the net before calling; the caller owns it.
struct GoResult {
    Move  bestMove;
    Value score;
    u64   nodes;
};

// `tbConfig` is what the POOL's root ranking would have produced. Defaulting it
// to a zero cardinality is what every caller wanting today's behaviour gets: the
// guard at the top of Step 6 short-circuits and the tablebase seam is never
// reached, which is exactly what a headless run without tables should do.
//
// PASS A NON-ZERO CARDINALITY AND THE SEAM IS REACHED PER NODE. That is the only
// way anything in-process can exercise the injected prober -- there is no root
// ranking on this path to set one -- so a harness asserting that a registered
// prober takes effect has to say so here. It is also the caller's promise that
// a prober IS registered: a cardinality without one reaches the default, which
// answers "no tablebases loaded" and costs a branch per node for nothing.
std::optional<GoResult> go(const Eval::NNUE::Network& net,
                           std::string_view           fen,
                           bool                       chess960,
                           int                        depth,
                           usize                      workers  = 1,
                           Tablebases::Config         tbConfig = {});

}  // namespace Search
}  // namespace Stockfish

#endif  // #ifndef SEARCH_GO_H_INCLUDED
