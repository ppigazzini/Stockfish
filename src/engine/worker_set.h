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
// A ctx POINTER so the host needs no global of its own. A function pointer
// cannot capture, so without a ctx the host must park its pool somewhere the
// callbacks can find it -- which is the shape the parallel-for seam forces, and
// `hostPool` in shell/engine.cpp is exactly that.
//
// It does NOT make two engines in one process work: `current` in worker_set.cpp
// is process-wide, so a second set_worker_set replaces the first engine's set
// and the first engine then dispatches onto the second's pool. Fixing that
// means giving the seam an owner, not a ctx.
//
// THE STOP FLAG IS NOT HERE. It is read per node, so it reaches the search as a
// std::atomic<bool>& in SharedState, fixed at construction. Route it through
// this struct instead -- even handing over the address once per search rather
// than calling per node -- and the per-node read becomes a load through a
// pointer member, which the compiler must reload after any call that might
// alias the worker; a reference fixed at construction needs no reload. Any move
// in that direction is a per-node cost: measure it with tests/perfbudget.sh.
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
