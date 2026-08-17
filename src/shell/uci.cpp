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

#include "uci.h"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <iterator>
#include <limits>
#include <optional>
#include <sstream>
#include <string_view>
#include <filesystem>
#include <utility>
#include <variant>
#include <vector>

#include "benchmark.h"
#include "engine.h"
#include "../platform/memory.h"
#include "../engine/movegen.h"
#include "../engine/position.h"
#include "../engine/score.h"
#include "../engine/search.h"
#include "../engine/types.h"
#include "ucioption.h"
#include "../platform/misc.h"
#include "../platform/text.h"
#include "console.h"
#include "../engine/clock.h"
#include "../engine/basetypes.h"

namespace Stockfish {

using Time = std::chrono::steady_clock;
using ms   = std::chrono::milliseconds;

constexpr auto BenchmarkCommand = "speedtest";

template<typename... Ts>
struct overload: Ts... {
    using Ts::operator()...;
};

template<typename... Ts>
overload(Ts...) -> overload<Ts...>;

void UCIEngine::print_info_string(std::string_view str) {
    sync_cout_start();
    for (auto& line : split(str, "\n"))
    {
        if (!is_whitespace(line))
        {
            std::cout << "info string " << line << '\n';
        }
    }
    sync_cout_end();
}

UCIEngine::UCIEngine(CommandLine cli_) :
    engine(cli_.argc > 0 ? std::optional{path_from_utf8(cli_.argv[0])} : std::nullopt),
    cli(std::move(cli_)) {

    engine.get_options().add_info_listener([](const std::optional<std::string>& str) {
        if (str.has_value())
            print_info_string(*str);
    });

    init_search_update_listeners();
}

void UCIEngine::init_search_update_listeners() {
    engine.set_on_iter([](const auto& i) { on_iter(i); });
    engine.set_on_update_no_moves([](const auto& i) { on_update_no_moves(i); });
    engine.set_on_update_full(
      [this](const auto& i) { on_update_full(i, engine.get_options()["UCI_ShowWDL"]); });
    engine.set_on_start([]() {});
    engine.set_on_bestmove([](const auto& bm, const auto& p) { on_bestmove(bm, p); });
    engine.set_on_verify_network([](const auto& s) { print_info_string(s); });
}

void UCIEngine::loop() {
    set_console_utf8();
    std::string token, cmd;

    for (int i = 1; i < cli.argc; ++i)
        cmd += std::string(cli.argv[i]) + " ";

    do
    {
        if (cli.argc == 1
            && !getline(std::cin, cmd))  // Wait for an input or an end-of-file (EOF) indication
            cmd = "quit";

        currentCmd = cmd;
        std::istringstream is(cmd);

        token.clear();  // Avoid a stale if getline() returns nothing or a blank line
        is >> token;

        if (token == "quit" || token == "stop")
            engine.stop();

        // The GUI sends 'ponderhit' to tell that the user has played the expected move.
        // So, 'ponderhit' is sent if pondering was done on the same move that the user
        // has played. The search should continue, but should also switch from pondering
        // to the normal search.
        else if (token == "ponderhit")
            engine.set_ponderhit(false);

        else if (token == "uci")
        {
            sync_cout << "id name " << engine_info(true) << "\n"
                      << engine.get_options() << sync_endl;

            sync_cout << "uciok" << sync_endl;
        }

        else if (token == "setoption")
            setoption(is);
        else if (token == "go")
        {
            // send info strings after the go command is sent for old GUIs and python-chess
            print_info_string(engine.numa_config_information_as_string());
            print_info_string(engine.thread_allocation_information_as_string());
            go(is);
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
            engine.search_clear();
        else if (token == "isready")
            sync_cout << "readyok" << sync_endl;

        // Add custom non-UCI commands, mainly for debugging purposes.
        else if (token == "flip")
        {
            if (auto err = engine.flip())
            {
                terminate_on_critical_error(err->what());
            }
        }
        else if (token == "bench")
            bench(is);
        else if (token == BenchmarkCommand)
            benchmark(is);
        else if (token == "d")
            sync_cout << engine.visualize() << sync_endl;
        else if (token == "eval")
            engine.trace_eval();
        else if (token == "compiler")
            sync_cout << compiler_info() << sync_endl;
        else if (token == "export_net")
        {
            std::optional<std::filesystem::path> file;
            std::string                          filename;

            if (is >> filename)
                file = path_from_utf8(filename);

            apply_idle([&] { engine.save_network(file); });
        }
        else if (token == "--help" || token == "help" || token == "--license" || token == "license")
            sync_cout
              << "\nStockfish is a powerful chess engine for playing and analyzing."
                 "\nIt is released as free software licensed under the GNU GPLv3 License."
                 "\nStockfish is normally used with a graphical user interface (GUI) and implements"
                 "\nthe Universal Chess Interface (UCI) protocol to communicate with a GUI, an API, etc."
                 "\nFor any further information, visit https://github.com/official-stockfish/Stockfish#readme"
                 "\nor read the corresponding README.md and Copying.txt files distributed along with this program.\n"
              << sync_endl;
        else if (!token.empty() && token[0] != '#')
            sync_cout << "Unknown command: '" << cmd << "'. Type help for more information."
                      << sync_endl;

    } while (token != "quit" && cli.argc <= 1);  // The command-line arguments are one-shot
}

Search::LimitsType UCIEngine::parse_limits(std::istream& is,
                                           std::vector<std::string>& searchmoves) {
    Search::LimitsType limits;
    std::string        token;

    limits.startTime = now();  // The search starts as early as possible

    // A clock arrives as a signed TimePoint straight off the wire and used to
    // reach timeman.cpp's arithmetic unvalidated. `go wtime -50000000000
    // btime 1000` is a signed overflow inside timeman.cpp, and so is
    // `go wtime 4000000000000000000 winc 4000000000000000000 btime 1000`.
    // Neither is a defect in the arithmetic: it is asked to hold a number the
    // protocol never had a right to send. Bound it where it enters, which is
    // the only place that knows it came from outside.
    //
    // The bound is 1e12 ms -- about 31 years, past any real time control, and
    // far enough below the top that every product timeman forms stays inside a
    // TimePoint. A value outside it is reported, never silently corrected.
    constexpr TimePoint MaxClockMs = 1000000000000;

    // The counts are not clocks and they reach arithmetic of their own.
    // `movestogo` is carried into timeman as std::min(movestogo, 50) and then
    // used as `mtg - 1`, so a negative one is a signed overflow -- and the
    // engine played its move at depth 1 on a full clock. `mate` is compared as
    // `2 * limits.mate`, so 2147483647 wraps to -2, the stop condition never
    // fires, and `go mate 2147483647` searched on past a mate it had at depth 1.
    // Neither number means anything below zero. Both are bounded where they
    // enter rather than where they overflow, as the clocks above already are.
    auto read_count = [&](int& dst, const char* what, int hi) {
        i64 given;
        if (!(is >> given))
            return;  // leave the stream failed; the check below reports it

        const i64 bounded = std::clamp(given, i64(0), i64(hi));
        if (bounded != given)
            sync_cout << "info string " << what << ' ' << given << " is outside [0, " << hi
                      << "]; using " << bounded << sync_endl;
        dst = int(bounded);
    };

    auto read_clock = [&](TimePoint& dst, const char* what, TimePoint lo = 0) {
        TimePoint given;
        if (!(is >> given))
            return;  // leave the stream failed; the check below reports it

        const TimePoint bounded = std::clamp(given, lo, MaxClockMs);
        if (bounded != given)
            sync_cout << "info string " << what << ' ' << given << " is outside [" << lo << ", "
                      << MaxClockMs << "]; using " << bounded << sync_endl;
        dst = bounded;
    };

    while (is >> token)
    {
        if (token == "searchmoves")  // Needs to be the last command on the line
        {
            // Not lowered here: UCIEngine::to_move lowers what it is given, and
            // doing it twice was a leftover of the token living in LimitsType.
            while (is >> token)
                searchmoves.push_back(token);
            break;
        }

        else if (token == "wtime")
            read_clock(limits.time[WHITE], "wtime");
        else if (token == "btime")
            read_clock(limits.time[BLACK], "btime");
        else if (token == "winc")
            read_clock(limits.inc[WHITE], "winc");
        else if (token == "binc")
            read_clock(limits.inc[BLACK], "binc");
        else if (token == "movestogo")
            read_count(limits.movestogo, "movestogo", std::numeric_limits<int>::max());
        else if (token == "depth")
            is >> limits.depth;
        else if (token == "nodes")
            is >> limits.nodes;
        // A movetime of zero is an unstoppable search, not an instant one:
        // check_time's condition is `limits.movetime && elapsed >=
        // limits.movetime`, so zero disables the only stop condition the search
        // has, and `stop` is never read again while the UCI thread waits inside
        // benchmark. `bench 16 1 0 default movetime` emits it without a user
        // typing it, and so does any speedtest duration that truncates to zero.
        else if (token == "movetime")
            read_clock(limits.movetime, "movetime", 1);
        else if (token == "mate")
            read_count(limits.mate, "mate", std::numeric_limits<int>::max() / 2);
        else if (token == "perft")
            is >> limits.perft;
        else if (token == "infinite")
            limits.infinite = 1;
        else if (token == "ponder")
            limits.ponderMode = true;

        if (is.fail())
            terminate_on_critical_error("Invalid argument for '" + token + "'");
    }

    return limits;
}

void UCIEngine::go(std::istringstream& is) {

    std::vector<std::string> searchmoves;
    Search::LimitsType       limits = parse_limits(is, searchmoves);

    if (limits.perft)
        perft(limits);
    else
        engine.go(limits, searchmoves);
}

void UCIEngine::bench(std::istream& args) {
    std::string token;
    u64         num, nodes = 0, cnt = 1;
    u64         nodesSearched = 0;
    const auto& options       = engine.get_options();

    engine.set_on_update_full([&](const auto& i) {
        nodesSearched = i.nodes;
        on_update_full(i, options["UCI_ShowWDL"]);
    });

    std::vector<std::string> list = Benchmark::setup_bench(engine.fen(), args);

    num = count_if(list.begin(), list.end(),
                   [](const std::string& s) { return s.find("go ") == 0 || s.find("eval") == 0; });

    TimePoint elapsed = now();

    for (const auto& cmd : list)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go" || token == "eval")
        {
            std::cerr << "\nPosition: " << cnt++ << '/' << num << " (" << engine.fen() << ")"
                      << std::endl;
            if (token == "go")
            {
                std::vector<std::string> searchmoves;
                Search::LimitsType       limits = parse_limits(is, searchmoves);

                if (limits.perft)
                    nodesSearched = perft(limits);
                else
                {
                    engine.go(limits);
                    engine.wait_for_search_finished();
                }

                nodes += nodesSearched;
                nodesSearched = 0;
            }
            else
                engine.trace_eval();
        }
        else if (token == "setoption")
            setoption(is);
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();  // search_clear may take a while
            elapsed = now();
        }
    }

