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

#ifndef TB_SOURCE_H_INCLUDED
#define TB_SOURCE_H_INCLUDED

#include <functional>
#include <vector>

#include "types.h"

namespace Stockfish {

class Position;

namespace Search {
struct RootMove;
using RootMoves = std::vector<RootMove>;
}

struct SearchOptions;

namespace Tablebases {

// The probe RESULT TYPES live here, in the engine, and the platform prober
// re-exports them: what the search does with a WDL verdict is chess, not I/O.
// Adding a member to WDLScore or ProbeState changes a value the search branches
// on, so it is an engine change with a platform consequence, never the reverse.

struct Config {
    int   cardinality = 0;
    bool  rootInTB    = false;
    bool  useRule50   = false;
    Depth probeDepth  = 0;
};

enum WDLScore {
    WDLLoss        = -2,  // Loss
    WDLBlessedLoss = -1,  // Loss, but draw under 50-move rule
    WDLDraw        = 0,   // Draw
    WDLCursedWin   = 1,   // Win, but draw under 50-move rule
    WDLWin         = 2,   // Win
};

// Possible states after a probing operation
enum ProbeState {
    FAIL              = 0,   // Probe failed (missing file table)
    OK                = 1,   // Probe successful
    CHANGE_STM        = -1,  // DTZ should check the other side
    ZEROING_BEST_MOVE = 2    // Best move zeroes DTZ (capture or pawn move)
};

// Injecting the prober. Probing is disk I/O -- a platform service -- so the
// search reaches it through pointers the host registers.
//
// GENUINELY SAFE UNREGISTERED, which is a different guarantee from the other
// seams. "No tablebases are loaded" is exactly true with no prober attached, and
// a search that does not probe is the correct search, not a degraded one.
//
// THE COST TO WATCH IS CADENCE, NOT COUNT. probe_wdl sits in Step 6 of search(),
// reached per node whenever tables are loaded, which puts this seam on the hot
// path. The default bench cannot see it: with SyzygyPath empty the
// tbConfig.cardinality guard short-circuits before the call, so a bench
// measurement of this seam measures the guard. Measuring the call needs
// SyzygyPath pointed at a corpus and positions chosen to probe.
// WHAT A HOST MUST GUARANTEE. probe_wdl MUST write *result on every path,
// including every early return. The caller in search() branches on it to decide
// whether the returned WDLScore is a real tablebase verdict, so a prober that
// returns without writing turns an unrelated value into a tablebase cutoff and
// stores a fabricated score in the transposition table. Nothing catches it: the
// bench never sets SyzygyPath, so no gate here probes at all. The bundled
// default writes FAIL first and null-checks result; a host gets no such help
// from the compiler, which is why it is stated here.
struct TbSource {
    void* ctx;
    int (*max_cardinality)(void* ctx);
    WDLScore (*probe_wdl)(void* ctx, Position& pos, ProbeState* result);
    Config (*rank_root_moves)(void*                        ctx,
                              const SearchOptions&         options,
                              Position&                    pos,
                              Search::RootMoves&           rootMoves,
                              bool                         rankDTZ,
                              const std::function<bool()>& time_abort);
};

const TbSource& tb_source();
void            set_tb_source(const TbSource& t);

}  // namespace Tablebases
}  // namespace Stockfish

#endif  // #ifndef TB_SOURCE_H_INCLUDED
