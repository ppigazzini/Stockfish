# The shell

`src/shell/main.cpp`, `src/shell/uci.h`, `src/shell/uci.cpp`, `src/shell/ucioption.h`, `src/shell/ucioption.cpp`,
`src/shell/engine.h`, `src/shell/engine.cpp`, `src/shell/benchmark.h`, `src/shell/benchmark.cpp`, `src/shell/perft.h`,
`src/shell/console.h`, `src/shell/console.cpp`, `src/shell/tune.h`, `src/shell/tune.cpp`.

The process around the engine: the UCI transport, the option table, the session that holds
the position and the network, and the bench.

Audience: the UCI surface and options.

## Where each thing lives

| Question | File | Symbol |
|---|---|---|
| process startup order | `shell/main.cpp` | `main` |
| the command loop | `shell/uci.cpp` | `UCIEngine::loop` |
| `go`'s argument grammar | `shell/uci.cpp` | `UCIEngine::parse_limits` |
| stopping before a mutation | `shell/uci.cpp` | `UCIEngine::apply_idle` |
| the option table and its callbacks | `shell/engine.cpp` | `Engine::Engine` |
| an option's parse, bounds and round-trip | `shell/ucioption.cpp` | `Option::operator=`, `operator<<` |
| what a search reads out of the options | `engine/searchoptions.h` | `SearchOptions` |
| filling the engine's seams | `shell/engine.cpp` | `Engine::ArenaInstallerTag`, `Engine::resize_threads` |
| the bench command list | `shell/benchmark.cpp` | `Benchmark::setup_bench` |
| `speedtest`'s clamps | `shell/benchmark.cpp` | `Benchmark::setup_benchmark` |
| `sync_cout` and the `dbg_*` counters | `shell/console.cpp` | `operator<<(ostream&, SyncCout)`, `dbg_print` |
| turning a constant into an option | `shell/tune.cpp` | `Tune::make_option` |

`main` does five things in order: print `engine_info()`, `Attacks::init()`, `Position::init()`,
construct a `UCIEngine` (which constructs the `Engine`, which registers the seams and builds the
pool), `Tune::init(uci->engine_options())`, then `loop()`. `Tune::init` is last because it adds
options to a map the `Engine` has already filled.

## The split that matters

`engine.cpp` owns the **session**: the current position and its `StateInfo` chain, the option
table and its on-change callbacks, the resident network, the thread pool and the
transposition table. `uci.cpp` is the **transport** over it and holds no engine state.

A command therefore parses in `uci.cpp` and executes against `engine.cpp`. That is the
boundary to keep when adding a command: a new UCI verb should not grow new state in the
transport.

`console.cpp` is the third piece and it belongs to the shell for the same reason: a process's
standard output stream and a diagnostic dump printed onto it are not things the engine needs in
order to search. It owns `sync_cout`/`sync_endl` and the `dbg_hit_on` / `dbg_mean_of` /
`dbg_stdev_of` / `dbg_extremes_of` / `dbg_correl_of` counters that `dbg_print` dumps. Nothing under
`src/engine/` includes `console.h`, and `tests/linkcheck.sh` fails the engine-to-shell edge that
including it would create -- the engine reaches output through the `OutputSink` seam instead.

## The composition root

`engine.cpp` is also where the engine's seams are filled. The engine declares each hook, this
file fills it, and `host.cpp` takes **one const snapshot** of the filled set. The snapshot is
the thing that travels: `SharedState` carries it as a `const Host&` and each `Worker` unpacks it
at construction. Nothing outside this file writes a seam.

**The snapshot is taken once, in `resize_threads`, and that is the only site.** It sits after
the `set_parallel_for` and `set_worker_set` calls and before `threads.set` builds the Workers,
because a Worker binds the snapshot for the life of the pool: taken one line earlier it would
hold the inline parallel-for and the refusing worker set, and the search would run, report no
workers and return a plausible number.

