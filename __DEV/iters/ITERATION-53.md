# ITERATION-53

Date: `2026-05-18`
Status: complete

## Scope

- rename the engine bridge's local string-transfer helper to a distinct name
- remove the include-time `take_string_and_free` macro alias from
  `zig_compat/uci_bridge.cpp`

## Constraints

- preserve the existing retained engine and UCI string-transfer behavior
- keep the included engine body ownership unchanged while shrinking the local
  collision surface

## Outcome

- renamed the engine bridge's local string-transfer helper to a distinct,
  engine-specific name
- removed the include-time `take_string_and_free` macro alias from
  `zig_compat/uci_bridge.cpp`
- preserved the existing retained engine and UCI string-transfer behavior while
  shrinking the local collision surface

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: isolate engine string helper name

Rename the engine bridge's local string helper so the UCI owner no
longer needs an include-time macro alias for that symbol.
```