    elapsed = now() - elapsed + 1;  // Ensure positivity to avoid a 'divide by zero'

    dbg_print();

    std::cerr << "\n==========================="    //
              << "\nTotal time (ms) : " << elapsed  //
              << "\nNodes searched  : " << nodes    //
              << "\nNodes/second    : " << 1000 * nodes / elapsed << std::endl;

    // reset callback, to not capture a dangling reference to nodesSearched
    engine.set_on_update_full([&](const auto& i) { on_update_full(i, options["UCI_ShowWDL"]); });
}

void UCIEngine::benchmark(std::istream& args) {
    // Probably not very important for a test this long, but include for completeness and sanity.
    static constexpr int NUM_WARMUP_POSITIONS = 3;

    std::string token;
    u64         cnt = 1;

    engine.set_on_update_full([](const auto&) {});
    engine.set_on_iter([](const auto&) {});
    engine.set_on_update_no_moves([](const auto&) {});
    engine.set_on_bestmove([](const auto&, const auto&) {});
    engine.set_on_verify_network([](const auto&) {});

    Benchmark::BenchmarkSetup setup = Benchmark::setup_benchmark(args);

    const auto numGoCommands = count_if(setup.commands.begin(), setup.commands.end(),
                                        [](const std::string& s) { return s.find("go ") == 0; });


    // Set options once at the start.
    auto ss = std::istringstream("name Threads value " + std::to_string(setup.threads));
    setoption(ss);
    ss = std::istringstream("name Hash value " + std::to_string(setup.ttSize));
    setoption(ss);
    ss = std::istringstream("name UCI_Chess960 value false");
    setoption(ss);

    // Warmup
    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            // One new line is produced by the search, so omit it here
            std::cerr << "\rWarmup position " << cnt++ << '/' << NUM_WARMUP_POSITIONS;

            std::vector<std::string> searchmoves;
            Search::LimitsType       limits = parse_limits(is, searchmoves);

            // Run with silenced network verification
            engine.go(limits);
            engine.wait_for_search_finished();
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();  // search_clear may take a while
        }

        if (cnt > NUM_WARMUP_POSITIONS)
            break;
    }

    std::cerr << "\n";

    cnt = 1;

    int           numHashfullReadings = 0;
    constexpr int hashfullAges[]      = {0, 999};  // Only normal hashfull and touched hash.
    constexpr int hashfullAgeCount    = std::size(hashfullAges);
    int           totalHashfull[hashfullAgeCount] = {0};
    int           maxHashfull[hashfullAgeCount]   = {0};

    auto updateHashfullReadings = [&]() {
        numHashfullReadings += 1;

        for (int i = 0; i < hashfullAgeCount; ++i)
        {
            const int hashfull = engine.get_hashfull(hashfullAges[i]);
            maxHashfull[i]     = std::max(maxHashfull[i], hashfull);
            totalHashfull[i] += hashfull;
        }
    };

    engine.search_clear();  // search_clear may take a while

    Time::time_point elapsed;
    Time::duration   totalTime(0);

    u64 nodes = 0, nodesSearched = 0;

    engine.set_on_update_full([&](const Engine::InfoFull& i) { nodesSearched = i.nodes; });

    engine.set_on_start([&elapsed, &nodesSearched]() {
        elapsed       = Time::now();
        nodesSearched = 0;
    });

    engine.set_on_bestmove(
      [&totalTime, &elapsed, &nodes, &nodesSearched](const auto&, const auto&) {
          totalTime += Time::now() - elapsed;
          nodes += nodesSearched;
      });

    for (const auto& cmd : setup.commands)
    {
        std::istringstream is(cmd);
        is >> token;

        if (token == "go")
        {
            // One new line is produced by the search, so omit it here
            std::cerr << "\rPosition " << cnt++ << '/' << numGoCommands;

            std::vector<std::string> searchmoves;
            Search::LimitsType       limits = parse_limits(is, searchmoves);

            // Run with silenced network verification
            engine.go(limits);
            engine.wait_for_search_finished();

            updateHashfullReadings();
        }
        else if (token == "position")
            position(is);
        else if (token == "ucinewgame")
        {
            engine.search_clear();  // search_clear may take a while
        }
    }

    // Ensure positivity to avoid a 'divide by zero'
    const auto totalTimeMs = std::max<i64>(std::chrono::duration_cast<ms>(totalTime).count(), 1LL);

    dbg_print();

    std::cerr << "\n";

    static_assert(
      std::size(hashfullAges) == 2 && hashfullAges[0] == 0 && hashfullAges[1] == 999,
      "Hardcoded for display. Would complicate the code needlessly in the current state.");

    std::string threadBinding = engine.thread_binding_information_as_string();
    if (threadBinding.empty())
        threadBinding = "none";

    // clang-format off

    std::cerr << "==========================="
              << "\nVersion                    : "
              << engine_version_info()
              // "\nCompiled by                : "
              << compiler_info()
              << "Large pages                : " << (has_large_pages() ? "yes" : "no")
              << "\nUser invocation            : " << BenchmarkCommand << " "
              << setup.originalInvocation << "\nFilled invocation          : " << BenchmarkCommand
              << " " << setup.filledInvocation
              << "\nAvailable processors       : " << engine.get_numa_config_as_string()
              << "\nThread count               : " << setup.threads
              << "\nThread binding             : " << threadBinding
              << "\nTT size [MiB]              : " << setup.ttSize
              << "\nHash max, avg [per mille]  : "
              << "\n    single search          : " << maxHashfull[0] << ", "
              << totalHashfull[0] / numHashfullReadings
              << "\n    single game            : " << maxHashfull[1] << ", "
              << totalHashfull[1] / numHashfullReadings
              << "\nTotal nodes searched       : " << nodes
              << "\nTotal search time [s]      : " << totalTimeMs / 1000.0
              << "\nNodes/second               : " << 1000 * nodes / totalTimeMs << std::endl;

    // clang-format on

    init_search_update_listeners();
}

