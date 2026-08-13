"""Behavioral tests for the transcript-load measurement harness.

These tests exist because the harness itself had criteria that could not
fail — a measurement bug that always reads "PASS" is worse than no
measurement at all, because it tells an operator the system is healthy when
the harness simply forgot to check. Each test below pins one such defect:

  - Part A: macOS/scripts/ps-time-seconds.awk, a `ps -o time=` parser that
    replaces a fixed-field ($1*3600)+($2*60)+$3 mapping that silently
    misreads variable-width `ps` time strings (a 60x inflation on a
    genuinely idle process).
  - Part B: macOS/scripts/transcript-load-report.py's evaluate() function,
    which the current script does not yet have — the criteria logic lives
    inline in main() today. Five specific criteria there cannot currently
    fail (documented per-test below).
  - Part C: macOS/scripts/transcript-load-test.sh, static/structural checks
    on the shell driver plus one live exercise of the dead-pid CPU guard.

Run with:
    /usr/bin/python3 -m unittest discover -s tests/transcript_load
"""

import contextlib
import datetime
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
AWK_PATH = os.path.join(REPO_ROOT, "macOS", "scripts", "ps-time-seconds.awk")
REPORT_SCRIPT_PATH = os.path.join(REPO_ROOT, "macOS", "scripts", "transcript-load-report.py")
SHELL_SCRIPT_PATH = os.path.join(REPO_ROOT, "macOS", "scripts", "transcript-load-test.sh")

# The report script is a normal .py file, but we load it the same way
# tests/doctor loads the extensionless bin/nostromo-doctor, for consistency
# with the project's established test pattern and so this file doesn't care
# whether the target has a suffix.
_loader = importlib.machinery.SourceFileLoader("transcript_load_report", REPORT_SCRIPT_PATH)
_spec = importlib.util.spec_from_file_location(
    "transcript_load_report", REPORT_SCRIPT_PATH, loader=_loader
)
report = importlib.util.module_from_spec(_spec)
_loader.exec_module(report)


# --------------------------------------------------------------------------
# Fixture builder
# --------------------------------------------------------------------------

_BASE_TIME = datetime.datetime(2026, 8, 12, 10, 0, 0, tzinfo=datetime.timezone.utc)


def _iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + "Z"


def make_rows(
    *,
    total_turns=5000,
    n_samples=26,
    max_materialized_per_pane=60,
    peak_materialized=42,
    footprint_start=400.0,
    footprint_end=420.0,
    include_panes=True,
    include_harness_fields=True,
    harness_targeted_panes=8,
    harness_requested_focuses=8,
    include_transcript_clears=True,
    transcript_clears=0,
    hot_payload_turns=200,
):
    """Build a diagnostics-row fixture that satisfies every criterion by
    default. Each test perturbs exactly one keyword to violate exactly one
    criterion — this is the symmetry check that keeps the fixture honest.
    """
    rows = []
    for i in range(n_samples):
        frac = (i / (n_samples - 1)) if n_samples > 1 else 1.0
        turns = round(total_turns * frac)
        ts = _BASE_TIME + datetime.timedelta(seconds=5 * i)
        footprint = footprint_start + (footprint_end - footprint_start) * frac
        row = {
            "timestamp": _iso(ts),
            "physFootprintBytes": int(footprint * 1024 * 1024),
            "physFootprintMB": footprint,
            "maxMaterializedPerPane": max_materialized_per_pane,
            "turnsProcessed": turns,
        }
        if include_harness_fields:
            row["harnessTargetedPanes"] = harness_targeted_panes
            row["harnessRequestedFocuses"] = harness_requested_focuses
        if include_panes:
            pane = {
                "tag": "claudia",
                "retainedTurns": min(turns, 100),
                "materializedViews": peak_materialized,
                "hotPayloadTurns": hot_payload_turns,
                "compressedPayloadBytes": 0,
                "estimatedDocHeight": 1000.0,
            }
            if include_transcript_clears:
                pane["transcriptClears"] = transcript_clears
            row["panes"] = [pane]
        else:
            row["panes"] = []
        rows.append(row)
    return rows


