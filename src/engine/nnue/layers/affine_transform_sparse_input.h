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

// Definition of layer AffineTransformSparseInput of NNUE evaluation function

#ifndef NNUE_LAYERS_AFFINE_TRANSFORM_SPARSE_INPUT_H_INCLUDED
#define NNUE_LAYERS_AFFINE_TRANSFORM_SPARSE_INPUT_H_INCLUDED

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>

#include "../../bitboard.h"
#include "../simd.h"
#include "../nnue_common.h"
#include "../nnz_helper.h"
#include "../../hashing.h"

/*
  This file contains the definition for a fully connected layer (aka affine transform) with block sparse input.
*/

namespace Stockfish::Eval::NNUE::Layers {


// gcc breaks `tzcnt`'s false output dependency by zeroing the destination before
// every one of them. The dependency is real -- Intel carries it through Skylake --
// but the `xor` is one instruction of the eighteen this loop retires per non-zero
// chunk, and on this loop it protects nothing: the register it zeroes was last
// written by the previous iteration's shift, which retires long before the next
// dot product can issue, and the loop is bound by its FP ports at about three
// cycles an iteration on any part that has the erratum. clang emits no such idiom,
// so it must not be given this; neither must a target without BMI, where `tzcnt`
// does not exist and `bsf` has a true dependency the compiler is right about.
#if defined(__x86_64__) && defined(__BMI__) && defined(__GNUC__) && !defined(__clang__)
    #define SF_TZCNT_WITHOUT_DEPBREAK
#endif

namespace Detail {

inline usize lsb_index(u64 b) {
#if defined(SF_TZCNT_WITHOUT_DEPBREAK)
    u64 i;
    asm("tzcnt %1, %0" : "=r"(i) : "r"(b) : "cc");
    return usize(i);
#else
    return usize(lsb(Bitboard(b)));
#endif
}

// pop_lsb's shape, with the index taken through the helper above.
inline usize pop_lsb_index(u64& b) {
    const usize i = lsb_index(b);
    b &= b - 1;
    return i;
}

}  // namespace Detail

// Sparse input implementation
template<IndexType InDims, IndexType OutDims>
class AffineTransformSparseInput {
   public:
    // Input/output type
    using InputType  = u8;
    using OutputType = i32;

    // Number of input/output dimensions
    static constexpr IndexType InputDimensions  = InDims;
    static constexpr IndexType OutputDimensions = OutDims;

    static_assert(OutputDimensions % 16 == 0,
                  "Only implemented for OutputDimensions divisible by 16.");

    static constexpr IndexType PaddedInputDimensions =
      ceil_to_multiple<IndexType>(InputDimensions, MaxSimdWidth);
    static constexpr IndexType PaddedOutputDimensions =
      ceil_to_multiple<IndexType>(OutputDimensions, MaxSimdWidth);

#if (defined(USE_SSSE3) || defined(USE_LSX) || defined(USE_LASX) || (USE_NEON >= 8))
    static constexpr IndexType ChunkSize = 4;
#else
    static constexpr IndexType ChunkSize = 1;
#endif

    using OutputBuffer = OutputType[PaddedOutputDimensions];

    // Hash value embedded in the evaluation file
    static constexpr u32 get_hash_value(u32 prevHash) {
        u32 hashValue = 0xCC03DAE4u;
        hashValue += OutputDimensions;
        hashValue ^= prevHash >> 1;
        hashValue ^= prevHash << 31;
        return hashValue;
    }

    static constexpr IndexType get_weight_index_scrambled(IndexType i) {
        return (i / ChunkSize) % (PaddedInputDimensions / ChunkSize) * OutputDimensions * ChunkSize
             + i / PaddedInputDimensions * ChunkSize + i % ChunkSize;
    }

    static constexpr IndexType get_weight_index(IndexType i) {
#if (defined(USE_SSSE3) || defined(USE_LSX) || defined(USE_LASX) || (USE_NEON >= 8) \
     || defined(USE_RVV))
        return get_weight_index_scrambled(i);
#else
        return i;
#endif
    }

    // Read network parameters
    bool read_parameters(std::istream& stream) {
        read_little_endian<BiasType>(stream, biases, OutputDimensions);
        for (IndexType i = 0; i < OutputDimensions * PaddedInputDimensions; ++i)
            weights[get_weight_index(i)] = read_little_endian<WeightType>(stream);

        return !stream.fail();
    }

