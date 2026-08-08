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

#ifndef MISC_H_INCLUDED
#define MISC_H_INCLUDED

#include <algorithm>
#include <atomic>
#include <cassert>
#include <exception>  // IWYU pragma: keep
// IWYU pragma: no_include <__exception/terminate.h>
#include <functional>
#include <filesystem>
#include <iosfwd>
#include <optional>
#include <string>
#include <string_view>
#include <type_traits>
#include <vector>

#if !defined(NO_PREFETCH) && (defined(_MSC_VER) || defined(__INTEL_COMPILER))
    #include <immintrin.h>
#endif

#include "../engine/basetypes.h"

#define stringify2(x) #x
#define stringify(x) stringify2(x)

namespace Stockfish {


std::string engine_version_info();
std::string engine_info(bool to_uci = false);
std::string compiler_info();


void start_logger(const std::filesystem::path& fname);

std::optional<usize> str_to_size_t(const std::string& s);

std::string           utf8_from_wstring(std::wstring_view s);
std::filesystem::path path_from_utf8(const std::string& path);

// Reads the file as bytes.
// Returns std::nullopt if the file does not exist.
std::optional<std::string> read_file_to_string(const std::string& path);



inline std::vector<std::string_view> split(std::string_view s, std::string_view delimiter) {
    std::vector<std::string_view> res;

    if (s.empty())
        return res;

    usize begin = 0;
    for (;;)
    {
        const usize end = s.find(delimiter, begin);
        if (end == std::string::npos)
            break;

        res.emplace_back(s.substr(begin, end - begin));
        begin = end + delimiter.size();
    }

    res.emplace_back(s.substr(begin));

    return res;
}

void remove_whitespace(std::string& s);
bool is_whitespace(std::string_view s);







// Wrapper around std::atomic<T> which uses relaxed accesses or plain
// accesses, depending on the config. Intended use is e.g. wasm where
// the overhead of atomic instructions can be significant, and we only
// require non-tearing for the updates, while ensuring we use relaxed
// accesses otherwise.
template<typename T>
class RelaxedAtomic {
    static constexpr bool UseAtomic =
#ifdef USE_SLOPPY_ATOMICS
      !std::atomic<T>::is_always_lock_free || sizeof(T) > sizeof(usize);
#else
      true;
#endif

   public:
    RelaxedAtomic() = default;
    RelaxedAtomic(T val) :
        inner(val) {}
    RelaxedAtomic(const RelaxedAtomic& a) :
        inner(static_cast<T>(a)) {}

    T operator=(T val) {
        if constexpr (UseAtomic)
            inner.store(val, std::memory_order_relaxed);
        else
            inner = val;
        return val;
    }

    RelaxedAtomic& operator=(const RelaxedAtomic& a) {
        this->store(static_cast<T>(a), std::memory_order_relaxed);
        return *this;
    }

    operator T() const {
        if constexpr (UseAtomic)
            return inner.load(std::memory_order_relaxed);
        else
            return inner;
    }

    RelaxedAtomic& operator+=(T val) {
        T res = this->load(std::memory_order_relaxed) + val;
        this->store(res, std::memory_order_relaxed);
        return *this;
    }

    RelaxedAtomic& operator++() {
        T res = this->load(std::memory_order_relaxed) + 1;
        this->store(res, std::memory_order_relaxed);
        return *this;
    }

    RelaxedAtomic& operator--() {
        T res = this->load(std::memory_order_relaxed) - 1;
        this->store(res, std::memory_order_relaxed);
        return *this;
    }

    T operator++(int) {
        T val = this->load(std::memory_order_relaxed);
        this->store(val + 1, std::memory_order_relaxed);
        return val;
    }

    T operator--(int) {
        T val = this->load(std::memory_order_relaxed);
        this->store(val - 1, std::memory_order_relaxed);
        return val;
    }

    RelaxedAtomic& operator-=(T val) {
        T res = this->load(std::memory_order_relaxed) - val;
        this->store(res, std::memory_order_relaxed);
        return *this;
    }

    T load(std::memory_order order) const {
        assert(order == std::memory_order_relaxed);
        if constexpr (UseAtomic)
            return inner.load(order);
        else
            return inner;
    }

    void store(T val, std::memory_order order) {
        assert(order == std::memory_order_relaxed);
        if constexpr (UseAtomic)
            inner.store(val, order);
        else
            inner = val;
    }

