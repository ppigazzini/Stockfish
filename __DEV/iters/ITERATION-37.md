# ITERATION-37

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/movegen_bridge.cpp`
- move the retained move-generation bridge definitions into
  `zig_compat/search_bridge.cpp`

## Constraints

- preserve Zig-backed capture, quiet, evasion, and legal move generation
- avoid widening scope beyond the retained owner that already depends on move
  generation directly

## Outcome

- removed `zig_compat/movegen_bridge.cpp`
- moved the retained move-generation bridge definitions into
  `zig_compat/search_bridge.cpp`, which already owns the live search path
- preserved Zig-backed move generation while eliminating another standalone
  bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline movegen bridge into search

Move the retained move-generation bridge definitions into the search
bridge so the separate movegen bridge translation unit can be removed.
```
