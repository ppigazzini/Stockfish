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

None of them is catchable by a tool. All of them are catchable by opening the file.

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
[11-references.md](11-references.md) as a link.

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

## What the gate checks, and what it cannot

```sh
./tests/docslint.sh
```

runs six checks, and `grep -n 'head_check "' tests/docslint.sh` is the list in order: a dead
internal link, a `src/`/`tests/`/`scripts/`/`.github/` path named in prose that is not in the
tree, a bench signature quoted in a page, a script in `tests/` or `scripts/` that no page
names, a tracked file pointing into the untracked working area, and the two copies of the
performance-gate selector table -- `AGENTS.md`'s and [10-tooling-ci.md](10-tooling-ci.md)'s --
naming different gates. A path `.gitignore` names is exempt from the path check, because prose
legitimately describes the tool that writes an ignored artifact.

Only the last of the six derives a count, and it derives it from a table rather than from
prose: it compares the gate column of the two selector tables and says nothing about the
numeral written above either one.

**It cannot tell you a sentence is false.** Prose can parse, link, name only real paths, and
still describe code that has moved. The gate buys the mechanical half; the half that needs a
reader is bought only by opening the file.
