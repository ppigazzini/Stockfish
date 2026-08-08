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

#ifndef BASETYPES_H_INCLUDED
#define BASETYPES_H_INCLUDED

#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <type_traits>
#include <utility>

namespace Stockfish {

using u64 = std::uint64_t;
using u32 = std::uint32_t;
using u16 = std::uint16_t;
using u8  = std::uint8_t;

using i64 = std::int64_t;
using i32 = std::int32_t;
using i16 = std::int16_t;
using i8  = std::int8_t;

using usize = std::size_t;
using isize = std::ptrdiff_t;

#if defined(__GNUC__) && defined(IS_64BIT)
__extension__ using u128 = unsigned __int128;
__extension__ using i128 = signed __int128;
#endif


template<typename T, usize MaxSize>
class ValueList {

   public:
    usize size() const { return size_; }
    int   ssize() const { return int(size_); }
    void  push_back(const T& value) {
        assert(size_ < MaxSize);
        values_[size_++] = value;
    }
    // pushes back value if value < max
    void push_back_if_lt(const T& value, const T& max) {
        assert(size_ < MaxSize);
        values_[size_] = value;
        size_ += (value < max);
    }
    const T* begin() const { return values_; }
    const T* end() const { return values_ + size_; }
    const T& operator[](int index) const { return values_[index]; }

    T* make_space(usize count) {
        T* result = &values_[size_];
        size_ += count;
        assert(size_ <= MaxSize);
        return result;
    }

   private:
    T     values_[MaxSize];
    usize size_ = 0;
};


template<typename T, usize Size, usize... Sizes>
class MultiArray;

namespace Detail {

template<typename T, usize Size, usize... Sizes>
struct MultiArrayHelper {
    using ChildType = MultiArray<T, Sizes...>;
};

template<typename T, usize Size>
struct MultiArrayHelper<T, Size> {
    using ChildType = T;
};

template<typename To, typename From>
constexpr bool is_strictly_assignable_v =
  std::is_assignable_v<To&, From> && (std::is_same_v<To, From> || !std::is_convertible_v<From, To>);

}

// MultiArray is a generic N-dimensional array.
// The template parameters (Size and Sizes) encode the dimensions of the array.
template<typename T, usize Size, usize... Sizes>
class MultiArray {
    using ChildType = typename Detail::MultiArrayHelper<T, Size, Sizes...>::ChildType;
    using ArrayType = std::array<ChildType, Size>;
    ArrayType data_;

   public:
    using value_type             = typename ArrayType::value_type;
    using size_type              = typename ArrayType::size_type;
    using difference_type        = typename ArrayType::difference_type;
    using reference              = typename ArrayType::reference;
    using const_reference        = typename ArrayType::const_reference;
    using pointer                = typename ArrayType::pointer;
    using const_pointer          = typename ArrayType::const_pointer;
    using iterator               = typename ArrayType::iterator;
    using const_iterator         = typename ArrayType::const_iterator;
    using reverse_iterator       = typename ArrayType::reverse_iterator;
    using const_reverse_iterator = typename ArrayType::const_reverse_iterator;

    constexpr auto&       at(size_type index) { return data_.at(index); }
    constexpr const auto& at(size_type index) const { return data_.at(index); }

    constexpr auto& operator[](size_type index) noexcept {
        assert(index < Size);
        return data_[index];
    }
    constexpr const auto& operator[](size_type index) const noexcept {
        assert(index < Size);
        return data_[index];
    }

    constexpr auto&       front() noexcept { return data_.front(); }
    constexpr const auto& front() const noexcept { return data_.front(); }
    constexpr auto&       back() noexcept { return data_.back(); }
    constexpr const auto& back() const noexcept { return data_.back(); }

    auto*       data() { return data_.data(); }
    const auto* data() const { return data_.data(); }

    constexpr auto begin() noexcept { return data_.begin(); }
    constexpr auto end() noexcept { return data_.end(); }
    constexpr auto begin() const noexcept { return data_.begin(); }
    constexpr auto end() const noexcept { return data_.end(); }
    constexpr auto cbegin() const noexcept { return data_.cbegin(); }
    constexpr auto cend() const noexcept { return data_.cend(); }

    constexpr auto rbegin() noexcept { return data_.rbegin(); }
    constexpr auto rend() noexcept { return data_.rend(); }
    constexpr auto rbegin() const noexcept { return data_.rbegin(); }
    constexpr auto rend() const noexcept { return data_.rend(); }
    constexpr auto crbegin() const noexcept { return data_.crbegin(); }
    constexpr auto crend() const noexcept { return data_.crend(); }

    constexpr bool      empty() const noexcept { return data_.empty(); }
    constexpr size_type size() const noexcept { return data_.size(); }
    constexpr size_type max_size() const noexcept { return data_.max_size(); }

    template<typename U>
    void fill(const U& v) {
        static_assert(Detail::is_strictly_assignable_v<T, U>,
                      "Cannot assign fill value to entry type");
        for (auto& ele : data_)
        {
            if constexpr (sizeof...(Sizes) == 0)
                ele = v;
            else
                ele.fill(v);
        }
    }

    constexpr void swap(MultiArray<T, Size, Sizes...>& other) noexcept { data_.swap(other.data_); }
};


// A key is a hashed summary of some SLICE of the position, and the engine keeps
// six of them. They are all u64, so before this type any one could stand in for
// any other -- and for a Bitboard, which is the same alias again.
//
// The space is a template parameter rather than a field: it costs no register
// and it makes two spaces different TYPES, which is the whole point.
//
// The algebra is deliberately tiny. A key is produced, stored, passed, masked
// to an index and truncated to a tag, and nothing else. In particular there is
// no operator^: keys are BUILT by xor-ing Zobrist words, and the same word is
// xor-ed into several spaces, so a public xor would let any space absorb any
// other's material -- exactly the mixing the type exists to prevent.
// Construction stays inside position.cpp, on the raw u64, and the type begins
// at the accessors.
enum class KeySpace : u8 {
    Pawn,
    MinorPiece,
    Material,
    NonPawn
};

template<KeySpace S>
class TypedKey {
   public:
    TypedKey() = default;
    constexpr explicit TypedKey(u64 v) :
        v(v) {}

    constexpr u64 raw() const { return v; }

    // Index into a power-of-two table. Returns the index, not a key: the result
    // has left the key domain and must not be mistaken for one.
    constexpr usize operator&(usize mask) const { return usize(v) & mask; }

    // The low bits a transposition entry stores as its tag.
    constexpr u16 tag() const { return u16(v); }

    constexpr bool operator==(const TypedKey& o) const { return v == o.v; }
    constexpr bool operator!=(const TypedKey& o) const { return v != o.v; }

   private:
    u64 v = 0;
};

using PawnKey     = TypedKey<KeySpace::Pawn>;
using MinorKey    = TypedKey<KeySpace::MinorPiece>;
using MaterialKey = TypedKey<KeySpace::Material>;
using NonPawnKey  = TypedKey<KeySpace::NonPawn>;

}  // namespace Stockfish

#endif  // #ifndef BASETYPES_H_INCLUDED
