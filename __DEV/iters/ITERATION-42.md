# ITERATION-42

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/thread_bridge.cpp`
- move the retained thread and thread-pool bridge definitions into
  `zig_compat/search_bridge.cpp`

## Constraints

- preserve the existing Zig-backed thread helper behavior
- keep the thread and thread-pool method ABI unchanged for the retained search
  owner

## Outcome

- removed `zig_compat/thread_bridge.cpp`
- moved the retained thread and thread-pool bridge definitions into
  `zig_compat/search_bridge.cpp`, which already owns the search worker and
  manager flow
- preserved the existing Zig-backed thread helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline thread bridge into search

Move the retained thread and thread-pool bridge definitions into the
search bridge so the separate thread bridge translation unit can be
removed.
```
