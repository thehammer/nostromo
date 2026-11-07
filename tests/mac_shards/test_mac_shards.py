"""Behavioural tests for `scripts/mac_shards.py` (Mac test sharding).

Pure functions are tested directly; the CLI through `main(argv)` with temp
configs and temp test directories. The real config is checked against the real
macOS/NostromoTests sources.

Run with:
    python3 -m unittest discover -s tests/mac_shards -v
"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPT = os.path.join(REPO_ROOT, "scripts", "mac_shards.py")
REAL_CONFIG = os.path.join(REPO_ROOT, "macOS", "ci", "mac-shards.json")
REAL_TESTS_DIR = os.path.join(REPO_ROOT, "macOS", "NostromoTests")

_spec = importlib.util.spec_from_file_location("mac_shards", SCRIPT)
ms = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ms)

LOG = """\
Test Suite 'All tests' started at 2026-11-07 10:00:00.000.
Test Suite 'NostromoTests.xctest' started at 2026-11-07 10:00:00.001.
Test Suite 'AlphaTests' started at 2026-11-07 10:00:00.002.
Test Case '-[NostromoTests.AlphaTests testOne]' started.
Test Case '-[NostromoTests.AlphaTests testOne]' passed (0.500 seconds).
Test Suite 'AlphaTests' passed at 2026-11-07 10:00:03.000.
\t Executed 3 tests, with 0 failures (0 unexpected) in 1.0 (1.1) seconds
Test Suite 'BetaTests' started at 2026-11-07 10:00:03.001.
Test Suite 'BetaTests' failed at 2026-11-07 10:00:08.000.
\t Executed 12 tests, with 1 test skipped and 2 failures (2 unexpected) in 4.5 (4.75) seconds
Test Suite 'NostromoTests.xctest' passed at 2026-11-07 10:23:00.000.
\t Executed 7704 tests, with 5 tests skipped and 0 failures (0 unexpected) in 1412.386 (1419.333) seconds
Test Suite 'All tests' passed at 2026-11-07 10:23:00.001.
\t Executed 7704 tests, with 5 tests skipped and 0 failures (0 unexpected) in 1412.386 (1419.333) seconds
"""


def run_main(argv):
    """Run the CLI as a real process (exit code, stdout, stderr)."""
    p = subprocess.run([sys.executable, SCRIPT] + list(argv), capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


class ParserTests(unittest.TestCase):
    def test_per_class_durations_come_from_the_class_suite_summary(self):
        d = ms.parse_class_durations(LOG)
        self.assertEqual(set(d), {"AlphaTests", "BetaTests"})
        self.assertAlmostEqual(d["AlphaTests"], 1.1)
        self.assertAlmostEqual(d["BetaTests"], 4.75)

    def test_bundle_and_all_tests_suites_are_ignored(self):
        d = ms.parse_class_durations(LOG)
        self.assertNotIn("All tests", d)
        self.assertNotIn("NostromoTests.xctest", d)
        self.assertFalse(any("xctest" in k or " " in k for k in d))

    def test_log_without_suites_yields_no_durations(self):
        self.assertEqual(ms.parse_class_durations("nothing useful\n"), {})

    def test_executed_is_the_last_total_line(self):
        self.assertEqual(ms.parse_executed(LOG), (7704, 0))

    def test_executed_reports_failures_from_the_last_line(self):
        log = "\t Executed 10 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n" \
              "\t Executed 20 tests, with 3 failures (3 unexpected) in 2.0 (2.0) seconds\n"
        self.assertEqual(ms.parse_executed(log), (20, 3))

    def test_executed_handles_singular_forms(self):
        log = "\t Executed 1 test, with 1 failure (1 unexpected) in 0.1 (0.1) seconds\n"
        self.assertEqual(ms.parse_executed(log), (1, 1))

    def test_executed_is_none_when_no_summary_present(self):
        self.assertIsNone(ms.parse_executed("build failed\n"))

    def test_total_seconds_is_the_last_wall_clock_figure(self):
        self.assertAlmostEqual(ms.parse_total_seconds(LOG), 1419.333)

    def test_total_seconds_none_without_summary(self):
        self.assertIsNone(ms.parse_total_seconds("nope\n"))


class BalanceTests(unittest.TestCase):
    WEIGHTS = {
        "A": 120.0, "B": 100.0, "C": 90.0, "D": 80.0, "E": 70.0, "F": 60.0,
        "G": 55.0, "H": 50.0, "I": 40.0, "J": 30.0, "K": 20.0, "L": 15.0,
        "M": 10.0, "N": 5.0,
    }

    def test_every_class_lands_in_exactly_one_of_three_bins(self):
        bins = ms.balance(self.WEIGHTS)
        self.assertEqual(len(bins), 3)
        flat = [c for b in bins for c in b]
        self.assertEqual(sorted(flat), sorted(self.WEIGHTS))

    def test_three_bins_are_within_15_percent_of_each_other(self):
        bins = ms.balance(self.WEIGHTS)
        loads = [sum(self.WEIGHTS[c] for c in b) for b in bins]
        self.assertLessEqual((max(loads) - min(loads)) / max(loads), 0.15, loads)

    def test_balance_is_deterministic_regardless_of_input_order(self):
        first = ms.balance(self.WEIGHTS)
        reordered = dict(reversed(list(self.WEIGHTS.items())))
        self.assertEqual(first, ms.balance(reordered))
        self.assertEqual(first, ms.balance(dict(self.WEIGHTS)))

    def test_ties_are_broken_by_class_name(self):
        weights = {n: 1.0 for n in "FEDCBA"}
        self.assertEqual(ms.balance(weights), [["A", "D"], ["B", "E"], ["C", "F"]])

    def test_empty_input_gives_three_empty_bins(self):
        self.assertEqual(ms.balance({}), [[], [], []])

    def test_bins_are_sorted_lists(self):
        for b in ms.balance(self.WEIGHTS):
            self.assertEqual(b, sorted(b))


class ArgBuilderTests(unittest.TestCase):
    CONFIG = {
        "shards": [
            {"classes": ["BTests", "ATests"]},
            {"classes": ["CTests"]},
            {"catch_all": True},
        ],
        "expected_min_executed": 1,
    }

    def test_listed_shards_only_run_their_classes(self):
        self.assertEqual(
            ms.xcodebuild_args(self.CONFIG, 1),
            ["-only-testing:NostromoTests/ATests", "-only-testing:NostromoTests/BTests"],
        )
        self.assertEqual(ms.xcodebuild_args(self.CONFIG, 2), ["-only-testing:NostromoTests/CTests"])

    def test_catch_all_skips_every_listed_class_and_nothing_else(self):
        self.assertEqual(
            ms.xcodebuild_args(self.CONFIG, 3),
            [
                "-skip-testing:NostromoTests/ATests",
                "-skip-testing:NostromoTests/BTests",
                "-skip-testing:NostromoTests/CTests",
            ],
        )

    def test_out_of_range_shard_is_rejected(self):
        for bad in (0, 4, -1):
            with self.subTest(shard=bad), self.assertRaises(ms.ConfigError):
                ms.xcodebuild_args(self.CONFIG, bad)


class TempProject(unittest.TestCase):
    """Helpers: a temp tests dir with known classes and a writable config."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = self._tmp.name
        self.tests_dir = os.path.join(self.tmp, "NostromoTests")
        os.makedirs(os.path.join(self.tests_dir, "Sub"))
        self.write_swift("A.swift", "final class ATests: XCTestCase {\n func testA1() {}\n func testA2() {}\n}\n")
        self.write_swift("Sub/B.swift", "class BTests: XCTestCase {\n    func testB() throws {}\n    func helper() {}\n}\n")
        self.write_swift("C.swift", "@MainActor\nfinal class CTests: XCTestCase {\n func testC() {}\n}\n")
        self.write_swift("D.swift", "final class DTests: XCTestCase {\n func testD() {}\n}\n")
        self.config_path = os.path.join(self.tmp, "cfg.json")

    def write_swift(self, rel, text):
        with open(os.path.join(self.tests_dir, rel), "w") as f:
            f.write(text)

    def write_config(self, shards, floor=10, **extra):
        cfg = {"shards": shards, "expected_min_executed": floor}
        cfg.update(extra)
        with open(self.config_path, "w") as f:
            json.dump(cfg, f)

    def good_config(self):
        self.write_config([{"classes": ["ATests"]}, {"classes": ["BTests"]}, {"catch_all": True}])

    def cli(self, *argv):
        return run_main(["--config", self.config_path, "--tests-dir", self.tests_dir] + list(argv))


