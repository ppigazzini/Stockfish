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

#ifndef HOST_H_INCLUDED
#define HOST_H_INCLUDED

#include "arena.h"
#include "clock.h"
#include "fatal.h"
#include "output_sink.h"
#include "parallel.h"
#include "tb_source.h"
#include "worker_set.h"

namespace Stockfish {

// Every seam the host fills, in one object, so a search can be handed the set it
// was built against instead of reaching seven globals for it.
//
// WHY A SNAPSHOT AND NOT THE STORAGE. Each seam keeps its own registration
// exactly where it is; this copies them. That is the whole design and it is
// worth stating, because collecting the seven registrations INTO one object is
// the obvious shape and it is the wrong one:
//
//   * it moves seven default sets across translation units, and each one is
//     constant-initialised on purpose -- parallel.cpp says why, and the failure
//     is a static initialiser in another TU reading a zeroed struct and calling
//     through a null pointer;
//   * it merges seven per-seam contracts into one file, which then has to
//     include every seam's dependencies -- <chrono>, <iostream>, Position,
//     RootMoves, the arena's platform conditionals;
//   * and tests/textequal.sh cannot judge it. Five of the six statics carry the
//     same demangled name, `Stockfish::(anonymous namespace)::current`, and the
//     gate normalises a rip-relative operand to its target's NAME, so it reports
//     IDENTICAL whether the merge went right or wrong.
//
// A snapshot has none of that. Nothing existing moves, so the change is free by
// construction rather than by measurement.
//
// WHAT IT BUYS, EXACTLY AS NARROW AS IT IS. A search reading its own Host reads
// the seams that were registered when it was built. Two engines in one process
// each snapshot their own, and the second one's set_* calls no longer reach into
// the first one's search. What it does NOT do is make the registration globals
// per-engine: they stay process-wide, and a second registration still overwrites
// the first. It stops mattering only because nothing reads them after
// construction.
//
// TAKE IT AFTER REGISTERING AND BEFORE SEARCHING. A snapshot taken too early
// holds defaults the host meant to replace, and nothing says so -- the search
// runs, allocates from the fallback arena and reports no workers, which is a
// working engine giving a different answer.
struct Host {
    Arena                arena;
    OutputSink           output;
    ParallelFor          parallel;
    WorkerSet            workers;
    Tablebases::TbSource tb;
    Clock                clock;
    Fatal                fatal;
};

// Read every seam as it is registered right now. With nothing registered this
// returns the defaults, because that is what each accessor returns.
Host current_host();

}  // namespace Stockfish

#endif  // #ifndef HOST_H_INCLUDED
