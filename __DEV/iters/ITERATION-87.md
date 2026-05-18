# ITERATION-87

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed `FullThreats::append_changed_indices` wrapper
  out of `zig_compat/nnue_accumulator_bridge.cpp`
- provide the same Zig-build wrapper surface through
  `src/nnue/features/full_threats.h`

## Constraints

- keep the existing Zig `zfish_full_threats_append_changed` export as the
  behavior source for changed-index computation
- preserve the C++ caller's add/remove routing and prefetch behavior while
  moving the index generation itself into Zig
- avoid changing the non-Zig C++ build path in
  `src/nnue/features/full_threats.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/nnue_accumulator_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added a Zig-build-only `zfish_full_threats_append_changed` declaration and
  result structs in `src/nnue/features/full_threats.h`
- moved `FullThreats::append_changed_indices` into the `ZFISH_ZIG_BUILD`
  path in the feature header while preserving the caller-side prefetching and
  `push_back_if_lt` filtering
- adjusted the Zig `fullAppendChanged` helper to return one computed index per
  dirty threat so the C++ wrapper can preserve the original routing logic
- removed the corresponding retained wrapper body from
  `zig_compat/nnue_accumulator_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig fullthreat append wrapper

Move the Zig-build FullThreats append_changed_indices wrapper out of
nnue_accumulator_bridge.cpp and let the Zig build use the existing
zfish_full_threats_append_changed export through full_threats.h.
```
