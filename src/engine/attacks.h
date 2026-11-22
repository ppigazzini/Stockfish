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

#ifndef ATTACKS_H_INCLUDED
#define ATTACKS_H_INCLUDED

#include <cassert>
#include <array>
#include <initializer_list>
#include <utility>

// Kept: DualMagic's rankAttacksLookup is a `const u8*`, and its member sits
// under `#ifndef USE_GFNI_RANK`. A GFNI host compiles that member out --
// x86-64-avx512icl is one -- so IWYU sees no use at that tier and asks for a
// removal that reds every build without GFNI, the tier a player ships.
#include "basetypes.h"  // IWYU pragma: keep
#include "types.h"
// Kept: RESTRICT, used below by DualMagic, expands to the __restrict__ KEYWORD.
// A macro that expands to a keyword leaves no AST node, so IWYU attributes no
// use to it and asks for a removal that reds every build.
#include "compiler.h"  // IWYU pragma: keep
#include "bitboard.h"

#if defined(USE_AVX2)
    // None of these is redundant: DualMagic's both_attacks_bb finishes in SSE --
    // _mm_cvtsi128_si64 is <emmintrin.h>, _mm_extract_epi64 is <smmintrin.h>,
    // and the _MM_SHUFFLE of the fold a GFNI host compiles out is
    // <xmmintrin.h> -- and <immintrin.h> reaching them is a property of this
    // toolchain, not of the language.
    #include <emmintrin.h>
    #include <immintrin.h>
    #include <smmintrin.h>
    #ifndef __GFNI__
        #include <xmmintrin.h>
    #endif
    #ifdef __GFNI__
        // vgf2p8affineqb reverses the bits inside every byte of a vector in one
        // instruction, which turns the byte reversal DualMagic already does into
        // a full 64-bit bit reversal -- the one thing a rank needs to be solved
        // by hyperbola quintessence like the other three rays.
        #define USE_GFNI_RANK
    #endif
#elif defined(__wasm_simd128__)
    #include <wasm_simd128.h>
#endif
#ifdef _MSC_VER
    #include <cstdlib>  // _byteswap_uint64()
#endif

namespace Stockfish::Attacks {

void init();

inline Bitboard byteswap_bb(Bitboard b) {
#if defined(_MSC_VER) && !defined(__clang__)
    return _byteswap_uint64(b);
#else
    return __builtin_bswap64(b);
#endif
}

// Sliding attacks by hyperbola quintessence,
// see https://www.chessprogramming.org/Hyperbola_Quintessence
struct alignas(32) DualMagic {
    // file, diagonal, rank, antidiagonal under USE_GFNI_RANK; file, diagonal,
    // antidiagonal, rank without it, where maskRank is zero: the reversal below
    // is then a byte reversal, which leaves a rank's bits inside their own byte
    // and so solves nothing on that lane. The order follows the fold each tier
    // takes further down.
#ifdef USE_GFNI_RANK
    Bitboard maskFile, maskDiag, maskRank, maskAntidiag;
#else
    Bitboard maskFile, maskDiag, maskAntidiag, maskRank;
#endif
    // Precomputed 2 * square_bb(sq), 2 * reverse(square_bb(sq)), where reverse
    // is the FULL bit reversal -- which is what the GFNI lane performs and what
    // the byte-reversing lane agrees with wherever a mask can reach.
    Bitboard r, rr;

#ifndef USE_GFNI_RANK
    const u8* RESTRICT rankAttacksLookup;
    // 8 * rank_of(sq)
    int shift;
#endif

