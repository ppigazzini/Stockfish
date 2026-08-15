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

#include "timeman.h"

#include <algorithm>
#include <cassert>
#include <cmath>

#include "search.h"
#include "searchoptions.h"

namespace Stockfish {

TimePoint TimeManagement::optimum() const { return optimumTime; }
TimePoint TimeManagement::maximum() const { return maximumTime; }

void TimeManagement::clear() {
    availableNodes = -1;  // When in 'nodes as time' mode
}

void TimeManagement::advance_nodes_time(i64 nodes) {
    assert(useNodesTime);
    availableNodes = std::max(i64(0), availableNodes - nodes);
}

// Called at the beginning of the search and calculates
// the bounds of time allowed for the current game ply. We currently support:
//      1) x basetime (+ z increment)
//      2) x moves in y seconds (+ z increment)
void TimeManagement::init(Search::LimitsType& limits,
                          Color               us,
                          int                 ply,
                          const SearchOptions& options,
                          double&             originalTimeAdjust) {
    TimePoint npmsec = TimePoint(options.nodestime);

    // If we have no time, we don't need to fully initialize TM.
    // startTime is used by movetime and useNodesTime is used in elapsed calls.
    startTime    = limits.startTime;
    useNodesTime = npmsec != 0;

    // elapsed() returns NODES while nodestime is in force, and check_time
    // compares it against limits.movetime, which is milliseconds and was never
    // converted: `setoption name nodestime value 600` then `go movetime 1000`
    // stopped at 1496 nodes and 5 ms of a 1000 ms budget. Convert it here,
    // beside useNodesTime and BEFORE the early return below -- the reported
    // case carries no clock at all, so anything placed after the return never
    // runs on it. limits is built fresh by parse_limits for each `go`, so this
    // scales once.
    if (useNodesTime)
        limits.movetime *= npmsec;

    // No clock for the side to move. Write the budgets anyway: leaving them is
    // not "no time management", it is the PREVIOUS search's time management.
    // `go wtime 200 btime 200` followed by `go btime 1000` then stops the second
    // search at depth 4 in about a millisecond, spending a budget that belonged
    // to the move before it.
    if (limits.time[us] == 0)
    {
        optimumTime = maximumTime = NoBound;
        return;
    }

    TimePoint moveOverhead = TimePoint(options.moveOverhead);

    // optScale is a percentage of available time to use for the current move.
    // maxScale is a multiplier applied to optimumTime.
    double optScale, maxScale;

    // If we have to play in 'nodes as time' mode, then convert from time
    // to nodes, and use resulting values in time management formulas.
    // WARNING: to avoid time losses, the given npmsec (nodes per millisecond)
    // must be much lower than the real engine speed.
    if (useNodesTime)
    {
        if (availableNodes == -1)                       // Only once at game start
            availableNodes = npmsec * limits.time[us];  // Time is in msec

        // Convert from milliseconds to nodes
        limits.time[us] = TimePoint(availableNodes);
        limits.inc[us] *= npmsec;
        limits.npmsec = npmsec;
        moveOverhead *= npmsec;
    }

    // These numbers are used where multiplications, divisions,
    // or comparisons with constants are involved.
    const i64       scaleFactor = useNodesTime ? npmsec : 1;
    const TimePoint scaledTime  = std::max(TimePoint(1), limits.time[us] / scaleFactor);

    // Maximum move horizon
    int mtg = limits.movestogo ? std::min(limits.movestogo, 50) : 50;

    // If less than one second, gradually reduce mtg.
    // In cyclic time controls we keep the actual movestogo as horizon.
    if (scaledTime < 1000 && limits.movestogo == 0)
        mtg = int(scaledTime * 0.05);

    // Make sure timeLeft is > 0 since we may use it as a divisor
    TimePoint timeLeft = std::max(TimePoint(1), limits.time[us] + limits.inc[us] * (mtg - 1)
                                                  - moveOverhead * (2 + mtg));

    // x basetime (+ z increment)
    // If there is a healthy increment, timeLeft can exceed the actual available
    // game time for the current move, so also cap to a percentage of available game time.
    if (limits.movestogo == 0)
    {
        // Extra time according to timeLeft
        if (originalTimeAdjust < 0)
            originalTimeAdjust = 0.3272 * std::log10(timeLeft) - 0.4141;

        // Calculate time constants based on current time left.
        double logTimeInSec = std::log10(scaledTime / 1000.0);
        double optConstant  = std::min(0.0029869 + 0.00033554 * logTimeInSec, 0.004905);
        double maxConstant  = std::max(3.3744 + 3.0608 * logTimeInSec, 3.1441);

        optScale = std::min(0.012112 + std::pow(ply + 3.22713, 0.46866) * optConstant,
                            0.19404 * limits.time[us] / timeLeft)
                 * originalTimeAdjust;

        maxScale = std::min(6.873, maxConstant + ply / 12.352);
    }

    // x moves in y seconds (+ z increment)
    else
    {
        optScale = std::min((0.88 + ply / 116.4) / mtg, 0.88 * limits.time[us] / timeLeft);
        maxScale = 1.3 + 0.11 * mtg;
    }

    // Limit the maximum possible time for this move
    optimumTime = TimePoint(std::max(1.0, optScale * timeLeft));
    maximumTime =
      TimePoint(std::max(double(optimumTime), std::min(0.8097 * limits.time[us] - moveOverhead,
                                                       maxScale * optimumTime)));

    if (options.ponder)
        optimumTime += optimumTime / 4;
}

}  // namespace Stockfish
