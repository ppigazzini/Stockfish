# ITERATION-46

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/position_bridge.cpp`
- move the retained position bridge definitions into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing Zig-backed position and bitboard helper behavior
- keep the retained position method ABI unchanged for the UCI-owned position
  control surface

## Outcome

- removed `zig_compat/position_bridge.cpp`
- moved the retained position bridge definitions into `zig_compat/uci_bridge.cpp`,
  which already owns the UCI-side position control flow and FEN handling
- preserved the existing Zig-backed position and bitboard helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline position bridge into uci

Move the retained position bridge definitions into the UCI bridge so
the separate position bridge translation unit can be removed.
```
