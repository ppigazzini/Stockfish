# ITERATION-84

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed `HalfKAv2_hm` helper wrappers out of
  `zig_compat/nnue_accumulator_bridge.cpp`
- provide the same `make_index` and `requires_refresh` Zig-build wrapper
  surface through `src/nnue/features/half_ka_v2_hm.h`

## Constraints

- keep the existing Zig `zfish_half_ka_make_index` and
  `zfish_half_ka_requires_refresh` exports as the behavior source
- avoid changing the non-Zig C++ build path in
  `src/nnue/features/half_ka_v2_hm.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/nnue_accumulator_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only `HalfKAv2_hm` helper declarations and inline wrapper
  bodies in `src/nnue/features/half_ka_v2_hm.h`
- moved the `HalfKAv2_hm::make_index` and
  `HalfKAv2_hm::requires_refresh` wrappers into the `ZFISH_ZIG_BUILD`
  path in the feature header
- removed the corresponding retained declarations and wrapper bodies from
  `zig_compat/nnue_accumulator_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig halfka wrappers

Move the Zig-build HalfKAv2_hm wrapper methods out of
nnue_accumulator_bridge.cpp and let the Zig build use the existing
zfish_half_ka exports through half_ka_v2_hm.h.
```
