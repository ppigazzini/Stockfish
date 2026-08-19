# Technical writing

Every sentence written about this engine -- in a page, in a code comment, in a commit
message -- is a **claim with a shelf life**: true when written, checkable, and standing over
code that will move under it. Write the claim that survives, and write it so it fails loudly
when it stops being true.

Audience: anyone writing prose about this code.

## A claim, and what it costs to get wrong

Three sentences about the same line:

```
1.  The penalty decrements the stored depth.
2.  TTWriter::penalize decrements depth8, clamped at zero.
3.  TTWriter::penalize decrements depth8, clamped at zero. depth8 is a u8
    holding d - DEPTH_NONE, and bool(depth8) IS the occupancy test, so letting
    it reach zero retires a live entry and letting it wrap makes a penalised
    shallow entry the deepest in the table.
```

The first is accurate and useless. The second is accurate and looks like a nicety someone can
simplify away -- `std::max(..., 0)` reads as defensive programming until you know what zero
means. Only the third stops the next reader removing the clamp.

**Write the sentence someone needs before they change your line**, not the sentence that
describes what it currently does.

## Name the owner, the invariant, and the failure

A claim is complete when it says **which symbol** owns the behaviour, **what must stay true**,
and **what breaks otherwise**. Two of the three is where the defects live.

| incomplete | complete |
|---|---|
| "the cluster is 32 bytes" | "`sizeof(Cluster) == 32` is asserted so a cluster divides a cache line: probing one position must touch one line" |
| "the states are in a deque" | "`StateListPtr` is a `deque` because the search holds pointers into it and a `vector` would invalidate them on resize" |
| "evaluation is clamped" | "the evaluation is clamped strictly inside the tablebase band, so an estimate can never be read as a proven verdict" |

Of the three, the failure clause is the one that turns a description into a reason not to
break something.

## Verify, do not recall

**Run it.** Not "read it carefully" -- `grep -c`, a `bench`, a `printf | ./stockfish`, an
`awk` over the file. A claim that takes seconds to check and was not checked is the claim that
turns out false.

The claims that survive review and fail verification are always the same shapes:

- **a list with the wrong count** -- an enum with five members written as four;
- **a real symbol under a wrong name** -- `TBCursedWin` for `WDLCursedWin`;
- **a case list that omits a case** -- `legal()` described without castling;
- **a paraphrase that inverts a condition** -- "an own-king move forces a refresh only across a
  bucket boundary", when `HalfKAv2_hm::requires_refresh` tests `diff.pc == make_piece(perspective,
  KING)` and every one of them does.

Three of the four are catchable only by opening the file. **The wrong count is the exception,
and only where a gate owns the list**: `docslint.sh` check 7 reads the CI table's gate column and
compares it, pair by pair, against what the workflows invoke, so a row that falls a gate behind
is a failure rather than a proofreading task. That check exists because the table had fallen nine
rows behind the YAML, in the same page that tells the reader a list drifting by one entry reads
exactly like one that has not.

**Two lists remain prose, and prose rots.** The tier table in
[09-type-design.md](09-type-design.md) and the option table in [07-shell.md](07-shell.md) are
both derivable and neither is welded; the rule below still applies to them with nothing behind
it. Gating a list means the page and the tree read from one source, and until that is written the
list is a claim.

## Show the command

"It is faster" is not a claim. The output of `tests/perfbudget.sh` is.

A behavioural or performance claim ships with what produced it, so the next reader re-runs it
instead of trusting you. If you cannot produce a command, you are writing hearsay -- cut the
sentence.

## Never pin a number that moves

Two classes, and both go stale:

- **Numbers a gate computes.** The bench signature above all. Quote the command;
  `tests/docslint.sh` refuses a page that quotes the signature, and reads the current value
  out of the commit record to do it.
- **Lists a gate computes**, which is the same rule one dimension up. Write the list only where
  something compares it to its source: the CI table is welded to `.github/workflows/` and the
  performance selector to its copy in `AGENTS.md`. Elsewhere, name the command that produces the
  list instead of the list.
- **Numbers the code computes about itself.** Line counts, file sizes, symbol counts. Every
  one drifts with the next commit that touches its subject.

Where the figure earns its place, write the command that produces it:

```sh
awk '/^Value Search::Worker::search\(/{s=NR} s && NR>s && /^}/{print NR-s+1; exit}' \
  src/engine/search.cpp
