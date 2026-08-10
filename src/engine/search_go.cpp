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

#include "search_go.h"

#include <atomic>
#include <deque>
#include <map>
#include <memory>
#include <string>

#include "arena.h"
#include "clock.h"
#include "history.h"
#include "movegen.h"
#include "position.h"
#include "search.h"
#include "searchoptions.h"
#include "tt.h"
#include "timeman.h"
#include "tb_source.h"
#include "../platform/numa.h"
#include "../platform/misc.h"

namespace Stockfish::Search {

namespace {

// Keep the heavy blocks process-static and reuse them. A Worker embeds the NNUE
// refresh cache, so a gate that constructs one per call is a gate nobody leaves
// switched on.
struct Context {
    SearchOptions                        options;
    TranspositionTable                   tt;
    std::map<NumaIndex, SharedHistories> sharedHistories;
    std::atomic<bool>                    stop{false};
    std::atomic<bool>                    increaseDepth{true};
    std::deque<StateInfo>                states;
    SearchManager::UpdateContext         updates;
    std::unique_ptr<SharedState>         shared;
    ArenaPtr<Worker>                     worker;

    // Which net the worker's refresh cache was last seeded from. Seeding writes
    // the whole cache, so reseeding per search dominates the cost of a shallow
    // one: ensure_network_replicated is a load-time operation, not a per-search
    // one.
    const Eval::NNUE::Network* seeded = nullptr;
};

Context* context() {
    // A function-local static with a dynamic initialiser, so the compiler emits
    // the thread-safe guard. The previous shape -- a null pointer tested and
    // then assigned -- was constant-initialised, which gets NO guard: two
    // callers could both see null and both construct, leaking one Context and
    // leaving each holding a different Worker. Never destroyed, deliberately:
    // the Worker owns arena memory whose allocator the host may already have
    // torn down by the time static destructors run.
    static Context* ctx = [] {
        auto* c = new Context();

        // One NUMA node, one worker. The token defaults to index 0 and the map
        // must carry that entry: Worker's first initialiser reaches it through
        // sharedHistories.at(), which throws if the entry is absent.
        c->sharedHistories.try_emplace(NumaIndex(0), 1);

        // Exercise the arena AND the parallel-for: resize allocates through the
        // former and clears through the latter, which runs inline when no host
        // has registered one. Sized for a smoke test, not a benchmark.
        c->tt.resize(1);

        // Install no-op callbacks where the shell would install printing ones:
        // the engine still composes the info lines, so the formatting paths
        // run, and the gate is not judged on its stdout. They must be non-empty
        // targets -- SearchManager calls them unconditionally.
        c->updates.onUpdateNoMoves = [](const InfoShort&) {};
        c->updates.onUpdateFull    = [](const InfoFull&) {};
        c->updates.onIter          = [](const InfoIteration&) {};
        c->updates.onBestmove      = [](std::string_view, std::string_view) {};
        c->updates.onStart         = []() {};

        c->shared = std::make_unique<SharedState>(c->options, c->tt, c->sharedHistories, c->stop,
                                                  c->increaseDepth);

        // Pass thread index 0: that makes this the main worker, which is what
        // applies the depth cap and drives the aspiration loop. A non-main
        // worker searches until someone else stops it, and headless nobody
        // would.
        c->worker = ArenaPtr<Worker>(memory_allocator<Worker>(
          arena_alloc, *c->shared, std::make_unique<SearchManager>(c->updates), usize(0), usize(0),
          usize(1), NumaReplicatedAccessToken{}));

        return c;
    }();

    return ctx;
}

}  // namespace

// Declared a friend of Worker in search.h: setting a root position is the pool's
// privilege, and this is the only other thing entitled to it.
struct HeadlessRunner {
    static std::optional<GoResult>
    run(Context& c, const Eval::NNUE::Network& net, std::string_view fen, bool chess960, int depth);
};

std::optional<GoResult> HeadlessRunner::run(Context&                   ctxRef,
                                            const Eval::NNUE::Network& net,
                                            std::string_view           fen,
                                            bool                       chess960,
                                            int                        depth) {

    Context* ctx = &ctxRef;
    Worker&  w   = *ctx->worker;

    // Seed the refresh cache from this net: a Worker constructed before any net
    // exists has none. Once per net, not once per search.
    if (ctx->seeded != &net)
    {
        w.ensure_network_replicated(net);
        ctx->seeded = &net;
    }

    ctx->states.clear();
    ctx->states.emplace_back();

    const std::string fenStr(fen);
    if (w.rootPos.set(fenStr, chess960, &ctx->states.back()) != std::nullopt)
        return std::nullopt;
    w.rootState = ctx->states.back();

    w.rootMoves.clear();
    for (const auto& m : MoveList<LEGAL>(w.rootPos))
        w.rootMoves.emplace_back(m);
    if (w.rootMoves.empty())
        return std::nullopt;  // mate or stalemate: nothing to search

    w.limits          = LimitsType();
    // LimitsType's constructor assigns every member EXCEPT startTime, and the
    // hosted path gets away with it because UCIEngine::parse_limits writes it
    // first thing. Nothing writes it here, and TimeManagement::init reads it
    // unconditionally -- before its own early return -- so leaving it out is an
    // indeterminate read on the one entry point that has no shell above it.
    w.limits.startTime = now();
    w.limits.depth     = depth;
    w.nodes           = 0;
    w.tbHits          = 0;
    w.bestMoveChanges = 0;
    w.nmpMinPly       = 0;
    w.rootDepth       = 0;
    w.tbConfig        = Tablebases::Config();

    // Reset the manager so EVERY headless search is independent. It carries
    // state across searches -- the previous best score, the previous time
    // reduction, the aspiration seed -- which is right for successive `go`
    // commands on one engine and wrong here: leave it and a result depends on
    // what was searched before it, and a driver that walks to a new position
    // every call seeds the aspiration window from an unrelated one, which costs
    // whole seconds on a search that should take milliseconds.
    //
    // This is ThreadPool::clear's reset plus start_thinking's two per-go fields.
    SearchManager& mgr           = *static_cast<SearchManager*>(w.main_manager());
    mgr.ponder                   = false;
    mgr.stopOnPonderhit          = false;
    mgr.callsCnt                 = 0;
    mgr.originalTimeAdjust       = -1;
    mgr.previousTimeReduction    = 0.85;
    mgr.bestPreviousScore        = VALUE_INFINITE;
    mgr.bestPreviousAverageScore = VALUE_INFINITE;
    mgr.tm.clear();

    ctx->stop.store(false);
    ctx->increaseDepth.store(true);
    ctx->tt.new_search();

    w.start_searching();

    return GoResult{w.rootMoves[0].pv[0], w.rootMoves[0].score, u64(w.nodes)};
}

std::optional<GoResult>
go(const Eval::NNUE::Network& net, std::string_view fen, bool chess960, int depth) {
    return HeadlessRunner::run(*context(), net, fen, chess960, depth);
}

}  // namespace Stockfish::Search
