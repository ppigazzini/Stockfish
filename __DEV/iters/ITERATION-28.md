# ITERATION-28

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/nnue_misc_bridge.cpp`
- move its single live NNUE trace wrapper into `zig_compat/evaluate_bridge.cpp`

## Constraints

- preserve NNUE trace formatting and bucket conversion behavior exactly
- avoid widening scope beyond the existing evaluation trace path

## Outcome

- removed `zig_compat/nnue_misc_bridge.cpp`
- moved the only live NNUE trace wrapper into `zig_compat/evaluate_bridge.cpp`
- preserved the existing bucket-wise centipawn conversion and trace formatting
	path while eliminating another standalone bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline nnue trace bridge into evaluate

Move the retained NNUE trace wrapper into the evaluation bridge so the
separate nnue_misc bridge translation unit can be removed.
```
