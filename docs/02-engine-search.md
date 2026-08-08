# The search

`src/search.h`, `src/search.cpp`, `src/tt.h`, `src/tt.cpp`, `src/history.h`,
`src/movepick.h`, `src/movepick.cpp`, `src/timeman.h`, `src/timeman.cpp`, `src/score.h`,
`src/score.cpp`.

Alpha-beta with a transposition table, a staged move picker, history-driven ordering and a
pruning set. Every margin, reduction and bonus named here is a tuned constant: read the value
from the source, which is the only place it is current.

Audience: search.

## `tt.cpp` -- the transposition table

A flat array of 32-byte `Cluster`s, three `TTEntry` per cluster plus two bytes of padding.
The size is asserted:

```cpp
static constexpr int ClusterSize = 3;
static_assert(sizeof(Cluster) == 32, "Suboptimal Cluster size");
```

**The cluster is sized to divide a cache line**, so probing one position touches one line.
The cluster count is `mbSize * 1024 * 1024 / sizeof(Cluster)`, and it decides which positions
collide -- two engines with the same table size and different cluster arithmetic search
different trees.

An entry packs a 16-bit key fragment, a move, a value, a static eval, a depth offset from
`DEPTH_NONE`, and a byte holding the generation, the bound and the PV flag. Sixteen bits of
key is not a full check: **collisions are accepted**. A wrong entry costs a wrong move
ordering and is caught by the search, and paying eight bytes per entry to avoid it would cost
more in cache than it saves in accuracy.

`is_occupied()` reads `depth8`, which is why `DEPTH_UNSEARCHED` and `DEPTH_NONE` are negative
and distinct -- an entry that stored no search must still be distinguishable from an empty
slot.

**The table is shared across threads with no lock.** Entries are written and read
concurrently; a torn entry is possible and tolerated. `RelaxedAtomic` in `src/misc.h` is what
keeps that defined rather than undefined behaviour. See
[04-multithreading.md](04-multithreading.md).

Replacement weighs depth against age: a shallow entry from an old generation is the cheapest
thing to lose. The generation counter advances per search, so an entry's `relative_age`
grows without the table needing a sweep.

`value_to_tt` / `value_from_tt` convert a mate score between root-relative and node-relative
form. A mate score stored at one ply means a different thing when read at another, and the
conversion is what makes the stored number reusable.

## `history.h` -- the ordering tables

Every table is a **gravity** table, and one operator is the whole mechanism:

```cpp
void operator<<(int bonus) {
    int clampedBonus = std::clamp(bonus, -D, D);
    T   val          = *this;
    *this            = val + clampedBonus - val * std::abs(clampedBonus) / D;
}
```

The update moves the stored value toward the bonus by an amount proportional to how far it
still is from the clamp `D`. **A value saturates smoothly instead of pinning.** A table that
simply added and clamped would lose the ordering between two moves that had both reached the
ceiling, and that ordering is most of what the table is for.

`D` is a template parameter, one per table, so a bonus and the clamp it belongs to cannot be
transposed at a call site.

| Table | Indexed by | Clamp |
|---|---|---|
| `ButterflyHistory` | colour, from-to | 7183 |
| `LowPlyHistory` | ply (first 5), from-to | 7183 |
| `CapturePieceToHistory` | moving piece, destination, captured type | 10692 |
| `PieceToHistory` (a continuation plane) | moving piece, destination | 30000 |
| `PawnHistory` | pawn-key row, piece, destination | 8192 |
| `CorrectionHistory` | a key row | 1024 |
| `TTMoveHistory` | a single entry | 8192 |

`ContinuationHistory` is a `MultiArray<PieceToHistory, PIECE_NB, SQUARE_NB>`: a plane per
(piece, destination) of the *previous* move, each plane itself a history over the current
move. That is what lets the ordering say "after a knight lands on f3, this reply has worked".

`PawnHistory` is a `DynStats` sized from `PAWN_HISTORY_BASE_SIZE`, which is asserted to be a
power of two because the index is a mask of the pawn key rather than a modulus.

The tables are large and per-worker. `PieceToHistory` and `PawnHistory` are `AtomicStats`
because the continuation planes are shared.

## `movepick.cpp` -- the staged picker

Moves are produced in the order the search wants to try them, and **each stage is generated
only when the previous one runs out**. Most nodes cut off on the transposition move or the
first good capture, so generating the quiet moves for those nodes would be most of the
generator's cost spent on moves nobody looks at.

