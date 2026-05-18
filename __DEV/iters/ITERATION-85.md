# ITERATION-85

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed `FullThreats` helper wrappers out of
  `zig_compat/nnue_accumulator_bridge.cpp`
- provide the same `make_index` and `requires_refresh` Zig-build wrapper
  surface through `src/nnue/features/full_threats.h`

## Constraints

- keep the existing Zig `zfish_full_threats_make_index` and
  `zfish_full_threats_requires_refresh` exports as the behavior source
- avoid changing the non-Zig C++ build path in
  `src/nnue/features/full_threats.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/nnue_accumulator_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only `FullThreats` helper declarations and inline wrapper
  bodies in `src/nnue/features/full_threats.h`
- moved the `FullThreats::make_index` and
  `FullThreats::requires_refresh` wrappers into the `ZFISH_ZIG_BUILD`
  path in the feature header
- removed the corresponding retained declarations and wrapper bodies from
  `zig_compat/nnue_accumulator_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig fullthreat wrappers

Move the Zig-build FullThreats wrapper methods out of
nnue_accumulator_bridge.cpp and let the Zig build use the existing
zfish_full_threats exports through full_threats.h.
```
