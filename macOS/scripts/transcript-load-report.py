#!/usr/bin/env python3
"""Turn a diagnostics.jsonl stream into a pass/fail table for the PR body.

Split out of transcript-load-test.sh because the arithmetic — a least-squares
fit, a footprint delta between two turn marks, a CPU rate between two samples —
is not something to write in jq and trust.

The governing rule here is that **every criterion must be able to fail**. A row
that is omitted when its input is missing, or that compares a measurement
against a limit read out of the app under test, is not a criterion — it is a
decoration that always says PASS. Several rows used to be exactly that; the
comments below name each one.

Usage:
    transcript-load-report.py [path/to/diagnostics.jsonl] [--turns N]
                              [--sample /tmp/sample.txt] [--cpu-percent X]
"""
import argparse
import datetime
import json
import os
import sys
from typing import NamedTuple

DEFAULT_DIAG = os.path.expanduser(
    "~/Library/Application Support/Nostromo/diagnostics.jsonl")

# `TurnListVirtualizer.maxMaterialized`, hardcoded deliberately.
#
# This used to be read from the run's own `maxMaterializedPerPane` field, which
# means the app under test supplied its own passing grade: raising
# maxMaterialized to 500 still printed "PASS ... <= 500 (documented maximum)".
# The number lives here, and the app's reported bound is asserted separately
# below — so a change to the constant fails this report until someone changes
# this line on purpose.
MATERIALIZED_LIMIT = 60


class Criterion(NamedTuple):
    name: str
    ok: bool
    measured: str
    limit: str


# The criteria table is a **fixed set of rows**. `evaluate()` returns exactly one
# row per entry below for every possible input — a run that reached turn 5, a run
# with no panes, a run whose sample failed. A criterion that is silently omitted
# when its input is missing reads as "not a problem" in a table where every other
# line says PASS, which is precisely the failure this whole report exists to
# refuse.
#
# These are stable *substrings*, not full names: several rows interpolate the
# turn marks they were evaluated at. Each substring must match exactly one row.
# The test suite asserts both halves of that — every substring present, and no
# row that isn't one of these.
CRITERIA = (
    "footprint delta turn-500",
    "second-half memory slope",
    "materializedViews at turn 100",
    "materializedViews peak",
    "documented view cap",
    "harnessTargetedPanes",
    "hot payload window bounded",
    "transcript never cleared",
    "retained turns monotonic",
    "per-delta cost flat in session length",
    "idle CPU",
    "CoreAutoLayout",
)


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


