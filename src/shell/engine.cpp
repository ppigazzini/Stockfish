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

#include "engine.h"

#include "../engine/arena.h"
#include "../engine/output_sink.h"
#include "../engine/parallel.h"
#include "../engine/worker_set.h"

#include <algorithm>
#include <cassert>
#include <filesystem>
#include <deque>
#include <iosfwd>
#include <memory>
#include <ostream>
#include <iomanip>
#include <sstream>
#include <string_view>
#include <utility>
#include <vector>

#include "../engine/evaluate.h"
#include "../platform/misc.h"
#include "../engine/nnue/network.h"
#include "../engine/nnue/nnue_common.h"
#include "../platform/numa.h"
#include "perft.h"
#include "../engine/position.h"
#include "../engine/search.h"
#include "../platform/shm.h"
#include "../platform/syzygy/tbprobe.h"
#include "../engine/types.h"
#include "uci.h"
#include "ucioption.h"
#include "console.h"

namespace Stockfish {

namespace NN = Eval::NNUE;

int MaxThreads = std::max(1024, 4 * int(get_hardware_concurrency()));

// The default configuration will attempt to group L3 domains up to 32 threads.
// This size was found to be a good balance between the Elo gain of increased
// history sharing and the speed loss from more cross-cache accesses (see
// PR#6526). The user can always explicitly override this behavior.
constexpr NumaAutoPolicy DefaultNumaPolicy = BundledL3Policy{32};

namespace {
// Bind the Syzygy prober to the engine's tb_source seam. Registering it adds a
// capability rather than fixing a defect: unlike the worker set, this seam is
// correct unregistered, because "no tablebases are loaded" is exactly true then.
Tablebases::WDLScore tb_probe_wdl(void*, Position& pos, Tablebases::ProbeState* r) {
    return Tablebases::probe_wdl(pos, r);
}
int tb_max_cardinality(void*) { return Tablebases::MaxCardinality; }
Tablebases::Config tb_rank_root(void*, const SearchOptions& o, Position& pos,
                                Search::RootMoves& rm, bool rankDTZ,
                                const std::function<bool()>& abort) {
    return Tablebases::rank_root_moves(o, pos, rm, rankDTZ, abort);
}
}  // namespace

namespace {
void host_line(std::string_view text) { sync_cout << text << sync_endl; }

// Hold the pool the engine's parallel-for runs on in a file-scope pointer: a
// plain function pointer cannot capture, which is also why the seam takes a
// registration call rather than a closure.
//
// Write it only on the main thread, inside resize_threads, before anything
// reads it.
ThreadPool* hostPool = nullptr;

// Pass the pool itself as the worker set's ctx, so it needs no second global --
// that is what the seam's void* ctx is for.
void  ws_start_searching(void* c) { static_cast<ThreadPool*>(c)->start_searching(); }
void  ws_wait_finished(void* c) { static_cast<ThreadPool*>(c)->wait_for_search_finished(); }
u64   ws_nodes_searched(void* c) { return static_cast<ThreadPool*>(c)->nodes_searched(); }
u64   ws_tb_hits(void* c) { return static_cast<ThreadPool*>(c)->tb_hits(); }
usize ws_count(void* c) { return static_cast<ThreadPool*>(c)->worker_count(); }
Search::Worker* ws_at(void* c, usize i) { return static_cast<ThreadPool*>(c)->worker_at(i); }

usize              pool_num_threads() { return hostPool->num_threads(); }
usize              pool_numa_nodes() { return hostPool->numa_nodes(); }
std::vector<usize> pool_thread_numa_map() { return hostPool->get_bound_thread_to_numa_node(); }
void pool_run_on(usize t, std::function<void()> fn) { hostPool->run_on_thread(t, std::move(fn)); }
void pool_wait_on(usize t) { hostPool->wait_on_thread(t); }
}  // namespace

// Install the host's seams: process output, the Syzygy prober, and the arena
// that hands out large pages where the OS will give them.
//
// RUN THIS BEFORE ANY OTHER ENGINE MEMBER IS BUILT. ArenaInstallerTag is
// declared first in engine.h, so this constructor runs before the transposition
// table or any history bank exists. A block taken from the engine's default
// allocator and released by the one installed here is heap corruption with no
// diagnostic.
Engine::ArenaInstallerTag::ArenaInstallerTag() {
    set_output_sink({host_line, dbg_print});
    Tablebases::set_tb_source({nullptr, tb_max_cardinality, tb_probe_wdl, tb_rank_root});
    set_arena({aligned_large_pages_alloc, aligned_large_pages_alloc_with_hint,
               aligned_large_pages_free});
}

Engine::Engine(std::optional<std::filesystem::path> path) :
    // Leave this first here for readability only: members initialise in
    // declaration order, and engine.h is where that order is fixed.
    arenaInstaller(),
    binaryDirectory(path ? CommandLine::get_binary_directory(*path) : std::filesystem::path{}),
    numaContext(NumaConfig::from_system(DefaultNumaPolicy)),
    states(new std::deque<StateInfo>(1)),
    threads(),
    networkFile{std::nullopt, ""},
    network(numaContext, get_default_network()) {

    pos.set(StartFEN, false, &states->back());

    options.add(  //
      "Debug Log File", Option("", [](const Option& o) {
          start_logger(path_from_utf8(std::string(o)));
          return std::nullopt;
      }));

    options.add(  //
      "NumaPolicy", Option("auto", [this](const Option& o) {
          if (!set_numa_config_from_option(o))
              return "NumaPolicy: invalid value '" + std::string(o) + "', keeping previous config.";
          return numa_config_information_as_string() + "\n"
               + thread_allocation_information_as_string();
      }));

    options.add(  //
      "Threads", Option(1, 1, MaxThreads, [this](const Option&) {
          resize_threads();
          return thread_allocation_information_as_string();
      }));

    options.add(  //
      "Hash", Option(16, 1, MaxHashMB, [this](const Option& o) {
          set_tt_size(o);
          return std::nullopt;
      }));

    options.add(  //
      "Clear Hash", Option([this](const Option&) {
          search_clear();
          return std::nullopt;
      }));

    options.add(  //
      "Ponder", Option(false));

    options.add(  //
      "MultiPV", Option(1, 1, MAX_MOVES));

    options.add("Skill Level", Option(20, 0, 20));

    options.add("Move Overhead", Option(10, 0, 5000));

    options.add("nodestime", Option(0, 0, 10000));

    options.add("UCI_Chess960", Option(false));

    options.add("UCI_LimitStrength", Option(false));

    options.add("UCI_Elo",
                Option(Stockfish::Search::Skill::LowestElo, Stockfish::Search::Skill::LowestElo,
                       Stockfish::Search::Skill::HighestElo));

    options.add("UCI_ShowWDL", Option(false));

    options.add(  //
      "SyzygyPath", Option("", [](const Option& o) {
          Tablebases::init(o);
          return std::nullopt;
      }));

    options.add("SyzygyProbeDepth", Option(1, 1, 100));

    options.add("Syzygy50MoveRule", Option(true));

    options.add("SyzygyProbeLimit", Option(7, 0, 7));

    options.add(  //
      "EvalFile", Option(EvalFileDefaultName, [this](const Option& o) {
          load_network(path_from_utf8(std::string(o)));
          return std::nullopt;
      }));

    threads.clear();
    threads.ensure_network_replicated(network);
    resize_threads();
}

std::variant<u64, PositionSetError>
Engine::perft(const std::string& fen, Depth depth, bool isChess960) {
    verify_network();

    return Benchmark::perft(fen, depth, isChess960);
}

void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);

    // Wait before touching searchOptions. Every Worker holds it as a
    // const SearchOptions& and reads multiPV, skillLevel and nodestime while it
    // searches, so assigning it under a live search is a data race on a type
    // holding a std::string. The UCI specification says `go` arrives only when
    // the engine is idle; uci.cpp accepts one whenever it is sent.
    wait_for_search_finished();

    verify_network();

    searchOptions = search_options();
    threads.start_thinking(searchOptions, pos, states, limits);
}
void Engine::stop() { threads.stop = true; }

