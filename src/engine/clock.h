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

// A count of milliseconds. The engine's own type: time management compares,
// subtracts and stores these, and none of that is a host service. Keep it 64
// bits -- now() returns an absolute steady-clock reading, not a duration, and a
// signed 32-bit millisecond count wraps after about 25 days of host uptime.
using TimePoint = std::chrono::milliseconds::rep;
static_assert(sizeof(TimePoint) == sizeof(i64), "TimePoint should be 64 bits");

// Where the engine reads the clock.
//
// No link gate can police this seam. A host clock is read through an inline
// function, which leaves no undefined symbol behind, so neither
// tests/linkcheck.sh nor tests/enginelink.sh can see an engine file that reads
// one directly. Keep the readers pointed at now() below by hand.
//
// THE SEAM READS MICROSECONDS AND now() IS A QUOTIENT OF IT. Keep the fine
// reading the source of truth and the coarse one derived from it, so a host
// substitutes ONE function and both views move together.
//
// The resolution is load-bearing at one reader. syzygy_extend_pv's time_abort
// budgets itself against `Move Overhead`, whose range starts at 0, and at
// whole-millisecond resolution `2 * 0 > 0` is false -- so a millisecond seam
// lets that abort run a further millisecond past the deadline it exists to
// enforce. Give this seam a TimePoint and that reader has to read a host clock
// directly to stay correct, which no gate can see and which hands a replay
// harness a deterministic search with one wall-clock component in it.
//
// Do not close it by widening TimePoint instead: TimePoint is the type every
// constant time management owns is written in, so changing it is a functional
// change to all of them.
//
// The cadence is what makes an indirect call affordable, and NO READER IS ON
// THE PER-NODE PATH. The hottest is TimeManagement::elapsed_time, reached from
// check_time -- which throttles itself to one call per callsCnt nodes -- and
// from Worker::elapsed once per depth iteration and output_pv once per info
// line. The rest are colder: one reading per `go` for LimitsType::startTime and
// a few around the bench loop (uci.cpp), plus two function-local statics that
// initialise once (search.cpp). Add a reader to the per-node path and this
// becomes a per-node indirect call.
//
// THE DEFAULT IS THE REAL CLOCK, and it is the "same answer, slower" kind of
// default: an unregistered engine tells the time correctly, one indirect call
// slower than the host-registered one would. A default returning 0 would make
// every search believe no time had passed, which is a wrong answer dressed as a
// working one.
struct Clock {
    i64 (*now_us)();
};

const Clock& clock_source();
void         set_clock_source(const Clock& c);

// Microseconds since the steady clock's epoch. The only reader that needs this
// is the tablebase PV extension, whose budget is a fraction of `Move Overhead`.
i64 now_us();

// Milliseconds, the type time management is written in. A truncation of the
// above, so a substituted clock reaches both.
TimePoint now();

}  // namespace Stockfish

#endif  // #ifndef CLOCK_H_INCLUDED
