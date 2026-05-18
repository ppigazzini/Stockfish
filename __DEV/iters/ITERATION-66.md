# ITERATION-66

Date: `2026-05-18`
Status: complete

## Scope

- move the engine `version` constant from `zig_compat/engine_bridge.cpp` into
  `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing engine version string formatting
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved the engine `version` constant from `zig_compat/engine_bridge.cpp`
  into `zig_compat/uci_bridge.cpp`
- preserved the existing engine version string formatting
- removed one more dependency from the outer UCI owner back into the included
  engine body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move engine version constant into uci

Move the engine version constant out of the included engine body and
into the owning UCI bridge.
```
