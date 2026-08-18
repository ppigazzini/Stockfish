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

// _BitScanForward64 for the word decoder below, on the one compiler that spells
// it that way. Kept out of the tier block above: it is a property of the
// compiler and not of the vector width, and every other arm of the decoder's
// selection is preprocessed away before an include lane sees it.
#if defined(_MSC_VER) && defined(_WIN64) && !defined(__clang__)
    #include <intrin.h>
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
using WeightType       = i16;
using PSQTWeightType   = i32;
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

constexpr const char  Leb128MagicString[]   = "COMPRESSED_LEB128";
constexpr const usize Leb128MagicStringSize = sizeof(Leb128MagicString) - 1;

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

// The word decoder below reads eight stream bytes as one integer and needs a
// count-trailing-zeros. Both are properties of the compiler rather than of the
// format, so where either is missing the decoder is compiled out entirely and
// the byte loop -- which is still present, and still what handles every tail --
// decodes the whole file. Neither arm changes a single decoded value.
#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && defined(__GNUC__)
constexpr bool LebWordDecode = __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__;
inline u32     leb_ctz64(u64 b) { return u32(__builtin_ctzll(b)); }
#elif defined(_MSC_VER) && defined(_WIN64) && !defined(__clang__)
constexpr bool LebWordDecode = true;
inline u32     leb_ctz64(u64 b) {
    unsigned long idx;
    _BitScanForward64(&idx, b);
    return u32(idx);
}
#else
constexpr bool LebWordDecode = false;
inline u32     leb_ctz64(u64) { return 0; }
#endif

// How far left a payload of n+1 groups must be shifted to put its top bit in
// bit 31, so that one arithmetic shift back both discards the groups the window
// picked up from the NEXT value and sign-extends this one. Index 4 is zero
// because 35 bits of payload leave nothing above the truncation to 32 to extend
// into, which is the `shift >= 32` arm of the byte loop.
constexpr u32 LebShift[5] = {25, 18, 11, 4, 0};

