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

#include "parallel.h"

namespace Stockfish {

namespace {

// Run the work rather than refuse it: for a parallel-for, one thread is the
// same answer taking longer. See the header for why the worker-set seam's
// default must behave differently.
usize              default_num_threads() { return 1; }
usize              default_numa_nodes() { return 1; }
std::vector<usize> default_thread_numa_map() { return {}; }
void               default_run_on(usize, std::function<void()> fn) { fn(); }
void               default_wait_on(usize) {}

ParallelFor current = {default_num_threads, default_numa_nodes, default_thread_numa_map,
                       default_run_on, default_wait_on};

}  // namespace

const ParallelFor& parallel_for() { return current; }

void set_parallel_for(const ParallelFor& p) { current = p; }

}  // namespace Stockfish
