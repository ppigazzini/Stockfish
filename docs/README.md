# Stockfish developer documentation

This set describes **the source tree**, for a contributor reading it cold. The
[wiki](https://github.com/official-stockfish/Stockfish/wiki) covers building, usage, UCI
commands and the terminology; nothing here duplicates it, because two copies of one fact
drift apart and the wrong one gets read.

| Page | Owns |
|---|---|
| [00-architecture.md](00-architecture.md) | `src/` -- what each file owns, how a search flows, and what depends on what |
| [10-tooling-ci.md](10-tooling-ci.md) | `tests/`, `scripts/`, `.github/workflows/` -- every gate, what it proves, and what it cannot see |

The numbering leaves room, so a page added later lands where a reader expects it rather than
renumbering the set.

## Docs are part of the change, not after it

Each page above is a live claim about code someone is about to touch. Change what a page owns,
re-read it and fix it **in the same commit**. A doc is wrong from the moment the code lands,
and that is how every false claim in a documentation set gets there.

This is the reason the pages are in the repository rather than in the wiki. A wiki in a
separate repository cannot be edited in the same commit, reviewed in the same pull request, or
checked against the tree.

```sh
./tests/docslint.sh
```

catches a dead link, a named path that does not exist, a pinned bench signature, an
undiscoverable gate, and a reference into the untracked working area. **It cannot tell you a
sentence has become false.** That part is yours, and it is the half that actually rots.

## These pages describe the tree AS IT IS

Not as it is intended to become. Where the current structure has a known problem the page
says so as present-tense fact, without a plan attached -- a description of the tree is
falsified by a change to the tree, which is checkable, while a description of an intention is
falsified by nothing.

## Numbers

Any figure a command can compute is written as the command, not as the number. A count in
prose is stale at the next commit and nobody greps documentation when it moves. The bench
signature is the sharpest case and `docslint` refuses it outright.
