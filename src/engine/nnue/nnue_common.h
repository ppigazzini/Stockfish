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

// Constants used in NNUE evaluation function

#ifndef NNUE_COMMON_H_INCLUDED
#define NNUE_COMMON_H_INCLUDED

#include <algorithm>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <type_traits>

#include "../compiler.h"

#if defined(USE_AVX2)
    #include <immintrin.h>

#elif defined(USE_SSE41)
    #include <smmintrin.h>

#elif defined(USE_SSSE3)
    #include <tmmintrin.h>

#elif defined(USE_SSE2)
    #include <emmintrin.h>

#elif defined(USE_LASX)
    #include <lasxintrin.h>
    #include <lsxintrin.h>

#elif defined(USE_LSX)
    #include <lsxintrin.h>

#elif defined(USE_NEON)
    #include <arm_neon.h>
#endif

namespace Stockfish::Eval::NNUE {

// Read a T out of a byte buffer. A static_assert, an alignment check and a
// memcpy: no OS in it, so it is the engine's own primitive and not the host's.
//
// The alignment branch is load-bearing and is NOT a bounds check. A misaligned
// buffer asserts and then hits __builtin_unreachable(), so an NDEBUG build
// treats alignment as a PROMISE rather than testing it -- the network parser
// aligns its buffers by construction. Removing the assert leaves the promise
// with no diagnostic in a debug build either.
//
// Scoped to NNUE because every caller is: the three of them read weights and an
// nnz bitset out of the network file.
template<typename T, typename ByteT>
T load_as(const ByteT* buffer) {
    static_assert(std::is_trivially_copyable<T>::value, "Type must be trivially copyable");
    static_assert(sizeof(ByteT) == 1);

    if (reinterpret_cast<uintptr_t>(buffer) % alignof(T) != 0)
    {
        assert(false);
#ifdef __GNUC__
        __builtin_unreachable();
#endif
    }

    T value;
    std::memcpy(&value, buffer, sizeof(T));

    return value;
}

using BiasType         = i16;
using ThreatWeightType = i8;
using WeightType       = i8;
using IndexType        = u32;

// Version of the evaluation file
constexpr u32 Version = 0x6A448AFAu;

// Constant used in evaluation value calculation
constexpr int OutputScale     = 16;
constexpr int WeightScaleBits = 6;
constexpr int FtMaxVal        = 255;
constexpr int HiddenOneVal    = 128;

// Size of cache line (in bytes)
constexpr usize CacheLineSize = 64;


// SIMD width (in bytes)
#if defined(USE_AVX2)
constexpr usize SimdWidth = 32;

#elif defined(USE_LASX)
constexpr usize SimdWidth = 32;

#elif defined(USE_SSE2)
constexpr usize SimdWidth = 16;

#elif defined(USE_NEON)
constexpr usize SimdWidth = 16;

#elif defined(USE_LSX)
constexpr usize SimdWidth = 16;
#endif

constexpr usize MaxSimdWidth = 32;

// Type of input feature after conversion
using TransformedFeatureType = u8;

// Round n up to be a multiple of base
template<typename IntType>
constexpr IntType ceil_to_multiple(IntType n, IntType base) {
    return (n + base - 1) / base * base;
}


// Utility to read an integer (signed or unsigned, any size)
// from a stream in little-endian order. We swap the byte order after the read if
// necessary to return a result with the byte ordering of the compiling machine.
//
// THE BUFFER IS ZEROED, THE RESULT IS NOT, and the difference is the whole
// point. A short read writes fewer than sizeof(IntType) bytes and sets failbit;
// the bytes it did not reach keep whatever was in the storage, so reading the
// object back is an indeterminate-value read. Zeroing a byte array before the
// read makes those bytes 0 with no branch and no test of the stream, which is
// what a test would have cost -- `stream`'s operator bool calls fail(), and
// fail() lives in the VIRTUAL base basic_ios, so reaching it needs a vtable
// vbase offset. gcount() is a plain member of basic_istream and would have been
// cheaper, but neither is needed.
//
// The register's reason for leaving this alone was wrong. It recorded the value
// as harmless because "every caller tests the stream immediately and discards
// it" -- `read_leb_128` does not. It takes this result as `bytes_left` and
// spends it as a byte budget before it looks at the stream at all.
//
// One array serves both arms, which is where the gcc win comes from:
// `IsLittleEndian` is a runtime bool, not a constant, so reading into `&result`
// on one arm compiled two `stream.read` call sites. Zeroing the RESULT was
// measured and rejected -- `result = 0` costs 12.8M startup instructions under
// gcc, 1.7% of the 731M this header's LEB128 decoder spends, by perturbing what
// gets inlined here.
template<typename IntType>
inline IntType read_little_endian(std::istream& stream) {
    u8 u[sizeof(IntType)] = {};

    stream.read(reinterpret_cast<char*>(u), sizeof(IntType));

    IntType result;

    if (IsLittleEndian)
        std::memcpy(&result, u, sizeof(IntType));
    else
    {
        std::make_unsigned_t<IntType> v = 0;

        for (usize i = 0; i < sizeof(IntType); ++i)
            v = (v << 8) | u[sizeof(IntType) - i - 1];

        std::memcpy(&result, &v, sizeof(IntType));
    }

    return result;
}


// Utility to write an integer (signed or unsigned, any size)
// to a stream in little-endian order. We swap the byte order before the write if
// necessary to always write in little-endian order, independently of the byte
// ordering of the compiling machine.
template<typename IntType>
inline void write_little_endian(std::ostream& stream, IntType value) {

    if (IsLittleEndian)
        stream.write(reinterpret_cast<const char*>(&value), sizeof(IntType));
    else
    {
        u8                            u[sizeof(IntType)];
        std::make_unsigned_t<IntType> v = value;

        usize i = 0;
        // if constexpr to silence the warning about shift by 8
        if constexpr (sizeof(IntType) > 1)
        {
            for (; i + 1 < sizeof(IntType); ++i)
            {
                u[i] = u8(v);
                v >>= 8;
            }
        }
        u[i] = u8(v);

        stream.write(reinterpret_cast<char*>(u), sizeof(IntType));
    }
}


// Read integers in bulk from a little-endian stream.
// This reads N integers from stream s and puts them in array out.
template<typename IntType>
inline void read_little_endian(std::istream& stream, IntType* out, usize count) {
    if (IsLittleEndian)
        stream.read(reinterpret_cast<char*>(out), sizeof(IntType) * count);
    else
        for (usize i = 0; i < count; ++i)
            out[i] = read_little_endian<IntType>(stream);
}


// Write integers in bulk to a little-endian stream.
// This takes N integers from array values and writes them on stream s.
template<typename IntType>
inline void write_little_endian(std::ostream& stream, const IntType* values, usize count) {
    if (IsLittleEndian)
        stream.write(reinterpret_cast<const char*>(values), sizeof(IntType) * count);
    else
        for (usize i = 0; i < count; ++i)
            write_little_endian<IntType>(stream, values[i]);
}


}  // namespace Stockfish::Eval::NNUE

#endif  // #ifndef NNUE_COMMON_H_INCLUDED
