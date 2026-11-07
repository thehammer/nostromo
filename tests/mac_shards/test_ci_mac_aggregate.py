"""Behavioural tests for `scripts/ci_mac_aggregate.py`, the verdict of the
`Swift tests (Mac app)` aggregate check.

Contract: only `--swift false`, or `--swift true` with every shard job `success`
and good reports from all three shards, passes. A skipped shard job MUST fail
(GitHub treats a skipped required check as passing).

Run with:
    python3 -m unittest discover -s tests/mac_shards -v
"""

import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPT = os.path.join(REPO_ROOT, "scripts", "ci_mac_aggregate.py")

_spec = importlib.util.spec_from_file_location("ci_mac_aggregate", SCRIPT)
agg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agg)

FLOOR = 100


def good_reports(per_shard=40):
    return {
        n: {"shard": n, "executed": per_shard, "failures": 0, "constraint_cases_passed": 1 if n == 1 else 0}
        for n in (1, 2, 3)
    }


class DecideMatrixTests(unittest.TestCase):
    SWIFT = ("true", "false", "", "other")
    RESULTS = ("success", "failure", "cancelled", "skipped")

    def test_only_swift_false_or_true_with_success_and_good_reports_passes(self):
        for swift in self.SWIFT:
            for result in self.RESULTS:
                with self.subTest(swift=swift, shards_result=result):
                    ok, reasons = agg.decide(swift, result, good_reports(), FLOOR)
                    expected = swift == "false" or (swift == "true" and result == "success")
                    self.assertEqual(ok, expected, reasons)
                    self.assertTrue(reasons)

    def test_swift_false_passes_without_any_reports_whatever_the_shard_result(self):
        for result in self.RESULTS:
            with self.subTest(shards_result=result):
                ok, _ = agg.decide("false", result, {}, FLOOR)
                self.assertTrue(ok)

    def test_skipped_shards_with_swift_true_fail_even_with_good_reports(self):
        ok, reasons = agg.decide("true", "skipped", good_reports(), FLOOR)
        self.assertFalse(ok)
        self.assertTrue(any("skipped" in r for r in reasons), reasons)

    def test_missing_report_fails(self):
        for missing in (1, 2, 3):
            with self.subTest(missing=missing):
                reports = good_reports()
                del reports[missing]
                ok, _ = agg.decide("true", "success", reports, 0)
                self.assertFalse(ok)

    def test_no_reports_at_all_fails(self):
        ok, _ = agg.decide("true", "success", {}, 0)
        self.assertFalse(ok)

    def test_a_shard_that_executed_zero_tests_fails(self):
        reports = good_reports()
        reports[2]["executed"] = 0
        ok, _ = agg.decide("true", "success", reports, 0)
        self.assertFalse(ok)

    def test_non_integer_executed_fails(self):
        for bad in (None, "40", 4.0):
            with self.subTest(executed=bad):
                reports = good_reports()
                reports[1]["executed"] = bad
                ok, _ = agg.decide("true", "success", reports, 0)
                self.assertFalse(ok)

    def test_any_nonzero_or_unknown_failures_fails(self):
        for bad in (1, 5, None):
            with self.subTest(failures=bad):
                reports = good_reports()
                reports[3]["failures"] = bad
                ok, _ = agg.decide("true", "success", reports, 0)
                self.assertFalse(ok)

    def test_total_below_floor_fails(self):
        ok, reasons = agg.decide("true", "success", good_reports(33), FLOOR)  # 99 < 100
        self.assertFalse(ok)
        self.assertTrue(any("floor" in r for r in reasons), reasons)

    def test_fails_when_no_shard_ran_the_constraint_tests(self):
        reports = good_reports()
        for r in reports.values():
            r["constraint_cases_passed"] = 0
        ok, reasons = agg.decide("true", "success", reports, FLOOR)
        self.assertFalse(ok)
        self.assertTrue(any("MotherDetailWidthConstraintTests" in r for r in reasons))

    def test_total_exactly_at_floor_passes(self):
        ok, reasons = agg.decide("true", "success", good_reports(), 120)
        self.assertTrue(ok, reasons)


class MainCliTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = self._tmp.name
        self.config = os.path.join(self.tmp, "cfg.json")
        with open(self.config, "w") as f:
            json.dump({"expected_min_executed": FLOOR}, f)
        self.reports = os.path.join(self.tmp, "reports")
        os.makedirs(self.reports)

    def write_report(self, shard, executed=40, failures=0, nested=False):
        d = self.reports
        if nested:  # actions/download-artifact puts each artifact in its own subdir
            d = os.path.join(d, "mac-shard-%d" % shard)
            os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "shard-%d.json" % shard), "w") as f:
            json.dump({"shard": shard, "executed": executed, "failures": failures,
                       "constraint_cases_passed": 1 if shard == 1 else 0}, f)

    def run_main(self, swift, result, reports=None, config=None):
        argv = [
            "--swift", swift, "--shards-result", result,
            "--reports", reports or self.reports, "--config", config or self.config,
        ]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = agg.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_exit_0_when_all_shards_reported_good(self):
        for n in (1, 2, 3):
            self.write_report(n)
        self.assertEqual(self.run_main("true", "success")[0], 0)

    def test_reports_in_artifact_subdirectories_are_found(self):
        for n in (1, 2, 3):
            self.write_report(n, nested=True)
        self.assertEqual(self.run_main("true", "success")[0], 0)

    def test_exit_0_for_swift_false_with_no_reports_dir(self):
        code, _, _ = self.run_main("false", "skipped", reports=os.path.join(self.tmp, "nope"))
        self.assertEqual(code, 0)

    def test_exit_1_when_shards_skipped_with_swift_true(self):
        for n in (1, 2, 3):
            self.write_report(n)
        code, out, _ = self.run_main("true", "skipped")
        self.assertEqual(code, 1)
        self.assertIn("FAIL", out)

    def test_exit_1_when_a_report_is_missing(self):
        self.write_report(1)
        self.write_report(2)
        self.assertEqual(self.run_main("true", "success")[0], 1)

    def test_exit_1_when_reports_dir_is_absent_and_swift_true(self):
        code, _, _ = self.run_main("true", "success", reports=os.path.join(self.tmp, "nope"))
        self.assertEqual(code, 1)

    def test_exit_1_when_a_shard_has_failures(self):
        self.write_report(1)
        self.write_report(2, failures=2)
        self.write_report(3)
        self.assertEqual(self.run_main("true", "success")[0], 1)

    def test_exit_1_when_total_is_below_the_config_floor(self):
        for n in (1, 2, 3):
            self.write_report(n, executed=10)
        self.assertEqual(self.run_main("true", "success")[0], 1)

    def test_exit_1_when_config_is_unreadable_even_for_swift_false(self):
        code, _, err = self.run_main("false", "success", config=os.path.join(self.tmp, "missing.json"))
        self.assertEqual(code, 1)
        self.assertTrue(err)

    def test_exit_1_when_config_has_no_floor(self):
        with open(self.config, "w") as f:
            json.dump({}, f)
        for n in (1, 2, 3):
            self.write_report(n)
        self.assertEqual(self.run_main("true", "success")[0], 1)


if __name__ == "__main__":
    unittest.main()
