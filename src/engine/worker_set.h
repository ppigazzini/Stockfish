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
// SHAPE TAKEN FROM ../mcfish's worker_set.h, including the two decisions that
// are easy to get wrong:
//
// A ctx POINTER rather than a file-scope global. A function pointer cannot
// capture, so the alternative is a hidden global -- which the parallel-for seam
// used, and which makes two engines in one process impossible.
//
// The stop flag is handed over as a POINTER, not read through a getter.
// Search::search reads it seventeen times, several of them per node, and an
// indirect call there would be a real cost on the hottest path in the program.
// The engine fetches the pointer once and loads the atomic directly, so the
// seam costs nothing where it would actually be measured.
struct WorkerSet {
    void* ctx;

    void (*start_searching)(void* ctx);
    void (*wait_for_search_finished)(void* ctx);
    u64 (*nodes_searched)(void* ctx);
    u64 (*tb_hits)(void* ctx);
    usize (*count)(void* ctx);
    Search::Worker* (*at)(void* ctx, usize index);

    // Read per node. Handed over once; never called on the hot path.
    std::atomic<bool>* (*stop_flag)(void* ctx);
    std::atomic<bool>* (*increase_depth_flag)(void* ctx);
};

const WorkerSet& worker_set();
void             set_worker_set(const WorkerSet& w);

}  // namespace Stockfish

#endif  // #ifndef WORKER_SET_H_INCLUDED
