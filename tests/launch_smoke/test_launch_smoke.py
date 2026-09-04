"""Behavioral tests for bin/nostromo-launch-smoke.

These tests exercise the pure-function contract of the launch smoke check:
the verdict model (`reach_verdict`/`gate_verdict`/`aggregate`/`exit_code_for`),
the detector registry, `.ips` crash-report parsing, diagnostics-row
attribution helpers, CPU-percentage arithmetic, the
`PaneFirstPaintAudit`-mirroring not-drawable predicate, and the fixture
daemon's IPC handshake over a real `AF_UNIX` socket. They do NOT exercise the
real launch/build/isolation/known-bad-validation machinery — that is verified
by actually running `bin/nostromo-launch-smoke` and
`macOS/scripts/launch-smoke-validate.sh` (see tests/launch_smoke/README.md).

This is the RED phase of red-green-refactor: `bin/nostromo-launch-smoke` does
not exist yet. Every test below is written against the module contract handed
down for this wedge (see `.claude/plans/launch-smoke-test.md` in the primary
repo checkout) and will fail at import time until that script exists.

The governing discipline, copied from
`macOS/scripts/transcript-load-report.py` and its test suite
(`tests/transcript_load/test_transcript_load_tooling.py`): a detector that
passes on evidence that measured nothing is worse than no detector at all,
because it converts "we didn't check" into "we checked and it's fine". So the
universal vacuity tests below are parameterised over the live `CRITERIA`
registry, not over today's list of seven detector keys — a detector added
tomorrow with no barren-input defence is a detector nobody checked.

Run with:
    /usr/bin/python3 -m unittest discover -s tests/launch_smoke
"""

import datetime
import importlib.machinery
import importlib.util
import json
import os
import re
import tempfile
import time
import unittest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
SCRIPT_PATH = os.path.join(REPO_ROOT, "bin", "nostromo-launch-smoke")
FIXTURE_FRAMES_PATH = os.path.join(REPO_ROOT, "tests", "fixtures", "focus_layout_split.json")

# The script is extensionless (bin/nostromo-launch-smoke, not .py), so
# spec_from_file_location can't infer a loader from the suffix and returns
# None unless we hand it one explicitly. Same mechanism tests/doctor uses to
# import bin/nostromo-doctor.
_loader = importlib.machinery.SourceFileLoader("nostromo_launch_smoke", SCRIPT_PATH)
_spec = importlib.util.spec_from_file_location(
    "nostromo_launch_smoke", SCRIPT_PATH, loader=_loader
)
launch_smoke = importlib.util.module_from_spec(_spec)
_loader.exec_module(launch_smoke)


# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------


def make_pane(
    pane_id="queue",
    *,
    has_content=True,
    is_loading=False,
    bounds_width=100.0,
    bounds_height=50.0,
    has_window=True,
    layout_pass_count=1,
):
    """A `panesMeasured` entry, shaped exactly like `PaneFirstPaintAudit.Measurements`."""
    return {
        "paneId": pane_id,
        "hasContent": has_content,
        "isLoading": is_loading,
        "boundsWidth": bounds_width,
        "boundsHeight": bounds_height,
        "hasWindow": has_window,
        "layoutPassCount": layout_pass_count,
    }


def make_row(*, pid=100, run_id="run-1", splits_ratios_applied=None, panes=None):
    """A diagnostics.jsonl row, shaped per the module contract."""
    return {
        "pid": pid,
        "runID": run_id,
        "splitsRatiosApplied": splits_ratios_applied,
        "panesMeasured": list(panes) if panes is not None else [],
    }


def healthy_evidence():
    """An Evidence that must make every registered detector PASS.

    Two rows, two distinct healthy panes each (queue/diff), split ratios
    applied, alive at window end, plausible mid-range CPU, a crash-report
    scan that actually happened and found nothing, and a pane scan that
    actually happened and found no violations. This is the mandatory
    counterpart to the vacuity tests below (mirrors
    `EvaluateKnownGoodRunTests` in transcript_load's suite) — without it, the
    vacuity tests would be satisfiable by a module that always fails, which
    is the same defect one level up.
    """
    return launch_smoke.Evidence.empty()._replace(
        launched_pid=100,
        rows=(
            make_row(pid=100, splits_ratios_applied=1,
                     panes=[make_pane("queue"), make_pane("diff")]),
            make_row(pid=100, splits_ratios_applied=1,
                     panes=[make_pane("queue"), make_pane("diff")]),
        ),
        observed_pids=(100,),
        another_instance_pid=None,
        alive_at_window_end=True,
        cpu_percent=15.0,
        crash_reports_scanned=3,
        crash_reports_dir_present=True,
        crash_reports_attributed_pids=(),
        notdrawable_violations=(),
        panes_scanned=4,
        window_seconds=15.0,
    )


def load_fixture_frames():
    with open(FIXTURE_FRAMES_PATH) as f:
        return json.load(f)


def keyed(verdicts):
    return {v.key: v for v in verdicts}


def _wait_until(predicate, timeout=2.0, interval=0.02):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


# ---------------------------------------------------------------------------
# Module constants
# ---------------------------------------------------------------------------


class ModuleConstantsTests(unittest.TestCase):
    def test_verdict_states_are_the_documented_strings_and_pairwise_distinct(self):
        self.assertEqual(
            [launch_smoke.PASS, launch_smoke.FAIL, launch_smoke.INCONCLUSIVE],
            ["PASS", "FAIL", "INCONCLUSIVE"],
        )
        self.assertEqual(
            len({launch_smoke.PASS, launch_smoke.FAIL, launch_smoke.INCONCLUSIVE}), 3
        )

    def test_exit_codes_table_matches_the_documented_mapping(self):
        self.assertEqual(
            launch_smoke.EXIT_CODES,
            {launch_smoke.PASS: 0, launch_smoke.FAIL: 1, launch_smoke.INCONCLUSIVE: 2},
        )

    def test_detector_kinds_are_the_documented_strings(self):
        self.assertEqual([launch_smoke.REACH, launch_smoke.GATE], ["reach", "gate"])

    def test_aggregate_inconclusive_causes_are_pinned_exactly(self):
        # Two come from main()'s pre-Evidence short-circuit (no Evidence
        # exists yet); the other three are the REACH detectors' causes. Since
        # GATE detectors can never be INCONCLUSIVE, this is the complete set
        # by construction — pinned here the same way MATERIALIZED_LIMIT is
        # pinned in transcript-load-report.py, so widening it is a visible,
        # deliberate edit rather than a silent drift.
        self.assertEqual(
            launch_smoke.AGGREGATE_INCONCLUSIVE_CAUSES,
            frozenset({
                "build failed",
                "prerequisite missing",
                "multi-pane layout not reached",
                "another instance took the launch",
                "timed out before the app came up",
            }),
        )


class EvidenceEmptyTests(unittest.TestCase):
    def test_matches_the_documented_all_absent_shape(self):
        ev = launch_smoke.Evidence.empty()
        self.assertIsNone(ev.launched_pid)
        self.assertEqual(ev.rows, ())
        self.assertEqual(ev.observed_pids, ())
        self.assertIsNone(ev.another_instance_pid)
        self.assertIsNone(ev.alive_at_window_end)
        self.assertIsNone(ev.cpu_percent)
        self.assertEqual(ev.crash_reports_scanned, 0)
        self.assertFalse(ev.crash_reports_dir_present)
        self.assertEqual(ev.crash_reports_attributed_pids, ())
        self.assertEqual(ev.notdrawable_violations, ())
        self.assertEqual(ev.panes_scanned, 0)
        self.assertEqual(ev.window_seconds, 0.0)


# ---------------------------------------------------------------------------
# reach_verdict / gate_verdict — the only two ways to build a Verdict
# ---------------------------------------------------------------------------


class ReachVerdictTests(unittest.TestCase):
    def test_ok_true_yields_pass_with_no_cause(self):
        v = launch_smoke.reach_verdict(
            "k", "name", ok=True, measured="m", cause=None, observations=3
        )
        self.assertEqual(v.state, launch_smoke.PASS)
        self.assertIsNone(v.cause)

    def test_ok_false_yields_inconclusive_with_the_given_cause(self):
        v = launch_smoke.reach_verdict(
            "k", "name", ok=False, measured="m", cause="reason", observations=0
        )
        self.assertEqual(v.state, launch_smoke.INCONCLUSIVE)
        self.assertEqual(v.cause, "reason")

    def test_reach_verdict_can_never_produce_fail(self):
        for ok in (True, False):
            with self.subTest(ok=ok):
                v = launch_smoke.reach_verdict(
                    "k", "name", ok=ok, measured="m",
                    cause=(None if ok else "r"), observations=1,
                )
                self.assertNotEqual(v.state, launch_smoke.FAIL)