class DiscoverClassesTests(TempProject):
    def test_finds_classes_in_nested_dirs_with_test_method_counts(self):
        self.assertEqual(
            ms.discover_classes(self.tests_dir),
            {"ATests": 2, "BTests": 1, "CTests": 1, "DTests": 1},
        )

    def test_ignores_non_swift_files(self):
        with open(os.path.join(self.tests_dir, "notes.txt"), "w") as f:
            f.write("final class GhostTests: XCTestCase {}\n")
        self.assertNotIn("GhostTests", ms.discover_classes(self.tests_dir))

    def test_class_without_tests_is_still_discovered(self):
        self.write_swift("E.swift", "final class ETests: XCTestCase {}\n")
        self.assertEqual(ms.discover_classes(self.tests_dir)["ETests"], 0)


class ConfigTests(TempProject):
    def test_valid_config_loads(self):
        self.good_config()
        cfg = ms.load_config(self.config_path)
        self.assertEqual(cfg["expected_min_executed"], 10)

    def test_wrong_shard_count_is_an_error(self):
        for shards in (
            [{"classes": ["ATests"]}, {"catch_all": True}],
            [{"classes": ["ATests"]}, {"classes": ["BTests"]}, {"classes": ["CTests"]}, {"catch_all": True}],
        ):
            with self.subTest(n=len(shards)):
                self.write_config(shards)
                with self.assertRaises(ms.ConfigError):
                    ms.load_config(self.config_path)

    def test_catch_all_must_be_the_last_shard_and_only_it(self):
        self.write_config([{"catch_all": True}, {"classes": ["BTests"]}, {"classes": ["CTests"]}])
        with self.assertRaises(ms.ConfigError):
            ms.load_config(self.config_path)

    def test_a_listed_shard_with_no_classes_is_an_error(self):
        self.write_config([{"classes": []}, {"classes": ["BTests"]}, {"catch_all": True}])
        with self.assertRaises(ms.ConfigError):
            ms.load_config(self.config_path)

    def test_class_listed_in_two_shards_is_an_error_naming_it(self):
        self.write_config([{"classes": ["ATests", "BTests"]}, {"classes": ["BTests"]}, {"catch_all": True}])
        with self.assertRaises(ms.ConfigError) as cm:
            ms.load_config(self.config_path)
        self.assertIn("BTests", str(cm.exception))

    def test_class_duplicated_within_one_shard_is_an_error(self):
        self.write_config([{"classes": ["ATests", "ATests"]}, {"classes": ["BTests"]}, {"catch_all": True}])
        with self.assertRaises(ms.ConfigError):
            ms.load_config(self.config_path)

    def test_floor_must_be_an_integer(self):
        self.write_config([{"classes": ["ATests"]}, {"classes": ["BTests"]}, {"catch_all": True}], floor="many")
        with self.assertRaises(ms.ConfigError):
            ms.load_config(self.config_path)