// Read N signed integers from the stream s, putting them in the array out.
// The stream is assumed to be compressed using the signed LEB128 format.
// See https://en.wikipedia.org/wiki/LEB128 for a description of the compression scheme.
// `buf_end` is how many bytes the last refill ACTUALLY delivered, and it is the
// whole difference between decoding a file and decoding the stack behind it.
// The refill asked for min(bytes_left, buf.size()) and recorded nothing, so a
// length field of 0 refilled nothing, the cursor still read all 8192 slots, and
// `--bytes_left` wrapped 0 to 0xFFFFFFFF. Under -DNDEBUG the magic check and the
// balance assert are both gone, so a release build loaded 8 KiB of uninitialised
// stack as network weights and said nothing.
//
// A short read is now a FAILED STREAM. Every read_parameters in the tree already
// ends in `return !stream.fail()`, so setting failbit reports the file through
// the path the callers already have, with no signature to change.
//
// The per-byte cost is unchanged: the refill test was a compare against a
// constant and is now a compare against a variable.
template<typename BufType, typename IntType>
inline void read_leb_128_detail(std::istream& stream,
                                IntType*      out,
                                usize         Count,
                                u32&          bytes_left,
                                BufType&      buf,
                                u32&          buf_pos,
                                u32&          buf_end) {

    static_assert(std::is_signed_v<IntType>, "Not implemented for unsigned types");
    static_assert(sizeof(IntType) <= 4, "Not implemented for types larger than 32 bit");
    static_assert((i32(-1) >> 1) == i32(-1), "Right shift of a negative must be arithmetic");

    // THE CURSOR IS HELD IN LOCALS and written back on the way out. All three
    // of these are reference parameters -- the caller's fold expression carries
    // them from one array to the next -- and the loop below contains a
    // stream.read() the compiler cannot prove does not alias them, so used
    // directly they are reloaded every byte. Adding `buf_end` as a fourth
    // reference and reading it per byte cost 12.2M startup instructions, 1.7%
    // of what this decoder spends. Locals cost nothing and the write-back is
    // once per call.
    u32 pos = buf_pos, end = buf_end, left = bytes_left;

    // Accumulate UNSIGNED. `(byte & 0x7f) << (shift % 32)` overflows a signed
    // int at shift 28 and 31, which a retrained net can reach and no shipped
    // net does.
    u32   result = 0;
    usize shift = 0, i = 0;
    while (i < Count)
    {
        // A whole value out of one 8-byte window, with no branch on the
        // continuation bit. Entered only at a value boundary and only with 8
        // bytes buffered, so it can neither straddle a refill nor read past
        // `end`; everything it declines is left to the byte loop below.
        if (LebWordDecode && shift == 0)
        {
            // A 16-bit output cannot need more than three groups, so its
            // compaction is two terms shorter and its window three bytes
            // narrower. That is 94% of a network file by weight count.
            constexpr u32 Groups = sizeof(IntType) <= 2 ? 3 : 5;
            static_assert(Groups <= sizeof(LebShift) / sizeof(LebShift[0]),
                          "the refusal bounds the table index");

            // ONE loop test, not three. A value consumes at most `Groups`
            // bytes, so from a cursor with a full window behind it the next
            // (end - 8 - pos) / Groups + 1 values are all in bounds; the test
            // for the window and the test for `left` both come out of the loop
            // and the byte budget is spent as a value budget. The buffer is
            // 8 KiB and the bound is conservative by a factor of `Groups`, so
            // this is re-entered two or three times per refill.
            const u32   pos0  = pos;
            const usize limit = end - pos < 8
                                ? i
                                : std::min(Count, i + usize((end - 8 - pos) / Groups) + 1);

            while (i < limit)
            {
                u64 word;
                std::memcpy(&word, &buf[pos], 8);

                // Byte 7's continuation bit is REPLACED by a set sentinel, so a
                // window of eight continuation bytes reports length 8 rather
                // than a zero the count-trailing-zeros could not be asked
                // about. Any length past `Groups` leaves the value to the byte
                // loop, which decodes a redundant or malformed encoding
                // correctly and slowly.
                const u64 term = (~word & 0x0080808080808080ull) | 0x8000000000000000ull;
                const u32 last = leb_ctz64(term) >> 3;  // index of the final byte
                if (last >= Groups)
                    break;

                // Each mask selects one 7-bit group already shifted into place,
                // so the continuation bits need no separate clearing.
                u32 value = u32(word) & 0x7Fu;
                value |= u32(word >> 1) & 0x3F80u;
                if constexpr (Groups > 2)
                    value |= u32(word >> 2) & 0x1FC000u;
                if constexpr (Groups > 3)
                    value |= u32(word >> 3) & 0xFE00000u;
                if constexpr (Groups > 4)
                    value |= u32(word >> 4) & 0xF0000000u;

                const u32 sh = LebShift[last];
                out[i++]     = IntType(i32(value << sh) >> sh);
                pos += last + 1;
            }

            // `left` is the balance the closing check reads, so it is exact --
            // but it is a function of the cursor, and paying for it once per
            // value is paying twice for the same subtraction.
            left -= pos - pos0;

            if (i == Count)
                break;
        }

        if (pos == end)
        {
            stream.read(reinterpret_cast<char*>(buf.data()), std::min(usize(left), buf.size()));
            pos = 0;
            end = u32(stream.gcount());

            if (end == 0)
            {
                buf_pos = pos, buf_end = end, bytes_left = left;
                stream.setstate(std::ios::failbit);
                return;
            }
        }

        u8 byte = buf[pos++];
        --left;
        result |= u32(byte & 0x7f) << (shift % 32);
        shift += 7;

        if ((byte & 0x80) == 0)
        {
            out[i++] = IntType(
              (shift >= 32 || (byte & 0x40) == 0) ? result : result | ~((u32(1) << shift) - 1));
            result = 0;
            shift  = 0;
        }
    }

    buf_pos = pos, buf_end = end, bytes_left = left;
}

