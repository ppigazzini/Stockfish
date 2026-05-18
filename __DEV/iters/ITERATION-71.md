# ITERATION-71

Date: `2026-05-18`
Status: complete

## Scope

- move `Engine::set_position()` from `zig_compat/engine_bridge.cpp` into
  `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing position setup and illegal-move error behavior
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved `Engine::set_position()` from `zig_compat/engine_bridge.cpp` into
  `zig_compat/uci_bridge.cpp`
- preserved the existing position setup and illegal-move error behavior
- reduced another user-facing engine method from the included owner body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move position setter into uci

Move Engine::set_position out of the included engine body and into the
owning UCI bridge.
```
