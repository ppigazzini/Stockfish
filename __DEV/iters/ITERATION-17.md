# ITERATION-17

Date: `2026-05-18`
Status: complete

## Outcome

- `src/movepick.cpp` is no longer compiled in the Zig build path
- move scoring and partial insertion sort now live in
  `zig_build/support/movepick_rewrites.zig`
- `MovePicker` state, `Position` queries, and history-table lookups remain
  explicit in `zig_compat/movepick_bridge.cpp`

## Scope

- replace `src/movepick.cpp` in the Zig build with Zig-owned move scoring and
  partial sort logic
- keep `MovePicker` object state, `Position` queries, and history-table lookups
  explicit in the compatibility bridge

## Constraints

- preserve current move-ordering scores and the partial insertion sort cutoff
  behavior exactly enough to keep bench and signature stable
- keep the bridge surface flat and value-oriented instead of exposing the
  `MovePicker` object layout to Zig

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- `zig build parity -Dsignature-ref=2336177`

Observed result:

- the parity check completed with `signature OK: 2336177`

## Planned Commit Message

```text
port: rewrite move scoring in zig

Move movepick scoring and partial sorting into Zig while keeping
MovePicker state, Position queries, and history-table lookups in the
compatibility bridge.
```
