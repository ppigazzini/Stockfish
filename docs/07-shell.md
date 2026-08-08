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

## The command loop

`UCIEngine::loop` reads lines from standard input and dispatches on the first token. The
recognised set:

```
uci  isready  setoption  ucinewgame  position  go  stop  ponderhit  quit
bench  perft  eval  d  flip  compiler  license  help
```

Everything after `quit` in that list is a Stockfish extension rather than UCI: `d` prints the
board, `eval` prints the evaluation breakdown, `flip` inverts the position, `compiler` prints
the build's toolchain, and `bench` runs the benchmark.

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

The transposition table is cleared between positions, so the number does not depend on the
order they run in.

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
protocol -- so it lives in `score.h/.cpp` and `evaluate.cpp` no longer reaches into this zone
to get it. `tests/depcheck.sh` is what keeps that from coming back.

## `tune.cpp` -- SPSA tuning

The tuning machinery turns a named constant into a UCI spin option so an external tuner can
drive it. A developer removes `const`, adds a `TUNE(...)` line, and the parameter appears in
the option list.

`types.h` includes `tune.h` after its own include guard so those macros are visible anywhere
without an extra include. **No committed file uses `TUNE(...)`** -- the machinery exists for
the local, temporary edit a tuning run needs, and the constants are hard-coded again once the
result lands.

The injection has no consumer in the committed tree and is required by the workflow above.
