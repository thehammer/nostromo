"""Behavioral tests for the transcript-load measurement harness.

These tests exist because the harness itself had criteria that could not
fail — a measurement bug that always reads "PASS" is worse than no
measurement at all, because it tells an operator the system is healthy when
the harness simply forgot to check. Each test below pins one such defect:

  - Part A: macOS/scripts/ps-time-seconds.awk, a `ps -o time=` parser that
    replaces a fixed-field ($1*3600)+($2*60)+$3 mapping that silently
    misreads variable-width `ps` time strings (a 60x inflation on a
    genuinely idle process).
  - Part B: macOS/scripts/transcript-load-report.py's criteria registry.
  - Part C: macOS/scripts/transcript-load-test.sh, static/structural checks
    on the shell driver plus one live exercise of the dead-pid CPU guard.

Part B in detail. Three consecutive independent reviews of the report script
each found *new* instances of one bug — a criterion satisfied by the absence of
the thing it measures — seven in total. The reason review kept finding new ones
is that the tests were hand-written one per criterion: **a criterion nobody
wrote a barren-input test for is a criterion nobody checked.** Writing an
eighth per-criterion test would have bought an eighth criterion's worth of
confidence and nothing more.

So the report script moved the decision to a choke point — a criterion is a
registered function that may only produce a verdict through `graded()` or
`failed()`, and `graded()` is the only path to PASS — and these tests are
parameterised over that registry rather than over a list of today's criteria.
Three universal tests carry the weight:

  - T1a: on input that measured nothing at all, **no** registered criterion
    passes. No exemptions, no allowlist.
  - T1b: on a run with fewer than two distinct samples, no `kind=RUN`
    criterion passes — `graded()`'s two-observation floor, asserted from the
    outside for every row at once.
  - T1c: with its own out-of-band argument absent, no `kind=PROCESS`
    criterion passes.

Each iterates `report.CRITERIA`, so a criterion registered tomorrow is covered
with no new test written. T2 is the mandatory counterpart — every row PASSes on
a healthy fixture — without which T1 would be satisfied by a report that always
FAILs, the same vacuity one level up. T3 pins, per registry key, one mutation
that must flip *that* row, and fails if a key has no entry. T3b declares each
criterion's evidence dependencies — which sources it reads — and asserts them
in both directions: non-PASS when a declared source is missing from an
otherwise healthy run, still PASS when it isn't. T4 reads the script with
`ast` to catch specific literal shapes that hide a missing measurement as a
zero one — `max(..., default=...)` and a two-argument `.get()` with a numeric
fallback — at review time rather than at soak time. T5 pins the registry's
integrity and the exit contract.

Run with:
    /usr/bin/python3 -m unittest discover -s tests/transcript_load
"""

