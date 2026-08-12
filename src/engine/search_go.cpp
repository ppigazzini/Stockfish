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
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

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
#include "parallel.h"
#include "worker_set.h"
#include "../platform/numa.h"

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
    std::vector<ArenaPtr<Worker>>        workers;

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

        return c;
    }();

    return ctx;
}

// A loop rather than ThreadPool's msb form, which would pull bitboard.h in for
// one call made once per rebuild.
usize next_power_of_two(usize count) {
    usize p = 1;
    while (p < count)
        p <<= 1;
    return p;
}

// (Re)build the workers and the SharedState they share.
//
// The histories are sized from the worker count and indexed by masking with
// size - 1, so the count has to be rounded up to a power of two exactly as
// ThreadPool does it. Everything downstream of SharedState has to be rebuilt
// with it: a Worker binds sharedHistory by reference in its initialiser list.
//
// Worker 0 gets the SearchManager and the others a NullSearchManager, matching
// the pool. Index 0 is what is_mainthread() tests, and only the main worker
// applies the depth cap and drives the aspiration loop.
void build_workers(Context& c, usize n) {
    if (c.workers.size() == n)
        return;

    // Destroy the old workers BEFORE the SharedState they hold references into.
    c.workers.clear();

    c.sharedHistories.clear();
    c.sharedHistories.try_emplace(NumaIndex(0), next_power_of_two(n));

    c.shared = std::make_unique<SharedState>(c.options, c.tt, c.sharedHistories, c.stop,
                                             c.increaseDepth);

    c.workers.reserve(n);
    for (usize i = 0; i < n; ++i)
        c.workers.push_back(make_arena_unique<Worker>(
          *c.shared,
          i == 0 ? std::unique_ptr<ISearchManager>(std::make_unique<SearchManager>(c.updates))
                 : std::unique_ptr<ISearchManager>(std::make_unique<NullSearchManager>()),
          i, i, n, NumaReplicatedAccessToken{}));

    // Every Worker carries its own refresh cache and the new ones have none.
    c.seeded = nullptr;
}

// The worker set over those workers. The threads are the host's: this dispatches
// onto the parallel-for seam and owns none of its own, which is what keeps
// engine/ free of a thread it created.
//
// Host thread 0 is skipped because the CALLER is running the main worker on it,
// exactly as ThreadPool::start_searching skips its own main thread.
Context& ws_ctx(void* p) { return *static_cast<Context*>(p); }

void ws_start_searching(void* p) {
    Context& c = ws_ctx(p);
    for (usize i = 1; i < c.workers.size(); ++i)
        parallel_for().run_on(i, [w = c.workers[i].get()]() { w->start_searching(); });
}

void ws_wait_for_search_finished(void* p) {
    Context& c = ws_ctx(p);
    for (usize i = 1; i < c.workers.size(); ++i)
        parallel_for().wait_on(i);
}

usize ws_count(void* p) { return ws_ctx(p).workers.size(); }

Search::Worker* ws_at(void* p, usize index) {
    Context& c = ws_ctx(p);
    return index < c.workers.size() ? c.workers[index].get() : nullptr;
}

// Restores whatever was registered before, rather than calling
// reset_worker_set: this is a borrowed global and putting the DEFAULT back
// would silently unregister a host that had one.
struct ScopedWorkerSet {
    explicit ScopedWorkerSet(const WorkerSet& w) :
        saved(worker_set()) {
        set_worker_set(w);
    }
    ~ScopedWorkerSet() { set_worker_set(saved); }
    ScopedWorkerSet(const ScopedWorkerSet&)            = delete;
    ScopedWorkerSet& operator=(const ScopedWorkerSet&) = delete;

    WorkerSet saved;
};

}  // namespace

// Declared a friend of Worker in search.h: setting a root position is the pool's
// privilege, and this is the only other thing entitled to it.
struct HeadlessRunner {
    // Worker::nodes and Worker::tbHits are private and this struct is Worker's
    // friend, so the two accessors that read them have to be members of it. A
    // static member function is still a plain function pointer, which is what
    // the seam holds.
    static u64 nodes_searched(void* p);
    static u64 tb_hits(void* p);

    static std::optional<GoResult> run(Context&                   c,
                                       const Eval::NNUE::Network& net,
                                       std::string_view           fen,
                                       bool                       chess960,
                                       int                        depth,
                                       usize                      workers);
};

u64 HeadlessRunner::nodes_searched(void* p) {
    u64 sum = 0;
    for (const auto& w : ws_ctx(p).workers)
        sum += u64(w->nodes);
    return sum;
}

