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

#ifndef HISTORY_H_INCLUDED
#define HISTORY_H_INCLUDED

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <type_traits>  // IWYU pragma: keep
#include <utility>

#include "position.h"
#include "arena.h"
#include "basetypes.h"

namespace Stockfish {

constexpr int PAWN_HISTORY_BASE_SIZE   = 8192;  // has to be a power of 2
constexpr int UINT_16_HISTORY_SIZE     = std::numeric_limits<u16>::max() + 1;
constexpr int CORRHIST_BASE_SIZE       = UINT_16_HISTORY_SIZE;
constexpr int CORRECTION_HISTORY_LIMIT = 1024;
constexpr int LOW_PLY_HISTORY_SIZE     = 5;

static_assert((PAWN_HISTORY_BASE_SIZE & (PAWN_HISTORY_BASE_SIZE - 1)) == 0,
              "PAWN_HISTORY_BASE_SIZE has to be a power of 2");

static_assert((CORRHIST_BASE_SIZE & (CORRHIST_BASE_SIZE - 1)) == 0,
              "CORRHIST_BASE_SIZE has to be a power of 2");

// Which worker of how many is asking for a slice. Two adjacent usizes as
// parameters, transposed, hand every worker a different slice and clear a
// different part of the table -- and the slice arithmetic keeps working, so
// nothing refuses it. They travel as one value with two names instead.
struct WorkerShare {
    usize index;
    usize total;
};

// Cut [0, count) into share.total contiguous slices and return the half-open
// bounds of slice share.index. The whole range is covered only when every index
// in [0, share.total) asks exactly once with the same total; a missing index
// leaves its slice untouched. A slice is empty when the total exceeds count,
// which partitions the range just as correctly.
inline std::pair<usize, usize> shared_slice(usize count, WorkerShare share) {
    assert(share.index < share.total);
    return {u64(share.index) * count / share.total,
            share.index + 1 == share.total ? count
                                           : u64(share.index + 1) * count / share.total};
}

// StatsEntry is the container of various numerical statistics. We use a class
// instead of a naked value to directly call history update operator<<() on
// the entry. The first template parameter T is the base type of the array,
// and the second template parameter D limits the range of updates in [-D, D]
// when we update values with the << operator
template<typename T, int D, bool Shared = false>
struct StatsEntry {
    static_assert(std::is_integral_v<T> && std::is_signed_v<T>, "Not a signed integer type");
    static_assert(D > 0 && D <= std::numeric_limits<T>::max()
                    && D <= std::numeric_limits<int>::max() / D,
                  "D can lead to overflows");

   private:
    std::conditional_t<Shared, RelaxedAtomic<T>, T> entry;

   public:
    // The scalar this entry's storage is layout-compatible with, which is what
    // lets MultiArray::fill write a run instead of an entry.
    //
    // IT IS THE FILL THAT IS UNSHARED, NOT THE ENTRY. Every access during a
    // search stays a relaxed atomic one; a relaxed store may not be merged with
    // its neighbours, so filling the shared 8 MiB continuation history entry by
    // entry emits 4.2 M two-byte stores the compiler is forbidden to widen --
    // 37.7 M instructions and 549 K mispredicts of every clear(). The caller
    // owes the invariant that no other thread can observe the range while it is
    // written: `clear()` runs before the search that reads it, and
    // `clear_range()` hands each worker a disjoint slice of the block.
    using bulk_fill_type = T;

    void operator=(const T& v) { entry = v; }

    operator T() const { return entry; }

    void operator<<(int bonus) {
        // Make sure that bonus is in range [-D, D]
        int clampedBonus = std::clamp(bonus, -D, D);
        T   val          = *this;
        *this            = val + clampedBonus - val * std::abs(clampedBonus) / D;

        assert(std::abs(T(*this)) <= D);
    }
};

template<typename T, int D, usize... Sizes>
using Stats = MultiArray<StatsEntry<T, D>, Sizes...>;

template<typename T, int D, usize... Sizes>
using AtomicStats = MultiArray<StatsEntry<T, D, true>, Sizes...>;

// DynStats is a dynamically sized array of Stats, used for thread-shared histories
// which should scale with the total number of threads. The SizeMultiplier gives
// the per-thread allocation count of T.
template<typename T, int SizeMultiplier>
struct DynStats {
    explicit DynStats(usize s) {
        size = s * SizeMultiplier;
        data = make_arena_unique<T[]>(size);
    }
    // Fill this thread's slice of the array with `value` -- not with zero; the
    // histories start at a tuned non-zero level. The slice is cut from the share
    // alone, so the whole array is cleared only when every index in
    // [0, share.total) calls exactly once with the same total; a missing index
    // leaves that range holding the previous game's statistics.
    void clear_range(int value, WorkerShare share) {
        auto [start, end] = shared_slice(size, share);

        while (start < end)
            data[start++].fill(value);
    }
    usize get_size() const { return size; }
    T&    operator[](usize index) {
        assert(index < size);
        return data.get()[index];
    }
    const T& operator[](usize index) const {
        assert(index < size);
        return data.get()[index];
    }