import ast
import contextlib
import copy
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
    run_id="run-A",
):
    """Build a diagnostics-row fixture that satisfies every criterion by
    default. Each test perturbs exactly one keyword to violate exactly one
    criterion — this is the symmetry check that keeps the fixture honest.

    `run_id` stamps every row with a `runID`, because run identity is part of
    what a healthy stream carries: the report scopes its rows to the newest run
    in the file, and a fixture with no identity is a fixture whose freshness
    cannot be established. Pass `run_id=None` to omit the key and get exactly
    that failure.
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
        if run_id is not None:
            row["runID"] = run_id
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


def find_row(verdicts, substring):
    """Look up a Verdict by a stable substring of its name. Fails loudly
    if the row is missing or if the substring is ambiguous — that ambiguity
    check is what makes "the row is present" a real assertion instead of a
    tautology.
    """
    matches = [v for v in verdicts if substring in v.name]
    if len(matches) == 0:
        names = "\n  ".join(v.name for v in verdicts)
        raise AssertionError(
            f"no criterion name contains {substring!r}. Names present:\n  {names}"
        )
    if len(matches) > 1:
        raise AssertionError(
            f"substring {substring!r} matched {len(matches)} criteria, expected exactly 1: "
            f"{[v.name for v in matches]}"
        )
    return matches[0]


def keyed(verdicts):
    """Verdicts by registry key, the identity the tests parameterise over."""
    return {v.key: v for v in verdicts}


def write_lines(lines):
    """Write raw lines to a temp file. Used for streams that must not parse."""
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    with os.fdopen(fd, "w") as handle:
        for line in lines:
            handle.write(line + "\n")
    return path


def write_jsonl(rows):
    return write_lines([json.dumps(row) for row in rows])


def write_text_file(text):
    fd, path = tempfile.mkstemp(suffix=".txt")
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    return path


class _Captured:
    text = ""


@contextlib.contextmanager
def captured_stdout():
    """Capture writes to file descriptor 1, not merely to the name `sys.stdout`.

    `print_report`'s `stream=sys.stdout` default argument is bound once, when
    the module is imported, so `contextlib.redirect_stdout` — which only
    rebinds the name — does not intercept the table at all. Capturing the file
    descriptor catches the output however the writer got hold of the stream,
    which is also what the shell driver reads.
    """
    cap = _Captured()
    sys.stdout.flush()
    saved_fd = os.dup(1)
    tmp = tempfile.TemporaryFile()
    try:
        os.dup2(tmp.fileno(), 1)
        yield cap
        sys.stdout.flush()
        tmp.seek(0)
        cap.text = tmp.read().decode("utf-8", errors="replace")
    finally:
        sys.stdout.flush()
        os.dup2(saved_fd, 1)
        os.close(saved_fd)
        tmp.close()


def run_main_on_path(path, extra_argv=()):
    """Invoke report.main() against `path`, returning (exit_code, stdout)."""
    old_argv = sys.argv
    sys.argv = ["transcript-load-report.py", path, *extra_argv]
    try:
        with captured_stdout() as cap:
            code = report.main()
    finally:
        sys.argv = old_argv
    return code, cap.text


def run_main(rows, extra_argv=()):
    """Invoke report.main() end-to-end against a real temp diagnostics file,
    the way the shell driver does, and return its exit code. stdout is
    swallowed; these tests assert on the return value, not the printed
    table.
    """
    diag_path = write_jsonl(rows)
    try:
        return run_main_on_path(diag_path, extra_argv)[0]
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
# Part B: the criteria registry
# --------------------------------------------------------------------------

# A sample file is only evidence if it looks like `sample(1)` output.
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

#: A sample that carries the incident's own signature inside a real call graph.
SIGNATURE_SAMPLE = GOOD_SAMPLE + "0x1234 CoreAutoLayout + 12\n" * 3


# --------------------------------------------------------------------------
# The barren fixtures the universal tests are parameterised over.
#
# Named so a failure names the fixture: "ONE_SAMPLE_PANES_ALL_ZERO passed
# hot-payload-window" is a bug report, "subTest #3 failed" is not.
# --------------------------------------------------------------------------

#: Nothing was read at all. The single most important input to this report and,
#: until the registry existed, the one it could not be tested against.
EMPTY = []

#: One sample, no panes, past every turn mark the table asks about.
ONE_SAMPLE_NO_PANES = make_rows(n_samples=1, total_turns=6000, include_panes=False)


def _panes_all_zero():
    """One sample whose single pane reported every counter at zero.

    A pane that reported itself with nothing in it is a pane the run never
    drove. This is the same defect one level in: presence read as
    instrumentation, and every number behind the gate a zero nobody measured.
    """
    rows = make_rows(n_samples=1, total_turns=6000, peak_materialized=0,
                     hot_payload_turns=0)
    for pane in rows[0]["panes"]:
        pane["retainedTurns"] = 0
    return rows


ONE_SAMPLE_PANES_ALL_ZERO = _panes_all_zero()

#: One healthy-looking sample sitting past every mark, where
#: `at_turn(rows, 500)` and `at_turn(rows, 5000)` resolve to the same row and
#: the criterion subtracts a measurement from itself.
SINGLE_SAMPLE_PAST_ALL_MARKS = make_rows(n_samples=1, total_turns=6000)

#: The same measurement written twice, identical timestamp and turn count. If
#: duplicates were not collapsed, every two-sample criterion would clear its
#: floor by reading one measurement twice.
DUPLICATED_SAMPLE = (SINGLE_SAMPLE_PAST_ALL_MARKS
                     + copy.deepcopy(SINGLE_SAMPLE_PAST_ALL_MARKS))

#: `evaluate()` kwargs with no out-of-band process measurements at all.
NO_PROCESS_MEASUREMENTS = dict(turns=5000, cpu_percent=None, sample_path=None)


def good_sample_path(tc):
    path = write_text_file(GOOD_SAMPLE)
    tc.addCleanup(os.remove, path)
    return path


def healthy_context(tc):
    """`evaluate()` kwargs for a run whose process measurements both succeeded."""
    return dict(turns=5000, cpu_percent=0.04, sample_path=good_sample_path(tc))


def all_malformed_evidence(tc):
    """A real file of unparseable lines, read through `load()`."""
    path = write_lines(["{not json", "]]]", "sample: could not attach"])
    tc.addCleanup(os.remove, path)
    return report.load(path)


def stale_only_evidence(tc):
    """A complete previous run, then a fresh run of one sample, in one file.

    `diagnostics.jsonl` is append-only across launches. Returning every row
    ever written meant a fresh run of a handful of samples could be graded
    entirely on a previous run's numbers and print PASS on the headline memory
    figure. The previous run here is healthy and reaches turn 5000, so if
    scoping regresses, most of the table goes green on somebody else's run.
    """
    path = write_jsonl(make_rows(run_id="run-old")
                       + make_rows(n_samples=1, total_turns=6000, run_id="run-new"))
    tc.addCleanup(os.remove, path)
    return report.load(path)


def barren_run_fixtures(tc):
    """Every fixture with fewer than two distinct samples of the current run."""
    return [
        ("ONE_SAMPLE_NO_PANES", ONE_SAMPLE_NO_PANES),
        ("ONE_SAMPLE_PANES_ALL_ZERO", ONE_SAMPLE_PANES_ALL_ZERO),
        ("SINGLE_SAMPLE_PAST_ALL_MARKS", SINGLE_SAMPLE_PAST_ALL_MARKS),
        ("DUPLICATED_SAMPLE", DUPLICATED_SAMPLE),
        ("STALE_ONLY", stale_only_evidence(tc)),
    ]


def nothing_measured_fixtures(tc):
    """Fixtures where the run measured nothing whatsoever."""
    return [("EMPTY", EMPTY), ("ALL_MALFORMED", all_malformed_evidence(tc))]


class _VacuityAssertions:
    """The shared assertion body of T1a/T1b/T1c.

    Factored out so `VacuityTestActuallyBitesTests` can prove the mechanism
    bites by running *this* logic against a deliberately vacuous criterion.
    A reimplementation there would prove nothing about the real tests.
    """

    def assert_no_criterion_passes(self, label, subject, *, kinds=None, **kwargs):
        verdicts = report.evaluate(subject, **kwargs)
        rows = keyed(verdicts)
        self.assertEqual(
            set(rows), {reg.key for reg in report.CRITERIA},
            f"[{label}] evaluate() did not return one row per registered criterion",
        )
        offenders = [
            f"{reg.key} (kind={reg.kind}): PASS with observations="
            f"{rows[reg.key].observations} measured={rows[reg.key].measured!r}"
            for reg in report.CRITERIA
            if (kinds is None or reg.kind in kinds) and rows[reg.key].state == report.PASS
        ]
        self.assertEqual(
            offenders, [],
            f"[{label}] criteria passed on input that measured nothing:\n  "
            + "\n  ".join(offenders),
        )


class ModuleConstantsTests(unittest.TestCase):
    """Constants the table's meaning rests on, pinned so a change to any of
    them fails this suite until someone edits the line on purpose.
    """

    def test_materialized_limit_matches_turn_list_virtualizer_max_materialized(self):
        self.assertEqual(report.MATERIALIZED_LIMIT, 60)

    def test_there_are_exactly_three_verdict_states_and_they_are_distinct(self):
        # INCONCLUSIVE exists so the *reason* is legible in the table, not to
        # soften the exit contract. Collapsing it into PASS or dropping it
        # entirely are both changes that must be made deliberately.
        states = [report.PASS, report.FAIL, report.INCONCLUSIVE]
        self.assertEqual(len(set(states)), 3)
        self.assertEqual(states, ["PASS", "FAIL", "INCONCLUSIVE"])

    def test_the_three_kinds_are_the_documented_strings(self):
        self.assertEqual([report.RUN, report.PROCESS, report.STREAM],
                         ["run", "process", "stream"])


class VerdictShapeTests(unittest.TestCase):
    """`Verdict` is the whole contract between a criterion and the table, and
    `.ok` is the whole contract between the table and the shell driver's exit
    status. INCONCLUSIVE being non-passing is the load-bearing half.
    """

    def test_verdict_is_the_documented_namedtuple_shape(self):
        verdicts = report.evaluate(make_rows(), **healthy_context(self))
        first = verdicts[0]
        self.assertIsInstance(first, report.Verdict)
        self.assertEqual(
            list(report.Verdict._fields),
            ["key", "name", "state", "measured", "limit", "observations"],
        )
        self.assertIsInstance(first.key, str)
        self.assertIsInstance(first.name, str)
        self.assertIsInstance(first.state, str)
        self.assertIsInstance(first.measured, str)
        self.assertIsInstance(first.limit, str)
        self.assertIsInstance(first.observations, int)

    def test_ok_is_true_only_for_pass_so_inconclusive_is_non_passing(self):
        def verdict(state):
            return report.Verdict(key="k", name="n", state=state, measured="m",
                                  limit="l", observations=0)

        self.assertTrue(verdict(report.PASS).ok)
        self.assertFalse(verdict(report.FAIL).ok)
        self.assertFalse(verdict(report.INCONCLUSIVE).ok)

    def test_graded_requires_two_observations_by_default_and_never_consults_ok_below_it(self):
        # The choke point itself, exercised the way a criterion body reaches
        # it: with `required` left unstated. Two is not an incidental default —
        # a criterion that declares nothing about how many points it needs gets
        # the strictest treatment, because the overwhelming majority of these
        # rows claim something about the run, and none of those claims is
        # observable from a single point. However confidently `ok` is set, one
        # observation cannot produce a PASS.
        one = report.graded("k", "n", observations=1, ok=True, measured="m", limit="l")
        self.assertEqual(one.state, report.INCONCLUSIVE)
        two = report.graded("k", "n", observations=2, ok=True, measured="m", limit="l")
        self.assertEqual(two.state, report.PASS)


class CriterionKindPartitionTests(unittest.TestCase):
    """The kind partition is the *only* exemption from the universal barren-run
    test, and it is pinned here exactly, in the same spirit as
    `MATERIALIZED_LIMIT`.

    `STREAM` is two rows wide and `PROCESS` is two more. A `STREAM` criterion
    may pass on a file holding one clean line, because "this file parses" is a
    true statement about a one-line file; a `PROCESS` criterion grades an
    argument handed in on the command line rather than the run's samples. Every
    other row claims something about the run — a delta, a slope, a peak, an
    agreement, the absence of an event *during* the run — and none of those is
    observable from a single point.

    `RUN` is the default, so a criterion registered without thinking about its
    kind is covered by T1b automatically. Moving a criterion *out* of `RUN`
    grants it an exemption from that test, and must fail here until someone
    edits the line below on purpose.
    """

    def test_stream_criteria_are_exactly_the_two_that_grade_the_file_itself(self):
        self.assertEqual(
            {reg.key for reg in report.CRITERIA if reg.kind == report.STREAM},
            {"stream-parses-cleanly", "samples-are-from-this-run"},
        )

    def test_process_criteria_are_exactly_the_two_out_of_band_measurements(self):
        self.assertEqual(
            {reg.key for reg in report.CRITERIA if reg.kind == report.PROCESS},
            {"idle-cpu", "no-coreautolayout-frames"},
        )

    def test_every_registered_kind_is_one_of_the_three(self):
        allowed = {report.RUN, report.PROCESS, report.STREAM}
        strays = [(reg.key, reg.kind) for reg in report.CRITERIA if reg.kind not in allowed]
        self.assertEqual(strays, [], f"criteria with an unknown kind: {strays}")

    def test_run_is_the_default_kind(self):
        @report.criterion("kind-default-probe", limit="probe")
        def _probe(ev):                                            # pragma: no cover
            return report.failed("kind-default-probe", "probe", measured="m",
                                 limit="probe")

        try:
            self.assertEqual(report.registration("kind-default-probe").kind, report.RUN)
        finally:
            report.CRITERIA.remove(report.registration("kind-default-probe"))


class UniversalVacuityTests(_VacuityAssertions, unittest.TestCase):
    """T1, the deliverable. Every assertion here iterates `report.CRITERIA`, so
    a criterion added tomorrow is covered without anyone writing a test.

    The seven historical defects were seven spellings of one sentence: the
    criterion was satisfied by the absence of the thing it measures. New
    instances kept surfacing because the tests were one per criterion — a
    criterion nobody wrote a barren-input test for is a criterion nobody
    checked. These tests remove the "nobody wrote one" step.
    """

    def test_no_criterion_passes_when_nothing_was_measured(self):
        # T1a. No exemptions and no allowlist: on input that measured nothing,
        # a PASS is wrong no matter which row prints it or what kind it is.
        for label, subject in nothing_measured_fixtures(self):
            with self.subTest(fixture=label):
                self.assert_no_criterion_passes(label, subject,
                                                **NO_PROCESS_MEASUREMENTS)

    def test_no_run_criterion_passes_on_a_barren_run(self):
        # T1b. Run against both process-measurement contexts, because a
        # successful `sample(1)` and a plausible idle-CPU figure must not lend
        # any credibility to a row that grades the run's own samples.
        contexts = [
            ("no process measurements", NO_PROCESS_MEASUREMENTS),
            ("with process measurements", healthy_context(self)),
        ]
        for label, subject in barren_run_fixtures(self):
            for context_label, kwargs in contexts:
                with self.subTest(fixture=label, context=context_label):
                    self.assert_no_criterion_passes(
                        f"{label} / {context_label}", subject,
                        kinds={report.RUN}, **kwargs)

    def test_a_stale_run_is_scoped_out_before_the_criteria_ever_see_it(self):
        # The precondition STALE_ONLY rests on: if `load()` stopped scoping to
        # the newest run, the fixture above would silently become a healthy
        # 27-sample run and T1b would pass while measuring nothing.
        ev = stale_only_evidence(self)
        self.assertEqual(len(ev.rows), 1)
        self.assertTrue(ev.other_runs, "the earlier run was not separated out")
        self.assertEqual(ev.run_id, "run-new")

    def test_one_measurement_written_twice_does_not_clear_the_two_sample_floor(self):
        # The precondition DUPLICATED_SAMPLE rests on. Collapsing duplicates
        # once in load()/from_rows() is what stops a criterion counting rows
        # from satisfying `required=2` by reading a single measurement twice.
        ev = report.Evidence.from_rows(DUPLICATED_SAMPLE)
        self.assertEqual(len(DUPLICATED_SAMPLE), 2)
        self.assertEqual(len(ev.rows), 1)
        self.assertEqual(ev.duplicates, 1)

    def test_process_criteria_fail_when_their_own_input_is_absent(self):
        # T1c. The run itself is entirely healthy — 26 samples, every counter
        # present — so nothing here excuses a row whose own argument is
        # missing. Both of these used to be emitted only when their argument
        # was present, so a failed measurement removed the criterion carrying
        # the incident's own signature from the table.
        self.assert_no_criterion_passes(
            "HEALTHY_26_SAMPLES", make_rows(), kinds={report.PROCESS},
            **NO_PROCESS_MEASUREMENTS)


class VacuityTestActuallyBitesTests(_VacuityAssertions, unittest.TestCase):
    """Proof that T1 is not itself vacuous.

    A universal test over a registry is only worth what it catches. This
    registers a criterion of exactly the shape the seven defects had — a PASS
    asserted on input that measured nothing — and runs the *same* assertion
    body T1a and T1b run against it, expecting that body to fail. If T1's
    logic is ever weakened into something that cannot object, this test starts
    failing first.
    """

    def _register_vacuous_criterion(self):
        saved = report.CRITERIA[:]
        self.addCleanup(report.CRITERIA.__setitem__, slice(None), saved)

        @report.criterion("always-passes", limit="nothing at all")
        def _always_passes(ev):
            return report.graded(
                "always-passes", "a criterion that measures nothing",
                observations=2, ok=True,
                measured="claimed two observations it never made",
                limit="nothing at all")

    def test_a_criterion_that_cannot_fail_is_caught_on_input_that_measured_nothing(self):
        self._register_vacuous_criterion()
        with self.assertRaises(self.failureException) as caught:
            self.assert_no_criterion_passes("EMPTY", EMPTY, **NO_PROCESS_MEASUREMENTS)
        self.assertIn("always-passes", str(caught.exception))

    def test_a_criterion_that_cannot_fail_is_caught_on_a_barren_run(self):
        self._register_vacuous_criterion()
        with self.assertRaises(self.failureException) as caught:
            self.assert_no_criterion_passes(
                "SINGLE_SAMPLE_PAST_ALL_MARKS", SINGLE_SAMPLE_PAST_ALL_MARKS,
                kinds={report.RUN}, **NO_PROCESS_MEASUREMENTS)
        self.assertIn("always-passes", str(caught.exception))

    def test_the_registry_is_restored_between_tests(self):
        # The two tests above mutate module state. If cleanup ever stopped
        # working, every other test in this file would start grading a
        # criterion that always passes, and the suite would go quietly green.
        self.assertNotIn("always-passes", [reg.key for reg in report.CRITERIA])


class EvaluateKnownGoodRunTests(unittest.TestCase):
    """T2, and it is mandatory rather than a nicety.

    Without it, every T1 assertion above is satisfiable by a report in which
    every criterion always FAILs — a vacuous test of a vacuous report, the same
    bug one level up. If the fixture below is genuinely good, every registered
    row must PASS.
    """

    def test_every_criterion_passes_on_a_well_behaved_run(self):
        verdicts = report.evaluate(make_rows(), **healthy_context(self))
        rows = keyed(verdicts)

        self.assertEqual(set(rows), {reg.key for reg in report.CRITERIA})
        not_passing = [
            f"{reg.key}: {rows[reg.key].state} measured={rows[reg.key].measured!r}"
            for reg in report.CRITERIA if rows[reg.key].state != report.PASS
        ]
        self.assertEqual(
            not_passing, [],
            "a healthy run must pass every row, or T1 is satisfied by a report "
            "that always fails:\n  " + "\n  ".join(not_passing),
        )

    def test_main_exits_zero_on_a_well_behaved_run(self):
        sample_path = good_sample_path(self)
        exit_code = run_main(make_rows(),
                             ["--cpu-percent", "0.04", "--sample", sample_path])
        self.assertEqual(exit_code, 0)


# --------------------------------------------------------------------------
# T3: per-criterion sensitivity.
#
# One mutation per registry key, each of which must flip *that* row off PASS.
# The table is checked against the registry, so registering a criterion without
# a sensitivity entry fails the test — that is what closes "a criterion nobody
# proved can fail".
#
# Each builder returns (subject, kwargs-overrides applied to healthy_context).
# --------------------------------------------------------------------------


def mutate_footprint_grows_past_budget(tc):
    """Headline memory number blows the 250 MB budget between the turn marks."""
    return make_rows(footprint_end=700.0), {}


def mutate_steep_second_half(tc):
    """Second-half least-squares slope far above 20 MB / 1000 turns."""
    return make_rows(footprint_end=800.0), {}


def mutate_materialization_grows_with_session_length(tc):
    """The last sample's pane materialized more views than the turn-100 sample."""
    rows = make_rows()
    rows[-1]["panes"][0]["materializedViews"] = 43
    return rows, {}


