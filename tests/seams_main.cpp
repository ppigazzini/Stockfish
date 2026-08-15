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

// The second host for tests/enginelink.sh: assert a SUBSTITUTED seam TAKES
// EFFECT.
//
// Usage: seams_main <dir-holding-the-net>  ->  0 on success, non-zero with a
// reason on stderr. A directory for the reason enginelink_main gives.
//
// tests/enginelink_main.cpp registers nothing, so it proves each seam DEFAULT is
// reachable and runs. That is a different question from this one. A seam whose
// getter the engine never consults would still pass there -- the default would
// simply never be called and nothing would notice -- so "the defaults work" does
// not establish that the engine reaches a seam at all.
//
// This host registers a RECOGNISABLE implementation and asserts the engine used
// it: a clock returning a scripted sequence, an arena that tags every block. A
// recorder that saw no traffic is the failure.
//
// SEPARATE BINARY, NOT MORE CASES IN enginelink_main.cpp. The arena has an
// ordering invariant no other seam has -- it must be registered before the first
// allocation and never swapped while a block from the previous one is live -- so
// asserting it means owning the process from the first line of main. A file that
// also has to leave every seam unregistered cannot do that.
//
// OWNING THE CLOCK IS WHAT MAKES ANOTHER SEAM REACHABLE, and that is worth
// stating because it reads as a coincidence otherwise. `debug_dump` fires from
// check_time on `tick - lastInfoTime >= 1000` -- a WALL-CLOCK branch -- so on a
// real clock a short run reaches it by luck and a harness asserting it would be
// flaky. A substituted clock that steps a second per reading reaches it on
// purpose, every time. The seam under test supplies the determinism the next
// seam's assertion needs.
//
// ONE SEAM STILL CANNOT BE OBSERVED DURING A SEARCH, and the mechanism is the
// finding rather than the omission:
//
//   worker set    Search::go registers its own set for the duration of a call
//                 with more than one worker and restores what was there. A
//                 recorder registered here is displaced for exactly the window
//                 it was meant to observe. What IS checkable is the restore,
//                 and that is what check_worker_set_is_restored does.
//
// `OutputSink::line` is a separate gap from `debug_dump` and stays one: the
// engine's only emit_line call is in syzygy_extend_pv on the time_abort path,
// which needs a real corpus and a budget small enough to miss.
//
// Deliberately not a test framework: it must build from the engine sources
// alone.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <functional>
#include <thread>
#include <vector>
#include <iostream>
#include <limits>
#include <memory>
#include <new>
#include <string>

#include "../src/engine/arena.h"
#include "../src/engine/attacks.h"
#include "../src/engine/clock.h"
#include "../src/engine/fatal.h"
#include "../src/engine/nnue/network.h"
#include "../src/engine/output_sink.h"
#include "../src/engine/parallel.h"
#include "../src/engine/position.h"
#include "../src/engine/search_go.h"
#include "../src/engine/searchoptions.h"
#include "../src/engine/tb_source.h"
#include "../src/engine/worker_set.h"
#include "../src/engine/types.h"

using namespace Stockfish;

