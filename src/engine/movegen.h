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

#ifndef MOVEGEN_H_INCLUDED
#define MOVEGEN_H_INCLUDED

#include <algorithm>  // IWYU pragma: keep

#include "types.h"
#include "basetypes.h"

namespace Stockfish {

class Position;

enum GenType {
    CAPTURES,
    QUIETS,
    EVASIONS,
    NON_EVASIONS,
    LEGAL
};

struct ExtMove: public Move {
    int value;

    void operator=(Move m) { data = m.raw(); }

    // Inhibit unwanted implicit conversions to Move
    // with an ambiguity that yields to a compile error.
    operator float() const = delete;
};

inline bool operator<(const ExtMove& f, const ExtMove& s) { return f.value < s.value; }

// The generators are written once against the destination element type. A Move
// is the first two bytes of an ExtMove and every store they make is a whole
// move, so the only thing the element type changes is the stride the write
// cursor advances by -- an immediate on the same add. Handing them the picker's
// own ExtMove slots is what lets the scorer skip a copy, and it costs the
// generator nothing.
template<GenType>
Move* generate(const Position& pos, Move* moveList);
template<GenType>
ExtMove* generate(const Position& pos, ExtMove* moveList);

// A slider's attack set is a function of its square and the occupancy alone,
// and neither changes between the capture list and the quiet list of one node:
// the two differ only in the target they intersect. CAPTURE_INIT therefore
// computes every set that QUIET_INIT is about to compute again.
//
// Measured over a warm 60-ply replay at depth 20, 33,473,573 nodes: 19,850,566
// generations visiting 65,420,816 sliders, 3.296 apiece, of which 5,205,030 are
// quiet lists that a capture list has already paid for.
//
// The cache is positional, not keyed: generate_all() walks bishops, then rooks,
// then queens, each by ascending square, and the piece sets are identical
// between the two calls, so the k-th set filled is the k-th set read. Sixteen
// entries is the bound -- sixteen men less the king.
enum SliderCacheMode {
    NoSliderCache,
    FillSliderCache,
    UseSliderCache
};

struct SliderCache {
    Bitboard att[16];
};

// Tags rather than a bool, so the mode is a template argument and the piece
// loop carries no test.
struct FillSliders {};
struct UseSliders {};

template<GenType, SliderCacheMode>
Move* generate_cached(const Position& pos, Move* moveList, SliderCache& sc);
template<GenType, SliderCacheMode>
ExtMove* generate_cached(const Position& pos, ExtMove* moveList, SliderCache& sc);

// The MoveList struct wraps the generate() function and returns a convenient
// list of moves. Using MoveList is sometimes preferable to directly calling
// the lower level generate() function.
template<GenType T>
struct MoveList {

    explicit MoveList(const Position& pos) :
        last(generate<T>(pos, moveList)) {}
    MoveList(const Position& pos, SliderCache& sc, FillSliders) :
        last(generate_cached<T, FillSliderCache>(pos, moveList, sc)) {}
    MoveList(const Position& pos, SliderCache& sc, UseSliders) :
        last(generate_cached<T, UseSliderCache>(pos, moveList, sc)) {}
    const Move* begin() const { return moveList; }
    const Move* end() const { return last; }
    usize       size() const { return last - moveList; }
    bool        contains(Move move) const { return std::find(begin(), end(), move) != end(); }

   private:
    Move moveList[MAX_MOVES], *last;
};

}  // namespace Stockfish

#endif  // #ifndef MOVEGEN_H_INCLUDED