def mutate_peak_above_documented_cap(tc):
    """One view past the hardcoded cap. Deliberately equal in both samples, so
    the turn-100-vs-late row still passes and only the peak row moves."""
    return make_rows(peak_materialized=61), {}


def mutate_disagreeing_view_caps(tc):
    """Half the samples report a different cap. `max()` over disagreeing
    samples let the run pass on the maximum while demonstrably running
    with a different cap for part of it."""
    rows = make_rows()
    for i in range(0, len(rows), 2):
        rows[i]["maxMaterializedPerPane"] = 30
    return rows, {}


def mutate_harness_drove_fewer_panes_than_requested(tc):
    """The harness asked for eight focuses and reached one."""
    return make_rows(harness_targeted_panes=1, harness_requested_focuses=8), {}


def mutate_hot_window_unbounded(tc):
    """Twice the hot window the retention policy allows."""
    return make_rows(hot_payload_turns=400), {}


def mutate_transcript_cleared(tc):
    """A pane emptied its own transcript mid-run."""
    return make_rows(transcript_clears=1), {}


def mutate_retained_turns_drop(tc):
    """A pane's retained turn count went backwards below the retention cap."""
    rows = make_rows()
    rows[-1]["panes"][0]["retainedTurns"] = 5
    return rows, {}