void Engine::search_clear() {
    wait_for_search_finished();

    tt.clear();
    threads.clear();

    // TODO: does not work with multiple instances
    Tablebases::init(options["SyzygyPath"]);  // Free mapped files
}

void Engine::set_on_update_no_moves(std::function<void(const Engine::InfoShort&)>&& f) {
    updateContext.onUpdateNoMoves = std::move(f);
}

void Engine::set_on_update_full(std::function<void(const Engine::InfoFull&)>&& f) {
    updateContext.onUpdateFull = std::move(f);
}

void Engine::set_on_iter(std::function<void(const Engine::InfoIter&)>&& f) {
    updateContext.onIter = std::move(f);
}

void Engine::set_on_bestmove(std::function<void(std::string_view, std::string_view)>&& f) {
    updateContext.onBestmove = std::move(f);
}

void Engine::set_on_start(std::function<void()>&& f) { updateContext.onStart = std::move(f); }

void Engine::set_on_verify_network(std::function<void(std::string_view)>&& f) {
    onVerifyNetwork = std::move(f);
}

void Engine::wait_for_search_finished() { threads.main_thread()->wait_for_search_finished(); }

std::optional<PositionSetError> Engine::set_position(const std::string&              fen,
                                                     const std::vector<std::string>& moves) {
    // Drop the old state and create a new one
    states   = StateListPtr(new std::deque<StateInfo>(1));
    auto err = pos.set(fen, options["UCI_Chess960"], &states->back());
    if (err.has_value())
        return err;

    for (const auto& move : moves)
    {
        auto m = UCIEngine::to_move(pos, move);

        if (m == Move::none())
            return PositionSetError("Illegal move: " + move);

        states->emplace_back();
        pos.do_move(m, states->back());
    }

    return std::nullopt;
}