class CliTests(TempProject):
    def test_validate_ok_for_good_config(self):
        self.good_config()
        code, out, _ = self.cli("validate")
        self.assertEqual(code, 0)
        self.assertIn("ok", out)

    def test_validate_fails_when_a_listed_class_does_not_exist(self):
        self.write_config([{"classes": ["ATests", "NoSuchTests"]}, {"classes": ["BTests"]}, {"catch_all": True}])
        code, _, err = self.cli("validate")
        self.assertEqual(code, 1)
        self.assertIn("NoSuchTests", err)

    def test_validate_fails_on_duplicate_class_config(self):
        self.write_config([{"classes": ["ATests"]}, {"classes": ["ATests"]}, {"catch_all": True}])
        self.assertEqual(self.cli("validate")[0], 1)

    def test_validate_fails_on_wrong_shard_count(self):
        self.write_config([{"classes": ["ATests"]}, {"catch_all": True}])
        self.assertEqual(self.cli("validate")[0], 1)

    def test_validate_fails_on_missing_config_file(self):
        os.remove(self.config_path) if os.path.exists(self.config_path) else None
        self.assertEqual(self.cli("validate")[0], 1)

    def test_args_subcommand_prints_xcodebuild_arguments(self):
        self.good_config()
        code, out, _ = self.cli("args", "--shard", "1")
        self.assertEqual(code, 0)
        self.assertEqual(out.split(), ["-only-testing:NostromoTests/ATests"])
        code, out, _ = self.cli("args", "--shard", "3")
        self.assertEqual(code, 0)
        self.assertEqual(
            out.split(),
            ["-skip-testing:NostromoTests/ATests", "-skip-testing:NostromoTests/BTests"],
        )

    def test_args_fails_for_nonexistent_class(self):
        self.write_config([{"classes": ["Ghost"]}, {"classes": ["BTests"]}, {"catch_all": True}])
        code, out, _ = self.cli("args", "--shard", "1")
        self.assertEqual(code, 1)
        self.assertEqual(out.strip(), "")

    def test_args_rejects_out_of_range_shard(self):
        self.good_config()
        self.assertEqual(self.cli("args", "--shard", "4")[0], 1)

    def test_a_new_unlisted_class_runs_in_the_catch_all_only(self):
        self.good_config()
        _, out3, _ = self.cli("args", "--shard", "3")
        self.assertNotIn("DTests", out3)  # unlisted classes are not skipped, so shard 3 runs them
        for shard in ("1", "2"):
            _, out, _ = self.cli("args", "--shard", shard)
            self.assertNotIn("DTests", out)

    def test_report_writes_json_with_executed_failures_and_classes(self):
        self.good_config()
        log = os.path.join(self.tmp, "x.log")
        out_path = os.path.join(self.tmp, "shard-1.json")
        with open(log, "w") as f:
            f.write(LOG)
        code, _, _ = self.cli("report", "--shard", "1", "--log", log, "--out", out_path)
        self.assertEqual(code, 0)
        with open(out_path) as f:
            report = json.load(f)
        self.assertEqual(report["shard"], 1)
        self.assertEqual(report["executed"], 7704)
        self.assertEqual(report["failures"], 0)
        self.assertAlmostEqual(report["seconds"], 1419.333)
        self.assertEqual(report["classes_run"], ["-only-testing:NostromoTests/ATests"])

    def test_report_for_log_without_summary_has_zero_executed_and_null_failures(self):
        self.good_config()
        log = os.path.join(self.tmp, "x.log")
        out_path = os.path.join(self.tmp, "shard-2.json")
        with open(log, "w") as f:
            f.write("xcodebuild: error: build failed\n")
        code, _, _ = self.cli("report", "--shard", "2", "--log", log, "--out", out_path)
        self.assertEqual(code, 0)
        with open(out_path) as f:
            report = json.load(f)
        self.assertEqual(report["executed"], 0)
        self.assertIsNone(report["failures"])
        self.assertEqual(report["shard"], 2)

    def test_report_fails_when_log_is_missing(self):
        self.good_config()
        code, _, _ = self.cli("report", "--shard", "1", "--log", os.path.join(self.tmp, "none.log"),
                              "--out", os.path.join(self.tmp, "o.json"))
        self.assertEqual(code, 1)


