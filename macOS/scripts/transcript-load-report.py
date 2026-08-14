#!/usr/bin/env python3
"""Turn a diagnostics.jsonl stream into a pass/fail table for the PR body.

Split out of transcript-load-test.sh because the arithmetic — a least-squares
fit, a footprint delta between two turn marks, a CPU rate between two samples —
is not something to write in jq and trust.

The governing rule is that **every criterion must be able to fail**. A row that
is omitted when its input is missing, or that compares a measurement against a
limit read out of the app under test, or that reads the *absence* of the thing it
measures as a clean result, is not a criterion — it is a decoration that always
says PASS.

## Why this file is shaped the way it is

Three consecutive independent reviews of the PR that introduced this report each
found *new* instances of that same bug, seven in total, every one a different
spelling of "the criterion was satisfied by the absence of the thing it
measures":

  - `max(..., default=0)` treated as a real measurement
  - a comparison that degenerates into comparing a value with itself
  - a loop that silently no-ops on empty input, leaving an initialised-to-zero
    accumulator to print PASS
  - an `if` with no `else`, so the row vanished instead of failing
  - `max()` used as the aggregator for what is an equality assertion
  - an `any()`-shaped instrumentation gate opened by one instrumented data point
    while every other point silently read as zero
  - a file-existence check that cannot distinguish empty or broken output from
    real output

The shape that produced all seven was one long `evaluate()` in which each
criterion hand-rolled its own "input missing / degenerate / measure" ladder and
then set its own boolean. That asks the same delicate question a dozen separate
times, and review only ever catches the instances it happens to look at. So the
decision moved to a choke point:

  1. A criterion is a **registered function** (`@criterion`). The table's row set
     *is* the registry, so a row cannot vanish, duplicate or reorder, and a
     criterion that raises becomes a FAIL row rather than a traceback.
  2. A criterion may only produce a verdict through `graded()` or `failed()`.
     `graded()` is the only path to PASS, it requires an explicit count of how
     many data points the criterion actually read, and below the count its own
     arithmetic needs it returns INCONCLUSIVE without ever consulting `ok`.
  3. **A criterion about the run requires two distinct samples.** Every
     `kind=RUN` criterion makes a claim about the run — a delta, a slope, a
     peak, an agreement, an absence of an event *during* the run — and none of
     those is observable from a single point. `graded()` enforces it, so the
     f4-class "subtracted a measurement from itself" defect cannot be
     reintroduced by a criterion body no matter how it is written.
  4. Duplicate measurements are collapsed once, in `load()`, rather than guarded
     against twelve times. Two lines carrying the same timestamp *and* the same
     turn count are one measurement written twice; counting them as two would
     satisfy rule 3 by comparing a measurement with itself.

`tests/transcript_load/test_transcript_load_tooling.py` asserts all of this
against the registry rather than against a hand-written list of today's
criteria, so a criterion added tomorrow is covered with no new test.

## The three kinds, and why the distinction is not an escape hatch

  - `RUN` — grades the run's measured behaviour, from the diagnostics rows.
    Cannot pass on a run with fewer than two distinct samples. This is the
    default, so a criterion that declares nothing gets the strictest treatment.
  - `PROCESS` — grades an out-of-band measurement of the process handed in on
    the command line (idle CPU, a `sample(1)` capture). Cannot pass when its own
    argument is absent.
  - `STREAM` — grades the evidence file itself: whether it parses, and whose run
    it is. These *can* pass on a file holding one clean line, because "this file
    parses" is a true statement about a one-line file. They are the two rows that
    qualify every other row.

The test suite pins the membership of `PROCESS` and `STREAM` exactly, in the same
spirit as `MATERIALIZED_LIMIT` below: the exemption exists, it is two rows wide,
and moving a criterion into it fails the suite until someone edits that line on
purpose.

Usage:
    transcript-load-report.py [path/to/diagnostics.jsonl] [--turns N]
                              [--sample /tmp/sample.txt] [--cpu-percent X]
"""
import argparse
import datetime
import json
import os
import sys
from typing import Any, Dict, NamedTuple, Optional, Tuple

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

# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------

PASS, FAIL, INCONCLUSIVE = "PASS", "FAIL", "INCONCLUSIVE"

#: A criterion's subject. See the module docstring for why there are three and
#: why the membership of the last two is pinned by the test suite.
RUN, PROCESS, STREAM = "run", "process", "stream"


class Verdict(NamedTuple):
    """One row of the table.

    `INCONCLUSIVE` is **non-passing**: `main()` exits non-zero if any row is not
    `PASS`. The third state exists so the *reason* is legible in the table — "we
    did not measure this" as against "we measured it and it is out of budget" —
    without weakening the exit contract by a single degree.
    """

    key: str
    name: str
    state: str
    measured: str
    limit: str
    observations: int

    @property
    def ok(self):
        return self.state == PASS


def graded(key, name, *, observations, ok, measured, limit, required=2):
    """The only way to produce a PASS.

    `observations` is how many data points this criterion actually read out of
    the run. It has no default, so a criterion cannot forget to say. `required`
    is the minimum the criterion's arithmetic needs, and it defaults to **2**:
    the overwhelming majority of rows here claim something about the run — a
    delta between two turn marks, a slope, a peak, an agreement between samples,
    the absence of an event *during* the run — and not one of those is observable
    from a single point. Below `required` the verdict is INCONCLUSIVE and `ok` is
    never consulted.

    This is the structural answer to three rounds of review findings in this
    file, every one of which was some variant of "the criterion was satisfied by
    the absence of the thing it measures": a `default=0`, a comparison of a value
    with itself, a loop that never ran, an `any()` gate one instrumented sample
    could open. Individual criteria no longer decide that empty input passes,
    because they no longer construct their own verdict state.

    Note what `observations` must count: *distinct measurements*, not rows.
    `load()` collapses duplicate samples precisely so that a criterion counting
    rows cannot clear a `required=2` gate by reading one measurement twice.
    """
    if observations < required:
        return Verdict(key=key, name=name, state=INCONCLUSIVE, measured=measured,
                       limit=limit, observations=observations)
    return Verdict(key=key, name=name, state=PASS if ok else FAIL,
                   measured=measured, limit=limit, observations=observations)


