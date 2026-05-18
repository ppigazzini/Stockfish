# ITERATION-30

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/tune_bridge.cpp`
- move the retained `Tune` static definitions and option-hook glue into
  `zig_compat/uci_bridge.cpp`

## Constraints

- preserve tune option registration and deferred readback behavior
- avoid changing `Tune` APIs or the macro-based tuning surface

## Outcome

- removed `zig_compat/tune_bridge.cpp`
- moved the retained `Tune` static definitions, option registration glue, and
  template specializations into `zig_compat/uci_bridge.cpp`
- preserved the existing tuning surface while eliminating another standalone
  bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline tune bridge into uci

Move the retained Tune support definitions into the UCI bridge so the
separate tune bridge translation unit can be removed.
```
