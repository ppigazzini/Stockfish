# ITERATION-70

Date: `2026-05-18`
Status: complete

## Scope

- move `Engine::wait_for_search_finished()` from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing wait-for-search behavior
- keep behavior unchanged while shrinking the remaining included engine owner
  body

## Outcome

- moved `Engine::wait_for_search_finished()` from
  `zig_compat/engine_bridge.cpp` into `zig_compat/uci_bridge.cpp`
- preserved the existing wait-for-search behavior
- removed another small engine method from the included owner body

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: move search wait helper into uci

Move Engine::wait_for_search_finished out of the included engine body
and into the owning UCI bridge.
```
