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

#ifndef SEARCH_H_INCLUDED
#define SEARCH_H_INCLUDED

#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>
#include <cstring>

#include "history.h"
#include "nnue/nnue_accumulator.h"
#include "position.h"
#include "score.h"
#include "timeman.h"
#include "types.h"
#include "basetypes.h"
#include "tb_source.h"
#include "clock.h"

namespace Stockfish {

// Different node types, used as a template parameter
enum NodeType {
    NonPV,
    PV,
    Root
};

class TranspositionTable;
class ThreadPool;
struct SearchOptions;

namespace Eval::NNUE {
class Network;
}

namespace Search {

// syzygy_extend_pv() may lead to PVs longer than MAX_PLY
struct RootPVMoves: public std::vector<Move> {
    RootPVMoves() { reserve(MAX_PLY); }
};

struct PVMoves {
    Move  moves[MAX_PLY + 1];
    usize length = 0;

    Move*       begin() { return moves; }
    const Move* begin() const { return moves; }
    Move*       end() { return moves + length; }
    const Move* end() const { return moves + length; }

    Move&       operator[](usize index) { return moves[index]; }
    const Move& operator[](usize index) const { return moves[index]; }

    bool  empty() const { return length == 0; }
    usize size() const { return length; }

    void clear() { length = 0; }

    void push_back(Move move) {
        assert(length < MAX_PLY + 1);
        moves[length++] = move;
    }

    void resize(usize newSize) {
        assert(newSize <= length);
        length = newSize;
    }

    void update(Move move, const PVMoves* childPv) {
        assert(childPv == nullptr || childPv->size() <= MAX_PLY);
        length = childPv ? childPv->length : 0;

        if (childPv)
        {
            std::memcpy(moves + 1, childPv->moves, length * sizeof(Move));
        }

        moves[0] = move;
        ++length;
    }

    PVMoves& operator=(const RootPVMoves& rhs) {
        length = std::min(rhs.size(), usize(MAX_PLY));
        std::memcpy(moves, rhs.data(), length * sizeof(Move));
        return *this;
    }
};

// Stack struct keeps track of the information we need to remember from nodes
// shallower and deeper in the tree during the search. Each search thread has
// its own array of Stack objects, indexed by the current ply.
struct Stack {
    PVMoves*                    pv;
    PieceToHistory*             continuationHistory;
    CorrectionHistory<PieceTo>* continuationCorrectionHistory;
    int                         ply;
    Move                        currentMove;
    Move                        excludedMove;
    Value                       staticEval;
    int                         statScore;
    int                         moveCount;
    bool                        inCheck;
    bool                        ttPv;
    bool                        ttHit;
    bool                        followPV;
    int                         cutoffCnt;
    int                         reduction;
};


// RootMove struct is used for moves at the root of the tree. For each root move
// we store a score and a PV (really a refutation in the case of moves which
// fail low). Score is normally set at -VALUE_INFINITE for all non-pv moves.
struct RootMove {

    explicit RootMove(Move m) { pv.push_back(m); }
    bool extract_ponder_from_tt(const TranspositionTable& tt, Position& pos);
    bool score_is_bound() const { return scoreLowerbound || scoreUpperbound; }
    bool score_is_exact_loss() const {
        return score != -VALUE_INFINITE && is_loss(score) && !score_is_bound();
    }
    void unset_bound_flags() { scoreLowerbound = scoreUpperbound = false; }
    bool operator==(const Move& m) const { return pv[0] == m; }
    // Sort in descending order
    bool operator<(const RootMove& m) const {
        return m.score != score ? m.score < score : m.previousScore < previousScore;
    }

    u64         effort             = 0;
    Value       score              = -VALUE_INFINITE;
    Value       previousScore      = -VALUE_INFINITE;
    Value       averageScore       = -VALUE_INFINITE;
    Value       meanSquaredScore   = -VALUE_INFINITE * VALUE_INFINITE;
    Value       uciScore           = -VALUE_INFINITE;
    bool        scoreLowerbound    = false;
    bool        scoreUpperbound    = false;
    bool        previousScoreExact = false;
    int         selDepth           = 0;
    int         tbRank             = 0;
    Value       tbScore            = -VALUE_INFINITE;
    RootPVMoves pv, previousPV;
};

using RootMoves = std::vector<RootMove>;


// LimitsType struct stores information sent by the caller about the analysis required.
struct LimitsType {

