# ITERATION-22

Date: `2026-05-18`
Status: complete

## Scope

- replace `src/search.cpp` in the Zig build with a compatibility bridge that
  compiles the retained search loop from the original source while moving pure
  search helpers into Zig
- port `to_corrected_static_eval`, `value_draw`, and
  `Search::Worker::reduction` to Zig-owned helpers

## Constraints

- preserve search behavior and bench signature exactly
- keep the main alpha-beta and quiescence loops in retained C++ for this slice

## Outcome

- replaced `src/search.cpp` in the Zig build with a compatibility bridge that
  compiles the retained search loop from the original source while overriding
  the moved helper surface
- moved `to_corrected_static_eval`, `value_draw`, and
  `Search::Worker::reduction` into `zig_build/support/search_rewrites.zig`

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: rewrite search helper formulas in zig

Move pure search score helpers and the late-move reduction formula
into Zig while compiling the remaining search logic through the
compatibility bridge.
```
