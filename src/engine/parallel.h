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

#ifndef PARALLEL_H_INCLUDED
#define PARALLEL_H_INCLUDED

#include <functional>
#include <vector>

#include "basetypes.h"

namespace Stockfish {

// A parallel-for over the host's workers, and nothing else.
//
// The callers are TranspositionTable::resize and ::clear, which zero the table
// split so that threads on a NUMA node clear a contiguous region -- that is why
// the seam exposes the numa map and not just a thread count. It is deliberately
// narrower than the search's relationship with the pool, which goes through
// WorkerSet.
//
// THE DEFAULT RUNS THE WORK, inline on the calling thread, reporting one thread
// and one node. For a parallel-for that is a correct implementation rather than
// a degradation: the table still gets cleared. It differs from the worker-set
// seam, where a single-worker default must REFUSE a larger count rather than
// silently search with fewer -- there, fewer workers is a different answer; here
// it is the same answer, slower.
struct ParallelFor {
    usize (*num_threads)();
    usize (*numa_nodes)();
    // Which NUMA node each thread is bound to, empty when the host does not know.
    std::vector<usize> (*thread_numa_map)();
    void (*run_on)(usize thread, std::function<void()> fn);
    void (*wait_on)(usize thread);
};

const ParallelFor& parallel_for();
void               set_parallel_for(const ParallelFor& p);

}  // namespace Stockfish

#endif  // #ifndef PARALLEL_H_INCLUDED
