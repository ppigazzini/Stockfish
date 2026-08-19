# Idiomatic C++ here

Which spellings this tree commits to, which of them measured, and which were tried and did not
pay. Each sibling port carries the same page for its own language, at the same number, and
several of the shapes below crossed from one of them.

Audience: hot-path and build contributors.

A pattern without a command is a hunch, so each one here carries its detector. What the detector
finds is a candidate and nothing more; the measurement is [11-performance.md](11-performance.md)'s
and the rule the programme runs under is absolute:

> Every refactor must keep or improve performance. Even a very small regression is forbidden.

## C++17, pinned and probed

```sh
grep -n 'std=c++' src/Makefile
```

The engine is `-std=c++17` and nothing in `src/engine/`, `src/platform/` or `src/shell/` may
assume more. Two objects under `src/universal/` build at `-std=c++20` -- the runtime-dispatch
entry point and the NNUE embed -- and they are the only ones; a C++20 spelling anywhere else
compiles on the developer's box and fails the compile matrix.

**Exceptions are off, and the tree does not merely avoid them.**

```sh
grep -n 'fno-exceptions' src/Makefile
grep -rnE '\bthrow\b|\bcatch[[:space:]]*\(' src/ --include=*.cpp --include=*.h
```

`-fno-exceptions` is in `CXXFLAGS`, and the second command finds exactly one line: a comment in
`src/platform/shm_unix.h` recording that a throw there **is** `std::terminate`, taken before the
call it guards can return. So a failure is a return value, a status, or the fatal seam -- never a
`throw` -- and a standard-library call that would have thrown terminates the process instead.

That is the constraint to write against, and it is stronger than "we do not use exceptions": an
allocation that cannot be served does not unwind, so anything holding a resource across one must
not depend on a destructor running to release it.

RTTI is not disabled. `-fno-rtti` appears nowhere in the Makefile, so `dynamic_cast` and
`typeid` compile; nothing on a hot path should want them, but the build does not forbid them and
a reader should not claim it does.

## The warning set

```sh
grep -n 'Wall\|Wextra\|Wshadow\|Wcast-qual\|Wmissing' src/Makefile
```

`-Wall -Wcast-qual` is unconditional. `-pedantic -Wextra -Wshadow` and a missing-declaration
warning are added per compiler, which is why a build that is clean under one toolchain is not
evidence for another. Measure and compile under both the tree builds with; the same command run
twice with `--comp gcc` and `--comp clang` is the smallest honest sweep.

## Moving a body out of a header is not free

The single most expensive assumption available when restructuring this tree, and it is measured
rather than argued: [11-performance.md](11-performance.md) carries the figures and the grid that
produced them.

The rule that falls out of it:

> Move a template whose instantiations all live in one translation unit. Leave a non-template
> body in the header unless the measurement says otherwise.

A template must be visible where it is *instantiated*, not everywhere its class is named, so a
member template instantiated in one unit can move into that unit and the compiler sees the same
code in the same place. A non-template body cannot: moving it forces the compiler to emit it
where before it could inline it away, and under LTO the inliner's budget is global, so what comes
back different is not the moved code but whatever the inliner stopped doing elsewhere.

**Do not read for candidates by eye -- let the compiler name them.** A template instantiated in
one translation unit leaves a weak symbol in exactly one object file:

```sh
for o in *.o; do nm --defined-only -C "$o" \
  | awk -v o="$o" '$2=="W"||$2=="V"{$1="";$2="";print o"\t"substr($0,3)}'; done \
| awk -F'\t' '{c[$2]++; own[$2]=$1} END{for (k in c) if (c[k]==1) print own[k]"\t"k}'
```

`tests/textequal.sh` shows how to get LTO-free objects; `EXTRACXXFLAGS=-fno-lto` does not work,
because `src/Makefile` appends `-flto` after it.

A single definer makes a template a candidate and nothing more. Ask three questions before moving
one: is it on the per-node path, does an explicit instantiation pin argument types a future
caller would have to add to, and does anything but the file it already lives beside include the
header?

## The family that pays: the compiler was forbidden, not blind

Every pattern below has one shape. **The compiler did not miss the optimisation -- it was not
allowed to perform it, and the change removes the prohibition.** That is why these show on the
instruction axis under both compilers at every tier: they remove work, and work is the same on
every machine. A change that merely helps one compiler's layout is a different animal and shows
as a sign that flips between toolchains.

### An atomic forbids widening a bulk operation

`std::atomic<T>` stores may not be combined, so an array of them is filled one element at a time
however wide the target's stores are, forever.

```sh
grep -rn 'RelaxedAtomic\|std::atomic' src/engine/*.h
grep -rn '\.fill(\|clear_range\|memset' src/engine/ | grep -iE 'hist|stat|table'
```

**Confirm the prohibition before writing the patch**, because the fix is invasive and the
diagnosis is cheap: build once with the atomic dropped everywhere -- not shippable, only a probe
-- and see whether the cost disappears. If it does not, the atomic was not what cost.

`TranspositionTable::clear` is already a per-thread `std::memset` and is not a candidate:

```sh
grep -n 'memset' src/engine/tt.cpp
```

### An aliasing barrier the compiler cannot see through

Two pointers the compiler must assume overlap, so a store through one orders every load through
the other. `RESTRICT` is spelled in `src/engine/compiler.h` and is a **macro, not a keyword**, so
a file that writes it must include that header itself -- inheriting it through another header
compiles until that header stops including it, and then fails with `RESTRICT` read as an
identifier. The header says so at the definition.

```sh
grep -rn '\bRESTRICT\b' src/ --include=*.h --include=*.cpp | grep -v 'define RESTRICT'
```

