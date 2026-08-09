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

#ifndef WORKER_SET_H_INCLUDED
#define WORKER_SET_H_INCLUDED

#include <atomic>

#include "basetypes.h"

namespace Stockfish {

namespace Search {
class Worker;
}

// The set of workers the search runs on: lifecycle and dispatch, and nothing
// that knows what a good move is. The best-move vote is Search::best_worker,
// on this side, reaching the set through count and at.
//
// A ctx POINTER rather than a file-scope global. A function pointer cannot
// capture, so the alternative is a hidden global -- which the parallel-for seam
// used, and which makes two engines in one process impossible.
//
// THE STOP FLAG IS NOT HERE. It is read per node, so it reaches the search as a
// std::atomic<bool>& in SharedState, fixed at construction. Routing it through
// this struct instead -- even handing over the address once per search rather
// than calling per node -- cost clang 2.4 instructions per node, because a
// pointer member must be reloaded after any call that might alias the worker
// while a reference member need not be. Measured, not assumed.
struct WorkerSet {
    void* ctx;

    void (*start_searching)(void* ctx);
    void (*wait_for_search_finished)(void* ctx);
    u64 (*nodes_searched)(void* ctx);
    u64 (*tb_hits)(void* ctx);
    usize (*count)(void* ctx);
    Search::Worker* (*at)(void* ctx, usize index);
};

const WorkerSet& worker_set();
void             set_worker_set(const WorkerSet& w);

}  // namespace Stockfish

#endif  // #ifndef WORKER_SET_H_INCLUDED
