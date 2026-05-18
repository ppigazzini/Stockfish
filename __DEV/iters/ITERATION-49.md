# ITERATION-49

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/engine_bridge.cpp` from the compiled bridge list
- make `zig_compat/uci_bridge.cpp` the owner translation unit for the retained
  engine bridge body

## Constraints

- preserve the existing engine, network, tablebase, misc, and accumulator
  helper behavior
- keep the retained engine ABI unchanged while changing only its
  translation-unit owner

## Outcome

- removed `zig_compat/engine_bridge.cpp` from the compiled bridge list
- made `zig_compat/uci_bridge.cpp` the owner translation unit for the retained
  engine bridge body
- isolated the local helper-name collisions inside the included engine body with
  include-time macro renames
- preserved the existing engine, network, tablebase, misc, and accumulator
  helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline engine bridge into uci

Make the UCI bridge own the retained engine bridge body so the
separate engine bridge translation unit no longer needs to be
compiled.
```
