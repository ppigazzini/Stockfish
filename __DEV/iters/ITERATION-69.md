# ITERATION-69

Date: `2026-05-18`
Status: complete

## Scope

- move the Engine callback-registration cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing update, iteration, bestmove, and network callback wiring
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved the Engine callback-registration cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`
- preserved the existing update, iteration, bestmove, and network callback
  wiring
- reduced another layer of UI-facing engine surface that still lived in the
  included engine owner body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move engine callback helpers into uci

Move the Engine callback-registration cluster out of the included
engine body and into the owning UCI bridge.
```
