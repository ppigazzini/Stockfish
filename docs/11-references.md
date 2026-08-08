# References

Background for the rest of the set. Owns no source.

Links only. Anything a reader could learn from one of these does not belong in the rest of
this set -- see [12-writing.md](12-writing.md).

Audience: all developers.

## This project

- [Stockfish][stockfish] -- the repository.
  - [Wiki][sf-wiki] -- building, usage, UCI commands, terminology, for users.
  - [Regression tests][sf-regression] -- what a `Bench:` line means and how it is produced.
  - [Releases][sf-releases] -- the tagged commits and their bench numbers.
  - [Fishtest][fishtest] -- the distributed testing framework. A functional change lands
    with an SPRT result from here.
  - [Discord][sf-discord] | [Discussions][sf-discussions]

## Chess programming

- [Chess Programming Wiki][cpw] -- the domain reference.
  - [Bitboards][cpw-bb] | [Magic bitboards][cpw-magic] | [Hyperbola quintessence][cpw-hq] --
    the three slider implementations in [01-engine-board.md](01-engine-board.md).
  - [Perft results][cpw-perft] -- the counts `tests/perft.sh` asserts.
  - [Alpha-beta][cpw-ab] | [Quiescence search][cpw-qs] | [Iterative deepening][cpw-id]
  - [Late move reductions][cpw-lmr] | [Null-move pruning][cpw-null] |
    [Futility pruning][cpw-fut] | [Razoring][cpw-razor] | [ProbCut][cpw-probcut] |
    [Singular extensions][cpw-singular]
  - [Transposition table][cpw-tt] | [Zobrist hashing][cpw-zobrist] |
    [Static exchange evaluation][cpw-see]
  - [Lazy SMP][cpw-lazysmp] -- the threading model, [04-multithreading.md](04-multithreading.md).
  - [Chess960][cpw-960] -- the castling encoding `Move` carries.
- [UCI protocol specification][uci] -- the wire protocol `src/shell/uci.cpp` implements.
- [Cuckoo hashing for repetition detection][cuckoo] -- van Kervinck's algorithm,
  `Position::upcoming_repetition`.

### NNUE

- [NNUE architecture and training][nnue-doc] -- the canonical description of the feature
  sets, the quantisation and the accumulator.
- [nnue-pytorch][nnue-pytorch] -- the trainer the networks come from.
- [Leela Chess Zero training data][lc0-data] -- what the networks are trained on, under the
  [ODbL][odbl].

### Syzygy tablebases

- [Syzygy tablebases][syzygy] -- the format and the probing rules.
- [Tablebase generation and the fifty-move rule][cpw-fifty] -- why cursed wins and blessed
  losses exist.

## C++

The engine compiles at `-std=c++17`. The universal binary's two objects do not:
`nnue_embed.cpp` and `universal/entry_*.cpp` are built at `-std=c++20`, and the embed
object adds `-Wno-c++26-extensions` because `#embed` is a C++26 feature used as an
extension. Read the standard that matches the translation unit.

- [cppreference][cppref] -- the day-to-day lookup, with per-revision notes.
- [C++17 working draft, N4659][n4659] -- the standard the engine compiles at.
- [C++20 working draft, N4861][n4861] -- what the universal binary's objects compile at.
- [P1967, `#embed`][p1967] -- the proposal, adopted for C++26 and accepted by both compilers
  as an extension today. `__has_embed` is what `nnue_embed.cpp` tests before using it.
- [WG14 N3017, `#embed` in C23][n3017] -- where the directive was standardised first, which
  is why the compilers had it before C++ adopted it.
- [C++ Core Guidelines][core-guidelines] -- the reference for the conventions this codebase
  mostly follows; where it does not, the deviation is deliberate and the relevant page says
  so.
- [GCC C++ status][gcc-cxx] | [Clang C++ status][clang-cxx] -- which features each compiler
  in the matrix actually implements.
- [Compiler Explorer][godbolt] -- for checking what a change compiles to before measuring it.

### Build, Makefile and toolchain

Background for the build described in [10-tooling-ci.md](10-tooling-ci.md) and for any change
to `src/Makefile`.

- [GNU Make manual][gnu-make] -- the reference. `src/Makefile` uses conditional assignment,
  target-specific variables, a recursive sub-make for the universal binary, and
  `$(shell ...)` for the build stamp; all four are in here.
- [Makefile conventions][gnu-conventions] -- the GNU standard for target names and variable
  usage that `install`, `clean` and `strip` follow.
- [GCC optimize options][gcc-optimize] | [Clang command-line reference][clang-cli] -- what
  each flag in `CXXFLAGS` does.
- [GCC instrumentation options][gcc-instrument] -- `-fprofile-generate` and
  `-fprofile-use`, which `profile-build` drives.
- [Clang profile-guided optimization][clang-pgo] -- the same for the clang lane, including
  `llvm-profdata merge`.
- [Reproducible builds][repro-builds] -- why a build stamp makes two builds of one commit
  differ, which `tests/textequal.sh` has to neutralise.

## Type design

