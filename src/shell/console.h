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

#ifndef CONSOLE_H_INCLUDED
#define CONSOLE_H_INCLUDED

#include <iosfwd>

#include "../engine/basetypes.h"

// Process output and the debug counters that print through it.
//
// Shell rather than platform: this is the standard output stream of a process
// and a diagnostic dump printed onto it, neither of which the engine needs to
// search. Living in misc.h -- a platform file -- meant an engine file calling
// sync_cout produced an engine-to-PLATFORM link edge, which the zone check for
// engine-to-shell could not see. The misplacement was hiding the violation.
namespace Stockfish {

void dbg_hit_on(bool cond, int slot = 0);
void dbg_mean_of(i64 value, int slot = 0);
void dbg_stdev_of(i64 value, int slot = 0);
void dbg_extremes_of(i64 value, int slot = 0);
void dbg_correl_of(i64 value1, i64 value2, int slot = 0);
void dbg_print();
void dbg_clear();

enum SyncCout {
    IO_LOCK,
    IO_UNLOCK
};
std::ostream& operator<<(std::ostream&, SyncCout);

#define sync_cout std::cout << IO_LOCK
#define sync_endl std::endl << IO_UNLOCK

void sync_cout_start();
void sync_cout_end();

}  // namespace Stockfish

#endif  // #ifndef CONSOLE_H_INCLUDED