def failed(key, name, *, measured, limit, observations=0):
    """A verdict for evidence that is affirmatively bad rather than absent.

    Partially-instrumented panes, disagreeing samples, a mid-file malformed
    line, a stream carrying more than one run: the run measured something and
    what it measured is wrong. Distinct from INCONCLUSIVE, which means nobody
    looked — and worth distinguishing, because the two call for different
    actions from whoever reads the table.
    """
    return Verdict(key=key, name=name, state=FAIL, measured=measured,
                   limit=limit, observations=observations)


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------


class _Registered(NamedTuple):
    key: str
    limit: str
    kind: str
    fn: Any


#: The criteria table, in table order. `evaluate()` returns exactly one verdict
#: per entry for **every** possible input, including no input at all.
#:
#: A row that is silently omitted when its input is missing reads as "not a
#: problem" in a table where every other line says PASS, which is precisely the
#: failure this report exists to refuse. The row set is no longer a
#: hand-maintained list of display substrings that someone must remember to
#: update — it is this list, and it is built by the decorator.
CRITERIA = []


def criterion(key, limit, kind=RUN):
    """Register a criterion function.

    `kind` defaults to `RUN`, the strictest treatment, so a criterion added
    without thinking about its kind is covered by the universal barren-input test
    rather than exempted from it.
    """
    def wrap(fn):
        CRITERIA.append(_Registered(key=key, limit=limit, kind=kind, fn=fn))
        return fn
    return wrap


def registration(key):
    """The registry entry for `key`, for tests and for `evaluate_evidence`."""
    for reg in CRITERIA:
        if reg.key == key:
            return reg
    raise KeyError(key)


# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------


class Evidence(NamedTuple):
    """Everything the criteria are allowed to look at, including what was lost.

    `load()` used to `continue` past an unparseable line and drop every row
    without a `turnsProcessed` field, counting neither — so a report built from
    three usable lines out of five hundred looked exactly like a report built
    from three lines. Parse losses and run staleness are evidence, not
    bookkeeping, so they are carried here and graded.
    """

    #: Samples for THIS run only, in file order, duplicates collapsed.
    rows: Tuple[dict, ...]
    #: The run these samples belong to; None when the stream carries no identity.
    run_id: Optional[str]
    #: Non-blank lines in the file.
    total_lines: int
    #: Line number of the last non-blank line, or 0 for an empty/absent file.
    #: A torn *final* line is legitimate — the app is still writing while the
    #: driver reads — and this is what lets `stream-parses-cleanly` tell that
    #: apart from a writer or reader that is broken.
    last_line: int
    #: (line_number, reason) per line that failed to parse.
    malformed: Tuple[Tuple[int, str], ...]
    #: Line numbers of lines that parsed but carry no `turnsProcessed`. Dropping
    #: these is correct — every line written while no harness runs looks like
    #: this — but it must be *counted* behaviour, so a reader can tell "3 harness
    #: lines among 500 GUI lines" from "3 lines".
    unusable: Tuple[int, ...]
    #: Lines dropped as an exact repeat of a measurement already seen: same
    #: timestamp, same turn count. See `graded()` for why this is collapsed once
    #: here rather than guarded against in every criterion.
    duplicates: int
    #: run_id -> rows excluded as belonging to an earlier run in the same file.
    other_runs: Dict[Optional[str], Tuple[dict, ...]]
    turns: int = 5000
    cpu_percent: Optional[float] = None
    sample_path: Optional[str] = None

    @classmethod
    def from_rows(cls, rows):
        """Wrap a bare list of sample dicts, as the tests and callers pass it.

        Deliberately does **not** fabricate clean provenance. `run_id` is derived
        from the rows themselves and stays None when they carry no `runID`, so a
        fixture built from unstamped rows makes the staleness criterion fail
        rather than quietly pass.
        """
        kept, duplicates = _collapse_duplicates(rows)
        ids = {row.get("runID") for row in kept}
        run_id = ids.pop() if len(ids) == 1 else None
        return cls(rows=kept, run_id=run_id, total_lines=len(rows), last_line=len(rows),
                   malformed=(), unusable=(), duplicates=duplicates, other_runs={})


def _measurement_key(row):
    """What makes two samples the same measurement rather than two."""
    return (row.get("timestamp"), row.get("turnsProcessed"))


def _collapse_duplicates(rows):
    """Drop exact repeats of a measurement already seen. Returns (kept, dropped).

    Two lines with the same timestamp and the same turn count describe one
    moment. Left in place they let a criterion clear `graded()`'s two-sample
    floor by reading a single measurement twice, which is exactly the defect
    that floor exists to close.
    """
    seen = set()
    kept = []
    dropped = 0
    for row in rows:
        key = _measurement_key(row)
        if key in seen:
            dropped += 1
            continue
        seen.add(key)
        kept.append(row)
    return tuple(kept), dropped