class GateVerdictTests(unittest.TestCase):
    def test_ok_true_yields_pass_with_no_cause(self):
        v = launch_smoke.gate_verdict(
            "k", "name", ok=True, measured="m", cause=None, observations=3
        )
        self.assertEqual(v.state, launch_smoke.PASS)
        self.assertIsNone(v.cause)

    def test_ok_false_yields_fail_with_the_given_cause(self):
        v = launch_smoke.gate_verdict(
            "k", "name", ok=False, measured="m", cause="reason", observations=0
        )
        self.assertEqual(v.state, launch_smoke.FAIL)
        self.assertEqual(v.cause, "reason")

    def test_gate_verdict_can_never_produce_inconclusive(self):
        for ok in (True, False):
            with self.subTest(ok=ok):
                v = launch_smoke.gate_verdict(
                    "k", "name", ok=ok, measured="m",
                    cause=(None if ok else "r"), observations=1,
                )
                self.assertNotEqual(v.state, launch_smoke.INCONCLUSIVE)


# ---------------------------------------------------------------------------
# The registry
# ---------------------------------------------------------------------------

#: Pinned exactly, in the same spirit as `CriterionKindPartitionTests` in
#: transcript_load's suite — widening either set is a visible, deliberate
#: edit to this line, not a silent drift.
EXPECTED_REACH_KEYS = frozenset({
    "our-process-ran-the-app", "multi-pane-laid-out", "split-ratios-applied",
})
EXPECTED_GATE_KEYS = frozenset({
    "alive-at-window-end", "no-attributable-crash-report", "cpu-settled",
    "no-zero-size-laid-out-pane",
})


class DetectorRegistryPinTests(unittest.TestCase):
    def test_exactly_seven_detectors_are_registered(self):
        self.assertEqual(len(launch_smoke.CRITERIA), 7)

    def test_reach_keys_are_pinned_exactly(self):
        self.assertEqual(
            {r.key for r in launch_smoke.CRITERIA if r.kind == launch_smoke.REACH},
            EXPECTED_REACH_KEYS,
        )

    def test_gate_keys_are_pinned_exactly(self):
        self.assertEqual(
            {r.key for r in launch_smoke.CRITERIA if r.kind == launch_smoke.GATE},
            EXPECTED_GATE_KEYS,
        )

    def test_every_registered_kind_is_reach_or_gate(self):
        allowed = {launch_smoke.REACH, launch_smoke.GATE}
        strays = [(r.key, r.kind) for r in launch_smoke.CRITERIA if r.kind not in allowed]
        self.assertEqual(strays, [])

    def test_no_duplicate_keys(self):
        keys = [r.key for r in launch_smoke.CRITERIA]
        self.assertEqual(len(keys), len(set(keys)))


class RegistrationLookupTests(unittest.TestCase):
    def test_registration_returns_the_matching_registered_entry(self):
        for reg in launch_smoke.CRITERIA:
            with self.subTest(key=reg.key):
                self.assertEqual(launch_smoke.registration(reg.key).key, reg.key)

    def test_registration_raises_keyerror_for_an_unknown_key(self):
        with self.assertRaises(KeyError):
            launch_smoke.registration("not-a-real-detector-key")


class DetectorDecoratorTests(unittest.TestCase):
    def test_registering_a_new_detector_appends_it_to_the_registry(self):
        saved = list(launch_smoke.CRITERIA)
        self.addCleanup(launch_smoke.CRITERIA.__setitem__, slice(None), saved)

        @launch_smoke.detector("redd-test-probe", launch_smoke.REACH)
        def _probe(ev):  # pragma: no cover - never invoked in this test
            return launch_smoke.reach_verdict(
                "redd-test-probe", "probe", ok=True, measured="m",
                cause=None, observations=1,
            )

        self.assertIn("redd-test-probe", [r.key for r in launch_smoke.CRITERIA])
        self.assertEqual(launch_smoke.registration("redd-test-probe").kind, launch_smoke.REACH)


# ---------------------------------------------------------------------------
# evaluate_evidence: shape invariants (fixed row set, registry order)
# ---------------------------------------------------------------------------


class EvaluateEvidenceShapeTests(unittest.TestCase):
    def test_returns_exactly_one_verdict_per_registered_detector_in_registry_order(self):
        for label, ev in [
            ("EMPTY", launch_smoke.Evidence.empty()),
            ("HEALTHY", healthy_evidence()),
        ]:
            with self.subTest(fixture=label):
                verdicts = launch_smoke.evaluate_evidence(ev)
                self.assertEqual(
                    [v.key for v in verdicts],
                    [r.key for r in launch_smoke.CRITERIA],
                )

    def test_a_detector_that_raises_becomes_a_failing_verdict_naming_the_exception(self):
        saved = list(launch_smoke.CRITERIA)
        self.addCleanup(launch_smoke.CRITERIA.__setitem__, slice(None), saved)

        target_key = launch_smoke.CRITERIA[0].key
        idx = next(i for i, r in enumerate(launch_smoke.CRITERIA) if r.key == target_key)

        def _boom(ev):
            raise ValueError("redd-injected-boom")

        launch_smoke.CRITERIA[idx] = launch_smoke.CRITERIA[idx]._replace(fn=_boom)

        verdicts = launch_smoke.evaluate_evidence(healthy_evidence())
        self.assertEqual(
            len(verdicts), len(saved),
            "a raising detector must not crash the whole evaluation or drop a row",
        )
        broken = keyed(verdicts)[target_key]
        self.assertEqual(broken.state, launch_smoke.FAIL)
        self.assertTrue(broken.cause)
        haystack = f"{broken.cause} {broken.measured}"
        self.assertIn("redd-injected-boom", haystack)


class VerdictCausePassInvariantTests(unittest.TestCase):
    """state == PASS <=> cause is None, and non-PASS always carries a
    non-empty cause. Checked across every fixture this file builds, not just
    a hand-picked pair — any future fixture added to `_ALL_FIXTURES` is
    covered automatically.
    """

    def test_across_every_fixture_in_this_suite(self):
        fixtures = [launch_smoke.Evidence.empty(), healthy_evidence()]
        for ev in fixtures:
            for v in launch_smoke.evaluate_evidence(ev):
                with self.subTest(fixture=id(ev), key=v.key):
                    if v.state == launch_smoke.PASS:
                        self.assertIsNone(v.cause, f"{v.key} PASSed but carries a cause")
                    else:
                        self.assertTrue(v.cause, f"{v.key} is {v.state} with no cause")


# ---------------------------------------------------------------------------
# The universal vacuity tests — the feature's main defence.
# ---------------------------------------------------------------------------


