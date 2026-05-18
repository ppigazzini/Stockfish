# ITERATION-67

Date: `2026-05-18`
Status: complete

## Scope

- move the `SyncCout` output helper cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing synchronized output behavior
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved the `SyncCout` output helper cluster from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`
- preserved the existing synchronized output behavior
- reduced another shared runtime helper dependency from the included engine
  owner body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move sync output helpers into uci

Move the SyncCout output helper cluster out of the included engine body
and into the owning UCI bridge.
```
