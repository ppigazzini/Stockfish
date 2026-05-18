# ITERATION-56

Date: `2026-05-18`
Status: complete

## Scope

- inline the retained search bridge body into `zig_compat/uci_bridge.cpp`
- remove `zig_compat/search_bridge.cpp`

## Constraints

- preserve the existing retained search, TT, movegen, timeman, and thread
  behavior
- keep `zig_compat/uci_bridge.cpp` as the owner file for the inlined body

## Outcome

- inlined the retained search bridge body into `zig_compat/uci_bridge.cpp`
- removed `zig_compat/search_bridge.cpp`
- repaired the missing namespace close introduced during the physical inline

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline search body into uci

Inline the retained search bridge body into the UCI bridge so the
separate search body file is no longer needed.
```