def mutate_throughput_collapses(tc):
    """Per-delta cost grows with session length: the second half of the run
    takes twelve times as long per sample as the first."""
    rows = make_rows()
    half = len(rows) // 2
    for i, row in enumerate(rows):
        if i >= half:
            row["timestamp"] = _iso(_BASE_TIME + datetime.timedelta(
                seconds=5 * half + 60 * (i - half)))
    return rows, {}


def mutate_idle_cpu_burning(tc):
    """Nine percent of a core across a minute of doing nothing."""
    return make_rows(), {"cpu_percent": 9.0}


def mutate_sample_carries_signature_frames(tc):
    """A real call graph holding the incident's own signature."""
    path = write_text_file(SIGNATURE_SAMPLE)
    tc.addCleanup(os.remove, path)
    return make_rows(), {"sample_path": path}


def mutate_malformed_line_mid_stream(tc):
    """A torn line in the middle of the file, read through `load()`.

    Every other number in the table came out of the same file, so a writer or
    reader broken partway through invalidates the table rather than one row.
    """
    lines = [json.dumps(row) for row in make_rows()]
    lines.insert(len(lines) // 2, "{ this line was never valid")
    path = write_lines(lines)
    tc.addCleanup(os.remove, path)
    return report.load(path), {}


def mutate_samples_carry_no_run_identity(tc):
    """No `runID` anywhere: the report cannot establish whose run this is."""
    return make_rows(run_id=None), {}


#: registry key -> a mutation of the good fixture that must flip that row.
SENSITIVITY = {
    "footprint-delta": mutate_footprint_grows_past_budget,
    "memory-slope": mutate_steep_second_half,
    "materialized-at-100-vs-late": mutate_materialization_grows_with_session_length,
    "materialized-peak": mutate_peak_above_documented_cap,
    "documented-view-cap": mutate_disagreeing_view_caps,
    "harness-targeting": mutate_harness_drove_fewer_panes_than_requested,
    "hot-payload-window": mutate_hot_window_unbounded,
    "transcript-never-cleared": mutate_transcript_cleared,
    "retained-turns-monotonic": mutate_retained_turns_drop,
    "per-delta-cost-flat": mutate_throughput_collapses,
    "idle-cpu": mutate_idle_cpu_burning,
    "no-coreautolayout-frames": mutate_sample_carries_signature_frames,
    "stream-parses-cleanly": mutate_malformed_line_mid_stream,
    "samples-are-from-this-run": mutate_samples_carry_no_run_identity,
}


class CriterionSensitivityTests(unittest.TestCase):
    """T3: every row must be provably able to fail, one keyed mutation each.

    T1 proves no row passes on nothing; T2 proves every row passes on a healthy
    run. Neither proves a row responds to *its own* subject going wrong — a row
    hardwired to the fixture's shape would satisfy both. The table is asserted
    against the registry, so a criterion registered without a sensitivity entry
    fails this test rather than joining the table unproven.
    """

    def test_every_registered_criterion_has_a_sensitivity_case(self):
        self.assertEqual(
            set(SENSITIVITY), {reg.key for reg in report.CRITERIA},
            "every criterion must be paired with a mutation that flips it; "
            "a criterion nobody proved can fail is the defect this file exists "
            "to close",
        )

    def test_each_mutation_flips_its_own_criterion_off_pass(self):
        for key, build in SENSITIVITY.items():
            with self.subTest(criterion=key, mutation=build.__name__):
                subject, overrides = build(self)
                kwargs = healthy_context(self)
                kwargs.update(overrides)
                row = keyed(report.evaluate(subject, **kwargs))[key]
                self.assertNotEqual(
                    row.state, report.PASS,
                    f"{key} still passed after {build.__name__}: {row}",
                )

    def test_a_torn_final_line_does_not_fail_the_stream(self):
        # The qualifier that keeps the rule above precise: the app is still
        # writing while the driver reads, so exactly one malformed line at the
        # end of the file is legitimate and expected. A rule that false-failed
        # here would be turned off, and then nothing would check parse losses.
        lines = [json.dumps(row) for row in make_rows()]
        lines.append("{ torn while being writ")
        path = write_lines(lines)
        self.addCleanup(os.remove, path)

        row = keyed(report.evaluate(report.load(path), **healthy_context(self)))[
            "stream-parses-cleanly"]
        self.assertEqual(row.state, report.PASS, row)
        self.assertIn("torn", row.measured)

    def test_turns_going_backwards_within_one_run_fails_the_identity_row(self):
        # Two processes appending to the same path within one run: the run id
        # agrees, but the turn counter does not advance monotonically.
        rows = make_rows()
        rows[10]["turnsProcessed"], rows[11]["turnsProcessed"] = (
            rows[11]["turnsProcessed"], rows[10]["turnsProcessed"])

        row = keyed(report.evaluate(rows, **healthy_context(self)))[
            "samples-are-from-this-run"]
        self.assertEqual(row.state, report.FAIL)
        self.assertIn("decreased", row.measured)

    def test_a_stale_earlier_run_in_the_same_file_fails_the_identity_row(self):
        row = keyed(report.evaluate(stale_only_evidence(self),
                                    **healthy_context(self)))[
            "samples-are-from-this-run"]
        self.assertEqual(row.state, report.FAIL)
        self.assertIn("earlier run", row.measured)

    def test_sample_containing_either_signature_frame_fails_and_counts_them(self):
        # Both tokens, and the count, because the fixture must fail for
        # carrying the incident's signature rather than for having no call
        # graph — otherwise this silently stops testing what it claims to.
        for token in ("CoreAutoLayout", "NSISEngine"):
            with self.subTest(token=token):
                sample_path = write_text_file(GOOD_SAMPLE + f"0x1234 {token} + 12\n" * 3)
                self.addCleanup(os.remove, sample_path)
                verdicts = report.evaluate(
                    make_rows(), turns=5000, cpu_percent=0.04, sample_path=sample_path)
                row = find_row(verdicts, "CoreAutoLayout")
                self.assertFalse(row.ok)
                self.assertIn("3 frames", row.measured)


# --------------------------------------------------------------------------
# T3b: what each criterion reads, and what happens when the run does not
# report it.
#
# T1b covers a run with too few samples. It does not cover the shape that a
# criterion silently ignoring its own missing evidence can have: a long,
# healthy, 26-sample run — clean footprint curve, plausible throughput, every
# turn mark reached — that simply never reported the thing one criterion
# measures. `graded()`'s two-observation floor is no help there, because such
# a criterion can truthfully count 26 samples while having read zero panes;
# `max(..., default=0)` did exactly that and printed PASS in the middle of an
# otherwise green table.
#
# So each criterion declares the evidence it reads, and the declaration is
# checked in both directions: every criterion that depends on a source must be
# non-PASS when the run omits it, and every criterion that does not must still
# PASS. The second half is what stops the declaration being gamed by naming
# everything. And a pinned exemption list is what stops it being gamed by
# naming *nothing*, which is a stronger loophole than naming everything
# because it silences one test and conscripts the other into demanding a PASS.
# --------------------------------------------------------------------------


def _rows_without(field):
    rows = make_rows()
    for row in rows:
        del row[field]
    return rows


def absence_fixtures(tc):
    """(evidence source, subject, kwargs) — one run per thing a run can omit."""
    return [
        ("panes", make_rows(include_panes=False), healthy_context(tc)),
        ("harness self-report", make_rows(include_harness_fields=False),
         healthy_context(tc)),
        ("transcriptClears", make_rows(include_transcript_clears=False),
         healthy_context(tc)),
        ("maxMaterializedPerPane", _rows_without("maxMaterializedPerPane"),
         healthy_context(tc)),
        ("physFootprintMB", _rows_without("physFootprintMB"), healthy_context(tc)),
        ("timestamp", _rows_without("timestamp"), healthy_context(tc)),
        ("runID", make_rows(run_id=None), healthy_context(tc)),
        ("cpu_percent", make_rows(),
         dict(healthy_context(tc), cpu_percent=None)),
        ("sample_path", make_rows(), dict(healthy_context(tc), sample_path=None)),
    ]

#: registry key -> the evidence sources above that criterion reads.
EVIDENCE_DEPENDENCIES = {
    "samples-are-from-this-run": {"runID"},
    "stream-parses-cleanly": set(),
    "footprint-delta": {"physFootprintMB"},
    "memory-slope": {"physFootprintMB"},
    "materialized-at-100-vs-late": {"panes"},
    "materialized-peak": {"panes"},
    "documented-view-cap": {"maxMaterializedPerPane"},
    "harness-targeting": {"panes", "harness self-report"},
    "hot-payload-window": {"panes"},
    "transcript-never-cleared": {"panes", "transcriptClears"},
    "retained-turns-monotonic": {"panes"},
    "per-delta-cost-flat": {"timestamp"},
    "idle-cpu": {"cpu_percent"},
    "no-coreautolayout-frames": {"sample_path"},
}

#: The criteria that legitimately read no evidence source above, pinned exactly
#: so the set cannot widen without someone editing this line on purpose.
#:
#: `stream-parses-cleanly` grades the *file* — whether the lines it holds parse —
#: which is a property of the stream itself and not of any field inside a sample,
#: so there is nothing above for it to name. Its barren case is T1a's: an empty,
#: absent or entirely unparseable file, where it too is non-passing.
#:
#: Every other row reads at least one thing a run can fail to report, and an
#: empty declaration for such a row is invisible to both directional tests below:
#: the "must not pass" half never selects it (no source is ever in an empty set)
#: and the "must keep grading" half then *requires* it to PASS on all nine
#: absence fixtures. That is exactly the escape route a criterion whose
#: degenerate default reads as a real measurement would take: declare nothing,
#: PASS on a healthy 26-sample run that never reported its field.
EMPTY_DEPENDENCY_EXEMPTIONS = {"stream-parses-cleanly"}


class _EvidenceDependencyAssertions:
    """The assertion body of the declaration guard, factored out so
    `EvidenceDependencyDeclarationBitesTests` can prove it bites by running
    *this* logic against a criterion that declares nothing. A reimplementation
    there would prove nothing about the real test.
    """

    def assert_only_exempt_criteria_declare_nothing(self, dependencies, exemptions):
        declared_nothing = {reg.key for reg in report.CRITERIA
                            if not dependencies.get(reg.key)}
        unexempted = sorted(declared_nothing - exemptions)
        stale = sorted(exemptions - declared_nothing)
        self.assertEqual(
            declared_nothing, exemptions,
            "\n".join(
                [f"declares no evidence and is not exempt: {key}" for key in unexempted]
                + [f"exempt but now declares evidence (drop the exemption): {key}"
                   for key in stale]
            ) or "the exemption set no longer matches the criteria registry",
        )


class CriterionEvidenceDependencyTests(_EvidenceDependencyAssertions, unittest.TestCase):
    """Every criterion names the evidence it reads, and is held to it.

    A criterion that keeps grading after the run stopped reporting its subject
    is grading nothing — the recurrence class this whole file exists for. A
    criterion that stops grading when some *unrelated* field goes missing is
    over-coupled, and will false-fail a run that is fine, which is how a check
    gets switched off. Three directions are asserted below: a criterion must
    not pass when the run omits evidence it declares reading; it must keep
    grading when evidence it does not read is absent; and it must name at
    least one evidence source unless it is on the pinned exemption list, since
    an empty declaration is answerable to neither of the first two tests.
    """

    def test_every_registered_criterion_declares_the_evidence_it_reads(self):
        self.assertEqual(
            set(EVIDENCE_DEPENDENCIES), {reg.key for reg in report.CRITERIA},
            "a criterion that has not said what it reads cannot be held to "
            "reading it",
        )

    def test_declared_sources_are_sources_the_fixtures_can_actually_remove(self):
        known = {source for source, _, _ in absence_fixtures(self)}
        declared = set().union(*EVIDENCE_DEPENDENCIES.values())
        self.assertEqual(declared - known, set(),
                         "declared an evidence source no fixture withholds")

    def test_a_criterion_does_not_pass_when_the_run_omits_what_it_reads(self):
        for source, subject, kwargs in absence_fixtures(self):
            verdicts = keyed(report.evaluate(subject, **kwargs))
            for reg in report.CRITERIA:
                if source not in EVIDENCE_DEPENDENCIES[reg.key]:
                    continue
                with self.subTest(missing=source, criterion=reg.key):
                    self.assertNotEqual(
                        verdicts[reg.key].state, report.PASS,
                        f"{reg.key} passed on a run that never reported "
                        f"{source}: {verdicts[reg.key]}",
                    )

    def test_a_criterion_keeps_grading_when_evidence_it_does_not_read_is_absent(self):
        for source, subject, kwargs in absence_fixtures(self):
            verdicts = keyed(report.evaluate(subject, **kwargs))
            for reg in report.CRITERIA:
                if source in EVIDENCE_DEPENDENCIES[reg.key]:
                    continue
                with self.subTest(missing=source, criterion=reg.key):
                    self.assertEqual(
                        verdicts[reg.key].state, report.PASS,
                        f"{reg.key} stopped grading a healthy run because "
                        f"{source} was absent, which it does not read: "
                        f"{verdicts[reg.key]}",
                    )

    def test_only_the_pinned_exemption_declares_no_evidence_at_all(self):
        # The third direction, and the one the two above cannot cover. An empty
        # declaration is not "reads nothing", it is "answerable to nothing":
        # both tests above skip it, so the criterion is held to no absence
        # fixture at all while still being required to PASS on every one.
        self.assert_only_exempt_criteria_declare_nothing(
            EVIDENCE_DEPENDENCIES, EMPTY_DEPENDENCY_EXEMPTIONS)


class EvidenceDependencyDeclarationBitesTests(_EvidenceDependencyAssertions,
                                              unittest.TestCase):
    """Proof that the declaration guard is not itself vacuous.

    Registers a criterion with a degenerate-default shape — `max(vals) if vals
    else 0`, a default read as a real measurement — declaring the empty
    set, and runs the *same* assertion body the real test runs, expecting it to
    object. If the guard is ever weakened into something that cannot, this test
    starts failing first.

    The spelling is deliberate. `pane.get(field, 0)` and `max(..., default=0)`
    are both caught by T4's AST checks; `max(vals) if vals else 0` walks past
    them, which is why the behavioural net underneath has to hold.
    """

    KEY = "compressed-payload-bounded"

    def _register_criterion_that_declares_nothing(self):
        saved = report.CRITERIA[:]
        self.addCleanup(report.CRITERIA.__setitem__, slice(None), saved)

        @report.criterion(self.KEY, limit="<= 999 bytes")
        def _bounded(ev):
            vals = [pane["compressedPayloadBytes"]
                    for row in ev.rows for pane in row.get("panes", ())
                    if "compressedPayloadBytes" in pane]
            worst = max(vals) if vals else 0
            return report.graded(
                self.KEY, "compressed payload stays bounded",
                observations=len(ev.rows), ok=worst <= 999,
                measured=f"worst {worst} bytes", limit="<= 999 bytes")

        return dict(EVIDENCE_DEPENDENCIES, **{self.KEY: set()})

    def test_a_criterion_declaring_the_empty_set_is_rejected(self):
        dependencies = self._register_criterion_that_declares_nothing()
        with self.assertRaises(self.failureException) as caught:
            self.assert_only_exempt_criteria_declare_nothing(
                dependencies, EMPTY_DEPENDENCY_EXEMPTIONS)
        self.assertIn(self.KEY, str(caught.exception))

    def test_the_only_way_to_silence_it_is_a_visible_edit_to_the_pinned_set(self):
        # The escape hatch exists and is deliberately loud: naming the criterion
        # in the exempt set is the one move that satisfies the guard, and it is
        # an edit to a pinned literal that a reviewer sees in the diff, not an
        # omission that nobody notices.
        dependencies = self._register_criterion_that_declares_nothing()
        self.assert_only_exempt_criteria_declare_nothing(
            dependencies, EMPTY_DEPENDENCY_EXEMPTIONS | {self.KEY})

    def test_such_a_criterion_passes_a_healthy_run_that_never_reported_its_field(self):
        # Why the pin earns its place. This is not endorsing the PASS — it pins
        # the damage an empty declaration buys: 26 samples, every other counter
        # present, panes never reported, and the row reads PASS off a default it
        # mistook for a measurement. Both directional tests above are silent
        # here, which is the whole finding.
        self._register_criterion_that_declares_nothing()
        row = keyed(report.evaluate(make_rows(include_panes=False),
                                    **healthy_context(self)))[self.KEY]
        self.assertEqual(row.state, report.PASS)
        self.assertEqual(row.observations, 26)


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
        criteria = report.evaluate(rows, **healthy_context(self))

        peak_row = find_row(criteria, "materializedViews peak")
        self.assertFalse(peak_row.ok)
        self.assertNotIn("500", peak_row.limit)

        bound_row = find_row(criteria, "documented view cap")
        self.assertFalse(bound_row.ok)


class EvaluateNoPanesTests(unittest.TestCase):
    """Pins: peak() used default=0, so a run that recorded zero panes
    printed 'PASS 0 vs 0'. A peak of 0 must now be a failure — it means the
    harness measured nothing, not that materialization stayed low.

    Distinct from the barren fixtures in T1: this is a *long, healthy-looking*
    run — 26 samples, a clean footprint curve, a plausible throughput — that
    simply never reported a pane. Every view-layer row above it would otherwise
    pass by vacuum in the middle of an otherwise green table.
    """

    def test_run_with_no_panes_fails_the_materialized_view_criterion(self):
        criteria = report.evaluate(make_rows(include_panes=False),
                                   **healthy_context(self))
        peak_row = find_row(criteria, "materializedViews peak")
        self.assertFalse(peak_row.ok)

    def test_run_with_no_panes_fails_hot_payload_window_bounded(self):
        # Hot payload window bounded used `max(..., default=0)`, so a
        # run with zero panes measured 0 <= 210 and PASSed. Absence of a
        # measurement is not evidence the window is bounded.
        criteria = report.evaluate(make_rows(include_panes=False),
                                   **healthy_context(self))
        row = find_row(criteria, "hot payload window bounded")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "no panes reported — nothing was measured")

    def test_run_with_no_panes_fails_retained_turns_monotonic(self):
        # Retained turns monotonic tracked worst_drop starting at 0 and
        # never observed a pane, so a run that measured nothing PASSed with
        # "largest drop: 0 turns". No pane observed is not "never dropped".
        criteria = report.evaluate(make_rows(include_panes=False),
                                   **healthy_context(self))
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
        criteria = report.evaluate(make_rows(total_turns=50, n_samples=6),
                                   **healthy_context(self))
        row = find_row(criteria, "materializedViews at turn 100")
        self.assertFalse(row.ok)
        self.assertIn("50", row.measured)


