# ITERATION-32

Date: `2026-05-18`
Status: complete

## Scope

- commit the remaining unstaged `zig_src/main.zig` export-name cleanup

## Constraints

- preserve the existing mangled symbol ABI for the Zig-owned memory exports
- avoid changing runtime behavior beyond declaration syntax normalization

## Outcome

- kept the existing `Stockfish`-mangled memory export symbols in
  `zig_src/main.zig`
- normalized those Zig export declarations from quoted identifiers to bare
  identifiers without changing the exported symbol names

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
style: normalize zig mangled export names

Use bare Zig identifiers for the existing Stockfish-mangled memory
exports in main.zig without changing the exported ABI.
```