// ONE policy for every command that mutates state a live worker holds, and the
// policy is: stop the search first, then apply.
//
// Waiting without stopping is a deadlock, not a wait. The main worker spins on
// `while (!threads.stop && (ponder || limits.infinite))` and only the UCI reader
// thread can set `threads.stop` -- and that thread is the one blocked inside the
// wait. Neither `stop` nor `quit` is ever read again; the engine is gone.
//
// Not waiting at all is the same defect facing the other way. `export_net`
// reaches modify_and_replicate, which destroys and rebuilds every network
// replica while workers hold pointers into them, and the process aborts on an
// empty optional mid-search.
//
// The choice between "stop first" and "refuse while searching" is visible to a
// GUI and both are defensible. Stop first, because a GUI that pushes an option
// mid-ponder gets the option applied AND a bestmove, where refusing gives it
// neither and no way to tell. The cost is stated rather than hidden: an option
// arriving during a ponder now ends that ponder.
void UCIEngine::apply_idle(const std::function<void()>& mutate) {
    engine.stop();
    engine.wait_for_search_finished();
    mutate();
}

void UCIEngine::setoption(std::istringstream& is) {
    apply_idle([&] { engine.get_options().setoption(is); });
}

u64 UCIEngine::perft(const Search::LimitsType& limits) {
    auto result = engine.perft(engine.fen(), limits.perft, engine.get_options()["UCI_Chess960"]);
    if (auto err = std::get_if<PositionSetError>(&result))
        terminate_on_critical_error(err->what());

    auto nodes = std::get<u64>(result);
    sync_cout << "\nNodes searched: " << nodes << "\n" << sync_endl;
    return nodes;
}