**A seam's target can change afterwards without a new snapshot**, because what a `Host` holds is
function pointers and a `ctx`, not the state behind them. `SyzygyPath`'s handler calls
`Tablebases::init`, which reloads the tables the tablebase seam reads through its `ctx`; the
pointers are the same pointers and no Worker has to be rebuilt. **Changing which function a
seam calls is the thing that needs a fresh snapshot**, and today only pool construction does
that.

```cpp
// src/engine/output_sink.h -- the engine declares the seam.
struct OutputSink {
    void (*line)(std::string_view);
    void (*debug_dump)();
};
void set_output_sink(const OutputSink& s);

// src/shell/engine.cpp -- the composition root fills it.
set_output_sink({host_line, dbg_print});
```

The registration points are two, and both are ordering-sensitive:

| Where | Fills | Why there |
|---|---|---|
| `Engine::ArenaInstallerTag` | output sink, tablebase source, arena | the tag is the **first member declared**, so it runs before anything allocates |
| `Engine::resize_threads` | parallel-for, worker set | both need a pool, and the parallel-for must be installed before `set_tt_size` |

`ThreadPool threads` is the **last member declared**, which is the same rule read backwards:
reverse destruction order takes the workers down before `searchOptions`, `host`, `tt`, `network`,
`updateContext` and `sharedHists`, every one of which a `Search::Worker` holds by reference or
by pointer. Declaration order in `engine.h` fixes both ends; the constructor's initialiser list
fixes neither.

```sh
sed -n '/^   private:/,/^};/p' src/shell/engine.h        # the order is the invariant
```

**`~Engine` puts back what it registered, and the arena is the exception.** It waits for the
search, then calls `reset_worker_set()` and `reset_parallel_for()` and drops `hostPool`, because
a seam still pointing at a destroyed pool is a call through a dangling `ctx` the moment anything
else searches. **The arena is deliberately left installed**: `~TranspositionTable` frees through
`arena()` during member destruction, which runs *after* the destructor body, so resetting it here
would hand a host-allocated block to the engine's fallback `free` -- heap corruption with no
diagnostic. A seam that owns memory is unregistered on a different schedule from one that owns a
callback, and this is the one place the two rules meet.

**The rule has an assertion behind it, and an assertion is a debug-build guarantee.**
`arena.h`'s `arena_alloc` / `arena_alloc_hinted` / `arena_free` wrappers count blocks acquired and
released, and `set_arena` asserts `arena_live_blocks() == 0` before it swaps -- so under
`debug=yes` replacing an allocator while it still owns memory aborts with a message instead of
corrupting a heap on some later free. `-DNDEBUG` deletes that assert from what ships, so the check
is a development tool and the ordering is still the thing that has to hold.

`arena_live_blocks` and the counters exist unconditionally and only the increments are
`#ifndef NDEBUG`: whether a symbol *exists* must not depend on `NDEBUG`, or a release build and a
debug build of the same tree disagree about the ABI, and `make build debug=yes` over a release tree
stops linking. A release build emits no counting at all -- verified by `objdump`, not by reading.

The seams are function pointers rather than closures, so a host that needs per-instance state
passes it as the `void* ctx` the struct carries -- the worker set uses the pool itself, which
spares it a global of its own. The parallel-for has no `ctx` and so needs one: `hostPool` in
`engine.cpp`. **Neither shape makes two engines in one process work.** Each seam's registered
value is a single file-scope `current` in the engine (`src/engine/worker_set.cpp`,
`src/engine/parallel.cpp`), so a second `Engine` overwrites the first's registration and the
first then dispatches onto the second's pool. `Engine::search_clear` carries a `TODO` saying the
same thing about `Tablebases::init`. Fixing it means giving the seams an owner, not a `ctx`.

The full catalogue, with each default and what it costs, is in
[00-architecture.md](00-architecture.md).

## The command loop

`UCIEngine::loop` reads lines from standard input and dispatches on the first token:

```sh
grep -nE 'token == "' src/shell/uci.cpp | sed -n '1,20p'
```

```
uci  isready  setoption  ucinewgame  position  go  stop  ponderhit  quit
bench  speedtest  eval  d  flip  compiler  export_net  help  license
```