```

Anchor the command on the symbol, never on a line number. A command that pins the line it
starts counting from goes stale on the first commit above it, and when it does it reports a
number rather than an error -- which is worse than pinning the figure, because it looks
current.

Where it does not, write the claim that stays true: *the largest file under `src/engine/nnue/`*
rather than *over a thousand lines*.

Tuned constants are the same class. Margins, reductions and history clamps move with tuning
patches -- name the file, not the value, unless the value is the point being made.

## Describe a gap as a gap

If something is unimplemented, unchecked or unmeasured, **say so, and say what it costs**.

Framing a hole as a decision is what keeps it alive: nobody fixes a design. "The platform
layer is deliberately minimal" invites no work. "`bench` is single-threaded and on one node,
so it exercises the allocator and nothing else here -- a change in this layer is one whose
correctness the gates largely do not establish" invites exactly the right work.

The same trap one step further: **never rationalise a defect into a convention.** When you
find yourself writing a sentence that makes a strange thing sound intended, stop and check
whether it is. That sentence is load-bearing for the next reader who might otherwise have
fixed it.

## State the limit

A description that omits its own boundary invites over-trust. Say what the thing does **not**
cover, as a property of the thing:

> A call count is inlining-immune at the callee. It is not immune at the caller -- a function
> inlined into its caller leaves the profile entirely.

That is a limit. "This page does not cover inlining" is not -- it is a note about the prose.

## What not to write

**No history.** "Used to be", "previously a stub", "fixed in". It is out of date the day after
and tells a reader nothing about the code in front of them. The before and after belong in the
commit message; that plus the code is the durable record.

**No meta.** Prose does not describe itself. No "this page explains", no section listing what
the page does not cover, no summary restating the section above it, no next-steps list nobody
asked for.

**No padding.** Length is not thoroughness; it is where rot hides. Cut anything that does not
help a reader implement or verify. Background available from the wiki belongs in
[12-references.md](12-references.md) as a link.

**Pair every prohibition with an alternative.** "Do not call X" leaves a reader stuck; "do not
call X, use Y, which holds the lock" does not.

**One example beats three paragraphs.**

## The three surfaces

A page, a code comment and a commit message answer to the same rules. They differ in shelf
life.

### Pages

Numbered by reading order; a contributor works down from the architecture into a zone. Each
owns one part of `src/`, names it in the opening lines, and names its audience.

A page is **hot** when it describes code that moves and **cold** when what it describes barely
does. The index table carries the temperature, and the temperature is a prediction of where to
look for a false claim: a page goes false when a commit changes the code and leaves the prose
describing what it replaced, so the rate is the rate the code moves.

**Change hot code, re-read its page in the same commit.** A doc is wrong from the moment the
code lands, and nobody knows which claim broke better than the person who broke it.

A diagram earns its place only when the structure is a graph or a branch that prose has to
serialise -- a decision with several conditions, a cycle, a dependency graph. A list, a table
or a linear pipeline is better as a list, a table or a linear pipeline.

### Code comments

**Imperative mood, leading with a verb.** "Resolve the path", not "Returns the path" or "This
function resolves...". A comment is an order to the reader, not a description of the author.

**Write only the constraint the code cannot show.** Never restate the next line. If the line
reads plainly, say nothing.

```cpp
// Sized to divide a cache line: probing one position must touch one line.
static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");
```

That comment survives a refactor. "The cluster is 32 bytes" does not.

Never say where the change came from or why it is right -- that is the commit message's job,
and it is noise the moment the change merges.

### Commit messages

The one surface where history is the **subject** rather than the contamination. A commit
message may say what the code used to do, because that is what a commit is.

**Every commit upstream accepts carries a `Bench:` line or the words "No functional change".**
This is not a convention, it is checked: the wiki's `pre-push` hook refuses a push otherwise,
matching

```
bench_regex='\b[Bb]ench[ :]+[1-9][0-9]{5,7}\b'
no_functional_change_regex='\b[Nn]o[[:space:]][Ff]unctional[[:space:]][Cc]hange\b'
```

so the bench number must be 6 to 8 digits. **The regexes ask only that the body contain one
form or the other**; that the `Bench:` line comes last and stands alone is this project's
shape, not something the hook can enforce. Which of the two applies is the same question
`CONTRIBUTING.md` asks: a functional change is tested on fishtest, a non-functional one is not,
unless it might affect performance.

#### A functional change

Subject, then the test results, then the pull request, then the bench:

```
Multi cut pruning correction history

STC: https://tests.stockfishchess.org/tests/view/<id>
LLR: 2.93 (-2.94,2.94) <0.00,2.00>
Total: 151072 W: 39154 L: 38677 D: 73241
Ptnml(0-2): 372, 17511, 39320, 17934, 399

LTC: https://tests.stockfishchess.org/tests/view/<id>
LLR: 2.96 (-2.94,2.94) <0.50,2.50>
Total: 109866 W: 28697 L: 28240 D: 52929
Ptnml(0-2): 39, 11353, 31686, 11822, 33

