# ITERATION-64

Date: `2026-05-18`
Status: complete

## Scope

- move the misc/string helper cluster from `zig_compat/engine_bridge.cpp`
  into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing logger, hashing, file-read, whitespace, and command-line
  helper behavior
- move the local string-free helper together with the functions that depend on it
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved the misc/string helper cluster from `zig_compat/engine_bridge.cpp`
  into `zig_compat/uci_bridge.cpp`
- preserved the existing logger, hashing, file-read, whitespace, and command-line
  helper behavior
- resolved the helper-scope mismatch by keeping a tiny engine-local string-free
  helper for the remaining tablebase path and using a renamed UCI-local helper
  for the moved functions

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move misc helpers into uci

Move the misc/string helper cluster out of the included engine body and
into the owning UCI bridge.
```
