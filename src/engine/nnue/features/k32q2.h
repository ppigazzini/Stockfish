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

//Definition of input features K32Q2 of NNUE evaluation function

#ifndef NNUE_FEATURES_K32Q2_H_INCLUDED
#define NNUE_FEATURES_K32Q2_H_INCLUDED

#include <array>             // IWYU pragma: keep
#include <initializer_list>  // IWYU pragma: keep

#include "../../types.h"
#include "../nnue_common.h"
#include "../../basetypes.h"
#include "../../compiler.h"  // IWYU pragma: keep
// Kept: the gcc branch below defines the two feature builders here, and they
// read <array>, <initializer_list> and sf_always_inline. IWYU runs on clang,
// sees the branch that only declares them, and would drop all three.


namespace Stockfish::Eval::NNUE::Features {

// Feature K32Q2: Combination of the position of own king (32 buckets), opponent queen presence (2 states),
// and piece-square positions. Position mirrored such that king is always on e..h files.
class K32Q2 {

    // Unique number for each piece type on each square
    enum {
        PS_NONE     = 0,
        PS_W_PAWN   = 0,
        PS_B_PAWN   = 1 * SQUARE_NB,
        PS_W_KNIGHT = 2 * SQUARE_NB,
        PS_B_KNIGHT = 3 * SQUARE_NB,
        PS_W_BISHOP = 4 * SQUARE_NB,
        PS_B_BISHOP = 5 * SQUARE_NB,
        PS_W_ROOK   = 6 * SQUARE_NB,
        PS_B_ROOK   = 7 * SQUARE_NB,
        PS_W_QUEEN  = 8 * SQUARE_NB,
        PS_B_QUEEN  = 9 * SQUARE_NB,
        PS_KING     = 10 * SQUARE_NB,
        PS_NB       = 11 * SQUARE_NB
    };

    alignas(64) static constexpr u16 PieceSquareIndex[COLOR_NB][PIECE_NB] = {
      // Convention: W - us, B - them
      // Viewed from other side, W and B are reversed
      {PS_NONE, PS_W_PAWN, PS_W_KNIGHT, PS_W_BISHOP, PS_W_ROOK, PS_W_QUEEN, PS_KING, PS_NONE,
       PS_NONE, PS_B_PAWN, PS_B_KNIGHT, PS_B_BISHOP, PS_B_ROOK, PS_B_QUEEN, PS_KING, PS_NONE},
      {PS_NONE, PS_B_PAWN, PS_B_KNIGHT, PS_B_BISHOP, PS_B_ROOK, PS_B_QUEEN, PS_KING, PS_NONE,
       PS_NONE, PS_W_PAWN, PS_W_KNIGHT, PS_W_BISHOP, PS_W_ROOK, PS_W_QUEEN, PS_KING, PS_NONE}};

   public:
    // Hash value embedded in the evaluation file
    static constexpr u32 HashValue = 0x32b5e284u;

    // Number of feature dimensions (45,056 piece-squares)
    static constexpr IndexType Dimensions =
      static_cast<IndexType>(SQUARE_NB) * static_cast<IndexType>(PS_NB);

#define B(v) (v * 2 * PS_NB)
    // clang-format off
    static constexpr IndexType KingBuckets[SQUARE_NB] = {
        B(28), B(29), B(30), B(31), B(31), B(30), B(29), B(28),
        B(24), B(25), B(26), B(27), B(27), B(26), B(25), B(24),
        B(20), B(21), B(22), B(23), B(23), B(22), B(21), B(20),
        B(16), B(17), B(18), B(19), B(19), B(18), B(17), B(16),
        B(12), B(13), B(14), B(15), B(15), B(14), B(13), B(12),
        B( 8), B( 9), B(10), B(11), B(11), B(10), B( 9), B( 8),
        B( 4), B( 5), B( 6), B( 7), B( 7), B( 6), B( 5), B( 4),
        B( 0), B( 1), B( 2), B( 3), B( 3), B( 2), B( 1), B( 0),
    };
    // clang-format on
#undef B
    // clang-format off
    // Orient a square according to perspective (rotates by 180 for black)
    static constexpr IndexType OrientTBL[SQUARE_NB] = {
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1,
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1,
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1,
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1,
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1,
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1,
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1,
        SQ_H1, SQ_H1, SQ_H1, SQ_H1, SQ_A1, SQ_A1, SQ_A1, SQ_A1 ,
    };
    // clang-format on