    // Init explicitly due to broken value-initialization of non POD in MSVC
    LimitsType() {
        time[WHITE] = time[BLACK] = inc[WHITE] = inc[BLACK] = npmsec = movetime = startTime =
          TimePoint(0);
        movestogo = depth = mate = perft = infinite = 0;
        nodes                                       = 0;
        ponderMode                                  = false;
    }

    bool use_time_management() const { return time[WHITE] || time[BLACK]; }

    std::vector<std::string> searchmoves;
    TimePoint                time[COLOR_NB], inc[COLOR_NB], npmsec, movetime, startTime;
    int                      movestogo, depth, mate, perft, infinite;
    u64                      nodes;
    bool                     ponderMode;
};


// Bundle the state every Worker in a search shares: the option snapshot, the
// transposition table, the per-NUMA-node histories, and the two run-control
// flags. Every member is a reference, so the host must keep each referent alive
// for as long as any Worker built from this state exists.
//
// `options` is a SearchOptions -- a plain value struct, not a handle on the UCI
// option model -- which is why nothing reachable from here includes ucioption.h.
// Widening it to the live option map would make a search impossible to start
// without the shell's option model behind it; see searchoptions.h.
struct SharedState {
    SharedState(const SearchOptions&                  opts,
                TranspositionTable&                   transpositionTable,
                std::map<HistoryBankIndex, SharedHistories>& sharedHists,
                std::atomic<bool>&                    stopFlagRef,
                std::atomic<bool>&                    increaseDepthFlagRef) :
        options(opts),
        tt(transpositionTable),
        sharedHistories(sharedHists),
        stopFlag(stopFlagRef),
        increaseDepthFlag(increaseDepthFlagRef) {}

    const SearchOptions&                  options;
    TranspositionTable&                   tt;
    std::map<HistoryBankIndex, SharedHistories>& sharedHistories;

    // The two flags every worker shares. Plain std::atomic rather than a host
    // handle, so the engine names no platform type to reach them: the host owns
    // the objects and hands over the references.
    std::atomic<bool>& stopFlag;
    std::atomic<bool>& increaseDepthFlag;
};

class Worker;

// Null Object Pattern, implement a common interface for the SearchManagers.
// A Null Object will be given to non-mainthread workers.
class ISearchManager {
   public:
    virtual ~ISearchManager() {}
    virtual void check_time(Search::Worker&) = 0;
};

struct InfoShort {
    int   depth;
    Score score;
};

struct InfoFull: InfoShort {
    int              selDepth;
    usize            multiPV;
    std::string_view wdl;
    std::string_view bound;
    usize            timeMs;
    usize            nodes;
    usize            nps;
    usize            tbHits;
    std::string_view pv;
    int              hashfull;
};

struct InfoIteration {
    int              depth;
    std::string_view currmove;
    usize            currmovenumber;
};

// Skill structure is used to implement strength limit. If we have a UCI_Elo,
// we convert it to an appropriate skill level, anchored to the Stash engine.
// This method is based on a fit of the Elo results for games played between
// Stockfish at various skill levels and various versions of the Stash engine.
// Skill 0 .. 19 now covers CCRL Blitz Elo from 1320 to 3190, approximately
// Reference: https://github.com/vondele/Stockfish/commit/a08b8d4e9711c2
struct Skill {
    // Lowest and highest Elo ratings used in the skill level calculation
    constexpr static int LowestElo  = 1320;
    constexpr static int HighestElo = 3190;

