# ITERATION-36

Date: `2026-05-18`
Status: complete

## Scope

- remove the dead `zig_compat/main_bridge.cpp` source file

## Constraints

- preserve the current Zig-owned startup path
- avoid changing any live compiled bridge or runtime behavior

## Outcome

- removed the obsolete `zig_compat/main_bridge.cpp` source file
- confirmed that the old `zfish_main_run` entrypoint is no longer referenced
	anywhere in the live tree
- preserved the current Zig-owned startup path while deleting dead C++ source

## Validation

- `zig build parity -Dsignature-ref=2336177`

## Verification

- parity passed with `signature OK: 2336177`

## Commit Message

```text
cleanup: drop dead startup bridge source

Remove the obsolete main bridge source now that startup sequencing is
owned by Zig and the old zfish_main_run entrypoint is no longer used.
```
