# ITERATION-40

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/nnue_features_bridge.cpp`
- move the retained NNUE feature bridge definitions into
  `zig_compat/nnue_accumulator_bridge.cpp`

## Constraints

- preserve the existing Zig-backed NNUE feature helper exports
- keep the feature method ABI unchanged for the retained NNUE accumulator owner

## Outcome

- removed `zig_compat/nnue_features_bridge.cpp`
- moved the retained NNUE feature bridge definitions into
  `zig_compat/nnue_accumulator_bridge.cpp`, which already owns the live feature
  update flow
- preserved the existing Zig-backed NNUE feature helper exports and behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline nnue features bridge into accumulator

Move the retained NNUE feature bridge definitions into the accumulator
bridge so the separate nnue features bridge translation unit can be
removed.
```
