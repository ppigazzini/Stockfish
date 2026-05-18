# ITERATION-26

Date: `2026-05-18`
Status: complete

## Scope

- remove `zig_compat/memory_bridge.cpp`
- export the required `Stockfish::memory` namespace symbols directly from Zig

## Constraints

- preserve the existing ABI used by the remaining C++ bridge files
- avoid changing allocation behavior or ownership semantics

## Outcome

- removed `zig_compat/memory_bridge.cpp`
- exported the required `Stockfish` memory namespace symbols directly from
	`zig_src/main.zig` using their current Itanium-mangled names
- kept the existing plain C allocation exports intact for the remaining
	bridge-owned call sites that already use them

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
port: remove memory bridge shim

Export the remaining Stockfish memory namespace symbols directly from
Zig so the temporary C++ memory bridge is no longer needed.
```