   private:
    usize             size;
    ArenaPtr<T[]> data;
};

// ButterflyHistory records how often quiet moves have been successful or unsuccessful
// during the current search, and is used for reduction and move ordering decisions.
// It uses 2 tables (one for each color) indexed by the move's from and to squares,
// see https://www.chessprogramming.org/Butterfly_Boards
using ButterflyHistory = Stats<i16, 7183, COLOR_NB, UINT_16_HISTORY_SIZE>;

// LowPlyHistory is addressed by ply and move's from and to squares, used
// to improve move ordering near the root
using LowPlyHistory = Stats<i16, 7183, LOW_PLY_HISTORY_SIZE, UINT_16_HISTORY_SIZE>;

// CapturePieceToHistory is addressed by a move's [piece][to][captured piece type]
using CapturePieceToHistory = Stats<i16, 10692, PIECE_NB, SQUARE_NB, PIECE_TYPE_NB>;

// PieceToHistory is like ButterflyHistory but is addressed by a move's [piece][to]
using PieceToHistory = AtomicStats<i16, 30000, PIECE_NB, SQUARE_NB>;

// ContinuationHistory is the combined history of a given pair of moves, usually
// the current one given a previous one. The nested history table is based on
// PieceToHistory instead of ButterflyBoards.
using ContinuationHistory = MultiArray<PieceToHistory, PIECE_NB, SQUARE_NB>;

// PawnHistory is addressed by the pawn structure and a move's [piece][to].
// The row a pawn key selects is named, because a caller that scores a whole
// move list holds one row across the list and needs a type to hold it in.
using PawnHistoryEntry = AtomicStats<i16, 8192, PIECE_NB, SQUARE_NB>;
using PawnHistory      = DynStats<PawnHistoryEntry, PAWN_HISTORY_BASE_SIZE>;

// Correction histories record differences between the static evaluation of
// positions and their search score. It is used to improve the static evaluation
// used by some search heuristics.
// see https://www.chessprogramming.org/Static_Evaluation_Correction_History
enum CorrHistType {
    PieceTo,       // By [piece][to] move
    Continuation,  // Combined history of move pairs
};

template<typename T, int D>
struct CorrectionBundle {
    StatsEntry<T, D, true> pawn;
    StatsEntry<T, D, true> minor;
    StatsEntry<T, D, true> nonPawnWhite;
    StatsEntry<T, D, true> nonPawnBlack;

    void operator=(T val) {
        pawn         = val;
        minor        = val;
        nonPawnWhite = val;
        nonPawnBlack = val;
    }
};

namespace Detail {

template<CorrHistType>
struct CorrHistTypedef;

template<>
struct CorrHistTypedef<PieceTo> {
    using type = Stats<i16, CORRECTION_HISTORY_LIMIT, PIECE_NB, SQUARE_NB>;
};

template<>
struct CorrHistTypedef<Continuation> {
    using type = MultiArray<CorrHistTypedef<PieceTo>::type, PIECE_NB, SQUARE_NB>;
};

}

using UnifiedCorrectionHistory =
  DynStats<MultiArray<CorrectionBundle<i16, CORRECTION_HISTORY_LIMIT>, COLOR_NB>,
           CORRHIST_BASE_SIZE>;

template<CorrHistType T>
using CorrectionHistory = typename Detail::CorrHistTypedef<T>::type;

using TTMoveHistory = StatsEntry<i16, 8192>;

// The two subscripts of ContinuationHistoryBlock, as types rather than as
// bools. Both indices are one bit, both subscripts are spelled the same way,
// and [capture][inCheck] compiles, reads a real table and returns plausible
// statistics -- a silently worse search that no assert, no bound and no
// diagnostic can see, only the bench anchor. Distinct types leave the
// transposition no spelling.
enum class InCheck : bool {
    No,
    Yes
};

enum class Capture : bool {
    No,
    Yes
};

// The quadrant is reachable only through an accessor that names both
// subscripts. The table stays [2][2] and the accessor inlines to the same two
// subscripts: this buys a diagnostic, not a layout.
struct ContinuationHistoryBlock {
    ContinuationHistory& operator()(InCheck inCheck, Capture capture) {
        return table[usize(inCheck)][usize(capture)];
    }