class RegenerateTests(TempProject):
    def log_for(self, durations):
        lines = []
        for name, secs in durations.items():
            lines.append("Test Suite '%s' passed at 2026-11-07 10:00:00.000.\n" % name)
            lines.append("\t Executed 2 tests, with 0 failures (0 unexpected) in %s (%s) seconds\n" % (secs, secs))
        lines.append("\t Executed 1000 tests, with 0 failures (0 unexpected) in 9.0 (9.0) seconds\n")
        path = os.path.join(self.tmp, "full.log")
        with open(path, "w") as f:
            f.writelines(lines)
        return path

    def test_regenerate_from_log_prints_a_config_that_validates(self):
        log = self.log_for({"ATests": 30.0, "BTests": 20.0, "CTests": 10.0})
        code, out, _ = self.cli("regenerate", "--log", log)
        self.assertEqual(code, 0)
        cfg = json.loads(out)
        self.assertEqual(len(cfg["shards"]), 3)
        self.assertTrue(cfg["shards"][2]["catch_all"])
        self.assertEqual(cfg["expected_min_executed"], 970)
        with open(self.config_path, "w") as f:
            f.write(out)
        self.assertEqual(self.cli("validate")[0], 0)

    def test_classes_missing_from_the_log_are_left_for_the_catch_all(self):
        log = self.log_for({"ATests": 30.0, "BTests": 20.0, "CTests": 10.0})
        _, out, _ = self.cli("regenerate", "--log", log)
        listed = [c for s in json.loads(out)["shards"][:2] for c in s["classes"]]
        self.assertNotIn("DTests", listed)

    def test_regenerate_without_write_leaves_config_untouched_and_with_write_replaces_it(self):
        self.good_config()
        before = open(self.config_path).read()
        log = self.log_for({"ATests": 30.0, "BTests": 20.0, "CTests": 10.0})
        self.cli("regenerate", "--log", log)
        self.assertEqual(open(self.config_path).read(), before)
        code, _, _ = self.cli("regenerate", "--log", log, "--write", "--floor", "123")
        self.assertEqual(code, 0)
        self.assertEqual(json.load(open(self.config_path))["expected_min_executed"], 123)

    def test_regenerate_from_source_uses_test_method_counts(self):
        code, out, _ = self.cli("regenerate", "--from-source")
        self.assertEqual(code, 0)
        cfg = json.loads(out)
        listed = [c for s in cfg["shards"][:2] for c in s["classes"]]
        self.assertTrue(listed)
        self.assertTrue(set(listed) <= {"ATests", "BTests", "CTests", "DTests"})
        self.assertTrue(cfg["shards"][2]["catch_all"])

    def test_regenerate_needs_a_source(self):
        self.assertEqual(self.cli("regenerate")[0], 1)

    def test_regenerate_fails_on_log_without_class_durations(self):
        path = os.path.join(self.tmp, "empty.log")
        open(path, "w").write("nothing\n")
        self.assertEqual(self.cli("regenerate", "--log", path)[0], 1)


