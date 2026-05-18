# ITERATION-54

Date: `2026-05-18`
Status: complete

## Scope

- move the `PieceToChar` collision alias from `zig_compat/uci_bridge.cpp` to
  the real owner file `zig_compat/engine_bridge.cpp`
- keep the included engine body ownership unchanged while shrinking the outer
  include wrapper in `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing retained engine, tablebase, and position rendering
  behavior
- keep the `PieceToChar` collision handling local to the engine-owned tbprobe
  include

## Outcome

- moved the `PieceToChar` collision alias from `zig_compat/uci_bridge.cpp` into
  `zig_compat/engine_bridge.cpp`, where the tbprobe include actually needs it
- removed the outer alias management from `zig_compat/uci_bridge.cpp`
- preserved the existing retained engine, tablebase, and position rendering
  behavior while shrinking the outer include wrapper

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: localize tbprobe piece glyph alias

Move the PieceToChar collision alias into the engine bridge so the
outer UCI owner no longer needs to manage that include-time rename.
```
