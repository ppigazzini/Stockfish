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

#ifndef HASHING_H_INCLUDED
#define HASHING_H_INCLUDED

#include <cstring>
#include <string>

#include "basetypes.h"

// Byte hashing. Engine rather than platform: it touches no OS, no process and
// no I/O -- it is arithmetic over bytes. Both zones call it, the NNUE net's
// content hash from engine/ and the shared-memory name hash from platform/, so
// keeping it here is what lets the engine side hash without including a
// platform header.
namespace Stockfish {

// Hash function based on public domain MurmurHash64A, by Austin Appleby.
inline u64 hash_bytes(const char* data, usize size) {
    const u64 m = 0xc6a4a7935bd1e995ull;
    const int r = 47;

    u64 h = size * m;

    const char* end = data + (size & ~(usize) 7);

    for (const char* p = data; p != end; p += 8)
    {
        u64 k;
        std::memcpy(&k, p, sizeof(k));

        k *= m;
        k ^= k >> r;
        k *= m;

        h ^= k;
        h *= m;
    }

    if (size & 7)
    {
        u64 k = 0;
        for (int i = (size & 7) - 1; i >= 0; i--)
            k = (k << 8) | u64(end[i]);

        h ^= k;
        h *= m;
    }

    h ^= h >> r;
    h *= m;
    h ^= h >> r;

    return h;
}

template<typename T>
inline usize get_raw_data_hash(const T& value) {
    // We must have no padding bytes because we're reinterpreting as char
    static_assert(std::has_unique_object_representations<T>());

    return static_cast<usize>(hash_bytes(reinterpret_cast<const char*>(&value), sizeof(value)));
}

template<typename T>
inline void hash_combine(usize& seed, const T& v) {
    usize x;
    // For primitive types we avoid using the default hasher, which may be
    // nondeterministic across program invocations
    if constexpr (std::is_integral<T>())
        x = v;
    else
        x = std::hash<T>{}(v);
    seed ^= x + 0x9e3779b9 + (seed << 6) + (seed >> 2);
}

inline u64 hash_string(const std::string& sv) { return hash_bytes(sv.data(), sv.size()); }

}  // namespace Stockfish

#endif  // #ifndef HASHING_H_INCLUDED
