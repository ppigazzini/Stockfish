# ITERATION-41

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/network_bridge.cpp`
- move the retained NNUE network bridge definitions into
  `zig_compat/engine_bridge.cpp`

## Constraints

- preserve the existing Zig-backed network helper exports and network file
  behavior
- keep the `Network` method ABI and embedded-net behavior unchanged for the
  retained engine owner

## Outcome

- removed `zig_compat/network_bridge.cpp`
- moved the retained NNUE network bridge definitions into
  `zig_compat/engine_bridge.cpp`, which already owns the network lifecycle
- preserved the existing Zig-backed network helper exports and embedded-net
  behavior

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline network bridge into engine

Move the retained NNUE network bridge definitions into the engine
bridge so the separate network bridge translation unit can be
removed.
```
