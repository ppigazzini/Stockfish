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

#ifndef ARENA_H_INCLUDED
#define ARENA_H_INCLUDED

#include <algorithm>
#include <limits>
#include <memory>
#include <new>
#include <type_traits>
#include <utility>

#include "basetypes.h"
#include "types.h"

namespace Stockfish {

// The engine's page allocator, and the seam that keeps engine/ free of the host.
//
// Route every engine allocation through here rather than through the platform
// allocator: the transposition table and the history banks both want large
// pages, and only the host knows whether it can hand them out.
//
// THE DEFAULT IS A WORKING ALLOCATOR, not a stub, which is what lets engine/ run
// with nothing registered. It is plain aligned malloc: correct, and slower than
// large pages, which is the right trade for a fallback.
//
// REGISTER IT BEFORE ANYTHING ELSE. A block taken from this default and released
// by the host's implementation is heap corruption with no diagnostic, so
// set_arena() must run before the first allocation and must never be called
// while anything allocated from the previous arena is still live.

// The huge page size the DEFAULT arena reports. A host that maps a different
// size registers its own; this value is what the unhosted engine computes with,
// and it matches the platform allocator's own so a hosted and an unhosted engine
// reach the same decision.
constexpr usize DefaultHugePageBytes = usize(1) << 30;

// WHAT A HOST MUST GUARANTEE. alloc and alloc_hinted return memory aligned to at
// least 4096 bytes, which is what the default below provides and what every
// caller is entitled to assume. Nothing checks it: ASSERT_ALIGNED is compiled
// out under NDEBUG, so an under-aligned block is handed to placement new and the
// fault arrives later inside the NNUE's aligned vector loads, with nothing
// pointing back at the registration. A host that wraps its own allocator with a
// header must make that header a whole multiple of the alignment, because the
// pointer it hands out only keeps the raw block's alignment if it is.
struct Arena {
    void* (*alloc)(usize bytes);
    void* (*alloc_hinted)(usize bytes, bool hugePageHint);
    void (*free)(void* p);

