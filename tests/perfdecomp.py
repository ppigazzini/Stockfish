#!/usr/bin/env python3
"""Decompose two callgrind profiles into components and compare them.

`callgrind_annotate` wraps a long C++ symbol across output lines, so its columns
cannot be parsed for symbols like `Stockfish::Eval::NNUE::AccumulatorStack::
evaluate(...)`. This reads the callgrind output file itself, whose format is
defined and stable, and sums SELF cost per function.

Self cost, not inclusive: the line following a `calls=` line carries the callee's
inclusive cost and is skipped. Summing it would count the whole NNUE evaluation
inside `search` and again inside itself.

Components come from a TSV of NAME <TAB> REGEX. A component whose regex matches
nothing on BOTH sides is reported by name rather than printed as a zero, because
a zero reads as a total win forever.

A component matching on ONE side only divides a real cost by nothing. That row is
marked X and excluded from the verdict, and the run exits 1 -- the other rows are
still worth reading, and asymmetric inlining is the expected outcome of the very
refactors this gate measures.

A profile carrying no cost, or one where a large share of either side's cost has
no symbol at all, cannot be grouped in the first place. Those refuse before
printing anything a reader could quote.

Exit codes:  0 reported   1 a component matched on one side only
             2 a profile could not be read or could not be grouped
"""

import contextlib
import re
import sys
from pathlib import Path

# The order callgrind writes, and the only ones worth a column here. Ir is the
# work, D1mr/DLmr are the two locality levels, Bc/Bcm are the branch pair.
EVENTS = [
    "Ir",
    "Dr",
    "Dw",
    "I1mr",
    "D1mr",
    "D1mw",
    "ILmr",
    "DLmr",
    "DLmw",
    "Bc",
    "Bcm",
    "Bi",
    "Bim",
]

# Symbols valgrind could not name: a raw address, or an unresolved
# name-compression id. A profile in which a large share of ONE side's cost
# carries no symbol cannot be decomposed at all -- every component then matches
# on the named side only, and a real cost divided by nothing reads as a total
# win. The limit is a share of that side's instructions.
UNNAMED = re.compile(r"^(0x[0-9a-fA-F]+|\?\d+|\?+)$")
UNNAMED_LIMIT = 5.0


def parse_callgrind(path):
    """Return {demangled_symbol: {event: total_self_cost}}."""
    text = Path(path).read_text(encoding="utf8", errors="replace")
    names = {}
    totals = {}
    current = None
    order = None
    skip_next_cost = False

    for line in text.splitlines():
        if line.startswith("events:"):
            order = line.split(":", 1)[1].split()
            continue
        # Name compression defines an id on its FIRST appearance, and that may be
        # a cfn= (called function) line rather than an fn=. Recording only fn=
        # leaves every such symbol as an unresolved id.
        if line.startswith(("fn=", "cfn=")):
            is_self = line.startswith("fn=")
            body = line.split("=", 1)[1]
            m = re.match(r"\((\d+)\)\s*(.*)$", body)
            if m:
                fid, name = m.group(1), m.group(2)
                if name:
                    names[fid] = name
                resolved = names.get(fid, f"?{fid}")
            else:
                resolved = body
            if is_self:
                current = resolved
                skip_next_cost = False
            continue
        if line.startswith("calls="):
            # The next cost line is the callee's inclusive cost, not ours.
            skip_next_cost = True
            continue
        if line[:1].isdigit() or line[:1] in "+-*":
            if skip_next_cost:
                skip_next_cost = False
                continue
            if current is None or order is None:
                continue
            parts = line.split()
            costs = totals.setdefault(current, {})
            for i, tok in enumerate(parts[1:]):
                if i >= len(order):
                    break
                with contextlib.suppress(ValueError):
                    costs[order[i]] = costs.get(order[i], 0) + int(tok)
            continue
        skip_next_cost = False

    return totals


