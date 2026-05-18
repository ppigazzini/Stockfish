# ITERATION-19

Date: `2026-05-18`
Status: complete

## Outcome

- `src/engine.cpp` is no longer compiled in the Zig build path
- engine NUMA, thread-allocation, and network-status formatting helpers now
  live in `zig_build/support/engine_rewrites.zig`
- option registration, thread-pool mutation, and live engine state remain
  explicit in `zig_compat/engine_bridge.cpp`

## Scope

- replace `src/engine.cpp` in the Zig build with Zig-owned engine status and
  formatting helpers
- keep option registration, thread-pool mutation, and other stateful control
  flow explicit in the compatibility bridge

## Constraints

- preserve current UCI-visible info strings for network verification and thread
  allocation reporting
- keep the bridge as the owner of the live engine objects and callbacks

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- `zig build parity -Dsignature-ref=2336177`

Observed result:

- the parity check completed with `signature OK: 2336177`

## Planned Commit Message

```text
port: rewrite engine status helpers in zig

Move engine status and formatting helpers into Zig while keeping
option registration, thread-pool mutation, and live engine state in the
compatibility bridge.
```