    // Maximum number of simultaneously active features.
    static constexpr IndexType MaxActiveDimensions = 32;
    using IndexList                                = ValueList<u16, MaxActiveDimensions>;
    using DiffType                                 = DirtyPiece;

#if defined(USE_AVX512ICL)
    // Compute all changed feature indices and write them to the given lists
    static void write_indices(const std::array<Piece, SQUARE_NB>& oldPieces,
                              const std::array<Piece, SQUARE_NB>& newPieces,
                              Bitboard                            removedBB,
                              Bitboard                            addedBB,
                              Color                               perspective,
                              Square                              ksq,
                              bool                                opponentHasQueen,
                              IndexList&                          removed,
                              IndexList&                          added);
#endif

    // Index of a feature for a given king position and another piece on some
    // square.
    //
    // Both of these live here rather than in the .cpp, and both are pinned
    // inline, because gcc's WHOLE-PROGRAM inliner was deciding one of them at
    // link time and the decision is BISTABLE: with append_changed_indices out
    // of line at update_accumulator_incremental<true>'s call site, that pair of
    // symbols retires 9,409,407 more instructions over a depth-12 bench than
    // with it folded in -- 0.100% of the search -- and an edit anywhere in the
    // tree could flip it. A ratio measured across such a flip is the inliner's
    // and not the change's, and no A/A control can see it, because the flip is
    // perfectly reproducible for a given tree. Pinning the cheaper state costs
    // the attribute and gives every measurement on this tree one lane back.
    //
    // gcc only. clang reads the pin the other way: forced into every caller,
    // the builders grow AccumulatorStack::evaluate and its inliner pays for the
    // size elsewhere in the search, and left in this header without the
    // attribute they still cost clang PGO. So clang gets them out of line, in
    // k32q2.cpp, where they were before the pin. The two bodies are one
    // function and must stay identical: the bench signature under each compiler
    // is what says they still are.
#if defined(__GNUC__) && !defined(__clang__)
    static sf_always_inline IndexType
    make_index(Color perspective, Square s, Piece pc, Square ksq, bool opponentHasQueen) {
        alignas(64) static constexpr auto offsets = [] {
            std::array<std::array<u16, PIECE_NB>, 2 * COLOR_NB * SQUARE_NB> table{};
            for (bool q : {false, true})
                for (int c = 0; c < COLOR_NB; ++c)
                    for (int sq = 0; sq < SQUARE_NB; ++sq)
                    {
                        const u16 flip        = 56 * c;
                        const u16 orient      = u16(OrientTBL[sq]) ^ flip;
                        const u16 queenOffset = q ? PS_NB : 0;
                        for (int pieceIndex = 0; pieceIndex < PIECE_NB; ++pieceIndex)
                            table[(int(q) * COLOR_NB + c) * SQUARE_NB + sq][pieceIndex] =
                              PieceSquareIndex[c][pieceIndex] + KingBuckets[sq ^ flip]
                              + queenOffset + orient;
                    }
            return table;
        }();

        return IndexType(s)
             ^ offsets[(int(opponentHasQueen) * COLOR_NB + perspective) * SQUARE_NB + ksq][pc];
    }

    // Get a list of indices for recently changed features
    static sf_always_inline void append_changed_indices(Color           perspective,
                                                        Square          ksq,
                                                        const DiffType& diff,
                                                        bool            opponentHasQueen,
                                                        IndexList&      removed,
                                                        IndexList&      added) {
        removed.push_back(make_index(perspective, diff.from, diff.pc, ksq, opponentHasQueen));
        if (diff.to != SQ_NONE)
            added.push_back(make_index(perspective, diff.to, diff.pc, ksq, opponentHasQueen));

        if (diff.remove_sq != SQ_NONE)
            removed.push_back(
              make_index(perspective, diff.remove_sq, diff.remove_pc, ksq, opponentHasQueen));

        if (diff.add_sq != SQ_NONE)
            added.push_back(
              make_index(perspective, diff.add_sq, diff.add_pc, ksq, opponentHasQueen));
    }
#else
    static IndexType
    make_index(Color perspective, Square s, Piece pc, Square ksq, bool opponentHasQueen);

    static void append_changed_indices(Color           perspective,
                                       Square          ksq,
                                       const DiffType& diff,
                                       bool            opponentHasQueen,
                                       IndexList&      removed,
                                       IndexList&      added);
#endif

    // Returns whether the change stored in this DirtyPiece means
    // that a full accumulator refresh is required.
    static bool requires_refresh(const DiffType& diff, Color perspective);
};

}  // namespace Stockfish::Eval::NNUE::Features

#endif  // #ifndef NNUE_FEATURES_K32Q2_H_INCLUDED
