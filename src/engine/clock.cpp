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

#include "clock.h"

#include <chrono>

namespace Stockfish {

namespace {

// Tell the time from the standard library. std::chrono is not a host service,
// so an unregistered engine is correct rather than degraded; the seam is there
// for a HOST that wants to substitute a clock -- a deterministic one for a
// replay harness, a coarser one where the steady clock is expensive.
//
// Keep this the steady clock. TimeManagement::elapsed_time subtracts two
// readings, so a clock that can step backwards yields a negative elapsed time
// and check_time never trips its `elapsed > tm.maximum()` deadline.
TimePoint default_now() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

Clock current = {default_now};

}  // namespace

const Clock& clock_source() { return current; }

void set_clock_source(const Clock& c) { current = c; }

TimePoint now() { return clock_source().now(); }

}  // namespace Stockfish