void UCIEngine::position(std::istringstream& is) {
    const std::string fullCommand = is.str();

    std::string token, fen;

    is >> token;

    if (token == "startpos")
    {
        fen = StartFEN;
        is >> token;  // Consume the "moves" token, if any
    }
    else if (token == "fen")
        while (is >> token && token != "moves")
            fen += token + " ";
    else
        return;

    std::vector<std::string> moves;

    while (is >> token)
    {
        moves.push_back(token);
    }

    auto err = engine.set_position(fen, moves);
    if (err.has_value())
    {
        terminate_on_critical_error(err->what());
    }
}


std::string UCIEngine::format_score(const Score& s) {
    constexpr int TB_CP = 20000;
    const auto    format =
      overload{[](Score::Mate mate) -> std::string {
                   auto m = (mate.plies > 0 ? (mate.plies + 1) : mate.plies) / 2;
                   return std::string("mate ") + std::to_string(m);
               },
               [](Score::Tablebase tb) -> std::string {
                   return std::string("cp ") + std::to_string((tb.win ? TB_CP : -TB_CP) - tb.plies);
               },
               [](Score::InternalUnits units) -> std::string {
                   return std::string("cp ") + std::to_string(units.value);
               }};

    return s.visit(format);
}






std::string UCIEngine::to_lower(std::string str) {
    std::transform(str.begin(), str.end(), str.begin(),
                   [](unsigned char c) { return std::tolower(c); });

    return str;
}

