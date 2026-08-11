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

#ifndef TIMEMAN_H_INCLUDED
#define TIMEMAN_H_INCLUDED


#include <limits>

#include "clock.h"
#include "basetypes.h"


namespace Stockfish {

enum Color : u8;

struct SearchOptions;

namespace Search {
struct LimitsType;
}

// The TimeManagement class computes the optimal time to think depending on
// the maximum available time, the game move number, and other parameters.
class TimeManagement {
   public:
    void init(Search::LimitsType& limits,
              Color               us,
              int                 ply,
              const SearchOptions& options,
              double&             originalTimeAdjust);

    TimePoint optimum() const;
    TimePoint maximum() const;
    template<typename FUNC>
    TimePoint elapsed(FUNC nodes) const {
        return useNodesTime ? TimePoint(nodes()) : elapsed_time();
    }
    TimePoint elapsed_time() const { return now() - startTime; };

    void clear();
    void advance_nodes_time(i64 nodes);

   private:
    // Every member a reader can reach carries a value this class wrote. init()
    // returns early whenever limits.time[us] is zero -- after startTime, before
    // the other two -- and use_time_management() does NOT exclude that case: it
    // is true when only the OPPOSING side has a clock. `go btime N` with White
    // to move therefore used to read two budgets out of storage nobody had
    // written, which memcheck reported at search.cpp's `elapsed > tm.maximum()`
    // and at its `min(totalTime, double(tm.maximum()))`.
    //
    // NoBound rather than zero, because the value chosen IS the behaviour on
    // that input. Zero is an instant move; NoBound is a search that runs until
    // something stops it, which is what the engine already did when the read
    // happened to find a large number, and it is the answer that cannot lose a
    // game on a clock the caller never gave. A real GUI sends both clocks; this
    // is what the malformed case means, stated once instead of decided by
    // whatever the heap held.
    static constexpr TimePoint NoBound = std::numeric_limits<TimePoint>::max() / 2;

    TimePoint startTime   = 0;
    TimePoint optimumTime = NoBound;
    TimePoint maximumTime = NoBound;

    i64  availableNodes = -1;     // When in 'nodes as time' mode
    bool useNodesTime   = false;  // True if we are in 'nodes as time' mode
};

}  // namespace Stockfish

#endif  // #ifndef TIMEMAN_H_INCLUDED
