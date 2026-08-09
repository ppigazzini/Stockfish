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

#ifndef SEARCHOPTIONS_H_INCLUDED
#define SEARCHOPTIONS_H_INCLUDED

#include <string>

#include "basetypes.h"

namespace Stockfish {

// The options the engine reads, snapshotted by the shell before a search.
//
// This is the seam that lets the engine be driven without an option model: it
// is a value, not a reference into the UCI layer, so nothing here reaches
// ucioption.h. The shell fills it from its OptionsMap; anything else that wants
// to run a search -- an in-process harness, a parameter sweep -- fills it
// directly.
//
// EVERY FIELD DEFAULTS TO A WORKING VALUE, matching the option the shell
// registers for it in Engine::Engine. Keep the two in step: a default that
// drifts makes an unhosted search run with different parameters from the UCI
// engine, and both still produce a plausible number. A seam that defaults to a
// stub instead reads to a gate as a broken engine rather than as an unwired one.
//
// The values are read at go-setup and info-line cadence, never per node, which
// is why a snapshot costs nothing and needs no indirection.
struct SearchOptions {
    usize       threads          = 1;
    std::string numaPolicy       = "auto";
    usize       multiPV          = 1;
    int         skillLevel       = 20;
    bool        limitStrength    = false;
    int         elo              = 1320;
    int         moveOverhead     = 10;
    bool        syzygy50MoveRule = true;
    int         syzygyProbeDepth = 1;
    int         syzygyProbeLimit = 7;
    bool        showWDL          = false;
    int         nodestime        = 0;
    bool        ponder           = false;
};

}  // namespace Stockfish

#endif  // #ifndef SEARCHOPTIONS_H_INCLUDED
