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

#include "arena.h"

#include <cstdlib>

namespace Stockfish {

namespace {

// The default: plain aligned allocation. Correct, and slower than large pages,
// which is the right trade for something that runs when nothing was registered.
// It is deliberately NOT a stub -- engine/ has to be able to allocate on its own
// or the standalone link proves nothing.
void* default_alloc(usize bytes) {
    constexpr usize Alignment = 4096;
    const usize     rounded   = ((bytes + Alignment - 1) / Alignment) * Alignment;
#if defined(_WIN32)
    return _aligned_malloc(rounded, Alignment);
#else
    return std::aligned_alloc(Alignment, rounded);
#endif
}

void* default_alloc_hinted(usize bytes, bool) { return default_alloc(bytes); }

void default_free(void* p) {
#if defined(_WIN32)
    _aligned_free(p);
#else
    std::free(p);
#endif
}

Arena current = {default_alloc, default_alloc_hinted, default_free};

}  // namespace

const Arena& arena() { return current; }

void set_arena(const Arena& a) { current = a; }

}  // namespace Stockfish