def find_row(criteria, substring):
    """Look up a Criterion by a stable substring of its name. Fails loudly
    if the row is missing or if the substring is ambiguous — that ambiguity
    check is what makes "the row is present" a real assertion instead of a
    tautology.
    """
    matches = [c for c in criteria if substring in c.name]
    if len(matches) == 0:
        names = "\n  ".join(c.name for c in criteria)
        raise AssertionError(
            f"no criterion name contains {substring!r}. Names present:\n  {names}"
        )
    if len(matches) > 1:
        raise AssertionError(
            f"substring {substring!r} matched {len(matches)} criteria, expected exactly 1: "
            f"{[c.name for c in matches]}"
        )
    return matches[0]


def write_jsonl(rows):
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    with os.fdopen(fd, "w") as handle:
        for row in rows:
            handle.write(json.dumps(row) + "\n")
    return path


def write_text_file(text):
    fd, path = tempfile.mkstemp(suffix=".txt")
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    return path


def run_main(rows, extra_argv=()):
    """Invoke report.main() end-to-end against a real temp diagnostics file,
    the way the shell driver does, and return its exit code. stdout is
    swallowed; these tests assert on the return value, not the printed
    table.
    """
    diag_path = write_jsonl(rows)
    try:
        old_argv = sys.argv
        sys.argv = ["transcript-load-report.py", diag_path, *extra_argv]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                return report.main()
        finally:
            sys.argv = old_argv
    finally:
        os.remove(diag_path)


# --------------------------------------------------------------------------
# Part A: macOS/scripts/ps-time-seconds.awk
# --------------------------------------------------------------------------


def run_awk_time_parser(value):
    return subprocess.run(
        ["awk", "-f", AWK_PATH],
        input=value + "\n",
        capture_output=True,
        text=True,
    )


