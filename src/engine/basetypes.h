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

#include <algorithm>
#include <array>
#include <atomic>
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

// An element type that can be filled a run at a time rather than one at a
// time announces it by naming the scalar its storage is layout-compatible
// with. See RelaxedAtomic for why a run matters and what the caller owes.
template<typename T, typename = void>
constexpr bool has_bulk_fill_v = false;
template<typename T>
constexpr bool has_bulk_fill_v<T, std::void_t<typename T::bulk_fill_type>> = true;

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

        // A run at a time where the element type says its storage allows it.
        // The assignment below is a RELAXED ATOMIC STORE for the shared
        // histories, and the compiler may not merge those with their
        // neighbours: filling the 8 MiB continuation history entry by entry is
        // 4.2 M two-byte stores it is forbidden to widen.
        if constexpr (sizeof...(Sizes) == 0 && Detail::has_bulk_fill_v<T>)
        {
            using S = typename T::bulk_fill_type;
            static_assert(sizeof(T) == sizeof(S) && alignof(T) == alignof(S),
                          "The element must be layout-compatible with its bulk type");
            std::fill_n(reinterpret_cast<S*>(data_.data()), Size, S(v));
        }
        else
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


// A key is a hashed summary of one SLICE of the position, and StateInfo keeps
// one per slice. Every slice is a u64, so without a distinct type any one
// substitutes silently for any other -- and for a Bitboard, which is the same
// alias again.
//
// The space is a template parameter rather than a field: it costs no register
// and it makes two spaces different TYPES, which is the whole point.
//
// Keep the algebra tiny. A key is produced, stored, passed, compared with
// another key of its own space, masked to an index and truncated to a tag, and
// nothing else. In particular do not add an operator^: keys are BUILT by
// xor-ing Zobrist words, and the same word is xor-ed into several spaces, so a
// public xor would let any space absorb any other's material -- exactly the
// mixing the type exists to prevent. The raw u64s are maintained in
// position.cpp; the type begins at the accessors in position.h.
// NonPawnWhite and NonPawnBlack are TWO SPACES, not one space with an argument.
// They were one, and `non_pawn_key(WHITE)` where BLACK was meant compiled --
// which is the defect the whole enum exists to make impossible, surviving in the
// one place the discriminator was a parameter instead of a type. The colour half
// of the pairing was already discriminated on the field side: CorrectionBundle
// has separate nonPawnWhite and nonPawnBlack members and history.h selects
// between them with `if constexpr`. This is the key side of the same job.
//
// The two must stay ADJACENT and in colour order: types.h maps Color to space by
// adding the colour to NonPawnWhite, which is one add rather than a branch.
enum class KeySpace : u8 {
    Pawn,
    MinorPiece,
    Material,
    NonPawnWhite,
    NonPawnBlack
};

template<KeySpace S>
class TypedKey {
   public:
    TypedKey() = default;
    constexpr explicit TypedKey(u64 key) :
        v(key) {}

    constexpr u64 raw() const { return v; }

    // Index into a power-of-two table. Note the result type: masking leaves the
    // key domain, so what comes back is an index and must not be fed back in
    // where a key is wanted.
    constexpr usize operator&(usize mask) const { return usize(v) & mask; }

    // Take the low bits a transposition entry stores as its tag.
    constexpr u16 tag() const { return u16(v); }

    constexpr bool operator==(const TypedKey& o) const { return v == o.v; }
    constexpr bool operator!=(const TypedKey& o) const { return v != o.v; }

   private:
    u64 v = 0;
};

using PawnKey     = TypedKey<KeySpace::Pawn>;
using MinorKey    = TypedKey<KeySpace::MinorPiece>;
using MaterialKey = TypedKey<KeySpace::Material>;
// NonPawnKey is in types.h -- it is parameterised by Color, which this header
// does not see and must not: types.h includes this one, not the reverse.



// Whether wide() may name the widening load itself. x86-64 only, because the
// widening load is the whole point; clang only, because gcc already folds it;
// and never under ThreadSanitizer, which cannot see inline asm.
#if defined(__clang__) && defined(__x86_64__)
    #if defined(__SANITIZE_THREAD__)
        // no
    #elif __has_feature(thread_sanitizer)
        // no
    #else
        #define SF_WIDE_ATOMIC_LOAD_ASM 1
    #endif