Four sequences, chosen by what the node is:

```
main search   MAIN_TT -> CAPTURE_INIT -> GOOD_CAPTURE -> QUIET_INIT
                      -> GOOD_QUIET -> BAD_CAPTURE -> BAD_QUIET
in check      EVASION_TT -> EVASION_INIT -> EVASION
probcut       PROBCUT_TT -> PROBCUT_INIT -> PROBCUT
quiescence    QSEARCH_TT -> QCAPTURE_INIT -> QCAPTURE
```

In check there is no capture/quiet split: every evasion is generated at once, because there
are few of them and skipping any is unsound.

The stage is entered by arithmetic rather than a branch:

```cpp
stage = EVASION_TT + !(ttm && pos.pseudo_legal(ttm));
```

A transposition move that is not pseudo-legal in this position -- which a 16-bit key
collision can produce -- skips the stage rather than being played.

Selection is one element per call, not a sort. A full sort would order moves the search never
reaches. `skip_quiets` is read at every call rather than fixed at construction, because the
search decides mid-node that it has seen enough quiet moves and the picker has to honour that
from the next call on.

## `search.cpp` -- the driver

`Worker::iterative_deepening` is what every thread runs, and it is three nested loops rather
than one. `search<Root>` is called from the innermost, so a single root position is searched
many times.

```mermaid
flowchart TD
    D{"rootDepth+1 < MAX_PLY,<br/>not stopped,<br/>depth limit not hit?"}
    D -->|no| OUT(["report bestmove"])
    D -->|yes| INC["rootDepth++"]
    INC --> MPV{"for each PV line<br/>pvIdx < multiPV"}
    MPV --> W["delta from the move's<br/>mean squared score<br/>alpha = avg-delta, beta = avg+delta"]
    W --> A["adjustedDepth = rootDepth<br/>- failedHighCnt - searchAgain term"]
    A --> SR["search&lt;Root&gt;(alpha, beta, adjustedDepth)"]
    SR --> SORT["stable_sort the root moves<br/>from pvIdx"]
    SORT --> ST{"stopped?"}
    ST -->|yes| OUT
    ST -->|no| C{"bestValue vs window"}
    C -->|"<= alpha, fail low"| FL["beta = alpha<br/>alpha = bestValue - delta<br/>failedHighCnt = 0"]
    C -->|">= beta, fail high"| FH["alpha = max(beta - delta, alpha)<br/>beta = bestValue + delta<br/>failedHighCnt++"]
    C -->|inside| NEXT["next PV line"]
    FL --> WID["delta widens"]
    FH --> WID
    WID --> A
    NEXT --> MPV
    MPV -->|done| D
```

Three things the shape makes visible:

- **A fail high shrinks the depth it re-searches at.** `adjustedDepth` subtracts
  `failedHighCnt`, so each successive fail high at one root depth searches shallower. A node
  that keeps failing high is one whose value is not yet bracketed, and re-searching it at full
  depth repeatedly would spend the iteration on it.
- **A fail low does not.** It resets `failedHighCnt` to zero and moves `beta` down to the old
  `alpha`, because a fail low means the move is worse than believed and the search needs the
  full depth to find out how much. Both branches keep the window one-sided rather than
  reopening it: a fail high raises `alpha` to `beta - delta` as well as lifting `beta`, so
  the re-search is still narrow.
- **The sort must be stable.** Every root move but the first and the new best is set to
  `-VALUE_INFINITE`, so an unstable sort would reorder moves that compare equal and lose the
  ordering the previous iteration established. Under MultiPV it would also disturb the lines
  already searched.

`delta` starts from the move's own `meanSquaredScore` and from `threadIdx`, so **threads
begin with different window widths** -- one of the ways Lazy SMP diverges
([04-multithreading.md](04-multithreading.md)).

Output during a fail is throttled by node count rather than depth: a re-search only reports
past a node threshold, because depth is reached quickly at the start of a search and some GUIs
do not cope with the volume.

## `search.cpp` -- the node

`Worker::search<NodeType>` is a single function structured as 21 numbered Steps, and it is
the largest in the tree:

```sh
awk 'NR>=708 && /^}/{print NR-708; exit}' src/search.cpp
```
 `NodeType` is a template parameter -- `NonPV`, `PV`, `Root` -- so the PV-only
