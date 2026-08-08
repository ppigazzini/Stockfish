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

#include "output_sink.h"

#include <iostream>

namespace Stockfish {

namespace {

// Prints. See the header: a discarding default would be silence, and silence is
// the failure mode that costs the most to diagnose.
void default_line(std::string_view text) { std::cout << text << std::endl; }

// Nothing to dump: the counters belong to the host. This one IS a no-op, and
// legitimately so -- the engine is asking whether anybody keeps such counters,
// and standalone the answer is no.
void default_debug_dump() {}

OutputSink current = {default_line, default_debug_dump};

}  // namespace

const OutputSink& output_sink() { return current; }

void set_output_sink(const OutputSink& s) { current = s; }

void emit_line(std::string_view text) { output_sink().line(text); }

}  // namespace Stockfish