// The magic string and the closing balance are the ONLY integrity checks this
// format has, and both were asserts -- deleted from every shipped binary by
// -DNDEBUG. What rejected a corrupt net in a release build was an incidental
// stream.peek(). Both are returned failures now.
template<typename... Arrays>
inline void read_leb_128(std::istream& stream, Arrays&... outs) {
    // Check the presence of our LEB128 magic string
    char leb128MagicString[Leb128MagicStringSize];
    stream.read(leb128MagicString, Leb128MagicStringSize);
    if (stream.gcount() != Leb128MagicStringSize
        || strncmp(Leb128MagicString, leb128MagicString, Leb128MagicStringSize) != 0)
    {
        stream.setstate(std::ios::failbit);
        return;
    }

    auto                 bytes_left = read_little_endian<u32>(stream);
    std::array<u8, 8192> buf;
    u32                  buf_pos = 0, buf_end = 0;

    (read_leb_128_detail(stream, outs.data(), outs.size(), bytes_left, buf, buf_pos, buf_end), ...);

    if (bytes_left != 0)
        stream.setstate(std::ios::failbit);
}


template<typename IntType>
inline void read_leb_128(std::istream& stream, IntType* out, usize expected) {
    // Check the presence of our LEB128 magic string
    char leb128MagicString[Leb128MagicStringSize];
    stream.read(leb128MagicString, Leb128MagicStringSize);
    if (stream.gcount() != Leb128MagicStringSize
        || strncmp(Leb128MagicString, leb128MagicString, Leb128MagicStringSize) != 0)
    {
        stream.setstate(std::ios::failbit);
        return;
    }

    auto                 bytes_left = read_little_endian<u32>(stream);
    std::array<u8, 8192> buf;
    u32                  buf_pos = 0, buf_end = 0;

    read_leb_128_detail(stream, out, expected, bytes_left, buf, buf_pos, buf_end);

    if (bytes_left != 0)
        stream.setstate(std::ios::failbit);
}


// Write signed integers to a stream with LEB128 compression.
// This takes N integers from array values, compresses them with
// the LEB128 algorithm and writes the result on the stream s.
// See https://en.wikipedia.org/wiki/LEB128 for a description of the compression scheme.
template<typename IntType>
inline void write_leb_128(std::ostream& stream, const IntType* values, usize Count) {

    // Write our LEB128 magic string
    stream.write(Leb128MagicString, Leb128MagicStringSize);

    static_assert(std::is_signed_v<IntType>, "Not implemented for unsigned types");

    u32 byte_count = 0;
    for (usize i = 0; i < Count; ++i)
    {
        IntType value = values[i];
        u8      byte;
        do
        {
            byte = value & 0x7f;
            value >>= 7;
            ++byte_count;
        } while ((byte & 0x40) == 0 ? value != 0 : value != -1);
    }

    write_little_endian(stream, byte_count);

    const u32 BUF_SIZE = 4096;
    u8        buf[BUF_SIZE];
    u32       buf_pos = 0;

    auto flush = [&]() {
        if (buf_pos > 0)
        {
            stream.write(reinterpret_cast<char*>(buf), buf_pos);
            buf_pos = 0;
        }
    };

    auto write = [&](u8 b) {
        buf[buf_pos++] = b;
        if (buf_pos == BUF_SIZE)
            flush();
    };

    for (usize i = 0; i < Count; ++i)
    {
        IntType value = values[i];
        while (true)
        {
            u8 byte = value & 0x7f;
            value >>= 7;
            if ((byte & 0x40) == 0 ? value == 0 : value == -1)
            {
                write(byte);
                break;
            }
            write(byte | 0x80);
        }
    }

    flush();
}

template<typename IntType, usize Count>
inline void write_leb_128(std::ostream& stream, const std::array<IntType, Count>& values) {
    write_leb_128(stream, values.data(), Count);
}

}  // namespace Stockfish::Eval::NNUE

#endif  // #ifndef NNUE_COMMON_H_INCLUDED