def evaluate(rows, *, turns, cpu_percent, sample_path):
    """Every criterion, as a list of rows that each carry their own verdict.

    Returns exactly one row per entry in `CRITERIA`, for every possible input —
    see that constant for why the row set is fixed rather than conditional.

    Pure, and separated from `main()` so the table can be asserted directly from
    tests rather than scraped out of stdout.
    """
    reached = max(r["turnsProcessed"] for r in rows)
    results = []

    def add(name, ok, measured, limit):
        results.append(Criterion(name, bool(ok), measured, limit))

    def peak(row):
        # No `default=0`. A row with no panes is a run that measured nothing,
        # and "0 materialized views" used to print as PASS 0 vs 0 — a criterion
        # satisfied by the absence of the thing it was measuring.
        return max((p["materializedViews"] for p in row.get("panes", [])), default=None)

    # Footprint delta between the two turn marks.
    #
    # f4: the two marks must resolve to two *different* samples. `at_turn`
    # returns the first sample at-or-after a mark, so a single sample past both
    # marks satisfied `lo and hi` and the criterion then subtracted a
    # measurement from itself: a guaranteed `+0.0 MB` PASS on this PR's single
    # most important memory number. A `--turns 500` invocation is degenerate in
    # the same way and fails here for the same honest reason.
    lo, hi = at_turn(rows, 500), at_turn(rows, turns)
    if lo is None or hi is None:
        add(f"footprint delta turn-500 → turn-{turns}", False,
            f"only reached turn {reached}", "<= 250 MB")
    elif lo is hi:
        add(f"footprint delta turn-500 → turn-{turns}", False,
            "only one sample covers both marks", "<= 250 MB")
    else:
        delta = hi["physFootprintMB"] - lo["physFootprintMB"]
        add(f"footprint delta turn-500 → turn-{turns}", delta <= 250,
            f"{delta:+.1f} MB "
            f"({lo['physFootprintMB']:.0f} → {hi['physFootprintMB']:.0f})",
            "<= 250 MB")

    # Slope over the second half.
    s = slope_mb_per_1000(rows)
    if s is not None:
        add("second-half memory slope", s <= 20,
            f"{s:+.2f} MB / 1000 turns", "<= 20 MB / 1000 turns")
    else:
        add("second-half memory slope", False, "insufficient samples",
            "<= 20 MB / 1000 turns")

    # Materialized views: constant in session length, under the documented max.
    early = at_turn(rows, 100)
    late = rows[-1]

    # Absent is not equal. This row used to be emitted only `if early:`, so a run
    # that never reached turn 100 silently dropped the constant-in-session-length
    # criterion instead of failing it.
    if early is None:
        add(f"materializedViews at turn 100 vs turn {late['turnsProcessed']}", False,
            f"run never reached turn 100 (max {reached})", "equal")
    elif early is late:
        # f4's shape again, on the row whose entire purpose is "materialization
        # is constant in session length". When the run has one sample, or died
        # early enough that the first sample at-or-after turn 100 *is* the last
        # sample, `e == l` is trivially true and the criterion passed from a
        # single measurement. The aborted-run case needs no exotic input — just
        # a run that fell over, which is exactly when this table is read.
        add(f"materializedViews at turn 100 vs turn {late['turnsProcessed']}", False,
            f"only one sample covers turn 100 and turn {late['turnsProcessed']}",
            "equal")
    else:
        e, l = peak(early), peak(late)
        if e is None or l is None:
            add(f"materializedViews at turn 100 vs turn {late['turnsProcessed']}", False,
                "no panes reported — nothing was measured", "equal")
        else:
            add(f"materializedViews at turn 100 vs turn {late['turnsProcessed']}",
                e == l, f"{e} vs {l}", "equal")

    peaks = [p for p in (peak(r) for r in rows) if p is not None]
    if not peaks or max(peaks) <= 0:
        # A run with no panes, or one whose panes never materialized anything,
        # has not demonstrated a bounded window — it has demonstrated nothing.
        add("materializedViews peak", False,
            "no materialized views reported — nothing was measured",
            f"0 < peak <= {MATERIALIZED_LIMIT}")
    else:
        worst = max(peaks)
        add("materializedViews peak", worst <= MATERIALIZED_LIMIT, f"{worst} views",
            f"0 < peak <= {MATERIALIZED_LIMIT}")

    # The app's own reported bound, asserted separately from the measurement it
    # used to supply the limit for.
    reported = [r["maxMaterializedPerPane"] for r in rows
                if r.get("maxMaterializedPerPane") is not None]
    if not reported:
        add("app reports the documented view cap", False,
            "maxMaterializedPerPane absent from every sample",
            f"== {MATERIALIZED_LIMIT}")
    else:
        # f11: `max()` is the wrong aggregator for an equality assertion. A run
        # reporting 60 in some samples and 30 in others passed on the maximum
        # alone, even though the app demonstrably ran with a different cap for
        # part of the run. This row exists so the app cannot supply its own
        # passing grade; an aggregator that hides disagreement between samples
        # hands part of that back. Every sample must agree, and the measured
        # column names the values when they don't.
        distinct = sorted(set(reported))
        add("app reports the documented view cap",
            len(distinct) == 1 and distinct[0] == MATERIALIZED_LIMIT,
            f"{distinct[0]}" if len(distinct) == 1 else f"{distinct}",
            f"== {MATERIALIZED_LIMIT}")

    # The harness actually drove the view layer. Traffic sent to a tag with no
    # ReplView attached exercises ChatSession and materializes nothing, which
    # would let every view-layer row above pass by vacuum.
    targeted = [r["harnessTargetedPanes"] for r in rows
                if r.get("harnessTargetedPanes") is not None]
    requested = [r["harnessRequestedFocuses"] for r in rows
                 if r.get("harnessRequestedFocuses") is not None]
    if not targeted:
        add("harnessTargetedPanes == harnessRequestedFocuses", False,
            "harness did not report targeted panes", "targeted == requested, > 0")
    else:
        drove = max(targeted)
        want = max(requested) if requested else None
        add("harnessTargetedPanes == harnessRequestedFocuses",
            drove > 0 and want is not None and drove == want,
            f"{drove} targeted / {want if want is not None else '?'} requested",
            "targeted == requested, > 0")

    # Retention actually engaged — otherwise the numbers above prove nothing.
    #
    # f2: no `default=0`, for the same reason `peak()` above refuses one. With
    # zero panes reported, `0 <= 210` printed PASS on a run that measured
    # nothing at all.
    hot = max((p["hotPayloadTurns"] for r in rows for p in r.get("panes", [])),
              default=None)
    if hot is None:
        add("hot payload window bounded", False,
            "no panes reported — nothing was measured", "<= 200 + in-flight")
    else:
        add("hot payload window bounded", hot <= 210, f"{hot} turns hot",
            "<= 200 + in-flight")

    # A transcript that empties itself is the most alarming thing this pane can
    # do. Reported explicitly so a drop in retained turns is never a mystery.
    #
    # f12: the instrumentation gate used to be satisfied by *any one* pane in
    # *any one* sample carrying the key, after which `.get(..., 0)` read every
    # pane that lacked it as zero clears — the "absent is not zero" rule below,
    # written down and then not applied one line later. In an 8-focus run a pane
    # that never reported the counter contributed a clean bill of health it
    # never earned. `TranscriptDiagnostics` emits `transcriptClears` as a
    # non-optional Int for every pane, so requiring it everywhere cannot
    # false-fail a run recorded by the current app — it only catches genuinely
    # partial evidence.
    pane_samples = [p for r in rows for p in r.get("panes", [])]
    missing = [p for p in pane_samples if "transcriptClears" not in p]
    if not pane_samples or len(missing) == len(pane_samples):
        # Absent is not zero. A run recorded before the counter existed must not
        # be allowed to report a clean bill of health it never earned.
        add("transcript never cleared during the run", False,
            "not instrumented in this run", "0")
    elif missing:
        add("transcript never cleared during the run", False,
            f"{len(missing)} pane samples did not report transcriptClears", "0")
    else:
        clears = max(p["transcriptClears"] for p in pane_samples)
        add("transcript never cleared during the run", clears == 0,
            f"{clears} clears", "0")

    # Retained turns must only ever grow (below the retention cap).
    #
    # f3: `worst_drop` starts at 0 and the loop never runs when no panes were
    # reported, so "largest drop: 0 turns" printed PASS on a run with nothing to
    # drop. Track whether a pane was seen at all — same class as f2 above.
    worst_drop = 0
    observed = False
    prev = {}
    for r in rows:
        for pane in r.get("panes", []):
            observed = True
            was = prev.get(pane["tag"], 0)
            worst_drop = max(worst_drop, was - pane["retainedTurns"])
            prev[pane["tag"]] = pane["retainedTurns"]
    if not observed:
        add("retained turns monotonic", False,
            "no panes reported — nothing was measured",
            "0 (below the retention cap)")
    else:
        add("retained turns monotonic", worst_drop == 0,
            f"largest drop: {worst_drop} turns", "0 (below the retention cap)")

    # Per-delta cost does not grow with session length.
    #
    # f1: this row had no `else`, so with fewer than two buckets it vanished
    # from the table entirely — including on the abort path, i.e. exactly when
    # the run measured nothing. It was the only row in this function that could
    # disappear; see CRITERIA for why that is not allowed.
    curve = throughput_curve(rows)
    if len(curve) >= 2:
        first, last = curve[0][2], curve[-1][2]
        add("per-delta cost flat in session length", last >= first / 2,
            f"{first:.2f} → {last:.2f} turns/sec", "final >= 0.5x initial")
    else:
        add("per-delta cost flat in session length", False,
            "insufficient samples", "final >= 0.5x initial")

    # Unmeasured is a FAIL, not an omission — for both of the rows below.
    #
    # They used to be conditional on their argument being present, so when
    # `sample` failed, the criterion carrying this incident's own signature
    # silently vanished from the table. This report is a pass/fail table for a
    # fixed set of criteria; a criterion nobody measured has not passed.
    if cpu_percent is None:
        add("idle CPU over 60 s", False, "not measured", "< 2 %")
    else:
        add("idle CPU over 60 s", cpu_percent < 2, f"{cpu_percent:.2f} %", "< 2 %")

    if sample_path and os.path.exists(sample_path):
        with open(sample_path, errors="replace") as handle:
            text = handle.read()
        # f13: existence is not measurement. A zero-byte file, or one holding
        # "sample: could not attach", counts zero signature frames and used to
        # print PASS — the criterion this PR is named for, satisfied by the
        # absence of the thing it measures. macOS `sample` always writes a
        # "Call graph:" section, including for an unresponsive process, so its
        # absence means the sample failed rather than that the app was clean.
        #
        # A false FAIL here is the safe direction: the shell driver already
        # requires a non-empty file before passing --sample and prints a warning
        # on the path that would produce one.
        if "Call graph" not in text:
            add("no CoreAutoLayout/NSISEngine in 5 s sample", False,
                "sample file has no call graph — nothing was measured",
                "0 frames")
        else:
            hits = text.count("CoreAutoLayout") + text.count("NSISEngine")
            add("no CoreAutoLayout/NSISEngine in 5 s sample", hits == 0,
                f"{hits} frames", "0 frames")
    else:
        add("no CoreAutoLayout/NSISEngine in 5 s sample", False,
            "not measured", "0 frames")

    return results


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
    results = evaluate(rows, turns=args.turns, cpu_percent=args.cpu_percent,
                       sample_path=args.sample)

    width = max(len(c.name) for c in results) + 2
    print(f"\nRun: {reached} turns delivered, {len(rows)} diagnostic samples, "
          f"{(seconds(rows[-1]) - seconds(rows[0])) / 60:.1f} min\n")
    print(f"{'criterion':<{width}} | {'':4} | {'measured':<28} | limit")
    print("-" * (width + 55))
    for c in results:
        print(f"{c.name:<{width}} | {'PASS' if c.ok else 'FAIL':4} | "
              f"{c.measured:<28} | {c.limit}")
    print("-" * (width + 55))

    curve = throughput_curve(rows)
    if curve:
        print("\nthroughput (per-delta cost vs session length):")
        for a, b, rate in curve:
            print(f"  turns {a:5d}–{b:5d}  {rate:5.2f} turns/sec")

    failed = sum(1 for c in results if not c.ok)
    print(f"\npassed: {len(results) - failed}   failed: {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