closes https://github.com/official-stockfish/Stockfish/pull/<n>

Bench: <node total>
```

One block per test, blank line between. The four lines of a block are the label and link, the
`LLR:` with its bounds, the `Total:` with the W/L/D split, and `Ptnml(0-2):` with the
pentanomial counts.

The label is free text that upstream never standardised, so read the recent record rather than
a rule:

```sh
git log -n 300 --format='%b' master | grep -oE '^[A-Za-z][A-Za-z0-9 ()-]*:' \
  | grep -iE 'stc|ltc' | sort | uniq -c | sort -rn | head
```

`Passed STC:` and `Passed LTC:` are the majority forms; a run made only to show the change
loses nothing adds `non-reg` or `non-regression`, in several spellings that all appear; `VLTC`
and `VVLTC` name the longest controls. Copy the form the record shows rather than adding a
spelling to the tail of that histogram.

Both a short and a long control are expected for a gainer. A non-regression result is one
block.

`Co-authored-by:` goes last, after the bench, when the work came from more than one person.

#### A non-functional change

The same shape without the tests, ending in the exact phrase:

```
Remove an incorrect AVX512 comment

closes https://github.com/official-stockfish/Stockfish/pull/<n>

No functional change
```

**A non-functional change that might affect performance is still tested**, and then it carries
a non-regression block and still ends "No functional change" -- the phrase is about the node
count, not about whether anyone measured it.

#### Prose in the body

Between the subject and the results, say what the change does and why it is expected to gain.
Credit an idea taken from elsewhere. This is the part a reader six months later actually needs,
and it is the part most often omitted.

The `closes` line is what links the commit to its review. It is not universal across the whole
history -- the convention post-dates most of it -- so read the ratio over the recent past
rather than over `master` entire:

```sh
git log -n 200 --format='%b' master | grep -c '^closes https://github.com/'
```

## The gates

| gate | what it proves here | owned by |
|---|---|---|
| `tests/docslint.sh` | the mechanical half of documentation rot: links, named paths, a pinned signature, an undiscoverable gate, and the two lists a gate can derive | this page |
| `tests/anchor.sh` | the commit record carries a `Bench:` a lane can read, and carries nothing else that looks like one | this page |
| `tests/devcite.sh` | citations into the untracked working area resolve, and the rebase-fragile ones carry their subject | this page |

### `tests/docslint.sh`

```sh
./tests/docslint.sh
```

runs seven checks, and `grep -n 'head_check "' tests/docslint.sh` is the list in order: a dead
internal link, a `src/`/`tests/`/`scripts/`/`docs/`/`.github/` path named in prose that is not in the
tree, a bench signature quoted in a page, a script in `tests/` or `scripts/` that no page
names, a tracked file pointing into the untracked working area, the two copies of the
performance-gate selector table -- `AGENTS.md`'s and [11-performance.md](11-performance.md)'s --
naming different gates, and that page's CI table naming, per workflow, the gates the workflow
actually invokes. A path `.gitignore` names is exempt from the path check, because prose
legitimately describes the tool that writes an ignored artifact.

The last two compare lists rather than reading a numeral, which is what makes them the only
checks here that can catch a wrong count. Neither reads the number written above its table: the
selector check compares the two gate columns to each other, and the CI check compares one column
to `.github/workflows/`. A count stated in a sentence is still prose.

Check 5 sweeps every tracked file rather than every page, and that scope is load-bearing: a
source comment or a workflow file dangles for a reader exactly as a doc line does. That is also
why it must exist separately from the path check, which exempts anything `.gitignore` names --
an ignored directory lands in that exemption and reports clean.

**It cannot tell you a sentence is false.** Prose can parse, link, name only real paths, and
still describe code that has moved. Three classes it will pass, and they are the ones worth
re-reading a page for: a real symbol attributed to the wrong file, a behaviour described as
absent from a build that has it, and a list with the wrong count or order **except** the two
that are welded. Every other list on every page is prose. The gate buys the mechanical half;
the half that needs a reader is bought only by opening the file.

### `tests/anchor.sh`

Holds the commit record to a shape the architecture lanes can read.

```sh
./tests/anchor.sh
```

`AGENTS.md` states the rule as *"the `Bench:` in the most recent commit body that carries one"*.
Two things must hold for that sentence to be operable, and neither was checked.

**There must be one, and it can be far back.** A branch that stacks non-functional commits on
upstream puts the newest footer arbitrarily deep, because none of its own may carry one:

```sh
git rev-list --count "$(git log -1 --format=%H -E --grep='^Bench: [1-9][0-9]{5,7}$')..HEAD"
```

So **never bound the walk.** A reader with a fixed depth finds nothing once the branch outgrows
it, and the depth that suffices today is the depth that stops sufficing at the next commit.
`git log --format=%b` over the whole history costs 0.1 s, which is cheaper than a number that
rots.

**Nothing else may look like one.** The regex upstream's pre-push hook uses,
`[Bb]ench[ :]+[0-9]{6,8}`, matches a run of spaces between the word and the number. So an
**evidence row** inside a body -- `  bench      2829394`, a gate result quoted in a commit
message -- is indistinguishable from a footer to anything scanning line by line. A lane that
reads one gets a value that was true when written and goes stale at the next rebase, and every
architecture job then fails against it while the engine benches correctly throughout.

So **anchor the regex to the whole line**: `^Bench: <n>$`, which no prose mention and no gate
row can satisfy. An unanchored `Bench: *[0-9]+` is not the safer-looking half of that choice --
it finds a body sentence *carrying* `Bench: <n>` in backticks, and this branch has one, in the
commit that introduced this very gate. Such a reader returns the right value exactly as long as
the prose it landed on happens to quote the current anchor.

Every workflow that benches carries its own copy of the reader, and each is one
`git log --format=%b` captured into a variable with `^Bench: *<n>$` anchored on both ends,
which is what the rule says and what `AGENTS.md`'s own command does. Check the second half
rather than assume it -- prose describing a regex is not the regex:

```sh
grep -n "grep -m1 -oE" AGENTS.md .github/workflows/*.yml
```

Dispatched by `docs.yml`, whose checkout takes `fetch-depth: 0` for it. The gate scans commit
bodies, so a shallow clone hands it fewer to scan and it reports clean over the ones it never
saw -- there is no depth at which it refuses.

**The scan matches anywhere in a line, not only a line that is nothing else.** The narrow rule
misses the shape that costs most -- a value quoted inside a sentence, or padded into a table
column beside a `|` -- and those are the ones an unanchored reader reaches first. Write
`<bench_value>` where a body must name the anchor at all: it says the same to a reader, it
survives a rebase, and no regex can take it for a number.

`tests/anchor.baseline` carries the bodies that predate the check, with the reason. It expires in
both directions and currently ships EMPTY, which is the state to keep it in: rewording an
unpushed commit costs nothing, so a new entry is a finding rather than an exemption.

The offender half cannot be driven from the tree -- `tests/negative_control.sh` mutates files and
restores them, and a commit body is neither -- so `ANCHOR_EXTRA_BODY` names a file the body scan
reads as one more commit. It can only ADD an offender, never drop one, so it cannot be used to
quiet the gate.

### `tests/devcite.sh`

Citation hygiene for the untracked working area. Five checks: every cited SHA is an ancestor of
`HEAD`; every rebase-fragile citation carries its commit subject; every relative link resolves;
no SHA-shaped placeholder survives; every fenced code block is closed.

```sh
./tests/devcite.sh          # 0 clean, 1 findings, 2 skipped (no working area)
```

**Existence is the wrong test, and that is the whole reason this gate exists.** A rebase leaves
its pre-rebase commits in the object store, and a backup ref pins them indefinitely, so

```sh
git cat-file -e "$sha^{commit}"          # WRONG -- asks about this clone
git merge-base --is-ancestor "$sha" HEAD # asks whether it is on the branch
```

differ for every citation written before the last rebase. The existence test is the tempting
one and it retracts correct findings: a SHA a backup ref still pins answers yes to it while
being reachable from nothing anyone else has.

So the gate classifies rather than tests, into three tiers. **On the branch** resolves for
anyone. **Off-branch but held by a ref** resolves on the author's machine and nowhere else --
a warning, not a failure, because a tagged sitting head is *meant* to be off-branch.
**Reachable from no ref** is one `git gc --prune` from unresolvable.

**Only the missing subject fails.** A rebase already happened and no edit recovers those
commits; what is repairable is whether the citation still means anything without its SHA. So
the durable form is a subject beside it -- `` `46944a92` "fix(shell): stop the search before the
critical-error exit" `` -- which survives any rebase and is greppable. Failing on the tier
itself would leave the gate permanently red on a state nobody can fix, and a gate that cannot
reach zero is ignored at zero plus one.

**What it cannot see**: whether the commit a SHA names is the commit the sentence means. A
remap that rewrites a citation to a reachable but *wrong* commit passes cleanly.

**No lane, and the reason is not that nobody wired one.** The working area is gitignored, so a
clone has nothing for it to read; a lane would run against an empty corpus and pass.
`lanecheck.sh` carries that excuse and `docslint.sh` exempts the gate from its own check 5 --
both because the area is this gate's subject rather than a reference it leaks. It SKIPs rather
than passing when the corpus is absent, which is what makes shipping it safe.