   private:
    std::conditional_t<UseAtomic, std::atomic<T>, T> inner;
};

// xorshift64star Pseudo-Random Number Generator
// This class is based on original code written and dedicated
// to the public domain by Sebastiano Vigna (2014).
// It has the following characteristics:
//
//  -  Outputs 64-bit numbers
//  -  Passes Dieharder and SmallCrush test batteries
//  -  Does not require warm-up, no zeroland to escape
//  -  Internal state is a single 64-bit integer
//  -  Period is 2^64 - 1
//  -  Speed: 1.60 ns/call (Core i7 @3.40GHz)
//
// For further analysis see
//   <http://vigna.di.unimi.it/ftp/papers/xorshift.pdf>

class PRNG {

    u64 s;

    u64 rand64() {

        s ^= s >> 12, s ^= s << 25, s ^= s >> 27;
        return s * 2685821657736338717LL;
    }

   public:
    PRNG(u64 seed) :
        s(seed) {
        assert(seed);
    }

    template<typename T>
    T rand() {
        return T(rand64());
    }

    // Special generator used to fast init magic numbers.
    // Output values only have 1/8th of their bits set on average.
    template<typename T>
    T sparse_rand() {
        return T(rand64() & rand64() & rand64());
    }
};

inline usize mul_hi64(u64 a, usize b) {
#if defined(__GNUC__) && defined(IS_64BIT) && !defined(__wasm__)
    return (u128(a) * u128(b)) >> 64;
#else
    u64 aL = u32(a), aH = a >> 32;
    u64 bL = u32(b), bH = u64(b) >> 32;
    u64 c1 = (aL * bL) >> 32;
    u64 c2 = aH * bL + c1;
    u64 c3 = aL * bH + u32(c2);
    return aH * bH + (c2 >> 32) + (c3 >> 32);
#endif
}

template<typename T1, typename T2>
inline constexpr T2 interpolate(T1 x, T1 x0, T1 x1, T2 y0, T2 y1) {
    assert(x0 != x1);
    return T2(y0 + (y1 - y0) * (x - x0) / (x1 - x0));
}



struct CommandLine {
   public:
    CommandLine(int _argc, char** _argv);

    CommandLine(const CommandLine&)            = delete;
    CommandLine& operator=(const CommandLine&) = delete;
    CommandLine(CommandLine&&)                 = default;
    CommandLine& operator=(CommandLine&&)      = default;

    static std::filesystem::path get_binary_directory(std::filesystem::path argv0);
    static std::filesystem::path get_working_directory();

    int    argc;
    char** argv;

   private:
#ifdef _WIN32
    std::vector<std::string> argv_storage;
    std::vector<char*>       argv_utf8;
#endif
};

namespace Utility {

template<typename T, typename Predicate>
void move_to_front(std::vector<T>& vec, Predicate pred) {
    auto it = std::find_if(vec.begin(), vec.end(), pred);

    if (it != vec.end())
    {
        std::rotate(vec.begin(), it, it + 1);
    }
}
}

#ifndef __has_builtin
    #define __has_builtin(x) 0
#endif

#if defined(__GNUC__)
    #define sf_always_inline __attribute__((always_inline))
#elif defined(_MSC_VER)
    #define sf_always_inline __forceinline
#else
    // do nothing for other compilers
    #define sf_always_inline
#endif

#if defined(__clang__)
    #define sf_assume(cond) __builtin_assume(cond)
#elif defined(__GNUC__)
    #if __GNUC__ >= 13
        #define sf_assume(cond) __attribute__((assume(cond)))
    #else
        #define sf_assume(cond) \
            do \
            { \
                if (!(cond)) \
                    __builtin_unreachable(); \
            } while (0)
    #endif
#elif defined(_MSC_VER)
    #define sf_assume(cond) __assume(cond)
#else
    // do nothing for other compilers
    #define sf_assume(cond)
#endif

#ifdef __GNUC__
    #define sf_unreachable() __builtin_unreachable()
#elif defined(_MSC_VER)
    #define sf_unreachable() __assume(0)
#else
    #define sf_unreachable()
#endif

void set_console_utf8();

}  // namespace Stockfish

#endif  // #ifndef MISC_H_INCLUDED