@unittest.skipUnless(shutil.which("awk"), "awk is not on PATH")
class PsTimeSecondsAwkTests(unittest.TestCase):
    def test_thirty_minutes_thirty_eight_point_six_seven_is_not_inflated_sixty_fold(self):
        # Pins the regression: the old ($1*3600)+($2*60)+$3 fixed-field
        # mapping treated a 2-field mm:ss.ss value as if $1 were hours,
        # reading "30:38.67" as 30h + 38min = 110320s instead of 30min 38.67s
        # = 1838.67s. That 60x inflation made a genuinely idle app (real CPU
        # usage ~0.04%) fail an "idle CPU < 2%" criterion.
        result = run_awk_time_parser("30:38.67")
        self.assertEqual(result.returncode, 0)
        measured = result.stdout.strip()
        self.assertEqual(measured, "1838.67")
        self.assertNotEqual(float(measured), 110320)

    def test_field_count_varies_with_runtime_and_is_handled_correctly(self):
        cases = [
            ("05:00", "300.00"),              # mm:ss
            ("1-02:03:04", "93784.00"),       # dd-hh:mm:ss
            ("00:00.00", "0.00"),             # mm:ss.ss, zero
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                result = run_awk_time_parser(value)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout.strip(), expected)

    def test_empty_input_fails_loudly_instead_of_feeding_arithmetic_a_blank(self):
        result = subprocess.run(
            ["awk", "-f", AWK_PATH], input="\n", capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_whitespace_only_input_fails_loudly(self):
        result = subprocess.run(
            ["awk", "-f", AWK_PATH], input="   \n", capture_output=True, text=True
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


# --------------------------------------------------------------------------
# Part B: transcript-load-report.py evaluate()
# --------------------------------------------------------------------------

# f13: a sample file is only evidence if it looks like `sample(1)` output.
# macOS `sample` always writes a "Call graph:" section, so its absence means
# the sample failed and the file is not a measurement. Fixtures that stand in
# for a healthy run must therefore look like a real sample, not be empty.
GOOD_SAMPLE = """\
Analysis of sampling Nostromo (pid 123) every 1 millisecond

Call graph:
    2669 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
      2669 start_wqthread + 8

Binary Images:
"""


class ModuleConstantsTests(unittest.TestCase):
    def test_materialized_limit_matches_turn_list_virtualizer_max_materialized(self):
        self.assertEqual(report.MATERIALIZED_LIMIT, 60)


class EvaluateKnownGoodRunTests(unittest.TestCase):
    """The anchor test. If the fixture below is genuinely good, every
    criterion must PASS — proving the fixes did not turn any criterion into
    one that can never pass, only into one that can fail when it should.
    """

    def test_every_criterion_passes_on_a_well_behaved_run(self):
        rows = make_rows()
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        self.assertGreater(len(criteria), 0)
        failing = [c for c in criteria if not c.ok]
        self.assertEqual(failing, [], f"unexpected failures: {failing}")

        # Every criterion this fix touches or introduces must be present.
        expected_substrings = [
            "footprint delta turn-500",
            "second-half memory slope",
            "materializedViews at turn 100",
            "materializedViews peak",
            "documented view cap",
            "hot payload window bounded",
            "transcript never cleared",
            "retained turns monotonic",
            "idle CPU",
            "CoreAutoLayout",
            "harnessTargetedPanes",
        ]
        for substring in expected_substrings:
            with self.subTest(substring=substring):
                row = find_row(criteria, substring)
                self.assertTrue(row.ok, f"{row.name!r} unexpectedly failed: {row}")

    def test_criterion_is_the_documented_namedtuple_shape(self):
        rows = make_rows()
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)
        first = criteria[0]
        self.assertIsInstance(first, report.Criterion)
        self.assertIsInstance(first.name, str)
        self.assertIsInstance(first.ok, bool)
        self.assertIsInstance(first.measured, str)
        self.assertIsInstance(first.limit, str)


class EvaluateMaterializedViewLimitTests(unittest.TestCase):
    """Pins: the view-cap limit was read out of the app under test
    (`max(r.get("maxMaterializedPerPane") or 60 ...)`), so raising the app's
    own constant to 500 made a peak of 300 print
    'PASS ... <= 500 (documented maximum)'. The limit must be the hardcoded
    MATERIALIZED_LIMIT, and the app's reported bound must be checked
    separately against 60.
    """

    def test_inflated_reported_limit_does_not_rescue_a_peak_above_the_hardcoded_limit(self):
        rows = make_rows(max_materialized_per_pane=500, peak_materialized=300)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        peak_row = find_row(criteria, "materializedViews peak")
        self.assertFalse(peak_row.ok)
        self.assertNotIn("500", peak_row.limit)

        bound_row = find_row(criteria, "documented view cap")
        self.assertFalse(bound_row.ok)


class EvaluateNoPanesTests(unittest.TestCase):
    """Pins: peak() used default=0, so a run that recorded zero panes
    printed 'PASS 0 vs 0'. A peak of 0 must now be a failure — it means the
    harness measured nothing, not that materialization stayed low.
    """

    def test_run_with_no_panes_fails_the_materialized_view_criterion(self):
        rows = make_rows(include_panes=False)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        peak_row = find_row(criteria, "materializedViews peak")
        self.assertFalse(peak_row.ok)

    def test_run_with_no_panes_fails_hot_payload_window_bounded(self):
        # f2: hot payload window bounded used `max(..., default=0)`, so a
        # run with zero panes measured 0 <= 210 and PASSed. Absence of a
        # measurement is not evidence the window is bounded.
        rows = make_rows(include_panes=False)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "hot payload window bounded")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "no panes reported — nothing was measured")

    def test_run_with_no_panes_fails_retained_turns_monotonic(self):
        # f3: retained turns monotonic tracked worst_drop starting at 0 and
        # never observed a pane, so a run that measured nothing PASSed with
        # "largest drop: 0 turns". No pane observed is not "never dropped".
        rows = make_rows(include_panes=False)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "retained turns monotonic")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "no panes reported — nothing was measured")


class EvaluateTurn100RowAlwaysPresentTests(unittest.TestCase):
    """Pins: the turn-100 comparison row was emitted only `if early:` — a
    run that never reached turn 100 silently omitted the row entirely. It
    must now always be present, and FAIL with measured text naming the
    highest turn actually reached.
    """

    def test_run_that_never_reaches_turn_100_still_emits_a_failing_row(self):
        rows = make_rows(total_turns=50, n_samples=6)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "materializedViews at turn 100")
        self.assertFalse(row.ok)
        self.assertIn("50", row.measured)


class EvaluateIdleCpuUnmeasuredTests(unittest.TestCase):
    """Pins: the idle-CPU row was conditional on `args.cpu_percent is not
    None` — when the sample failed, the incident's own signature criterion
    silently vanished instead of failing. It must always be emitted.
    """

    def test_unmeasured_cpu_yields_a_failing_row_not_an_absent_one(self):
        rows = make_rows()
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=None, sample_path=sample_path)

        row = find_row(criteria, "idle CPU")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not measured")


