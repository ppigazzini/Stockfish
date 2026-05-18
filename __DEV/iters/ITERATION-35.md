# ITERATION-35

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/evaluate_bridge.cpp`
- move `Eval::evaluate()` into `zig_compat/search_bridge.cpp`
- move `Eval::trace()` into `zig_compat/engine_bridge.cpp`

## Constraints

- preserve evaluation math and trace formatting behavior exactly
- keep the split aligned with the retained owners that actually call these
  entrypoints

## Outcome

- removed `zig_compat/evaluate_bridge.cpp`
- moved `Eval::evaluate()` into `zig_compat/search_bridge.cpp`, which owns the
  live evaluation call in the retained search path
- moved `Eval::trace()` into `zig_compat/engine_bridge.cpp`, which owns the
  live evaluation-trace path
- preserved evaluation and trace behavior while eliminating another standalone
  bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: split evaluate bridge across owners

Move Eval::evaluate into the search bridge and Eval::trace into the
engine bridge so the standalone evaluate bridge translation unit can
be removed.
```