`help` and `license` each also answer to a `--`-prefixed spelling, so the command-line form works.
`speedtest` is spelled once, as `BenchmarkCommand` in `uci.cpp`; the string is not repeated.

Everything after `quit` in that list is a Stockfish extension rather than UCI: `d` prints the
board, `eval` prints the evaluation breakdown, `flip` inverts the position, `compiler` prints
the build's toolchain, `export_net` writes the resident network out, `bench` runs the
benchmark and `speedtest` runs the long-form one. **`perft` is not among them** -- it is
`go perft N`, parsed as a limit inside `go`, so a bare `perft` gets "Unknown command". A line
whose first character is `#` is ignored, which is what lets a command file carry comments.

**Arguments given on the command line are one-shot.** `loop` seeds `cmd` from `argv` and its
`while` condition is `token != "quit" && cli.argc <= 1`, so `./stockfish bench` runs once and exits
without reading standard input at all. That is what makes `stockfish bench` usable from a script.

**`go` runs on a separate thread; the loop keeps reading.** That is what lets `stop` arrive
during a search. It is also why end-of-input has to be treated as `quit` -- a pipe that closes
mid-search must end the process rather than leave a detached search running.

**Every command that mutates engine state goes through `UCIEngine::apply_idle`**, which stops
the search, waits for it, then applies the change. `setoption` and `export_net` are its callers:

```sh
git grep -n 'apply_idle' -- src
```

Route a new mutating command through it rather than calling `wait_for_search_finished()` at the
handler: the wait runs on the reader thread, and the reader thread is the only one that can
deliver the `stop` that releases it, so a handler that waits without stopping first wedges the
engine permanently against a `go infinite`.

The choice is visible to a GUI and it is stop-first rather than refuse-while-searching: an
option pushed mid-ponder is applied **and** a `bestmove` comes back, where refusing would give
neither and no way to tell which. The cost is that such an option ends the ponder.

**`position` and `go` do not go through it**, and that is not an oversight but it is a sharp edge.
`Engine::go` waits for the previous search itself before it touches `searchOptions` or resolves
`searchmoves`; `Engine::set_position` does not wait at all. Both can therefore reach
`UCIEngine::terminate_on_critical_error` with a search running -- an unparsable FEN during
`go infinite` -- which is why that function stops and joins the search before `std::exit`. Without
the join, `std::exit` runs static destructors, `~TBTables` munmaps every tablebase, and workers
still inside `decompress_pairs` read the unmapped pages.

`position` takes `startpos` or `fen`, then optional `moves`, and rebuilds the state chain from
scratch in `Engine::set_position` -- which is why `StateListPtr` is a `deque`: the search holds
pointers into it and a `vector` would invalidate them on resize. **A `position` line whose first
token is neither `startpos` nor `fen` is dropped silently**: the handler returns without setting a
position and without printing anything, so the engine keeps the previous one and a GUI has no way
to notice.

## Options

### The table

Registered in `Engine::Engine`, in this order -- which is the order the `uci` handshake prints them
in:

```sh
grep -n 'options.add' src/shell/engine.cpp
```

| Option | Type | `OnChange` | What it costs |
|---|---|---|---|
| `Debug Log File` | string | `start_logger` | tees stdin and stdout to a file |
| `NumaPolicy` | string | parses and applies, **returns a diagnostic on failure** | rebinds threads |
| `Threads` | spin | `resize_threads` | rebuilds the pool and re-snapshots the `Host` |
| `Hash` | spin | `set_tt_size` | reallocates the table, cleared through the parallel-for |
| `Clear Hash` | button | `search_clear` | clears TT, histories, and remaps the tablebases |
| `Ponder` | check | -- | read as `SearchOptions::ponder` |
| `MultiPV` | spin | -- | how many root lines are searched |
| `Skill Level` | spin | -- | with `UCI_Elo`, drives `Search::Skill` |
| `Move Overhead` | spin | -- | also the budget `syzygy_extend_pv` spends |
| `nodestime` | spin | -- | nodes-per-millisecond clock instead of wall time |
| `UCI_Chess960` | check | -- | read by `Engine::set_position` and `perft` |
| `UCI_LimitStrength` | check | -- | switches `Skill Level` for `UCI_Elo` |
| `UCI_Elo` | spin | -- | bounded by `Search::Skill::LowestElo`/`HighestElo` |
| `UCI_ShowWDL` | check | -- | read per `info` line |
| `SyzygyPath` | string | `Tablebases::init` | rescans and remaps ([05-tablebases.md](05-tablebases.md)) |
| `SyzygyProbeDepth` | spin | -- | Step 6's `probeDepth` |
| `Syzygy50MoveRule` | check | -- | `Rule50` and `tbConfig.useRule50` |
| `SyzygyProbeLimit` | spin | -- | a **ceiling**, clamped down to what is on disk |
| `EvalFile` | string | `load_network` | reloads and re-replicates the net |

