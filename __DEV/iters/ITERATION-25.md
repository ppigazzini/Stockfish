# ITERATION-25

Date: `2026-05-18`
Status: complete

## Scope

- replace `zig_compat/main_bridge.cpp` with Zig-owned process startup in
  `zig_src/main.zig`
- keep `Bitboards`, `Position`, `UCIEngine`, and `Tune` on their current owners
  while exposing the narrow C ABI needed for Zig startup sequencing

## Constraints

- preserve startup order and user-visible banner output exactly
- avoid widening scope into UCI command handling or board initialization logic

## Outcome

- removed `zig_compat/main_bridge.cpp` from `build.zig`
- moved process startup sequencing into `zig_src/main.zig`
- added narrow startup helper exports on existing `misc`, `bitboard`,
  `position`, and `uci` bridge owners so Zig can print the banner,
  initialize board state, construct the UCI runtime, register tuning
  options, and enter the command loop without a dedicated C++ entrypoint

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: rewrite startup entry in zig

Move process startup sequencing into Zig while keeping UCI engine,
board initialization, and tune registration on their current owners
behind a narrow compatibility ABI.
```