class EvaluateIdleCpuUnmeasuredTests(unittest.TestCase):
    """Pins: the idle-CPU row was conditional on `args.cpu_percent is not
    None` — when the sample failed, the incident's own signature criterion
    silently vanished instead of failing. It must always be emitted.
    """

    def test_unmeasured_cpu_yields_a_failing_row_not_an_absent_one(self):
        criteria = report.evaluate(make_rows(), turns=5000, cpu_percent=None,
                                   sample_path=good_sample_path(self))
        row = find_row(criteria, "idle CPU")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not measured")

    def test_a_wedged_process_burning_no_cpu_at_all_fails_rather_than_passes(self):
        # A measured 0.00 % is not the best possible result, it is a different
        # failure: an app that burned no CPU across a full minute while
        # allegedly running a 5,000-turn harness is wedged, not efficient.
        criteria = report.evaluate(make_rows(), turns=5000, cpu_percent=0.0,
                                   sample_path=good_sample_path(self))
        row = find_row(criteria, "idle CPU")
        self.assertEqual(row.state, report.FAIL)


class EvaluateSampleUnmeasuredTests(unittest.TestCase):
    """Pins: the CoreAutoLayout/NSISEngine sample row was conditional on
    `args.sample and os.path.exists(args.sample)` — a missing or failed
    sample silently dropped the incident's signature criterion. It must
    always be emitted, failing when unmeasured.
    """

    def test_sample_path_of_none_yields_a_failing_row(self):
        criteria = report.evaluate(make_rows(), turns=5000, cpu_percent=0.04,
                                   sample_path=None)
        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not measured")

    def test_nonexistent_sample_path_yields_a_failing_row(self):
        missing_path = "/tmp/nostromo-transcript-sample-does-not-exist-redd.txt"
        self.assertFalse(os.path.exists(missing_path))
        criteria = report.evaluate(make_rows(), turns=5000, cpu_percent=0.04,
                                   sample_path=missing_path)
        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not measured")


