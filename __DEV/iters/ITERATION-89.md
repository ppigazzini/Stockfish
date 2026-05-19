# ITERATION-89

Date: `2026-05-19`
Status: complete

## Scope

- retire the retained `ZfishUciRuntimeHandle` owner block in
  `zig_compat/uci_bridge.cpp`
- move the runtime-handle ownership and `argv` lifetime responsibility into
  `zig_src/main.zig`

## Constraints

- preserve the existing UCI startup flow: print engine info, initialize
  bitboards/position state, construct `UCIEngine`, run `Tune::init`, then enter
  `loop()`
- keep the raw `UCIEngine` lifecycle on the C++ side for now; this slice only
  removes the extra runtime-handle wrapper layer
- ensure the `argv` pointer array stays alive for the whole UCI loop
- hold parity at `2336177`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- replaced the Zig main `argv` array with a Zig-owned mutable pointer array that
  stays alive for the whole engine loop
- changed `zig_src/main.zig` to call raw engine lifecycle exports instead of
  the retained runtime-handle create/loop/destroy block
- removed `ZfishUciRuntimeHandle` and its duplicated `ownedArgv`/
  `mutableArgv` state from `zig_compat/uci_bridge.cpp`
- narrowed the remaining UCI runtime bridge surface to raw
  `zfish_uci_create_engine`, `zfish_uci_loop_engine`, and
  `zfish_uci_destroy_engine`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: retire uci runtime handle

Move the runtime argv/handle ownership into Zig main and reduce the
remaining UCI bridge runtime block to raw UCIEngine create/loop/destroy
exports.
```