namespace {

int fail(const std::string& why) {
    std::cerr << "seams: " << why << std::endl;
    return 1;
}

// ---------------------------------------------------------------- the arena
//
// Tag every block with a header the free path checks. This is the only proposed
// check for arena.h's ordering invariant -- "a block taken from this default and
// released by the host's implementation is heap corruption with no diagnostic"
// -- and it works in exactly one direction: it catches a block that did NOT come
// from here arriving at this free. The reverse, a block from here freed by
// somebody else, is invisible from inside this allocator and stays invisible.
// Say so rather than let the row read as a proof of both.
namespace tagging_arena {

constexpr u64 Magic = 0x5EA115EA115EA115ULL;

// MATCH THE ALIGNMENT THE DEFAULT GUARANTEES, which is 4096 (arena.cpp's
// default_alloc). A substituted allocator that returns less is not caught at the
// registration or at the allocation: ASSERT_ALIGNED is compiled out under
// NDEBUG, so the block is handed to placement new and the fault arrives later,
// inside the NNUE's aligned vector loads, with nothing pointing back here.
//
// This harness learned that by crashing. A first version used plain malloc with
// a 64-byte header; glibc returns large requests page-aligned, so every
// single-worker search passed, and the two-worker rebuild took a size that came
// back 16-aligned and segfaulted in update_accumulator_refresh_cache.
//
// The header is a WHOLE Alignment rather than 64 for the arithmetic reason: the
// pointer handed out is raw + HeaderBytes, and that only keeps raw's alignment
// when HeaderBytes is a multiple of it.
constexpr usize Alignment   = 4096;
constexpr usize HeaderBytes = Alignment;

u64 allocs   = 0;
u64 frees    = 0;
u64 untagged = 0;

void* alloc(usize bytes) {
    if (bytes > std::numeric_limits<usize>::max() - HeaderBytes - (Alignment - 1))
        return nullptr;
    const usize total = ((bytes + HeaderBytes + Alignment - 1) / Alignment) * Alignment;
    void*       raw   = std::aligned_alloc(Alignment, total);
    if (!raw)
        return nullptr;
    std::memcpy(raw, &Magic, sizeof(Magic));
    ++allocs;
    return static_cast<char*>(raw) + HeaderBytes;
}

void* alloc_hinted(usize bytes, bool) { return alloc(bytes); }

void free_(void* p) {
    if (!p)
        return;
    char* raw = static_cast<char*>(p) - HeaderBytes;
    u64   tag = 0;
    std::memcpy(&tag, raw, sizeof(tag));
    if (tag != Magic)
    {
        // A cross-allocator free. Do NOT std::free(raw) -- the block was not
        // shaped by this allocator, so raw is not its base and releasing it is
        // the corruption this check exists to report.
        ++untagged;
        return;
    }
    std::memset(raw, 0, sizeof(Magic));
    ++frees;
    std::free(raw);
}

}  // namespace tagging_arena

// ---------------------------------------------------------------- the clock
namespace scripted_clock {

u64 reads = 0;
i64 next  = 0;

// Monotonic, for the reason clock.h gives: TimeManagement::elapsed_time
// subtracts two readings, so a clock that can step backwards yields a negative
// elapsed time and check_time never trips its deadline. One microsecond per
// read is monotonic and too slow to reach check_time's 1000ms info branch
// during a depth-limited search, which keeps this substitution from changing
// what the engine does.
i64 now_us() {
    ++reads;
    return next++;
}

// A fixed reading, for the coherence check below. Deliberately NOT a multiple of
// 1000: the whole claim is that the coarse view is a truncation of the fine one,
// and a value that divides evenly cannot tell truncation from coincidence.
i64 fixed_us() {
    ++reads;
    return 1'999'999;
}

}  // namespace scripted_clock

// clock.h: "A host substitutes ONE function and both views move together." That
// is the property the microsecond-quotient shape exists to deliver, and nothing
// in the tree has ever registered a second clock to check it -- set_clock_source
// has a declaration, a definition, and no caller.
//
// Assert the quotient, not just that the substitution was seen: a seam where
// now() kept reading a real clock while now_us() was substituted would hand a
// replay harness a deterministic search with one wall-clock component in it, and
// every assertion about now_us() alone would still pass.
int check_clock_views_move_together() {
    const Clock saved = clock_source();

    scripted_clock::reads = 0;
    set_clock_source(Clock{scripted_clock::fixed_us});

    const i64       us = now_us();
    const TimePoint ms = now();

    set_clock_source(saved);

    if (scripted_clock::reads == 0)
        return fail("the registered clock was never read");
    if (us != 1'999'999)
        return fail("now_us() did not return the registered clock's reading");
    if (ms != 1999)
        return fail("now() is not the millisecond truncation of now_us(); got "
                    + std::to_string(ms));

    std::cout << "  clock: both views move together -- now_us() " << us << ", now() " << ms
              << "\n";
    return 0;
}

// And that the SEARCH reads the seam rather than a clock of its own. An engine
// file that called std::chrono directly would leave no undefined symbol, so
// enginelink.sh cannot see it and depcheck.sh only sees the include -- this is
// the one check that would notice.
int check_search_reads_the_clock(const Eval::NNUE::Network& net, const char* fen) {
    const Clock saved = clock_source();

    scripted_clock::reads = 0;
    scripted_clock::next  = 0;
    set_clock_source(Clock{scripted_clock::now_us});

    const auto r = Search::go(net, fen, false, 6, 1);

    // Restore BEFORE reporting: the seam points at this file's statics, and
    // anything running afterwards must not still reach them.
    const u64 reads = scripted_clock::reads;
    set_clock_source(saved);

    if (!r.has_value())
        return fail("a one-worker search produced no result");
    if (reads == 0)
        return fail("a search read no clock through the seam");

    std::cout << "  clock: a depth-6 search read the registered clock " << reads << " time(s)\n";
    return 0;
}

// ------------------------------------------------------- the tablebase prober
//
// The seam whose cadence the whole handle question turns on: probe_wdl sits in
// Step 6 and is reached PER NODE once tables are loaded. Nothing in-process
// could reach it until Search::go learned to take a Tablebases::Config, because
// the root ranking that sets a cardinality on the hosted path has no equivalent
// here.
namespace recording_tb {

u64 probes = 0;

int max_cardinality(void*) { return 7; }

// WRITE *result ON EVERY PATH. tb_source.h states this as the one thing a host
// must guarantee and says why: search() branches on it to decide whether the
// returned WDLScore is a real verdict, so a prober that returns without writing
// turns an unrelated value into a tablebase cutoff and stores a fabricated score
// in the transposition table. A recognisable implementation that got this wrong
// would be asserting the seam works while corrupting the search through it.
Tablebases::WDLScore probe_wdl(void*, Position&, Tablebases::ProbeState* result) {
    ++probes;
    *result = Tablebases::ProbeState::OK;
    return Tablebases::WDLScore::WDLDraw;
}

Tablebases::Config rank_root_moves(void*,
                                   const SearchOptions&,
                                   Position&,
                                   Search::RootMoves&,
                                   bool,
                                   const std::function<bool()>&) {
    return Tablebases::Config();
}

}  // namespace recording_tb

// A three-man endgame with no castling rights and a zeroed fifty-move counter,
// because Step 6's guard tests all three. A cardinality above the piece count
// also clears the `depth >= probeDepth` half of the guard, so the probe is
// reached on the fifty-move-zero nodes rather than only on deep ones.
int check_tb_source_substituted(const Eval::NNUE::Network& net) {
    const Tablebases::TbSource saved = Tablebases::tb_source();

    recording_tb::probes = 0;
    Tablebases::set_tb_source(Tablebases::TbSource{nullptr, recording_tb::max_cardinality,
                                                  recording_tb::probe_wdl,
                                                  recording_tb::rank_root_moves});

    Tablebases::Config cfg;
    cfg.cardinality = 7;
    cfg.rootInTB    = false;
    cfg.useRule50   = true;
    cfg.probeDepth  = 0;

    const auto r = Search::go(net, "8/8/8/4k3/8/8/4P3/4K3 w - - 0 1", false, 10, 1, cfg);

    const u64 probes = recording_tb::probes;
    Tablebases::set_tb_source(saved);

    if (!r.has_value())
        return fail("the probing search produced no result");
    if (probes == 0)
        return fail("a search with a cardinality reached no registered prober");

    std::cout << "  tb source: a depth-10 search probed the registered prober " << probes
              << " time(s)\n";
    return 0;
}

// ----------------------------------------------------------- the output sink
namespace recording_sink {

u64 lines = 0;
u64 dumps = 0;

void line(std::string_view) { ++lines; }
void debug_dump() { ++dumps; }

}  // namespace recording_sink

namespace stepping_clock {

// A SECOND PER READING. check_time admits itself once per callsCnt nodes and
// then fires the debug dump on `tick - lastInfoTime >= 1000`, so a clock that
// steps a whole second between readings crosses that threshold on purpose
// rather than when the machine happens to be slow.
//
// SEED IT ABOVE WHATEVER THE ENGINE LAST SAW, and the reason is a process-wide
// static this harness ran into rather than predicted. `lastInfoTime` in
// check_time is a function-local static: it is initialised on the FIRST
// admission in the process and then carries across every later search,
// including ones run under a different clock. A stepping clock starting at zero
// therefore compares its own small readings against a threshold left behind by
// the real clock's, `tick - lastInfoTime` is hugely negative, and the dump never
// fires -- which is what the first version of this check reported.
//
// That static is one of the two the search path holds, and it is the one whose
// failure is silent: a wrong info cadence is a plausible number. Reentrancy work
// has to give it an owner.
i64 next = 0;
i64 now_us() {
    next += 1'000'000;
    return next;
}

}  // namespace stepping_clock

int check_output_sink_substituted(const Eval::NNUE::Network& net, const char* fen) {
    const Clock      savedClock = clock_source();
    const OutputSink savedSink  = output_sink();

    recording_sink::dumps = 0;
    recording_sink::lines = 0;
    // Read the real clock BEFORE substituting, so the stepping sequence
    // continues from where the engine's own static was last written rather than
    // from zero.
    stepping_clock::next = now_us();
    set_output_sink(OutputSink{recording_sink::line, recording_sink::debug_dump});
    set_clock_source(Clock{stepping_clock::now_us});

    const auto r = Search::go(net, fen, false, 12, 1);

    const u64 dumps = recording_sink::dumps;
    set_clock_source(savedClock);
    set_output_sink(savedSink);

    if (!r.has_value())
        return fail("the sink search produced no result");
    if (dumps == 0)
        return fail("check_time never reached the registered sink debug_dump");

    std::cout << "  output sink: debug_dump reached " << dumps
              << " time(s) under a stepping clock\n";
    return 0;
}

// ------------------------------------------------------------- the worker set
//
// A thread-owning parallel-for, because Search::go REFUSES a count above what
// parallel_for().num_threads() reports and the built-in one reports 1. That
// refusal is correct and enginelink_main.cpp asserts it; reaching the
// multi-worker path at all needs a host with threads, so this is the smallest
// one that has the right shape. A thread per dispatch rather than a pool: the
// engine ships the pool and the thing under test is whether the seam can start
// a helper and wait for it afterwards.
namespace thread_host {

constexpr usize Threads = 2;

std::thread running[Threads];

usize              num_threads() { return Threads; }
usize              numa_nodes() { return 1; }
std::vector<usize> thread_numa_map() { return {}; }

void run_on(usize t, std::function<void()> fn) {
    if (t >= Threads)
    {
        fn();
        return;
    }
    if (running[t].joinable())
        running[t].join();
    running[t] = std::thread(std::move(fn));
}

void wait_on(usize t) {
    if (t < Threads && running[t].joinable())
        running[t].join();
}

}  // namespace thread_host

//
// Search::go registers its own set for a multi-worker call and puts back what
// was there, so a recorder cannot observe the search itself. The RESTORE is a
// real property and it is the one worth holding: a Search::go that reset the
// seam to the default instead would silently unregister a host that had one,
// which is the failure ScopedWorkerSet exists to avoid.
int check_worker_set_is_restored(const Eval::NNUE::Network& net, const char* fen) {
    set_parallel_for({thread_host::num_threads, thread_host::numa_nodes,
                      thread_host::thread_numa_map, thread_host::run_on, thread_host::wait_on});

    const WorkerSet saved = worker_set();

    // A recognisable ctx: the engine must hand THIS one back afterwards.
    static int marker = 0;
    WorkerSet  mine   = saved;
    mine.ctx          = &marker;
    set_worker_set(mine);

    const auto r = Search::go(net, fen, false, 6, 2);

    const bool restored = worker_set().ctx == &marker;
    set_worker_set(saved);
    // Unregister BEFORE reporting: the seam reaches into this file's statics and
    // nothing running afterwards may still be pointed at them.
    reset_parallel_for();

    if (!r.has_value())
        return fail("a two-worker search produced no result");
    if (!restored)
        return fail("Search::go did not put the host worker set back");

    std::cout << "  worker set: the host registration survived a two-worker search\n";
    return 0;
}

// ------------------------------------------------------------- the fatal seam
namespace recording_fatal {

// RETURNS, deliberately. fatal.h's contract is that engine_abort terminates
// AFTER calling out, precisely because a host handler is an ordinary function
// that may return and every caller is on a path that assumed it would not. A
// handler that returns is therefore the case worth registering: if the process
// survives it, the [[noreturn]] on engine_abort is a lie the compiler has
// already optimised against.
void handler(std::string_view reason) {
    std::cout << "  fatal: host handler reached with reason '" << reason << "'\n";
    std::cout.flush();
}

}  // namespace recording_fatal

// Runs in its own process, because the thing under test ends one. enginelink.sh
// asserts the exit status and the marker together: a run that printed the marker
// and exited 0 would mean the wrapper trusted a handler that returned.
[[noreturn]] void run_abort_probe() {
    set_fatal_source(Fatal{recording_fatal::handler});
    engine_abort("probe");
}

}  // namespace

