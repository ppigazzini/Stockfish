# ITERATION-21

Date: `2026-05-18`
Status: complete

## Scope

- replace `src/position.cpp` in the Zig build with a bridge that keeps the
  original move and attack logic in C++ while moving text and material-key
  helpers into Zig
- port `Position::fen()`, `Position::compute_material_key()`, and the
  endgame-code overload of `Position::set()` to Zig-owned helpers

## Constraints

- preserve FEN formatting, Chess960 castling notation, and endgame-code setup
  behavior exactly
- keep move execution, legality, attack generation, and repetition logic in the
  retained C++ body for now

## Outcome

- replaced `src/position.cpp` in the Zig build with a compatibility bridge that
  compiles the retained move and attack logic from the original source while
  overriding the moved helper surface
- moved `Position::fen()`, `Position::compute_material_key()`, and the
  endgame-code overload of `Position::set()` into `zig_build/board/position_rewrites.zig`

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: rewrite position text helpers in zig

Move Position FEN rendering, endgame-code setup, and material-key
rebuild helpers into Zig while compiling the remaining position logic
through the compatibility bridge.
```