**Defaults are not written here on purpose.** They move, and there is a gate that reads them out of
the tree instead: `tests/optiondefaults.sh` prints `uci` from a built engine, reads the
field-to-option mapping out of `Engine::search_options()`, and compares each default against
`SearchOptions`'s own. Read that script rather than this table for a current value. It covers only
the options the engine has a field for; `Hash`, `EvalFile`, `SyzygyPath`, `UCI_Chess960` and
`Debug Log File` are the shell's alone, with no second copy to drift against.

### How one round-trips

`ucioption.cpp` implements the protocol with five types -- check, spin, combo, button, string --
chosen by which `Option` constructor is used. **No registered option is a combo**: the two-`const
char*` constructor that sets `type("combo")` has no caller in `src/`, so that arm of
`Option::operator=` and of `operator<<` is unexercised by anything but a `Tune` run.

Out:

```
uci  ->  operator<<(std::ostream&, const OptionsMap&)
```

which scans `idx` from 0 to `size() - 1` and prints the option whose `idx` matches, so the
handshake order is insertion order even though `options_map` is a `std::map` sorted
case-insensitively. `insertOrder` must therefore be a **member** of `OptionsMap` and never a
function-local `static` in `add()`: one counter shared by every map ever constructed would make a
second `OptionsMap` start numbering where the first stopped, putting every one of its options
outside the range `operator<<` scans and dropping the whole `uci` handshake with no diagnostic.
Nothing constructs a second one today, so this is a bound rather than a repair.

In:

```
setoption name <N> value <V>  ->  OptionsMap::setoption  ->  Option::operator=
```

`setoption` accumulates spaces into both the name and the value, so `Move Overhead` and a path with
spaces both work. An unknown name prints `No such option:`.

`Option::operator=` validates and then fires:

- empty value on anything but `button` or `string` -- rejected;
- `check` with a value that is not `true`/`false` -- rejected;
- `spin` outside `[min, max]`, or not an integer at all (`strtoll` must consume the whole token) --
  rejected;
- `combo` naming a token not in the default list, or the literal `var` -- rejected;
- `string` maps the literal `<empty>` back to `""`, which is what `operator<<` prints for an empty
  default, so the two directions agree;
- `button` never stores a value; it exists only to fire its callback.

**A rejection is silent.** Every one of those arms is `return *this;` with nothing printed, so a GUI
that sends `setoption name Threads value 0` gets no reply and the engine keeps the old value. The
protocol has no error reply for `setoption`, but the engine has an `info string` channel and does
not use it here.

The callback's return value is that channel:

```cpp
using OnChange = std::function<std::optional<std::string>(const Option&)>;
```

A returned string is handed to `OptionsMap::info`, the `InfoListener` that `UCIEngine` installs to
print `info string`. **Only `NumaPolicy` uses it to report a failure.** `Threads` and `NumaPolicy`
return thread-allocation text on success; `Hash`, `SyzygyPath`, `EvalFile`, `Clear Hash` and
`Debug Log File` all return `std::nullopt` unconditionally, so a `Hash` allocation that fails or a
`SyzygyPath` that names nothing is not reported through this path at all.

## Bench, and why its shape is fixed

`bench` runs a fixed list of positions at a fixed depth and prints the total node count. That
total is the **signature**: a single number that changes if and only if the engine searches a
different tree.