class EvaluateHarnessTargetingTests(unittest.TestCase):
    """harnessTargetedPanes must be present, > 0, and equal
    harnessRequestedFocuses — proof the harness actually drove the number of
    panes it meant to, not just that panes existed. The targeted-below-
    requested case lives in the T3 table; these are the cases that table does
    not carry.
    """

    def test_field_absent_fails(self):
        criteria = report.evaluate(make_rows(include_harness_fields=False),
                                   **healthy_context(self))
        row = find_row(criteria, "harnessTargetedPanes")
        self.assertFalse(row.ok)

    def test_zero_targeted_panes_fails(self):
        criteria = report.evaluate(
            make_rows(harness_targeted_panes=0, harness_requested_focuses=0),
            **healthy_context(self))
        row = find_row(criteria, "harnessTargetedPanes")
        self.assertFalse(row.ok)

    def test_targeted_panes_equal_requested_focuses_passes(self):
        criteria = report.evaluate(
            make_rows(harness_targeted_panes=8, harness_requested_focuses=8),
            **healthy_context(self))
        row = find_row(criteria, "harnessTargetedPanes")
        self.assertTrue(row.ok)


class EvaluateSingleSampleTests(unittest.TestCase):
    """A run that only ever produced one diagnostics sample is
    the sharpest version of "comparison against yourself always passes" —
    every two-point comparison (throughput curve, footprint delta between
    two turn marks, materializedViews at turn 100 vs the last sample)
    degenerates to comparing a sample to itself. None of these are
    measurements; all three must fail and say so.

    T1b asserts no RUN row passes here. These pin the *text*, because the
    table's whole job is telling an operator which of "we did not measure it"
    and "we measured it and it is bad" they are looking at.
    """

    def test_single_sample_run_fails_per_delta_cost_flat(self):
        criteria = report.evaluate(make_rows(n_samples=1, total_turns=5000),
                                   **healthy_context(self))
        row = find_row(criteria, "per-delta cost flat in session length")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "insufficient samples")

    def test_single_sample_run_fails_footprint_delta(self):
        criteria = report.evaluate(make_rows(n_samples=1, total_turns=5000),
                                   **healthy_context(self))
        row = find_row(criteria, "footprint delta turn-500")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "only one sample covers both marks")

    def test_single_sample_run_fails_materialized_views_at_turn_100(self):
        criteria = report.evaluate(make_rows(n_samples=1, total_turns=5000),
                                   **healthy_context(self))
        row = find_row(criteria, "materializedViews at turn 100")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "only one sample covers turn 100 and turn 5000")


