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

#include "tt.h"

#include <cstdio>

#include "fatal.h"

#include "arena.h"
#include "parallel.h"

#include <algorithm>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <numeric>
#include <vector>

#include "bitboard.h"

namespace Stockfish {


// TTEntry struct is the 8 bytes transposition table entry, defined as:
//
// depth       8 bit
// pv node     1 bit
// bound type  2 bit
// generation  5 bit
// move       16 bit
// value      16 bit
// evaluation 16 bit
//
// The 21-bit keys are packed separately in Cluster::keys.
//
// We use `bool(depth8)` as the cheap internal occupancy check, corresponding
// to `depth == DEPTH_NONE` externally, so we offset the internal depth by DEPTH_NONE.
//
// Pv, bound and generation are packed in a single byte.

static constexpr u8 GENERATION_BITS = 5;
static constexpr u8 GENERATION_MASK = (1 << GENERATION_BITS) - 1;
static constexpr u8 BOUND_SHIFT     = GENERATION_BITS;
// The bound field is two bits wide because Bound is the powerset of two atoms
// and BOUND_EXACT is their join, so the lattice's TOP is the field's mask.
// Spelling it 0b11 wrote that same number a second time with nothing making
// the two agree; a reordered or extended Bound would move one and not the other.
static constexpr u8 BOUND_MASK = u8(BOUND_EXACT) << BOUND_SHIFT;
static constexpr u8 PV_SHIFT   = BOUND_SHIFT + 2;
static constexpr u8 PV_MASK    = 1 << PV_SHIFT;

// The byte is packed in one place and unpacked in three -- read(),
// TTWriter::write()'s secondary-aging test and relative_age() -- and nothing
// related the four. One
// operation each way, and the law relating them decided over the WHOLE domain
// rather than asserted at a site: 32 generations x 4 bounds x 2 pv flags is 256
// cases, which is small enough for the compiler to enumerate. A metamorphic
// relation between two implementations needs no oracle for either, and this one
// needs no lane either.
static constexpr u8 pack_gen_bound(u8 gen, Bound b, bool pv) {
    return u8(gen | u8(b) << BOUND_SHIFT | u8(pv) << PV_SHIFT);
}
static constexpr Bound bound_of(u8 gb) { return Bound((gb & BOUND_MASK) >> BOUND_SHIFT); }
static constexpr bool  pv_of(u8 gb) { return bool(gb & PV_MASK); }

static_assert((GENERATION_MASK | BOUND_MASK | PV_MASK) == 0xFF
                && (GENERATION_MASK & BOUND_MASK) == 0 && (GENERATION_MASK & PV_MASK) == 0
                && (BOUND_MASK & PV_MASK) == 0,
              "the three fields partition genBound8 exactly");

static_assert(
  [] {
      for (int g = 0; g <= GENERATION_MASK; ++g)
          for (int b = BOUND_NONE; b <= BOUND_EXACT; ++b)
              for (int pv = 0; pv <= 1; ++pv)
              {
                  const u8 gb = pack_gen_bound(u8(g), Bound(b), bool(pv));

                  // read() recovers the bound and the pv flag ...
                  if (bound_of(gb) != Bound(b) || pv_of(gb) != bool(pv))
                      return false;

                  // ... and relative_age() reads zero for the generation that
                  // wrote it, which is the only property it asks of the byte:
                  // the bound and pv bits must borrow away under the mask.
                  if (u8((u8(g) - gb) & GENERATION_MASK) != 0)
                      return false;
              }
      return true;
  }(),
  "the unpackers invert pack_gen_bound over every value it can produce");

// wide() is named on the two i16 fields and on NOTHING else here, and the line
// between them was measured, not guessed. clang keeps genBound8's
// `(curr_generation - genBound8) & GENERATION_MASK` and depth8's
// `std::max(depth8 - 1, 0)` entirely in byte operations -- the latter as
// `cmp $1; adc $-1` -- so widening those adds an instruction. The six depth8
// sites that DO carry a redundant extension are a separate, equal-sized saving
// that cannot be taken together with this one: each set alone retires fewer
// instructions per node under clang PGO and the two together retire more,
// because both inline into Worker::search<NonPV> through probe() and the pair
// crosses a register-allocation threshold neither reaches alone.
struct TTEntry {