```
bench [ttSize] [threads] [limit] [fenFile] [limitType]
```

defaulting to `16 1 13 default depth`. The defaults are the contract -- a signature is only
comparable against another signature taken with the same arguments. `fenFile` also takes `current`,
for the position already set; `limitType` also takes `eval`, which traces the evaluation of each
position instead of searching it.

**`setup_bench` emits one `ucinewgame`, before the first position, and none after.** The table
is cleared once and then carries from each position into the next, so the total is a property
of the whole list *in the order it is listed*: reordering the positions, or dropping one,
changes the number without changing the engine. That is why the position list is fixed and why
`bench 16 1 13 <fenFile>` on a different file is not comparable to the default signature.

**A line in the fen file containing `setoption` is passed through rather than treated as a
position.** That is how a caller configures the engine inside the measured region --
`tests/perfbudget.sh --syzygy` writes a `SyzygyPath` line at the top of its generated file, which is
why the table load lands inside the profile ([05-tablebases.md](05-tablebases.md)).

**It is single-threaded by default on purpose.** A multi-threaded search is non-deterministic
by design ([04-multithreading.md](04-multithreading.md)), so a multi-threaded bench could not
be a signature.

Every commit that changes the search must carry the new `Bench:` in its message. That is what
makes the number a permanent record rather than a local check --
[10-tooling-ci.md](10-tooling-ci.md) shows the gates reading it back out of `git log`.

`speedtest` is the other benchmark and it is not a signature: `setup_benchmark` derives threads,
hash and duration from what the host has and clamps every one of them, reporting each clamp. The
ceiling on threads is `SYSTEM_THREADS_NB` rather than what the `Threads` option accepts, because
the option's range reaches `max(1024, 4 * cores)` and each worker carries tens of megabytes of
histories and accumulator caches.

## `perft`

`go perft N` counts leaf nodes at depth N -- no evaluation, no transposition table, no
pruning. It is the move generator alone, which makes it the one measurement that isolates
[the board zone](01-engine-board.md). `UCIEngine::perft` runs it through `Engine::perft`, which
takes the FEN and the `UCI_Chess960` flag rather than sharing the live position.

Its counts are **facts about chess**, not a golden. A mismatch is always a movegen bug.

## `eval`

Prints the evaluation with its breakdown. Rendering centipawns needs `to_cp`, which is the
win-rate model fitted to fishtest statistics -- evaluation-domain knowledge rather than
protocol -- so it lives in `score.h/.cpp` and not here. `tests/depcheck.sh` is what keeps an
engine file from reaching into this zone for it.

`UCIEngine::format_score` is the shell's half of the same split: it visits a `Score` and emits
`mate n`, `cp v`, or -- for a tablebase verdict -- `(tb.win ? TB_CP : -TB_CP) - tb.plies` with
`TB_CP = 20000`. A tablebase score is deliberately rendered as a large centipawn value rather than
as a mate, because it is proven and is not a mate.

## `tune.cpp` -- SPSA tuning

The tuning machinery turns a named constant into a UCI spin option so an external tuner can
drive it. A developer removes `const`, adds a `TUNE(...)` line, and the parameter appears in
the option list.

The mechanics: `TUNE(...)` expands to a file-scope `int` initialised by a lambda, so
`Tune::add` runs during static initialisation and records the variable's address and name.
`Tune::init(OptionsMap&)` -- called from `main` after the `Engine` is built -- then walks that list
and calls `make_option` for each, which registers a spin bounded by its `SetRange` and prints one
CSV line per parameter, ready to paste into fishtest. Every generated option shares one `on_tune`
callback that reads the whole set back into the variables. A parameter whose range is empty
(`min == max`) generates no option at all.

`types.h` includes `tune.h` after its own include guard so those macros are visible anywhere
without an extra include. **No committed file uses `TUNE(...)`**:

```sh
git grep -n 'TUNE(' -- src        # only tune.h's own definition and its comments
```

The machinery exists for the local, temporary edit a tuning run needs, and the constants are
hard-coded again once the result lands. So the include has no consumer a grep can find, and
removing it on that evidence taxes every future tuning run with an include to add first.
