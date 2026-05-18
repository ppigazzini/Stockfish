# ITERATION-82

Date: `2026-05-19`
Status: complete

## Scope

- move the retained Zig-backed score classification constructor out of
  `zig_compat/uci_bridge.cpp`
- provide the same `Score::Score` Zig-build wrapper surface through
  `src/score.h`

## Constraints

- keep the existing Zig `zfish_classify_score` classification logic as the
  behavior source
- avoid changing the non-Zig C++ build path in `src/score.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added Zig-build-only score classification declarations and an inline
  `Score::Score` definition in `src/score.h`
- used the existing Zig `zfish_uci_to_cp` export directly from `src/score.h`
  with a local material-count helper so the constructor no longer depends on
  a retained bridge body
- removed the corresponding retained score classification declarations and
  constructor body from `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig score wrappers

Move the Zig-build Score::Score classification wrapper out of
uci_bridge.cpp and let the Zig build use the existing zfish score and UCI
exports through score.h.
```
