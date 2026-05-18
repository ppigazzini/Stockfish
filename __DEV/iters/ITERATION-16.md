# ITERATION-16

Date: `2026-05-18`
Status: complete

## Outcome

- `src/nnue/network.cpp` is no longer compiled in the Zig build path
- the public NNUE network load, save, verify, evaluate, and trace control flow
  now lives in `zig_build/eval/network_rewrites.zig`
- stream serialization, embedded-net loading, and per-bucket
  `FeatureTransformer` or `NetworkArchitecture` calls remain explicit in
  `zig_compat/network_bridge.cpp`

## Scope

- replace `src/nnue/network.cpp` in the Zig build with Zig-owned public NNUE
  network control flow
- keep stream serialization, embedded-net loading, and per-bucket
  `FeatureTransformer` or `NetworkArchitecture` calls explicit in the
  compatibility bridge

## Constraints

- preserve the current external-net behavior under the Linux `x86_64` Zig path
- keep the network verification message and bucket evaluation outputs aligned
  with the current bench and UCI surfaces

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- `zig build parity -Dsignature-ref=2336177`

Observed result:

- the parity check completed with `signature OK: 2336177`

## Planned Commit Message

```text
port: rewrite nnue network control in zig

Move the public NNUE network control flow into Zig while keeping
stream serialization, embedded-net loading, and per-bucket transformer
calls in the compatibility bridge.
```
