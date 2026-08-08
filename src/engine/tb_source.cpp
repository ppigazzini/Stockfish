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

#include "tb_source.h"

namespace Stockfish::Tablebases {

namespace {

// "No tablebases are loaded" is exactly true with no prober attached, so these
// need no registration for correctness -- see the header.
int      no_tables(void*) { return 0; }
WDLScore no_probe(void*, Position&, ProbeState* result) {
    if (result)
        *result = FAIL;
    return WDLDraw;
}
Config no_rank(void*, const SearchOptions&, Position&, Search::RootMoves&, bool,
               const std::function<bool()>&) {
    return Config{};
}

TbSource current = {nullptr, no_tables, no_probe, no_rank};

}  // namespace

const TbSource& tb_source() { return current; }

void set_tb_source(const TbSource& t) { current = t; }

}  // namespace Stockfish::Tablebases
