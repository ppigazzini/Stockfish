# ITERATION-75

Date: `2026-05-19`
Status: complete

## Scope

- remove the retained Zig-backed misc wrapper bodies from
  `zig_compat/uci_bridge.cpp`
- provide the same wrapper surface through `src/misc.h` only for the Zig build

## Constraints

- keep the existing Zig `zfish_misc_*` exports as the behavior source
- avoid changing the non-Zig C++ build path in `src/misc.cpp`
- preserve parity while shrinking the retained owner code in
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Outcome

- added a Zig-build-only `ZFISH_ZIG_BUILD` macro in `build.zig`
- moved the `hash_bytes`, `str_to_size_t`, `read_file_to_string`,
  `remove_whitespace`, `is_whitespace`, and `CommandLine` misc wrappers into
  `src/misc.h` for Zig builds
- deleted the corresponding retained bodies and stale declarations from
  `zig_compat/uci_bridge.cpp`

## Validation

- `zig build parity -Dsignature-ref=2336177`
- result: `signature OK: 2336177`

## Planned Commit Message

```text
port: inline zig misc wrappers

Move the misc bridge wrappers out of uci_bridge.cpp and let the Zig
build consume the existing zfish_misc exports directly through a
Zig-build-only header path.
```# ITERATION-75

Date: `2026-05-19`
Status: active

## Scope

- extract the retained search, movegen, transposition-table, and thread owner
  block out of `zig_compat/uci_bridge.cpp`
- compile the extracted block as `zig_compat/search_bridge.cpp`

## Constraints

- preserve retained search, move ordering, TT, and thread behavior
- keep parity while continuing to reduce the owner code still held inside
  `zig_compat/uci_bridge.cpp`

## Planned Validation

- `zig build parity -Dsignature-ref=2336177`

## Planned Commit Message

```text
port: extract search bridge

Move the retained search, movegen, transposition-table, and thread
owner body out of the UCI bridge so the remaining UCI-facing surface can
be retired in smaller slices.
```
