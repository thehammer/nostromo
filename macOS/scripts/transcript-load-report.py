#!/usr/bin/env python3
"""Turn a diagnostics.jsonl stream into a pass/fail table for the PR body.

Split out of transcript-load-test.sh because the arithmetic — a least-squares
fit, a footprint delta between two turn marks, a CPU rate between two samples —
is not something to write in jq and trust.

Usage:
    transcript-load-report.py [path/to/diagnostics.jsonl] [--turns N]
                              [--sample /tmp/sample.txt] [--cpu-percent X]
"""
import argparse
import datetime
import json
import os
import sys

DEFAULT_DIAG = os.path.expanduser(
    "~/Library/Application Support/Nostromo/diagnostics.jsonl")


def load(path):
    rows = []
    with open(path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue          # a torn last line while the app is still writing
    return [r for r in rows if r.get("turnsProcessed") is not None]


def seconds(row):
    return datetime.datetime.fromisoformat(
        row["timestamp"].replace("Z", "+00:00")).timestamp()


def at_turn(rows, n):
    """First sample at or after turn `n`."""
    for row in rows:
        if row["turnsProcessed"] >= n:
            return row
    return None


def slope_mb_per_1000(rows):
    """Least-squares MB per 1,000 turns over the second half of the run."""
    if not rows:
        return None
    half = max(r["turnsProcessed"] for r in rows) / 2
    pts = [(r["turnsProcessed"], r["physFootprintMB"])
           for r in rows if r["turnsProcessed"] >= half]
    if len(pts) < 2:
        return None
    mx = sum(x for x, _ in pts) / len(pts)
    my = sum(y for _, y in pts) / len(pts)
    num = sum((x - mx) * (y - my) for x, y in pts)
    den = sum((x - mx) ** 2 for x, _ in pts)
    return None if den == 0 else (num / den) * 1000


def throughput_curve(rows, buckets=6):
    """(turn range, turns/sec) per bucket — the per-delta-cost criterion."""
    out = []
    step = max(1, len(rows) // buckets)
    for i in range(0, len(rows) - step, step):
        a, b = rows[i], rows[i + step]
        dt = seconds(b) - seconds(a)
        dn = b["turnsProcessed"] - a["turnsProcessed"]
        if dt > 0 and dn > 0:
            out.append((a["turnsProcessed"], b["turnsProcessed"], dn / dt))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("diag", nargs="?", default=DEFAULT_DIAG)
    ap.add_argument("--turns", type=int, default=5000)
    ap.add_argument("--sample", default=None)
    ap.add_argument("--cpu-percent", type=float, default=None)
    args = ap.parse_args()

    rows = load(args.diag)
    if not rows:
        print(f"no diagnostics samples in {args.diag}", file=sys.stderr)
        return 2

    reached = max(r["turnsProcessed"] for r in rows)
    results = []   # (criterion, verdict, measured, limit)

    def add(name, ok, measured, limit):
        results.append((name, "PASS" if ok else "FAIL", measured, limit))

    # Footprint delta between the two turn marks.
    lo, hi = at_turn(rows, 500), at_turn(rows, args.turns)
    if lo and hi:
        delta = hi["physFootprintMB"] - lo["physFootprintMB"]
        add(f"footprint delta turn-500 → turn-{args.turns}", delta <= 250,
            f"{delta:+.1f} MB "
            f"({lo['physFootprintMB']:.0f} → {hi['physFootprintMB']:.0f})",
            "<= 250 MB")
    else:
        add(f"footprint delta turn-500 → turn-{args.turns}", False,
            f"only reached turn {reached}", "<= 250 MB")

    # Slope over the second half.
    s = slope_mb_per_1000(rows)
    if s is not None:
        add("second-half memory slope", s <= 20,
            f"{s:+.2f} MB / 1000 turns", "<= 20 MB / 1000 turns")
    else:
        add("second-half memory slope", False, "insufficient samples",
            "<= 20 MB / 1000 turns")

    # Materialized views: constant in session length, under the documented max.
    limit = max((r.get("maxMaterializedPerPane") or 60) for r in rows)
    early = at_turn(rows, 100)
    late = rows[-1]

    def peak(row):
        return max((p["materializedViews"] for p in row["panes"]), default=0)

    if early:
        add(f"materializedViews at turn 100 vs turn {late['turnsProcessed']}",
            peak(early) == peak(late),
            f"{peak(early)} vs {peak(late)}", "equal")
    worst = max(peak(r) for r in rows)
    add("materializedViews peak", worst <= limit, f"{worst} views",
        f"<= {limit} (documented maximum)")

    # Retention actually engaged — otherwise the numbers above prove nothing.
    hot = max((p["hotPayloadTurns"] for r in rows for p in r["panes"]), default=0)
    add("hot payload window bounded", hot <= 210, f"{hot} turns hot",
        "<= 200 + in-flight")

    # A transcript that empties itself is the most alarming thing this pane can
    # do. Reported explicitly so a drop in retained turns is never a mystery.
    instrumented = any("transcriptClears" in p for r in rows for p in r["panes"])
    if instrumented:
        clears = max((p.get("transcriptClears", 0) for r in rows for p in r["panes"]),
                     default=0)
        add("transcript never cleared during the run", clears == 0,
            f"{clears} clears", "0")
    else:
        # Absent is not zero. A run recorded before the counter existed must not
        # be allowed to report a clean bill of health it never earned.
        add("transcript never cleared during the run", False,
            "not instrumented in this run", "0")

    # Retained turns must only ever grow (below the retention cap).
    worst_drop = 0
    prev = {}
    for r in rows:
        for pane in r["panes"]:
            was = prev.get(pane["tag"], 0)
            worst_drop = max(worst_drop, was - pane["retainedTurns"])
            prev[pane["tag"]] = pane["retainedTurns"]
    add("retained turns monotonic", worst_drop == 0,
        f"largest drop: {worst_drop} turns", "0 (below the retention cap)")

    # Per-delta cost does not grow with session length.
    curve = throughput_curve(rows)
    if len(curve) >= 2:
        first, last = curve[0][2], curve[-1][2]
        add("per-delta cost flat in session length", last >= first / 2,
            f"{first:.2f} → {last:.2f} turns/sec", "final >= 0.5x initial")

    if args.cpu_percent is not None:
        add("idle CPU over 60 s", args.cpu_percent < 2,
            f"{args.cpu_percent:.2f} %", "< 2 %")

    if args.sample and os.path.exists(args.sample):
        text = open(args.sample, errors="replace").read()
        hits = text.count("CoreAutoLayout") + text.count("NSISEngine")
        add("no CoreAutoLayout/NSISEngine in 5 s sample", hits == 0,
            f"{hits} frames", "0 frames")

    # --- report ---
    width = max(len(r[0]) for r in results) + 2
    print(f"\nRun: {reached} turns delivered, {len(rows)} diagnostic samples, "
          f"{(seconds(rows[-1]) - seconds(rows[0])) / 60:.1f} min\n")
    print(f"{'criterion':<{width}} | {'':4} | {'measured':<28} | limit")
    print("-" * (width + 55))
    for name, verdict, measured, limit in results:
        print(f"{name:<{width}} | {verdict:4} | {measured:<28} | {limit}")
    print("-" * (width + 55))

    if curve:
        print("\nthroughput (per-delta cost vs session length):")
        for a, b, rate in curve:
            print(f"  turns {a:5d}–{b:5d}  {rate:5.2f} turns/sec")

    failed = sum(1 for r in results if r[1] == "FAIL")
    print(f"\npassed: {len(results) - failed}   failed: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