**The lever is real and it is narrow.** It pays only where a reload actually happens; a value the
compiler already holds in a register has no barrier to remove, and annotating it changes nothing
while reading as though it did. Check the disassembly for the reload before writing `RESTRICT`.

### A short loop the vectoriser turns into a gather

A gather on a per-node path can cost more than the scalar loop it replaced.

```sh
objdump -d src/stockfish | awk '/^[0-9a-f]+ </{s=$2} /vpgather/{c[s]++} END{for(k in c) print c[k], k}'
```

This one is **tier- and compiler-specific**, which is why it sits outside the family rather than
in it: a gather emitted at one vector width under one compiler is absent at another. Quote the
tier and the compiler with any result, and expect the fix to be a barrier against vectorising
rather than a change to the arithmetic.

### An index whose type forces a sign extension per use

An `int` index into an array on a 64-bit target needs a sign extension at every use that an
unsigned or a `usize` does not.

```sh
objdump -d --demangle --no-show-raw-insn src/stockfish | awk '
  /^[0-9a-f]+ </{s=substr($0,index($0,"<"))} /\t(movslq|cltq|movsbl|movswl)/{c[s]++}
  END{for(k in c) if(c[k]>=8) print c[k], k}' | sort -rn
```

**The census is a candidate list, not a work list**, and [09-type-design.md](09-type-design.md)
is why: a type is free while a value is CARRIED and costs when many are live at once in one large
function, because that is a register-allocation problem. The functions at the top of that census
are exactly the large ones. Widening an index there removes a sign extension per use and adds a
64-bit value to a register file already at its limit. It needs the measurement, not the argument.

### Zeroing that a later full write makes dead

A buffer value-initialised and then fully overwritten before any read. The compiler cannot elide
the zeroing when the write happens across an allocation or an I/O boundary it cannot see through.

```sh
cd src && valgrind --tool=callgrind --callgrind-out-file=cg --separate-callers=2 \
  ./stockfish bench 16 1 8
```

Read the `memset` and `memcpy` totals per caller. On a target where `erms` retires about one
instruction per byte those figures read directly as volume, and the calibration is free: set the
bench hash to a known size and check that the transposition-table clear's figure is that size
times the number of clears.

**The warning on this one is sharp.** Deleting an initialisation because a later write is
believed to cover it is a bet, and the failure is a read of uninitialised memory that produces a
plausible answer rather than a crash. Establish that the write covers every byte on **every**
path -- including the error path and the short-read path -- or leave it.

**And check where it would show.** Most of this cost is startup, which `perfbudget.sh` subtracts
before computing its verdict, so a real win here reports as nothing on that gate. The exception
is work that runs after the startup probe stops counting.

### A runtime parameter that is a literal at every call site

The strongest of the family, because the tell is not in the code at all.

> **If the function is still a real symbol in the profile, it was not inlined -- so the constant
> never reached it, however obviously literal every call site looks.**

That inverts the intuition: reading the call sites suggests the compiler must fold the argument,
and the symbol surviving in the profile proves it did not.

```sh
callgrind_annotate --threshold=95 cg.out     # 1. the callee is a real symbol
grep -rn '<the function>' src/engine/        # 2. every call site passes a literal
```

Step three is what separates a win from a rounding error: **the parameter must be read inside a
loop, not once at the top.** Folding a parameter used once at the top of a function saves one
address computation and duplicates the whole body to do it.

`Worker::search(..., const bool cutNode)` is the position this pattern points at and the one to
leave alone without an instruction-cache measurement. [09-type-design.md](09-type-design.md)
states why a template argument occupies no register, which is what makes `NodeType` free on the
hottest function in the engine -- and templating a second flag there doubles the instantiations
of the largest function in the tree. `tests/perfcounters.sh` is the instrument for that, not
`perfbudget.sh`.

## The test to apply before writing any of them

Changes on this tree have removed a real cost from the function they targeted and made the whole
program worse. What separates those from the ones that landed is not the size of the cost
removed:

> **If the change still does work per item, the work it adds on every item must be smaller than
> the work it removes on the few. If the change DELETES the per-item work, it wins.**

A change that keeps the loop and pays per iteration to improve it is the shape that loses. A
change that deletes the loop, or deletes the per-element store, is the shape that wins.

**A correct attribution is not a licence.** Each of the losing changes was aimed by a correct
profile at a real cost in a real function, removed that cost, and cost the program more
elsewhere. The profile says where the work is; it does not say that removing it is free.

## What a measurement here has to survive

One `-O3` lane is not evidence. A reading that changes sign or vanishes when the compiler or the
tier changes is not an instruction-count change at all, and `make profile-build` is what ships.
[11-performance.md](11-performance.md) owns the grid, which lane binds, and what each axis cannot
see.

## The gates

| gate | what it proves here | owned by |
|---|---|---|
| `tests/textequal.sh` | a spelling change emitted the same instructions, which is the only proof of pure code motion that has no noise floor | [11-performance.md](11-performance.md) |
| `tests/perfbudget.sh` | a spelling that claims to cost nothing retires no more instructions | [11-performance.md](11-performance.md) |
| `tests/perfcounters.sh` | a spelling whose claim is locality or instruction-cache pressure, which the instruction axis reports with the wrong sign | [11-performance.md](11-performance.md) |
| `tests/iwyu.sh` | a header moved or split still carries the includes its own uses need, at every tier | [00-architecture.md](00-architecture.md) |
| `tests/negative_control.sh` | a type introduced so that a wrong spelling stops compiling actually refuses it | [10-tooling-ci.md](10-tooling-ci.md) |
