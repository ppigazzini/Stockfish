# ITERATION-45

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/bitboard_bridge.cpp`
- move the retained bitboard bridge definitions into
  `zig_compat/position_bridge.cpp`

## Constraints

- preserve the existing Zig-backed bitboard helper behavior
- keep the retained bitboard method ABI unchanged for the position-owned
  runtime initialization path

## Outcome

- removed `zig_compat/bitboard_bridge.cpp`
- moved the retained bitboard bridge definitions into
  `zig_compat/position_bridge.cpp`, which already sits on the position runtime
  initialization path
- preserved the existing Zig-backed bitboard helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline bitboard bridge into position

Move the retained bitboard bridge definitions into the position bridge
so the separate bitboard bridge translation unit can be removed.
```
