# ITERATION-15

Date: `2026-05-18`
Status: complete

## Outcome

- `src/movegen.cpp` is no longer compiled in the Zig build path
- the pseudo-legal move generation loops now live in
  `zig_build/board/movegen_rewrites.zig`
- `Position` snapshotting, bitboard helper lookups, and `generate<LEGAL>`
  filtering stay explicit in `zig_compat/movegen_bridge.cpp`

## Scope

- replace `src/movegen.cpp` in the Zig build with a Zig-owned pseudo-legal
  move generator
- keep `Position` snapshots, bitboard helper lookups, and
  `generate<LEGAL>` filtering explicit in the compatibility bridge

## Constraints

- preserve the current pseudo-legal move ordering, including promotion,
  castling, and en-passant emission order
- keep the bridge surface narrow and derived from live `Position` state instead
  of copying search-owned data structures

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- `zig build && cd src && printf 'position startpos\ngo perft 5\nquit\n' |
  ../zig-out/bin/stockfish`
- `zig build parity -Dsignature-ref=2336177`

Observed results:

- the focused perft check reported `Nodes searched: 4865609`
- the parity check completed with `signature OK: 2336177`

## Planned Commit Message

```text
port: rewrite move generation in zig

Move the pseudo-legal move generation loops into Zig while keeping
Position snapshots, bitboard helper lookups, and LEGAL filtering in the
compatibility bridge.
```
