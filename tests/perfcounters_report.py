#!/usr/bin/env python3
"""Aggregate paired hardware-counter rounds into a table for one tier.

Reads the TSV tests/perfcounters.sh accumulates and prints, per counter, the
median of each side and the median of the PAIRED ratios -- not the ratio of the
medians. A pair is one round, which is the only comparison in which both sides
saw the same machine state, so pairing is what makes a noisy counter readable at
all.

The spread reported is the min and max of those per-round ratios. A ratio whose
spread straddles 1.000 has established no direction, and the caller is told so
rather than left to read a median that looks decisive.

Exit codes:  0 reported   2 no paired rounds to report
"""

import contextlib
import sys
from pathlib import Path

# Counters the C tool emits, in the order worth reading: what the work was, then
# how well the machine ran it, then the two things that make it run badly.
COUNTERS = [
    ("instructions", "instructions"),
    ("cycles", "cycles"),
    ("cache_misses", "cache misses"),
    ("cache_refs", "cache refs"),
    ("branch_misses", "branch misses"),
    ("branches", "branches"),
]

# Derived, because a ratio of ratios is what actually answers "did the machine
# execute it differently". IPC falling while instructions hold is a locality
# regression that the instruction axis reports as free.
DERIVED = [
    ("IPC", lambda c: c["instructions"] / c["cycles"] if c.get("cycles") else None),
    (
        "cache miss rate",
        lambda c: c["cache_misses"] / c["cache_refs"] if c.get("cache_refs") else None,
    ),
    (
        "branch miss rate",
        lambda c: c["branch_misses"] / c["branches"] if c.get("branches") else None,
    ),
]


def median(values):
    s = sorted(values)
    n = len(s)
    if n == 0:
        return None
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def parse(path, arch):
    """Return {side: {round: {counter: value}}} for one tier."""
    rounds = {"base": {}, "head": {}}
    for line in Path(path).read_text(encoding="utf8").splitlines():
        parts = line.split("\t")
        if len(parts) < 4 or parts[0] != arch:
            continue
        _, side, rnd, payload = parts[0], parts[1], parts[2], parts[3]
        vals = {}
        for token in payload.replace("perfcounters:", "").split():
            if "=" not in token:
                continue
            k, v = token.split("=", 1)
            with contextlib.suppress(ValueError):
                vals[k] = float(v)
        rounds[side][rnd] = vals
    return rounds


def main():
    if len(sys.argv) != 3:
        print("usage: perfcounters_report.py <results.tsv> <arch>", file=sys.stderr)
        return 2

    rounds = parse(sys.argv[1], sys.argv[2])
    paired = sorted(set(rounds["base"]) & set(rounds["head"]))
    if not paired:
        print("  no paired rounds to report", file=sys.stderr)
        return 2

    print(f"  {'counter':<18} {'base':>16} {'head':>16} {'ratio':>9}   spread")

    def report(name, getter):
        bvals, hvals, ratios = [], [], []
        for r in paired:
            b, h = getter(rounds["base"][r]), getter(rounds["head"][r])
            if b is None or h is None or b == 0:
                return None
            bvals.append(b)
            hvals.append(h)
            ratios.append(h / b)
        mb, mh, mr = median(bvals), median(hvals), median(ratios)
        lo, hi = min(ratios), max(ratios)
        straddles = lo <= 1.0 <= hi
        mark = "" if straddles else "  <-- outside the spread"
        fmt = ",.0f" if mb >= 1000 else ".4f"
        print(f"  {name:<18} {mb:>16{fmt}} {mh:>16{fmt}} {mr:>9.4f}   [{lo:.4f}, {hi:.4f}]{mark}")
        return None if straddles else mr

    decided = []
    for key, label in COUNTERS:
        got = report(label, lambda c, k=key: c.get(k))
        if got is not None:
            decided.append((label, got))
    for label, fn in DERIVED:
        got = report(label, fn)
        if got is not None:
            decided.append((label, got))

    if not decided:
        print(
            f"  every ratio's spread straddles 1.000 over {len(paired)} rounds:"
            " no direction established"
        )
        return 0

    print()
    for label, ratio in decided:
        direction = "higher" if ratio > 1 else "lower"
        print(f"  head is {abs(ratio - 1) * 100:.2f}% {direction} on {label}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