Background for [09-type-design.md](09-type-design.md).

- [Harper, *Practical Foundations for Programming Languages*][pfpl] -- a type is a set of
  values and membership is construction, which is the frame that page assumes.
- [Harper, "Boolean Blindness"][boolblind] -- *"There is no information carried by a Boolean
  beyond its value. To make use of one you have to know its provenance."* The argument for
  `NodeType` being an enum rather than two flags, and against the `cutNode` parameter beside
  it.
- [Kennedy, "Types for Units-of-Measure"][kennedy] -- unit polymorphism: a function generic
  in the unit it returns. That is the property a `Depth` type would need, and cannot have in
  C++, which is why `using Depth = int` is correct here.
- [Stroustrup, "Foundations of C++"][zero-overhead] -- the zero-overhead principle, carried
  as the claim that the measured cost rule qualifies rather than as one this codebase relies
  on.
- [Parent, "Better Code: Runtime Polymorphism"][parent] -- on inheritance versus value
  semantics, background for the `ISearchManager` null-object in `src/engine/search.h`.

## Codegen, LTO and measurement

Background for [10-tooling-ci.md](10-tooling-ci.md) and for any change measured with the
perf gates.

- [LLVM link-time optimization][llvm-lto] | [ThinLTO][thinlto] -- what LTO does across a
  translation-unit boundary and under what budget, which is why `tests/textequal.sh` must
  disable it to compare per-symbol.
- [LLVM auto-vectorization][llvm-vec] -- the loop and SLP vectorizers and the `-Rpass`
  remarks that report them.
- [GCC common function attributes][gcc-attr] | [Clang attribute reference][clang-attr] --
  what `always_inline`, `noinline` and `aligned` are and are not a request for.
- [Intel intrinsics guide][intel-intrinsics] -- the lookup for the per-ISA kernels in
  `src/engine/nnue/simd.h`.
