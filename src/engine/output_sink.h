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

#ifndef OUTPUT_SINK_H_INCLUDED
#define OUTPUT_SINK_H_INCLUDED

#include <string_view>

namespace Stockfish {

// Where the engine says things.
//
// The engine has two kinds of thing to say and they are not the same: a line it
// composed itself, and a request that the host dump its own diagnostic counters.
// The second is not a line the engine can write -- the counters live in the
// shell -- so it is a separate hook rather than a formatted string.
//
// THE DEFAULT PRINTS. It writes to stdout with no lock, so two threads emitting
// at once can interleave one line into another; a host that searches on more
// than one thread registers a synchronised sink. A null sink would be silence
// instead, and silence reads to a gate as a hung engine rather than as a wiring
// fault -- the failure that is expensive to diagnose.
struct OutputSink {
    void (*line)(std::string_view);
    void (*debug_dump)();
};

const OutputSink& output_sink();
void              set_output_sink(const OutputSink& s);

// Convenience for the call sites, which all emit one whole line.
void emit_line(std::string_view text);

}  // namespace Stockfish

#endif  // #ifndef OUTPUT_SINK_H_INCLUDED
