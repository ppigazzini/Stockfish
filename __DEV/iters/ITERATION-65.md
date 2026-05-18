# ITERATION-65

Date: `2026-05-18`
Status: complete

## Scope

- move `build_nnue_trace` from `zig_compat/engine_bridge.cpp` into
  `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing NNUE trace formatting and behavior
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved `build_nnue_trace` from `zig_compat/engine_bridge.cpp` into
  `zig_compat/uci_bridge.cpp`
- preserved the existing NNUE trace formatting and behavior
- repaired the local declaration-order issue by adding a forward declaration in
  the owning UCI body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move nnue trace helper into uci

Move the build_nnue_trace helper out of the included engine body and
into the owning UCI bridge.
```