    // Extract data from the TT entry. We have to convert TT internal bitfields
    // to external types. depth8 is a parameter rather than a member read because
    // the only caller has already asked the entry for it -- probe() needs the
    // same byte to decide occupancy -- and a relaxed atomic named twice is two
    // loads the compiler may not fold into one.
    TTData read(int d8) const {
        const u8 gb = genBound8;
        return TTData{Move(move16),
                      Value(value16.wide()),
                      Value(eval16.wide()),
                      Depth(DEPTH_NONE + d8),
                      bound_of(gb),
                      pv_of(gb)};
    }

    // Check if the TT entry is occupied
    bool is_occupied() const { return bool(depth8); }

    // Return TT entry age
    u8 relative_age(const u8 curr_generation) const;

   private:
    friend class TranspositionTable;
    friend struct TTWriter;

    RelaxedAtomic<u8>   depth8;
    RelaxedAtomic<u8>   genBound8;
    RelaxedAtomic<Move> move16;
    RelaxedAtomic<i16>  value16;
    RelaxedAtomic<i16>  eval16;
};

// A TranspositionTable is an array of Cluster, of size clusterCount. Each
// cluster consists of ClusterSize number of TTEntry. Each non-empty TTEntry
// contains information on exactly one position. The size of a Cluster should
// divide the size of a cache line for best performance, as the cacheline is
// prefetched when possible.

static constexpr int ClusterSize = 3;
static constexpr int KeyBits     = 21;
static constexpr u64 KeyMask     = (1ULL << KeyBits) - 1;

struct Cluster {
    // keys contains the low 21 bits of the Zobrist keys of the 3 TT entries in this cluster,
    // packed together into 63 bits of an u64
    RelaxedAtomic<u64> keys;
    TTEntry            entry[ClusterSize];
};

static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");

// Populates the TTEntry and its key with a new node's data, possibly overwriting
// an old position. The update is non-atomic and can be racy. We convert external
// types to internal bitfields.
void TTWriter::write(
  Key k, Value v, bool pv, Bound b, Depth d, Move m, Value ev, u8 curr_generation) {

    const int shift   = KeyBits * index;
    const u64 keys    = cluster->keys;
    const u64 keyDiff = ((keys >> shift) ^ k) & KeyMask;
    auto&     entry   = cluster->entry[index];

    // Preserve the old ttmove if we don't have a new one
    if (m || keyDiff)
        entry.move16 = m;

    // Overwrite less valuable entries (cheapest checks first)
    if (b == BOUND_EXACT || keyDiff || d - DEPTH_NONE + 2 * pv > entry.depth8 - 4
        || entry.relative_age(curr_generation))
    {
        assert(d > DEPTH_NONE);
        assert(d - DEPTH_NONE < 256);
        assert(curr_generation <= GENERATION_MASK);  // TranspositionTable::new_search() plays nice

        cluster->keys   = keys ^ (keyDiff << shift);
        entry.depth8    = u8(d - DEPTH_NONE);
        entry.genBound8 = pack_gen_bound(curr_generation, b, pv);
        entry.value16   = i16(v);
        entry.eval16    = i16(ev);
    }

    // Secondary aging. Important for elementary mate finding.
    // (*Scaler) Secondary aging on entries relevant to singular extensions
    // generally scales poorly and requires VVLTC verification.
    else if (entry.depth8 + DEPTH_NONE >= 5 && bound_of(entry.genBound8) != BOUND_EXACT)
    {
        // Named `int`, never `auto`, for two separate reasons. `auto` over the
        // member itself deduces RelaxedAtomic<i16>: the copy is an object
        // holding a std::atomic, so it lands on the stack and every use reloads
        // it from there. `auto` over wide() deduces Wide<i16>, which is int on
        // one toolchain and i16 on the others -- a local whose type is a property
        // of the compiler. The shared entry is read exactly once in every
        // spelling.
        const int v16 = entry.value16.wide();

        // Guard against racy underflows, default to "unoccupied"
        if (std::abs(v16) < VALUE_INFINITE && is_decisive(v16))
            entry.depth8 = std::max(int(entry.depth8) - 1, 0);
    }
}

// Returns this entry's age. We count generations like clocks count hours,
// i.e. we require 0 - 1 == 31. Unsigned subtraction guarantees the required
// borrowing regardless of the upper pv/bound bits.
u8 TTEntry::relative_age(const u8 curr_generation) const {
    return (curr_generation - genBound8) & GENERATION_MASK;
}


// TTWriter is but a very thin wrapper around the pointer
TTWriter::TTWriter(Cluster* cl, int idx) :
    cluster(cl),
    index(idx) {}

// Flag a TTEntry as useless (decrementing the stored depth by the given penalty)
void TTWriter::penalize(int penalty) {
    auto& entry = cluster->entry[index];
    // Guard against racy underflows, default to "unoccupied"
    entry.depth8 = std::max(int(entry.depth8) - penalty, 0);
}


// Sets the size of the transposition table, measured in megabytes.
// Transposition table consists of clusters and each cluster consists
// of ClusterSize number of TTEntry.
void TranspositionTable::resize(usize mbSize) {
    arena_free(table);

    clusterCount  = mbSize * 1024 * 1024 / sizeof(Cluster);
    usize ttBytes = clusterCount * sizeof(Cluster);

    // Request 1GB pages if we'd get at least eight per NUMA node, to avoid
    // memory oversubscription
    bool hugePageHint = ttBytes >= parallel_for().numa_nodes() * arena().hugePageBytes * 8;

    table = static_cast<Cluster*>(arena_alloc_hinted(ttBytes, hugePageHint));

    if (!table)
    {
        // Same shape as the arena's two sites and for the same reason: this is
        // an allocation failure, so the report is formatted without allocating.
        char buf[128];
        std::snprintf(buf, sizeof(buf), "Failed to allocate %lluMB for transposition table.",
                      static_cast<unsigned long long>(mbSize));
        engine_abort(buf);
    }

    clear();
}


// Initializes the entire transposition table to zero, in a multi-threaded way
void TranspositionTable::clear() {
    generation8             = 0;
    const usize threadCount = parallel_for().num_threads();

    std::vector<usize> threadToNuma = parallel_for().thread_numa_map();

    std::vector<usize> order(threadCount);
    std::iota(order.begin(), order.end(), 0);

    // To promote good NUMA distribution (esp. with huge pages), we permute
    // threads so that all threads in a NUMA node clear a contiguous region.
    if (threadToNuma.size() == threadCount)
        std::stable_sort(order.begin(), order.end(), [&threadToNuma](usize t1, usize t2) {
            return threadToNuma.at(t1) < threadToNuma.at(t2);
        });

    for (usize i = 0; i < threadCount; ++i)
    {
        parallel_for().run_on(order[i], [this, i, threadCount]() {
            // Each thread will zero its part of the hash table
            const usize stride = clusterCount / threadCount;
            const usize start  = stride * i;
            const usize len    = i + 1 != threadCount ? stride : clusterCount - start;

            std::memset(static_cast<void*>(&table[start]), 0, len * sizeof(Cluster));
        });
    }

    for (usize i = 0; i < threadCount; ++i)
        parallel_for().wait_on(i);
}


// Whether one entry counts towards the occupancy sample. The three results are
// summed by the caller, where bool promotes to int on its own.
static bool counts_as_full(const TTEntry& e, u8 gen, int maxAge) {
    return e.is_occupied() && e.relative_age(gen) <= maxAge;
}


// Returns an approximation of the hashtable occupation during a search.
// The hash is x permill full, as per UCI protocol. Only counts entries
// which are younger than maxAge.
int TranspositionTable::hashfull(int maxAge) const {
    // generation8 is a plain member and the entry bytes beside it are relaxed
    // atomics, so it was reloaded on every occupied entry: a compiler will not
    // hoist a plain load across an atomic one.
    const u8 gen = generation8;

    // The cluster is walked without a loop. Three iterations carrying a branch
    // is under gcc's unrolling threshold, and the loop control it emitted --
    // an advance, a bound and a jump per entry -- was half of what this
    // function retired.
    static_assert(ClusterSize == 3, "the cluster walk below is written out");

    int cnt = 0;
    for (const Cluster* c = table, *last = table + 1000; c != last; ++c)
        cnt += counts_as_full(c->entry[0], gen, maxAge) + counts_as_full(c->entry[1], gen, maxAge)
             + counts_as_full(c->entry[2], gen, maxAge);

    return cnt / ClusterSize;
}


// Must be called at the beginning of each root search to track entry aging
void TranspositionTable::new_search() {
    ++generation8;
    // Don't overflow into the other bits of TTEntry::genBound8
    generation8 &= GENERATION_MASK;
}


// The current age, used when writing new data to the TT
u8 TranspositionTable::generation() const { return generation8; }


// Looks up the current position in the transposition table. Calling probe(key)
// returns true if the key is found (which may be a collision) and has non-null
// data. Otherwise, it returns false and a pointer to an empty or least valuable
// TTEntry to be replaced later. The value of an entry is its depth minus 8 times
// its relative age.
std::tuple<bool, TTData, TTWriter> TranspositionTable::probe(const Key key) const {

    Cluster* const cluster = get_cluster(key);
    auto&          tte     = cluster->entry;
    const u64      key21   = key & KeyMask;  // Use the low 21 bits as key inside the cluster

    constexpr u64 KeyLsb  = 1ULL | (1ULL << KeyBits) | (1ULL << 2 * KeyBits);
    constexpr u64 KeyMsb  = KeyLsb << (KeyBits - 1);
    const u64     keys    = cluster->keys;
    const u64     keyXors = keys ^ (KeyLsb * key21);
    // This bit twiddling trick will produce a one in the last (=most significant) bit of
    // the first 21bit block matching key21. The bits before that first matching block will
    // be all zeros, but after the first matching block there could be garbage.
    const u64 matches = (keyXors - KeyLsb) & ~keyXors & KeyMsb;

    if (matches)
    {
        static_assert(KeyBits == 21, "Index computation below assumes KeyBits == 21");
        const int i = (int(lsb(matches)) >> 4) - 1;
        // This gap is the main place for read races.
        // After `read()` completes that copy is final, but may be self-inconsistent.
        // depth8 answers both halves of the return -- occupancy and the copy's
        // depth -- and it is a relaxed atomic, so it is read once for the two.
        const int d8 = tte[i].depth8;
        return {bool(d8), tte[i].read(d8), TTWriter(cluster, i)};
    }

    // Find an entry to be replaced according to the replacement strategy.
    // The leader's value is carried instead of recomputed: depth8 and genBound8
    // are relaxed atomics, so the compiler may not reuse the loads, and the
    // incumbent would be re-read and re-aged once per remaining entry.
    int replace      = 0;
    int replaceValue = tte[0].depth8 - 8 * tte[0].relative_age(generation8);
    for (int i = 1; i < ClusterSize; ++i)
    {
        const int value = tte[i].depth8 - 8 * tte[i].relative_age(generation8);
        if (replaceValue > value)
        {
            replace      = i;
            replaceValue = value;
        }
    }

    // Everything a miss returns except the writer is the same six constants
    // every time, so they are named once and copied in whole rather than
    // materialised field by field on each of them.
    static constexpr TTData NoData{Move::none(), VALUE_NONE, VALUE_NONE,
                                   DEPTH_NONE,   BOUND_NONE, false};

    return {false, NoData, TTWriter(cluster, replace)};
}


// The hash function; its only external use is memory prefetching
Cluster* TranspositionTable::get_cluster(const Key key) const {
    return &table[mul_hi64(key, clusterCount)];
}

}  // namespace Stockfish