class RealConfigTests(unittest.TestCase):
    def test_real_config_loads(self):
        cfg = ms.load_config(REAL_CONFIG)
        self.assertGreater(cfg["expected_min_executed"], 0)

    def test_real_config_validates_against_real_test_sources(self):
        code, _, err = run_main(["validate"])
        self.assertEqual(code, 0, err)

    def test_every_listed_class_exists_in_nostromo_tests(self):
        known = ms.discover_classes(REAL_TESTS_DIR)
        self.assertTrue(known)
        cfg = ms.load_config(REAL_CONFIG)
        self.assertEqual(ms.validate_config(cfg, known), [])

    def test_no_class_is_listed_twice_in_the_real_config(self):
        with open(REAL_CONFIG) as f:
            cfg = json.load(f)
        listed = [c for s in cfg["shards"] for c in s.get("classes", [])]
        self.assertEqual(len(listed), len(set(listed)))

    def test_real_config_shards_1_and_2_only_and_3_skips_exactly_their_union(self):
        cfg = ms.load_config(REAL_CONFIG)
        a1, a2, a3 = (ms.xcodebuild_args(cfg, n) for n in (1, 2, 3))
        self.assertTrue(all(a.startswith("-only-testing:NostromoTests/") for a in a1 + a2))
        self.assertTrue(all(a.startswith("-skip-testing:NostromoTests/") for a in a3))
        union = {a.split("/", 1)[1] for a in a1 + a2}
        self.assertEqual({a.split("/", 1)[1] for a in a3}, union)
        self.assertFalse(set(a1) & set(a2))


if __name__ == "__main__":
    unittest.main()
