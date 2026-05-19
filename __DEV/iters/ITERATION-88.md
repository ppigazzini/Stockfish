# ITERATION-88

Date: `2026-05-19`
Status: complete

## Scope

- port the accumulator query half so Zig stops calling retained C++ exports for
  stack size, computed-state checks, and refresh checks
- shrink the retained surface in `zig_compat/nnue_accumulator_bridge.cpp`
  before tackling the larger update-dispatch boundary

## Constraints

- preserve the existing update-dispatch C exports for this slice; only retire
  the read-only query half of the boundary
- mirror the real `AccumulatorStack` layout exactly enough to avoid semantic or
  ABI drift in Zig
- keep the non-Zig C++ path unchanged
- hold parity at `2336177`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- mirrored the `AccumulatorStack` query layout in
  `zig_build/eval/nnue_accumulator_rewrites.zig`, including the real embedded
  diff offsets inside the accumulator tail padding
- replaced the Zig calls to retained C++ query exports with direct raw reads of
  stack size, computed flags, and refresh inputs
- inlined the refresh predicates in the Zig accumulator module so the query
  logic operates on the raw C++ diff layout without an ABI-translation hop
- removed the three read-only query exports and the now-dead bridge helper
  methods from `zig_compat/nnue_accumulator_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline accumulator query boundary

Teach the Zig accumulator rewrite to read stack size, computed flags,
and refresh state directly from AccumulatorStack so the read-only query
exports can be removed from nnue_accumulator_bridge.cpp.
```
