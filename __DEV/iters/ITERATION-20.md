# ITERATION-20

Date: `2026-05-18`
Status: complete

## Scope

- replace `src/nnue/nnue_accumulator.cpp` in the Zig build with Zig-owned
  accumulator stack evaluation flow
- keep the hot accumulator kernels, feature-index gathering, and cache-entry
  mutation explicit in the compatibility bridge

## Constraints

- preserve the current NNUE accumulator semantics for both PSQ and threat
  feature sets
- keep the SIMD-sensitive numeric update kernels on the retained C++ side for
  now

## Outcome

- replaced `src/nnue/nnue_accumulator.cpp` in the Zig build with a Zig-owned
  evaluation flow that decides when each accumulator side can replay
  incrementally versus when it must refresh from the latest stack state
- retained the hot SIMD accumulator kernels, cache refresh mutation, and
  feature-index gathering in `zig_compat/nnue_accumulator_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: rewrite nnue accumulator flow in zig

Move NNUE accumulator stack orchestration into Zig while keeping hot
update kernels, feature-index gathering, and cache mutation in the
compatibility bridge.
```
