# ITERATION-55

Date: `2026-05-18`
Status: complete

## Scope

- inline the retained NNUE accumulator bridge body into
  `zig_compat/engine_bridge.cpp`
- remove `zig_compat/nnue_accumulator_bridge.cpp`

## Constraints

- preserve the existing retained NNUE accumulator and feature behavior
- keep `zig_compat/engine_bridge.cpp` as the owner file for the inlined body

## Outcome

- inlined the retained NNUE accumulator bridge body into
  `zig_compat/engine_bridge.cpp`
- removed `zig_compat/nnue_accumulator_bridge.cpp`
- preserved the existing retained NNUE accumulator and feature behavior while
  keeping `zig_compat/engine_bridge.cpp` as the owner file for the body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline accumulator body into engine

Inline the retained NNUE accumulator bridge body into the engine
bridge so the separate accumulator body file is no longer needed.
```
