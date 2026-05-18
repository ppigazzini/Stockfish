# ITERATION-29

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/score_bridge.cpp`
- move the `Score::Score` constructor definition into `zig_compat/uci_bridge.cpp`

## Constraints

- preserve score classification semantics and the existing `UCIEngine::to_cp`
  dependency
- avoid changing the `Score` object layout or public API

## Outcome

- removed `zig_compat/score_bridge.cpp`
- moved the retained `Score::Score` constructor definition into
  `zig_compat/uci_bridge.cpp`, where its existing `UCIEngine::to_cp`
  dependency already lives
- preserved score classification and constructor behavior while eliminating
  another standalone bridge translation unit

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: inline score bridge into uci

Move the retained Score constructor into the UCI bridge so the separate
score bridge translation unit can be removed.
```
