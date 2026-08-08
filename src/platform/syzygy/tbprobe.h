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

#ifndef TBPROBE_H
#define TBPROBE_H

#include <functional>
#include <string>
#include <vector>


#include "../../engine/searchoptions.h"
#include "../../engine/tb_source.h"

namespace Stockfish {
class Position;

using Depth = int;

namespace Search {
struct RootMove;
using RootMoves = std::vector<RootMove>;
}
}

namespace Stockfish::Tablebases {

// Config, WDLScore and ProbeState are search-facing values and live in
// engine/tb_source.h; this header re-exports them by including it.
extern int MaxCardinality;


void     init(const std::string& paths);
WDLScore probe_wdl(Position& pos, ProbeState* result);
int      probe_dtz(Position& pos, ProbeState* result);
bool     root_probe(Position&                    pos,
                    Search::RootMoves&           rootMoves,
                    bool                         rule50,
                    bool                         rankDTZ,
                    const std::function<bool()>& time_abort);
bool     root_probe_wdl(Position& pos, Search::RootMoves& rootMoves, bool rule50);
Config   rank_root_moves(
    const SearchOptions&            options,
    Position&                    pos,
    Search::RootMoves&           rootMoves,
    bool                         rankDTZ    = false,
    const std::function<bool()>& time_abort = []() { return false; });

}  // namespace Stockfish::Tablebases

#endif