class UniversalVacuityTests(unittest.TestCase):
    """On evidence that observed nothing at all, no registered detector may
    produce a passing verdict — with one pinned, documented exception, in the
    same spirit as transcript-load-report.py's two-row-wide STREAM/PROCESS
    exemption from its own universal vacuity test (see that module's
    docstring: "these CAN pass on a file holding one clean line ... the
    exemption exists, it is two rows wide, and moving a criterion into it
    fails the suite until someone edits that line on purpose").

    `no-zero-size-laid-out-pane` is that exemption here, and it is
    load-bearing, not an oversight: verified empirically by actually running
    `bin/nostromo-launch-smoke` against the fixture daemon serving a
    single-`repl`-leaf tree instead of the split tree (the literal
    fixture-rot demonstration the PRD requires). `repl` is a `ReplView`, not
    a `PaneContentNSView`, so it is never registered in the pane registry
    `panesMeasured` reads from — a perfectly healthy, ordinary tree
    legitimately produces `panes_scanned == 0` and zero violations. Gating
    this detector on `panes_scanned > 0` (as an earlier revision did) made it
    FAIL on that tree, which — because a GATE FAIL always dominates
    `aggregate()` — reported the whole run FAIL instead of the required
    INCONCLUSIVE "multi-pane layout not reached", breaking the fixture-rot
    demonstration outright. This mirrors `PaneFirstPaintAudit.verdict` itself
    (`macOS/Nostromo/UI/PaneFirstPaintAudit.swift`): it reports `.healthy`
    whenever there is nothing to judge (no content, no window, no completed
    layout pass) — "nothing to violate" is not the same failure mode as
    "something was measured and it's wrong," and only the latter is what
    this detector exists to catch.
    """

    #: Detectors that may legitimately PASS on `Evidence.empty()`. Exactly
    #: one entry, pinned here the same way transcript-load-report.py pins
    #: its STREAM/PROCESS partition — widening this is a visible, deliberate
    #: edit, not a silent drift.
    VACUOUS_PASS_EXEMPT = frozenset({"no-zero-size-laid-out-pane"})

    def test_no_registered_detector_passes_on_evidence_empty_except_the_pinned_exemption(self):
        verdicts = launch_smoke.evaluate_evidence(launch_smoke.Evidence.empty())
        offenders = [
            v for v in verdicts
            if v.state == launch_smoke.PASS and v.key not in self.VACUOUS_PASS_EXEMPT
        ]
        self.assertEqual(
            offenders, [],
            f"detectors passed on Evidence.empty(): {[v.key for v in offenders]}",
        )
        # And the exempted detector really does still PASS here — otherwise
        # the exemption itself would be dead code nobody's fixture exercises.
        exempted = keyed(verdicts)[next(iter(self.VACUOUS_PASS_EXEMPT))]
        self.assertEqual(exempted.state, launch_smoke.PASS)

    def test_no_registered_detector_is_inconclusive_since_gate_never_is_and_reach_never_fails(self):
        # Every verdict on Evidence.empty() is either INCONCLUSIVE (a REACH
        # detector), FAIL (a GATE detector), or PASS (the one pinned
        # exemption above) — never an unpinned PASS — which is exactly
        # `test_no_registered_detector_passes_on_evidence_empty_except_the_pinned_exemption`
        # above, restated per-kind so a reader sees why the aggregate can't
        # be INCONCLUSIVE here without re-deriving it (some GATE detector
        # always FAILs on totally barren evidence, and a GATE FAIL always
        # dominates `aggregate()` — see AggregateTests below).
        verdicts = launch_smoke.evaluate_evidence(launch_smoke.Evidence.empty())
        for v in verdicts:
            kind = launch_smoke.registration(v.key).kind
            with self.subTest(key=v.key, kind=kind):
                if v.key in self.VACUOUS_PASS_EXEMPT:
                    self.assertEqual(v.state, launch_smoke.PASS)
                elif kind == launch_smoke.REACH:
                    self.assertEqual(v.state, launch_smoke.INCONCLUSIVE)
                elif kind == launch_smoke.GATE:
                    self.assertEqual(v.state, launch_smoke.FAIL)


class VacuityTestActuallyBitesTests(unittest.TestCase):
    """Proof the vacuity test above is not itself vacuous: register a
    detector shaped exactly like the historical defect class (a PASS
    satisfied by input that measured nothing) and confirm the same assertion
    body objects. Mirrors `VacuityTestActuallyBitesTests` in transcript_load's
    suite.
    """

    def test_a_detector_that_cannot_fail_is_caught_on_evidence_empty(self):
        saved = list(launch_smoke.CRITERIA)
        self.addCleanup(launch_smoke.CRITERIA.__setitem__, slice(None), saved)

        @launch_smoke.detector("always-passes", launch_smoke.GATE)
        def _always_passes(ev):
            return launch_smoke.gate_verdict(
                "always-passes", "a detector that measures nothing",
                ok=True, measured="claimed a measurement it never made",
                cause=None, observations=0,
            )

        verdicts = launch_smoke.evaluate_evidence(launch_smoke.Evidence.empty())
        offenders = [v for v in verdicts if v.state == launch_smoke.PASS]
        self.assertIn("always-passes", [v.key for v in offenders])


class EvaluateKnownGoodEvidenceTests(unittest.TestCase):
    """Mandatory counterpart to the vacuity tests: on a genuinely healthy
    run, every detector must PASS. Without this, the vacuity tests above are
    satisfiable by a module that always FAILs/INCONCLUSIVEs — the same bug
    one level up. Mirrors `EvaluateKnownGoodRunTests`.
    """

    def test_every_registered_detector_passes_on_a_healthy_run(self):
        verdicts = launch_smoke.evaluate_evidence(healthy_evidence())
        not_passing = [
            (v.key, v.state, v.cause) for v in verdicts if v.state != launch_smoke.PASS
        ]
        self.assertEqual(
            not_passing, [],
            "a healthy run must pass every detector, or the vacuity tests are "
            "satisfied by a module that always fails",
        )


# ---------------------------------------------------------------------------
# The kind-partition invariant: REACH never FAILs, GATE never INCONCLUSIVE.
# Parameterised over the live registry (via `registration(key).kind`), not
# over today's hardcoded list of seven keys — a detector registered tomorrow
# is covered with no new test.
# ---------------------------------------------------------------------------


def mutate_another_instance_took_the_launch():
    return (
        healthy_evidence()._replace(
            launched_pid=999, observed_pids=(100,), another_instance_pid=100,
        ),
        launch_smoke.INCONCLUSIVE,
        "another instance took the launch",
    )


def mutate_timed_out_before_the_app_came_up():
    return (
        healthy_evidence()._replace(
            launched_pid=999, observed_pids=(100,), another_instance_pid=None,
        ),
        launch_smoke.INCONCLUSIVE,
        "timed out before the app came up",
    )


def mutate_multipane_not_reached():
    return (
        healthy_evidence()._replace(
            rows=(make_row(pid=100, splits_ratios_applied=1, panes=[make_pane("repl")]),),
        ),
        launch_smoke.INCONCLUSIVE,
        "multi-pane layout not reached",
    )


def mutate_split_ratios_never_applied():
    return (
        healthy_evidence()._replace(
            rows=(make_row(pid=100, splits_ratios_applied=None,
                           panes=[make_pane("queue"), make_pane("diff")]),),
        ),
        launch_smoke.INCONCLUSIVE,
        "multi-pane layout not reached",
    )


def mutate_process_died_before_window_end():
    return healthy_evidence()._replace(alive_at_window_end=False), launch_smoke.FAIL, None


def mutate_crash_report_attributed():
    return (
        healthy_evidence()._replace(crash_reports_attributed_pids=(100,)),
        launch_smoke.FAIL,
        None,
    )


def mutate_crash_scan_never_happened():
    # Nothing was actually scanned (no DiagnosticReports directory, zero
    # reports considered). An implementation that only checks
    # `len(crash_reports_attributed_pids) == 0` would wrongly PASS here —
    # exactly the "criterion satisfied by the absence of the thing it
    # measures" defect transcript-load-report.py's whole registry design
    # exists to close (see its `idle-cpu` criterion, which FAILs rather than
    # passes when `cpu_percent is None`). Since this is a GATE detector it
    # cannot report INCONCLUSIVE for "didn't measure" the way a REACH
    # detector would, so the only correct answer is FAIL.
    return (
        healthy_evidence()._replace(
            crash_reports_scanned=0, crash_reports_dir_present=False,
            crash_reports_attributed_pids=(),
        ),
        launch_smoke.FAIL,
        None,
    )


def mutate_cpu_unmeasured():
    return healthy_evidence()._replace(cpu_percent=None), launch_smoke.FAIL, "could not measure CPU"


def mutate_cpu_wedged_at_zero():
    return healthy_evidence()._replace(cpu_percent=0.0), launch_smoke.FAIL, "wedged, not idle"


def mutate_cpu_pinned():
    return healthy_evidence()._replace(cpu_percent=95.0), launch_smoke.FAIL, "pinned at"


def mutate_zero_size_pane_violation():
    return (
        healthy_evidence()._replace(
            notdrawable_violations=(
                "pane=queue hasContent=true loading=false hasWindow=true "
                "layoutPasses=1 bounds=0.0x50.0 verdict=notDrawable(zeroWidth)",
            ),
        ),
        launch_smoke.FAIL,
        None,
    )


#: registry key -> list of (builder returning (evidence, expected_state,
#: cause_substring_or_None)) — every registered detector must appear at least
#: once. `cause_substring_or_None` is only checked when not None, since the
#: contract pins exact cause text for some detectors (the REACH causes and
#: cpu-settled's three) but not others.
SENSITIVITY = {
    "our-process-ran-the-app": [
        mutate_another_instance_took_the_launch,
        mutate_timed_out_before_the_app_came_up,
    ],
    "multi-pane-laid-out": [mutate_multipane_not_reached],
    "split-ratios-applied": [mutate_split_ratios_never_applied],
    "alive-at-window-end": [mutate_process_died_before_window_end],
    "no-attributable-crash-report": [
        mutate_crash_report_attributed,
        mutate_crash_scan_never_happened,
    ],
    "cpu-settled": [mutate_cpu_unmeasured, mutate_cpu_wedged_at_zero, mutate_cpu_pinned],
    # `no-zero-size-laid-out-pane`: deliberately only one mutation, unlike
    # its GATE siblings above. There is no "zero panes scanned" failure case
    # for this detector — see `PaneScanNeverHappenedStillPassesTests` below
    # and `UniversalVacuityTests`'s docstring for why that absence is
    # intentional, not an oversight.
    "no-zero-size-laid-out-pane": [mutate_zero_size_pane_violation],
}