Move UCIEngine::to_move(const Position& pos, std::string str) {
    str = to_lower(str);

    for (const auto& m : MoveList<LEGAL>(pos))
        if (str == move_to_uci(m, pos.is_chess960()))
            return m;

    return Move::none();
}

void UCIEngine::on_update_no_moves(const Engine::InfoShort& info) {
    sync_cout << "info depth " << info.depth << " score " << format_score(info.score) << sync_endl;
}

void UCIEngine::on_update_full(const Engine::InfoFull& info, bool showWDL) {
    std::stringstream ss;

    ss << "info";
    ss << " depth " << info.depth                 //
       << " seldepth " << info.selDepth           //
       << " multipv " << info.multiPV             //
       << " score " << format_score(info.score);  //

    if (!info.bound.empty())
        ss << " " << info.bound;

    if (showWDL)
        ss << " wdl " << info.wdl;

    ss << " nodes " << info.nodes        //
       << " nps " << info.nps            //
       << " hashfull " << info.hashfull  //
       << " tbhits " << info.tbHits      //
       << " time " << info.timeMs        //
       << " pv " << info.pv;             //

    sync_cout << ss.str() << sync_endl;
}

void UCIEngine::on_iter(const Engine::InfoIter& info) {
    std::stringstream ss;

    ss << "info";
    ss << " depth " << info.depth                     //
       << " currmove " << info.currmove               //
       << " currmovenumber " << info.currmovenumber;  //

    sync_cout << ss.str() << sync_endl;
}

void UCIEngine::on_bestmove(std::string_view bestmove, std::string_view ponder) {
    sync_cout << "bestmove " << bestmove;
    if (!ponder.empty())
        std::cout << " ponder " << ponder;
    std::cout << sync_endl;
}

void UCIEngine::terminate_on_critical_error(const std::string& message) {
    sync_cout << "info string CRITICAL ERROR: Command `" << currentCmd
              << "` failed. Reason: " << message << '\n'
              << sync_endl;

    // Stop the search before leaving, because std::exit does not leave quietly.
    // It never unwinds main, so the thread pool is never joined -- and it DOES
    // run static destructors, among them the tablebase reader's global TBTables,
    // whose ~TBTable munmaps every mapping and frees every PairsData while
    // workers are inside decompress_pairs reading exactly those. `position` and
    // `go` do not wait for the search, so an invalid FEN or an unparsable limit
    // arriving during `go infinite` reaches this line with every worker running.
    //
    // Every caller is on the UCI thread, which is the thread that can end a
    // search, so this wait cannot be waiting on itself. A GUI now gets the
    // bestmove of the search it asked for before the engine goes.
    engine.stop();
    engine.wait_for_search_finished();

    std::exit(1);
}

}  // namespace Stockfish
