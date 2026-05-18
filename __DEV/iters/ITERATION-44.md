# ITERATION-44

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/misc_bridge.cpp`
- move the retained misc bridge definitions into `zig_compat/engine_bridge.cpp`

## Constraints

- preserve the existing Zig-backed misc helper behavior
- keep the retained misc method ABI unchanged for the engine-owned runtime
  surface

## Outcome

- removed `zig_compat/misc_bridge.cpp`
- moved the retained misc bridge definitions into `zig_compat/engine_bridge.cpp`,
  which already owns the top-level runtime surface and command-line helpers
- preserved the existing Zig-backed misc helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline misc bridge into engine

Move the retained misc bridge definitions into the engine bridge so
the separate misc bridge translation unit can be removed.
```