class EvaluateSampleUnmeasuredTests(unittest.TestCase):
    """Pins: the CoreAutoLayout/NSISEngine sample row was conditional on
    `args.sample and os.path.exists(args.sample)` — a missing or failed
    sample silently dropped the incident's signature criterion. It must
    always be emitted, failing when unmeasured.
    """

    def test_sample_path_of_none_yields_a_failing_row(self):
        rows = make_rows()
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=None)
        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not measured")

    def test_nonexistent_sample_path_yields_a_failing_row(self):
        rows = make_rows()
        missing_path = "/tmp/nostromo-transcript-sample-does-not-exist-redd.txt"
        self.assertFalse(os.path.exists(missing_path))
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=missing_path)
        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not measured")


class EvaluateSampleDetectsIncidentSignatureTests(unittest.TestCase):
    """The criterion this whole fix is named for must still catch the
    incident's own signature when it's actually present in a sample.
    """

    def test_sample_containing_signature_frames_fails(self):
        # The fixture must contain a real "Call graph" section (per f13) —
        # otherwise this would fail for having no call graph, not for
        # carrying the incident's own signature, and would silently stop
        # testing what it claims to test.
        cases = ["CoreAutoLayout", "NSISEngine"]
        for token in cases:
            with self.subTest(token=token):
                rows = make_rows()
                sample_path = write_text_file(GOOD_SAMPLE + f"0x1234 {token} + 12\n" * 3)
                self.addCleanup(os.remove, sample_path)

                criteria = report.evaluate(
                    rows, turns=5000, cpu_percent=0.04, sample_path=sample_path
                )
                row = find_row(criteria, "CoreAutoLayout")
                self.assertFalse(row.ok)
                self.assertIn("3 frames", row.measured)


class EvaluateHarnessTargetingTests(unittest.TestCase):
    """New f7 criterion: harnessTargetedPanes must be present, > 0, and
    equal harnessRequestedFocuses — proof the harness actually drove the
    number of panes it meant to, not just that panes existed.
    """

    def test_field_absent_fails(self):
        rows = make_rows(include_harness_fields=False)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)
        row = find_row(criteria, "harnessTargetedPanes")
        self.assertFalse(row.ok)

    def test_zero_targeted_panes_fails(self):
        rows = make_rows(harness_targeted_panes=0, harness_requested_focuses=8)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)
        row = find_row(criteria, "harnessTargetedPanes")
        self.assertFalse(row.ok)

    def test_targeted_panes_below_requested_focuses_fails(self):
        rows = make_rows(harness_targeted_panes=1, harness_requested_focuses=8)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)
        row = find_row(criteria, "harnessTargetedPanes")
        self.assertFalse(row.ok)

    def test_targeted_panes_equal_requested_focuses_passes(self):
        rows = make_rows(harness_targeted_panes=8, harness_requested_focuses=8)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)
        row = find_row(criteria, "harnessTargetedPanes")
        self.assertTrue(row.ok)


class EvaluateSingleSampleTests(unittest.TestCase):
    """f1/f4/f10: a run that only ever produced one diagnostics sample is
    the sharpest version of "comparison against yourself always passes" —
    every two-point comparison (throughput curve, footprint delta between
    two turn marks, materializedViews at turn 100 vs the last sample)
    degenerates to comparing a sample to itself. None of these are
    measurements; all three must fail and say so.
    """

    def test_single_sample_run_fails_per_delta_cost_flat(self):
        rows = make_rows(n_samples=1, total_turns=5000)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "per-delta cost flat in session length")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "insufficient samples")

    def test_single_sample_run_fails_footprint_delta(self):
        rows = make_rows(n_samples=1, total_turns=5000)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "footprint delta turn-500")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "only one sample covers both marks")

    def test_single_sample_run_fails_materialized_views_at_turn_100(self):
        rows = make_rows(n_samples=1, total_turns=5000)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "materializedViews at turn 100")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "only one sample covers turn 100 and turn 5000")


class EvaluateAbortedRunMaterializedViewTests(unittest.TestCase):
    """f10, distinct from EvaluateSingleSampleTests above: this is the
    realistic version of the defect, not an exotic edge case. A run that
    died right after turn 100 — two samples, the second already past 100 —
    hits the exact same self-comparison bug with no contrived input at all.
    If this needs a fix separate from the single-sample case, that's the
    signal the single-sample fix was too narrow.
    """

    def test_run_that_dies_just_after_turn_100_fails_the_comparison(self):
        rows = make_rows(n_samples=2, total_turns=400)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=400, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "materializedViews at turn 100")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "only one sample covers turn 100 and turn 400")