    // How large one huge page is, so a caller weighing alloc_hinted against
    // oversubscription can do the arithmetic without naming a host constant.
    // The POLICY stays with the caller -- how many pages per NUMA node are worth
    // asking for is a property of the table, not of the machine.
    //
    // A DEFAULT MEMBER INITIALISER, deliberately: Arena is filled by braced
    // aggregate initialisation at every registration site, and a field a host
    // forgets would otherwise be zero. Zero here is not a small huge page, it is
    // a divide-free comparison that is true for every size -- so the hint would
    // be set on every allocation and the run would still produce a number. Never
    // register a zero.
    usize hugePageBytes = DefaultHugePageBytes;
};

const Arena& arena();
void         set_arena(const Arena& a);

// An allocation this layer cannot satisfy is reported and ends the process, the
// way TranspositionTable::resize already models. There is no continuing past
// it: ASSERT_ALIGNED is NOT a null check -- it expands to `ptr % alignment == 0`
// and `0 % n == 0` is true -- so an asserts-enabled build walks into the
// placement new at address 0 with no assert fired, which is the configuration
// that was supposed to catch it.
[[noreturn]] void arena_alloc_failed(usize bytes);
[[noreturn]] void arena_size_overflow(usize num, usize elementSize);

// Outstanding blocks taken from the CURRENT arena, so set_arena can refuse a
// swap while one is live. Declared only in an asserts-enabled build: every
// counter update below is inside #ifndef NDEBUG, so the shipped allocation path
// is the bare indirect call it was and this costs nothing to ship.
//
// The header states the invariant -- "must never be called while anything
// allocated from the previous arena is still live" -- and until this counter
// existed nothing could see a violation. A block taken from one allocator and
// released by another is heap corruption with no diagnostic, which is the one
// failure on this seam that reports nothing at all.
// Declared and defined unconditionally, and called only under !NDEBUG. Making
// the SYMBOL's existence depend on NDEBUG instead splits the ABI between build
// modes: a debug object then wants a symbol a release object does not define,
// and mixing the two -- which `make build debug=yes` over an existing release
// tree does, because the flag change alone does not force a rebuild -- fails to
// link with a message about the counter rather than about the mode.
//
// Release still pays nothing: the call sites below are inside #ifndef NDEBUG, so
// no call is emitted at all and the definitions are unreferenced.
void  arena_block_acquired();
void  arena_block_released();
usize arena_live_blocks();

// Free functions, so a deleter can name one without capturing. EVERY arena
// operation goes through these three: a caller reaching arena() directly is a
// block the counter never sees, which is how tt.cpp escaped it.
inline void* arena_alloc(usize bytes) {
    void* p = arena().alloc(bytes);
#ifndef NDEBUG
    if (p)
        arena_block_acquired();
#endif
    return p;
}

inline void* arena_alloc_hinted(usize bytes, bool hugePageHint) {
    void* p = arena().alloc_hinted(bytes, hugePageHint);
#ifndef NDEBUG
    if (p)
        arena_block_acquired();
#endif
    return p;
}

inline void arena_free(void* p) {
#ifndef NDEBUG
    if (p)
        arena_block_released();
#endif
    arena().free(p);
}

// Placement-new and destructor plumbing, parameterised on the allocator. Pure
// pointer arithmetic with no OS in it.
template<typename T, typename FREE_FUNC>
void memory_deleter(T* ptr, FREE_FUNC free_func) {
    if (!ptr)
        return;

    // Explicitly needed to call the destructor
    if constexpr (!std::is_trivially_destructible_v<T>)
        ptr->~T();

    free_func(ptr);
}

template<typename T, typename FREE_FUNC>
void memory_deleter_array(T* ptr, FREE_FUNC free_func) {
    if (!ptr)
        return;

    // Move back on the pointer to where the size is allocated
    const usize array_offset = std::max(sizeof(usize), alignof(T));
    char*       raw_memory   = reinterpret_cast<char*>(ptr) - array_offset;

    if constexpr (!std::is_trivially_destructible_v<T>)
    {
        const usize size = *reinterpret_cast<usize*>(raw_memory);

        // Explicitly call the destructor for each element in reverse order
        for (usize i = size; i-- > 0;)
            ptr[i].~T();
    }

    free_func(raw_memory);
}

// WHY DEFAULT-INITIALISATION, AND WHAT IT COSTS THE CALLER.
//
// `new (p) T()` value-initialises and `new (p) T` does not. For a type whose
// default constructor is trivial that is the only difference between them: one
// zeroes the storage, the other runs no code at all. So
// is_trivially_default_constructible_v is exactly the line between zeroing that
// has no other effect and a constructor that has to run, and gating on it
// leaves every type with a real default constructor on the path it was already
// on.
//
// EVERY BYTE MUST BE WRITTEN BEFORE IT IS READ. The block comes from
// aligned_large_pages_alloc or from the default arena's aligned malloc, and
// neither promises zeros -- posix_memalign and _aligned_malloc both hand back
// recycled heap, so an unwritten element holds arbitrary bytes rather than the
// zeros a reader would have got before. What made this worth doing is that the
// shared histories were zeroed and then completely overwritten by
// Search::Worker::clear() before the first search, so the zeroing was dead.
//
// The zeroing was also the FIRST TOUCH that placed the pages, which is what
// ThreadPool::set is buying when it constructs a bank inside
// execute_on_numa_node. Placement now happens on whichever thread writes a page
// first, so a caller relying on first touch must make that thread the one it
// wants the pages near. Worker::clear() runs from the Worker constructor on the
// already-bound worker thread and each worker writes a disjoint slice, so the
// pages of a bank still land on the node its workers run on.
template<typename T>
constexpr bool arena_skips_init_v = std::is_trivially_default_constructible_v<T>;

template<typename T, typename ALLOC_FUNC, typename... Args>
inline std::enable_if_t<!std::is_array_v<T>, T*> memory_allocator(ALLOC_FUNC alloc_func,
                                                                  Args&&... args) {
    void* raw_memory = alloc_func(sizeof(T));
    if (raw_memory == nullptr)
        arena_alloc_failed(sizeof(T));
    ASSERT_ALIGNED(raw_memory, alignof(T));
    if constexpr (sizeof...(Args) == 0 && arena_skips_init_v<T>)
        return new (raw_memory) T;
    else
        return new (raw_memory) T(std::forward<Args>(args)...);
}

template<typename T, typename ALLOC_FUNC>
inline std::enable_if_t<std::is_array_v<T>, std::remove_extent_t<T>*>
memory_allocator(ALLOC_FUNC alloc_func, usize num) {
    using ElementType = std::remove_extent_t<T>;

    const usize array_offset = std::max(sizeof(usize), alignof(ElementType));

    // The byte count is computed before it is asked for, so it must be computed
    // in a type that holds it: `num * sizeof(ElementType)` wraps, and a wrapped
    // total buys a few bytes that the element loop below then writes past.
    if (num > (std::numeric_limits<usize>::max() - array_offset) / sizeof(ElementType))
        arena_size_overflow(num, sizeof(ElementType));

    char* raw_memory =
      reinterpret_cast<char*>(alloc_func(array_offset + num * sizeof(ElementType)));
    if (raw_memory == nullptr)
        arena_alloc_failed(array_offset + num * sizeof(ElementType));
    ASSERT_ALIGNED(raw_memory, alignof(T));

    new (raw_memory) usize(num);

    // See arena_skips_init_v: the default-initialising arm begins the lifetimes
    // and writes nothing, so the whole loop compiles away where the
    // value-initialising one lowered to a memset of the array.
    for (usize i = 0; i < num; ++i)
    {
        void* slot = raw_memory + array_offset + i * sizeof(ElementType);
        if constexpr (arena_skips_init_v<ElementType>)
            new (slot) ElementType;
        else
            new (slot) ElementType();
    }

    return reinterpret_cast<ElementType*>(raw_memory + array_offset);
}

// Owning pointers whose deleter goes through the arena. The deleter is part of
// the type: a block from arena_alloc must be released through these and never
// through platform/memory.h's LargePagePtr, which bakes aligned_large_pages_free
// into every instantiation. Crossing the two frees a block with an allocator
// that never made it.
template<typename T>
struct ArenaDeleter {
    void operator()(T* ptr) const { return memory_deleter<T>(ptr, arena_free); }
};

template<typename T>
struct ArenaArrayDeleter {
    void operator()(T* ptr) const { return memory_deleter_array<T>(ptr, arena_free); }
};

template<typename T>
using ArenaPtr = std::conditional_t<std::is_array_v<T>,
                                    std::unique_ptr<T, ArenaArrayDeleter<std::remove_extent_t<T>>>,
                                    std::unique_ptr<T, ArenaDeleter<T>>>;

template<typename T, typename... Args>
std::enable_if_t<!std::is_array_v<T>, ArenaPtr<T>> make_arena_unique(Args&&... args) {
    static_assert(alignof(T) <= 4096, "arena alloc may fail for such an alignment");
    return ArenaPtr<T>(memory_allocator<T>(arena_alloc, std::forward<Args>(args)...));
}

template<typename T>
std::enable_if_t<std::is_array_v<T>, ArenaPtr<T>> make_arena_unique(usize num) {
    using ElementType = std::remove_extent_t<T>;
    static_assert(alignof(ElementType) <= 4096, "arena alloc may fail for such an alignment");
    return ArenaPtr<T>(memory_allocator<T>(arena_alloc, num));
}

}  // namespace Stockfish

#endif  // #ifndef ARENA_H_INCLUDED
