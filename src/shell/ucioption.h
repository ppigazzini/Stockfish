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

#ifndef UCIOPTION_H_INCLUDED
#define UCIOPTION_H_INCLUDED

#include <functional>
#include <iosfwd>
#include <map>
#include <optional>
#include <string>

#include "../engine/basetypes.h"

namespace Stockfish {
// Define a custom comparator, because the UCI options should be case-insensitive
//
// ASCII by hand, and not std::tolower. UCI option names are ASCII by
// specification, while tolower() is a locale-dependent libc call that no amount
// of optimisation can inline: it was 10,010 retired instructions per `go` on
// this tree, because Engine::search_options looks up thirteen names on the move
// latency path and every character of every comparison went through it.
//
// It is also the safer of the two. Nothing here ever calls setlocale, so the
// program runs in the "C" locale and tolower() already folds exactly A-Z -- but
// that is an accident of what has not been called yet. In a Turkish locale
// tolower('I') is not 'i', and "UCI_Elo" would stop matching itself.
//
// Defined here rather than in the .cpp so std::map's search inlines it.
struct CaseInsensitiveLess {

    static constexpr unsigned char fold(char c) {
        const unsigned char u = static_cast<unsigned char>(c);
        return u >= 'A' && u <= 'Z' ? static_cast<unsigned char>(u + 'a' - 'A') : u;
    }

    // std::lexicographical_compare's own ordering: the first differing
    // character decides, and a prefix is less than what it is a prefix of.
    bool operator()(const std::string& s1, const std::string& s2) const {
        const usize n = s1.size() < s2.size() ? s1.size() : s2.size();
        for (usize i = 0; i < n; ++i)
            if (fold(s1[i]) != fold(s2[i]))
                return fold(s1[i]) < fold(s2[i]);
        return s1.size() < s2.size();
    }
};

class OptionsMap;

// The Option class implements each option as specified by the UCI protocol
class Option {
   public:
    using OnChange = std::function<std::optional<std::string>(const Option&)>;

    Option(OnChange = nullptr);
    Option(bool v, OnChange = nullptr);
    Option(const char* v, OnChange = nullptr);
    Option(int v, int minv, int maxv, OnChange = nullptr);
    Option(const char* v, const char* cur, OnChange = nullptr);

    Option& operator=(const std::string&);
    operator int() const;
    operator std::string() const;
    bool operator==(const char*) const;
    bool operator!=(const char*) const;

    friend std::ostream& operator<<(std::ostream&, const OptionsMap&);

    int operator<<(const Option&) = delete;

   private:
    friend class OptionsMap;
    friend class Engine;
    friend class Tune;


    std::string       defaultValue, currentValue, type;
    int               min = 0, max = 0;
    usize             idx = 0;
    OnChange          on_change;
    const OptionsMap* parent = nullptr;
};

class OptionsMap {
   public:
    using InfoListener = std::function<void(std::optional<std::string>)>;

    OptionsMap()                             = default;
    OptionsMap(const OptionsMap&)            = delete;
    OptionsMap(OptionsMap&&)                 = delete;
    OptionsMap& operator=(const OptionsMap&) = delete;
    OptionsMap& operator=(OptionsMap&&)      = delete;

    void add_info_listener(InfoListener&&);

    void setoption(std::istringstream&);

    const Option& operator[](const std::string&) const;

    void add(const std::string&, const Option& option);

    usize count(const std::string&) const;

   private:
    friend class Engine;
    friend class Option;

    friend std::ostream& operator<<(std::ostream&, const OptionsMap&);

    // The options container is defined as a std::map
    using OptionsStore = std::map<std::string, Option, CaseInsensitiveLess>;

    OptionsStore options_map;

    // Per MAP, not per process. It was a function-local `static` inside add(),
    // shared by every OptionsMap ever constructed, while operator<< scans the
    // indices 0..size()-1 -- so a second OptionsMap started numbering where the
    // first stopped and every one of its options fell outside the printed
    // range, silently dropping the whole `uci` handshake. Nothing constructs a
    // second one today, which is why this is a bound and not a repair.
    usize insertOrder = 0;
    InfoListener info;
};

}
#endif  // #ifndef UCIOPTION_H_INCLUDED