// modifiers

bool Engine::set_numa_config_from_option(const std::string& o) {
    if (o == "auto" || o == "system")
    {
        numaContext.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy));
    }
    else if (o == "hardware")
    {
        // Don't respect affinity set in the system.
        numaContext.set_numa_config(NumaConfig::from_system(DefaultNumaPolicy, false));
    }
    else if (o == "none")
    {
        numaContext.set_numa_config(NumaConfig{});
    }
    else
    {
        auto parsed = NumaConfig::from_string(o);
        if (!parsed.has_value())
            return false;
        numaContext.set_numa_config(std::move(*parsed));
    }

    // Force reallocation of threads in case affinities need to change.
    resize_threads();
    threads.ensure_network_replicated(network);
    return true;
}

// Convert the live option map into the engine's option snapshot here, in the
// composition root. This is the seam: everything below Engine reads a plain
// SearchOptions value, so no file under engine/ includes ucioption.h, and a
// search driven from somewhere with no OptionsMap fills the struct directly.
//
// Take it fresh on every use, so a setoption between searches is seen.
SearchOptions Engine::search_options() const {
    SearchOptions o;
    o.threads          = usize(int(options["Threads"]));
    o.numaPolicy       = std::string(options["NumaPolicy"]);
    o.multiPV          = usize(int(options["MultiPV"]));
    o.skillLevel       = int(options["Skill Level"]);
    o.limitStrength    = bool(options["UCI_LimitStrength"]);
    o.elo              = int(options["UCI_Elo"]);
    o.moveOverhead     = int(options["Move Overhead"]);
    o.syzygy50MoveRule = bool(options["Syzygy50MoveRule"]);
    o.syzygyProbeDepth = int(options["SyzygyProbeDepth"]);
    o.syzygyProbeLimit = int(options["SyzygyProbeLimit"]);
    o.showWDL          = bool(options["UCI_ShowWDL"]);
    o.nodestime        = int(options["nodestime"]);
    o.ponder           = bool(options["Ponder"]);
    return o;
}

void Engine::resize_threads() {
    threads.wait_for_search_finished();
    searchOptions = search_options();
    threads.set(numaContext.get_numa_config(),
                {searchOptions, tt, sharedHists, threads.stop, threads.increaseDepth},
                updateContext);

    // ORDER: the pool must exist before it is installed, and be installed before
    // set_tt_size, which clears the table THROUGH the parallel-for. Installing
    // after would clear a resized table single-threaded on the first call and
    // multi-threaded on every later one -- correct either way, and a silent
    // performance cliff on exactly the path that allocates gigabytes.
    hostPool = &threads;
    set_parallel_for({pool_num_threads, pool_numa_nodes, pool_thread_numa_map, pool_run_on,
                      pool_wait_on});
    set_worker_set({&threads, ws_start_searching, ws_wait_finished, ws_nodes_searched, ws_tb_hits,
                    ws_count, ws_at});

    // Reallocate the hash with the new threadpool size
    set_tt_size(options["Hash"]);
    threads.ensure_network_replicated(network);
}

void Engine::set_tt_size(usize mb) {
    wait_for_search_finished();
    tt.resize(mb);
}

void Engine::set_ponderhit(bool b) { threads.main_manager()->ponder = b; }

// network related

void Engine::verify_network() const {
    const auto file = path_from_utf8(std::string(options["EvalFile"]));
    network->verify(onVerifyNetwork, networkFile, file);

    auto statuses = network.get_status_and_errors();
    for (usize i = 0; i < statuses.size(); ++i)
    {
        const auto [status, error] = statuses[i];
        std::string message        = "Network replica " + std::to_string(i + 1) + ": ";
        if (status == SystemWideSharedConstantAllocationStatus::NoAllocation)
        {
            message += "No allocation.";
        }
        else if (status == SystemWideSharedConstantAllocationStatus::LocalMemory)
        {
            message += "Local memory.";
        }
        else if (status == SystemWideSharedConstantAllocationStatus::SharedMemory)
        {
            message += "Shared memory.";
        }
        else
        {
            message += "Unknown status.";
        }

        if (error.has_value())
        {
            message += " " + *error;
        }

        onVerifyNetwork(message);
    }
}

std::unique_ptr<Eval::NNUE::Network> Engine::get_default_network() {

    auto network_ = std::make_unique<NN::Network>();

    network_->load(binaryDirectory, std::filesystem::path{}, networkFile);

    return network_;
}

