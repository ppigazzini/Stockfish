# ITERATION-43

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/tbprobe_bridge.cpp`
- move the retained Syzygy tablebase bridge definitions into
  `zig_compat/engine_bridge.cpp`

## Constraints

- preserve the existing Zig-backed Syzygy helper behavior
- keep the retained tablebase method ABI unchanged for the engine-owned
  tablebase lifecycle

## Outcome

- removed `zig_compat/tbprobe_bridge.cpp`
- moved the retained Syzygy tablebase bridge definitions into
  `zig_compat/engine_bridge.cpp`, which already owns the top-level tablebase
  lifecycle
- preserved the existing Zig-backed Syzygy helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline tbprobe bridge into engine

Move the retained Syzygy tablebase bridge definitions into the engine
bridge so the separate tbprobe bridge translation unit can be
removed.
```
