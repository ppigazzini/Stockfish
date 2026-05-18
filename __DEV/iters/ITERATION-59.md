# ITERATION-59

Date: `2026-05-18`
Status: complete

## Scope

- move the simple `Engine` surface method cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing option, position, visualization, and hashfull behavior
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved the simple `Engine` surface method cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`
- preserved the existing option, position, visualization, and hashfull
  behavior
- reduced the lightweight accessor and presentation surface that still lives in
  the included engine owner body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move simple engine surface into uci

Move the simple Engine accessors and presentation helpers out of the
included engine body and into the owning UCI bridge.
```