    // Write network parameters
    bool write_parameters(std::ostream& stream) const {
        write_little_endian<BiasType>(stream, biases, OutputDimensions);

        for (IndexType i = 0; i < OutputDimensions * PaddedInputDimensions; ++i)
            write_little_endian<WeightType>(stream, weights[get_weight_index(i)]);

        return !stream.fail();
    }

    usize get_content_hash() const {
        usize h = 0;
        hash_combine(h, get_raw_data_hash(biases));
        hash_combine(h, get_raw_data_hash(weights));
        hash_combine(h, get_hash_value(0));
        return h;
    }

    // Forward propagation
    void propagate(const InputType*                        input,
                   OutputType*                             output,
                   [[maybe_unused]] const NNZInfo<InDims>& nnzInfo) const {

#if (defined(USE_SSSE3) || defined(USE_LSX) || defined(USE_LASX) || (USE_NEON >= 8))
    #if defined(USE_AVX512)
        using invec_t  = __m512i;
        using outvec_t = __m512i;
        #define vec_add_32 _mm512_add_epi32
        #define vec_set_32 _mm512_set1_epi32
        #define vec_add_dpbusd_32 SIMD::m512_add_dpbusd_epi32
    #elif defined(USE_AVX2)
        using invec_t  = __m256i;
        using outvec_t = __m256i;
        #define vec_add_32 _mm256_add_epi32
        #define vec_set_32 _mm256_set1_epi32
        #define vec_add_dpbusd_32 SIMD::m256_add_dpbusd_epi32
    #elif defined(USE_SSSE3)
        using invec_t  = __m128i;
        using outvec_t = __m128i;
        #define vec_set_32 _mm_set1_epi32
        #define vec_add_dpbusd_32 SIMD::m128_add_dpbusd_epi32
    #elif defined(USE_NEON_DOTPROD)
        using invec_t  = int8x16_t;
        using outvec_t = int32x4_t;
        #define vec_set_32(a) vreinterpretq_s8_u32(vdupq_n_u32(a))
        #define vec_add_dpbusd_32 SIMD::dotprod_m128_add_dpbusd_epi32
    #elif defined(USE_NEON)
        using invec_t  = int8x16_t;
        using outvec_t = int32x4_t;
        #define vec_set_32(a) vreinterpretq_s8_u32(vdupq_n_u32(a))
        #define vec_add_dpbusd_32 SIMD::neon_m128_add_dpbusd_epi32
    #elif defined(USE_LASX)
        using invec_t  = __m256i;
        using outvec_t = __m256i;
        #define vec_add_32 __lasx_xvadd_w
        #define vec_set_32 __lasx_xvreplgr2vr_w
        #define vec_add_dpbusd_32 SIMD::lasx_m256_add_dpbusd_epi32
    #elif defined(USE_LSX)
        using invec_t  = __m128i;
        using outvec_t = __m128i;
        #define vec_add_32 __lsx_vadd_w
        #define vec_set_32 __lsx_vreplgr2vr_w
        #define vec_add_dpbusd_32 SIMD::lsx_m128_add_dpbusd_epi32
    #endif
    #if defined(USE_LASX)
        #define vec_load_32(a) __lasx_xvldrepl_w(reinterpret_cast<const void*>(a), 0)
    #elif defined(USE_LSX)
        #define vec_load_32(a) __lsx_vldrepl_w(reinterpret_cast<const void*>(a), 0)
    #else
        #define vec_load_32(a) vec_set_32(load_as<i32>(a))
    #endif
        constexpr IndexType OutputSimdWidth = sizeof(outvec_t) / sizeof(OutputType);
        constexpr IndexType NumAccums       = OutputDimensions / OutputSimdWidth;
        // If we're using high-latency dot product instructions, split the accumulators
        // into separate dependency chains and merge at the end
        constexpr IndexType NumRegs =
    #if (defined(USE_VNNI) && defined(USE_AVX512)) || defined(USE_NEON_DOTPROD)
          3 * NumAccums;
    #elif defined(USE_AVXVNNI)
          2 * NumAccums;
    #else
          NumAccums;
    #endif

    // The bitset walk below carries the sums in a block-local copy, so on that arm `acc`
    // is written only at the end of a block and the biases can seed block zero's copy
    // directly. Seeding `acc` here instead leaves four vector stores of the biases into an
    // array nothing ever reads: gcc gives a set that is live across the four blocks a
    // memory image beside the registers, and DSE does not take the image away.
    #if !defined(USE_AVX512) && !defined(USE_AVXVNNI) && !defined(USE_NEON_DOTPROD) \
      && defined(__GNUC__) && !defined(__clang__)
        #define SF_FC0_SEED_BLOCK_ZERO
    #endif

        const outvec_t* biasvec = reinterpret_cast<const outvec_t*>(biases);
        outvec_t        acc[NumRegs];
    #if !defined(SF_FC0_SEED_BLOCK_ZERO)
        for (IndexType k = 0; k < NumAccums; ++k)
            acc[k] = biasvec[k];
    #endif

    #if defined(USE_AVXVNNI)
        for (IndexType k = NumAccums; k < NumRegs; ++k)
            acc[k] = vec_set_32(0);
    #elif defined(USE_NEON_DOTPROD)
        for (IndexType k = NumAccums; k < NumRegs; ++k)
            acc[k] = vdupq_n_s32(0);
    #endif

        // convince GCC to not do weird pointer arithmetic in the following loops
        const i8* weights_cp = weights;

    #if defined(USE_AVX512)
        const auto* start = nnzInfo.nnz;
        const auto* end   = nnzInfo.nnz + nnzInfo.count;

        // The VNNI walk below carries three dependency chains, and gcc gives the two seeded
        // from vec_zero() a register copy in and a register copy out on EVERY iteration --
        // eight per three chunks, 26 instructions where clang retires 18. It is not the
        // array: naming the six accumulators as six variables reproduces it exactly. It is
        // that all four zero-seeded chains enter their phi with the SAME value, which gcc
        // materialises once and then cannot coalesce four ways, so the allocator splits
        // every one of them and copies around the split. An empty asm makes each seed an
        // opaque value of its own, costs no instruction, and the eight copies go. clang
        // coalesces this already and takes six copies if it is given the barrier, so the
        // #else branch spells the tokens it compiled before.
    #if defined(__x86_64__) && defined(__GNUC__) && !defined(__clang__)
        for (IndexType k = NumAccums; k < NumRegs; ++k)
        {
            acc[k] = vec_zero();
            asm("" : "+v"(acc[k]));  // opt barrier
        }
    #else
        for (IndexType k = NumAccums; k < NumRegs; ++k)
            acc[k] = vec_zero();
    #endif
        #if defined(USE_VNNI)
        while (start < end - 2)
        {
            const isize   i0  = *start++;
            const isize   i1  = *start++;
            const isize   i2  = *start++;
            const invec_t in0 = vec_load_32(input + i0 * sizeof(i32));
            const invec_t in1 = vec_load_32(input + i1 * sizeof(i32));
            const invec_t in2 = vec_load_32(input + i2 * sizeof(i32));
            const auto    col0 =
              reinterpret_cast<const invec_t*>(&weights_cp[i0 * OutputDimensions * ChunkSize]);
            const auto col1 =
              reinterpret_cast<const invec_t*>(&weights_cp[i1 * OutputDimensions * ChunkSize]);
            const auto col2 =
              reinterpret_cast<const invec_t*>(&weights_cp[i2 * OutputDimensions * ChunkSize]);
            for (IndexType k = 0; k < NumAccums; ++k)
            {
                vec_add_dpbusd_32(acc[k], in0, col0[k]);
                vec_add_dpbusd_32(acc[k + NumAccums], in1, col1[k]);
                vec_add_dpbusd_32(acc[k + 2 * NumAccums], in2, col2[k]);
            }
        }

        for (IndexType k = 0; k < NumAccums; ++k)
            acc[k] = vec_add_32(vec_add_32(acc[k], acc[k + NumAccums]), acc[k + 2 * NumAccums]);
        #endif

        while (start < end)
        {
            const isize   i  = *start++;
            const invec_t in = vec_load_32(input + i * sizeof(i32));
            const auto    col =
              reinterpret_cast<const invec_t*>(&weights_cp[i * OutputDimensions * ChunkSize]);
            for (IndexType k = 0; k < NumAccums; ++k)
                vec_add_dpbusd_32(acc[k], in, col[k]);
        }
    #else
        static_assert(InputDimensions % 256 == 0);
    #ifdef SF_FC0_SEED_BLOCK_ZERO
        // Block zero seeds the running sums from the biases, so the walk below has to run.
        static_assert(InputDimensions >= 256);
    #endif

        // Straight-line the blocks. The trip count is four for L1 = 1024 and known at compile
        // time, but gcc rolls the loop anyway and pays a bitset load, two pointer copies for
        // the barrier below, three pointer increments, a compare and a back edge on each
        // pass. Unrolling is only safe once the walk runs on the block-local copy below:
        // against the array it costs four register copies per NON-ZERO CHUNK, which is the
        // coalescing failure that shape provokes, so the guard excludes the two inner loops
        // that still accumulate into `acc` directly. clang straight-lines this already and
        // never sees the pragma.
    #if defined(__GNUC__) && !defined(__clang__) && !defined(USE_AVXVNNI) \
      && !defined(USE_NEON_DOTPROD)
        #pragma GCC unroll 4
    #endif
        for (IndexType k = 0; k < InputDimensions / 256; ++k)
        {
            u64   bits = load_as<u64>(nnzInfo.bitset + k * 8);
            isize base = k * 64;

            auto* base_addr    = input + base * sizeof(i32);
            auto* weights_base = &weights_cp[base * OutputDimensions * ChunkSize];

        #if defined(USE_NEON_DOTPROD) && defined(__GNUC__) && !defined(__clang__)
            // GCC 15 pessimizes the following code on ARM64 by eliding the intermediate
            // computation of key pointers (base_addr, weights_base, col, input_addr), leading
            // to a lot of redundant indexing arithmetic in the while (bits) loop. The
            // optimization barriers force these pointers to be calculated and used.
            #if __GNUC__ >= 15
                #define FIX_GCC15_MISOPTIMIZATION
            #endif
        #endif

        // x86-64 gcc elides the same two pointers and rebases each access on the array
        // start, paying an add per non-zero chunk to undo what the block loop already
        // computed. Only the BLOCK pointers are pinned: pinning col and input_addr as
        // well, which FIX_GCC15_MISOPTIMIZATION does, costs an instruction back by
        // keeping the per-iteration addresses out of the memory operands.
        #if defined(__x86_64__) && defined(__GNUC__) && !defined(__clang__)
            #define SF_BLOCK_BASE_BARRIER
        #endif

        // Pin the input broadcast ahead of the weight offset. The chunk index is scaled by 4
        // for the input and by 128 for the weights, and x86 addressing scales by at most 8,
        // so one of the two reaches a register through a shift; pinning the load first leaves
        // the index dead at the shift, and gcc then shifts it in place rather than copying it
        // and shifting the copy. The barrier has to stand between the load and col: below col
        // it buys nothing. clang already emits the shape it produces, and must not be told.
        #if defined(__x86_64__) && defined(__GNUC__) && !defined(__clang__)
            #define SF_PIN_INPUT_BROADCAST
        #endif

        #if defined(FIX_GCC15_MISOPTIMIZATION) || defined(SF_BLOCK_BASE_BARRIER)
            asm("" : "+r"(base_addr), "+r"(weights_base));  // opt barrier
        #endif

        #if defined(USE_AVXVNNI)
            while (bits)
            {
                const isize   i0   = isize(Detail::pop_lsb_index(bits));
                const invec_t in0  = vec_load_32(base_addr + i0 * sizeof(i32));
                const auto    col0 = reinterpret_cast<const invec_t*>(
                  &weights_base[i0 * OutputDimensions * ChunkSize]);

                if (!bits)
                {
                    for (IndexType l = 0; l < NumAccums; ++l)
                        vec_add_dpbusd_32(acc[l], in0, col0[l]);
                    break;
                }

                const isize   i1   = isize(Detail::pop_lsb_index(bits));
                const invec_t in1  = vec_load_32(base_addr + i1 * sizeof(i32));
                const auto    col1 = reinterpret_cast<const invec_t*>(
                  &weights_base[i1 * OutputDimensions * ChunkSize]);

                for (IndexType l = 0; l < NumAccums; ++l)
                {
                    vec_add_dpbusd_32(acc[l], in0, col0[l]);
                    vec_add_dpbusd_32(acc[l + NumAccums], in1, col1[l]);
                }
            }
        #elif defined(USE_NEON_DOTPROD)
            while (bits)
            {
                const isize i0 = isize(Detail::pop_lsb_index(bits));
                if (!bits)
                {
                    const invec_t in0  = vec_load_32(base_addr + i0 * sizeof(i32));
                    const auto    col0 = reinterpret_cast<const invec_t*>(
                      &weights_base[i0 * OutputDimensions * ChunkSize]);
                    for (IndexType l = 0; l < NumAccums; ++l)
                        vec_add_dpbusd_32(acc[l], in0, col0[l]);
                    break;
                }

                const isize i1 = isize(Detail::pop_lsb_index(bits));
                if (!bits)
                {
                    const invec_t in0  = vec_load_32(base_addr + i0 * sizeof(i32));
                    const invec_t in1  = vec_load_32(base_addr + i1 * sizeof(i32));
                    const auto    col0 = reinterpret_cast<const invec_t*>(
                      &weights_base[i0 * OutputDimensions * ChunkSize]);
                    const auto col1 = reinterpret_cast<const invec_t*>(
                      &weights_base[i1 * OutputDimensions * ChunkSize]);
                    for (IndexType l = 0; l < NumAccums; ++l)
                    {
                        vec_add_dpbusd_32(acc[l], in0, col0[l]);
                        vec_add_dpbusd_32(acc[l + NumAccums], in1, col1[l]);
                    }
                    break;
                }

                const isize   i2   = isize(Detail::pop_lsb_index(bits));
                const invec_t in0  = vec_load_32(base_addr + i0 * sizeof(i32));
                const invec_t in1  = vec_load_32(base_addr + i1 * sizeof(i32));
                const invec_t in2  = vec_load_32(base_addr + i2 * sizeof(i32));
                const auto    col0 = reinterpret_cast<const invec_t*>(
                  &weights_base[i0 * OutputDimensions * ChunkSize]);
                const auto col1 = reinterpret_cast<const invec_t*>(
                  &weights_base[i1 * OutputDimensions * ChunkSize]);
                const auto col2 = reinterpret_cast<const invec_t*>(
                  &weights_base[i2 * OutputDimensions * ChunkSize]);
                for (IndexType l = 0; l < NumAccums; ++l)
                {
                    vec_add_dpbusd_32(acc[l], in0, col0[l]);
                    vec_add_dpbusd_32(acc[l + NumAccums], in1, col1[l]);
                    vec_add_dpbusd_32(acc[l + 2 * NumAccums], in2, col2[l]);
                }
            }
        #else
            // Walk the block on a block-local copy of the accumulator set. `acc` is live
            // across all four blocks, and gcc answers that by keeping a memory image of the
            // array beside the registers it already uses: it writes the four biases out
            // before the block loop, writes the sums out again after it under a flag
            // recording whether any chunk was seen at all, and reads them back for the
            // activation. Copying into values whose live range ends with the block gets the
            // array scalarised instead, and the second store batch, the reload and the flag
            // all go. clang keeps the sums in registers either way and is unchanged.
            outvec_t blockAcc[NumAccums];
        #ifdef SF_FC0_SEED_BLOCK_ZERO
            for (IndexType l = 0; l < NumAccums; ++l)
                blockAcc[l] = k == 0 ? biasvec[l] : acc[l];
        #else
            for (IndexType l = 0; l < NumAccums; ++l)
                blockAcc[l] = acc[l];
        #endif

            while (bits)
            {
                isize       i          = isize(Detail::pop_lsb_index(bits));
                const auto* input_addr = base_addr + i * sizeof(i32);
                invec_t     in         = vec_load_32(input_addr);

            #ifdef SF_PIN_INPUT_BROADCAST
                asm("" : "+x"(in));  // opt barrier
            #endif

                auto col =
                  reinterpret_cast<const invec_t*>(&weights_base[i * OutputDimensions * ChunkSize]);

            #ifdef FIX_GCC15_MISOPTIMIZATION
                asm("" : "+r"(col), "+r"(input_addr));
                #undef FIX_GCC15_MISOPTIMIZATION
            #endif

                for (IndexType l = 0; l < NumAccums; ++l)
                    vec_add_dpbusd_32(blockAcc[l], in, col[l]);
            }

            for (IndexType l = 0; l < NumAccums; ++l)
                acc[l] = blockAcc[l];
        #endif
        }

        #if defined(USE_AVXVNNI)
        for (IndexType l = 0; l < NumAccums; ++l)
            acc[l] = vec_add_32(acc[l], acc[l + NumAccums]);
        #elif defined(USE_NEON_DOTPROD)
        for (IndexType l = 0; l < NumAccums; ++l)
            acc[l] = vaddq_s32(vaddq_s32(acc[l], acc[l + NumAccums]), acc[l + 2 * NumAccums]);
        #endif
    #endif
    #ifdef SF_FC0_SEED_BLOCK_ZERO
        #undef SF_FC0_SEED_BLOCK_ZERO
    #endif
        outvec_t* outptr = reinterpret_cast<outvec_t*>(output);
        for (IndexType k = 0; k < NumAccums; ++k)
            outptr[k] = acc[k];

    #undef vec_set_32
    #undef vec_load_32
    #undef vec_add_dpbusd_32
    #ifdef vec_add_32
        #undef vec_add_32
    #endif
#elif defined(USE_RVV)
        // we don't support larger for now
        static_assert(OutputDimensions <= 128 * 8 / 32);

    #define RVV_SPARSE_PROPAGATE(m1, m2, m4) \
        do \
        { \
            usize          vl  = OutputDimensions; \
            vint32##m4##_t acc = __riscv_vle32_v_i32##m4(biases, vl); \
            IndexType      i   = 0; \
            for (; i + 2 <= nnzInfo.count; i += 2) \
            { \
                usize         idx0 = nnzInfo.nnz[i + 0]; \
                usize         idx1 = nnzInfo.nnz[i + 1]; \
                uint8_t       in0  = input[idx0]; \
                uint8_t       in1  = input[idx1]; \
                vint8##m1##_t w0   = __riscv_vle8_v_i8##m1(&weights[idx0 * OutputDimensions], vl); \
                vint8##m1##_t w1   = __riscv_vle8_v_i8##m1(&weights[idx1 * OutputDimensions], vl); \
                /* input is in [0:127], weights is in [-128:127], \
                 * so it's safe to accumulate into 16-bit twice */ \
                vint16##m2##_t prod = __riscv_vwmulsu(w0, in0, vl); \
                prod                = __riscv_vwmaccus(prod, in1, w1, vl); \
                acc                 = __riscv_vwadd_wv(acc, prod, vl); \
            } \
            if (i < nnzInfo.count) \
            { \
                usize          idx  = nnzInfo.nnz[i]; \
                uint8_t        in   = input[idx]; \
                vint8##m1##_t  w    = __riscv_vle8_v_i8##m1(&weights[idx * OutputDimensions], vl); \
                vint16##m2##_t prod = __riscv_vwmulsu(w, in, vl); \
                acc                 = __riscv_vwadd_wv(acc, prod, vl); \
            } \
            __riscv_vse32(output, acc, vl); \
        } while (0)

        // Select LMUL
        const usize VL1 = __riscv_vsetvlmax_e32m1();
        if (VL1 >= OutputDimensions)
            RVV_SPARSE_PROPAGATE(mf4, mf2, m1);
        else if (VL1 * 2 >= OutputDimensions)
            RVV_SPARSE_PROPAGATE(mf2, m1, m2);
        else if (VL1 * 4 >= OutputDimensions)
            RVV_SPARSE_PROPAGATE(m1, m2, m4);
        else
            RVV_SPARSE_PROPAGATE(m2, m4, m8);

    #undef RVV_SPARSE_PROPAGATE
#else
        // Use dense implementation for the other architectures.
        affine_transform_non_ssse3<InputDimensions, PaddedInputDimensions, OutputDimensions>(
          output, weights, biases, input);
#endif
    }

   private:
    using BiasType   = OutputType;
    using WeightType = i8;

    alignas(CacheLineSize) BiasType biases[OutputDimensions];
    alignas(CacheLineSize) WeightType weights[OutputDimensions * PaddedInputDimensions];
};

}  // namespace Stockfish::Eval::NNUE::Layers

#endif  // #ifndef NNUE_LAYERS_AFFINE_TRANSFORM_SPARSE_INPUT_H_INCLUDED