int main(int argc, char** argv) {
    if (argc >= 2 && std::string(argv[1]) == "--abort")
    {
        run_abort_probe();
        // Unreachable by contract. If control arrives here the seam let a
        // returning handler through, so say so loudly rather than exiting 0 and
        // letting the harness read silence as success.
        std::cout << "  fatal: THE WRAPPER RETURNED -- engine_abort is not [[noreturn]]\n";
        return 0;
    }

    // FIRST, before anything the engine might allocate through. arena.h states
    // the invariant as an ordering one and nothing enforces it; here the harness
    // is the host, so registering on the first line is what makes every later
    // free checkable.
    set_arena(Arena{tagging_arena::alloc, tagging_arena::alloc_hinted, tagging_arena::free_,
                    DefaultHugePageBytes});

    if (argc < 2)
        return fail("usage: seams_main <dir-holding-the-net>");

    const std::filesystem::path netDir(argv[1]);
    if (!std::filesystem::is_directory(netDir))
        return fail("no such directory: " + netDir.string());

    Attacks::init();
    Position::init();

    auto                 net = std::make_unique<Eval::NNUE::Network>();
    Eval::NNUE::EvalFile evalFile{std::nullopt, ""};
    net->load(netDir, std::filesystem::path{}, evalFile);
    if (!evalFile.current.has_value())
        return fail("no net named " + std::string(Eval::NNUE::EvalFile::defaultName)
                    + " loaded from " + netDir.string());

    if (const int rc = check_clock_views_move_together(); rc != 0)
        return rc;

    static constexpr char StartPos[] =
      "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
    if (const int rc = check_search_reads_the_clock(*net, StartPos); rc != 0)
        return rc;

    if (const int rc = check_tb_source_substituted(*net); rc != 0)
        return rc;

    if (const int rc = check_output_sink_substituted(*net, StartPos); rc != 0)
        return rc;

    if (const int rc = check_worker_set_is_restored(*net, StartPos); rc != 0)
        return rc;

    // The arena verdict, read after the work rather than during it: a search
    // allocates the transposition table and the history banks, so a count taken
    // before one proves only that startup allocated.
    if (tagging_arena::allocs == 0)
        return fail("nothing was allocated through the registered arena");
    if (tagging_arena::untagged != 0)
        return fail("a block that did not come from the registered arena was freed through it: "
                    + std::to_string(tagging_arena::untagged));

    std::cout << "  arena: " << tagging_arena::allocs << " tagged allocation(s), "
              << tagging_arena::frees << " matched free(s), 0 cross-allocator free(s)\n";

    std::cout << "seams: every substituted seam was reached\n";
    return 0;
}
