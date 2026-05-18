# ITERATION-52

Date: `2026-05-18`
Status: complete

## Scope

- restore the canonical tracked `zig_compat/engine_bridge.cpp` and
  `zig_compat/search_bridge.cpp` filenames
- keep `zig_compat/uci_bridge.cpp` as the owner translation unit for those
  bodies

## Constraints

- preserve the existing retained engine and search behavior and included-body
  ownership
- eliminate the duplicate untracked bridge files without changing runtime
  behavior

## Outcome

- restored the canonical tracked `zig_compat/engine_bridge.cpp` and
  `zig_compat/search_bridge.cpp` filenames
- kept `zig_compat/uci_bridge.cpp` as the owner translation unit for those
  included bodies
- eliminated the duplicate untracked bridge files without changing runtime
  behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: restore tracked bridge filenames

Restore the tracked engine and search bridge filenames so the owner
translation unit still includes the same bodies without leaving
duplicate untracked bridge files in the worktree.
```