u64 HeadlessRunner::tb_hits(void* p) {
    u64 sum = 0;
    for (const auto& w : ws_ctx(p).workers)
        sum += u64(w->tbHits);
    return sum;
}

std::optional<GoResult> HeadlessRunner::run(Context&                   ctxRef,
                                            const Eval::NNUE::Network& net,
                                            std::string_view           fen,
                                            bool                       chess960,
                                            int                        depth,
                                            usize                      workers) {

    Context* ctx = &ctxRef;

    // Refused before anything is built. The built-in parallel-for reports one
    // thread and runs the job inline, and an inline helper never returns: the
    // depth cap tests `mainThread`, a non-main worker has none, so it searches
    // to MAX_PLY waiting for a stop the caller cannot reach the line to raise.
    // Searching with fewer workers than asked for is a different answer, not a
    // slower one, so this says no rather than quietly doing that.
    if (workers == 0 || (workers > 1 && parallel_for().num_threads() < workers))
        return std::nullopt;

    build_workers(*ctx, workers);

    // Seed every refresh cache from this net: a Worker constructed before any
    // net exists has none. Once per net, not once per search.
    if (ctx->seeded != &net)
    {
        for (const auto& worker : ctx->workers)
            worker->ensure_network_replicated(net);
        ctx->seeded = &net;
    }

    ctx->states.clear();
    ctx->states.emplace_back();

    // Set up and validate ONE root position, then copy it into every worker.
    // Validating inside the per-worker loop would leave half the set seeded
    // from a FEN the other half rejected.
    const std::string fenStr(fen);
    Position          root;
    if (root.set(fenStr, chess960, &ctx->states.back()) != std::nullopt)
        return std::nullopt;

    RootMoves rootMoves;
    for (const auto& m : MoveList<LEGAL>(root))
        rootMoves.emplace_back(m);
    if (rootMoves.empty())
        return std::nullopt;  // mate or stalemate: nothing to search

    for (const auto& held : ctx->workers)
    {
        Worker& w = *held;

        w.limits = LimitsType();
        // LimitsType's constructor assigns every member EXCEPT startTime, and
        // the hosted path gets away with it because UCIEngine::parse_limits
        // writes it first thing. Nothing writes it here, and
        // TimeManagement::init reads it unconditionally -- before its own early
        // return -- so leaving it out is an indeterminate read on the one entry
        // point that has no shell above it.
        w.limits.startTime = now();
        w.limits.depth     = depth;
        w.nodes            = 0;
        w.tbHits           = 0;
        w.bestMoveChanges  = 0;
        w.nmpMinPly        = 0;
        w.rootDepth        = 0;
        w.rootMoves        = rootMoves;
        w.tbConfig         = Tablebases::Config();

        // Each worker points at its OWN rootState, as ThreadPool::start_thinking
        // does. They search the same position from separate threads and a shared
        // StateInfo would be written by all of them.
        w.rootPos.set(fenStr, chess960, &w.rootState);
        w.rootState = ctx->states.back();
    }

    Worker& main = *ctx->workers[0];

    // Reset the manager so EVERY headless search is independent. It carries
    // state across searches -- the previous best score, the previous time
    // reduction, the aspiration seed -- which is right for successive `go`
    // commands on one engine and wrong here: leave it and a result depends on
    // what was searched before it, and a driver that walks to a new position
    // every call seeds the aspiration window from an unrelated one, which costs
    // whole seconds on a search that should take milliseconds.
    //
    // This is ThreadPool::clear's reset plus start_thinking's two per-go fields.
    SearchManager& mgr           = *static_cast<SearchManager*>(main.main_manager());
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

    // Registered only above one worker, so the single-worker call still runs
    // with NOTHING registered and every seam on its default -- which is the
    // configuration tests/enginelink.sh exists to exercise.
    const WorkerSet set{ctx,
                        ws_start_searching,
                        ws_wait_for_search_finished,
                        &HeadlessRunner::nodes_searched,
                        &HeadlessRunner::tb_hits,
                        ws_count,
                        ws_at};

    u64 nodes = 0;
    {
        std::optional<ScopedWorkerSet> registration;
        if (workers > 1)
            registration.emplace(set);

        main.start_searching();

        // Read the total INSIDE the registration: outside it the seam is
        // whatever it was before, which for a headless caller reports zero.
        nodes = workers > 1 ? nodes_searched(ctx) : u64(main.nodes);
    }

    return GoResult{main.rootMoves[0].pv[0], main.rootMoves[0].score, nodes};
}

std::optional<GoResult>
go(const Eval::NNUE::Network& net, std::string_view fen, bool chess960, int depth, usize workers) {
    return HeadlessRunner::run(*context(), net, fen, chess960, depth, workers);
}

}  // namespace Stockfish::Search
