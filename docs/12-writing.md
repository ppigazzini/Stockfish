# Writing these docs

What a page here must be true about, and what `tests/docslint.sh` does and does not check.
Read it before adding or editing a page.

Audience: anyone editing a page.

## The set

`README.md` is the index; GitHub renders it for the folder, so it is what a reader lands on.
The rest are numbered by **reading order**, not importance: a contributor works down from the
architecture into a zone. The prefix is the only ordinal.

Each page owns one part of `src/` and names its audience in the index table. A page describes
**what this code does** -- not what a chess engine does in general. Background a reader could
get from the wiki belongs there, not here.

## The rules

**Name the owner and the invariant, not just the mechanism.** Say which file and symbol owns
the behaviour and what must stay true about it. "`TTEntry::save` stores the depth" is accurate
and useless; the sentence a reader needs is that `depth8` is stored as an offset from
`DEPTH_NONE` and that `is_occupied()` tests it, so a depth encoding that reaches zero makes a
live entry read as empty. Write the sentence someone needs before they delete your line.

**Verify the claim against the tree.** Not "read it carefully" -- run it. `grep -c`, a `bench`
invocation, a `printf | ./stockfish`. A claim that takes seconds to check and was not checked
is the claim that turns out false.

**Describe a gap as a gap, never as a design.** If something is unimplemented or unchecked,
say unimplemented, and say what it costs. Framing a hole as a decision is what keeps it alive:
nobody fixes a design.

**Never rationalise a defect into a convention.** When you find yourself explaining why the
odd thing is fine, check whether it is.

**State the limit.** A description that omits its own boundary invites over-trust. Say what
the thing does not cover -- as a property of the thing, not as a section about the page.

**Never pin a number a gate computes.** The bench signature above all: it moves with every
functional commit and nobody greps documentation when it does. Quote the command. `docslint`
fails on a pinned signature, and it reads the current value out of the commit record to do it.

Tuned constants are the same class. Margins, reductions and history clamps move with tuning
patches; name the file, not the value, unless the value is the point.

**No history.** "Used to be", "fixed in", "previously a stub" is out of date the day after and
tells a reader nothing about the code in front of them. The before and after belong in the
commit message -- that plus the code is the durable record.

**No meta.** A page does not describe itself. No "this page explains", no section listing what
the page does not cover, no summary restating the section above it.

**Show the command.** "It is faster" is not a claim; the output of `tests/perfbudget.sh` is. A
behavioural or performance claim ships with what produced it, so the next reader can re-run it
instead of trusting you.

**One example beats three paragraphs**, and **pair every prohibition with an alternative**.
"Do not call X" leaves a reader stuck; "do not call X, use Y, which holds the lock" does not.

**Cut anything that does not help implement or verify.** Length is not thoroughness; it is
where rot hides.

## Hot and cold

These pages do not age alike. A page is **hot** when it describes code that moves: it is a
running claim about a tree someone is changing today. It is **cold** when what it describes
barely moves.

**Change hot code, re-read its page in the same commit.** A doc is wrong from the moment the
code lands, and nobody knows which claim broke better than the person who broke it.

The index table carries the temperature. Every false claim found in a set like this is found
in a hot row, and lands the same way: a commit changed the code and left the page describing
the code it replaced.

Cold does not mean unowned. It means the claim outlives a release, so when it is wrong it has
usually been wrong for a long time.

## Code comments

Same rules, plus these. No gate enforces comment style, so the tree stays clean only by
review.

**Imperative mood, leading with a verb.** "Resolve the path", not "Returns the path" or "This
function resolves...". A comment is an order to the reader, not a description of the author.

**Write only the constraint the code cannot show.** Never restate the next line. Never say
where the change came from or why it is right -- that is the commit message's job and it is
noise the moment the change merges. If the line reads plainly, say nothing.

**Name the invariant and what breaks without it.**

```cpp
// Sized to divide a cache line: probing one position must touch one line.
static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");
```

That comment survives a refactor. "The cluster is 32 bytes" does not.

**No history, no meta.** Not "was a stub", not "the following block does".

## The gate

```sh
./tests/docslint.sh
```

fails on a dead internal link, a `src/`/`tests/`/`scripts/`/`.github/` path named in prose
that is not in the tree, a bench signature quoted in a page, a script in `tests/` or
`scripts/` that no page names, and a tracked file pointing into the untracked working area.

A path `.gitignore` names is exempt from the path check, because a page legitimately describes
the tool that writes an ignored artifact.

**It cannot tell you a sentence is false.** A page can parse, link, name only real paths, and
still describe code that moved a month ago. The gate buys the mechanical half so review can
spend its attention on the half that needs a reader.
