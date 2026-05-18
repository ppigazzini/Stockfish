# ITERATION-51

Date: `2026-05-18`
Status: complete

## Scope

- rename the now-included retained engine bridge body to a non-compiled include
  file
- keep `zig_compat/uci_bridge.cpp` as the owner translation unit for that body

## Constraints

- preserve the existing retained engine behavior and included-body ownership
- keep the build output unchanged aside from the file-path cleanup

## Outcome

- renamed the now-included retained engine bridge body to
  `zig_compat/engine_bridge_body.inc`
- kept `zig_compat/uci_bridge.cpp` as the owner translation unit for that body
- preserved the existing retained engine behavior and included-body ownership

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: rename engine bridge body include

Rename the now-included engine bridge body to a non-compiled include
file so the remaining owner structure is explicit.
```
