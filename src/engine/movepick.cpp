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
// Kept: std::numeric_limits, used by MoveSorter below -- the branch compiled
// when the vector paths are. IWYU asks to drop it at every ARCH that takes
// the scalar path, and dropping it stops the tree building at the ones that
// do not.
#include <limits>  // IWYU pragma: keep
#include <type_traits>
#include <utility>

// bitboard.h is reached only from the AVX-512 sorter below, which calls lsb() on
// the vpcmpd hit mask. Below that tier nothing here needs it and IWYU says so at
// two of the three tiers the lane runs -- deleting it breaks the third.
#include "bitboard.h"  // IWYU pragma: keep
#include "position.h"
#include "basetypes.h"

#ifdef USE_AVX512
    #include <immintrin.h>
#endif

// Spelled here rather than in compiler.h because one function needs it and the
// reason is local: MovePicker::generate_stage() has a single call site, which
// is the shape every inliner folds, and folding it is exactly what puts its
// frame back on the calls that do not use it.
#if defined(__GNUC__)
    #define SF_NOINLINE __attribute__((noinline))
#elif defined(_MSC_VER)
    #define SF_NOINLINE __declspec(noinline)
#else
    #define SF_NOINLINE
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

// Sort every move in the range, descending.
//
// This is the shape the call sites with no limit need, and naming it is what
// removes a copy they were paying per move. With no score able to fail,
// `sortedEnd` advances on every move and so tracks `p` exactly -- which makes
// `*p = *++sortedEnd` a copy of a slot onto itself. clang keeps it: at
// avx512icl the unrolled sorter reloads the eight bytes through a vector
// extract and a `shld` and stores them back, on every move of every capture and
// evasion list. The ladder below starts at the same slot the general form's
// `sortedEnd` would name, so the order out is the same order.
void sort_all(ExtMove* begin, ExtMove* end) {
    ExtMove* p = begin + 1;

#ifdef USE_AVX512
    if (begin == end)
        return;

    MoveSorter     sorter(*begin);
    ExtMove* const sorterEnd =
      end - begin < MoveSorter::MAX_ELEMENTS ? end : begin + MoveSorter::MAX_ELEMENTS;

    for (; p < sorterEnd; ++p)
        sorter.insert(*p);

    sorter.write_sorted(begin, p - begin);
    // Use scalar implementation for any remaining elements
#endif

    for (; p < end; ++p)
    {
        ExtMove tmp = *p, *q;
        for (q = p; q != begin && *(q - 1) < tmp; --q)
            *q = *(q - 1);
        *q = tmp;
    }
}

