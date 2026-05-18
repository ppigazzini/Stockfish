# ITERATION-74

Date: `2026-05-19`
Status: complete

## Scope

- extract the retained NNUE accumulator owner block out of
  `zig_compat/uci_bridge.cpp`
- compile the extracted block as `zig_compat/nnue_accumulator_bridge.cpp`

## Constraints

- preserve the current retained NNUE accumulator and feature-update behavior
- keep parity while reducing the amount of owner code still living in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- moved the retained NNUE accumulator owner body out of
  `zig_compat/uci_bridge.cpp`
- compiled the moved body as `zig_compat/nnue_accumulator_bridge.cpp`
- kept `zig_compat/uci_bridge.cpp` building with the remaining retained owners

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: extract nnue accumulator bridge

Move the retained NNUE accumulator owner body out of the UCI bridge so
the final UCI bridge retirement can continue in bounded parity-gated
slices.
```
