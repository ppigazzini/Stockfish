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

#ifndef FATAL_H_INCLUDED
#define FATAL_H_INCLUDED

#include <string_view>

namespace Stockfish {

// What the engine does when it cannot continue, and the seam that lets a host
// decide instead.
//
// This is the sixth seam and it is not shaped like the other five. Those route
// a SERVICE the host provides; this routes a POLICY the engine was making on
// the host's behalf -- ending the process. A host embedding the engine cannot
// survive a failed Hash resize today: the engine calls exit() and the host's
// own error handling never runs.
//
// THE DEFAULT IS THE CURRENT BEHAVIOUR, printing to stderr and exiting, so an
// unhosted engine behaves exactly as it did and no caller has to change.

struct Fatal {
    // NOT [[noreturn]], and this is a language rule rather than a choice.
    // The attribute appertains to a FUNCTION DECLARATION; a member of
    // function-pointer type is a variable declaration, so there is nothing for
    // it to attach to. clang refuses it outright -- "'noreturn' attribute only
    // applies to functions" -- while gcc accepts it silently, so a header that
    // spelled it here would build under one compiler and not the other.
    //
    // The guarantee lives on engine_abort below instead.
    void (*abort_now)(std::string_view reason);
};

const Fatal& fatal_source();
void         set_fatal_source(const Fatal& f);

// END THE PROCESS, after giving the host its say.
//
// [[noreturn]] IS THE CONTRACT AND THE COMPILER CANNOT CARRY IT ACROSS THE SEAM.
// A host handler is an ordinary function that may return; every caller here is
// on a path that assumed it would not, and several are themselves [[noreturn]].
// So this wrapper TERMINATES AFTER CALLING OUT rather than trusting the handler,
// and the attribute stays here where the optimiser can still use it -- the same
// shape as tb_source.h's "probe_wdl MUST write *result on every path", written
// down for the same reason: a host gets no help from the compiler.
//
// Losing the attribute is a codegen change wearing a refactor. Every caller of a
// failing allocation grows a return path, so check it with tests/textequal.sh
// rather than by reading.
//
// `reason` is what the ENGINE still has to say. A site that has already emitted
// its diagnostic through a callback it was handed passes nothing, and the
// default prints nothing -- see Network::verify, which is the site that proves
// saying and terminating are separable.
[[noreturn]] void engine_abort(std::string_view reason);

}  // namespace Stockfish

#endif  // #ifndef FATAL_H_INCLUDED
