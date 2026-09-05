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

#ifndef COMPILER_H_INCLUDED
#define COMPILER_H_INCLUDED

#include "basetypes.h"

// Reach TimePoint and now() through here: both are declared in clock.h, because
// comparing and storing a time is the engine's job, and this include is what
// makes them visible to a file that includes compiler.h.
#include "clock.h"

#if !defined(NO_PREFETCH) && (defined(_MSC_VER) || defined(__INTEL_COMPILER))
    #include <immintrin.h>
#endif

// Spell the compiler's no-aliasing qualifier. RESTRICT is a macro, not a
// keyword, so include-what-you-use cannot attribute it to this header: a file
// that writes RESTRICT must include compiler.h itself. Inheriting it through
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

// The no-stack-protector attribute, here for the reason sf_always_inline is:
// it is a property of the COMPILER. It had three identical definitions -- in
// search.h, in nnue/nnue_architecture.h and in movepick.cpp -- each with its own
// empty fallback, and that shape is a defect rather than duplication. An empty
// fallback cannot fail to compile: a file that reaches the macro through an
// include chain nothing states keeps building when the chain breaks, silently
// drops the attribute, and the frame keeps a canary nobody measures again.
// evaluate.cpp was found in exactly that state.
//
// Like RESTRICT above, a macro cannot be attributed to a header by
// include-what-you-use, so a file that WRITES SF_NO_STACK_PROTECTOR must include
// compiler.h itself rather than inherit it.
//
// Why each function is exempt is a property of that function, so the argument
// stays at the use site; only the spelling lives here.
#if defined(__has_attribute)
    #if __has_attribute(no_stack_protector)
        #define SF_NO_STACK_PROTECTOR __attribute__((no_stack_protector))
    #endif
#endif
#if !defined(SF_NO_STACK_PROTECTOR)
    #define SF_NO_STACK_PROTECTOR
#endif

// The always-inline attribute, here because it is a property of the COMPILER and
// this is the compiler header.
#if defined(__GNUC__)
    #define sf_always_inline inline __attribute__((always_inline))
#elif defined(_MSC_VER)
    #define sf_always_inline __forceinline
#else
    // plain inline for other compilers
    #define sf_always_inline inline
#endif

// The cold-path attribute, here for the same reason sf_always_inline is. A
// function marked with it is kept out of line and out of the hot path's
// straight-line code; the caller decides which of its arms is rare, so only the
// spelling lives here.
//
// An empty fallback costs a layout hint and nothing else, which is why this one
// is allowed to be empty where SF_NO_STACK_PROTECTOR's is not.
#if defined(__GNUC__)
    #define sf_cold_path __attribute__((noinline, cold))
#elif defined(_MSC_VER)
    #define sf_cold_path __declspec(noinline)
#else
    #define sf_cold_path
#endif

}  // namespace Stockfish

#endif  // #ifndef COMPILER_H_INCLUDED
