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

#include "movegen.h"

#include <cassert>
#include <initializer_list>

#include "attacks.h"
#include "bitboard.h"
#include "position.h"

#if defined(USE_AVX512ICL)
    // The splat finishes in SSE -- _mm_or_si128 and _mm_slli_epi16 are
    // <emmintrin.h>, _mm_cvtepi8_epi16 is <smmintrin.h> -- and <immintrin.h>
    // reaching them is a property of this toolchain, not of the language.
    #include <emmintrin.h>
    #include <immintrin.h>
    #include <smmintrin.h>
#endif

namespace Stockfish {

namespace {

#if defined(USE_AVX512ICL)

// The two packed splats store their moves as ADJACENT 16-bit lanes, so they
// write a Move list and nothing else: an eight-byte stride would want a masked
// permute per eight moves and four stores where there is one. This tier keeps
// the packed buffer that movepick.cpp's SF_GENERATE_INTO_SLOTS names, and the
// static_assert is what says so at the one place that would otherwise store a
// list of the wrong shape.
template<Direction offset, class Dst>
inline Dst* splat_pawn_moves(Dst* moveList, Bitboard to_bb) {
    static_assert(sizeof(Dst) == sizeof(Move), "the packed splat writes adjacent 16-bit lanes");
    assert(popcount(to_bb) <= 8);  // <= 8 pawns per side

    const __m128i toSquares =
      _mm_cvtepi8_epi16(_mm512_castsi512_si128(_mm512_maskz_compress_epi8(to_bb, AllSquares)));
    const __m128i fromSquares = _mm_subs_epi16(toSquares, _mm_set1_epi16(offset));
    const __m128i moves       = _mm_or_si128(_mm_slli_epi16(fromSquares, Move::FromSqShift),
                                             _mm_slli_epi16(toSquares, Move::ToSqShift));

    _mm_storeu_si128(reinterpret_cast<__m128i*>(moveList), moves);
    return moveList + popcount(to_bb);
}

template<class Dst>
inline Dst* splat_moves(Dst* moveList, Square from, Bitboard to_bb) {
    static_assert(sizeof(Dst) == sizeof(Move), "the packed splat writes adjacent 16-bit lanes");
    assert(popcount(to_bb) <= 32);  // Q can attack up to 27 squares

    // THE STORE BELOW WRITES 32 MOVES REGARDLESS OF THE POPCOUNT. The caller's
    // buffer must therefore hold 32 slots from moveList even when this call
    // contributes one, which means at most MAX_MOVES - 32 moves may already be
    // in it. The bound is real and was undocumented; it cannot be asserted here
    // because this function is never told where the buffer ends. Measured
    // maximum over bench plus the 218-move record position: 218 of MAX_MOVES.
    static_assert(MAX_MOVES >= 32 + 218, "the unmasked store needs 32 slots past the worst case");

    const __m512i fromVec = _mm512_set1_epi16(Move(from, SQUARE_ZERO).raw());
    const __m512i toSquares =
      _mm512_cvtepi8_epi16(_mm512_castsi512_si256(_mm512_maskz_compress_epi8(to_bb, AllSquares)));
    const __m512i moves = _mm512_or_si512(fromVec, _mm512_slli_epi16(toSquares, Move::ToSqShift));

    _mm512_storeu_si512(moveList, moves);
    return moveList + popcount(to_bb);
}

#else

// gcc's final value pass rewrites a loop cursor that is live past its loop.
// The cursor these two walks return is exactly that, and the replacement it
// builds is `moveList + popcount(to_bb)`: a copy of to_bb held in a register
// across the walk to be popcounted after it, a decrement, a movslq because
// popcount() returns int, and a lea -- five instructions to rebuild a pointer
// the cursor already held. It is 67 of the 77 register-to-register sign
// extensions in MovePicker::generate_stage() and all 51 in the two out-of-line
// generate_body clones, and 149 popcounts in this translation unit alone.
//
// Naming the end pointer ahead of the walk kills the cursor at the loop's exit
// and leaves to_bb free to be destroyed by the walk rather than held alive for
// it. The empty bitboard -- a piece with no captures, a pawn shift that lands
// nowhere -- must keep paying nothing, so the popcount stays under the guard
// the walk already had; hoisted above it the same change reads +0.0508% where
// this reads -0.0453%.
//
// clang does no such replacement: two popcounts in the whole translation unit
// against gcc's 149, and eight sign extensions against 149. There the named
// end pointer is 106 popcounts nothing asked for, and it costs +0.1606% at
// -O3. And gcc drops the replacement itself where popcount() is not one
// instruction: at ARCH=x86-64 the base emits none, and naming the pointer
// there puts 97 calls to __popcountdi2 in this translation unit.
//
// So it is named where the replacement is already being paid AND the popcount
// is hardware: gcc, and a tier that defines USE_POPCNT. The token stream every
// other compiler and tier sees is the one below the #else, unchanged.
#if defined(__GNUC__) && !defined(__clang__) && defined(USE_POPCNT)

template<Direction offset, class Dst>
inline Dst* splat_pawn_moves(Dst* moveList, Bitboard to_bb) {
    if (!to_bb)
        return moveList;

    Dst* const end = moveList + usize(popcount(to_bb));
    do
    {
        Square to   = pop_lsb(to_bb);
        *moveList++ = Move(to - offset, to);
    } while (to_bb);
    return end;
}

template<class Dst>
inline Dst* splat_moves(Dst* moveList, Square from, Bitboard to_bb) {
    if (!to_bb)
        return moveList;

    Dst* const end = moveList + usize(popcount(to_bb));
    do
        *moveList++ = Move(from, pop_lsb(to_bb));
    while (to_bb);
    return end;
}

#else

template<Direction offset, class Dst>
inline Dst* splat_pawn_moves(Dst* moveList, Bitboard to_bb) {
    while (to_bb)
    {
        Square to   = pop_lsb(to_bb);
        *moveList++ = Move(to - offset, to);
    }
    return moveList;
}

template<class Dst>
inline Dst* splat_moves(Dst* moveList, Square from, Bitboard to_bb) {
    while (to_bb)
        *moveList++ = Move(from, pop_lsb(to_bb));
    return moveList;
}

#endif

#endif

template<GenType Type, Direction D, bool Enemy, class Dst>
Dst* make_promotions(Dst* moveList, [[maybe_unused]] Square to) {

    constexpr bool          all  = Type == EVASIONS || Type == ALL;
    [[maybe_unused]] Square from = to - D;

    if constexpr (Type == CAPTURES || all)
        *moveList++ = Move::make<PROMOTION>(from, to, QUEEN);

    if constexpr ((Type == CAPTURES && Enemy) || (Type == QUIETS && !Enemy) || all)
    {
        *moveList++ = Move::make<PROMOTION>(from, to, ROOK);
        *moveList++ = Move::make<PROMOTION>(from, to, BISHOP);
        *moveList++ = Move::make<PROMOTION>(from, to, KNIGHT);
    }

    return moveList;
}


template<Color Us, GenType Type, class Dst>
Dst* generate_pawn_moves(const Position& pos, Dst* moveList, Bitboard target) {

    static_assert(Type != ALL, "Unsupported type in generate_pawn_moves()");

    constexpr Color     Them     = ~Us;
    constexpr Bitboard  TRank7BB = (Us == WHITE ? Rank7BB : Rank2BB);
    constexpr Bitboard  TRank3BB = (Us == WHITE ? Rank3BB : Rank6BB);
    constexpr Direction Up       = pawn_push(Us);
    constexpr Direction UpRight  = (Us == WHITE ? NORTH_EAST : SOUTH_WEST);
    constexpr Direction UpLeft   = (Us == WHITE ? NORTH_WEST : SOUTH_EAST);

    const Bitboard emptySquares = ~pos.pieces();
    const Bitboard enemies      = Type == EVASIONS ? pos.checkers() : pos.pieces(Them);
    const Bitboard pinned       = pos.blockers_for_king(Us);
    const Square   ksq          = pos.square<KING>(Us);

    const Bitboard pawnsOn7        = pos.pieces(Us, PAWN) & TRank7BB;
    const Bitboard pawnsNotOn7     = pos.pieces(Us, PAWN) & ~TRank7BB;
    const Bitboard pushable        = ~pinned | file_bb(ksq);
    const Bitboard canCaptureLeft  = ~pinned | Attacks::antidiag_bb(ksq);
    const Bitboard canCaptureRight = ~pinned | Attacks::diag_bb(ksq);

    // Single and double pawn pushes, no promotions
    if constexpr (Type != CAPTURES)
    {
        Bitboard b1 = shift(pawnsNotOn7 & pushable, Up) & emptySquares;
        Bitboard b2 = shift(b1 & TRank3BB, Up) & emptySquares;

        if constexpr (Type == EVASIONS)  // Consider only blocking squares
        {
            b1 &= target;
            b2 &= target;
        }

        moveList = splat_pawn_moves<Up>(moveList, b1);
        moveList = splat_pawn_moves<Up + Up>(moveList, b2);
    }

    // Promotions and underpromotions
    if (pawnsOn7)
    {
        Bitboard b1 = shift(pawnsOn7 & canCaptureRight, UpRight) & enemies;
        Bitboard b2 = shift(pawnsOn7 & canCaptureLeft, UpLeft) & enemies;
        Bitboard b3 = shift(pawnsOn7 & pushable, Up) & emptySquares;

        if constexpr (Type == EVASIONS)
            b3 &= target;

        while (b1)
            moveList = make_promotions<Type, UpRight, true>(moveList, pop_lsb(b1));

        while (b2)
            moveList = make_promotions<Type, UpLeft, true>(moveList, pop_lsb(b2));

        while (b3)
            moveList = make_promotions<Type, Up, false>(moveList, pop_lsb(b3));
    }

    // Standard and en passant captures
    if constexpr (Type == CAPTURES || Type == EVASIONS)
    {
        Bitboard b1 = shift(pawnsNotOn7 & canCaptureRight, UpRight) & enemies;
        Bitboard b2 = shift(pawnsNotOn7 & canCaptureLeft, UpLeft) & enemies;

        moveList = splat_pawn_moves<UpRight>(moveList, b1);
        moveList = splat_pawn_moves<UpLeft>(moveList, b2);

        const Square epSq = pos.ep_square();

        if (epSq != SQ_NONE
            // An en passant capture cannot resolve a discovered check
            && !(Type == EVASIONS && (target & (epSq + Up))))
        {
            assert(rank_of(epSq) == relative_rank(Us, RANK_6));

            b1 = pawnsNotOn7
               & ((canCaptureRight & shift(square_bb(epSq), -UpRight))
                  | (canCaptureLeft & shift(square_bb(epSq), -UpLeft)));
            assert(b1);

            while (b1)
                *moveList++ = Move::make<EN_PASSANT>(pop_lsb(b1), epSq);
        }
    }

    return moveList;
}


// `CM` reaches only the three sliders: a knight's attack set is a table read,
// which is already cheaper than the cache slot that would hold it.
template<PieceType Pt, SliderCacheMode CM = NoSliderCache, class Dst = Move>
Dst* generate_moves(const Position&              pos,
                    Dst*                         moveList,
                    Bitboard                     target,
                    Color                        us,
                    [[maybe_unused]] SliderCache* sc   = nullptr,
                    [[maybe_unused]] int*         next = nullptr) {

    static_assert(Pt != KING && Pt != PAWN, "Unsupported piece type in generate_moves()");

    constexpr bool Cached = CM != NoSliderCache && Pt != KNIGHT;

    const Square   ksq    = pos.square<KING>(us);
    const Bitboard pinned = pos.blockers_for_king(us);

    // Cut a pinned slider's set to its pin line before it is cached: the line is
    // as much a property of the node as the occupancy, so the quiet list reads
    // the cut set back. An unpinned slider passes the whole board, which cuts
    // nothing.
    auto attacks = [&](Square from, Bitboard line) {
        Bitboard a;

        if constexpr (Cached && CM == UseSliderCache)
            a = sc->att[(*next)++];
        else
        {
            a = Attacks::attacks_bb(Pt, from, pos.pieces()) & line;
            if constexpr (Cached)
            {
                assert(*next < 16);
                sc->att[(*next)++] = a;
            }
        }

        return a;
    };

    Bitboard bb = pos.pieces(us, Pt) & ~pinned;
    while (bb)
    {
        Square from = pop_lsb(bb);
        moveList    = splat_moves(moveList, from, attacks(from, ~Bitboard(0)) & target);
    }

    if constexpr (Pt != KNIGHT)  // pinned knights cannot move
    {
        bb = pos.pieces(us, Pt) & pinned;
        while (bb)
        {
            Square from = pop_lsb(bb);
            moveList =
              splat_moves(moveList, from, attacks(from, Attacks::line_bb(ksq, from)) & target);
        }
    }

    return moveList;
}


template<GenType Type, SliderCacheMode CM = NoSliderCache, class Dst = Move>
Dst* generate_all(const Position& pos, Dst* moveList, Color us, SliderCache* sc = nullptr) {

    static_assert(Type != ALL, "Unsupported type in generate_all()");
    static_assert(CM == NoSliderCache || Type == CAPTURES || Type == QUIETS,
                  "only the capture list and the quiet list of one node share sliders");

    const Square ksq = pos.square<KING>(us);
    Bitboard     target;
    int          next = 0;

    // Skip generating non-king moves when in double check
    if (Type != EVASIONS || !more_than_one(pos.checkers()))
    {
        target = Type == EVASIONS ? Attacks::between_bb(ksq, lsb(pos.checkers()))
               : Type == CAPTURES ? pos.pieces(~us)
                                  : ~pos.pieces();  // QUIETS

        moveList = us == WHITE ? generate_pawn_moves<WHITE, Type>(pos, moveList, target)
                               : generate_pawn_moves<BLACK, Type>(pos, moveList, target);
        moveList = generate_moves<KNIGHT>(pos, moveList, target, us);
        moveList = generate_moves<BISHOP, CM>(pos, moveList, target, us, sc, &next);
        moveList = generate_moves<ROOK, CM>(pos, moveList, target, us, sc, &next);
        moveList = generate_moves<QUEEN, CM>(pos, moveList, target, us, sc, &next);
    }

    if constexpr (Type == EVASIONS)
        target = ~pos.pieces(us);

    target &= ~pos.threats_by(ALL_PIECES);

    Bitboard b = Attacks::attacks_bb(KING, ksq) & target;
    moveList   = splat_moves(moveList, ksq, b);

    if (Type == QUIETS && pos.can_castle(us & ANY_CASTLING))
    {
        for (CastlingRights cr : {us & KING_SIDE, us & QUEEN_SIDE})
        {
            Square rookSquare = pos.castling_rook_square(cr);
            Square to         = relative_square(us, rookSquare > ksq ? SQ_G1 : SQ_C1);

            if (!pos.castling_impeded(cr) && pos.can_castle(cr)
                && !(Attacks::between_bb(ksq, to) & pos.threats_by(ALL_PIECES))
                && !(pos.blockers_for_king(us) & rookSquare))
                *moveList++ = Move::make<CASTLING>(ksq, rookSquare);
        }
    }

    return moveList;
}

// The entry checks, written once for both destination types.
template<GenType Type, class Dst>
Dst* generate_body(const Position& pos, Dst* moveList) {

    static_assert(Type != ALL, "Unsupported type in generate()");
    assert((Type == EVASIONS) == bool(pos.checkers()));

    Color us = pos.side_to_move();

    return generate_all<Type, NoSliderCache, Dst>(pos, moveList, us);
}

template<GenType Type, SliderCacheMode CM, class Dst>
Dst* generate_cached_body(const Position& pos, Dst* moveList, SliderCache& sc) {

    static_assert(Type == CAPTURES || Type == QUIETS, "Unsupported type in generate_cached()");
    assert((Type == EVASIONS) == bool(pos.checkers()));

    Color us = pos.side_to_move();

    return generate_all<Type, CM, Dst>(pos, moveList, us, &sc);
}

}  // namespace


// <CAPTURES>     Generates all legal captures plus queen promotions
// <QUIETS>       Generates all legal non-captures and underpromotions
// <EVASIONS>     Generates all legal check evasions
//
// Returns a pointer to the end of the move list.
template<GenType Type>
Move* generate(const Position& pos, Move* moveList) {
    return generate_body<Type>(pos, moveList);
}

template<GenType Type>
ExtMove* generate(const Position& pos, ExtMove* moveList) {
    return generate_body<Type>(pos, moveList);
}

// The same generator, with the slider sets written on the capture list and read
// back on the quiet list. It is a separate name rather than a defaulted
// argument on generate() so that the uncached call sites keep the signature and
// the codegen they had.
template<GenType Type, SliderCacheMode CM>
Move* generate_cached(const Position& pos, Move* moveList, SliderCache& sc) {
    return generate_cached_body<Type, CM>(pos, moveList, sc);
}

template<GenType Type, SliderCacheMode CM>
ExtMove* generate_cached(const Position& pos, ExtMove* moveList, SliderCache& sc) {
    return generate_cached_body<Type, CM>(pos, moveList, sc);
}

// Explicit template instantiations. The picker's three generating stages take
// the ExtMove destination below avx512icl and the packed one above it, and only
// the pair the tier actually calls is emitted.
#if defined(USE_AVX512ICL)
template Move* generate_cached<CAPTURES, FillSliderCache>(const Position&, Move*, SliderCache&);
template Move* generate_cached<QUIETS, UseSliderCache>(const Position&, Move*, SliderCache&);
#else
template ExtMove*
generate_cached<CAPTURES, FillSliderCache>(const Position&, ExtMove*, SliderCache&);
template ExtMove* generate_cached<QUIETS, UseSliderCache>(const Position&, ExtMove*, SliderCache&);
template ExtMove* generate<EVASIONS>(const Position&, ExtMove*);
#endif

template Move* generate<CAPTURES>(const Position&, Move*);
template Move* generate<QUIETS>(const Position&, Move*);
template Move* generate<EVASIONS>(const Position&, Move*);

// generate<ALL> generates all the legal moves in the given position

template<>
Move* generate<ALL>(const Position& pos, Move* moveList) {
    return pos.checkers() ? generate<EVASIONS>(pos, moveList)
                          : generate<QUIETS>(pos, generate<CAPTURES>(pos, moveList));
}

}  // namespace Stockfish