#ifndef USE_AVX512
// Sort moves in descending order up to and including a given limit.
// The order of moves smaller than the limit is left unspecified.
void partial_insertion_sort(ExtMove* begin, ExtMove* end, int limit) {
    ExtMove *sortedEnd = begin, *p = begin + 1;

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
#endif

#ifdef USE_AVX512
// The sort for the one call site that HAS a limit, where a score can fail and
// the walk cannot just run to the sorter's capacity.
//
// A scalar scan runs `p->value >= limit` once per move and branches on it --
// 33.9 moves a call at a 34% true rate, which is the band a predictor cannot
// learn. Here the test is a vpcmpd over eight moves at a time and there is no
// branch left to mispredict: what remains is a walk of the ~11.5 bits that came
// back set, a tzcnt and a blsr apiece.
//
// ExtMove is eight bytes with `value` in the upper half, so a 512-bit load holds
// eight of them with the values in the ODD 32-bit lanes; 0xAAAA drops the halves
// carrying the Move itself, and a set lane 2i+1 names move i of the block. The
// tail block is loaded maskz and its dead lanes are dropped from `live` as well,
// because a zeroed lane compares >= a negative limit and would otherwise read as
// a move that qualifies.
//
// A block's mask survives while that block is consumed for the reason the scalar
// scan can read a list it is permuting: the walk only ever WRITES positions it
// has already passed. At the k-th qualification `*q = *++sortedEnd` stores to q
// and reads index k, and k <= q always, so no value ahead of the walk moves.
void sort_quiets(ExtMove* begin, ExtMove* end, int limit) {
    if (begin == end)
        return;

    ExtMove*      sortedEnd = begin;
    ExtMove*      p         = end;  // where the scan stops if the sorter never fills
    MoveSorter    sorter(*begin);
    const __m512i lim = _mm512_set1_epi32(limit);

    u32 seed = 0b10;  // index 0 seeds the sorter, it is not an insertion

    // Returns true when the sorter filled, leaving p at the move that did not fit.
    auto consume = [&](ExtMove* block, u32 hits) {
        while (hits)
        {
            ExtMove* q = block + (int(lsb(hits)) >> 1);

            if (sortedEnd - begin + 1 >= MoveSorter::MAX_ELEMENTS)  // sorter full
            {
                p = q;
                return true;
            }

            sorter.insert(*q);
            *q = *++sortedEnd;
            hits &= hits - 1;
        }
        return false;
    };

    // Whole blocks first. Eight moves is 64 bytes ending at or before `end`, so
    // the load is plain and every lane is a move -- neither a length test nor a
    // load mask reaches the common path.
    ExtMove* block = begin;
    for (; end - block >= 8; block += 8)
    {
        const u32 hits = u32(_mm512_cmpge_epi32_mask(_mm512_loadu_si512(block), lim)) & 0xAAAAu;

        if (consume(block, hits & ~seed))
            goto tail;
        seed = 0;
    }

    if (block < end)
    {
        const isize   n = end - block;
        const __m512i v = _mm512_maskz_loadu_epi64(__mmask8((1u << n) - 1), block);
        const u32     live = 0xAAAAu & u32((u64(1) << (2 * n)) - 1);

        consume(block, u32(_mm512_cmpge_epi32_mask(v, lim)) & live & ~seed);
    }

tail:
    sorter.write_sorted(begin, sortedEnd - begin + 1);

    // Use scalar implementation for any remaining elements
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
#else
// Without the vector sorter there is no scan to replace.
inline void sort_quiets(ExtMove* begin, ExtMove* end, int limit) {
    partial_insertion_sort(begin, end, limit);
}
#endif

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
    [[maybe_unused]] Bitboard checkSquare[KING + 1];

    // The tables the QUIETS arm reads are at the same ADDRESS for every move in
    // the list, and pos.see_ge() below is a call the compiler cannot see
    // through. That call is what stops those addresses being hoisted: after it
    // gcc re-reads `this->continuationHistory` once per plane -- five times a
    // move -- and re-derives the pawn bank's row from pos.pawn_key(). Both are
    // invariant by construction, since a position does not change while its own
    // move list is scored. Only the addresses are named here; every counter is
    // still loaded per move.
    //
    // Each is the FIRST ELEMENT of its plane rather than the plane, because the
    // six are all read at the same [pc][to] and clang lowers `(*t)[pc][to]` as
    // `t + pc * 128` and then an index of `to * 2`: one add per plane that the
    // addressing mode could have carried for free. A flat element index named
    // once leaves `base + hi * 2`, and the add goes away six times a move.
    //
    // MultiArray is a std::array of std::array of a two-byte entry with nothing
    // between them, so [pc][to] is element pc * SQUARE_NB + to of one run --
    // which is the same layout MultiArray::fill() writes through. The
    // static_asserts below are what hold that; a padded entry breaks the build
    // rather than the ordering.
    using ContEntry = std::remove_pointer_t<decltype(continuationHistory[0]->data()->data())>;
    using PawnEntry =
      std::remove_pointer_t<decltype(sharedHistory->pawn_entry(pos).data()->data())>;
    static_assert(sizeof(PieceToHistory) == PIECE_NB * SQUARE_NB * sizeof(ContEntry));
    static_assert(sizeof(PawnHistoryEntry) == PIECE_NB * SQUARE_NB * sizeof(PawnEntry));
    [[maybe_unused]] ContEntry *contHist0, *contHist1, *contHist2, *contHist3, *contHist5;
    [[maybe_unused]] PawnEntry* pawnHist;

    // The main history's ROW, for the same reason and by the same rule: `us`
    // does not change across a move list, so the colour belongs in the address
    // and not in the loop. Left as [us][raw] gcc reloads `this->mainHistory`
    // once a move, adds the move to it, and then adds a separately spilled
    // `us << 17` -- four instructions where a row named once leaves
    // `row + raw * 2`, which the addressing mode carries.
    using MainEntry = std::remove_pointer_t<decltype((*mainHistory)[WHITE].data())>;
    static_assert(sizeof((*mainHistory)[WHITE]) == UINT_16_HISTORY_SIZE * sizeof(MainEntry));
    [[maybe_unused]] MainEntry* mainRow;

    if constexpr (Type == QUIETS)
    {
        threatByLesser[PAWN]   = 0;
        threatByLesser[KNIGHT] = threatByLesser[BISHOP] = pos.attacks_by<PAWN>(~us);
        threatByLesser[ROOK] =
          pos.attacks_by<KNIGHT>(~us) | pos.attacks_by<BISHOP>(~us) | threatByLesser[KNIGHT];
        threatByLesser[QUEEN] = pos.attacks_by<ROOK>(~us) | threatByLesser[ROOK];
        threatByLesser[KING]  = 0;

        contHist0 = continuationHistory[0]->data()->data();
        contHist1 = continuationHistory[1]->data()->data();
        contHist2 = continuationHistory[2]->data()->data();
        contHist3 = continuationHistory[3]->data()->data();
        contHist5 = continuationHistory[5]->data()->data();
        pawnHist  = sharedHistory->pawn_entry(pos).data()->data();
        mainRow   = (*mainHistory)[us].data();
#if defined(__GNUC__) && !defined(__clang__)
        asm("" : "+r"(mainRow));
#endif

        // Copied beside threatByLesser so the per-move read is one instruction.
        // pos.check_squares(pt) is st->checkSquares[pt], and `st` is one more
        // loop-invariant pointer than the loop has registers for -- it comes
        // back off the stack once a move and the plane load hangs off it, two
        // instructions where a local array indexed off rsp is one. clang copies
        // the eight bitboards as two 256-bit moves, so the whole hoist is four
        // instructions per generated quiet list against one saved per move in
        // it.
        for (int pt = PAWN; pt <= KING; ++pt)
            checkSquare[pt] = pos.check_squares(PieceType(pt));
    }

    // Walked by INDEX rather than by two pointers. A range-for over the source
    // and a `*it++` on the destination give the loop three induction variables
    // that the end test then has to reconstruct a pointer from; one count that
    // both sides address off leaves the trip count in a register and the exit
    // test a compare against it, and it is also what tells the caller where the
    // list ended without a second variable tracking that.
    ExtMove* const    it  = cur;
    const Move* const src = ml.begin();
    const isize       n   = isize(ml.size());

    // clang vectorises the capture arm at AVX-512 and pays a masked
    // `vpgatherdd` for PieceValue[piece_on(to)]. A gather is 16 scattered
    // loads issued as one instruction, and the loop it replaces is a handful
    // of moves; guarded because gcc warns on an unknown pragma under -Werror.
#if defined(__clang__)
    #pragma clang loop vectorize(disable)
#endif
    for (isize i = 0; i < n; ++i)
    {
        ExtMove& m = it[i];
        m          = src[i];

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
            const int hi = int(pc) * SQUARE_NB + int(to);

            int value = 2 * mainRow[m.raw()];
            value += 2 * pawnHist[hi];
            value += contHist0[hi];
            value += contHist1[hi];
            value += contHist2[hi];
            value += contHist3[hi];
            value += contHist5[hi];

            // bonus for checks. A statement rather than a multiply by the
            // predicate: the short circuit is already a branch, and the product
            // makes its not-taken arm materialise a zero and add it. Counted at
            // this line by a bench instrumented to increment on each side, the
            // arm the test skips is 96.9% of scored quiets at depth 8, 97.1% at
            // 11, 95.9% at 12 and 96.0% at 13, so the two instructions would be
            // paid on all but a few in a hundred. see_ge() itself is reached
            // 243,288 times over 5,954,783 quiets at depth 12 and returns true
            // on 120,381 of those, so the bonus lands on 2.0% of the list.
            if ((checkSquare[pt] >> to & 1) && pos.see_ge(m, -75))
                value += 16384;

            // penalty for moving to a square threatened by a lesser piece
            // or bonus for escaping an attack by a lesser piece.
            //
            // Both halves are the same bit test on the same bitboard, but
            // `b & square_bb(s)` gives clang a VALUE to test where a shift gives
            // it a bit position: from `bool(threat & to)` it builds 1 << to and
            // tests it, four instructions, where the `from` half it had already
            // lowered to a `bt`. Written as shifts it emits `bt` for both and
            // the difference falls out of the carry.
            const Bitboard threat = threatByLesser[pt];
            const int      v      = 20 * (int(threat >> from & 1) - int(threat >> to & 1));
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

            for (isize i = 0; i < n; ++i)
                it[i].value += 8 * lowPlyRow[it[i].raw()] / divisor;
        }
    }

    return it + n;
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

// The stages that have no list to walk yet: the TT move, the three that
// generate and score one, and the two that filter a list through see_ge().
//
// It is out of line and never inlined because of what it costs its caller to
// hold. A MoveList<> is 512 bytes of stack and the generating arms need six
// callee-saved registers between them, so a single function pays a 680-byte
// frame and a six-push prologue on EVERY next_move() call -- and 56.7% of them
// only ever walk a list. A warm 60-ply game at depth 20 spends 22.6 Ir a node
// entering that frame and 26.7 leaving it, over 3.20 calls, which is 6% of the
// whole of next_move() and buys nothing on the calls that do not generate.
SF_NOINLINE Move MovePicker::generate_stage() {

top:
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
        MoveList<CAPTURES> ml(pos, sliderCache, FillSliders{});

        cur = endBadCaptures = moves;
        endCur = endCaptures = score<CAPTURES>(ml);

        sort_all(cur, endCur);
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
            // The sliders this list needs were computed by the capture list
            // above: CAPTURE_INIT always runs before QUIET_INIT in one picker,
            // and the position a do_move/undo_move pair leaves behind is the
            // one the capture list saw.
            MoveList<QUIETS> ml(pos, sliderCache, UseSliders{});

            endCur = endGenerated = score<QUIETS>(ml);

            sort_quiets(cur, endCur, -3560 * depth);
        }

        ++stage;
        return walk_lists();

    case EVASION_INIT : {
        MoveList<EVASIONS> ml(pos);

        cur    = moves;
        endCur = endGenerated = score<EVASIONS>(ml);

        sort_all(cur, endCur);
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
}

// The three stages that only walk a list, chained by fallthrough exactly as
// they were when they were cases of the switch above. Reached by a range test
// rather than through the jump table, so more than half of the dispatches are a
// direct branch and the table keeps the rest.
//
// Naming them AHEAD of the switch while they were still cases of it did
// nothing: clang folds a test whose target is a case label back into the table,
// and the emitted dispatch was byte-identical. They have to leave the switch
// for the test to survive -- and leaving the FUNCTION is what drops the frame.
Move MovePicker::walk_lists() {

    constexpr int goodQuietThreshold = -14000;

    if (stage == GOOD_QUIET)
        goto good_quiet;
    if (stage == BAD_CAPTURE)
        goto bad_capture;
    goto bad_quiet;

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

// This is the most important method of the MovePicker class. We emit one
// new pseudo-legal move on every call until there are no more moves left,
// picking the move with the highest score from a list of generated moves.
//
// Essentially every indirect mispredict the engine pays is the jump table in
// generate_stage(). A callgrind --branch-sim profile at avx2, marginal depth 12
// to 16, puts whole-engine indirect mispredicts at 1.41 per node and attributes
// 1.409 of them there, over about 8.8 entries at a simulated 47.9% rate. Over a
// warm 60-ply game at depth 20 the dispatch runs 3.20 times per node, and 56.7%
// of those ask for one of the three consecutive stages that do nothing but walk
// a list: GOOD_QUIET 22.5%, BAD_CAPTURE 6.5%, BAD_QUIET 27.7%.
Move MovePicker::next_move() {

    if (unsigned(stage - GOOD_QUIET) <= unsigned(BAD_QUIET - GOOD_QUIET))
        return walk_lists();

    return generate_stage();
}

void MovePicker::skip_quiet_moves() { skipQuiets = true; }

}  // namespace Stockfish
