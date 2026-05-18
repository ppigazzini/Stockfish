# ITERATION-86

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed `HalfKAv2_hm::append_changed_indices` wrapper
  out of `zig_compat/nnue_accumulator_bridge.cpp`
- provide the same Zig-build wrapper surface through
  `src/nnue/features/half_ka_v2_hm.h`

## Constraints

- keep the existing Zig `zfish_half_ka_append_changed` export as the behavior
  source for the changed-index computation
- avoid changing the non-Zig C++ build path in
  `src/nnue/features/half_ka_v2_hm.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/nnue_accumulator_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added a Zig-build-only `zfish_half_ka_append_changed` declaration and result
  struct in `src/nnue/features/half_ka_v2_hm.h`
- moved `HalfKAv2_hm::append_changed_indices` into the `ZFISH_ZIG_BUILD`
  path in the feature header while preserving the removed/added ordering used
  by the C++ caller
- removed the corresponding retained wrapper body from
  `zig_compat/nnue_accumulator_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig halfka append wrapper

Move the Zig-build HalfKAv2_hm append_changed_indices wrapper out of
nnue_accumulator_bridge.cpp and let the Zig build use the existing
zfish_half_ka_append_changed export through half_ka_v2_hm.h.
```