#: All the (evidence, ...) fixtures the sensitivity mutations produce, used to
#: broaden the kind-partition invariant's coverage beyond EMPTY/HEALTHY.
def _all_sensitivity_fixtures():
    for builders in SENSITIVITY.values():
        for build in builders:
            yield build()[0]


class CriterionSensitivityTests(unittest.TestCase):
    """Every registered detector must be provably able to produce its
    non-passing state at least once. Mirrors `CriterionSensitivityTests` /
    T3 in transcript_load's suite — a detector nobody proved can fail is the
    defect this whole file exists to close.
    """

    def test_every_registered_detector_has_a_sensitivity_case(self):
        self.assertEqual(
            set(SENSITIVITY), {r.key for r in launch_smoke.CRITERIA},
            "every detector must be paired with a mutation that flips it off PASS",
        )

    def test_each_mutation_flips_its_own_detector_to_the_expected_state(self):
        for key, builders in SENSITIVITY.items():
            for build in builders:
                with self.subTest(criterion=key, mutation=build.__name__):
                    evidence, expected_state, cause_substring = build()
                    row = keyed(launch_smoke.evaluate_evidence(evidence))[key]
                    self.assertEqual(
                        row.state, expected_state,
                        f"{key}/{build.__name__} did not produce {expected_state}: {row}",
                    )
                    if cause_substring is not None:
                        self.assertIn(
                            cause_substring, row.cause or "",
                            f"{key}/{build.__name__}: cause {row.cause!r} does not "
                            f"contain {cause_substring!r}",
                        )


class PaneScanNeverHappenedStillPassesTests(unittest.TestCase):
    """`no-zero-size-laid-out-pane` must PASS when zero panes were ever
    scanned — the load-bearing counterpart to
    `UniversalVacuityTests.VACUOUS_PASS_EXEMPT` above. `panes_scanned == 0`
    is the ordinary, healthy shape of a tree with no `PaneContentNSView`-
    backed panes (a single `repl` leaf — `repl` is a `ReplView`, never
    registered in the pane registry `panesMeasured` reads from), not evidence
    that this run's own plumbing failed to measure anything. Verified
    empirically: this is precisely the diagnostics shape
    `bin/nostromo-launch-smoke` observed when actually run against the
    fixture daemon serving a single-leaf tree instead of the split tree — the
    literal fixture-rot demonstration the PRD requires to report
    INCONCLUSIVE ("multi-pane layout not reached"), which an earlier
    revision of this detector broke by FAILing on exactly that shape (a GATE
    FAIL always dominates `aggregate()`, so the whole run read FAIL instead).
    """

    def test_zero_panes_scanned_and_zero_violations_still_passes(self):
        ev = healthy_evidence()._replace(panes_scanned=0, notdrawable_violations=())
        row = keyed(launch_smoke.evaluate_evidence(ev))["no-zero-size-laid-out-pane"]
        self.assertEqual(row.state, launch_smoke.PASS, row)
        self.assertIsNone(row.cause)


class DetectorKindInvariantTests(unittest.TestCase):
    """The kind-partition invariant, asserted generically: for every verdict
    produced across a battery of fixtures, a REACH detector's verdict is
    never FAIL and a GATE detector's verdict is never INCONCLUSIVE. Looked up
    via `registration(key).kind` rather than a hardcoded key list, so a
    detector registered tomorrow is covered automatically — mirrors
    `CriterionKindPartitionTests`'s spirit applied at the evaluation layer
    rather than only at the static-registry layer (see
    DetectorRegistryPinTests above for the static pin).
    """

    def test_reach_never_fails_and_gate_never_inconclusive_across_many_fixtures(self):
        fixtures = [launch_smoke.Evidence.empty(), healthy_evidence()]
        fixtures.extend(_all_sensitivity_fixtures())

        for i, ev in enumerate(fixtures):
            for v in launch_smoke.evaluate_evidence(ev):
                kind = launch_smoke.registration(v.key).kind
                with self.subTest(fixture=i, key=v.key, kind=kind):
                    if kind == launch_smoke.REACH:
                        self.assertNotEqual(v.state, launch_smoke.FAIL)
                    elif kind == launch_smoke.GATE:
                        self.assertNotEqual(v.state, launch_smoke.INCONCLUSIVE)


# ---------------------------------------------------------------------------
# aggregate()
# ---------------------------------------------------------------------------


def _v(key, state, cause=None):
    return launch_smoke.Verdict(
        key=key, name=key, state=state, measured="m", cause=cause, observations=1
    )


class AggregateTests(unittest.TestCase):
    def test_empty_list_is_pass_with_no_cause(self):
        self.assertEqual(launch_smoke.aggregate([]), (launch_smoke.PASS, None))

    def test_all_pass_is_pass_with_no_cause(self):
        verdicts = [_v("a", launch_smoke.PASS), _v("b", launch_smoke.PASS)]
        self.assertEqual(launch_smoke.aggregate(verdicts), (launch_smoke.PASS, None))

    def test_inconclusive_alone_beats_pass(self):
        verdicts = [_v("a", launch_smoke.PASS), _v("b", launch_smoke.INCONCLUSIVE, "b-cause")]
        self.assertEqual(
            launch_smoke.aggregate(verdicts), (launch_smoke.INCONCLUSIVE, "b-cause")
        )

    def test_fail_beats_inconclusive_the_load_bearing_precedence_case(self):
        # The known-bad build (reentrancy guard removed): the app dies
        # mid-layout, so the REACH detectors read INCONCLUSIVE (never reached
        # multi-pane layout) while a GATE detector FAILs (not alive at window
        # end / crash report / unsettled CPU). This must aggregate to FAIL —
        # if INCONCLUSIVE won here, the known-bad build would report
        # INCONCLUSIVE forever and the whole gate would be decorative.
        verdicts = [
            _v("multi-pane-laid-out", launch_smoke.INCONCLUSIVE, "multi-pane layout not reached"),
            _v("alive-at-window-end", launch_smoke.FAIL, "process died before window end"),
        ]
        self.assertEqual(
            launch_smoke.aggregate(verdicts),
            (launch_smoke.FAIL, "process died before window end"),
        )

    def test_fail_beats_pass_and_inconclusive_regardless_of_list_order(self):
        verdicts = [
            _v("a", launch_smoke.FAIL, "only fail"),
            _v("b", launch_smoke.INCONCLUSIVE, "inc"),
            _v("c", launch_smoke.PASS),
        ]
        self.assertEqual(launch_smoke.aggregate(verdicts), (launch_smoke.FAIL, "only fail"))

    def test_cause_is_the_first_registry_order_verdict_at_the_worst_state(self):
        verdicts = [
            _v("a", launch_smoke.PASS),
            _v("b", launch_smoke.FAIL, "first fail"),
            _v("c", launch_smoke.FAIL, "second fail"),
        ]
        self.assertEqual(launch_smoke.aggregate(verdicts), (launch_smoke.FAIL, "first fail"))

    # See the note in UniversalVacuityTests above: aggregate() of the real
    # registry on Evidence.empty() is FAIL, not INCONCLUSIVE, because
    # "alive-at-window-end" and "cpu-settled" (both GATE) each correctly FAIL
    # on totally barren evidence per their own literal spec, and GATE FAILs
    # dominate. That is asserted directly here rather than left unstated.
    def test_real_registered_verdicts_on_evidence_empty_aggregate_to_fail_not_inconclusive(self):
        verdicts = launch_smoke.evaluate_evidence(launch_smoke.Evidence.empty())
        state, _cause = launch_smoke.aggregate(verdicts)
        self.assertEqual(
            state, launch_smoke.FAIL,
            "if this ever starts reading INCONCLUSIVE, the contract tension "
            "documented above has been resolved — great, but then the "
            "'aggregate empty evidence is INCONCLUSIVE' requirement from the "
            "module contract should get a real test here instead of this one",
        )

    def test_real_registered_verdicts_on_a_healthy_run_aggregate_to_pass(self):
        verdicts = launch_smoke.evaluate_evidence(healthy_evidence())
        self.assertEqual(launch_smoke.aggregate(verdicts), (launch_smoke.PASS, None))