    // We always compute [bishop, rook] attacks at once, then rely on
    // compiler's DCE and CSE to eliminate unneeded re-computations or extractions.
    //
    // When using hyperbola quintessence, file, diagonal and antidiagonal attacks
    // can use a byte reversal rather than a full bit reversal (because all squares
    // reside in different bytes). Rank attacks cannot: without GFNI they take a
    // compact lookup table indexed by the 6 inner bits of the rank's occupancy
    // (the edge squares never affect the attack set), and with it they take the
    // lane the three ray masks leave empty.
    sf_always_inline std::pair<Bitboard, Bitboard> both_attacks_bb(Bitboard occupied) const {

#ifndef USE_GFNI_RANK
        Bitboard rowOccupancy = rankAttacksLookup[(occupied >> (shift + 1)) & 0x3f];
        Bitboard rankAttacks  = rowOccupancy << shift;
#endif

#ifdef USE_AVX2
        // Reverse each 64-bit lane: vpshufb reverses the bytes, and under GFNI
        // the affine transform by the anti-diagonal matrix reverses the bits
        // inside each byte. Byte order across the two halves of a 128-bit lane
        // is immaterial -- rrs below is broadcast and the second call undoes it.
        const auto reverse = [](__m256i v) {
            v = _mm256_shuffle_epi8(v, _mm256_set_epi8(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13,
                                                       14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
                                                       12, 13, 14, 15));
    #ifdef USE_GFNI_RANK
            v = _mm256_gf2p8affine_epi64_epi8(v, _mm256_set1_epi64x(0x8040201008040201ULL), 0);
    #endif
            return v;
        };

        // Each lane contains a mask and we follow the scalar algorithm below
        const __m256i mask = _mm256_load_si256(reinterpret_cast<const __m256i*>(this));
        const __m256i rs   = _mm256_set1_epi64x(r);
        const __m256i rrs  = _mm256_set1_epi64x(rr);

        __m256i o      = _mm256_and_si256(mask, _mm256_set1_epi64x(occupied));
        __m256i fwd    = _mm256_sub_epi64(o, rs);
        __m256i rev    = reverse(_mm256_sub_epi64(reverse(o), rrs));
        __m256i result = _mm256_and_si256(_mm256_xor_si256(fwd, rev), mask);

    #ifdef USE_GFNI_RANK
        // Lanes 0 and 2: rook attacks (file, rank); lanes 1 and 3: bishop
        const __m128i rookBishop =
          _mm_or_si128(_mm256_extracti128_si256(result, 1), _mm256_castsi256_si128(result));

        // [bishop, rook]
        return {_mm_extract_epi64(rookBishop, 1), _mm_cvtsi128_si64(rookBishop)};
    #else
        // Lane 0: rook attacks (file only); lanes 1 and 2: bishop attacks
        const __m256i rookBishop =
          _mm256_or_si256(result, _mm256_permute4x64_epi64(result, _MM_SHUFFLE(3, 1, 2, 0)));

        // [bishop, rook]
        // Lane 3 is empty here -- maskRank is zero without USE_GFNI_RANK -- so the
        // rook's file attacks are already in result's low lane, and reading them
        // there rather than out of rookBishop drops the OR from the dependency
        // chain.
        return {_mm_extract_epi64(_mm256_castsi256_si128(rookBishop), 1),
                _mm_cvtsi128_si64(_mm256_castsi256_si128(result)) + rankAttacks};
    #endif
#elif defined(__wasm_simd128__)
        // Byteswap within each 64-bit lane
        const auto bswap = [](v128_t v) {
            return wasm_i8x16_shuffle(v, v, 7, 6, 5, 4, 3, 2, 1, 0, 15, 14, 13, 12, 11, 10, 9, 8);
        };

        const v128_t occ = wasm_i64x2_splat(i64(occupied));
        const v128_t rs  = wasm_i64x2_splat(i64(r));
        const v128_t rrs = wasm_i64x2_splat(i64(rr));

        // Two lanes of the scalar algorithm below
        const auto hyperbola2 = [&](v128_t mask) {
            const v128_t o   = wasm_v128_and(mask, occ);
            const v128_t fwd = wasm_i64x2_sub(o, rs);
            const v128_t rev = bswap(wasm_i64x2_sub(bswap(o), rrs));
            return wasm_v128_and(wasm_v128_xor(fwd, rev), mask);
        };

        // Bishop: [diagonal, antidiagonal]; rook: [file, none]. A query for one
        // piece type then computes only one vector.
        const v128_t diags = hyperbola2(wasm_v128_load(&maskDiag));
        const v128_t file  = hyperbola2(wasm_v128_load64_zero(&maskFile));

        // [bishop, rook]
        return {Bitboard(wasm_i64x2_extract_lane(diags, 0) | wasm_i64x2_extract_lane(diags, 1)),
                Bitboard(wasm_i64x2_extract_lane(file, 0)) + rankAttacks};
#else
        const auto hyperbola = [&](Bitboard mask) {
            Bitboard o = occupied & mask;
            return ((o - r) ^ byteswap_bb(byteswap_bb(o) - rr)) & mask;
        };

        // [bishop, rook]
        return {hyperbola(maskDiag) | hyperbola(maskAntidiag), hyperbola(maskFile) + rankAttacks};
#endif
    }
};

extern const std::array<DualMagic, SQUARE_NB> DualMagics;
inline const DualMagic&                       dual_magic(Square s) { return DualMagics[s]; }

extern Bitboard LineBB[SQUARE_NB][SQUARE_NB];
extern Bitboard BetweenBB[SQUARE_NB][SQUARE_NB];
extern Bitboard inverse_RayPassBB[SQUARE_NB][SQUARE_NB];
extern Bitboard DiagBB[SQUARE_NB];
extern Bitboard AntiDiagBB[SQUARE_NB];

// horizontal/vertical/diagonal line passing through s1 and s2
inline Bitboard line_bb(Square s1, Square s2) {
    assert(is_ok(s1) && is_ok(s2));
    return LineBB[s1][s2];
}

// horizontal/vertical/diagonal line segment from s1 to s2,
// excluding s1 but including s2
inline Bitboard between_bb(Square s1, Square s2) {
    assert(is_ok(s1) && is_ok(s2));
    return BetweenBB[s1][s2];
}

// ray going from s1 to s2 and past, excluding s1
inline Bitboard ray_pass_bb(Square s1, Square s2) {
    assert(is_ok(s1) && is_ok(s2));
    return inverse_RayPassBB[s2][s1];
}

inline Bitboard diag_bb(Square s) {
    assert(is_ok(s));
    return DiagBB[s];
}

inline Bitboard antidiag_bb(Square s) {
    assert(is_ok(s));
    return AntiDiagBB[s];
}

// Returns the bitboard of target square for the given step
// from the given square. If the step is off the board, returns empty bitboard.
constexpr Bitboard safe_destination(Square s, int step) {
    constexpr auto abs = [](int v) { return v < 0 ? -v : v; };
    Square         to  = Square(s + step);
    return is_ok(to) && abs(file_of(s) - file_of(to)) <= 2 ? square_bb(to) : Bitboard(0);
}

constexpr Bitboard sliding_attack(PieceType pt, Square sq, Bitboard occupied) {
    Bitboard            attacks             = 0;
    constexpr Direction RookDirections[4]   = {NORTH, SOUTH, EAST, WEST};
    constexpr Direction BishopDirections[4] = {NORTH_EAST, SOUTH_EAST, SOUTH_WEST, NORTH_WEST};

    for (Direction d : (pt == ROOK ? RookDirections : BishopDirections))
        for (Square s = sq; Bitboard dest = safe_destination(s, d); s += d)
        {
            attacks |= dest;
            if (occupied & dest)
                break;
        }

    return attacks;
}

constexpr Bitboard knight_attack(Square sq) {
    Bitboard b = {};
    for (int step : {-17, -15, -10, -6, 6, 10, 15, 17})
        b |= safe_destination(sq, step);
    return b;
}

constexpr Bitboard king_attack(Square sq) {
    Bitboard b = {};
    for (int step : {-9, -8, -7, -1, 1, 7, 8, 9})
        b |= safe_destination(sq, step);
    return b;
}

constexpr Bitboard pseudo_attacks(PieceType pt, Square sq) {
    switch (pt)
    {
    case PieceType::ROOK :
    case PieceType::BISHOP :
        return sliding_attack(pt, sq, 0);
    case PieceType::QUEEN :
        return sliding_attack(PieceType::ROOK, sq, 0) | sliding_attack(PieceType::BISHOP, sq, 0);
    case PieceType::KNIGHT :
        return knight_attack(sq);
    case PieceType::KING :
        return king_attack(sq);
    default :
        assert(false);
        return 0;
    }
}

inline constexpr auto PseudoAttacks = []() constexpr {
    std::array<std::array<Bitboard, SQUARE_NB>, PIECE_TYPE_NB> attacks{};

    for (Square s1 = SQ_A1; s1 <= SQ_H8; ++s1)
    {
        attacks[WHITE][s1] = pawn_attacks_bb<WHITE>(square_bb(s1));
        attacks[BLACK][s1] = pawn_attacks_bb<BLACK>(square_bb(s1));

        attacks[KING][s1]   = pseudo_attacks(KING, s1);
        attacks[KNIGHT][s1] = pseudo_attacks(KNIGHT, s1);
        attacks[QUEEN][s1] = attacks[BISHOP][s1] = pseudo_attacks(BISHOP, s1);
        attacks[QUEEN][s1] |= attacks[ROOK][s1]  = pseudo_attacks(ROOK, s1);
    }

    return attacks;
}();

// Returns the pseudo attacks of the given piece type
// assuming an empty board.
sf_always_inline Bitboard attacks_bb(PieceType pt, Square s, Color c = COLOR_NB) {

    assert((pt != PAWN || c < COLOR_NB) && is_ok(s));
    return pt == PAWN ? PseudoAttacks[c][s] : PseudoAttacks[pt][s];
}

// Returns the attacks by the given piece
// assuming the board is occupied according to the passed Bitboard.
// Sliding piece attacks do not continue past an occupied square.
sf_always_inline Bitboard attacks_bb(PieceType pt, Square s, Bitboard occupied) {

    assert(pt != PAWN && is_ok(s));

    [[maybe_unused]] const auto [bishop, rook] = dual_magic(s).both_attacks_bb(occupied);

    switch (pt)
    {
    case BISHOP :
        return bishop;
    case ROOK :
        return rook;
    case QUEEN :
        return bishop | rook;
    default :
        return PseudoAttacks[pt][s];
    }
}

inline std::pair<Bitboard, Bitboard> both_attacks_bb(Square s, Bitboard occupied) {
    return dual_magic(s).both_attacks_bb(occupied);
}

}  // namespace Stockfish::Attacks

#endif  // #ifndef ATTACKS_H_INCLUDED
