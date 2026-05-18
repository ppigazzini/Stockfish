# ITERATION-81

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed tune helper wrappers and support state out of
  `zig_compat/uci_bridge.cpp`
- provide the same tune helper wrapper surface through `src/tune.h` only for
  the Zig build

## Constraints

- keep the existing Zig `zfish_tune_next` and
  `zfish_tune_should_make_option` exports as the behavior source
- avoid changing the non-Zig C++ build path in `src/tune.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only tune helper declarations, inline support state, and
  inline wrapper bodies in `src/tune.h`
- moved `Tune::make_option` and `Tune::next` into the `ZFISH_ZIG_BUILD`
  path in `src/tune.h`
- removed the corresponding retained tune helper declarations, support
  state, dead local utilities, and wrapper bodies from
  `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig tune wrappers

Move the tune bridge wrappers and their Zig-build support state out of
uci_bridge.cpp and let the Zig build use the existing zfish_tune exports
through the ZFISH_ZIG_BUILD header path.
```