class ExitCodeForTests(unittest.TestCase):
    def test_maps_each_state_to_its_documented_code(self):
        self.assertEqual(launch_smoke.exit_code_for(launch_smoke.PASS), 0)
        self.assertEqual(launch_smoke.exit_code_for(launch_smoke.FAIL), 1)
        self.assertEqual(launch_smoke.exit_code_for(launch_smoke.INCONCLUSIVE), 2)

    def test_matches_the_exit_codes_table(self):
        for state in (launch_smoke.PASS, launch_smoke.FAIL, launch_smoke.INCONCLUSIVE):
            with self.subTest(state=state):
                self.assertEqual(
                    launch_smoke.exit_code_for(state), launch_smoke.EXIT_CODES[state]
                )

    def test_the_three_codes_are_pairwise_distinct(self):
        codes = {
            launch_smoke.exit_code_for(s)
            for s in (launch_smoke.PASS, launch_smoke.FAIL, launch_smoke.INCONCLUSIVE)
        }
        self.assertEqual(len(codes), 3)


# ---------------------------------------------------------------------------
# .ips crash-report parsing
# ---------------------------------------------------------------------------


def build_ips_text(
    *,
    pid=4242,
    proc_path="/private/tmp/nostromo-smoke-abc123/Nostromo.app/Contents/MacOS/Nostromo",
    header_timestamp="2026-09-03 10:15:22.00 -0700",
    capture_time="2026-09-03 10:15:23.50 -0700",
    incident_id="ABCDEF12-3456-7890-ABCD-EF1234567890",
):
    """A realistic two-JSON-part .ips report, built inline rather than read
    from a file on disk — a JSON header object on line 1, followed by the
    JSON body (pretty-printed, as real .ips bodies are, spanning several
    lines), matching the shape verified against a real report in the plan.
    """
    header = json.dumps({
        "app_name": "Nostromo",
        "timestamp": header_timestamp,
        "bug_type": "309",
        "incident_id": incident_id,
    })
    body = json.dumps({
        "pid": pid,
        "procName": "Nostromo",
        "procPath": proc_path,
        "captureTime": capture_time,
        "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"},
    }, indent=2)
    return header + "\n" + body


