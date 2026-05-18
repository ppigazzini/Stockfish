# ITERATION-18

Date: `2026-05-18`
Status: complete

## Outcome

- `src/thread.cpp` is no longer compiled in the Zig build path
- thread sizing and best-thread selection logic now live in
  `zig_build/support/thread_rewrites.zig`
- worker lifecycle, custom jobs, and thread-pool state mutation remain explicit
  in `zig_compat/thread_bridge.cpp`

## Scope

- replace `src/thread.cpp` in the Zig build with Zig-owned pure thread sizing
  and best-thread selection logic
- keep actual worker lifecycle, custom jobs, and thread-pool state mutation
  explicit in the compatibility bridge

## Constraints

- preserve the current best-thread voting behavior exactly enough to keep bench
  and signature stable
- keep concurrency and NUMA binding mechanics on the retained C++ side

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- `zig build parity -Dsignature-ref=2336177`

Observed result:

- the parity check completed with `signature OK: 2336177`

## Planned Commit Message

```text
port: rewrite thread selection in zig

Move thread sizing and best-thread selection into Zig while keeping
worker lifecycle, custom jobs, and thread-pool mutation in the
compatibility bridge.
```
