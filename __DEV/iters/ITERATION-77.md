# ITERATION-77

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed UCI command-parsing wrapper bodies out of
  `zig_compat/uci_bridge.cpp`
- provide the same `parse_limits` and `position` wrapper surface through
  `src/uci.h` only for the Zig build

## Constraints

- keep the existing Zig `zfish_uci_parse_limits` and
  `zfish_uci_parse_position` exports as the behavior source
- avoid changing the non-Zig C++ build path in `src/uci.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only `ZfishParsedLimits` and `ZfishParsedPosition`
  declarations in `src/uci.h`
- moved the `UCIEngine::parse_limits` and `UCIEngine::position` wrappers into
  the `ZFISH_ZIG_BUILD` path in `src/uci.h`
- removed the corresponding retained method bodies and stale declarations from
  `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig uci parse wrappers

Move the UCI parse_limits and position bridge wrappers out of
uci_bridge.cpp and let the Zig build use the existing zfish_uci parser
exports through the ZFISH_ZIG_BUILD header path.
```