   private:
    ContinuationHistory table[2][2];
};

// Which shared-history bank a worker draws from.
//
// The HOST decides the grouping -- today one bank per NUMA node -- and the
// engine only has to name the group it was put in. So this is an index into the
// engine's own map, not a handle on the host's topology: a worker never asks
// what a NUMA node is, and nothing here can be used to find out.
//
// Scoped, because the value both producers hand over is a NumaIndex and that
// alias is also usize. With this an alias the distinction above held in prose
// alone; with it an enum the two sites that turn a node number into a bank
// number have to say so.
enum class HistoryBankIndex : usize {
};

// A count the caller has already rounded up.
//
// SharedHistories sizes both its tables as a multiple of the count and indexes
// them by masking a key with `size - 1`, which selects a row inside the array
// only while the size is a power of two. Any other count masks to an index the
// array does not hold -- and an assert used to be the only thing that said so,
// in a build that does not ship. The constructor takes this instead, and the
// only way to make one is to round.
class PowerOfTwo {
   public:
    static constexpr PowerOfTwo ceil(usize count) {
        usize p = 1;
        while (p < count)
            p <<= 1;
        return PowerOfTwo(p);
    }

    constexpr operator usize() const { return value; }

   private:
    constexpr explicit PowerOfTwo(usize v) :
        value(v) {}

    usize value;
};

// One bank of histories, shared by every worker the host put in the same group.
// WHICH workers those are is not this struct's business -- see HistoryBankIndex
// above. The host groups to keep a bank off a remote node; the engine holds the
// bank and never asks what the grouping meant.
//
// The count has to be a power of two, and PowerOfTwo above is what says so --
// this used to be a comment in capitals over a parameter that took any usize,
// with an assert underneath it that -DNDEBUG removes.
struct SharedHistories {
    explicit SharedHistories(PowerOfTwo threadCount) :
        correctionHistory(threadCount),
        continuationHistoryBlock(make_arena_unique<ContinuationHistoryBlock>()),
        pawnHistory(threadCount) {
        sizeMinus1         = correctionHistory.get_size() - 1;
        pawnHistSizeMinus1 = pawnHistory.get_size() - 1;
    }

    ContinuationHistoryBlock& continuationHistory() { return *continuationHistoryBlock; }

    usize get_size() const { return sizeMinus1 + 1; }

    auto& pawn_entry(const Position& pos) {
        return pawnHistory[pos.pawn_key() & pawnHistSizeMinus1];
    }
    const auto& pawn_entry(const Position& pos) const {
        return pawnHistory[pos.pawn_key() & pawnHistSizeMinus1];
    }

    // Return the COUNTER, never the bundle holding it. Each accessor picks the
    // key that selects the row and the field read out of that row in one place,
    // so a caller cannot pair one key's row with another key's field. Handing
    // out the bundle makes that pairing expressible again, and it type-checks:
    // the result is a live counter of the wrong kind, not a fault.
    //
    // `us` stays a parameter because it is a different colour from the one that
    // selects the row: it is the side to move, while in nonpawn_correction the
    // template argument is the side whose key is used. Folding the two into one
    // would be wrong, not safer.
    auto& pawn_correction(const Position& pos, Color us) {
        return correctionHistory[pos.pawn_key() & sizeMinus1][us].pawn;
    }
    const auto& pawn_correction(const Position& pos, Color us) const {
        return correctionHistory[pos.pawn_key() & sizeMinus1][us].pawn;
    }

    auto& minor_piece_correction(const Position& pos, Color us) {
        return correctionHistory[pos.minor_piece_key() & sizeMinus1][us].minor;
    }
    const auto& minor_piece_correction(const Position& pos, Color us) const {
        return correctionHistory[pos.minor_piece_key() & sizeMinus1][us].minor;
    }

    template<Color c>
    auto& nonpawn_correction(const Position& pos, Color us) {
        auto& bundle = correctionHistory[pos.non_pawn_key<c>() & sizeMinus1][us];
        if constexpr (c == WHITE)
            return bundle.nonPawnWhite;
        else
            return bundle.nonPawnBlack;
    }
    template<Color c>
    const auto& nonpawn_correction(const Position& pos, Color us) const {
        const auto& bundle = correctionHistory[pos.non_pawn_key<c>() & sizeMinus1][us];
        if constexpr (c == WHITE)
            return bundle.nonPawnWhite;
        else
            return bundle.nonPawnBlack;
    }

    UnifiedCorrectionHistory           correctionHistory;
    ArenaPtr<ContinuationHistoryBlock> continuationHistoryBlock;
    PawnHistory                        pawnHistory;


   private:
    usize sizeMinus1, pawnHistSizeMinus1;
};

}  // namespace Stockfish

#endif  // #ifndef HISTORY_H_INCLUDED
