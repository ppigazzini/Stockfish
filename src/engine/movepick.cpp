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

#include "movepick.h"

#include <cassert>
#include <limits>
#include <utility>

#include "bitboard.h"
#include "position.h"
#include "basetypes.h"

#ifdef USE_AVX512
    #include <immintrin.h>
#endif

namespace Stockfish {

namespace {

enum Stages {
    // generate main search moves
    MAIN_TT,
    CAPTURE_INIT,
    GOOD_CAPTURE,
    QUIET_INIT,
    GOOD_QUIET,
    BAD_CAPTURE,
    BAD_QUIET,

    // generate evasion moves
    EVASION_TT,
    EVASION_INIT,
    EVASION,

    // generate probcut moves
    PROBCUT_TT,
    PROBCUT_INIT,
    PROBCUT,

    // generate qsearch moves
    QSEARCH_TT,
    QCAPTURE_INIT,
    QCAPTURE
};

#ifdef USE_AVX512
// Load the Move, and the ExtMove value, into all lanes of 512-bit registers
static void splat_extmove(const ExtMove& m, __m512i& move, __m512i& value) {
    move  = _mm512_set1_epi32(m.raw());
    value = _mm512_set1_epi32(m.value);
}

// Sorts up to 16 moves.
struct MoveSorter {
    static constexpr int MAX_ELEMENTS = 16;
    __m512i              sortedValues, sortedMoves;

    explicit MoveSorter(const ExtMove& first) {
        splat_extmove(first, sortedMoves, sortedValues);

        // Set the uninitialized move values to INT_MIN, so that they sort less than any other move
        sortedValues = _mm512_mask_set1_epi32(sortedValues, ~1, std::numeric_limits<int>::min());
    }

    void insert(const ExtMove& m) {
        __m512i move, value;
        splat_extmove(m, move, value);

        // Mask of all elements except the insertion point
        assert(m.value != std::numeric_limits<int>::min());
        const u16 expand = _kadd_mask16(_mm512_cmplt_epi32_mask(sortedValues, value), -1);

        sortedValues = _mm512_mask_expand_epi32(value, expand, sortedValues);
        sortedMoves  = _mm512_mask_expand_epi32(move, expand, sortedMoves);
    }

