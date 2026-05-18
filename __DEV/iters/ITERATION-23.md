# ITERATION-23

Date: `2026-05-18`
Status: complete

## Scope

- replace `src/syzygy/tbprobe.cpp` in the Zig build with a compatibility bridge
  that compiles the retained tablebase probing logic from the original source
  while moving small Syzygy helpers into Zig
- port the DTZ zeroing helper and table-code string construction used by
  `TBTables::add()` into Zig-owned helpers

## Constraints

- preserve Syzygy file discovery, table registration, and root probing behavior
  exactly
- keep the actual tablebase probing and decompression logic in retained C++ for
  this slice

## Outcome

- replaced `src/syzygy/tbprobe.cpp` in the Zig build with a compatibility
  bridge that compiles the retained tablebase probing logic from the original
  source while overriding the moved helper surface
- moved the DTZ zeroing helper and table-code string construction used by
  `TBTables::add()` into `zig_build/support/tbprobe_rewrites.zig`
- removed the final direct `src/` translation unit from `stockfish_sources`

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: rewrite syzygy helper routines in zig

Move small Syzygy helper routines into Zig while compiling the
remaining tablebase probing logic through the compatibility bridge.
```
