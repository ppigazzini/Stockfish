# ITERATION-80

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed UCI option helper wrappers out of
  `zig_compat/uci_bridge.cpp`
- provide the same option helper wrapper surface through `src/ucioption.h`
  only for the Zig build

## Constraints

- keep the existing Zig `zfish_option_*` exports as the behavior source
- avoid changing the non-Zig C++ build path in `src/ucioption.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only option helper declarations and inline wrapper bodies
  in `src/ucioption.h`
- moved the `CaseInsensitiveLess::operator()`, `OptionsMap::setoption`,
  `Option::operator==`, and `Option::operator=` wrappers into the
  `ZFISH_ZIG_BUILD` path in `src/ucioption.h`
- removed the corresponding retained declarations, duplicate helper result
  structs, and wrapper bodies from `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig option wrappers

Move the UCI option bridge wrappers out of uci_bridge.cpp and let the
Zig build use the existing zfish_option exports through the
ZFISH_ZIG_BUILD header path.
```