    void write_sorted(ExtMove* moves, isize count) const {
        static_assert(sizeof(ExtMove) == 8);
        assert(count <= MAX_ELEMENTS);

        // Because values and moves are stored separately, we need to reassemble the ExtMoves
        auto write = [&](int offset, const __m512i indices) {
            const __m512i extMoves = _mm512_permutex2var_epi32(sortedMoves, indices, sortedValues);
            const isize   storeCount = count - offset;

            if (storeCount > 0)
                _mm512_mask_storeu_epi64(moves + offset, (1 << storeCount) - 1, extMoves);
        };

        write(0, _mm512_setr_epi32(0, 16, 1, 17, 2, 18, 3, 19, 4, 20, 5, 21, 6, 22, 7, 23));
        write(8, _mm512_setr_epi32(8, 24, 9, 25, 10, 26, 11, 27, 12, 28, 13, 29, 14, 30, 15, 31));
    }
};
#endif

// Sort moves in descending order up to and including a given limit.
// The order of moves smaller than the limit is left unspecified.
void partial_insertion_sort(ExtMove* begin, ExtMove* end, int limit) {
    ExtMove *sortedEnd = begin, *p = begin + 1;

#ifdef USE_AVX512
    if (begin == end)
        return;

    MoveSorter sorter(*begin);
    for (; p < end; ++p)
    {
        if (p->value >= limit)
        {
            if (sortedEnd - begin + 1 >= MoveSorter::MAX_ELEMENTS)  // sorter full
                break;

            sorter.insert(*p);
            *p = *++sortedEnd;
        }
    }
    sorter.write_sorted(begin, sortedEnd - begin + 1);
    // Use scalar implementation for any remaining elements
#endif

    for (; p < end; ++p)
        if (p->value >= limit)
        {
            ExtMove tmp = *p, *q;
            *p          = *++sortedEnd;
            for (q = sortedEnd; q != begin && *(q - 1) < tmp; --q)
                *q = *(q - 1);
            *q = tmp;
        }
}

}  // namespace


// Constructors of the MovePicker class. As arguments, we pass information
// to decide which class of moves to emit, to help sorting the (presumably)
// good moves first, and how important move ordering is at the current node.

// MovePicker constructor for the main search and for the quiescence search
MovePicker::MovePicker(const Position&              p,
                       Move                         ttm,
                       Depth                        d,
                       const ButterflyHistory*      mh,
                       const LowPlyHistory*         lph,
                       const CapturePieceToHistory* cph,
                       const PieceToHistory**       ch,
                       const SharedHistories*       sh,
                       int                          pl) :
    pos(p),
    mainHistory(mh),
    lowPlyHistory(lph),
    captureHistory(cph),
    continuationHistory(ch),
    sharedHistory(sh),
    ttMove(ttm),
    depth(d),
    ply(pl) {

    if (pos.checkers())
        stage = EVASION_TT + !(ttm && pos.pseudo_legal(ttm));

    else
        stage = (depth > 0 ? MAIN_TT : QSEARCH_TT) + !(ttm && pos.pseudo_legal(ttm));
}

// MovePicker constructor for ProbCut: we generate captures with Static Exchange
// Evaluation (SEE) greater than or equal to the given threshold.
MovePicker::MovePicker(const Position& p, Move ttm, int th, const CapturePieceToHistory* cph) :
    pos(p),
    captureHistory(cph),
    ttMove(ttm),
    threshold(th) {
    assert(!pos.checkers());

    stage = PROBCUT_TT + !(ttm && pos.capture_stage(ttm) && pos.pseudo_legal(ttm));
}

// Assigns a numerical value to each move in a list, used for sorting.
// Captures are ordered by Most Valuable Victim (MVV), preferring captures
// with a good history. Quiet moves are ordered using the history tables.
template<GenType Type>
ExtMove* MovePicker::score(const MoveList<Type>& ml) {

    static_assert(Type == CAPTURES || Type == QUIETS || Type == EVASIONS, "Wrong type");

    Color us = pos.side_to_move();

    [[maybe_unused]] Bitboard threatByLesser[KING + 1];

    // The tables the QUIETS arm reads are at the same ADDRESS for every move in
    // the list, and pos.see_ge() below is a call the compiler cannot see
    // through. That call is what stops those addresses being hoisted: after it
    // gcc re-reads `this->continuationHistory` once per plane -- five times a
    // move -- and re-derives the pawn bank's row from pos.pawn_key(). Both are
    // invariant by construction, since a position does not change while its own
    // move list is scored. Only the addresses are named here; every counter is
    // still loaded per move.
    [[maybe_unused]] const PieceToHistory *   contHist0, *contHist1, *contHist2, *contHist3,
      *contHist5;
    [[maybe_unused]] const PawnHistoryEntry* pawnHist;

    if constexpr (Type == QUIETS)
    {
        threatByLesser[PAWN]   = 0;
        threatByLesser[KNIGHT] = threatByLesser[BISHOP] = pos.attacks_by<PAWN>(~us);
        threatByLesser[ROOK] =
          pos.attacks_by<KNIGHT>(~us) | pos.attacks_by<BISHOP>(~us) | threatByLesser[KNIGHT];
        threatByLesser[QUEEN] = pos.attacks_by<ROOK>(~us) | threatByLesser[ROOK];
        threatByLesser[KING]  = 0;

        contHist0 = continuationHistory[0];
        contHist1 = continuationHistory[1];
        contHist2 = continuationHistory[2];
        contHist3 = continuationHistory[3];
        contHist5 = continuationHistory[5];
        pawnHist  = &sharedHistory->pawn_entry(pos);
    }

    ExtMove* it = cur;
    // clang vectorises the capture arm at AVX-512 and pays a masked
    // `vpgatherdd` for PieceValue[piece_on(to)]. A gather is 16 scattered
    // loads issued as one instruction, and the loop it replaces is a handful
    // of moves; guarded because gcc warns on an unknown pragma under -Werror.
#if defined(__clang__)
    #pragma clang loop vectorize(disable)
#endif
    for (auto move : ml)
    {
        ExtMove& m = *it++;
        m          = move;

        const Square    from          = m.from_sq();
        const Square    to            = m.to_sq();
        const Piece     pc            = pos.moved_piece(m);
        const PieceType pt            = type_of(pc);
        const Piece     capturedPiece = pos.piece_on(to);

        if constexpr (Type == CAPTURES)
            m.value = (*captureHistory)[pc][to][type_of(capturedPiece)]
                    + 7 * int(PieceValue[capturedPiece]);

        else if constexpr (Type == QUIETS)
        {
            // histories -- summed in a local and stored once. m.value is a
            // location the see_ge() call below can reach, so every `+=` on it
            // is a load, an add and a store rather than an accumulator.
            //
            // The low-ply term below keeps its `+=` deliberately. Carrying the
            // local past it makes the low-ply arm the loop's tail, and gcc then
            // duplicates the exit test into both paths -- 237 K more mispredicts
            // AND 476 K more instructions on a depth-9 search, so it is not even
            // a trade. Stopping the accumulator at the store leaves the tail
            // where it was, and the mispredicts fall with the instruction count.
            int value = 2 * (*mainHistory)[us][m.raw()];
            value += 2 * (*pawnHist)[pc][to];
            value += (*contHist0)[pc][to];
            value += (*contHist1)[pc][to];
            value += (*contHist2)[pc][to];
            value += (*contHist3)[pc][to];
            value += (*contHist5)[pc][to];

            // bonus for checks
            value += ((pos.check_squares(pt) & to) && pos.see_ge(m, -75)) * 16384;

            // penalty for moving to a square threatened by a lesser piece
            // or bonus for escaping an attack by a lesser piece.
            int v = 20 * (bool(threatByLesser[pt] & from) - bool(threatByLesser[pt] & to));
            m.value = value + PieceValue[pt] * v;
        }

        else  // Type == EVASIONS
        {
            if (pos.capture_stage(m))
                m.value = PieceValue[capturedPiece] + (1 << 28);
            else
                m.value = (*mainHistory)[us][m.raw()] + (*continuationHistory[0])[pc][to];
        }
    }

    // The low-ply term is a second pass over the same list, and the reason is
    // the loop above rather than this one: `ply` and the row `ply` selects are
    // invariant across the list, and the see_ge() call re-reads both per move.
    // Here there is no call, so the row address and the divisor are derived
    // once, and every move that is not at a low ply pays no test at all.
    if constexpr (Type == QUIETS)
    {
        if (ply < LOW_PLY_HISTORY_SIZE)
        {
            const auto& lowPlyRow = (*lowPlyHistory)[ply];
            const int   divisor   = 1 + ply;

            for (ExtMove* p = cur; p != it; ++p)
                p->value += 8 * lowPlyRow[p->raw()] / divisor;
        }
    }

    return it;
}

// Returns the next move satisfying a predicate function.
// This never returns the TT move, as it was emitted before.
template<typename Pred>
Move MovePicker::select(Pred filter) {

    for (; cur < endCur; ++cur)
        if (*cur != ttMove && filter())
            return *cur++;

    return Move::none();
}

// This is the most important method of the MovePicker class. We emit one
// new pseudo-legal move on every call until there are no more moves left,
// picking the move with the highest score from a list of generated moves.
Move MovePicker::next_move() {

    constexpr int goodQuietThreshold = -14000;
top:
    // Essentially every indirect mispredict the engine pays is this jump table.
    // A callgrind --branch-sim profile at avx2, marginal depth 12 to 16, puts
    // whole-engine indirect mispredicts at 1.41 per node and attributes 1.409 of
    // them here, over about 8.8 entries at a simulated 47.9% rate. Over a warm
    // 60-ply game at depth 20 the dispatch runs 3.20 times per node, and 56.7%
    // of those ask for one of the three consecutive stages that do nothing but
    // walk a list: GOOD_QUIET 22.5%, BAD_CAPTURE 6.5%, BAD_QUIET 27.7%. Those
    // three are hoisted below the switch and reached by a range test, so more
    // than half of the dispatches become direct branches and the table keeps the
    // rest. They still chain by fallthrough exactly as they did as cases; only
    // QUIET_INIT reaches the first of them by a jump rather than by falling in.
    //
    // Naming them AHEAD of the switch while they were still cases of it did
    // nothing: clang folds a test whose target is a case label back into the
    // table, and the emitted dispatch was byte-identical. They have to leave the
    // switch for the test to survive.
    if (unsigned(stage - GOOD_QUIET) <= unsigned(BAD_QUIET - GOOD_QUIET))
    {
        if (stage == GOOD_QUIET)
            goto good_quiet;
        if (stage == BAD_CAPTURE)
            goto bad_capture;
        goto bad_quiet;
    }

    switch (stage)
    {

    case MAIN_TT :
    case EVASION_TT :
    case QSEARCH_TT :
    case PROBCUT_TT :
        ++stage;
        return ttMove;

    case CAPTURE_INIT :
    case PROBCUT_INIT :
    case QCAPTURE_INIT : {
        MoveList<CAPTURES> ml(pos);

        cur = endBadCaptures = moves;
        endCur = endCaptures = score<CAPTURES>(ml);

        partial_insertion_sort(cur, endCur, std::numeric_limits<int>::min());
        ++stage;
        goto top;
    }

    case GOOD_CAPTURE :
        if (select([&]() {
                if (pos.see_ge(*cur, -cur->value / 18))
                    return true;
                std::swap(*endBadCaptures++, *cur);
                return false;
            }))
            return *(cur - 1);

        ++stage;
        [[fallthrough]];

    case QUIET_INIT :
        if (!skipQuiets)
        {
            MoveList<QUIETS> ml(pos);

            endCur = endGenerated = score<QUIETS>(ml);

            partial_insertion_sort(cur, endCur, -3560 * depth);
        }

        ++stage;
        goto good_quiet;

    case EVASION_INIT : {
        MoveList<EVASIONS> ml(pos);

        cur    = moves;
        endCur = endGenerated = score<EVASIONS>(ml);

        partial_insertion_sort(cur, endCur, std::numeric_limits<int>::min());
        ++stage;
        [[fallthrough]];
    }

    case EVASION :
    case QCAPTURE :
        return select([]() { return true; });

    case PROBCUT :
        return select([&]() { return pos.see_ge(*cur, threshold); });
    }

    assert(false);
    return Move::none();  // Silence warning

good_quiet:
        // A good quiet is one scoring above goodQuietThreshold, and select()
        // walks to the END of the list looking for the next one. It cannot find
        // one past the FIRST move that scores at or below the threshold: ahead
        // of that move lies the rest of the sorted prefix, which descends, and
        // then the unsorted tail, every member of which scores below the sort's
        // own limit. That is only an argument when the limit is at or below the
        // threshold -- -3560 * depth reaches -14000 at depth 4 -- so the walk
        // stops early there and runs to the end below it, where a tail move can
        // still outscore the threshold. Two thirds of the iterations this stage
        // spends at depth 20 are past that first failing move: 1.70 of 2.54 per
        // node, nearly all of them in the 7.7% of visits that exhaust the list.
        if (!skipQuiets)
        {
            if (-3560 * depth <= goodQuietThreshold)
            {
                for (; cur < endCur; ++cur)
                {
                    if (cur->value <= goodQuietThreshold)
                        break;
                    if (*cur != ttMove)
                        return *cur++;
                }
            }
            else if (select([&]() { return cur->value > goodQuietThreshold; }))
                return *(cur - 1);
        }

        // Prepare the pointers to loop over the bad captures
        cur    = moves;
        endCur = endBadCaptures;

        ++stage;

bad_capture:
        if (select([]() { return true; }))
            return *(cur - 1);

        // Prepare the pointers to loop over quiets again -- ONLY if any were
        // generated. endGenerated gets its value in QUIET_INIT, and QUIET_INIT
        // is skipped whenever quiets are, so this copied a value no search had
        // written; it was saved from being read by BAD_QUIET returning first.
        // Guarding the copy costs one predictable branch per node here, where
        // initialising endGenerated in CAPTURE_INIT would cost a store at every
        // node instead. skipQuiets is monotone -- skip_quiet_moves() only ever
        // sets it -- so a caller cannot un-skip between the two stages and find
        // the pointers unset.
        if (!skipQuiets)
        {
            cur    = endCaptures;
            endCur = endGenerated;
        }

        ++stage;

bad_quiet:
        if (!skipQuiets)
            return select([&]() { return cur->value <= goodQuietThreshold; });

        return Move::none();
}

void MovePicker::skip_quiet_moves() { skipQuiets = true; }

}  // namespace Stockfish
