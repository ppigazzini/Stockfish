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

#ifndef TEXT_H_INCLUDED
#define TEXT_H_INCLUDED

#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "../engine/basetypes.h"

// Turning the host's text into values: the UCI command line arriving on stdin
// and the sysfs files the NUMA prober reads are both text this engine did not
// write and must not trust. Nothing here decides anything about chess, and
// nothing above the platform zone needs it -- it is separate from misc.h so
// that a header wanting to parse a line does not also pull in the process
// identity, the logger and argv, which is what carried the whole drawer into
// engine/'s transitive include graph by way of numa.h.

namespace Stockfish {

// Parse a decimal count. Returns nullopt for the empty string, for anything
// negative, on overflow, and on any trailing character that is not whitespace,
// so a caller cannot mistake a partial parse for a whole one.
std::optional<usize> str_to_size_t(const std::string& s);

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

}  // namespace Stockfish

#endif  // #ifndef TEXT_H_INCLUDED
