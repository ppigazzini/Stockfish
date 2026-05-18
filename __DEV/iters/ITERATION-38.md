# ITERATION-38

Date: `2026-05-18`
Status: complete

## Scope

- correct the Zig bitboard init arithmetic to match the C++ magic-generation
	semantics

## Constraints

- preserve the current validated runtime path while fixing the dormant Zig
	rewrite implementation

## Outcome

- updated `zig_build/board/bitboard_rewrites.zig` to use explicit wrapping
	multiplication in the Zig magic-generation PRNG and index math
- preserved the current validated C++ bitboard runtime path after the direct
	runtime wiring attempt proved unstable

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
fix: match zig bitboard magic arithmetic

Use explicit wrapping multiplication in the Zig bitboard rewrite so its
magic generation matches the original C++ overflow semantics exactly.
```
