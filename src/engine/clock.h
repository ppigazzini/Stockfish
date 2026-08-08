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

#ifndef CLOCK_H_INCLUDED
#define CLOCK_H_INCLUDED

#include <chrono>

#include "basetypes.h"

namespace Stockfish {

// A value in milliseconds. The engine's own time type, declared here rather
// than in the platform because the engine is what speaks it -- time management
// compares, subtracts and stores these, and none of that is a host service.
using TimePoint = std::chrono::milliseconds::rep;
static_assert(sizeof(TimePoint) == sizeof(i64), "TimePoint should be 64 bits");

// Where the engine reads the clock.
//
// This seam closes no link edge and never will: the platform's now() is inline,
// so the three engine callers compiled it in place and no symbol crossed the
// boundary for a gate to notice. That is the whole reason it is worth doing by
// hand -- one direct call anywhere in engine/ keeps the dependency whole,
// however empty the baseline looks.
//
// The cadence is why an indirect call is affordable here. Two of the three
// readers are once-per-process static initialisers; the third is
// TimeManagement::elapsed_time, reached from check_time, which runs once per 512
// nodes. Nothing on the per-node path reads a clock.
//
// THE DEFAULT IS THE REAL CLOCK, and it is the "same answer, slower" kind of
// default: an unregistered engine tells the time correctly, one indirect call
// slower than the host-registered one would. A default returning 0 would make
// every search believe no time had passed, which is a wrong answer dressed as a
// working one.
struct Clock {
    TimePoint (*now)();
};

const Clock& clock_source();
void         set_clock_source(const Clock& c);

// Convenience for the call sites. Named now() so the readers keep reading the
// way they did; the difference is which zone owns the declaration.
TimePoint now();

}  // namespace Stockfish

#endif  // #ifndef CLOCK_H_INCLUDED
