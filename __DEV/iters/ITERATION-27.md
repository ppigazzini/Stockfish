# ITERATION-27

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/benchmark_bridge.cpp`
- move its live wrapper logic into `zig_compat/uci_bridge.cpp`, which is the
  only compiled caller of the benchmark helpers

## Constraints

- preserve benchmark command parsing and string splitting behavior
- avoid widening scope beyond the existing UCI benchmark entrypoints

## Outcome

- removed `zig_compat/benchmark_bridge.cpp`
- moved the live benchmark wrapper logic into `zig_compat/uci_bridge.cpp`,
  which is the only compiled caller of the benchmark helper exports
- preserved the existing benchmark command parsing and string materialization
  behavior while eliminating a standalone bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline benchmark bridge into uci

Call the Zig benchmark helpers directly from the retained UCI bridge so
the separate benchmark bridge translation unit can be removed.
```
