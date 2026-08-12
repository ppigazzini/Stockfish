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

#include "text.h"

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <fstream>
#include <ios>
#include <iterator>
#include <limits>

#include "../engine/basetypes.h"

namespace Stockfish {

std::optional<usize> str_to_size_t(const std::string& s) {
    if (s.empty() || s[0] == '-')
        return std::nullopt;
    errno                           = 0;
    char*                    endptr = nullptr;
    const unsigned long long value  = std::strtoull(s.c_str(), &endptr, 10);
    if (errno == ERANGE || (*endptr != '\0' && !std::isspace((unsigned char) *endptr))
        || value > std::numeric_limits<usize>::max())
        return std::nullopt;
    return static_cast<usize>(value);
}

std::optional<std::string> read_file_to_string(const std::string& path) {
    std::ifstream f(path, std::ios_base::binary);
    if (!f)
        return std::nullopt;
    return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

void remove_whitespace(std::string& s) {
    s.erase(std::remove_if(s.begin(), s.end(),
                           [](char c) { return std::isspace((unsigned char) c); }),
            s.end());
}

bool is_whitespace(std::string_view s) {
    return std::all_of(s.begin(), s.end(), [](char c) { return std::isspace((unsigned char) c); });
}

}  // namespace Stockfish