class EvaluateAbortedRunMaterializedViewTests(unittest.TestCase):
    """Distinct from EvaluateSingleSampleTests above: this is the
    realistic version of the defect, not an exotic edge case. A run that
    died right after turn 100 — two samples, the second already past 100 —
    hits the exact same self-comparison bug with no contrived input at all.
    If this needs a fix separate from the single-sample case, that's the
    signal the single-sample fix was too narrow.
    """

    def test_run_that_dies_just_after_turn_100_fails_the_comparison(self):
        criteria = report.evaluate(make_rows(n_samples=2, total_turns=400),
                                   turns=400, cpu_percent=0.04,
                                   sample_path=good_sample_path(self))
        row = find_row(criteria, "materializedViews at turn 100")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "only one sample covers turn 100 and turn 400")


class EvaluateViewCapMixedReportingTests(unittest.TestCase):
    """The view-cap criterion used `max(reported) == MATERIALIZED_LIMIT`,
    so a run where most samples reported the cap correctly but some reported
    something else (a mid-run config change, a stale build) PASSed as long as
    the maximum happened to equal 60. Every sample must agree.

    The mutation itself is the T3 table's `documented-view-cap` entry; what is
    added here is the exact text, which has to name both values for the table
    to be actionable.
    """

    def test_disagreeing_reported_caps_fail_and_name_both_values(self):
        rows, _ = mutate_disagreeing_view_caps(self)
        criteria = report.evaluate(rows, **healthy_context(self))
        row = find_row(criteria, "documented view cap")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "[30, 60]")

    def test_uniform_reported_cap_still_passes(self):
        # The fix must not make this row impossible to pass — a genuinely
        # uniform, correct run still needs to PASS.
        criteria = report.evaluate(make_rows(), **healthy_context(self))
        row = find_row(criteria, "documented view cap")
        self.assertTrue(row.ok)
        self.assertEqual(row.measured, "60")


