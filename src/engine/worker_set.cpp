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

#include "worker_set.h"

namespace Stockfish {

namespace {

// Report no workers: with no host attached there are none to hand out. Unlike
// the parallel-for's default, which runs the work inline, a worker set cannot
// honestly pretend -- fewer workers is a DIFFERENT answer, not the same answer
// more slowly. A host that cannot supply the requested count must therefore
// REFUSE it rather than silently search with fewer threads: a degraded run still
// produces a number, and the number looks fine.
//
// Every accessor here must tolerate a null ctx, since that is what `current`
// carries until set_worker_set runs.

void  noop(void*) {}
u64   zero_u64(void*) { return 0; }
usize zero_usize(void*) { return 0; }

Search::Worker* no_worker(void*, usize) { return nullptr; }

WorkerSet current = {nullptr, noop, noop, zero_u64, zero_u64, zero_usize, no_worker};

}  // namespace

const WorkerSet& worker_set() { return current; }

void set_worker_set(const WorkerSet& w) { current = w; }

}  // namespace Stockfish
