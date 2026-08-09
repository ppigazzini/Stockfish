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

#ifndef SCORE_H_INCLUDED
#define SCORE_H_INCLUDED

#include <string>
#include <variant>
#include <utility>

#include "types.h"

namespace Stockfish {

class Position;

// The win-rate model fitted to fishtest LTC statistics, whose parameters depend
// on the material left on the board -- so every function below needs the
// position, not just the Value.
// See github.com/official-stockfish/WDL_model

// Return the win rate in per mille units.
int win_rate_model(Value v, const Position& pos);

// Turn a Value into an integer centipawn number, without treatment of mate and
// similar special scores.
int to_cp(Value v, const Position& pos);

// Format the win/draw/loss triple in per mille, as the UCI info line spells it.
std::string wdl_to_string(Value v, const Position& pos);

class Score {
   public:
    struct Mate {
        int plies;
    };

    struct Tablebase {
        int  plies;
        bool win;
    };

    struct InternalUnits {
        int value;
    };

    Score() = default;
    Score(Value v, const Position& pos);

    template<typename T>
    bool is() const {
        return std::holds_alternative<T>(score);
    }

    template<typename T>
    T get() const {
        return std::get<T>(score);
    }

    template<typename F>
    decltype(auto) visit(F&& f) const {
        return std::visit(std::forward<F>(f), score);
    }

   private:
    std::variant<Mate, Tablebase, InternalUnits> score;
};

}

#endif  // #ifndef SCORE_H_INCLUDED
