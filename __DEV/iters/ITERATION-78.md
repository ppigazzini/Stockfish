# ITERATION-78

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed UCI help and unknown-command formatting
  wrappers out of `zig_compat/uci_bridge.cpp`
- provide the same `help_text` and `format_unknown_command` wrapper surface
  through `src/uci.h` only for the Zig build

## Constraints

- keep the existing Zig `zfish_uci_help_text` and
  `zfish_uci_format_unknown_command` exports as the behavior source
- avoid changing the non-Zig C++ build path in `src/uci.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only `zfish_uci_help_text` and
  `zfish_uci_format_unknown_command` declarations in `src/uci.h`
- moved the `UCIEngine::help_text` and
  `UCIEngine::format_unknown_command` wrappers into the
  `ZFISH_ZIG_BUILD` path in `src/uci.h`
- updated `UCIEngine::loop()` to call the wrapper surface instead of the
  direct Zig exports and removed the stale retained declarations from
  `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig uci help wrappers

Move the UCI help_text and unknown-command formatting bridge wrappers out
of uci_bridge.cpp and let the Zig build use the existing zfish_uci helper
exports through the ZFISH_ZIG_BUILD header path.
```
