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

// Decide the NNUE LEB128 reader against the format, not against a shipped file.
//
// THE NET IS ONE STREAM AND IT EXERCISES ONE SHAPE. Every value in it is a
// weight, so it is 16-bit and minimally encoded, its lengths are 1 or 2 bytes,
// and the 23 M of them straddle a refill boundary only 3800 times. The reader
// is specified for more than that: 32-bit values, five-group payloads, a
// redundant encoding a hostile file may carry, a value split across a refill,
// and a stream that stops in the middle of one. `bench` cannot see any of it --
// a decoder that got all five wrong would still load the net and still print
// the anchor.
//
// So the reference is the WRITER, which is in the same header and which no
// optimisation of the reader touches. Round-tripping proves the pair, and the
// hand-built cases below prove what the writer will never emit.
//
//   tests/leb128 [iterations]
//
// Exit: 0 all cases pass, 1 a case failed, 2 the rig itself failed.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include "../src/engine/nnue/nnue_common.h"

using namespace Stockfish;
using namespace Stockfish::Eval::NNUE;

namespace {

int failures = 0;
int cases    = 0;

void report(const char* name, bool ok, const std::string& detail = "") {
    ++cases;
    if (!ok)
    {
        ++failures;
        std::printf("leb128: FAIL  %-28s %s\n", name, detail.c_str());
    }
    else
        std::printf("leb128: ok    %s\n", name);
}

// Round-trip a vector through the writer and the reader.
template<typename IntType>
bool roundtrip(const std::vector<IntType>& in, std::string& detail) {
    std::ostringstream out;
    write_leb_128(out, in.data(), in.size());

    std::vector<IntType> back(in.size(), IntType(0x5A));
    std::istringstream   is(out.str());
    read_leb_128(is, back.data(), back.size());

    if (is.fail())
    {
        detail = "stream failed on a stream the writer produced";
        return false;
    }
    for (usize i = 0; i < in.size(); ++i)
        if (in[i] != back[i])
        {
            char buf[160];
            std::snprintf(buf, sizeof(buf), "value %zu: wrote %lld, read %lld", usize(i),
                          (long long) in[i], (long long) back[i]);
            detail = buf;
            return false;
        }
    return true;
}

// Build a stream by hand: magic, byte count, then the bytes as given.
std::string handmade(const std::vector<u8>& bytes) {
    std::string s(Leb128MagicString, Leb128MagicStringSize);
    u32         n = u32(bytes.size());
    for (int i = 0; i < 4; ++i)
        s.push_back(char(u8(n >> (8 * i))));
    s.append(reinterpret_cast<const char*>(bytes.data()), bytes.size());
    return s;
}

template<typename IntType>
bool decodes_to(const std::vector<u8>& bytes, const std::vector<IntType>& want, std::string& detail) {
    std::vector<IntType> got(want.size(), IntType(0x5A));
    std::istringstream   is(handmade(bytes));
    read_leb_128(is, got.data(), got.size());

    if (is.fail())
    {
        detail = "stream failed";
        return false;
    }
    for (usize i = 0; i < want.size(); ++i)
        if (want[i] != got[i])
        {
            char buf[160];
            std::snprintf(buf, sizeof(buf), "value %zu: want %lld, got %lld", usize(i),
                          (long long) want[i], (long long) got[i]);
            detail = buf;
            return false;
        }
    return true;
}

// Put a hand-built sequence deep inside a stream, with filler before and after.
//
// THE WORD DECODER NEEDS EIGHT BUFFERED BYTES and a value boundary, so a stream
// of eight bytes is decoded entirely by the byte loop -- a fixture made of short
// streams tests the fallback and reports it as coverage. Found by mutation: the
// fast path's length refusal was widened to accept six-group values and every
// hand-built case still passed, because not one of them reached it.
template<typename IntType>
bool embedded(const std::vector<u8>& bytes, const std::vector<IntType>& want, std::string& detail) {
    std::vector<u8>      all;
    std::vector<IntType> exp;

    for (int k = 0; k < 4096; ++k)
        all.push_back(0x11), exp.push_back(IntType(17));
    all.insert(all.end(), bytes.begin(), bytes.end());
    exp.insert(exp.end(), want.begin(), want.end());
    for (int k = 0; k < 64; ++k)
        all.push_back(0x7E), exp.push_back(IntType(-2));

    return decodes_to(all, exp, detail);
}

}  // namespace