class EvaluateViewCapMixedReportingTests(unittest.TestCase):
    """f11: the view-cap criterion used `max(reported) == MATERIALIZED_LIMIT`,
    so a run where most samples reported the cap correctly but some reported
    something else (a mid-run config change, a stale build) PASSed as long as
    the maximum happened to equal 60. Every sample must agree.
    """

    def test_disagreeing_reported_caps_fail_and_name_both_values(self):
        rows = make_rows()
        for i in range(0, len(rows), 2):
            rows[i]["maxMaterializedPerPane"] = 30

        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "documented view cap")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "[30, 60]")

    def test_uniform_reported_cap_still_passes(self):
        # The fix must not make this row impossible to pass — a genuinely
        # uniform, correct run still needs to PASS.
        rows = make_rows()
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "documented view cap")
        self.assertTrue(row.ok)
        self.assertEqual(row.measured, "60")


class EvaluatePartiallyInstrumentedPanesTests(unittest.TestCase):
    """f12: "transcript never cleared" was gated on ANY pane anywhere
    carrying the transcriptClears key, then read every pane lacking it as
    zero clears via `.get(..., 0)`. A run where one pane is instrumented and
    another silently is not therefore PASSed on the strength of the
    instrumented pane alone, while the uninstrumented pane's clears (if any)
    were invisible. Every pane in every sample must report the key.
    """

    def test_some_panes_missing_the_key_fails_and_counts_them(self):
        rows = make_rows()
        for row in rows:
            row["panes"].append({
                "tag": "b", "retainedTurns": 10, "materializedViews": 42,
                "hotPayloadTurns": 200, "compressedPayloadBytes": 0,
                "estimatedDocHeight": 1000.0,
            })
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "transcript never cleared")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "26 pane samples did not report transcriptClears")

    def test_no_pane_anywhere_instrumented_still_fails_as_not_instrumented(self):
        rows = make_rows(include_transcript_clears=False)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "transcript never cleared")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not instrumented in this run")


class EvaluateSampleFileMustContainCallGraphTests(unittest.TestCase):
    """f13: the existence of a sample file is not evidence of a
    measurement. `sample` can write an empty or truncated file (permissions,
    a killed process, a too-short duration) with no "Call graph:" section at
    all, and the old code counted 0 signature-frame hits in that file as a
    clean PASS. A file is only a measurement if it actually contains a call
    graph.
    """

    def test_empty_sample_file_fails_as_unmeasured_not_as_a_clean_pass(self):
        rows = make_rows()
        sample_path = write_text_file("")
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "sample file has no call graph — nothing was measured")

    def test_garbage_sample_file_fails_as_unmeasured_not_as_a_clean_pass(self):
        rows = make_rows()
        sample_path = write_text_file("sample: could not attach\n")
        self.addCleanup(os.remove, sample_path)

        criteria = report.evaluate(rows, turns=5000, cpu_percent=0.04, sample_path=sample_path)

        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "sample file has no call graph — nothing was measured")


class EvaluateRowSetIsFixedTests(unittest.TestCase):
    """f14, the guard against a fourth review round: every fix above must
    change whether a row PASSes or FAILs, never whether it exists. evaluate()
    must return the exact same set of criteria — same names (up to the
    dynamic turn numbers interpolated into a few of them), same count — no
    matter what the input looks like. A dropped row and a stray extra row
    are exactly the two failure modes this whole PR was written to close off
    permanently; this test parameterizes over inputs designed to surface
    both.
    """

    def _assert_row_set_matches(self, criteria, label):
        missing = []
        for substring in report.CRITERIA:
            try:
                find_row(criteria, substring)
            except AssertionError:
                missing.append(substring)
        names = [c.name for c in criteria]
        self.assertEqual(
            missing, [],
            f"[{label}] missing criteria for substrings {missing!r}; "
            f"names present:\n  " + "\n  ".join(names),
        )
        self.assertEqual(
            len(criteria), len(report.CRITERIA),
            f"[{label}] expected exactly {len(report.CRITERIA)} rows "
            f"(one per entry in report.CRITERIA), got {len(criteria)}:\n  "
            + "\n  ".join(names),
        )

    def test_row_set_is_identical_across_every_kind_of_input(self):
        good_rows = make_rows()
        good_sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, good_sample_path)

        fixtures = [
            ("known-good", make_rows(), dict(turns=5000, cpu_percent=0.04,
                                              sample_path=good_sample_path)),
            ("no panes", make_rows(include_panes=False),
             dict(turns=5000, cpu_percent=0.04, sample_path=good_sample_path)),
            ("single sample", make_rows(n_samples=1),
             dict(turns=5000, cpu_percent=0.04, sample_path=good_sample_path)),
            ("aborted run", make_rows(n_samples=2, total_turns=400),
             dict(turns=400, cpu_percent=0.04, sample_path=good_sample_path)),
            ("no harness fields", make_rows(include_harness_fields=False),
             dict(turns=5000, cpu_percent=0.04, sample_path=good_sample_path)),
            ("no transcript clears field", make_rows(include_transcript_clears=False),
             dict(turns=5000, cpu_percent=0.04, sample_path=good_sample_path)),
            ("cpu_percent is None", good_rows,
             dict(turns=5000, cpu_percent=None, sample_path=good_sample_path)),
            ("sample_path is None", good_rows,
             dict(turns=5000, cpu_percent=0.04, sample_path=None)),
        ]

        for label, rows, kwargs in fixtures:
            with self.subTest(label=label):
                criteria = report.evaluate(rows, **kwargs)
                self._assert_row_set_matches(criteria, label)