def load(path):
    """Read `path` into an `Evidence`, counting everything discarded on the way."""
    try:
        handle = open(path)
    except OSError as exc:
        return Evidence(rows=(), run_id=None, total_lines=0, last_line=0,
                        malformed=((0, f"cannot read {path}: {exc.strerror}"),),
                        unusable=(), duplicates=0, other_runs={})

    parsed = []
    malformed = []
    unusable = []
    total_lines = 0
    last_line = 0
    with handle:
        for lineno, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            total_lines += 1
            last_line = lineno
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                malformed.append((lineno, exc.msg))
                continue
            if not isinstance(row, dict):
                malformed.append((lineno, "not a JSON object"))
                continue
            if row.get("turnsProcessed") is None:
                unusable.append(lineno)
                continue
            parsed.append(row)

    # Scope to the newest run in the file.
    #
    # `diagnostics.jsonl` is append-only across app launches, and two Nostromo
    # instances — a normal GUI plus a harness build — append to the same path
    # within one run. Returning every row ever written meant `at_turn(rows, 500)`
    # answered from run #1, the footprint delta straddled two runs, and a fresh
    # run of three samples could be graded entirely on a previous run's numbers
    # and print PASS on the headline memory figure.
    groups = {}
    order = []
    for row in parsed:
        run_id = row.get("runID")
        if run_id not in groups:
            groups[run_id] = []
            order.append(run_id)
        groups[run_id].append(row)

    if parsed:
        newest = parsed[-1].get("runID")
        rows, duplicates = _collapse_duplicates(groups.pop(newest))
        other_runs = {run_id: tuple(groups[run_id]) for run_id in order if run_id in groups}
    else:
        newest, rows, duplicates, other_runs = None, (), 0, {}

    return Evidence(rows=rows, run_id=newest, total_lines=total_lines,
                    last_line=last_line, malformed=tuple(malformed),
                    unusable=tuple(unusable), duplicates=duplicates,
                    other_runs=other_runs)


# ---------------------------------------------------------------------------
# Arithmetic
# ---------------------------------------------------------------------------


