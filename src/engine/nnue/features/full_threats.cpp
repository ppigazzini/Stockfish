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

//Definition of input features FullThreats of NNUE evaluation function

#include "full_threats.h"

#include <array>
#include <cstdint>
#include <initializer_list>
#include <utility>

#include "../../attacks.h"
#include "../../bitboard.h"
#include "../../position.h"
#include "../../types.h"
#include "../nnue_common.h"
#include "../../compiler.h"
#include "../../basetypes.h"

namespace Stockfish::Eval::NNUE::Features {

struct HelperOffsets {
    int cumulativePieceOffset, cumulativeOffset;
};

constexpr std::array<Piece, 12> AllPieces = {
  W_PAWN, W_KNIGHT, W_BISHOP, W_ROOK, W_QUEEN, W_KING,
  B_PAWN, B_KNIGHT, B_BISHOP, B_ROOK, B_QUEEN, B_KING,
};

template<PieceType PT>
constexpr auto make_piece_indices_type() {
    static_assert(PT != PieceType::PAWN);

    std::array<std::array<u8, SQUARE_NB>, SQUARE_NB> out{};

    for (Square from = SQ_A1; from <= SQ_H8; ++from)
    {
        Bitboard attacks = Attacks::PseudoAttacks[PT][from];

        for (Square to = SQ_A1; to <= SQ_H8; ++to)
        {
            out[from][to] = constexpr_popcount(((1ULL << to) - 1) & attacks);
        }
    }

    return out;
}

template<Piece P>
constexpr auto make_piece_indices_piece() {
    static_assert(type_of(P) == PieceType::PAWN);

    std::array<std::array<u8, SQUARE_NB>, SQUARE_NB> out{};

    constexpr Color C = color_of(P);

    for (Square from = SQ_A1; from <= SQ_H8; ++from)
    {
        Bitboard attacks = Attacks::PseudoAttacks[C][from];

        for (Square to = SQ_A1; to <= SQ_H8; ++to)
        {
            out[from][to] = constexpr_popcount(((1ULL << to) - 1) & attacks);
        }
    }

    return out;
}

constexpr auto index_lut2_array() {
    constexpr auto KNIGHT_ATTACKS = make_piece_indices_type<PieceType::KNIGHT>();
    constexpr auto BISHOP_ATTACKS = make_piece_indices_type<PieceType::BISHOP>();
    constexpr auto ROOK_ATTACKS   = make_piece_indices_type<PieceType::ROOK>();
    constexpr auto QUEEN_ATTACKS  = make_piece_indices_type<PieceType::QUEEN>();
    constexpr auto KING_ATTACKS   = make_piece_indices_type<PieceType::KING>();

    std::array<std::array<std::array<u8, SQUARE_NB>, SQUARE_NB>, PIECE_NB> indices{};

    indices[W_PAWN] = make_piece_indices_piece<W_PAWN>();
    indices[B_PAWN] = make_piece_indices_piece<B_PAWN>();

    indices[W_KNIGHT] = KNIGHT_ATTACKS;
    indices[B_KNIGHT] = KNIGHT_ATTACKS;

    indices[W_BISHOP] = BISHOP_ATTACKS;
    indices[B_BISHOP] = BISHOP_ATTACKS;

    indices[W_ROOK] = ROOK_ATTACKS;
    indices[B_ROOK] = ROOK_ATTACKS;

    indices[W_QUEEN] = QUEEN_ATTACKS;
    indices[B_QUEEN] = QUEEN_ATTACKS;

    indices[W_KING] = KING_ATTACKS;
    indices[B_KING] = KING_ATTACKS;

    return indices;
}

constexpr auto init_threat_offsets() {
    std::array<HelperOffsets, PIECE_NB>                    indices{};
    std::array<std::array<IndexType, SQUARE_NB>, PIECE_NB> offsets{};

    int cumulativeOffset = 0;
    for (Piece piece : AllPieces)
    {
        int pieceIdx              = piece;
        int cumulativePieceOffset = 0;

        for (Square from = SQ_A1; from <= SQ_H8; ++from)
        {
            offsets[pieceIdx][from] = cumulativePieceOffset;

            if (type_of(piece) != PAWN)
            {
                Bitboard attacks = Attacks::PseudoAttacks[type_of(piece)][from];
                cumulativePieceOffset += constexpr_popcount(attacks);
            }

            else if (from >= SQ_A2 && from <= SQ_H7)
            {
                Bitboard attacks = (pieceIdx < 8) ? Attacks::PseudoAttacks[WHITE][from]
                                                  : Attacks::PseudoAttacks[BLACK][from];
                cumulativePieceOffset += constexpr_popcount(attacks);
            }
        }

        indices[pieceIdx] = {cumulativePieceOffset, cumulativeOffset};

        cumulativeOffset += numValidTargets[pieceIdx] * cumulativePieceOffset;
    }

    return std::pair{indices, offsets};
}

constexpr auto helper_offsets = init_threat_offsets().first;

constexpr auto init_index_luts() {
    std::array<std::array<std::array<u32, 2>, PIECE_NB>, PIECE_NB> indices{};

    for (Piece attacker : AllPieces)
    {
        for (Piece attacked : AllPieces)
        {
            bool      enemy        = (attacker ^ attacked) == 8;
            PieceType attackerType = type_of(attacker);
            PieceType attackedType = type_of(attacked);

            int  map           = FullThreats::map[attackerType - 1][attackedType - 1];
            bool semi_excluded = attackerType == attackedType && (enemy || attackerType != PAWN);
            IndexType feature  = helper_offsets[attacker].cumulativeOffset
                              + (color_of(attacked) * (numValidTargets[attacker] / 2) + map)
                                  * helper_offsets[attacker].cumulativePieceOffset;

            bool excluded                  = map < 0;
            indices[attacker][attacked][0] = excluded ? FullThreats::Dimensions : feature;
            indices[attacker][attacked][1] =
              excluded || semi_excluded ? FullThreats::Dimensions : feature;
        }
    }

    return indices;
}

// Every value in index_lut2 comes from PseudoAttacks, which tells the two pawn
// colours apart and nothing else, so the twelve pieces read seven rows.
constexpr IndexType NumAttackRows = 7;
constexpr IndexType AttackRowSize = SQUARE_NB * SQUARE_NB;

// [piece] -> the start of its row, already scaled, so make_index adds where a
// second subscript would shift first. Rows 0 and 1 are the white and the black
// pawn; rows 2..6 are the piece type, which is how PseudoAttacks indexes the
// rest. Widen the element before adding a row: the last start is 6 * 4096.
constexpr std::array<u16, PIECE_NB> AttackRowBase = {
  0 * AttackRowSize, 0 * AttackRowSize, 2 * AttackRowSize, 3 * AttackRowSize,
  4 * AttackRowSize, 5 * AttackRowSize, 6 * AttackRowSize, 0 * AttackRowSize,
  0 * AttackRowSize, 1 * AttackRowSize, 2 * AttackRowSize, 3 * AttackRowSize,
  4 * AttackRowSize, 5 * AttackRowSize, 6 * AttackRowSize, 0 * AttackRowSize};

constexpr auto init_threat_index() {
    constexpr auto squarePair = index_lut2_array();
    constexpr auto fromOffset = init_threat_offsets().second;

    std::array<u16, NumAttackRows * AttackRowSize> table{};

    for (Piece piece : AllPieces)
        for (Square from = SQ_A1; from <= SQ_H8; ++from)
            for (Square to = SQ_A1; to <= SQ_H8; ++to)
                table[AttackRowBase[piece] + from * SQUARE_NB + to] =
                  u16(fromOffset[piece][from] + squarePair[piece][from][to]);

    return table;
}

// The final index is the sum of these two LUTs

// [attacker][attacked][from < to]
constexpr auto index_lut1 = init_index_luts();
// [AttackRowBase[attacker] + from * SQUARE_NB + to], the from-offset and the
// square-pair count already summed; the largest entry is under 1500
constexpr auto index_lut2 = init_threat_index();

// Six pieces write a row another piece also writes, so a pair that disagreed
// anywhere would leave whichever of them ran last and no diagnostic. Enumerate
// the whole domain make_index reaches: twelve attackers by every square pair.
constexpr bool attack_rows_agree() {
    constexpr auto squarePair = index_lut2_array();
    constexpr auto fromOffset = init_threat_offsets().second;

    for (Piece piece : AllPieces)
        for (Square from = SQ_A1; from <= SQ_H8; ++from)
            for (Square to = SQ_A1; to <= SQ_H8; ++to)
                if (index_lut2[AttackRowBase[piece] + from * SQUARE_NB + to]
                    != fromOffset[piece][from] + squarePair[piece][from][to])
                    return false;

    return true;
}

static_assert(attack_rows_agree());

// Offset of the weight row a feature selects, for a given king position and
// another piece on some square -- the feature number scaled by the row stride.
sf_always_inline IndexType FullThreats::make_index(
  Color perspective, Piece attacker, Square from, Square to, Piece attacked, Square ksq) {
    const i8 orientation   = OrientTBL[ksq] ^ (56 * perspective);
    unsigned from_oriented = u8(from) ^ orientation;
    unsigned to_oriented   = u8(to) ^ orientation;

    i8       swap              = 8 * perspective;
    unsigned attacker_oriented = attacker ^ swap;
    unsigned attacked_oriented = attacked ^ swap;

    return (index_lut1[attacker_oriented][attacked_oriented][from_oriented < to_oriented]
            + index_lut2[AttackRowBase[attacker_oriented] + from_oriented * SQUARE_NB
                         + to_oriented])
        << RowShift;
}

// The excluded features index_lut1 marks with Dimensions stay above this bound
// under the scale, which is a multiplication by a positive constant.
constexpr IndexType RowLimit = FullThreats::Dimensions << FullThreats::RowShift;

// Get a list of indices for active features in ascending order

void FullThreats::append_active_indices(Color perspective, const Position& pos, IndexList& active) {
    const Square   ksq                = pos.square<KING>(perspective);
    const Bitboard occupied           = pos.pieces();
    const Bitboard pawnTargets        = pos.pieces(KNIGHT, ROOK);
    const Bitboard minorSliderTargets = pos.pieces(PAWN, KNIGHT, BISHOP, ROOK);
    const Bitboard queenTargets       = pos.pieces(PAWN, KNIGHT, BISHOP, ROOK, QUEEN);

    auto process_pawn_attacks = [&](Color c, Direction attkDir) {
        const Bitboard cPawns  = pos.pieces(c, PAWN);
        Bitboard       attacks = shift(cPawns, attkDir) & pawnTargets;
        while (attacks)
        {
            Square    to       = pop_lsb(attacks);
            Square    from     = to - attkDir;
            Piece     attacked = pos.piece_on(to);
            Piece     attacker = make_piece(c, PAWN);
            IndexType index    = make_index(perspective, attacker, from, to, attacked, ksq);
            active.push_back_if_lt(index, RowLimit);
        }
    };

    process_pawn_attacks(WHITE, NORTH_EAST);
    process_pawn_attacks(WHITE, NORTH_WEST);

    process_pawn_attacks(BLACK, SOUTH_WEST);
    process_pawn_attacks(BLACK, SOUTH_EAST);

    for (Color c : {WHITE, BLACK})
    {
        for (PieceType pt = KNIGHT; pt < KING; ++pt)
        {
            Piece    attacker = make_piece(c, pt);
            Bitboard bb       = pos.pieces(c, pt);
            Bitboard targets  = pt == KNIGHT || pt == QUEEN ? queenTargets : minorSliderTargets;
            while (bb)
            {
                Square   from    = pop_lsb(bb);
                Bitboard attacks = Attacks::attacks_bb(pt, from, occupied) & targets;
                while (attacks)
                {
                    Square    to       = pop_lsb(attacks);
                    Piece     attacked = pos.piece_on(to);
                    IndexType index    = make_index(perspective, attacker, from, to, attacked, ksq);
                    active.push_back_if_lt(index, RowLimit);
                }
            }
        }
    }
}

// Get a list of indices for recently changed features

void FullThreats::append_changed_indices(Color                   perspective,
                                         Square                  ksq,
                                         const DiffType&         diff,
                                         IndexList&              removed,
                                         IndexList&              added,
                                         const ThreatWeightType* prefetchBase) {

    for (const auto& dirty : diff.list)
    {
        auto attacker = dirty.pc();
        auto attacked = dirty.threatened_pc();
        auto from     = dirty.pc_sq();
        auto to       = dirty.threatened_sq();
        auto add      = dirty.add();

        auto&           insert = add ? added : removed;
        const IndexType index  = make_index(perspective, attacker, from, to, attacked, ksq);

        if (prefetchBase)
            prefetch<PrefetchRw::READ, PrefetchLoc::LOW>(reinterpret_cast<const void*>(
              reinterpret_cast<uintptr_t>(prefetchBase) + uintptr_t(index)));
        insert.push_back_if_lt(index, RowLimit);
    }
}

void FullThreats::append_changed_indices_both(Square                  white_ksq,
                                              Square                  black_ksq,
                                              const DiffType&         diff,
                                              IndexList&              white_removed,
                                              IndexList&              white_added,
                                              IndexList&              black_removed,
                                              IndexList&              black_added,
                                              const ThreatWeightType* prefetchBase) {

    // The add flag is a coin flip -- 3.070 of 6.839 trips, 44.9%, dead centre
    // of the predictor's worst band -- and this is the one site that pays for
    // it twice. gcc answers the two conditional references with a branch and
    // four stack reloads; an indexed pair costs the flag as a value, two loads,
    // and nothing to predict. The single-perspective spelling above already
    // lowers to cmov and is left alone.
    IndexList* const white_lists[2] = {&white_removed, &white_added};
    IndexList* const black_lists[2] = {&black_removed, &black_added};

    for (const auto& dirty : diff.list)
    {
        const Piece  attacker = dirty.pc();
        const Piece  attacked = dirty.threatened_pc();
        const Square from     = dirty.pc_sq();
        const Square to       = dirty.threatened_sq();
        const bool   add      = dirty.add();

        auto& white_insert = *white_lists[add];
        auto& black_insert = *black_lists[add];

        const IndexType white_index = make_index(WHITE, attacker, from, to, attacked, white_ksq);
        const IndexType black_index = make_index(BLACK, attacker, from, to, attacked, black_ksq);

        if (prefetchBase)
        {
            prefetch<PrefetchRw::READ, PrefetchLoc::LOW>(reinterpret_cast<const void*>(
              reinterpret_cast<uintptr_t>(prefetchBase) + uintptr_t(white_index)));
            prefetch<PrefetchRw::READ, PrefetchLoc::LOW>(reinterpret_cast<const void*>(
              reinterpret_cast<uintptr_t>(prefetchBase) + uintptr_t(black_index)));
        }

        white_insert.push_back_if_lt(white_index, RowLimit);
        black_insert.push_back_if_lt(black_index, RowLimit);
    }
}

}  // namespace Stockfish::Eval::NNUE::Features
