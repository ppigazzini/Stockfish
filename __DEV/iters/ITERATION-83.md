# ITERATION-83

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed NNUE accumulator evaluate wrapper out of
  `zig_compat/nnue_accumulator_bridge.cpp`
- provide the same `AccumulatorStack::evaluate` Zig-build wrapper surface
  through `src/nnue/nnue_accumulator.h`

## Constraints

- keep the existing Zig `zfish_accumulator_evaluate` export as the behavior
  source
- avoid changing the non-Zig C++ build path in
  `src/nnue/nnue_accumulator.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/nnue_accumulator_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added a Zig-build-only `zfish_accumulator_evaluate` declaration and inline
  `AccumulatorStack::evaluate` definition in
  `src/nnue/nnue_accumulator.h`
- removed the corresponding retained wrapper body from
  `zig_compat/nnue_accumulator_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig accumulator evaluate wrapper

Move the Zig-build AccumulatorStack::evaluate wrapper out of
nnue_accumulator_bridge.cpp and let the Zig build use the existing
zfish_accumulator_evaluate export through nnue_accumulator.h.
```