int main(int argc, char** argv) {
    const int iterations = argc > 1 ? std::atoi(argv[1]) : 200;
    if (iterations <= 0)
    {
        std::fprintf(stderr, "leb128: iterations must be positive\n");
        return 2;
    }

    std::string detail;

    // -- the shape the net has, at every count that can land on a refill --------
    //
    // The reader refills 8192 bytes at a time and a weight is 1 or 2 of them, so
    // a value straddles the boundary only for particular counts. Sweeping the
    // count is how the straddle gets hit at all.
    {
        std::mt19937                          rng(20260814);
        std::uniform_int_distribution<int>    weight(-181, 181);  // what a net holds
        bool                                  ok = true;
        for (usize count : {usize(1), usize(2), usize(7), usize(4095), usize(4096), usize(4097),
                            usize(8191), usize(8192), usize(8193), usize(16384), usize(40000)})
        {
            std::vector<i16> v(count);
            for (auto& x : v)
                x = i16(weight(rng));
            if (!roundtrip(v, detail))
            {
                detail = "count " + std::to_string(count) + ": " + detail;
                ok     = false;
                break;
            }
        }
        report("net-shaped weights", ok, detail);
    }

    // -- the full 16-bit range, which a retrained net can reach ----------------
    {
        std::vector<i16> v;
        v.reserve(65536 + 8);
        for (int x = -32768; x <= 32767; ++x)
            v.push_back(i16(x));
        report("every i16", roundtrip(v, detail), detail);
    }

    // -- 32-bit values: the five-group payload the net never contains ----------
    {
        std::vector<i32> v = {0,          1,          -1,        63,        64,        -64,
                              -65,        8191,       8192,      -8192,     -8193,     1048575,
                              1048576,    -1048576,   -1048577,  134217727, 134217728, -134217728,
                              -134217729, 2147483647, -2147483647 - 1, 305419896, -305419896};
        report("i32 group boundaries", roundtrip(v, detail), detail);
    }

    // -- random i32, sweeping counts across the refill -------------------------
    {
        std::mt19937                            rng(981);
        std::uniform_int_distribution<i32>      any(-2147483647 - 1, 2147483647);
        bool                                    ok = true;
        for (int it = 0; it < iterations && ok; ++it)
        {
            std::vector<i32> v(usize(1 + (it * 373) % 5000));
            for (auto& x : v)
                x = any(rng);
            ok = roundtrip(v, detail);
        }
        report("random i32", ok, detail);
    }

    // -- a redundant encoding: legal LEB128 the writer will never emit ---------
    //
    // 0x80 0x80 0x00 is zero in three groups. A decoder that trusts the length
    // to be minimal reads it as something else, and no net in the tree contains
    // one.
    {
        std::vector<u8> bytes = {0x80, 0x80, 0x00,  // 0, three groups
                                 0xFF, 0x7F,        // -1, two groups
                                 0x80, 0x80, 0x80, 0x00,  // 0, four groups
                                 0x2A};                   // 42, one group
        report("redundant encodings", embedded<i16>(bytes, {0, -1, 0, 42}, detail), detail);
    }

    // -- an over-long encoding, where the reader's own rule is the reference ---
    //
    // Six groups for a 32-bit value is legal LEB128 and past what 32 bits hold.
    // The reader wraps the shift (`shift % 32`), so group 5 lands at bit 3 and
    // 0x80 0x80 0x80 0x80 0x80 0x01 is 8 -- and the value after it must still be
    // read from the right byte. A decoder that takes a short cut on the length
    // agrees on neither. This is the case that pins the fast path's refusal:
    // without it the refusal can be widened and every other case still passes.
    {
        std::vector<u8> bytes = {0x80, 0x80, 0x80, 0x80, 0x80, 0x01,  // 8, six groups
                                 0x2A,                                // 42
                                 0x7E};                               // -2
        report("i32 over-long encoding", embedded<i32>(bytes, {8, 42, -2}, detail), detail);
    }

    // -- a value longer than the window itself ---------------------------------
    //
    // Ten groups fills an eight-byte window with continuation bytes and leaves
    // the fast path's length search nothing to find. The byte loop's shift wraps
    // (`% 32`), so group 9 lands at bit 31 and the value is INT32_MIN; what is
    // being checked is that the window decoder hands this over rather than
    // reporting a length out of a window with no terminator in it.
    {
        std::vector<u8> bytes = {0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01,
                                 0x2A};
        report("value longer than the window",
               embedded<i32>(bytes, {-2147483647 - 1, 42}, detail), detail);
    }

    // -- a value whose groups straddle a refill --------------------------------
    //
    // 8192 is the buffer. Placing a multi-byte value so that its first group is
    // the last byte of one refill is the case the word decoder must decline and
    // the byte loop must carry.
    {
        bool ok = true;
        for (int split = 1; split <= 4 && ok; ++split)
        {
            std::vector<u8>  bytes;
            std::vector<i16> want;
            while (bytes.size() < usize(8192 - split))
            {
                bytes.push_back(0x01);
                want.push_back(1);
            }
            // -8193 needs three groups: 0xFF 0xBF 0x7F
            bytes.insert(bytes.end(), {0xFF, 0xBF, 0x7F});
            want.push_back(i16(-8193));
            for (int k = 0; k < 40; ++k)
            {
                bytes.push_back(0x7E);
                want.push_back(-2);
            }
            ok = decodes_to<i16>(bytes, want, detail);
            if (!ok)
                detail = "split " + std::to_string(split) + ": " + detail;
        }
        report("refill straddle", ok, detail);
    }

    // -- a stream that stops mid-value must FAIL, not invent a weight ----------
    //
    // Failing is half of it. THE OTHER HALF IS THAT NOTHING PAST THE TRUNCATION
    // IS WRITTEN, and it is the half a fail-only check cannot see: the balance
    // at the end of read_leb_128 catches a short read too, so a decoder that
    // reads its own stale buffer for the rest of the array and then reports the
    // leftover balance still sets failbit. That is the release build this
    // reader's own header describes -- 8 KiB of uninitialised stack loaded as
    // weights, and said nothing -- so the outputs are checked, not just the
    // stream state.
    {
        std::vector<i16>   got(4, i16(0x5A));
        std::string        s = handmade({0x2A, 0x81});  // one value, then a dangling group
        std::istringstream is(s);
        read_leb_128(is, got.data(), got.size());

        const bool untouched = got[1] == i16(0x5A) && got[2] == i16(0x5A) && got[3] == i16(0x5A);
        report("truncated stream fails", is.fail() && got[0] == 42 && untouched,
               !is.fail() ? "a short stream was accepted"
                          : !untouched ? "weights were written past the truncation"
                                       : "the value before the truncation was lost");
    }

    // -- a declared byte count larger than the stream must FAIL ----------------
    {
        std::string s = handmade({0x01, 0x02, 0x03});
        s[Leb128MagicStringSize] = char(u8(200));  // claim 200 bytes, supply 3
        std::vector<i16>   got(3, i16(0x5A));
        std::istringstream is(s);
        read_leb_128(is, got.data(), got.size());
        report("over-declared length fails", is.fail(),
               is.fail() ? "" : "a truncated body was accepted");
    }

    // -- a body longer than the values asked for must FAIL the balance ---------
    {
        std::vector<i16>   got(2, i16(0x5A));
        std::istringstream is(handmade({0x01, 0x02, 0x03}));
        read_leb_128(is, got.data(), got.size());
        report("unread trailing bytes fail", is.fail(),
               is.fail() ? "" : "a leftover balance was accepted");
    }

    // -- a wrong magic must FAIL before anything is decoded --------------------
    {
        std::string s = handmade({0x01});
        s[0]          = 'X';
        std::vector<i16>   got(1, i16(0x5A));
        std::istringstream is(s);
        read_leb_128(is, got.data(), got.size());
        report("wrong magic fails", is.fail() && got[0] == i16(0x5A),
               is.fail() ? "the output was touched" : "a wrong magic was accepted");
    }

    std::printf("leb128: %d cases, %d failed\n", cases, failures);
    return failures ? 1 : 0;
}
