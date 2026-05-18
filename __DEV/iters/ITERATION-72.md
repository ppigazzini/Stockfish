# ITERATION-72

Date: `2026-05-18`
Status: complete

## Scope

- move `Engine::Engine` from `zig_compat/engine_bridge.cpp` into
  `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing engine initialization, option wiring, and startup behavior
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved `Engine::Engine` from `zig_compat/engine_bridge.cpp` into
  `zig_compat/uci_bridge.cpp`
- preserved the existing engine initialization, option wiring, and startup
  behavior
- reduced the remaining included engine owner body by moving its top-level
  constructor into the owning UCI file

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move engine constructor into uci

Move Engine::Engine out of the included engine body and into the owning
UCI bridge.
```