void Engine::load_network(const std::filesystem::path& file) {
    network.modify_and_replicate(
      [this, &file](NN::Network& network_) { network_.load(binaryDirectory, file, networkFile); });
    // ORDER: re-hand the replicas BEFORE clearing. modify_and_replicate destroys
    // and rebuilds every replica, so each worker's network pointer dangles the
    // moment it returns, and ThreadPool::clear runs Worker::clear, which reads
    // that pointer to reseed the refresh cache. Clear first and that read is a
    // use-after-free, on the ordinary `setoption name EvalFile` path.
    threads.ensure_network_replicated(network);
    threads.clear();
}

void Engine::save_network(const std::optional<std::filesystem::path>& file) {
    network.modify_and_replicate(
      [&file, this](NN::Network& network_) { network_.save(networkFile, file); });
    // Re-hand the replicas here too: saving goes through modify_and_replicate,
    // so the workers' pointers dangle exactly as they do after a load. Nothing
    // on this path evaluates, so dropping this line raises nothing here -- the
    // next search reads the freed replica instead.
    threads.ensure_network_replicated(network);
}

// utility functions

void Engine::trace_eval() const {
    StateListPtr trace_states(new std::deque<StateInfo>(1));
    Position     p;
    p.set(pos.fen(), options["UCI_Chess960"], &trace_states->back());

    verify_network();

    sync_cout << "\n" << Eval::trace(p, *network) << sync_endl;
}

const OptionsMap& Engine::get_options() const { return options; }
OptionsMap&       Engine::get_options() { return options; }

std::string Engine::fen() const { return pos.fen(); }

std::optional<PositionSetError> Engine::flip() { return pos.flip(); }

std::string Engine::visualize() const {
    std::stringstream ss;
    ss << pos;

    // Append the tablebase rows of the `d` board here, not in Position's
    // operator<<. A probe is disk I/O -- a platform service -- and moving these
    // lines back into the stream operator makes every engine object that prints
    // a Position reference Tablebases, for the sake of a debug view.
    if (Tablebases::MaxCardinality >= popcount(pos.pieces()) && !pos.can_castle(ANY_CASTLING))
    {
        StateInfo st;
        Position  p;
        p.set(pos.fen(), pos.is_chess960(), &st);

        Tablebases::ProbeState s1, s2;
        Tablebases::WDLScore   wdl = Tablebases::probe_wdl(p, &s1);
        int                    dtz = Tablebases::probe_dtz(p, &s2);

        ss << "\nTablebases WDL: " << std::setw(4) << wdl << " (" << s1 << ")"
           << "\nTablebases DTZ: " << std::setw(4) << dtz << " (" << s2 << ")";
    }

    return ss.str();
}

int Engine::get_hashfull(int maxAge) const { return tt.hashfull(maxAge); }

std::vector<std::pair<usize, usize>> Engine::get_bound_thread_count_by_numa_node() const {
    auto                                 counts = threads.get_bound_thread_count_by_numa_node();
    const NumaConfig&                    cfg    = numaContext.get_numa_config();
    std::vector<std::pair<usize, usize>> ratios;
    NumaIndex                            n = 0;
    for (; n < counts.size(); ++n)
        ratios.emplace_back(counts[n], cfg.num_cpus_in_numa_node(n));
    if (!counts.empty())
        for (; n < cfg.num_numa_nodes(); ++n)
            ratios.emplace_back(0, cfg.num_cpus_in_numa_node(n));
    return ratios;
}

std::string Engine::get_numa_config_as_string() const {
    return numaContext.get_numa_config().to_string();
}

std::string Engine::numa_config_information_as_string() const {
    auto cfgStr = get_numa_config_as_string();
    return "Available processors: " + cfgStr;
}

std::string Engine::thread_binding_information_as_string() const {
    auto              boundThreadsByNode = get_bound_thread_count_by_numa_node();
    std::stringstream ss;
    if (boundThreadsByNode.empty())
        return ss.str();

    bool isFirst = true;

    for (auto&& [current, total] : boundThreadsByNode)
    {
        if (!isFirst)
            ss << ":";
        ss << current << "/" << total;
        isFirst = false;
    }

    return ss.str();
}

std::string Engine::thread_allocation_information_as_string() const {
    std::stringstream ss;

    usize threadsSize = threads.size();
    ss << "Using " << threadsSize << (threadsSize > 1 ? " threads" : " thread");

    auto boundThreadsByNodeStr = thread_binding_information_as_string();
    if (boundThreadsByNodeStr.empty())
        return ss.str();

    ss << " with NUMA node thread binding: ";
    ss << boundThreadsByNodeStr;

    return ss.str();
}
}
