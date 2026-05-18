# ITERATION-76

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed UCI formatting and status wrapper bodies out of
  `zig_compat/uci_bridge.cpp`
- provide the same wrapper surface through `src/uci.h` only for the Zig build

## Constraints

- keep the existing Zig `zfish_uci_*` exports as the behavior source
- avoid changing the non-Zig C++ build path in `src/uci.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added a Zig-build-only `zfish_uci_*` wrapper path in `src/uci.h` for
  `print_info_string`, score formatting, score conversion, move formatting,
  lowercasing, and search-update output helpers
- removed the corresponding retained method bodies from
  `zig_compat/uci_bridge.cpp`
- deleted the now-unused local `overload` and `material_count` helpers from
  `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig uci format wrappers

Move the UCI formatting and status bridge wrappers out of uci_bridge.cpp
and let the Zig build use the existing zfish_uci exports through a
ZFISH_ZIG_BUILD header path.
```