#endif

#if defined(SF_WIDE_ATOMIC_LOAD_ASM)
constexpr bool HasWideAtomicLoad = true;
#else
constexpr bool HasWideAtomicLoad = false;
#endif

// A narrow integer promoted to the type its arithmetic happens in -- but only
// where widening it is free. Everywhere else the type is left alone, and that
// is deliberate rather than tidy: a toolchain that already folds the widening
// into its load gains nothing from the wider type and can lose a little to it.
// gcc at plain -O3 read +0.028% of bench instructions from carrying the wider
// one, so it goes on compiling the source it always did.
//
// Nothing deduces this type, which is what keeps a per-toolchain width from
// being a per-toolchain semantics. Every use of the conversion is an operand of
// int arithmetic, and every `auto` over a history table binds a REFERENCE to
// the entry rather than a copy of its value:
//
//   grep -rnE '\bauto\b' src/engine/{search.cpp,movepick.cpp,history.h}
//     | grep -iE 'hist|stats|entry|bundle|correction'
//
// A site that dropped the `&` would take i16 under gcc and int under clang, so
// add one only where the value is used as this one is.
template<typename T>
using Wide = std::conditional_t<HasWideAtomicLoad && std::is_integral_v<T>
                                  && (sizeof(T) < sizeof(int)),
                                int,
                                T>;

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

    // The value already widened to int, for a caller that is going to do
    // integer arithmetic with it -- which is every caller of a narrow one.
    //
    // clang lowers a 1- or 2-byte relaxed atomic load to `movzwl (mem)` and
    // then a SEPARATE reg-reg extension, because LLVM has no sextload or
    // zextload pattern for ATOMIC_LOAD: the DAG node's result is i16 and the
    // widening cannot fold into it. gcc emits the one `movswl (mem)` a plain
    // load gets. The defect is per LOAD, and the shared histories are read six
    // times per quiet move scored.
    //
    // On x86-64 a naturally aligned 1- or 2-byte load IS the relaxed atomic
    // load -- so naming the widening one asserts nothing the hardware does not
    // already give, and the operand is `inner` itself rather than a punned
    // pointer. Inline asm with a memory operand is opaque to LLVM's memory
    // analysis, so it is not forwarded across a store to the same entry nor
    // hoisted across a call; it is strictly MORE ordered than the relaxed load
    // it replaces, never less.
    //
    // The sanitizer lane keeps the real atomic: ThreadSanitizer instruments
    // the atomic API and cannot see inline asm, and a lane that stops finding
    // races is worth more than the instruction.
    Wide<T> wide() const {
#if defined(SF_WIDE_ATOMIC_LOAD_ASM)
        if constexpr (UseAtomic && std::is_integral_v<T> && sizeof(T) < sizeof(int))
        {
            // What the asm operand assumes, as build-time facts rather than as
            // a hope about the standard library's layout: the atomic holds the
            // scalar and nothing else, at its own alignment, and the hardware
            // does the access in one go. A libstdc++ that padded or over-
            // aligned it would fail the build, not miscompile the search.
            static_assert(sizeof(decltype(inner)) == sizeof(T));
            static_assert(alignof(decltype(inner)) == alignof(T));
            static_assert(std::atomic<T>::is_always_lock_free);

            // ONE instruction, which is what makes "=r" rather than "=&r"
            // correct: x86 reads every source operand of an instruction before
            // it writes the destination, so clang may -- and does -- allocate
            // the output over a register holding part of the address.
            int r;
            if constexpr (std::is_signed_v<T>)
            {
                if constexpr (sizeof(T) == 2)
                    __asm__("movswl %1, %0" : "=r"(r) : "m"(inner));
                else
                    __asm__("movsbl %1, %0" : "=r"(r) : "m"(inner));
            }
            else
            {
                if constexpr (sizeof(T) == 2)
                    __asm__("movzwl %1, %0" : "=r"(r) : "m"(inner));
                else
                    __asm__("movzbl %1, %0" : "=r"(r) : "m"(inner));
            }
            return r;
        }
        else
#endif
            return static_cast<T>(*this);
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

}  // namespace Stockfish

#endif  // #ifndef BASETYPES_H_INCLUDED
