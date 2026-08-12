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

#include <exception>  // IWYU pragma: keep
// IWYU pragma: no_include <__exception/terminate.h>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#if !defined(NO_PREFETCH) && (defined(_MSC_VER) || defined(__INTEL_COMPILER))
    #include <immintrin.h>
#endif

#include "../engine/basetypes.h"


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

#ifndef __has_builtin
    #define __has_builtin(x) 0
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