class MainExitCodeTests(unittest.TestCase):
    """main() must aggregate evaluate()'s criteria into the process exit
    code the shell driver relies on: 1 if anything failed, 0 otherwise.
    """

    def test_all_passing_run_exits_zero(self):
        rows = make_rows()
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        exit_code = run_main(rows, ["--cpu-percent", "0.04", "--sample", sample_path])
        self.assertEqual(exit_code, 0)

    def test_run_with_any_failure_exits_one(self):
        rows = make_rows(include_panes=False)
        sample_path = write_text_file(GOOD_SAMPLE)
        self.addCleanup(os.remove, sample_path)
        exit_code = run_main(rows, ["--cpu-percent", "0.04", "--sample", sample_path])
        self.assertEqual(exit_code, 1)


# --------------------------------------------------------------------------
# Part C: transcript-load-test.sh
# --------------------------------------------------------------------------


class ShellScriptSyntaxTests(unittest.TestCase):
    def test_bash_parses_the_script_without_error(self):
        result = subprocess.run(
            ["bash", "-n", SHELL_SCRIPT_PATH], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck not installed; not adding it as a dependency")
    def test_shellcheck_reports_no_errors(self):
        result = subprocess.run(
            ["shellcheck", "--severity=error", SHELL_SCRIPT_PATH],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class ShellScriptStaticAssertionTests(unittest.TestCase):
    """Structural checks on the driver script text. These are a pragmatic
    fallback — the script launches a real app, so behavior can't be
    exercised hermetically — but each assertion pins a specific defect named
    in its docstring/comment, not an arbitrary implementation detail.
    """

    @classmethod
    def setUpClass(cls):
        with open(SHELL_SCRIPT_PATH) as handle:
            cls.text = handle.read()

    def test_stale_sample_file_is_removed_before_sampling(self):
        # Defect: a stale /tmp/nostromo-transcript-sample.txt left over from
        # a prior run could be read as this run's sample if `sample` failed
        # silently, making a real incident signature from a previous run
        # look like it belongs to the current one.
        rm_match = re.search(r"rm\s+-f\s+\S*SAMPLE_OUT\S*", self.text)
        self.assertIsNotNone(rm_match, "expected an `rm -f ... $SAMPLE_OUT` before sampling")

        sample_call_match = re.search(r'\bsample\s+"?\$APP_PID"?\b', self.text)
        self.assertIsNotNone(sample_call_match, "expected a `sample $APP_PID ...` invocation")

        self.assertLess(
            rm_match.start(),
            sample_call_match.start(),
            "the stale sample file must be removed BEFORE the `sample` invocation, "
            "not after",
        )

    def test_does_not_use_the_naive_awk_dash_f_colon_cpu_one_liner(self):
        # Defect: `awk -F: '{print ($1*3600)+($2*60)+$3}'` is the fixed-field
        # mapping that inflated "30:38.67" to 110320 instead of 1838.67.
        self.assertNotIn("awk -F:", self.text)

    def test_cpu_delta_awk_program_does_not_interpolate_shell_values_into_the_body(self):
        # Defect: `awk "BEGIN{printf \"%.2f\", ($T1 - $T0) / 60 * 100}"`
        # interpolates raw shell variables directly into the awk program
        # source. Values must instead be passed in with `-v`, which is both
        # safer (no quoting/injection surprises) and testable in isolation.
        self.assertNotRegex(self.text, r"awk\s+\"BEGIN\{[^}]*\$T1[^}]*\}\"")
        self.assertIn("awk -v", self.text)

    def test_sample_commands_exit_status_is_captured(self):
        # Defect: `sample $APP_PID 5 -file "$SAMPLE_OUT" >/dev/null 2>&1` on
        # its own, as a bare statement, discards the command's exit status,
        # so a failed sample (permissions, no such pid, etc.) was
        # indistinguishable from a successful empty one. The status must be
        # consumed somehow — either fed straight into control flow (`if
        # sample ...; then` / `sample ... && ...`) or captured into a `$?`
        # variable. Either idiom honors it; a bare statement honors neither.
        sample_call = re.search(r'\bsample\s+"?\$APP_PID"?\b.*$', self.text, re.MULTILINE)
        self.assertIsNotNone(sample_call, "expected a `sample $APP_PID ...` invocation")

        line_start = self.text.rfind("\n", 0, sample_call.start()) + 1
        line_end = self.text.find("\n", sample_call.start())
        full_line = self.text[line_start:line_end]
        stripped = full_line.strip()

        feeds_control_flow = (
            stripped.startswith("if ")
            or stripped.startswith("elif ")
            or "&&" in full_line
            or "||" in full_line
        )
        if feeds_control_flow:
            return  # exit status drives an if/&&/||, which is honoring it.

        # Otherwise, a bare statement must still capture $? within the next
        # couple of lines.
        tail = self.text[sample_call.start():]
        nearby_lines = "\n".join(tail.splitlines()[:3])
        self.assertRegex(
            nearby_lines,
            r"=\s*\$\?",
            "expected the `sample` command's exit status to be consumed — either "
            "by driving an if/&&/|| or by capture into a `$?` variable — not "
            "discarded as a bare statement",
        )


def _extract_bash_function(text, name):
    """Pull a single named bash function's source out of a script by
    counting braces, so it can be sourced and exercised in isolation without
    running the rest of the (app-launching) script.
    """
    marker = re.search(rf"\b{re.escape(name)}\s*\(\)\s*\{{", text)
    if not marker:
        return None
    brace_start = text.index("{", marker.start())
    depth = 0
    for i in range(brace_start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[marker.start() : i + 1]
    return None


class ShellScriptCpuGuardDeadPidTests(unittest.TestCase):
    """Exercises the real cpu_seconds() function (extracted from the actual
    script, not reimplemented) against a pid that is guaranteed dead, to
    confirm the NF-aware guard reports an unmeasured (empty) reading with a
    non-zero exit status rather than surfacing an awk arithmetic error.

    This never launches Nostromo.app: it spawns and waits out a `sleep`
    child, then reuses that now-dead pid.
    """

    def test_dead_pid_is_reported_as_unmeasured_not_an_awk_error(self):
        with open(SHELL_SCRIPT_PATH) as handle:
            text = handle.read()
        func_src = _extract_bash_function(text, "cpu_seconds")
        if func_src is None:
            self.skipTest(
                "could not statically extract a cpu_seconds() function from "
                "transcript-load-test.sh to exercise directly; the guard's shape "
                "is instead pinned statically in ShellScriptStaticAssertionTests "
                "(the no-`awk -F:`-one-liner and `awk -v` checks)."
            )

        proc = subprocess.Popen(["sleep", "0.01"])
        dead_pid = proc.pid
        proc.wait()
        # Guard against flakiness: pid reuse on a busy CI box is rare but
        # possible. If the OS handed the pid to something else already,
        # skip rather than report a false result.
        alive_check = subprocess.run(["kill", "-0", str(dead_pid)], capture_output=True)
        if alive_check.returncode == 0:
            self.skipTest(f"pid {dead_pid} was reused by another process before this check ran")

        snippet = f"""
set -uo pipefail
{func_src}
cpu_seconds {dead_pid}
"""
        result = subprocess.run(["bash", "-c", snippet], capture_output=True, text=True)
        self.assertNotEqual(
            result.returncode,
            0,
            f"expected a non-zero exit for a dead pid; got stdout={result.stdout!r} "
            f"stderr={result.stderr!r}",
        )
        self.assertEqual(result.stdout.strip(), "")
        self.assertNotIn("division by zero", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
