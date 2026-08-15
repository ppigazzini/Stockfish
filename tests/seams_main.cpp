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
// THREE SEAMS CANNOT BE ASSERTED FROM HERE, and the mechanism is the finding
// rather than the omission:
//
//   output sink   The engine's only emit_line call is in syzygy_extend_pv, on
//                 the time_abort path (search.cpp). Search::go wires every
//                 update callback to a no-op (search_go.cpp), so a headless
//                 search emits nothing. `line` is reachable only by calling it;
//                 `debug_dump` fires from check_time on `tick - lastInfoTime >=
//                 1000`, a WALL-CLOCK branch, so a short run reaches it by luck.
//   worker set    Search::go registers its own set for the duration of a call
//                 with more than one worker and restores what was there. A
//                 recorder registered here is displaced for exactly the window
//                 it was meant to observe.
//   tb source     Search::go assigns `w.tbConfig = Tablebases::Config()`, which
//                 is cardinality 0, so Step 6's guard short-circuits on every
//                 node and probe_wdl is never called whatever is registered.
//                 The root ranking that would set a cardinality lives in the
//                 POOL's path, not the headless one.
//
// Asserting those three needs the shell, or a headless entry point that accepts
// a tablebase configuration. Neither is this file's to invent.
//
// Deliberately not a test framework: it must build from the engine sources
// alone.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <memory>
#include <new>
#include <string>

#include "../src/engine/arena.h"
#include "../src/engine/attacks.h"
#include "../src/engine/clock.h"
#include "../src/engine/nnue/network.h"
#include "../src/engine/position.h"
#include "../src/engine/search_go.h"
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

// Keep the header a multiple of the largest alignment the engine asks for, so
// the pointer handed out has the alignment the raw block had. memory_allocator
// asserts alignment and static_asserts alignof(T) <= 4096; 64 covers every type
// in the tree and keeps the arithmetic obvious.
constexpr usize HeaderBytes = 64;

u64 allocs   = 0;
u64 frees    = 0;
u64 untagged = 0;

void* alloc(usize bytes) {
    void* raw = std::malloc(bytes + HeaderBytes);
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

}  // namespace

int main(int argc, char** argv) {
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
