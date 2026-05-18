# ITERATION-48

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/search_bridge.cpp` from the compiled bridge list
- make `zig_compat/uci_bridge.cpp` the owner translation unit for the retained
  search bridge body

## Constraints

- preserve the existing Zig-backed search, TT, thread, movegen, and timeman
  helper behavior
- keep the retained search ABI unchanged while changing only its
  translation-unit owner

## Outcome

- removed `zig_compat/search_bridge.cpp` from the compiled bridge list
- made `zig_compat/uci_bridge.cpp` the owner translation unit for the retained
  search bridge body
- preserved the existing Zig-backed search, TT, thread, movegen, and timeman
  helper behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline search bridge into uci

Make the UCI bridge own the retained search bridge body so the
separate search bridge translation unit no longer needs to be
compiled.
```