bookkeeping is compiled out of the zero-window instantiation, which is the overwhelming
majority of nodes.

The Steps, in the order the node applies them:

| Step | What |
|---|---|
| 1 | initialise the node |
| 2 | aborted search, immediate draw |
| 3 | mate-distance pruning |
| 4 | transposition lookup |
| 5 | static evaluation, corrected |
| 6 | tablebase probe |
| 7 | razoring |
| 8 | futility pruning (child node) |
| 9 | null-move search with verification |
| 10 | internal iterative reduction |
| 11-12 | ProbCut |
| 13 | the move loop |
| 14 | pruning at shallow depth |
| 15 | extensions, including singular |
| 16 | make the move |
| 17 | late move reduction |
| 18 | full-depth search when LMR is skipped |
| 19 | undo |
| 20 | new best move |
| 21 | mate and stalemate |

What each pruning rule assumes, since that is what decides when it is unsound:

- **Razoring** -- so far below alpha at low depth that a quiescence search is enough to
  confirm it.
- **Futility** -- so far above beta that giving away material could not bring it below.
- **Null move** -- if passing still fails high, the real move will too. The assumption fails
  in zugzwang, which is why it is skipped when the side to move has no non-pawn material.
- **Internal iterative reduction** -- a node with no transposition move has no ordering to
  work with, so searching it at full depth mostly wastes the effort.
- **ProbCut** -- a capture that beats beta by a margin at reduced depth probably beats it at
  full depth.
- **Singular extension** -- if the transposition move is much better than every alternative,
  the node hinges on it and it is searched a ply deeper. "Much better" is measured by
  re-searching with that move *excluded*. The same search yields multi-cut when the node
  fails high anyway.
- **LMR** -- late moves in a well-ordered list are unlikely to be best, so they are searched
  shallower, with a re-search at full depth if the reduced search beats alpha.

**The static evaluation is corrected before any of this.** Correction-history tables record
how far the evaluation of positions sharing a pawn structure, a minor-piece configuration or
a non-pawn material count has historically been from what the search actually found, and the
node starts from the corrected value.

`qsearch` is the same shape in 9 Steps: stand-pat, then captures and promotions only, until
the position is quiet enough for the evaluation to mean something.

## `timeman.cpp` -- the budget

Two numbers. The **optimum** is the point past which a new iteration should not be started --
stopping between iterations is free, because the last completed one already has a best move.
The **maximum** is the point past which the search stops wherever it is.

The optimum is scaled between iterations by evidence about whether the current answer can be
trusted: a falling evaluation buys time, a best move stable across iterations sells it back,
best-move changes pooled across threads buy it, and a best move that already accounts for
most of the tree has little left that could displace it. The product is always clamped by the
maximum.

**Under `nodestime` the clock is not a clock.** Remaining time, increment and move overhead
are multiplied into node counts and the search is measured against nodes searched. The `time`
a GUI is told stays real milliseconds -- it asked how long the engine thought, not how the
engine chose to count.

The clock is read inside the search only through `check_time`, throttled by a node counter.
Reading a clock is a syscall on some platforms, and at millions of nodes per second the
granularity is well under a millisecond either way.

## `score.cpp` -- what a reported score means

The search works in units whose scale is a property of the network. Reporting them raw would
make `cp 200` mean something different after every net change, so the reported centipawn is
defined through a model fitted to real game results, whose parameters depend on the material
left on the board. The same internal evaluation therefore reports lower in an endgame, where
there is less left to convert it with. `UCI_ShowWDL` reads the same model.

Three kinds of score stay distinct rather than being flattened: a **mate** is a distance, a
**tablebase verdict** is a fact reported above any evaluation and below any mate, and
everything else is an estimate. Only the estimate goes through the model.

## `Skill` -- playing below full strength

A weakened engine must not simply search less deeply, because that produces an opponent that
blunders at random -- no easier to plan against and no more fun to play. The engine searches
at full strength, keeps several principal variations behind the GUI's back, and picks among
them with a bias that widens as the level drops, so every move it plays is one it genuinely
considered.

`UCI_Elo` wins over `Skill Level` when `UCI_LimitStrength` is set: a GUI asking for a rating
has asked the more specific question. The polynomial mapping one to the other is a fit
against real games, anchored to a named opponent, so the ratings mean ratings rather than
being a scale of the engine's own invention.
