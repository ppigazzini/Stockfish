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

#ifndef ENGINE_H_INCLUDED
#define ENGINE_H_INCLUDED

#include <functional>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <variant>
#include <vector>

#include "../engine/history.h"
#include "../engine/nnue/network.h"
#include "../engine/nnue/nnue_misc.h"
#include "../platform/numa_shared.h"
#include "../engine/position.h"
#include "../engine/search.h"
#include "../platform/syzygy/tbprobe.h"  // for Stockfish::Depth
#include "../platform/thread.h"
#include "../engine/tt.h"
#include "../engine/types.h"  // for Stockfish::Is64Bit, used by MaxHashMB
#include "ucioption.h"
#include "../engine/basetypes.h"
#include "../platform/numa.h"

#include "../engine/searchoptions.h"

namespace Stockfish {

constexpr int MaxHashMB = Is64Bit ? 33554432 : 2048;
extern int    MaxThreads;

class Engine {
   public:
    using InfoShort = Search::InfoShort;
    using InfoFull  = Search::InfoFull;
    using InfoIter  = Search::InfoIteration;

    Engine(std::optional<std::filesystem::path> path = std::nullopt);

    // Cannot be movable due to components holding backreferences to fields
    Engine(const Engine&)            = delete;
    Engine(Engine&&)                 = delete;
    Engine& operator=(const Engine&) = delete;
    Engine& operator=(Engine&&)      = delete;

    // Out of line: it uninstalls the seams this engine registered, and the
    // file-scope pointer one of them reaches through lives in engine.cpp.
    ~Engine();

    std::variant<u64, PositionSetError> perft(const std::string& fen, Depth depth, bool isChess960);

    // non blocking call to start searching
    void go(Search::LimitsType&);
    // non blocking call to stop searching
    void stop();

    // blocking call to wait for search to finish
    void wait_for_search_finished();
    // set a new position, moves are in UCI format
    std::optional<PositionSetError> set_position(const std::string&              fen,
                                                 const std::vector<std::string>& moves);

    // modifiers

    bool set_numa_config_from_option(const std::string& o);
    SearchOptions search_options() const;
    void          resize_threads();
    void set_tt_size(usize mb);
    void set_ponderhit(bool);
    void search_clear();

    void set_on_update_no_moves(std::function<void(const InfoShort&)>&&);
    void set_on_update_full(std::function<void(const InfoFull&)>&&);
    void set_on_iter(std::function<void(const InfoIter&)>&&);
    void set_on_bestmove(std::function<void(std::string_view, std::string_view)>&&);
    void set_on_start(std::function<void()>&&);
    void set_on_verify_network(std::function<void(std::string_view)>&&);

    // network related

    void                                 verify_network() const;
    std::unique_ptr<Eval::NNUE::Network> get_default_network();
    void                                 load_network(const std::filesystem::path& file);
    void save_network(const std::optional<std::filesystem::path>& file);

    // utility functions

    void trace_eval() const;

    const OptionsMap& get_options() const;
    OptionsMap&       get_options();

    int get_hashfull(int maxAge = 0) const;

    std::string                          fen() const;
    std::optional<PositionSetError>      flip();
    std::string                          visualize() const;
    std::vector<std::pair<usize, usize>> get_bound_thread_count_by_numa_node() const;
    std::string                          get_numa_config_as_string() const;
    std::string                          numa_config_information_as_string() const;
    std::string                          thread_allocation_information_as_string() const;
    std::string                          thread_binding_information_as_string() const;

   private:
    // Keep this DECLARED FIRST. Members are initialised in declaration order,
    // not in the order the constructor's init list names them, so this
    // declaration -- not the init list in engine.cpp -- is what makes the arena
    // installer run before any member below it allocates. Move it down and a
    // block taken from the engine's fallback allocator is released by the
    // host's, which is heap corruption with no diagnostic.
    struct ArenaInstallerTag {
        ArenaInstallerTag();
    } arenaInstaller;

    const std::filesystem::path binaryDirectory;

    NumaReplicationContext numaContext;

    Position     pos;
    StateListPtr states;

    OptionsMap                                        options;
    // Keep the option snapshot as a member, not a local in resize_threads:
    // every Worker binds it as a const SearchOptions& at construction and reads
    // it for the life of the thread pool, so a local would dangle the moment
    // resize_threads returned. ThreadPool::set takes its SharedState by value
    // and drops it, so the pool itself holds nothing -- the Workers are the
    // reason this must outlive them.
    SearchOptions                                     searchOptions;
    TranspositionTable                                tt;
    Eval::NNUE::EvalFile                              networkFile;
    LazyNumaReplicatedSystemWide<Eval::NNUE::Network> network;

    Search::SearchManager::UpdateContext  updateContext;
    std::function<void(std::string_view)> onVerifyNetwork;
    std::map<NumaIndex, SharedHistories>  sharedHists;

    // Keep this DECLARED LAST, for the mirror of the reason the arena installer
    // is declared first. Members are destroyed in reverse declaration order, and
    // every Thread this owns holds a Search::Worker bound to declarations above:
    // searchOptions and tt by reference, one SharedHistories out of sharedHists
    // by reference, a pointer into a replica owned by network, and -- on the
    // main thread only -- a SearchManager holding updateContext by reference.
    // Declaring the pool earlier destroys those referents while the Workers
    // still exist, and nothing diagnoses it.
    ThreadPool threads;
};

}  // namespace Stockfish


#endif  // #ifndef ENGINE_H_INCLUDED
