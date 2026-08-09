# The shell

`src/shell/main.cpp`, `src/shell/uci.h`, `src/shell/uci.cpp`, `src/shell/ucioption.h`, `src/shell/ucioption.cpp`,
`src/shell/engine.h`, `src/shell/engine.cpp`, `src/shell/benchmark.h`, `src/shell/benchmark.cpp`, `src/shell/perft.h`,
`src/shell/tune.h`, `src/shell/tune.cpp`.

The process around the engine: the UCI transport, the option table, the session that holds
the position and the network, and the bench.

Audience: the UCI surface and options.

## The split that matters

`engine.cpp` owns the **session**: the current position and its `StateInfo` chain, the option
table and its on-change callbacks, the resident network, the thread pool and the
transposition table. `uci.cpp` is the **transport** over it and holds no engine state.

A command therefore parses in `uci.cpp` and executes against `engine.cpp`. That is the
boundary to keep when adding a command: a new UCI verb should not grow new state in the
transport.

## The composition root

`engine.cpp` is also where the engine's seams are filled. The engine declares each hook and
reads it through a getter; nothing outside this file calls a setter.

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
| `Engine::ArenaInstallerTag` | arena, output sink, tablebase source | the tag is the **first member declared**, so it runs before anything allocates |
| `Engine::resize_threads` | parallel-for, worker set | both need a pool, and the parallel-for must be installed before `set_tt_size` |

The seams are function pointers rather than closures, so a host that needs per-instance state
passes it as the `void* ctx` the struct carries -- the worker set uses the pool itself. A
file-scope pointer is the alternative, and it makes two engines in one process impossible.

The full catalogue, with each default and what it costs, is in
[00-architecture.md](00-architecture.md).

## The command loop

`UCIEngine::loop` reads lines from standard input and dispatches on the first token. The
recognised set:

```
uci  isready  setoption  ucinewgame  position  go  stop  ponderhit  quit
bench  speedtest  eval  d  flip  compiler  export_net  license  help
```

Everything after `quit` in that list is a Stockfish extension rather than UCI: `d` prints the
board, `eval` prints the evaluation breakdown, `flip` inverts the position, `compiler` prints
the build's toolchain, `export_net` writes the resident network out, `bench` runs the
benchmark and `speedtest` runs the long-form one. **`perft` is not among them** -- it is
`go perft N`, parsed as a limit inside `go`, so a bare `perft` gets "Unknown command". A line
whose first character is `#` is ignored, which is what lets a command file carry comments.

**`go` runs on a separate thread; the loop keeps reading.** That is what lets `stop` arrive
during a search. It is also why end-of-input has to be treated as `quit` -- a pipe that closes
mid-search must end the process rather than leave a detached search running.

`position` takes `startpos` or `fen`, then optional `moves`. The state chain is rebuilt from
scratch each time, which is why `StateListPtr` is a `deque`: the search holds pointers into
it.

## Options

`ucioption.cpp` implements the UCI option protocol with five types -- check, spin, combo,
button, string. An `Option` carries its default, its current value, its type and bounds, and
an `OnChange` callback:

```cpp
using OnChange = std::function<std::optional<std::string>(const Option&)>;
```

The callback returns an optional string, which is how an option reports a problem without
throwing: setting `Threads` resizes the pool, setting `Hash` reallocates the table, setting
`SyzygyPath` rescans for tables, and any of those can fail in a way the GUI should be told
about.

The map is case-insensitive and preserves insertion order, because the `uci` handshake must
list options in a stable order.

## Bench, and why its shape is fixed

`bench` runs a fixed list of positions at a fixed depth and prints the total node count. That
total is the **signature**: a single number that changes if and only if the engine searches a
different tree.

```
bench [ttSize] [threads] [limit] [fenFile] [limitType]
```

defaulting to `16 1 13 default depth`. The defaults are the contract -- a signature is only
comparable against another signature taken with the same arguments.

**`setup_bench` emits one `ucinewgame`, before the first position, and none after.** The table
is cleared once and then carries from each position into the next, so the total is a property
of the whole list *in the order it is listed*: reordering the positions, or dropping one,
changes the number without changing the engine. That is why the position list is fixed and why
`bench 16 1 13 <fenFile>` on a different file is not comparable to the default signature.

**It is single-threaded by default on purpose.** A multi-threaded search is non-deterministic
by design ([04-multithreading.md](04-multithreading.md)), so a multi-threaded bench could not
be a signature.

Every commit that changes the search must carry the new `Bench:` in its message. That is what
makes the number a permanent record rather than a local check --
[10-tooling-ci.md](10-tooling-ci.md) shows the gates reading it back out of `git log`.

## `perft`

`go perft N` counts leaf nodes at depth N -- no evaluation, no transposition table, no
pruning. It is the move generator alone, which makes it the one measurement that isolates
[the board zone](01-engine-board.md).

Its counts are **facts about chess**, not a golden. A mismatch is always a movegen bug.

## `eval`

Prints the evaluation with its breakdown. Rendering centipawns needs `to_cp`, which is the
win-rate model fitted to fishtest statistics -- evaluation-domain knowledge rather than
protocol -- so it lives in `score.h/.cpp` and not here. `tests/depcheck.sh` is what keeps an
engine file from reaching into this zone for it.

## `tune.cpp` -- SPSA tuning

The tuning machinery turns a named constant into a UCI spin option so an external tuner can
drive it. A developer removes `const`, adds a `TUNE(...)` line, and the parameter appears in
the option list.

`types.h` includes `tune.h` after its own include guard so those macros are visible anywhere
without an extra include. **No committed file uses `TUNE(...)`** -- the machinery exists for
the local, temporary edit a tuning run needs, and the constants are hard-coded again once the
result lands. So the include has no consumer a grep can find, and removing it on that evidence
taxes every future tuning run with an include to add first.
