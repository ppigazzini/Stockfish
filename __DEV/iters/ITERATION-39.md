# ITERATION-39

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/tt_bridge.cpp`
- move the retained transposition-table bridge definitions into
  `zig_compat/search_bridge.cpp`

## Constraints

- preserve the existing Zig-backed TT entry helpers and probe behavior
- keep the TT method ABI unchanged for the retained C++ owners

## Outcome

- removed `zig_compat/tt_bridge.cpp`
- moved the retained transposition-table bridge definitions into
  `zig_compat/search_bridge.cpp`, which already owns the primary TT consumers
- preserved the existing Zig-backed TT entry helpers and TT probe behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline tt bridge into search

Move the retained transposition-table bridge definitions into the
search bridge so the separate tt bridge translation unit can be
removed.
```