class ParseIpsReportTests(unittest.TestCase):
    def _parse_never_raises(self, text):
        try:
            return launch_smoke.parse_ips_report(text)
        except Exception as e:  # noqa: BLE001 - the contract says this must never raise
            self.fail(f"parse_ips_report raised {type(e).__name__}: {e} on {text!r}")

    def test_a_realistic_two_part_report_parses_pid_path_and_timestamps(self):
        text = build_ips_text(
            pid=4242,
            proc_path="/tmp/x/Nostromo.app/Contents/MacOS/Nostromo",
            header_timestamp="2026-09-03 10:15:22.00 -0700",
            capture_time="2026-09-03 10:15:23.50 -0700",
        )
        parsed = self._parse_never_raises(text)
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["pid"], 4242)
        self.assertEqual(parsed["proc_path"], "/tmp/x/Nostromo.app/Contents/MacOS/Nostromo")
        self.assertEqual(parsed["capture_time"], "2026-09-03 10:15:23.50 -0700")
        self.assertEqual(parsed["header_timestamp"], "2026-09-03 10:15:22.00 -0700")

    def test_empty_text_returns_none(self):
        self.assertIsNone(self._parse_never_raises(""))

    def test_single_json_object_with_no_body_returns_none(self):
        text = json.dumps({
            "app_name": "Nostromo", "timestamp": "x", "bug_type": "309", "incident_id": "abc",
        })
        self.assertIsNone(self._parse_never_raises(text))

    def test_truncated_report_returns_none_not_a_crash(self):
        text = build_ips_text()
        truncated = text[: len(text) // 2]
        self.assertIsNone(self._parse_never_raises(truncated))

    def test_garbage_text_returns_none(self):
        self.assertIsNone(self._parse_never_raises("this is not json at all\nnor is this"))

    def test_valid_header_but_garbage_body_returns_none(self):
        header = json.dumps({
            "app_name": "Nostromo", "timestamp": "x", "bug_type": "309", "incident_id": "abc",
        })
        text = header + "\nnot valid json for the body"
        self.assertIsNone(self._parse_never_raises(text))


class ParseIpsTimestampTests(unittest.TestCase):
    """`parse_ips_timestamp` — the piece that lets `crash_report_matches`
    corroborate a report's pid/path match against the actual observation
    window, rather than trusting pid equality alone (macOS recycles pids,
    so a stale `.ips` file from an unrelated, months-old run can share a pid
    with the current run purely by chance)."""

    def _parse_never_raises(self, s):
        try:
            return launch_smoke.parse_ips_timestamp(s)
        except Exception as e:  # noqa: BLE001 - the contract says this must never raise
            self.fail(f"parse_ips_timestamp raised {type(e).__name__}: {e} on {s!r}")

    def test_a_realistic_timestamp_parses_to_the_correct_epoch_value(self):
        s = "2026-09-03 10:15:22.00 -0700"
        expected = datetime.datetime.strptime(s, "%Y-%m-%d %H:%M:%S.%f %z").timestamp()
        self.assertEqual(self._parse_never_raises(s), expected)

    def test_none_returns_none(self):
        self.assertIsNone(self._parse_never_raises(None))

    def test_empty_string_returns_none(self):
        self.assertIsNone(self._parse_never_raises(""))

    def test_garbage_string_returns_none(self):
        self.assertIsNone(self._parse_never_raises("not a timestamp"))

    def test_missing_utc_offset_returns_none(self):
        # Plausible-looking but malformed: the same date/time as a real
        # capture_time, minus the trailing " ±ZZZZ" the format requires.
        self.assertIsNone(self._parse_never_raises("2026-09-03 10:15:22.00"))

    def test_non_string_input_returns_none(self):
        self.assertIsNone(self._parse_never_raises(12345))
        self.assertIsNone(self._parse_never_raises(["2026-09-03 10:15:22.00 -0700"]))


# A window that contains the realistic default capture_time/header_timestamp
# `CrashReportMatchesTests._parsed()` below hands out, so the pre-existing
# pid/path structural tests keep testing exactly what they tested before
# `crash_report_matches` gained timestamp corroboration.
_WINDOW_TZ = datetime.timezone(datetime.timedelta(hours=-7))
_WINDOW_START_DT = datetime.datetime(2026, 9, 3, 10, 0, 0, tzinfo=_WINDOW_TZ)
_WINDOW_END_DT = datetime.datetime(2026, 9, 3, 10, 30, 0, tzinfo=_WINDOW_TZ)
_WINDOW_START = _WINDOW_START_DT.timestamp()
_WINDOW_END = _WINDOW_END_DT.timestamp()
_DEFAULT_CAPTURE_TIME = "2026-09-03 10:15:23.50 -0700"      # inside the window
_DEFAULT_HEADER_TIMESTAMP = "2026-09-03 10:15:22.00 -0700"  # inside the window


def _ips_ts(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S.00 %z")


class CrashReportMatchesTests(unittest.TestCase):
    @staticmethod
    def _parsed(pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
                capture_time=_DEFAULT_CAPTURE_TIME, header_timestamp=_DEFAULT_HEADER_TIMESTAMP):
        return {
            "pid": pid, "proc_path": proc_path,
            "capture_time": capture_time, "header_timestamp": header_timestamp,
        }

    # -- pre-existing structural (pid/path) tests, now given a window that
    # contains the realistic default timestamps above, so they still test
    # only the structural check they always tested. --

    def test_matching_pid_and_path_under_bundle_root_matches(self):
        parsed = self._parsed(pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo")
        self.assertTrue(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_wrong_pid_does_not_match(self):
        parsed = self._parsed(pid=999, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo")
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_matching_pid_but_path_outside_bundle_root_does_not_match(self):
        parsed = self._parsed(pid=100, proc_path="/Applications/Nostromo.app/Contents/MacOS/Nostromo")
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_both_pid_and_path_right_matches_among_multiple_candidate_pids(self):
        parsed = self._parsed(pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo")
        self.assertTrue(
            launch_smoke.crash_report_matches(
                parsed, pids=(50, 100, 200), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_missing_proc_path_does_not_match(self):
        parsed = {
            "pid": 100, "proc_path": None,
            "capture_time": _DEFAULT_CAPTURE_TIME, "header_timestamp": _DEFAULT_HEADER_TIMESTAMP,
        }
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_macos_redacted_temp_clone_path_matches_when_bundle_root_is_a_temp_dir(self):
        # Verified against a real crash report from this check's own
        # known-bad validation run: macOS's crash reporter redacted a real
        # absolute clone path under /var/folders/ down to exactly this
        # literal shape (the whole variable middle collapsed to one `*`).
        parsed = self._parsed(
            pid=100, proc_path="/var/folders/*/Nostromo.app/Contents/MacOS/Nostromo",
        )
        self.assertTrue(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,),
                bundle_root="/var/folders/m8/abc123/T/nostromo-launch-smoke-xyz/Nostromo.app",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_redacted_shape_does_not_match_when_bundle_root_is_not_a_temp_dir(self):
        # The redacted-shape acceptance must not become a blanket "any
        # Nostromo.app matches" rule — it only applies when OUR OWN clone is
        # itself under a temp directory (always true in practice), so an
        # unrelated report whose path merely looks like this can't slip
        # through for a `bundle_root` that was never a temp path at all.
        parsed = self._parsed(
            pid=100, proc_path="/var/folders/*/Nostromo.app/Contents/MacOS/Nostromo",
        )
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/Applications/Nostromo.app",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    # -- new: timestamp corroboration --

    def test_matching_pid_and_path_but_timestamp_outside_window_does_not_match_a_stale_report(self):
        """The core regression this gap exists to fix: macOS recycles pids,
        so a *stale* `.ips` file left over from a months-old validation run
        can share a pid with the current run's launched process purely by
        chance, and — because this check's own runs always produce the same
        redacted temp-clone `procPath` shape — the structural pid+path check
        alone would falsely attribute that ancient crash to a perfectly
        healthy current run, turning a false-negative crash into a false
        FAIL. Corroborating against the run's own observation window closes
        that hole: pid/path matching is necessary but no longer sufficient.
        """
        stale = "2026-01-01 09:00:00.00 -0700"  # months before the window
        parsed = self._parsed(
            pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
            capture_time=stale, header_timestamp=stale,
        )
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_unparseable_capture_time_falls_back_to_header_timestamp(self):
        parsed = self._parsed(
            pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
            capture_time="not a timestamp", header_timestamp=_DEFAULT_HEADER_TIMESTAMP,
        )
        self.assertTrue(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_both_timestamps_unparseable_fails_closed_even_with_correct_pid_and_path(self):
        # Pid/path equality alone is never enough — if neither timestamp
        # field parses, the report does not corroborate and must not match,
        # regardless of how convincing the structural match looks.
        parsed = self._parsed(
            pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
            capture_time="garbage", header_timestamp=None,
        )
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_timestamp_exactly_at_window_start_matches_inclusive_boundary(self):
        parsed = self._parsed(
            pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
            capture_time=_ips_ts(_WINDOW_START_DT), header_timestamp=_ips_ts(_WINDOW_START_DT),
        )
        self.assertTrue(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_timestamp_exactly_at_window_end_matches_inclusive_boundary(self):
        parsed = self._parsed(
            pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
            capture_time=_ips_ts(_WINDOW_END_DT), header_timestamp=_ips_ts(_WINDOW_END_DT),
        )
        self.assertTrue(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_timestamp_one_second_before_window_start_does_not_match(self):
        before = _WINDOW_START_DT - datetime.timedelta(seconds=1)
        parsed = self._parsed(
            pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
            capture_time=_ips_ts(before), header_timestamp=_ips_ts(before),
        )
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )

    def test_timestamp_one_second_after_window_end_does_not_match(self):
        after = _WINDOW_END_DT + datetime.timedelta(seconds=1)
        parsed = self._parsed(
            pid=100, proc_path="/tmp/clone/Nostromo.app/Contents/MacOS/Nostromo",
            capture_time=_ips_ts(after), header_timestamp=_ips_ts(after),
        )
        self.assertFalse(
            launch_smoke.crash_report_matches(
                parsed, pids=(100,), bundle_root="/tmp/clone",
                window_start=_WINDOW_START, window_end=_WINDOW_END,
            )
        )


# ---------------------------------------------------------------------------
# CPU arithmetic
# ---------------------------------------------------------------------------


class CpuPercentFromTimesTests(unittest.TestCase):
    def test_basic_arithmetic(self):
        self.assertAlmostEqual(launch_smoke.cpu_percent_from_times(10.0, 25.0, 10.0), 150.0)

    def test_zero_delta_is_zero_percent(self):
        self.assertAlmostEqual(launch_smoke.cpu_percent_from_times(100.0, 100.0, 10.0), 0.0)

    def test_plausible_idle_delta(self):
        self.assertAlmostEqual(launch_smoke.cpu_percent_from_times(100.0, 100.05, 10.0), 0.5)

    def test_a_full_core_pinned_over_the_whole_window_is_100_percent(self):
        self.assertAlmostEqual(launch_smoke.cpu_percent_from_times(0.0, 10.0, 10.0), 100.0)


# ---------------------------------------------------------------------------
# Diagnostics-row pure helpers
# ---------------------------------------------------------------------------


class RowsForPidTests(unittest.TestCase):
    def test_returns_only_rows_for_the_given_pid_in_file_order(self):
        rows = (make_row(pid=1), make_row(pid=2), make_row(pid=1))
        self.assertEqual(launch_smoke.rows_for_pid(rows, 1), (rows[0], rows[2]))

    def test_no_matching_rows_returns_empty_tuple(self):
        rows = (make_row(pid=1),)
        self.assertEqual(launch_smoke.rows_for_pid(rows, 999), ())

    def test_empty_input_returns_empty_tuple(self):
        self.assertEqual(launch_smoke.rows_for_pid((), 1), ())


class DistinctPidsTests(unittest.TestCase):
    def test_sorted_distinct_pids_from_mixed_input(self):
        rows = (make_row(pid=3), make_row(pid=1), make_row(pid=2), make_row(pid=1))
        self.assertEqual(launch_smoke.distinct_pids(rows), (1, 2, 3))

    def test_rows_without_a_pid_field_are_skipped(self):
        rows = ({"runID": "x", "panesMeasured": []}, make_row(pid=5))
        self.assertEqual(launch_smoke.distinct_pids(rows), (5,))

    def test_empty_input_returns_empty_tuple(self):
        self.assertEqual(launch_smoke.distinct_pids(()), ())


class DistinctMultipaneCountTests(unittest.TestCase):
    def test_the_same_pane_id_across_two_samples_counts_once_not_twice(self):
        rows = (make_row(panes=[make_pane("queue")]), make_row(panes=[make_pane("queue")]))
        self.assertEqual(launch_smoke.distinct_multipane_count(rows), 1)

    def test_two_distinct_qualifying_panes_counts_two(self):
        rows = (make_row(panes=[make_pane("queue"), make_pane("diff")]),)
        self.assertEqual(launch_smoke.distinct_multipane_count(rows), 2)

    def test_a_pane_without_a_window_is_excluded(self):
        rows = (make_row(panes=[make_pane("queue", has_window=False), make_pane("diff")]),)
        self.assertEqual(launch_smoke.distinct_multipane_count(rows), 1)

    def test_a_pane_with_zero_layout_passes_is_excluded(self):
        rows = (make_row(panes=[make_pane("queue", layout_pass_count=0), make_pane("diff")]),)
        self.assertEqual(launch_smoke.distinct_multipane_count(rows), 1)

    def test_a_pane_with_zero_width_is_excluded(self):
        rows = (make_row(panes=[make_pane("queue", bounds_width=0), make_pane("diff")]),)
        self.assertEqual(launch_smoke.distinct_multipane_count(rows), 1)

    def test_a_pane_with_zero_height_is_excluded(self):
        rows = (make_row(panes=[make_pane("queue", bounds_height=0), make_pane("diff")]),)
        self.assertEqual(launch_smoke.distinct_multipane_count(rows), 1)

    def test_only_one_qualifying_pane_across_the_whole_stream_never_reaches_two(self):
        rows = (make_row(panes=[make_pane("repl")]), make_row(panes=[make_pane("repl")]))
        self.assertEqual(launch_smoke.distinct_multipane_count(rows), 1)

    def test_no_rows_yields_zero(self):
        self.assertEqual(launch_smoke.distinct_multipane_count(()), 0)


class MaxSplitsRatiosAppliedTests(unittest.TestCase):
    def test_takes_the_max_across_rows(self):
        rows = (make_row(splits_ratios_applied=1), make_row(splits_ratios_applied=2))
        self.assertEqual(launch_smoke.max_splits_ratios_applied(rows), 2)

    def test_none_values_are_ignored_not_treated_as_zero_that_wins(self):
        rows = (make_row(splits_ratios_applied=None), make_row(splits_ratios_applied=1))
        self.assertEqual(launch_smoke.max_splits_ratios_applied(rows), 1)

    def test_all_none_defaults_to_zero(self):
        rows = (make_row(splits_ratios_applied=None), make_row(splits_ratios_applied=None))
        self.assertEqual(launch_smoke.max_splits_ratios_applied(rows), 0)

    def test_no_rows_defaults_to_zero(self):
        self.assertEqual(launch_smoke.max_splits_ratios_applied(()), 0)


class NotdrawableViolationsFromRowsTests(unittest.TestCase):
    """Pins the exact `PaneFirstPaintAudit.verdict` predicate
    (`macOS/Nostromo/UI/PaneFirstPaintAudit.swift`): a pane is a violation iff
    `hasContent && !isLoading && hasWindow && layoutPassCount > 0 &&
    (boundsWidth <= 0 || boundsHeight <= 0)`.
    """

    def _violations(self, pane):
        return launch_smoke.notdrawable_violations_from_rows((make_row(panes=[pane]),))

    def test_no_content_is_healthy(self):
        pane = make_pane(has_content=False, has_window=True, layout_pass_count=1,
                         bounds_width=0, bounds_height=0)
        self.assertEqual(self._violations(pane), ())

    def test_loading_is_healthy(self):
        pane = make_pane(is_loading=True, has_content=True, has_window=True,
                         layout_pass_count=1, bounds_width=0, bounds_height=0)
        self.assertEqual(self._violations(pane), ())

    def test_no_window_is_healthy(self):
        pane = make_pane(has_content=True, has_window=False, layout_pass_count=1,
                         bounds_width=0, bounds_height=0)
        self.assertEqual(self._violations(pane), ())

    def test_zero_layout_passes_is_healthy(self):
        pane = make_pane(has_content=True, has_window=True, layout_pass_count=0,
                         bounds_width=0, bounds_height=0)
        self.assertEqual(self._violations(pane), ())

    def test_content_window_laid_out_zero_width_is_a_violation(self):
        pane = make_pane(has_content=True, is_loading=False, has_window=True,
                         layout_pass_count=1, bounds_width=0, bounds_height=50)
        self.assertEqual(len(self._violations(pane)), 1)

    def test_content_window_laid_out_zero_height_is_a_violation(self):
        pane = make_pane(has_content=True, is_loading=False, has_window=True,
                         layout_pass_count=1, bounds_width=50, bounds_height=0)
        self.assertEqual(len(self._violations(pane)), 1)

    def test_healthy_real_size_is_healthy(self):
        pane = make_pane(has_content=True, is_loading=False, has_window=True,
                         layout_pass_count=1, bounds_width=100, bounds_height=50)
        self.assertEqual(self._violations(pane), ())

    def test_the_same_violation_repeated_across_samples_is_deduplicated(self):
        pane = make_pane("queue", has_content=True, is_loading=False, has_window=True,
                         layout_pass_count=1, bounds_width=0, bounds_height=50)
        rows = (make_row(panes=[dict(pane)]), make_row(panes=[dict(pane)]))
        self.assertEqual(len(launch_smoke.notdrawable_violations_from_rows(rows)), 1)

    def test_distinct_violations_are_each_reported(self):
        pane_a = make_pane("queue", has_content=True, is_loading=False, has_window=True,
                           layout_pass_count=1, bounds_width=0, bounds_height=50)
        pane_b = make_pane("diff", has_content=True, is_loading=False, has_window=True,
                           layout_pass_count=1, bounds_width=50, bounds_height=0)
        rows = (make_row(panes=[pane_a, pane_b]),)
        self.assertEqual(len(launch_smoke.notdrawable_violations_from_rows(rows)), 2)

    def test_no_rows_yields_no_violations(self):
        self.assertEqual(launch_smoke.notdrawable_violations_from_rows(()), ())


# ---------------------------------------------------------------------------
# Process-snapshot isolation invariant: no nostromd/mother/claude process
# started during a run. Per the same discipline `_warn_if_isolation_broken`
# already applies to the focuses.json hash and the
# `defaults export com.hammer.nostromo` domain, this is a third isolation
# invariant — WARNING-only, never a verdict input, and NOT a new GATE/REACH
# detector (the plan caps verdict detectors at 4 GATE + 3 REACH). Only the
# pure parsing/diffing logic is tested here; the impure `ps` invocation and
# the before/after wiring into `run()`/`_isolation_snapshot()` are Cody's.
# ---------------------------------------------------------------------------


class MonitoredProcessNamesConstantTests(unittest.TestCase):
    def test_pinned_exactly(self):
        self.assertEqual(
            launch_smoke.MONITORED_PROCESS_NAMES, frozenset({"nostromd", "mother", "claude"})
        )


class MatchingMonitoredProcessesTests(unittest.TestCase):
    """`matching_monitored_processes` parses `ps -axo pid,command` text and
    returns the `(pid, basename)` pairs whose EXECUTABLE's basename — not
    the whole command string — is exactly a monitored name. Mirrors the
    documented rationale for `another_nostromo_pid`'s path-vs-substring
    distinction: matching anywhere in the command line would flag an
    unrelated process whose arguments merely happen to mention "mother" or
    "claude" (e.g. a coding agent's own invocation, or a script path)."""

    SAMPLE = (
        "  PID COMMAND\n"
        "  501 /usr/local/bin/mother daemon start\n"
        "  502 /opt/homebrew/bin/claude --resume\n"
        "  503 /usr/local/bin/nostromod\n"
        "  504 /usr/local/bin/nostromd\n"
        "  505 /usr/bin/ps -axo pid,command\n"
        "  506 /usr/bin/python3 /Users/x/plans/mother-plan.py\n"
    )

    def test_matches_exactly_the_monitored_processes_by_executable_basename(self):
        result = launch_smoke.matching_monitored_processes(self.SAMPLE)
        self.assertEqual(
            set(result), {(501, "mother"), (502, "claude"), (504, "nostromd")}
        )

    def test_nostromod_is_not_a_substring_or_prefix_match_for_nostromd(self):
        # "nostromod" (pid 503) and "nostromd" (pid 504) are different
        # strings — an exact basename match must tell them apart, or a
        # process that has nothing to do with the real daemon binary would
        # be reported as if it were nostromd.
        result = launch_smoke.matching_monitored_processes(self.SAMPLE)
        self.assertNotIn(503, [pid for pid, _name in result])
        self.assertIn((504, "nostromd"), result)

    def test_a_monitored_name_embedded_only_in_the_arguments_does_not_match(self):
        # pid 506's executable is /usr/bin/python3; "mother" only appears
        # deep in an argument (a plan file path). Only the executable's own
        # basename is ever checked — never the rest of the command string.
        result = launch_smoke.matching_monitored_processes(self.SAMPLE)
        self.assertNotIn(506, [pid for pid, _name in result])

    def test_an_unrelated_process_does_not_match(self):
        result = launch_smoke.matching_monitored_processes(self.SAMPLE)
        self.assertNotIn(505, [pid for pid, _name in result])

    def test_a_basename_that_merely_starts_with_a_monitored_name_does_not_match(self):
        # /opt/foo/mothership -> basename "mothership" -- a prefix of
        # "mother", not equal to it. Exact basename equality only.
        text = "  PID COMMAND\n  600 /opt/foo/mothership\n"
        self.assertEqual(launch_smoke.matching_monitored_processes(text), ())

    def test_empty_string_returns_empty_tuple(self):
        self.assertEqual(launch_smoke.matching_monitored_processes(""), ())

    def test_header_only_returns_empty_tuple(self):
        self.assertEqual(launch_smoke.matching_monitored_processes("  PID COMMAND\n"), ())

    def test_result_is_sorted_by_pid(self):
        result = launch_smoke.matching_monitored_processes(self.SAMPLE)
        self.assertEqual(list(result), sorted(result, key=lambda pair: pair[0]))

    def test_never_raises_on_malformed_or_blank_lines_mixed_in(self):
        text = (
            "  PID COMMAND\n"
            "\n"
            "   \n"
            "  501 /usr/local/bin/mother daemon start\n"
        )
        try:
            result = launch_smoke.matching_monitored_processes(text)
        except Exception as e:  # noqa: BLE001 - the contract says this must never raise
            self.fail(f"matching_monitored_processes raised {type(e).__name__}: {e}")
        self.assertEqual(set(result), {(501, "mother")})


class NewMonitoredProcessesTests(unittest.TestCase):
    """`new_monitored_processes(before, after)` — the entries in `after`
    whose pid wasn't present in `before`. A monitored process that was
    already running before the run started (e.g. the operator's own Mother
    daemon, coincidentally) is excluded even though it's still present in
    `after` — it isn't something this run caused."""

    def test_a_process_absent_before_is_new(self):
        self.assertEqual(
            launch_smoke.new_monitored_processes((), ((501, "mother"),)),
            ((501, "mother"),),
        )

    def test_a_process_present_in_both_before_and_after_is_not_new(self):
        before = ((501, "mother"),)
        after = ((501, "mother"),)
        self.assertEqual(launch_smoke.new_monitored_processes(before, after), ())

    def test_only_the_genuinely_new_pid_is_returned_when_one_was_pre_existing(self):
        before = ((501, "mother"),)
        after = ((501, "mother"), (502, "claude"))
        self.assertEqual(
            launch_smoke.new_monitored_processes(before, after), ((502, "claude"),)
        )

    def test_both_empty_returns_empty(self):
        self.assertEqual(launch_smoke.new_monitored_processes((), ()), ())

    def test_this_is_the_structural_defence_against_the_broker_offline_backstop_firing_silently(self):
        """`AppStore.start()`'s 5s "broker offline, spawn mother daemon
        start" backstop is exactly what `BrokerStub` (answering the hello
        handshake immediately) and the scrubbed child `PATH` in `_child_env`
        exist to prevent from ever firing. If it fires anyway — a bug in
        BrokerStub's timing, a PATH leak, anything — this diff is what
        surfaces it: "mother" shows up as a newly-started process even
        though the whole run otherwise looks perfectly healthy (still
        reaches multi-pane layout, stays alive, settles CPU). Without this
        check, that failure mode passes completely silently.
        """
        before = ()
        after = ((777, "mother"),)
        self.assertEqual(
            launch_smoke.new_monitored_processes(before, after), ((777, "mother"),)
        )


# ---------------------------------------------------------------------------
# Multi-launch accounting: "if more than one launch is observed in a run,
# the report states how many launches crashed and FAILs if that count
# exceeds zero." The FAIL-on-any-attributed-crash behavior already exists
# (`no-attributable-crash-report` FAILs on any non-empty
# `crash_reports_attributed_pids`); what's missing is purely making the
# launch/crash counts explicit and visible in the printed report.
# ---------------------------------------------------------------------------


class MultiLaunchSummaryTests(unittest.TestCase):
    def test_single_healthy_launch(self):
        self.assertEqual(launch_smoke.multi_launch_summary((100,), ()), (1, 0))

    def test_two_launches_observed_one_attributed_to_a_crash(self):
        # e.g. a crash-relaunch within one run's observation window.
        self.assertEqual(launch_smoke.multi_launch_summary((100, 200), (200,)), (2, 1))

    def test_nothing_observed_and_nothing_attributed(self):
        self.assertEqual(launch_smoke.multi_launch_summary((), ()), (0, 0))

    def test_three_launches_two_crashed(self):
        self.assertEqual(
            launch_smoke.multi_launch_summary((100, 200, 300), (200, 300)), (3, 2)
        )

    def test_an_attributed_pid_not_among_observed_pids_does_not_inflate_the_crashed_count(self):
        # An attributed pid this run never actually observed as a launch
        # (e.g. a pid seen only in an unrelated stale scan) must not count
        # towards "crashed launches" — it wasn't a launch this run observed.
        self.assertEqual(launch_smoke.multi_launch_summary((100,), (999,)), (1, 0))


class FormatReportMultiLaunchTests(unittest.TestCase):
    """`format_report` must make the launch/crash accounting visible in the
    printed report, not only implicit in whether `no-attributable-crash-
    report` happened to FAIL. Substring-only assertions — the exact
    formatting/column layout is Cody's call, not part of this contract."""

    def test_report_mentions_launches_observed_and_launches_crashed_counts(self):
        ev = healthy_evidence()._replace(
            observed_pids=(100, 200), crash_reports_attributed_pids=(200,),
        )
        detectors = launch_smoke.evaluate_evidence(ev)
        state, cause = launch_smoke.aggregate(detectors)
        report = launch_smoke.format_report(state, cause, detectors, ev)

        self.assertEqual(launch_smoke.multi_launch_summary(ev.observed_pids,
                                                             ev.crash_reports_attributed_pids),
                          (2, 1))
        self.assertRegex(report, r"launches observed[^0-9]*2")
        self.assertRegex(report, r"launches crashed[^0-9]*1")


# ---------------------------------------------------------------------------
# Fixture daemon: a real AF_UNIX listener, exercised over a real socket.
# ---------------------------------------------------------------------------


class FixtureDaemonTests(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.socket_path = os.path.join(self.tmpdir.name, "nostromd.sock")
        self.frames = load_fixture_frames()
        self.daemon = launch_smoke.FixtureDaemon(self.socket_path, self.frames)
        self.daemon.start()
        self.addCleanup(self.daemon.stop)

    def _connect(self):
        sock = launch_smoke.ipc_connect(self.socket_path, timeout=3.0)
        self.addCleanup(sock.close)
        return sock

    def test_hello_then_subscribe_yields_welcome_then_every_frame_in_order(self):
        sock = self._connect()
        launch_smoke.ipc_write_frame(
            sock, {"type": "hello", "client_id": "redd-test", "protocol_version": 4}
        )
        welcome = launch_smoke.ipc_read_frame(sock)
        self.assertEqual(welcome["type"], "welcome")
        self.assertEqual(welcome["protocol_version"], 4)
        self.assertIn("daemon_pid", welcome)

        launch_smoke.ipc_write_frame(
            sock, {"type": "subscribe", "topics": ["layout"], "renders_decisions": False}
        )
        received = [launch_smoke.ipc_read_frame(sock) for _ in range(len(self.frames))]
        self.assertEqual(received, self.frames)

    def test_subscribe_then_hello_defensive_ordering_still_delivers_every_frame_once(self):
        sock = self._connect()
        launch_smoke.ipc_write_frame(
            sock, {"type": "subscribe", "topics": ["layout"], "renders_decisions": False}
        )
        launch_smoke.ipc_write_frame(
            sock, {"type": "hello", "client_id": "redd-test-2", "protocol_version": 4}
        )
        all_frames = [
            launch_smoke.ipc_read_frame(sock) for _ in range(len(self.frames) + 1)
        ]

        welcomes = [f for f in all_frames if f.get("type") == "welcome"]
        others = [f for f in all_frames if f.get("type") != "welcome"]
        self.assertEqual(len(welcomes), 1, f"expected exactly one welcome, got {all_frames}")
        self.assertEqual(others, self.frames)

    def test_unknown_frame_type_mid_stream_is_drained_and_logged_without_closing_the_connection(self):
        sock = self._connect()
        launch_smoke.ipc_write_frame(
            sock, {"type": "hello", "client_id": "redd-test-3", "protocol_version": 4}
        )
        launch_smoke.ipc_read_frame(sock)  # welcome
        launch_smoke.ipc_write_frame(
            sock, {"type": "subscribe", "topics": ["layout"], "renders_decisions": False}
        )
        for _ in range(len(self.frames)):
            launch_smoke.ipc_read_frame(sock)

        # An unknown/unhandled frame type, sent mid-stream. Must be drained
        # and logged, not close the connection or crash the daemon.
        launch_smoke.ipc_write_frame(sock, {"type": "session_spawn", "tag": "perri"})

        # The connection must still be alive and responsive afterward.
        launch_smoke.ipc_write_frame(sock, {"type": "ping"})
        pong = launch_smoke.ipc_read_frame(sock)
        self.assertEqual(pong["type"], "pong")

        self.assertTrue(
            _wait_until(lambda: "session_spawn" in self.daemon.log),
            f"session_spawn never appeared in daemon.log: {self.daemon.log}",
        )

    def test_stop_is_safe_to_call_more_than_once(self):
        self.daemon.stop()
        self.daemon.stop()  # must not raise


if __name__ == "__main__":
    unittest.main()
