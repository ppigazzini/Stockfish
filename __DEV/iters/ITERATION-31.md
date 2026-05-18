# ITERATION-31

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/timeman_bridge.cpp`
- move the retained `TimeManagement` method definitions into
  `zig_compat/search_bridge.cpp`

## Constraints

- preserve time-management marshaling into the Zig helper exactly
- avoid widening scope beyond the retained search owner that calls these methods

## Outcome

- removed `zig_compat/timeman_bridge.cpp`
- moved the retained `TimeManagement` method definitions into
  `zig_compat/search_bridge.cpp`, which is the live owner that calls them
- preserved the existing Zig-backed time-management marshaling while
  eliminating another standalone bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline timeman bridge into search

Move the retained TimeManagement method definitions into the search
bridge so the separate timeman bridge translation unit can be removed.
```
