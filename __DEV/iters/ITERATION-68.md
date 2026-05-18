# ITERATION-68

Date: `2026-05-18`
Status: complete

## Scope

- move the Engine search-control method cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing perft, go, stop, and search-clear behavior
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved the Engine search-control method cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`
- preserved the existing perft, go, stop, and search-clear behavior
- reduced the remaining active engine-control surface that still lives in the
  included engine owner body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move engine search control into uci

Move the Engine search-control method cluster out of the included
engine body and into the owning UCI bridge.
```
