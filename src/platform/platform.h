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

#ifndef PLATFORM_H_INCLUDED
#define PLATFORM_H_INCLUDED

#include <chrono>

#include "../engine/basetypes.h"

// Reach TimePoint and now() through here: both are declared in engine/clock.h,
// because comparing and storing a time is the engine's job, and this include is
// what makes them visible to a file that includes platform.h.
#include "../engine/clock.h"

#if !defined(NO_PREFETCH) && (defined(_MSC_VER) || defined(__INTEL_COMPILER))
    #include <immintrin.h>
#endif

// Spell the compiler's no-aliasing qualifier. RESTRICT is a macro, not a
// keyword, so include-what-you-use cannot attribute it to this header: a file
// that writes RESTRICT must include platform.h itself. Inheriting it through
// another header compiles until that header stops including this one, and then
// fails with RESTRICT read as an identifier.
#ifdef __GNUC__
    #define RESTRICT __restrict__
#elif defined(_MSC_VER)
    #define RESTRICT __restrict
#else
    #define RESTRICT
#endif

namespace Stockfish {

// True if and only if the machine RUNNING this binary is little-endian: the
// initialiser reads Le's first byte at run time, so a cross-compile reports the
// target's byte order and never the build host's.
static inline const u16  Le             = 1;
static inline const bool IsLittleEndian = *reinterpret_cast<const char*>(&Le) == 1;


// Prefetch hint enums for explicit call-site control.
enum class PrefetchRw {
    READ,
    WRITE
};

// NOTE: PrefetchLoc controls locality / cache level, not whether a prefetch
//       is issued. In particular, PrefetchLoc::NONE maps to a non-temporal /
//       lowest-locality prefetch (Intel: _MM_HINT_NTA, GCC/Clang: locality = 0)
//       and therefore still performs a prefetch. To completely disable
//       prefetching, define NO_PREFETCH so that prefetch() becomes a no-op.
enum class PrefetchLoc {
    NONE,      // Non-temporal / no cache locality (still issues a prefetch)
    LOW,       // Low locality (e.g. T2 / L2)
    MODERATE,  // Moderate locality (e.g. T1 / L1)
    HIGH       // High locality (e.g. T0 / closest cache)
};

// Preloads the given address into cache. This is a non-blocking
// function that doesn't stall the CPU waiting for data to be loaded from memory,
// which can be quite slow.
#ifdef NO_PREFETCH
template<PrefetchRw RW = PrefetchRw::READ, PrefetchLoc LOC = PrefetchLoc::HIGH>
void prefetch(const void*) {}
#elif defined(_MSC_VER) || defined(__INTEL_COMPILER)

constexpr int get_intel_hint(PrefetchRw rw, PrefetchLoc loc) {
    if (rw == PrefetchRw::WRITE)
    {
    #ifdef _MM_HINT_ET0
        return _MM_HINT_ET0;
    #else
        // Fallback when write-prefetch hint is not available: use T0
        return _MM_HINT_T0;
    #endif
    }
    switch (loc)
    {
    case PrefetchLoc::NONE :
        return _MM_HINT_NTA;
    case PrefetchLoc::LOW :
        return _MM_HINT_T2;
    case PrefetchLoc::MODERATE :
        return _MM_HINT_T1;
    case PrefetchLoc::HIGH :
        return _MM_HINT_T0;
    default :
        return _MM_HINT_T0;
    }
}

template<PrefetchRw RW = PrefetchRw::READ, PrefetchLoc LOC = PrefetchLoc::HIGH>
void prefetch(const void* addr) {
    _mm_prefetch(static_cast<const char*>(addr), get_intel_hint(RW, LOC));
}
#else
template<PrefetchRw RW = PrefetchRw::READ, PrefetchLoc LOC = PrefetchLoc::HIGH>
void prefetch(const void* addr) {
    __builtin_prefetch(addr, static_cast<int>(RW), static_cast<int>(LOC));
}
#endif



// Stringify a macro's VALUE rather than its name -- the two-step is what makes
// the argument expand first. Here for the same reason as the attribute below:
// it is preprocessor plumbing, and engine/nnue/network.cpp needs it for the
// DEFAULT_NNUE_DIRECTORY knob while platform/misc.cpp needs it for the build
// stamp. Neither wants the drawer.
#define stringify2(x) #x
#define stringify(x) stringify2(x)

// The always-inline attribute, here rather than in misc.h because it is a
// property of the COMPILER and this is the compiler header. It sat in the
// drawer, and three engine/ files included a platform grab-bag for this macro
// and nothing else.
#if defined(__GNUC__)
    #define sf_always_inline __attribute__((always_inline))
#elif defined(_MSC_VER)
    #define sf_always_inline __forceinline
#else
    // do nothing for other compilers
    #define sf_always_inline
#endif

}  // namespace Stockfish

#endif  // #ifndef PLATFORM_H_INCLUDED