def seconds(row):
    """The sample's wall-clock time, or None if it carries no usable timestamp."""
    raw = row.get("timestamp")
    if not isinstance(raw, str):
        return None
    try:
        return datetime.datetime.fromisoformat(raw.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def plural(n, noun):
    return f"{n} {noun}" if n == 1 else f"{n} {noun}s"


def agreed(values):
    """The single value every sample reported, or None if they disagree.

    `max()` is not an aggregator for an equality assertion: a run reporting 60 in
    some samples and 30 in others passed on the maximum alone, even though the
    app demonstrably ran with a different cap for part of the run. An aggregator
    that hides disagreement between samples hands the app back part of the
    passing grade this report exists to withhold from it.
    """
    distinct = set(values)
    return distinct.pop() if len(distinct) == 1 else None


def reached_turn(rows):
    """Highest turn any sample reported, or None when there are none.

    Explicitly not `max(..., default=0)`. Zero turns and no samples are different
    facts, and the whole point of this file is to keep them different.
    """
    counts = [row["turnsProcessed"] for row in rows
              if row.get("turnsProcessed") is not None]
    return max(counts) if counts else None


def at_turn(rows, n):
    """First sample at or after turn `n`."""
    for row in rows:
        if row["turnsProcessed"] >= n:
            return row
    return None


def peak_materialized(row):
    """The largest `materializedViews` any pane in `row` reported, or None.

    Returns None rather than 0 for a row with no panes, and does it with an
    explicit list rather than `max(..., default=None)` — the textual shape that
    recurred through three review rounds — so the count of panes actually read is
    available to the caller instead of being swallowed by the aggregator.
    """
    views = [pane["materializedViews"] for pane in row.get("panes", [])
             if pane.get("materializedViews") is not None]
    return max(views) if views else None


def pane_samples(rows):
    """Every pane report in every sample, flattened."""
    return [pane for row in rows for pane in row.get("panes", [])]


def driven_pane_samples(rows):
    """Pane reports that show the view layer actually did something.

    A pane that reported itself with every counter at zero is a pane the run
    never drove, and its mere presence is not evidence about materialization,
    retention or the hot window. Accepting presence alone is round 2's f12 one
    level in: the instrumentation gate opens, and the numbers behind it are all
    zeros nobody measured.
    """
    out = []
    for row in rows:
        for pane in row.get("panes", []):
            if pane.get("retainedTurns") or pane.get("materializedViews"):
                out.append(pane)
    return out


def slope_mb_per_1000(rows):
    """Least-squares MB per 1,000 turns over the second half of the run.

    Returns `(slope, points)`. `points` is how many samples the fit actually
    consumed, so the criterion can report its own observation count instead of
    inferring one. `slope` is None when the fit is not defined — fewer than two
    points, or every point at the same turn count.
    """
    reached = reached_turn(rows)
    if reached is None:
        return (None, 0)
    half = reached / 2
    pts = [(row["turnsProcessed"], row["physFootprintMB"])
           for row in rows if row["turnsProcessed"] >= half]
    if len(pts) < 2:
        return (None, len(pts))
    mx = sum(x for x, _ in pts) / len(pts)
    my = sum(y for _, y in pts) / len(pts)
    num = sum((x - mx) * (y - my) for x, y in pts)
    den = sum((x - mx) ** 2 for x, _ in pts)
    return (None if den == 0 else (num / den) * 1000, len(pts))


def throughput_curve(rows, buckets=6):
    """(turn range, turns/sec) per bucket — the per-delta-cost criterion."""
    out = []
    step = max(1, len(rows) // buckets)
    for i in range(0, len(rows) - step, step):
        a, b = rows[i], rows[i + step]
        ta, tb = seconds(a), seconds(b)
        if ta is None or tb is None:
            continue
        dt = tb - ta
        dn = b["turnsProcessed"] - a["turnsProcessed"]
        if dt > 0 and dn > 0:
            out.append((a["turnsProcessed"], b["turnsProcessed"], dn / dt))
    return out


# ---------------------------------------------------------------------------
# The criteria
# ---------------------------------------------------------------------------

LIMIT_RUN_IDENTITY = "one run id, turnsProcessed non-decreasing"
LIMIT_STREAM_PARSES = "0 malformed lines (a torn final line excepted)"
LIMIT_FOOTPRINT = "<= 250 MB"
LIMIT_SLOPE = "<= 20 MB / 1000 turns"
LIMIT_MATERIALIZED_EQUAL = "equal"
LIMIT_MATERIALIZED_PEAK = f"0 < peak <= {MATERIALIZED_LIMIT}"
LIMIT_VIEW_CAP = f"== {MATERIALIZED_LIMIT}"
LIMIT_HARNESS = "targeted == requested, > 0"
LIMIT_HOT_WINDOW = "<= 200 + in-flight"
LIMIT_CLEARS = "0"
LIMIT_MONOTONIC = "0 (below the retention cap)"
LIMIT_THROUGHPUT = "final >= 0.5x initial"
LIMIT_CPU = "0 < cpu < 2 %"
LIMIT_SAMPLE_FRAMES = "0 frames"


@criterion("samples-are-from-this-run", limit=LIMIT_RUN_IDENTITY, kind=STREAM)
def _samples_are_from_this_run(ev):
    """Whose numbers is the rest of this table computed from?

    Distinct from the append-fallback truncation bug in `TranscriptDiagnostics`,
    and not closed by fixing it: that bug is about the app destroying evidence
    *during* a run, this row is about the report not knowing where the current
    run *starts*. `transcript-load-test.sh` truncates the file before each run,
    so the driver path is protected — but the script documents direct invocation
    against the default path, two instances append to that path within one run,
    and once the app can no longer truncate, the driver is the only thing that
    ever shortens the file.
    """
    key = "samples-are-from-this-run"
    name = "samples are from this run"
    excluded = sum(len(rows) for rows in ev.other_runs.values())

    if not ev.rows:
        return graded(key, name, observations=0, required=1, ok=False,
                      measured="no usable samples", limit=LIMIT_RUN_IDENTITY)

    ids = sorted({row["runID"] for row in ev.rows if row.get("runID") is not None})
    if not ids:
        return failed(key, name, observations=len(ev.rows),
                      measured=f"{plural(len(ev.rows), 'sample')} carry no runID — "
                               "freshness cannot be established",
                      limit=LIMIT_RUN_IDENTITY)
    if len(ids) > 1:
        return failed(key, name, observations=len(ev.rows),
                      measured=f"{len(ids)} run ids survived grouping: {ids}",
                      limit=LIMIT_RUN_IDENTITY)

    counts = [row["turnsProcessed"] for row in ev.rows]
    regressions = sum(1 for a, b in zip(counts, counts[1:]) if b < a)
    if regressions:
        return failed(key, name, observations=len(ev.rows),
                      measured=f"turnsProcessed decreased {regressions}x within one "
                               "run — two processes are writing this file",
                      limit=LIMIT_RUN_IDENTITY)
    if excluded:
        # The file holds an earlier run as well. The rows above were scoped to the
        # newest one, so the rest of the table is at least computed from a single
        # run — but this file is not this run's file, and saying so is the whole
        # job of this row.
        return failed(key, name, observations=len(ev.rows),
                      measured=f"{plural(len(ev.rows), 'sample')} from {ids[0][:8]}, "
                               f"{excluded} discarded from "
                               f"{plural(len(ev.other_runs), 'earlier run')} "
                               "in the same file",
                      limit=LIMIT_RUN_IDENTITY)

    return graded(key, name, observations=len(ev.rows), required=1, ok=True,
                  measured=f"{plural(len(ev.rows), 'sample')} from {ids[0][:8]}",
                  limit=LIMIT_RUN_IDENTITY)


@criterion("stream-parses-cleanly", limit=LIMIT_STREAM_PARSES, kind=STREAM)
def _stream_parses_cleanly(ev):
    """Did the file this table was computed from actually parse?

    At most one malformed line, and only if it is the last non-blank line. A torn
    final line is legitimate and expected — the app is still writing while the
    driver reads. Anything earlier means the writer or the reader is broken, and
    *every other number in this table came out of the same file*, so the table
    cannot be trusted. A high discard rate has to fail something; the
    must-be-the-last-line qualifier is what makes the rule precise enough not to
    false-fail the legitimate case.
    """
    key = "stream-parses-cleanly"
    name = "diagnostics stream parses cleanly"
    detail = (f"{plural(ev.total_lines, 'line')}, {len(ev.unusable)} without "
              f"turnsProcessed, {ev.duplicates} duplicate")

    if ev.total_lines == 0 and ev.malformed:
        # An unreadable or absent file, not a malformed line. `load` records the
        # reason at line 0; report it rather than "1 malformed line at 0 of 0".
        return graded(key, name, observations=0, required=1, ok=False,
                      measured=ev.malformed[0][1], limit=LIMIT_STREAM_PARSES)

    if not ev.malformed:
        return graded(key, name, observations=ev.total_lines, required=1, ok=True,
                      measured=detail, limit=LIMIT_STREAM_PARSES)

    torn_tail = (len(ev.malformed) == 1 and ev.last_line > 0
                 and ev.malformed[0][0] == ev.last_line)
    if torn_tail:
        return graded(key, name, observations=ev.total_lines, required=1, ok=True,
                      measured=f"{detail}, final line torn while being written",
                      limit=LIMIT_STREAM_PARSES)

    where = ", ".join(str(lineno) for lineno, _ in ev.malformed[:5])
    return failed(key, name, observations=ev.total_lines,
                  measured=f"{plural(len(ev.malformed), 'malformed line')} "
                           f"of {ev.total_lines}, at {where}",
                  limit=LIMIT_STREAM_PARSES)


@criterion("footprint-delta", limit=LIMIT_FOOTPRINT)
def _footprint_delta(ev):
    """The headline memory number: growth between the two turn marks.

    The two marks must resolve to two *different* samples. `at_turn` returns the
    first sample at-or-after a mark, so a single sample past both marks satisfied
    `lo and hi` and the criterion then subtracted a measurement from itself: a
    guaranteed `+0.0 MB` PASS on this PR's single most important number. A
    `--turns 500` invocation is degenerate in the same way and fails here for the
    same honest reason.
    """
    key = "footprint-delta"
    name = f"footprint delta turn-500 → turn-{ev.turns}"
    lo, hi = at_turn(ev.rows, 500), at_turn(ev.rows, ev.turns)

    if lo is None or hi is None:
        reached = reached_turn(ev.rows)
        return graded(key, name, observations=len(ev.rows), ok=False,
                      measured=f"only reached turn {reached}" if reached is not None
                               else "no usable samples",
                      limit=LIMIT_FOOTPRINT)
    if lo is hi:
        return graded(key, name, observations=1, ok=False,
                      measured="only one sample covers both marks",
                      limit=LIMIT_FOOTPRINT)

    delta = hi["physFootprintMB"] - lo["physFootprintMB"]
    return graded(key, name, observations=2, ok=delta <= 250,
                  measured=f"{delta:+.1f} MB "
                           f"({lo['physFootprintMB']:.0f} → {hi['physFootprintMB']:.0f})",
                  limit=LIMIT_FOOTPRINT)


@criterion("memory-slope", limit=LIMIT_SLOPE)
def _memory_slope(ev):
    """Least-squares growth over the second half of the run."""
    key = "memory-slope"
    name = "second-half memory slope"
    slope, points = slope_mb_per_1000(ev.rows)

    if slope is None and points >= 2:
        # Two or more points that all sit at the same turn count: the fit has no
        # x-spread. That is not a missing measurement, it is a broken one.
        return failed(key, name, observations=points,
                      measured=f"{points} samples all report the same turn count",
                      limit=LIMIT_SLOPE)
    if slope is None:
        return graded(key, name, observations=points, ok=False,
                      measured="insufficient samples", limit=LIMIT_SLOPE)
    return graded(key, name, observations=points, ok=slope <= 20,
                  measured=f"{slope:+.2f} MB / 1000 turns", limit=LIMIT_SLOPE)


@criterion("materialized-at-100-vs-late", limit=LIMIT_MATERIALIZED_EQUAL)
def _materialized_at_100_vs_late(ev):
    """Materialization is constant in session length.

    The row used to be emitted only `if early:`, so a run that never reached turn
    100 silently dropped the criterion instead of failing it — and when the run
    had one sample, or died early enough that the first sample at-or-after turn
    100 *is* the last sample, the comparison was trivially true and the criterion
    passed from a single measurement. The aborted-run case needs no exotic input:
    just a run that fell over, which is exactly when this table is read.
    """
    key = "materialized-at-100-vs-late"
    if not ev.rows:
        return graded(key, "materializedViews at turn 100 vs the last sample",
                      observations=0, ok=False, measured="no usable samples",
                      limit=LIMIT_MATERIALIZED_EQUAL)

    late = ev.rows[-1]
    name = f"materializedViews at turn 100 vs turn {late['turnsProcessed']}"
    early = at_turn(ev.rows, 100)

    if early is None:
        return graded(key, name, observations=len(ev.rows), ok=False,
                      measured=f"run never reached turn 100 "
                               f"(max {reached_turn(ev.rows)})",
                      limit=LIMIT_MATERIALIZED_EQUAL)
    if early is late:
        return graded(key, name, observations=1, ok=False,
                      measured=f"only one sample covers turn 100 and "
                               f"turn {late['turnsProcessed']}",
                      limit=LIMIT_MATERIALIZED_EQUAL)

    e, l = peak_materialized(early), peak_materialized(late)
    if e is None or l is None:
        return graded(key, name, observations=0, ok=False,
                      measured="no panes reported — nothing was measured",
                      limit=LIMIT_MATERIALIZED_EQUAL)
    return graded(key, name, observations=2, ok=e == l, measured=f"{e} vs {l}",
                  limit=LIMIT_MATERIALIZED_EQUAL)


@criterion("materialized-peak", limit=LIMIT_MATERIALIZED_PEAK)
def _materialized_peak(ev):
    """The bounded materialization window, against the hardcoded documented cap."""
    key = "materialized-peak"
    name = "materializedViews peak"
    peaks = [p for p in (peak_materialized(row) for row in ev.rows) if p is not None]

    if not peaks or max(peaks) <= 0:
        # A run with no panes, or one whose panes never materialized anything,
        # has not demonstrated a bounded window — it has demonstrated nothing.
        return graded(key, name, observations=0, ok=False,
                      measured="no materialized views reported — nothing was measured",
                      limit=LIMIT_MATERIALIZED_PEAK)

    worst = max(peaks)
    return graded(key, name, observations=len(peaks), ok=worst <= MATERIALIZED_LIMIT,
                  measured=f"{worst} views", limit=LIMIT_MATERIALIZED_PEAK)


@criterion("documented-view-cap", limit=LIMIT_VIEW_CAP)
def _documented_view_cap(ev):
    """The app's own reported bound, asserted separately from the measurement it
    used to supply the limit for. Every sample must agree: this is an equality
    assertion, and `max()` over disagreeing samples hands the app back exactly
    the self-grading this row exists to withhold.
    """
    key = "documented-view-cap"
    name = "app reports the documented view cap"
    reported = [row["maxMaterializedPerPane"] for row in ev.rows
                if row.get("maxMaterializedPerPane") is not None]

    if not reported:
        return graded(key, name, observations=0, ok=False,
                      measured="maxMaterializedPerPane absent from every sample",
                      limit=LIMIT_VIEW_CAP)

    value = agreed(reported)
    if value is None:
        return failed(key, name, observations=len(reported),
                      measured=f"{sorted(set(reported))}", limit=LIMIT_VIEW_CAP)
    return graded(key, name, observations=len(reported),
                  ok=value == MATERIALIZED_LIMIT, measured=f"{value}",
                  limit=LIMIT_VIEW_CAP)


@criterion("harness-targeting", limit=LIMIT_HARNESS)
def _harness_targeting(ev):
    """The harness actually drove the view layer.

    Traffic sent to a tag with no `ReplView` attached exercises `ChatSession` and
    materializes nothing, which would let every view-layer row above pass by
    vacuum. `max()` on *both* sides of this equality was the same defect the view
    cap above was fixed for and this row was left with: a run reporting
    `targeted: 8` in one sample and `targeted: 1` in the rest passed on the
    maximum.
    """
    key = "harness-targeting"
    name = "harnessTargetedPanes == harnessRequestedFocuses"
    targeted = [row["harnessTargetedPanes"] for row in ev.rows
                if row.get("harnessTargetedPanes") is not None]
    requested = [row["harnessRequestedFocuses"] for row in ev.rows
                 if row.get("harnessRequestedFocuses") is not None]

    if not targeted:
        return graded(key, name, observations=0, ok=False,
                      measured="harness did not report targeted panes",
                      limit=LIMIT_HARNESS)
    if not driven_pane_samples(ev.rows):
        # `harnessTargetedPanes` is the harness's own claim about itself. With no
        # pane reporting any retained turn or materialized view, nothing
        # corroborates it, and a self-report nobody checked is not a measurement
        # of the view layer.
        return graded(key, name, observations=0, ok=False,
                      measured=f"harness claims {max(targeted)} targeted panes, but no "
                               "pane reported any activity",
                      limit=LIMIT_HARNESS)

    drove, want = agreed(targeted), agreed(requested)
    if not requested:
        return graded(key, name, observations=len(targeted), ok=False,
                      measured="harness did not report requested focuses",
                      limit=LIMIT_HARNESS)
    if drove is None or want is None:
        return failed(key, name, observations=len(targeted),
                      measured=f"samples disagree: targeted {sorted(set(targeted))} / "
                               f"requested {sorted(set(requested))}",
                      limit=LIMIT_HARNESS)
    return graded(key, name, observations=len(targeted),
                  ok=drove > 0 and drove == want,
                  measured=f"{drove} targeted / {want} requested", limit=LIMIT_HARNESS)


@criterion("hot-payload-window", limit=LIMIT_HOT_WINDOW)
def _hot_payload_window(ev):
    """Retention actually engaged — otherwise the numbers above prove nothing.

    No `default=0`, for the same reason `peak_materialized` refuses one: with
    zero panes reported, `0 <= 210` printed PASS on a run that measured nothing
    at all. And a pane *reporting* a zero-turn transcript is the same
    non-measurement one level in, so it is not counted either.
    """
    key = "hot-payload-window"
    name = "hot payload window bounded"
    windows = [pane["hotPayloadTurns"] for pane in driven_pane_samples(ev.rows)
               if pane.get("hotPayloadTurns") is not None]

    if not windows:
        return graded(key, name, observations=0, ok=False,
                      measured="no panes reported — nothing was measured",
                      limit=LIMIT_HOT_WINDOW)
    hot = max(windows)
    return graded(key, name, observations=len(windows), ok=hot <= 210,
                  measured=f"{hot} turns hot", limit=LIMIT_HOT_WINDOW)


@criterion("transcript-never-cleared", limit=LIMIT_CLEARS)
def _transcript_never_cleared(ev):
    """A transcript that empties itself is the most alarming thing a pane can do.

    The instrumentation gate used to be satisfied by *any one* pane in *any one*
    sample carrying the key, after which `.get(..., 0)` read every pane that
    lacked it as zero clears — the "absent is not zero" rule, written down and
    then not applied one line later. In an 8-focus run a pane that never reported
    the counter contributed a clean bill of health it never earned.
    `TranscriptDiagnostics` emits `transcriptClears` as a non-optional Int for
    every pane, so requiring it everywhere cannot false-fail a run recorded by
    the current app — it only catches genuinely partial evidence.
    """
    key = "transcript-never-cleared"
    name = "transcript never cleared during the run"
    panes = pane_samples(ev.rows)
    missing = [pane for pane in panes if "transcriptClears" not in pane]

    if not panes or len(missing) == len(panes):
        # Absent is not zero. A run recorded before the counter existed must not
        # be allowed to report a clean bill of health it never earned.
        return graded(key, name, observations=0, ok=False,
                      measured="not instrumented in this run", limit=LIMIT_CLEARS)
    if missing:
        return failed(key, name, observations=len(panes) - len(missing),
                      measured=f"{len(missing)} pane samples did not report "
                               "transcriptClears",
                      limit=LIMIT_CLEARS)
    if not driven_pane_samples(ev.rows):
        return graded(key, name, observations=0, ok=False,
                      measured="no pane ever held a turn — nothing was measured",
                      limit=LIMIT_CLEARS)

    # `max` is a sound aggregator here and only here: `transcriptClears` is a
    # non-negative monotonic counter, so `max == 0` is exactly "every sample
    # reported zero". Every pane sample is read, including ones that hold no
    # turns — a clear is precisely the event that empties one.
    clears = max(pane["transcriptClears"] for pane in panes)
    return graded(key, name, observations=len(panes), ok=clears == 0,
                  measured=f"{clears} clears", limit=LIMIT_CLEARS)


@criterion("retained-turns-monotonic", limit=LIMIT_MONOTONIC)
def _retained_turns_monotonic(ev):
    """Retained turns must only ever grow, below the retention cap.

    `worst_drop` used to start at 0 with a loop that never ran when no panes were
    reported, so "largest drop: 0 turns" printed PASS on a run with nothing to
    drop. Counting *panes seen* instead of *comparisons made* was the same defect
    one level shallower: a run with a single sample performs zero comparisons and
    still had something to print. What is counted here is transitions, and one
    transition already implies two samples — the pair, not the point, is the unit
    this row measures in.
    """
    key = "retained-turns-monotonic"
    name = "retained turns monotonic"
    panes = pane_samples(ev.rows)
    transitions = 0
    worst_drop = 0
    previous = {}
    for row in ev.rows:
        for pane in row.get("panes", []):
            tag = pane.get("tag")
            if tag in previous:
                transitions += 1
                worst_drop = max(worst_drop, previous[tag] - pane["retainedTurns"])
            previous[tag] = pane["retainedTurns"]

    if not panes:
        return graded(key, name, observations=0, required=1, ok=False,
                      measured="no panes reported — nothing was measured",
                      limit=LIMIT_MONOTONIC)
    if not transitions:
        return graded(key, name, observations=0, required=1, ok=False,
                      measured="only one sample per pane — nothing to compare",
                      limit=LIMIT_MONOTONIC)
    return graded(key, name, observations=transitions, required=1,
                  ok=worst_drop == 0, measured=f"largest drop: {worst_drop} turns",
                  limit=LIMIT_MONOTONIC)


@criterion("per-delta-cost-flat", limit=LIMIT_THROUGHPUT)
def _per_delta_cost_flat(ev):
    """Per-delta cost does not grow with session length.

    This row had no `else`, so with fewer than two buckets it vanished from the
    table entirely — including on the abort path, i.e. exactly when the run
    measured nothing. It was the only row in the old `evaluate()` that could
    disappear; the registry is why none can now.
    """
    key = "per-delta-cost-flat"
    name = "per-delta cost flat in session length"
    curve = throughput_curve(ev.rows)

    if len(curve) < 2:
        return graded(key, name, observations=len(curve), ok=False,
                      measured="insufficient samples", limit=LIMIT_THROUGHPUT)
    first, last = curve[0][2], curve[-1][2]
    return graded(key, name, observations=len(curve), ok=last >= first / 2,
                  measured=f"{first:.2f} → {last:.2f} turns/sec",
                  limit=LIMIT_THROUGHPUT)


@criterion("idle-cpu", limit=LIMIT_CPU, kind=PROCESS)
def _idle_cpu(ev):
    """Idle CPU over 60 s. Unmeasured is a FAIL, not an omission.

    This row used to be conditional on its argument being present, so when the
    measurement failed the criterion carrying the incident's own signature
    silently vanished from the table.

    A measured **0.00 %** is not the best possible result, it is a different
    failure. `transcript-load-test.sh` computes this from a `cpu_seconds` delta
    over a 60 s window and checks `kill -0` both before and after, so a process
    that *died* yields no `--cpu-percent` at all and lands in the branch above —
    but a process that is *wedged* yields exactly `0.00`. An app that burned zero
    CPU across a full minute while allegedly running a 5,000-turn harness is
    evidence of a wedge, not of efficiency.
    """
    key = "idle-cpu"
    name = "idle CPU over 60 s"

    if ev.cpu_percent is None:
        return graded(key, name, observations=0, required=1, ok=False,
                      measured="not measured", limit=LIMIT_CPU)
    if ev.cpu_percent == 0:
        return failed(key, name, observations=1,
                      measured="0.00 % — no CPU at all over 60 s (wedged, not idle)",
                      limit=LIMIT_CPU)
    return graded(key, name, observations=1, required=1, ok=ev.cpu_percent < 2,
                  measured=f"{ev.cpu_percent:.2f} %", limit=LIMIT_CPU)


@criterion("no-coreautolayout-frames", limit=LIMIT_SAMPLE_FRAMES, kind=PROCESS)
def _no_coreautolayout_frames(ev):
    """The incident's own signature, inverted.

    Existence is not measurement. A zero-byte file, or one holding "sample: could
    not attach", counts zero signature frames and used to print PASS — the
    criterion this PR is named for, satisfied by the absence of the thing it
    measures. macOS `sample` always writes a "Call graph:" section, including for
    an unresponsive process, so its absence means the sample failed rather than
    that the app was clean. A false FAIL here is the safe direction: the shell
    driver already requires a non-empty file before passing `--sample`.
    """
    key = "no-coreautolayout-frames"
    name = "no CoreAutoLayout/NSISEngine in 5 s sample"

    if not ev.sample_path or not os.path.exists(ev.sample_path):
        return graded(key, name, observations=0, required=1, ok=False,
                      measured="not measured", limit=LIMIT_SAMPLE_FRAMES)
    with open(ev.sample_path, errors="replace") as handle:
        text = handle.read()
    if "Call graph" not in text:
        return graded(key, name, observations=0, required=1, ok=False,
                      measured="sample file has no call graph — nothing was measured",
                      limit=LIMIT_SAMPLE_FRAMES)
    hits = text.count("CoreAutoLayout") + text.count("NSISEngine")
    return graded(key, name, observations=1, required=1, ok=hits == 0,
                  measured=f"{hits} frames", limit=LIMIT_SAMPLE_FRAMES)


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------


def evaluate_evidence(ev):
    """Exactly one verdict per registered criterion, in registry order.

    A criterion that raises becomes a FAIL row naming the exception rather than a
    traceback that kills the table, and rather than an omission. That is what
    makes this callable on genuinely barren input — the single most important
    input to this report, and until the registry existed, the one input it could
    not be tested against at all.
    """
    out = []
    for reg in CRITERIA:
        try:
            verdict = reg.fn(ev)
            if verdict.key != reg.key or verdict.limit != reg.limit:
                raise ValueError(
                    f"criterion {reg.key!r} returned key={verdict.key!r} "
                    f"limit={verdict.limit!r}")
            out.append(verdict)
        except Exception as exc:                                   # noqa: BLE001
            out.append(failed(reg.key, reg.key,
                              measured=f"criterion raised "
                                       f"{type(exc).__name__}: {exc}",
                              limit=reg.limit))
    return out


def evaluate(rows_or_evidence, *, turns, cpu_percent, sample_path):
    """Every criterion, as a list of rows that each carry their own verdict.

    Accepts either an `Evidence` from `load()` or a bare list of sample dicts,
    which is how the tests and any ad-hoc caller hold them. Pure, and separated
    from `main()` so the table can be asserted directly from tests rather than
    scraped out of stdout.
    """
    ev = (rows_or_evidence if isinstance(rows_or_evidence, Evidence)
          else Evidence.from_rows(rows_or_evidence))
    return evaluate_evidence(ev._replace(turns=turns, cpu_percent=cpu_percent,
                                         sample_path=sample_path))


# ---------------------------------------------------------------------------
# Presentation
# ---------------------------------------------------------------------------

_STATE_WIDTH = len(INCONCLUSIVE)


def print_report(ev, results, stream=sys.stdout):
    """Print the run header, the full table, and the throughput curve.

    The table is printed for **every** input, including an empty, absent or
    entirely malformed file. `main()` used to return early in exactly that case,
    printing no table at all — so the one input where every row should read
    INCONCLUSIVE was the one input where no rows were printed. That is the
    criterion-omitted-rather-than-failed defect at whole-table scale.
    """
    reached = reached_turn(ev.rows)
    span = ""
    if len(ev.rows) >= 2:
        first, last = seconds(ev.rows[0]), seconds(ev.rows[-1])
        if first is not None and last is not None:
            span = f", {(last - first) / 60:.1f} min"
    print(f"\nRun: {reached if reached is not None else 'no'} turns delivered, "
          f"{len(ev.rows)} diagnostic samples{span}", file=stream)
    print(f"     {ev.total_lines} lines read, {len(ev.malformed)} malformed, "
          f"{len(ev.unusable)} without turnsProcessed, {ev.duplicates} duplicate, "
          f"{sum(len(r) for r in ev.other_runs.values())} from earlier runs\n",
          file=stream)

    # `obs` is the count of data points the row actually read. It is printed
    # because it is the number that decides whether a verdict may say PASS at all,
    # and a table that hides it asks a reader to take "PASS" on trust — which is
    # how this report came to have criteria that could not fail.
    width = max(len(v.name) for v in results) + 2 if results else 20
    print(f"{'criterion':<{width}} | {'':{_STATE_WIDTH}} | {'obs':>4} | "
          f"{'measured':<44} | limit", file=stream)
    print("-" * (width + _STATE_WIDTH + 67), file=stream)
    for v in results:
        print(f"{v.name:<{width}} | {v.state:{_STATE_WIDTH}} | {v.observations:>4} | "
              f"{v.measured:<44} | {v.limit}", file=stream)
    print("-" * (width + _STATE_WIDTH + 67), file=stream)

    curve = throughput_curve(ev.rows)
    if curve:
        print("\nthroughput (per-delta cost vs session length):", file=stream)
        for a, b, rate in curve:
            print(f"  turns {a:5d}–{b:5d}  {rate:5.2f} turns/sec", file=stream)

    passed = sum(1 for v in results if v.state == PASS)
    print(f"\npassed: {passed}   "
          f"failed: {sum(1 for v in results if v.state == FAIL)}   "
          f"inconclusive: {sum(1 for v in results if v.state == INCONCLUSIVE)}",
          file=stream)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("diag", nargs="?", default=DEFAULT_DIAG)
    ap.add_argument("--turns", type=int, default=5000)
    ap.add_argument("--sample", default=None)
    ap.add_argument("--cpu-percent", type=float, default=None)
    args = ap.parse_args()

    ev = load(args.diag)._replace(turns=args.turns, cpu_percent=args.cpu_percent,
                                  sample_path=args.sample)
    results = evaluate_evidence(ev)
    print_report(ev, results)
    # INCONCLUSIVE is non-passing. A criterion nobody measured has not passed,
    # and the shell driver's exit status must not say otherwise.
    return 1 if any(not v.ok for v in results) else 0


if __name__ == "__main__":
    sys.exit(main())
