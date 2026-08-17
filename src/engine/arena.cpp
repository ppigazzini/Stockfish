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

#include <cstdio>

#include <atomic>
#include "fatal.h"

#include <cassert>
#include <cstdlib>
#include <limits>

// The guard platform/memory.cpp carries, repeated rather than included: these
// toolchains do not declare std::aligned_alloc, and engine/ must not include a
// platform header. Without it this file does not compile at all on an ARCH the
// Makefile enumerates -- e2k is in the ARCH list, and any libstdc++ configured
// without _GLIBCXX_HAVE_ALIGNED_ALLOC is in the same position.
#if defined(__APPLE__) || defined(__ANDROID__) || defined(__OpenBSD__) \
  || (defined(__GLIBCXX__) && !defined(_GLIBCXX_HAVE_ALIGNED_ALLOC) && !defined(_WIN32)) \
  || defined(__e2k__)
    #define ARENA_POSIX_ALIGNED_ALLOC
    #include <stdlib.h>
#endif

namespace Stockfish {

namespace {

// Allocate page-aligned with plain malloc. Correct, and slower than large pages,
// which is the right trade for something that runs when nothing was registered.
// Keep it a working allocator rather than a stub: engine/ must be able to
// allocate on its own, or tests/enginelink.sh links an engine it cannot run.
void* default_alloc(usize bytes) {
    constexpr usize Alignment = 4096;

    // Rounding up is itself arithmetic on an untrusted size: a request within
    // Alignment of the top wraps to a small allocation. Refuse it here so the
    // caller's null check reports it.
    if (bytes > std::numeric_limits<usize>::max() - (Alignment - 1))
        return nullptr;

    const usize rounded = ((bytes + Alignment - 1) / Alignment) * Alignment;
#if defined(_WIN32)
    return _aligned_malloc(rounded, Alignment);
#elif defined(ARENA_POSIX_ALIGNED_ALLOC)
    void* mem = nullptr;
    return posix_memalign(&mem, Alignment, rounded) == 0 ? mem : nullptr;
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

// Relaxed: the count is only ever compared against zero at setup cadence, and
// no other state is published through it. Atomic rather than a plain integer
// because the engine allocates from worker threads as well as the main one, and
// a debug counter that races is a debug counter that lies.
std::atomic<usize> liveBlocks{0};

}  // namespace

const Arena& arena() { return current; }

void  arena_block_acquired() { liveBlocks.fetch_add(1, std::memory_order_relaxed); }
void  arena_block_released() { liveBlocks.fetch_sub(1, std::memory_order_relaxed); }
usize arena_live_blocks() { return liveBlocks.load(std::memory_order_relaxed); }

void set_arena(const Arena& a) {
    // Setup cadence, so the check is free. A zero would make every hugePageHint
    // true rather than none of them, which is a wrong answer that still runs.
    assert(a.hugePageBytes != 0);

    // The ordering invariant this header states, now enforced where it can be
    // seen. Swapping the arena under a live block means that block is released
    // through an allocator that did not produce it.
    assert(arena_live_blocks() == 0
           && "set_arena while a block from the previous arena is still live");

    current = a;
}

// A STACK BUFFER AND snprintf, not a std::string or a stream. Both callers here
// are reporting that an allocation FAILED, so building the message must not be
// an allocation: with -fno-exceptions a std::string that cannot get its buffer
// aborts, and the report the operator needs is lost to a second failure inside
// the first one. 128 bytes holds either message with two 20-digit numbers in it,
// and snprintf truncates rather than overruns.
void arena_alloc_failed(usize bytes) {
    char buf[128];
    std::snprintf(buf, sizeof(buf), "Failed to allocate %llu bytes.",
                  static_cast<unsigned long long>(bytes));
    engine_abort(buf);
}

void arena_size_overflow(usize num, usize elementSize) {
    char buf[128];
    std::snprintf(buf, sizeof(buf),
                  "Refusing an array of %llu x %llu bytes: the byte count does not fit a size_t.",
                  static_cast<unsigned long long>(num),
                  static_cast<unsigned long long>(elementSize));
    engine_abort(buf);
}

}  // namespace Stockfish