- [Agner Fog's optimisation manuals][agner] -- instruction tables and microarchitecture.
- [What every programmer should know about memory][drepper] -- cache lines and data layout,
  the background for the 32-byte transposition cluster.
- [Callgrind manual][callgrind] -- the instrument `tests/perfbudget.sh` and
  `tests/fingerprint.sh` drive, including what it simulates and what it does not.
- [Valgrind manual][valgrind] | [Memcheck][memcheck] | [Helgrind][helgrind] -- the
  sanitizer lanes' instruments.
- [ThreadSanitizer][tsan] | [UndefinedBehaviorSanitizer][ubsan] -- what each lane in
  `sanitizers.yml` actually detects.
- [Transparent hugepages][thp] -- what `MADV_HUGEPAGE` requires, used by the transposition
  table allocation.

## Gates, lanes and testing

Background for the gates in [10-tooling-ci.md](10-tooling-ci.md).

- [GitHub Actions workflow syntax][gha-syntax] -- triggers, `workflow_call`, and job
  dependencies. A workflow that declares only `workflow_call` and that nothing calls cannot
  run, which is what `tests/lanecheck.sh` checks.
- [GitHub Actions: reusing workflows][gha-reuse] -- the `uses:` mechanism the umbrella
  workflow invokes each lane through.
- [Sequential probability ratio test][sprt] -- the statistical test fishtest runs. An SPRT
  result is what a functional change ships with.
- [Mutation testing][mutation-testing] -- the discipline `tests/negative_control.sh`
  implements: a gate is credited only when a deliberate defect makes it fail.
- [Metamorphic testing][metamorphic] -- the frame for the differential gates, which compare
  two builds rather than asserting an expected value.
- [Bash pitfalls][bash-pitfalls] -- the reference for the shell traps the gates hit:
  `set -o pipefail` interacting with `grep -q`, and `$?` after a pipeline reporting the last
  command's status.
- [ShellCheck][shellcheck] -- for anything added under `tests/`.

## Licensing

- [GNU GPL v3][gpl3] -- see [`../Copying.txt`](../Copying.txt) and
  [`../AUTHORS`](../AUTHORS).
- [ODbL][odbl] -- the licence on the network training data.

[agner]:            https://www.agner.org/optimize/
[bash-pitfalls]:    https://mywiki.wooledge.org/BashPitfalls
[callgrind]:        https://valgrind.org/docs/manual/cl-manual.html
[clang-attr]:       https://clang.llvm.org/docs/AttributeReference.html
[clang-cli]:        https://clang.llvm.org/docs/ClangCommandLineReference.html
[clang-cxx]:        https://clang.llvm.org/cxx_status.html
[clang-pgo]:        https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization
[core-guidelines]:  https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines
[cppref]:           https://en.cppreference.com/w/cpp
[cpw]:              https://www.chessprogramming.org/Main_Page
[cpw-960]:          https://www.chessprogramming.org/Chess960
[cpw-ab]:           https://www.chessprogramming.org/Alpha-Beta
[cpw-bb]:           https://www.chessprogramming.org/Bitboards
[cpw-fifty]:        https://www.chessprogramming.org/Fifty-move_Rule
[cpw-fut]:          https://www.chessprogramming.org/Futility_Pruning
[cpw-hq]:           https://www.chessprogramming.org/Hyperbola_Quintessence
[cpw-id]:           https://www.chessprogramming.org/Iterative_Deepening
[cpw-lazysmp]:      https://www.chessprogramming.org/Lazy_SMP
[cpw-lmr]:          https://www.chessprogramming.org/Late_Move_Reductions
[cpw-magic]:        https://www.chessprogramming.org/Magic_Bitboards
[cpw-null]:         https://www.chessprogramming.org/Null_Move_Pruning
[cpw-perft]:        https://www.chessprogramming.org/Perft_Results
[cpw-probcut]:      https://www.chessprogramming.org/ProbCut
[cpw-qs]:           https://www.chessprogramming.org/Quiescence_Search
[cpw-razor]:        https://www.chessprogramming.org/Razoring
[cpw-see]:          https://www.chessprogramming.org/Static_Exchange_Evaluation
[cpw-singular]:     https://www.chessprogramming.org/Singular_Extensions
[cpw-tt]:           https://www.chessprogramming.org/Transposition_Table
[cpw-zobrist]:      https://www.chessprogramming.org/Zobrist_Hashing
[cuckoo]:           https://web.archive.org/web/20201107002606/https://marcelk.net/2013-04-06/paper/upcoming-rep-v2.pdf
[drepper]:          https://www.akkadia.org/drepper/cpumemory.pdf
[fishtest]:         https://tests.stockfishchess.org/tests
[gcc-attr]:         https://gcc.gnu.org/onlinedocs/gcc/Common-Function-Attributes.html
[gcc-cxx]:          https://gcc.gnu.org/projects/cxx-status.html
[gcc-instrument]:   https://gcc.gnu.org/onlinedocs/gcc/Instrumentation-Options.html
[gcc-optimize]:     https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html
[gha-reuse]:        https://docs.github.com/en/actions/sharing-automations/reusing-workflows
[gha-syntax]:       https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
[gnu-conventions]:  https://www.gnu.org/prep/standards/html_node/Makefile-Conventions.html
[gnu-make]:         https://www.gnu.org/software/make/manual/make.html
[godbolt]:          https://godbolt.org/
[gpl3]:             https://www.gnu.org/licenses/gpl-3.0.html
[helgrind]:         https://valgrind.org/docs/manual/hg-manual.html
[intel-intrinsics]: https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html
[kennedy]:          https://doi.org/10.1007/978-3-642-17685-2_8
[lc0-data]:         https://storage.lczero.org/files/training_data
[llvm-lto]:         https://llvm.org/docs/LinkTimeOptimization.html
[llvm-vec]:         https://llvm.org/docs/Vectorizers.html
[memcheck]:         https://valgrind.org/docs/manual/mc-manual.html
[metamorphic]:      https://en.wikipedia.org/wiki/Metamorphic_testing
[mutation-testing]: https://en.wikipedia.org/wiki/Mutation_testing
[n4659]:            https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2017/n4659.pdf
[n4861]:            https://www.open-std.org/jtc1/sc22/wg21/docs/papers/2020/n4861.pdf
[p1967]:            https://wg21.link/p1967
[n3017]:            https://www.open-std.org/jtc1/sc22/wg14/www/docs/n3017.htm
[nnue-doc]:         https://github.com/official-stockfish/nnue-pytorch/blob/master/docs/nnue.md
[nnue-pytorch]:     https://github.com/official-stockfish/nnue-pytorch
[odbl]:             https://opendatacommons.org/licenses/odbl/odbl-10.txt
[parent]:           https://sean-parent.stlab.cc/papers-and-presentations/
[pfpl]:             https://www.cs.cmu.edu/~rwh/pfpl.html
[boolblind]:        https://existentialtype.wordpress.com/2011/03/15/boolean-blindness/
[repro-builds]:     https://reproducible-builds.org/docs/
[sf-discord]:       https://discord.gg/GWDRS3kU6R
[sf-discussions]:   https://github.com/official-stockfish/Stockfish/discussions
[sf-regression]:    https://github.com/official-stockfish/Stockfish/wiki/Regression-Tests
[sf-releases]:      https://github.com/official-stockfish/Stockfish/releases
[sf-wiki]:          https://github.com/official-stockfish/Stockfish/wiki
[shellcheck]:       https://www.shellcheck.net/
[sprt]:             https://en.wikipedia.org/wiki/Sequential_probability_ratio_test
[stockfish]:        https://github.com/official-stockfish/Stockfish
[syzygy]:           https://www.chessprogramming.org/Syzygy_Bases
[thinlto]:          https://clang.llvm.org/docs/ThinLTO.html
[thp]:              https://docs.kernel.org/admin-guide/mm/transhuge.html
[tsan]:             https://clang.llvm.org/docs/ThreadSanitizer.html
[ubsan]:            https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
[uci]:              https://backscattering.de/chess/uci/
[valgrind]:         https://valgrind.org/docs/manual/manual.html
[zero-overhead]:    https://www.stroustrup.com/ETAPS-corrected-draft.pdf
