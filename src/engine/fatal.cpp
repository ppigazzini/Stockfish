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

#include "fatal.h"

#include <cstdlib>
#include <iostream>
#include <string_view>

namespace Stockfish {

namespace {

// stderr and exit, which is what every site did before it reached this seam.
// NOT the output-sink seam: a host that has replaced the sink has replaced where
// the engine SAYS things, and two of the callers here are allocation failures
// where the sink's implementation may itself be unable to run. Keep the two
// decisions apart -- Network::verify is the site that shows they are.
//
// Print nothing for an empty reason. A caller that has already emitted its
// diagnostic through a callback it was handed has nothing left to add, and a
// second line here would be output the unhosted engine never produced.
void default_abort(std::string_view reason) {
    if (!reason.empty())
        std::cerr << reason << std::endl;
}

// The initialiser is the address of a function, so `current` is CONSTANT-
// initialised and no static initialiser can observe it empty. parallel.cpp
// carries the same note and the reason: a dynamically-initialised seam read by
// another translation unit's static initialiser is a call through a null
// pointer, and the failure path is exactly where nobody looks.
Fatal current = {default_abort};

}  // namespace

const Fatal& fatal_source() { return current; }

void set_fatal_source(const Fatal& f) { current = f; }

void engine_abort(std::string_view reason) {
    fatal_source().abort_now(reason);

    // NOT an else, and not an assert. A host handler that returns has put the
    // caller back on a path that assumed it would not; every caller of this is
    // out of options by construction, so the only correct thing left is to
    // terminate. This line is what makes the [[noreturn]] on the declaration
    // true no matter what a host registers.
    std::exit(EXIT_FAILURE);
}

}  // namespace Stockfish