    Skill(int skill_level, int uci_elo) {
        if (uci_elo)
        {
            double e = double(uci_elo - LowestElo) / (HighestElo - LowestElo);
            level = std::clamp((((37.2473 * e - 40.8525) * e + 22.2943) * e - 0.311438), 0.0, 19.0);
        }
        else
            level = double(skill_level);
    }
    bool enabled() const { return level < 20.0; }
    bool time_to_pick(Depth depth) const { return depth == 1 + int(level); }
    Move pick_best(const RootMoves&, usize multiPV);

    double level;
    Move   best = Move::none();
};

// SearchManager manages the search from the main thread. It is responsible for
// keeping track of the time, and storing data strictly related to the main thread.
class SearchManager: public ISearchManager {
   public:
    using UpdateShort    = std::function<void(const InfoShort&)>;
    using UpdateFull     = std::function<void(const InfoFull&)>;
    using UpdateIter     = std::function<void(const InfoIteration&)>;
    using UpdateBestmove = std::function<void(std::string_view, std::string_view)>;
    using UpdateStart    = std::function<void()>;

    struct UpdateContext {
        UpdateShort    onUpdateNoMoves;
        UpdateFull     onUpdateFull;
        UpdateIter     onIter;
        UpdateBestmove onBestmove;
        UpdateStart    onStart;
    };


    SearchManager(const UpdateContext& updateContext) :
        updates(updateContext) {}

    void check_time(Search::Worker& worker) override;

    void output_pv(Search::Worker&           worker,
                   const TranspositionTable& tt,
                   Depth                     depth);

    // Keep an initial value on every member below: the constructor binds only
    // `updates`, so these initialisers are the whole reason a manager is valid
    // the moment it exists. Hosts that reset per search write these same values
    // back, but a driver that constructs a manager and searches without one
    // would otherwise read indeterminate storage -- and `ponder` is a bool, for
    // which a byte that is neither 0 nor 1 is undefined behaviour rather than a
    // wrong answer.
    //
    // Two members carry none. iterValue needs none because
    // iterative_deepening() fills it before the first read.
    //
    // `tm` is a class and gets its default constructor, which is enough only
    // because TimeManagement now carries its own initialisers -- it did not,
    // and `go wtime 0 btime N` read two budgets out of storage no search had
    // written. That fix belongs there and not here: the members are private, so
    // this site can do nothing but default-construct the object.
    Stockfish::TimeManagement tm;
    double                    originalTimeAdjust = -1;
    int                       callsCnt           = 0;
    std::atomic_bool          ponder             = false;

    std::array<Value, 4> iterValue;
    double               previousTimeReduction    = 0.85;
    Value                bestPreviousScore        = VALUE_INFINITE;
    Value                bestPreviousAverageScore = VALUE_INFINITE;
    bool                 stopOnPonderhit          = false;

    const UpdateContext& updates;
};

class NullSearchManager: public ISearchManager {
   public:
    void check_time(Search::Worker&) override {}
};

// Search::Worker is the class that does the actual search.
// It is instantiated once per thread, and it is responsible for keeping track
// of the search history, and storing data required for the search.
Worker* best_worker(const std::vector<Worker*>& workers);

class Worker {
    friend Worker* best_worker(const std::vector<Worker*>& workers);
   public:
    Worker(SharedState&,
           std::unique_ptr<ISearchManager>,
           usize,
           usize,
           usize,
           HistoryBankIndex);

    // Called at instantiation to initialize reductions tables.
    // Reset histories, usually before a new game.
    void clear();

    // Called when the program receives the UCI 'go' command.
    // It searches from the root position and outputs the "bestmove".
    void start_searching();

    bool is_mainthread() const { return threadIdx == 0; }

    void ensure_network_replicated(const Eval::NNUE::Network& net);

    // Public because they need to be updatable by the stats
    ButterflyHistory mainHistory;
    LowPlyHistory    lowPlyHistory;

    CapturePieceToHistory           captureHistory;
    CorrectionHistory<Continuation> continuationCorrectionHistory;

    TTMoveHistory    ttMoveHistory;
    SharedHistories& sharedHistory;
    ContinuationHistory (&continuationHistory)[2][2];

   private:
    bool iterative_deepening();

