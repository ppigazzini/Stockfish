# ITERATION-34

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/movepick_bridge.cpp`
- move the retained `MovePicker` definitions into `zig_compat/search_bridge.cpp`

## Constraints

- preserve move ordering, staging, and Zig-backed scoring behavior exactly
- avoid widening scope beyond the retained search owner that uses `MovePicker`

## Outcome

- removed `zig_compat/movepick_bridge.cpp`
- moved the retained `MovePicker` definitions into
	`zig_compat/search_bridge.cpp`, which already owns the live search path
- preserved move staging, ordering, and Zig-backed scoring behavior while
	eliminating another standalone bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline movepick bridge into search

Move the retained MovePicker definitions into the search bridge so
the separate movepick bridge translation unit can be removed.
```
