# ITERATION-79

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed benchmark setup wrappers out of
  `zig_compat/uci_bridge.cpp`
- provide the same `setup_bench` and `setup_benchmark` wrapper surface
  through `src/benchmark.h` only for the Zig build

## Constraints

- keep the existing Zig `zfish_benchmark_setup_bench` and
  `zfish_benchmark_setup_benchmark` exports as the behavior source
- avoid changing the non-Zig C++ build path in `src/benchmark.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only benchmark setup declarations and inline wrapper
  bodies in `src/benchmark.h`
- moved the `Benchmark::setup_bench` and `Benchmark::setup_benchmark`
  wrappers into the `ZFISH_ZIG_BUILD` path in `src/benchmark.h`
- updated `UCIEngine::bench()` and `UCIEngine::benchmark()` to call the
  public `Benchmark::*` wrapper surface instead of the direct Zig exports
  and removed the stale retained declarations from `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig benchmark wrappers

Move the benchmark setup bridge wrappers out of uci_bridge.cpp and let
the Zig build use the existing zfish_benchmark exports through the
ZFISH_ZIG_BUILD header path.
```
