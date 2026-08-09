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
nothing on a side is reported rather than silently zero, because a zero on one
side reads as a total win forever.

Exit codes:  0 reported   2 a profile could not be read
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
    for name, _ in components:
        b, h = gb[name], gh[name]
        if b["Ir"] == 0 and h["Ir"] == 0:
            missing.append(name)
            continue
        r_ir = ratio(h["Ir"], b["Ir"])
        r_d1 = ratio(h["D1mr"], b["D1mr"])
        r_bc = ratio(h["Bcm"], b["Bcm"])

        # The verdict is on instructions, which are deterministic here. A tie
        # band is still required: a component difference inside it is code
        # layout rather than work, and calling that a winner invites a refactor
        # to be argued from the rounding.
        if r_ir is None:
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

    if missing:
        print()
        print("  MATCHED NOTHING ON EITHER SIDE (fix the regex, do not delete the row):")
        for name in missing:
            print(f"    {name}")

    # The biggest ungrouped symbols are the next rows worth adding -- on BOTH
    # sides. A component matching on one side only divides a real cost by a
    # near-zero one, so a broken regex reads as a catastrophic regression.
    for label, prof, claimed in (("upstream", base, claimed_b), ("refish", head, claimed_h)):
        rest = [(c.get("Ir", 0), s) for s, c in prof.items() if s not in claimed and c.get("Ir", 0)]
        rest.sort(reverse=True)
        if rest[:4]:
            print()
            print(f"  largest ungrouped symbols ({label} side):")
            for ir, sym in rest[:4]:
                print(f"    {fmt_m(ir):>10}  {sym[:86]}")
    return 0


def rf_(r):
    return f"{r:.4f}" if r is not None else "-"


if __name__ == "__main__":
    sys.exit(main())
