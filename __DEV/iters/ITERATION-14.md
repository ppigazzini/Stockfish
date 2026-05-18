# Iteration 14: NNUE Feature Index Slice

Date: `2026-05-18`
Status: complete

## Outcome

- `src/nnue/features/half_ka_v2_hm.cpp` and
  `src/nnue/features/full_threats.cpp` are no longer compiled in the Zig build
  path
- the NNUE feature lookup tables, index math, and refresh predicates now live
  in `zig_build/eval/nnue_feature_rewrites.zig`
- the live `Position` traversal, `DirtyThreats` iteration, and prefetch behavior
  remain explicit in `zig_compat/nnue_features_bridge.cpp`

## Request

- continue the bounded C++-to-Zig migration until the Zig path passes 80 percent
  of imported translation units
- keep each ownership move in a separate slice with a local iteration note and
  a separate commit

## Scope

- replace `src/nnue/features/half_ka_v2_hm.cpp` and
  `src/nnue/features/full_threats.cpp` in the Zig build
- move the feature lookup tables, index math, and refresh predicates into a
  Zig rewrite module under `zig_build/eval/`
- keep the live `Position` traversal, `DirtyThreats` iteration, and prefetch
  behavior explicit in a `zig_compat` bridge

## Constraints

- keep Linux `x86_64` as the only owned runtime target
- preserve current NNUE feature indexing and parity behavior
- keep the bridge explicit about the retained `Position` and threat-list
  dependencies

## Hypothesis

If the NNUE feature lookup tables and index math move into Zig while the bridge
keeps the `Position` and `DirtyThreats` traversal explicit, then both feature
translation units can leave the Zig compile list without changing the current
Linux `x86_64` parity gates.

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- `zig build parity -Dsignature-ref=2336177`

Observed result:

- the parity check completed with `signature OK: 2336177`

## Planned Commit

```text
port: rewrite nnue features in zig

Move the NNUE feature lookup tables and index math out of
src/nnue/features/half_ka_v2_hm.cpp and src/nnue/features/full_threats.cpp
into a zig_build rewrite module. Keep the Position and DirtyThreats
bridge explicit in zig_compat and revalidate the Linux x86_64 parity
gates.
```