    void do_move(Position& pos, const Move move, StateInfo& st, Stack* const ss);
    void
    do_move(Position& pos, const Move move, StateInfo& st, const bool givesCheck, Stack* const ss);
    void do_null_move(Position& pos, StateInfo& st, Stack* const ss);
    void undo_move(Position& pos, const Move move);
    void undo_null_move(Position& pos);

    // This is the main search function, for both PV and non-PV nodes
    template<NodeType nodeType>
    Value
    search(Position& pos, Stack* ss, Value alpha, Value beta, Depth depth, const bool cutNode);

    // Quiescence search function, which is called by the main search
    template<NodeType nodeType>
    Value qsearch(Position& pos, Stack* ss, Value alpha, Value beta);

    int reduction(bool i, Depth d, int mn, int delta) const;

    // Pointer to the search manager, only allowed to be called by the main thread
    SearchManager* main_manager() const {
        assert(threadIdx == 0);
        return static_cast<SearchManager*>(manager.get());
    }

    TimePoint elapsed() const;

    Value evaluate(const Position&);

    LimitsType limits;

    usize              pvIdx, pvLast;
    RelaxedAtomic<u64> nodes, tbHits, bestMoveChanges;
    int                selDepth, nmpMinPly;

    Value optimism[COLOR_NB];

    Position  rootPos;
    StateInfo rootState;
    RootMoves rootMoves;
    Depth     rootDepth;
    Value     rootDelta;

    PVMoves lastIterationIdxPV;

    usize threadIdx, numaThreadIdx, numaTotal;

    // Reductions lookup table initialized at startup
    std::array<int, MAX_MOVES> reductions;  // [depth or moveNumber]

    // The main thread has a SearchManager, the others have a NullSearchManager
    std::unique_ptr<ISearchManager> manager;

    Tablebases::Config tbConfig;

    const SearchOptions&                                     options;
    TranspositionTable&                                      tt;

    // The two flags every worker shares. stopFlag is the one on the hot path:
    // search() reads it at the top of every non-root node and again after every
    // move it searches there, so the per-node cost is one load plus one per
    // move; qsearch() never reads it. increaseDepthFlag is read once per
    // iteration, in iterative_deepening().
    //
    // Keep these REFERENCES. A reference member's binding is fixed at
    // construction, so the compiler may hoist the load of the referent's address
    // out of the node; a pointer member is mutable, so any call that might alias
    // `this` forces a reload. Turning them into pointers is therefore a per-node
    // instruction cost, not a style change -- measure it with
    // tests/perfbudget.sh under both compilers before attempting it.
    //
    // They come in through SharedState, so they are available at construction
    // and the engine still names no host type to reach them.
    std::atomic<bool>&                                       stopFlag;
    std::atomic<bool>&                                       increaseDepthFlag;

    // The replica for THIS worker's NUMA node. A POINTER, null from construction
    // until ensure_network_replicated sets it.
    //
    // A worker is constructible before any net exists -- Engine's constructor
    // sizes the pool while networkFile is still empty -- and is complete then
    // EXCEPT for the refresh cache, which is seeded from the net's
    // feature-transformer biases. So nothing on the construction path may
    // dereference this, and clear() tests it before touching refreshTable.
    // Resolving a replica in the constructor instead would read a replica list
    // that has no entries yet.
    //
    // The platform resolves WHICH replica and hands it in, so the engine never
    // learns the network is replicated at all.
    const Eval::NNUE::Network* network = nullptr;

    // Used by NNUE
    Eval::NNUE::AccumulatorStack  accumulatorStack;
    Eval::NNUE::AccumulatorCaches refreshTable;

    friend class Stockfish::ThreadPool;

    // The engine's own headless entry (search_go.cpp) sets the same root state
    // the platform's pool sets, so it needs the same access the pool has. A
    // friend rather than a public setter: nothing outside these two should be
    // able to hand a worker a root position.
    friend struct HeadlessRunner;
    friend class SearchManager;
};

struct ConthistBonus {
    int index;
    int weight;
};


}  // namespace Search

}  // namespace Stockfish

#endif  // #ifndef SEARCH_H_INCLUDED