class EvaluatePartiallyInstrumentedPanesTests(unittest.TestCase):
    """The "transcript never cleared" criterion was gated on ANY pane anywhere
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
        criteria = report.evaluate(rows, **healthy_context(self))

        row = find_row(criteria, "transcript never cleared")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "26 pane samples did not report transcriptClears")

    def test_no_pane_anywhere_instrumented_still_fails_as_not_instrumented(self):
        criteria = report.evaluate(make_rows(include_transcript_clears=False),
                                   **healthy_context(self))
        row = find_row(criteria, "transcript never cleared")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "not instrumented in this run")


class EvaluateSampleFileMustContainCallGraphTests(unittest.TestCase):
    """The existence of a sample file is not evidence of a
    measurement. `sample` can write an empty or truncated file (permissions,
    a killed process, a too-short duration) with no "Call graph:" section at
    all, and the old code counted 0 signature-frame hits in that file as a
    clean PASS. A file is only a measurement if it actually contains a call
    graph.
    """

    def test_empty_sample_file_fails_as_unmeasured_not_as_a_clean_pass(self):
        sample_path = write_text_file("")
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(make_rows(), turns=5000, cpu_percent=0.04,
                                   sample_path=sample_path)
        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "sample file has no call graph — nothing was measured")

    def test_garbage_sample_file_fails_as_unmeasured_not_as_a_clean_pass(self):
        sample_path = write_text_file("sample: could not attach\n")
        self.addCleanup(os.remove, sample_path)
        criteria = report.evaluate(make_rows(), turns=5000, cpu_percent=0.04,
                                   sample_path=sample_path)
        row = find_row(criteria, "CoreAutoLayout")
        self.assertFalse(row.ok)
        self.assertEqual(row.measured, "sample file has no call graph — nothing was measured")


# --------------------------------------------------------------------------
# T4: the shapes that recurred textually, caught by reading the script.
# --------------------------------------------------------------------------


def _report_module_ast():
    with open(REPORT_SCRIPT_PATH) as handle:
        return ast.parse(handle.read(), filename=REPORT_SCRIPT_PATH)


def _criterion_functions(tree):
    """Every function carrying an `@criterion(...)` decorator."""
    out = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for dec in node.decorator_list:
            target = dec.func if isinstance(dec, ast.Call) else dec
            if isinstance(target, ast.Name) and target.id == "criterion":
                out.append(node)
                break
    return out


def _calls_named(tree, name):
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) \
                and node.func.id == name:
            yield node


def _enclosing_functions(tree):
    """node -> name of the innermost function containing it."""
    owner = {}

    def walk(node, current):
        for child in ast.iter_child_nodes(node):
            name = child.name if isinstance(
                child, (ast.FunctionDef, ast.AsyncFunctionDef)) else current
            owner[child] = name
            walk(child, name)

    walk(tree, None)
    return owner


class ReportScriptShapeTests(unittest.TestCase):
    """Structural assertions on the report script's source.

    The same defect kept recurring with a literal textual signature:
    `max(..., default=0)` standing in for a measurement, `.get(key, 0)`
    reading absent as zero, a criterion assembling its own `Verdict` and so
    choosing its own state, a `graded()` call that forgot to say how many
    points it read. Behavioural tests catch these once the criterion exists
    and someone writes a fixture for it. These catch the *shape* at review
    time, before a soak run is spent discovering it — which is the
    difference between finding an eighth instance and there not being one.
    """

    @classmethod
    def setUpClass(cls):
        cls.tree = _report_module_ast()
        cls.owner = _enclosing_functions(cls.tree)

    def test_every_registered_criterion_is_a_decorated_function(self):
        functions = _criterion_functions(self.tree)
        self.assertEqual(
            len(functions), len(report.CRITERIA),
            "the registry and the decorated functions in the source must be the "
            "same set; a criterion registered any other way is outside every "
            "structural guard below",
        )

    def test_criteria_return_only_through_graded_or_failed(self):
        # `graded()` is the only path to PASS and the only place the
        # two-observation floor is applied. A criterion that builds its own
        # Verdict, or returns anything else, is a criterion that chose its own
        # verdict state — the shape all seven defects were written in.
        offenders = []
        for fn in _criterion_functions(self.tree):
            returns = [n for n in ast.walk(fn) if isinstance(n, ast.Return)]
            self.assertTrue(returns, f"{fn.name} returns nothing at all")
            for node in returns:
                if node.value is None:
                    offenders.append(f"line {node.lineno}: bare return in {fn.name}")
                    continue
                call = node.value
                if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Name)
                        and call.func.id in ("graded", "failed")):
                    offenders.append(
                        f"line {node.lineno}: {fn.name} returns something other "
                        f"than graded(...) or failed(...)")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_every_graded_call_states_its_observation_count_explicitly(self):
        # `observations` has no default precisely so a criterion cannot forget
        # to say how many data points it read. Passing it positionally, or
        # relying on a default someone later adds, reopens that door.
        offenders = [
            f"line {call.lineno}: graded(...) without an explicit observations="
            for call in _calls_named(self.tree, "graded")
            if "observations" not in {kw.arg for kw in call.keywords}
        ]
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_no_max_or_min_call_uses_a_default_keyword(self):
        # `max(..., default=0)` hides a missing measurement as a zero one: an
        # empty input yields zero, zero compares favourably against the limit,
        # and the row prints PASS on a run that measured nothing.
        offenders = []
        for name in ("max", "min"):
            for call in _calls_named(self.tree, name):
                if any(kw.arg == "default" for kw in call.keywords):
                    offenders.append(
                        f"line {call.lineno}: {name}(..., default=...) hides the "
                        f"difference between no measurement and a zero one")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_no_two_argument_get_falls_back_to_a_numeric_literal(self):
        # "Absent is not zero" — a rule that can be written down and then
        # violated one line later: `pane.get("transcriptClears", 0)` turns a
        # pane that never reported the counter into a clean bill of health.
        offenders = []
        for node in ast.walk(self.tree):
            if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
                continue
            if node.func.attr != "get" or len(node.args) != 2:
                continue
            fallback = node.args[1]
            if isinstance(fallback, ast.UnaryOp) and isinstance(fallback.op, ast.USub):
                fallback = fallback.operand
            if isinstance(fallback, ast.Constant) and isinstance(
                    fallback.value, (int, float)) and not isinstance(fallback.value, bool):
                offenders.append(
                    f"line {node.lineno}: .get(..., {ast.unparse(node.args[1])}) "
                    f"reads an absent field as a measured value")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_verdict_is_constructed_only_inside_graded_and_failed(self):
        # The choke point is only a choke point if there is no way around it.
        offenders = [
            f"line {call.lineno}: Verdict(...) built inside "
            f"{self.owner.get(call) or '<module>'}"
            for call in _calls_named(self.tree, "Verdict")
            if self.owner.get(call) not in ("graded", "failed")
        ]
        self.assertEqual(offenders, [], "\n".join(offenders))


# --------------------------------------------------------------------------
# T5: registry integrity and the exit contract.
# --------------------------------------------------------------------------


class RegistryIntegrityTests(unittest.TestCase):
    """The guard against a regression class of its own: every fix must change
    whether a row PASSes or FAILs, never whether it exists.

    The table's row set *is* the registry, so a row cannot vanish, duplicate or
    reorder — but only if `evaluate()` really does return one verdict per entry
    in order for every possible input, including a criterion that throws. A
    dropped row reads as "not a problem" in a table where every other line says
    PASS, which is precisely the failure this report exists to refuse.
    """

    def test_keys_are_unique_and_non_empty(self):
        keys = [reg.key for reg in report.CRITERIA]
        self.assertEqual(len(keys), len(set(keys)), f"duplicate criterion keys in {keys}")
        self.assertTrue(all(key and key.strip() for key in keys))

    def test_every_criterion_states_a_non_empty_limit(self):
        blank = [reg.key for reg in report.CRITERIA if not (reg.limit and reg.limit.strip())]
        self.assertEqual(blank, [], f"criteria with no stated limit: {blank}")

    def test_evaluate_returns_one_verdict_per_criterion_in_registry_order(self):
        expected = [reg.key for reg in report.CRITERIA]
        fixtures = (nothing_measured_fixtures(self) + barren_run_fixtures(self)
                    + [("HEALTHY_26_SAMPLES", make_rows()),
                       ("NO_PANES", make_rows(include_panes=False))])
        contexts = [("no process measurements", NO_PROCESS_MEASUREMENTS),
                    ("with process measurements", healthy_context(self))]

        for label, subject in fixtures:
            for context_label, kwargs in contexts:
                with self.subTest(fixture=label, context=context_label):
                    verdicts = report.evaluate(subject, **kwargs)
                    self.assertEqual([v.key for v in verdicts], expected)

    def test_every_verdict_carries_its_registrations_limit(self):
        limits = {reg.key: reg.limit for reg in report.CRITERIA}
        for label, subject in nothing_measured_fixtures(self) + [
                ("HEALTHY_26_SAMPLES", make_rows())]:
            with self.subTest(fixture=label):
                for verdict in report.evaluate(subject, **NO_PROCESS_MEASUREMENTS):
                    self.assertEqual(verdict.limit, limits[verdict.key],
                                     f"{verdict.key} reported a limit of its own")

    def test_a_criterion_that_raises_becomes_a_failing_row_not_a_traceback(self):
        # A traceback kills the whole table, which is the omitted-row defect at
        # maximum scale: one broken criterion and the operator sees no rows at
        # all. The row must survive, name the exception, and be non-passing.
        saved = report.CRITERIA[:]
        self.addCleanup(report.CRITERIA.__setitem__, slice(None), saved)

        @report.criterion("explodes", limit="never gets there")
        def _explodes(ev):
            raise RuntimeError("instrumentation is not wired up")

        verdicts = report.evaluate(make_rows(), **healthy_context(self))
        self.assertEqual(len(verdicts), len(saved) + 1)

        row = keyed(verdicts)["explodes"]
        self.assertEqual(row.state, report.FAIL)
        self.assertIn("RuntimeError", row.measured)
        self.assertEqual(row.limit, "never gets there")


class MainExitContractTests(unittest.TestCase):
    """main()'s exit status is the only thing the shell driver reads, so every
    weakening of the table has to show up here as well.

    INCONCLUSIVE is non-passing. A criterion nobody measured has not passed,
    and a report that exits 0 because "nothing actually failed" is the seven
    original defects rebuilt in the exit code.
    """

    def test_all_passing_run_exits_zero(self):
        sample_path = good_sample_path(self)
        exit_code = run_main(make_rows(),
                             ["--cpu-percent", "0.04", "--sample", sample_path])
        self.assertEqual(exit_code, 0)

    def test_run_with_any_failure_exits_one(self):
        sample_path = good_sample_path(self)
        exit_code = run_main(make_rows(include_panes=False),
                             ["--cpu-percent", "0.04", "--sample", sample_path])
        self.assertEqual(exit_code, 1)

    def test_an_inconclusive_row_alone_exits_non_zero(self):
        # A healthy run whose CPU measurement simply did not happen: nothing
        # failed, and the run still has not passed.
        sample_path = good_sample_path(self)
        verdicts = report.evaluate(make_rows(), turns=5000, cpu_percent=None,
                                   sample_path=sample_path)
        states = {v.state for v in verdicts}
        self.assertNotIn(report.FAIL, states,
                         "this fixture must isolate INCONCLUSIVE from FAIL")
        self.assertIn(report.INCONCLUSIVE, states)

        self.assertNotEqual(run_main(make_rows(), ["--sample", sample_path]), 0)

    def test_barren_inputs_still_print_the_whole_table_and_exit_non_zero(self):
        # The omitted-row defect at whole-table scale: main() used to return
        # early on an empty, absent or unreadable file, so the one input where
        # every row should read INCONCLUSIVE was the one input that printed no
        # rows at all.
        empty_path = write_lines([])
        self.addCleanup(os.remove, empty_path)
        malformed_path = write_lines(["{not json", "]]]", "nope"])
        self.addCleanup(os.remove, malformed_path)
        absent_path = "/tmp/nostromo-transcript-diagnostics-does-not-exist-redd.jsonl"
        self.assertFalse(os.path.exists(absent_path))

        for label, path in [("empty file", empty_path), ("absent file", absent_path),
                            ("all-malformed file", malformed_path)]:
            with self.subTest(input=label):
                exit_code, out = run_main_on_path(path)
                self.assertNotEqual(exit_code, 0)

                verdicts = report.evaluate_evidence(report.load(path))
                self.assertEqual([v.key for v in verdicts],
                                 [reg.key for reg in report.CRITERIA])
                for verdict in verdicts:
                    self.assertIn(verdict.name, out,
                                  f"[{label}] {verdict.key} printed no row")
                    self.assertIn(verdict.state, out)
                    self.assertNotEqual(verdict.state, report.PASS,
                                        f"[{label}] {verdict.key} passed on nothing")

                # Every row but the one that grades the file itself read
                # nothing whatsoever, and must say so rather than blame the run.
                for verdict in verdicts:
                    if verdict.key == "stream-parses-cleanly":
                        continue
                    self.assertEqual(verdict.state, report.INCONCLUSIVE,
                                     f"[{label}] {verdict.key}: {verdict}")


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
        self.assertIsNotNone(
            func_src,
            "could not statically extract a cpu_seconds() function from "
            "transcript-load-test.sh to exercise directly",
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
