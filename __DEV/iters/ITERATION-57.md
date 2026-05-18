# ITERATION-57

Date: `2026-05-18`
Status: complete

## Scope

- move the engine version/info helper cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing engine info text and compiler-info formatting
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved the engine version/info helper cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`
- preserved the existing engine info text and compiler-info formatting
- reduced the remaining helper surface that still lives in the included engine
  owner body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move engine info helpers into uci

Move the engine version and compiler info helper cluster out of the
included engine body and into the owning UCI bridge.
```
