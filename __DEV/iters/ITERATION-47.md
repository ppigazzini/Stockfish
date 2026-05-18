# ITERATION-47

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/nnue_accumulator_bridge.cpp` from the compiled bridge list
- make `zig_compat/engine_bridge.cpp` the owner translation unit for the NNUE
  accumulator bridge body

## Constraints

- preserve the existing Zig-backed NNUE accumulator helper behavior
- keep the retained NNUE accumulator ABI unchanged while changing only its
  translation-unit owner

## Outcome

- removed `zig_compat/nnue_accumulator_bridge.cpp` from the compiled bridge list
- made `zig_compat/engine_bridge.cpp` the owner translation unit for the NNUE
  accumulator bridge body
- preserved the existing Zig-backed NNUE accumulator helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline accumulator bridge into engine

Make the engine bridge own the NNUE accumulator bridge body so the
separate accumulator bridge translation unit no longer needs to be
compiled.
```