def load_components(path):
    rows = []
    for line in Path(path).read_text(encoding="utf8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        rows.append((parts[0].strip(), re.compile(parts[1].strip())))
    return rows


def group(totals, components):
    """Sum each component's events; return (per-component, matched-symbol set)."""
    out = {name: dict.fromkeys(EVENTS, 0) for name, _ in components}
    claimed = set()
    for symbol, costs in totals.items():
        for name, rx in components:
            if rx.search(symbol):
                for ev in EVENTS:
                    out[name][ev] += costs.get(ev, 0)
                claimed.add(symbol)
                break
    return out, claimed


def fmt_m(v):
    return f"{v / 1e6:,.1f}" if v else "-"


def ratio(head, base):
    return head / base if base else None


def unnamed_share(profile):
    """Percentage of a side's instructions sitting under an unnamed symbol."""
    total = sum(c.get("Ir", 0) for c in profile.values())
    if not total:
        return 0.0
    unnamed = sum(c.get("Ir", 0) for s, c in profile.items() if UNNAMED.match(s))
    return 100.0 * unnamed / total


def biggest(profile, predicate, n=4):
    rows = [(c.get("Ir", 0), s) for s, c in profile.items() if predicate(s) and c.get("Ir", 0)]
    rows.sort(reverse=True)
    return rows[:n]


def main():
    if len(sys.argv) != 4:
        print("usage: perfdecomp.py <base.out> <head.out> <components.tsv>", file=sys.stderr)
        return 2

    base_path, head_path, comp_path = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        base = parse_callgrind(base_path)
        head = parse_callgrind(head_path)
    except OSError as exc:
        print(f"perfdecomp: cannot read a profile: {exc}", file=sys.stderr)
        return 2

    components = load_components(comp_path)
    gb, claimed_b = group(base, components)
    gh, claimed_h = group(head, components)

    tot_b = sum(c.get("Ir", 0) for c in base.values())
    tot_h = sum(c.get("Ir", 0) for c in head.values())

    # REFUSE BEFORE PRINTING ANYTHING. A table is not a safe way to report
    # either failure below: the reader sees plausible per-row numbers and a
    # grouped total that is arithmetic on a hole. Both conditions mean the two
    # profiles are not comparable per component, so say so and produce no table.
    if not tot_b or not tot_h:
        print(
            f"perfdecomp: VOID -- a profile carries no cost at all"
            f" (upstream {tot_b} Ir, head {tot_h} Ir). A truncated or empty callgrind"
            f" file reads as a total win; it is a dead run, not a result.",
            file=sys.stderr,
        )
        return 2

    un_b, un_h = unnamed_share(base), unnamed_share(head)
    if max(un_b, un_h) > UNNAMED_LIMIT:
        print(
            f"perfdecomp: VOID -- {un_b:.1f}% of upstream and {un_h:.1f}% of head instructions"
            f" carry no symbol (limit {UNNAMED_LIMIT:.0f}%).",
            file=sys.stderr,
        )
        print(
            "perfdecomp: cost that carries no symbol cannot be attributed to any"
            " component, so the grouping below it would be arithmetic on a hole."
            " When only one side is affected every component matches on the other"
            " side alone. Whole-program totals come from valgrind's own summary and"
            " are unaffected.",
            file=sys.stderr,
        )
        for label, prof in (("upstream", base), ("head", head)):
            rows = biggest(prof, lambda s: bool(UNNAMED.match(s)))
            if rows:
                print(f"  largest unnamed symbols ({label} side):", file=sys.stderr)
                for ir, sym in rows:
                    print(f"    {fmt_m(ir):>10}  {sym}", file=sys.stderr)
        return 2

    print(
        f"  {'component':<26} {'up Ir':>10} {'re Ir':>10} {'Ir':>7} "
        f"{'up D1mr':>9} {'re D1mr':>9} {'D1mr':>7} "
        f"{'up Bcm':>9} {'re Bcm':>9} {'Bcm':>7}  winner"
    )
    print(
        f"  {'-' * 26} {'-' * 10} {'-' * 10} {'-' * 7} "
        f"{'-' * 9} {'-' * 9} {'-' * 7} {'-' * 9} {'-' * 9} {'-' * 7}  {'-' * 8}"
    )

    missing = []
    one_sided = []
    for name, _ in components:
        b, h = gb[name], gh[name]
        if b["Ir"] == 0 and h["Ir"] == 0:
            missing.append(name)
            continue
        if (b["Ir"] == 0) != (h["Ir"] == 0):
            one_sided.append(name)
        r_ir = ratio(h["Ir"], b["Ir"])
        r_d1 = ratio(h["D1mr"], b["D1mr"])
        r_bc = ratio(h["Bcm"], b["Bcm"])

        # The verdict is on instructions, which are deterministic here. A tie
        # band is still required: a component difference inside it is code
        # layout rather than work, and calling that a winner invites a refactor
        # to be argued from the rounding.
        if name in one_sided:
            # A real cost divided by nothing. Name it as an artifact rather than
            # ranking it, and keep every other row: asymmetric inlining is the
            # expected outcome of the refactors this gate exists to measure.
            winner = "X one side"
        elif r_ir is None:
            winner = "-"
        elif r_ir < 0.9995:
            winner = "refish"
        elif r_ir > 1.0005:
            winner = "upstream"
        else:
            winner = "tie"

        def rf(r):
            return f"{r:.4f}" if r is not None else "-"

        print(
            f"  {name:<26} {fmt_m(b['Ir']):>10} {fmt_m(h['Ir']):>10} {rf(r_ir):>7} "
            f"{fmt_m(b['D1mr']):>9} {fmt_m(h['D1mr']):>9} {rf(r_d1):>7} "
            f"{fmt_m(b['Bcm']):>9} {fmt_m(h['Bcm']):>9} {rf(r_bc):>7}  {winner}"
        )

    cb = sum(gb[n]["Ir"] for n, _ in components)
    ch = sum(gh[n]["Ir"] for n, _ in components)
    print(f"  {'-' * 26}")
    print(f"  {'grouped':<26} {fmt_m(cb):>10} {fmt_m(ch):>10} {rf_(ratio(ch, cb)):>7}")
    whole = rf_(ratio(tot_h, tot_b))
    print(f"  {'whole program':<26} {fmt_m(tot_b):>10} {fmt_m(tot_h):>10} {whole:>7}")
    cov_b = 100 * cb / tot_b if tot_b else 0
    cov_h = 100 * ch / tot_h if tot_h else 0
    print(f"  coverage: {cov_b:.1f}% of upstream Ir, {cov_h:.1f}% of refish Ir is grouped")
    print(f"  unnamed:  {un_b:.1f}% of upstream Ir, {un_h:.1f}% of refish Ir carries no symbol")

    if missing:
        print()
        print("  MATCHED NOTHING ON EITHER SIDE (fix the regex, do not delete the row):")
        for name in missing:
            print(f"    {name}")

    # The biggest ungrouped symbols are the next rows worth adding -- on BOTH
    # sides. A component matching on one side only divides a real cost by a
    # near-zero one, so a broken regex reads as a catastrophic regression.
    if one_sided:
        print()
        print("  MATCHED ON ONE SIDE ONLY -- marked X above, not ranked:")
        for name in one_sided:
            side = "head" if gb[name]["Ir"] == 0 else "upstream"
            print(f"    {name}  (no match on the {side} side)")
        print("  Either the regex is wrong, or the symbol was inlined away on that side")
        print("  only. Compare the neighbouring row that absorbed it, not this one.")

    for label, prof, claimed in (("upstream", base, claimed_b), ("refish", head, claimed_h)):
        rest = [(c.get("Ir", 0), s) for s, c in prof.items() if s not in claimed and c.get("Ir", 0)]
        rest.sort(reverse=True)
        if rest[:4]:
            print()
            print(f"  largest ungrouped symbols ({label} side):")
            for ir, sym in rest[:4]:
                print(f"    {fmt_m(ir):>10}  {sym[:86]}")
    return 1 if one_sided else 0


def rf_(r):
    return f"{r:.4f}" if r is not None else "-"


if __name__ == "__main__":
    sys.exit(main())
