# ITERATION-90

Date: `2026-05-19`
Status: complete

## Scope

- port the accumulator forward/backward update loop control out of the retained
  C++ bridge
- keep the per-step incremental update math in C++ for now while removing the
  range-dispatch helper exports from the Zig boundary

## Constraints

- preserve the existing forward and backward traversal order for both feature
  sets
- keep `refresh_latest` untouched in this slice; only retire the
  forward/backward range helpers
- avoid changing the non-Zig C++ build path in `src/nnue/nnue_accumulator.cpp`
- hold parity at `2336177`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- replaced the Zig calls to `zfish_accumulator_forward_update` and
  `zfish_accumulator_backward_update` with Zig-owned forward/backward loops in
  `zig_build/eval/nnue_accumulator_rewrites.zig`
- added a narrower `zfish_accumulator_incremental_step` export so the remaining
  C++ boundary only owns a single incremental update step per loop iteration
- removed the old forward/backward range helper exports and the corresponding
  Zig-build-only loop-control definitions from
  `zig_compat/nnue_accumulator_bridge.cpp`
- left `refresh_latest` as the remaining update-side owner boundary for a later
  slice

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline accumulator update loops

Move the accumulator forward/backward loop control into Zig and replace
the old C++ range helper exports with a narrower per-step incremental
update entrypoint.
```
