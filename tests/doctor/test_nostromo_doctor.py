"""Behavioral tests for bin/nostromo-doctor.

These tests exercise the pure-function contract of the doctor script: status
model, exit-code/worst-status aggregation, report formatting, load/etime/ps
parsing, staleness classification, error-log filtering, and the per-session
stuck-signal classifier. They do NOT exercise the live-system checks (socket
handshake, ps/git/launchctl subprocess execution, filesystem globbing) —
those are covered by the manual verification checklist referenced in
tests/doctor/README.md.

Run with:
    /usr/bin/python3 -m unittest discover -s tests/doctor
"""

import datetime
import importlib.machinery
import importlib.util
import os
import unittest

SCRIPT_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "bin", "nostromo-doctor")
# The script is extensionless (bin/nostromo-doctor, not .py), so
# spec_from_file_location can't infer a loader from the suffix and returns
# None unless we hand it one explicitly.
_loader = importlib.machinery.SourceFileLoader("nostromo_doctor", SCRIPT_PATH)
spec = importlib.util.spec_from_file_location("nostromo_doctor", SCRIPT_PATH, loader=_loader)
doctor = importlib.util.module_from_spec(spec)
_loader.exec_module(doctor)


def make_result(name="check", status=doctor.STATUS_OK, detail="detail", next_step=None):
    return doctor.CheckResult(name=name, status=status, detail=detail, next_step=next_step)


class ValidateCheckResultTests(unittest.TestCase):
    def test_ok_result_with_no_next_step_is_valid(self):
        result = make_result(status=doctor.STATUS_OK, next_step=None)
        # Should not raise.
        doctor.validate_check_result(result)

    def test_ok_result_with_a_next_step_is_rejected(self):
        result = make_result(status=doctor.STATUS_OK, next_step="do something")
        with self.assertRaises(ValueError):
            doctor.validate_check_result(result)

    def test_non_ok_result_missing_next_step_is_rejected(self):
        for status in (doctor.STATUS_WARN, doctor.STATUS_FAIL, doctor.STATUS_INCONCLUSIVE):
            with self.subTest(status=status):
                result = make_result(status=status, next_step=None)
                with self.assertRaises(ValueError):
                    doctor.validate_check_result(result)

    def test_non_ok_result_with_empty_string_next_step_is_rejected(self):
        for status in (doctor.STATUS_WARN, doctor.STATUS_FAIL, doctor.STATUS_INCONCLUSIVE):
            with self.subTest(status=status):
                result = make_result(status=status, next_step="")
                with self.assertRaises(ValueError):
                    doctor.validate_check_result(result)

    def test_non_ok_result_with_a_next_step_is_valid(self):
        for status in (doctor.STATUS_WARN, doctor.STATUS_FAIL, doctor.STATUS_INCONCLUSIVE):
            with self.subTest(status=status):
                result = make_result(status=status, next_step="run make install")
                doctor.validate_check_result(result)


class ComputeExitCodeTests(unittest.TestCase):
    def test_all_ok_exits_zero(self):
        results = [make_result(status=doctor.STATUS_OK)]
        self.assertEqual(doctor.compute_exit_code(results), 0)

    def test_ok_and_warn_mix_exits_zero(self):
        results = [
            make_result(status=doctor.STATUS_OK),
            make_result(status=doctor.STATUS_WARN, next_step="look into it"),
        ]
        self.assertEqual(doctor.compute_exit_code(results), 0)

    def test_ok_warn_and_inconclusive_mix_exits_zero(self):
        results = [
            make_result(status=doctor.STATUS_OK),
            make_result(status=doctor.STATUS_WARN, next_step="look into it"),
            make_result(status=doctor.STATUS_INCONCLUSIVE, next_step="check manually"),
        ]
        self.assertEqual(doctor.compute_exit_code(results), 0)

    def test_any_fail_exits_one_regardless_of_other_statuses(self):
        results = [
            make_result(status=doctor.STATUS_OK),
            make_result(status=doctor.STATUS_WARN, next_step="look into it"),
            make_result(status=doctor.STATUS_FAIL, next_step="restart it"),
            make_result(status=doctor.STATUS_INCONCLUSIVE, next_step="check manually"),
        ]
        self.assertEqual(doctor.compute_exit_code(results), 1)

    def test_single_fail_exits_one(self):
        results = [make_result(status=doctor.STATUS_FAIL, next_step="restart it")]
        self.assertEqual(doctor.compute_exit_code(results), 1)

    def test_empty_results_exits_zero(self):
        self.assertEqual(doctor.compute_exit_code([]), 0)


class WorstStatusTests(unittest.TestCase):
    def test_empty_list_is_ok(self):
        self.assertEqual(doctor.worst_status([]), doctor.STATUS_OK)

    def test_all_ok_is_ok(self):
        results = [make_result(status=doctor.STATUS_OK), make_result(status=doctor.STATUS_OK)]
        self.assertEqual(doctor.worst_status(results), doctor.STATUS_OK)

    def test_fail_beats_everything(self):
        results = [
            make_result(status=doctor.STATUS_OK),
            make_result(status=doctor.STATUS_WARN, next_step="x"),
            make_result(status=doctor.STATUS_INCONCLUSIVE, next_step="x"),
            make_result(status=doctor.STATUS_FAIL, next_step="x"),
        ]
        self.assertEqual(doctor.worst_status(results), doctor.STATUS_FAIL)

    def test_warn_beats_inconclusive_and_ok(self):
        results = [
            make_result(status=doctor.STATUS_OK),
            make_result(status=doctor.STATUS_INCONCLUSIVE, next_step="x"),
            make_result(status=doctor.STATUS_WARN, next_step="x"),
        ]
        self.assertEqual(doctor.worst_status(results), doctor.STATUS_WARN)

    def test_inconclusive_beats_ok_when_no_warn_or_fail(self):
        results = [
            make_result(status=doctor.STATUS_OK),
            make_result(status=doctor.STATUS_INCONCLUSIVE, next_step="x"),
        ]
        self.assertEqual(doctor.worst_status(results), doctor.STATUS_INCONCLUSIVE)

    def test_precedence_order_is_fail_warn_inconclusive_ok_table_driven(self):
        cases = [
            ([doctor.STATUS_OK], doctor.STATUS_OK),
            ([doctor.STATUS_INCONCLUSIVE], doctor.STATUS_INCONCLUSIVE),
            ([doctor.STATUS_WARN], doctor.STATUS_WARN),
            ([doctor.STATUS_FAIL], doctor.STATUS_FAIL),
            ([doctor.STATUS_OK, doctor.STATUS_INCONCLUSIVE], doctor.STATUS_INCONCLUSIVE),
            ([doctor.STATUS_INCONCLUSIVE, doctor.STATUS_WARN], doctor.STATUS_WARN),
            ([doctor.STATUS_WARN, doctor.STATUS_FAIL], doctor.STATUS_FAIL),
            (
                [doctor.STATUS_FAIL, doctor.STATUS_WARN, doctor.STATUS_INCONCLUSIVE, doctor.STATUS_OK],
                doctor.STATUS_FAIL,
            ),
        ]
        for statuses, expected in cases:
            with self.subTest(statuses=statuses):
                results = [
                    make_result(status=s, next_step=(None if s == doctor.STATUS_OK else "x"))
                    for s in statuses
                ]
                self.assertEqual(doctor.worst_status(results), expected)


class FormatCheckLineTests(unittest.TestCase):
    def test_ok_line_contains_label_name_and_detail(self):
        result = make_result(name="daemon liveness", status=doctor.STATUS_OK, detail="pid 123, up 4h", next_step=None)
        line = doctor.format_check_line(result)
        self.assertIn(doctor.STATUS_OK, line)
        self.assertIn("daemon liveness", line)
        self.assertIn("pid 123, up 4h", line)

    def test_line_with_no_next_step_does_not_contain_next_step_text(self):
        sentinel = "run make install && restart nostromd"
        with_next_step = make_result(
            name="daemon liveness", status=doctor.STATUS_WARN, detail="pid stale", next_step=sentinel
        )
        without_next_step = make_result(
            name="daemon liveness", status=doctor.STATUS_OK, detail="pid stale", next_step=None
        )
        # Sanity: the sentinel text does show up when next_step is set...
        self.assertIn(sentinel, doctor.format_check_line(with_next_step))
        # ...but must not appear at all when next_step is None.
        self.assertNotIn(sentinel, doctor.format_check_line(without_next_step))

    def test_failing_line_contains_label_name_detail_and_next_step(self):
        result = make_result(
            name="ipc channel",
            status=doctor.STATUS_FAIL,
            detail="socket present but not responding",
            next_step="restart the daemon: make install && nostromd",
        )
        line = doctor.format_check_line(result)
        self.assertIn(doctor.STATUS_FAIL, line)
        self.assertIn("ipc channel", line)
        self.assertIn("socket present but not responding", line)
        self.assertIn("restart the daemon: make install && nostromd", line)

    def test_warn_line_contains_next_step(self):
        result = make_result(
            name="load average",
            status=doctor.STATUS_WARN,
            detail="load 12.0 across 8 cores",
            next_step="check for runaway processes with `top`",
        )
        line = doctor.format_check_line(result)
        self.assertIn(doctor.STATUS_WARN, line)
        self.assertIn("check for runaway processes with `top`", line)


class FormatReportTests(unittest.TestCase):
    def test_report_contains_every_check_name_and_status(self):
        results = [
            make_result(name="daemon liveness", status=doctor.STATUS_OK, detail="pid 100"),
            make_result(
                name="ipc channel",
                status=doctor.STATUS_FAIL,
                detail="no response",
                next_step="restart the daemon",
            ),
        ]
        report = doctor.format_report(results)
        self.assertIn("daemon liveness", report)
        self.assertIn("ipc channel", report)
        self.assertIn(doctor.STATUS_OK, report)
        self.assertIn(doctor.STATUS_FAIL, report)

    def test_report_summary_line_states_worst_status(self):
        results = [
            make_result(name="a", status=doctor.STATUS_OK),
            make_result(name="b", status=doctor.STATUS_WARN, next_step="x"),
        ]
        report = doctor.format_report(results)
        self.assertIn("Summary", report)
        self.assertIn(doctor.worst_status(results), report)

    def test_report_summary_reflects_fail_when_present(self):
        results = [
            make_result(name="a", status=doctor.STATUS_OK),
            make_result(name="b", status=doctor.STATUS_WARN, next_step="x"),
            make_result(name="c", status=doctor.STATUS_FAIL, next_step="y"),
        ]
        report = doctor.format_report(results)
        self.assertIn("Summary", report)
        self.assertIn(doctor.STATUS_FAIL, report)

    def test_report_of_empty_results_still_has_a_summary_line(self):
        report = doctor.format_report([])
        self.assertIn("Summary", report)
        self.assertIn(doctor.STATUS_OK, report)


class ParseLoadAverageTests(unittest.TestCase):
    def test_parses_macos_style_load_averages_plural(self):
        text = "13:19  up 6 mins, 3 users, load averages: 20.40 44.98 26.12"
        self.assertEqual(doctor.parse_load_average(text), 20.40)

    def test_parses_linux_style_load_average_singular_with_commas(self):
        text = "13:19:01 up 2 days,  4:12,  1 user,  load average: 0.52, 0.58, 0.59"
        self.assertEqual(doctor.parse_load_average(text), 0.52)

    def test_raises_value_error_when_no_load_average_section_present(self):
        text = "13:19  up 6 mins, 3 users"
        with self.assertRaises(ValueError):
            doctor.parse_load_average(text)

    def test_raises_value_error_on_empty_string(self):
        with self.assertRaises(ValueError):
            doctor.parse_load_average("")


class ClassifyLoadTests(unittest.TestCase):
    def test_ratio_at_or_below_one_is_ok(self):
        self.assertEqual(doctor.classify_load(load1=4.0, cores=8), doctor.STATUS_OK)
        self.assertEqual(doctor.classify_load(load1=8.0, cores=8), doctor.STATUS_OK)  # exactly 1.0

    def test_ratio_just_above_one_is_warn(self):
        self.assertEqual(doctor.classify_load(load1=8.1, cores=8), doctor.STATUS_WARN)

    def test_ratio_at_exactly_two_is_warn(self):
        self.assertEqual(doctor.classify_load(load1=16.0, cores=8), doctor.STATUS_WARN)

    def test_ratio_just_above_two_is_fail(self):
        self.assertEqual(doctor.classify_load(load1=16.01, cores=8), doctor.STATUS_FAIL)

    def test_ratio_far_above_two_is_fail(self):
        self.assertEqual(doctor.classify_load(load1=200.0, cores=8), doctor.STATUS_FAIL)

    def test_boundary_table(self):
        cases = [
            (0.0, doctor.STATUS_OK),
            (0.5, doctor.STATUS_OK),
            (1.0, doctor.STATUS_OK),
            (1.0001, doctor.STATUS_WARN),
            (2.0, doctor.STATUS_WARN),
            (2.0001, doctor.STATUS_FAIL),
        ]
        cores = 1
        for ratio, expected in cases:
            with self.subTest(ratio=ratio):
                self.assertEqual(doctor.classify_load(load1=ratio * cores, cores=cores), expected)


class ParsePsRowsTests(unittest.TestCase):
    FIELD_NAMES = ["pid", "ppid", "etime", "%cpu", "stat", "command"]

    def test_parses_header_and_rows_into_dicts(self):
        ps_output = (
            "  PID  PPID ETIME %CPU STAT COMMAND\n"
            "  100     1 04:22  0.1 S    /Users/hammer/.local/bin/nostromd\n"
            "  205   100 00:05 12.0 S    claude --agent perri\n"
        )
        rows = doctor.parse_ps_rows(ps_output, self.FIELD_NAMES)
        self.assertEqual(
            rows,
            [
                {
                    "pid": "100",
                    "ppid": "1",
                    "etime": "04:22",
                    "%cpu": "0.1",
                    "stat": "S",
                    "command": "/Users/hammer/.local/bin/nostromd",
                },
                {
                    "pid": "205",
                    "ppid": "100",
                    "etime": "00:05",
                    "%cpu": "12.0",
                    "stat": "S",
                    "command": "claude --agent perri",
                },
            ],
        )

    def test_command_field_captures_full_remainder_including_spaces(self):
        ps_output = "PID CMD\n" "1 claude --agent perri --flag value\n"
        rows = doctor.parse_ps_rows(ps_output, ["pid", "command"])
        self.assertEqual(rows[0]["command"], "claude --agent perri --flag value")

    def test_blank_lines_are_skipped(self):
        ps_output = "PID CMD\n" "1 foo\n" "\n" "   \n" "2 bar\n"
        rows = doctor.parse_ps_rows(ps_output, ["pid", "command"])
        self.assertEqual(len(rows), 2)
        self.assertEqual([r["pid"] for r in rows], ["1", "2"])

    def test_no_data_rows_yields_empty_list(self):
        ps_output = "PID CMD\n"
        rows = doctor.parse_ps_rows(ps_output, ["pid", "command"])
        self.assertEqual(rows, [])


class BuildDescendantPidsTests(unittest.TestCase):
    def test_direct_children_are_descendants(self):
        rows = [
            {"pid": "1", "ppid": "0"},
            {"pid": "2", "ppid": "1"},
            {"pid": "3", "ppid": "1"},
        ]
        self.assertEqual(doctor.build_descendant_pids(rows, 1), {2, 3})

    def test_multi_level_chain_includes_grandchildren_and_great_grandchildren(self):
        # 1 -> 2 -> 3 -> 4 (four levels deep)
        rows = [
            {"pid": "1", "ppid": "0"},
            {"pid": "2", "ppid": "1"},
            {"pid": "3", "ppid": "2"},
            {"pid": "4", "ppid": "3"},
            {"pid": "999", "ppid": "0"},  # unrelated process, must be excluded
        ]
        self.assertEqual(doctor.build_descendant_pids(rows, 1), {2, 3, 4})

    def test_root_pid_itself_is_excluded(self):
        rows = [
            {"pid": "1", "ppid": "0"},
            {"pid": "2", "ppid": "1"},
        ]
        result = doctor.build_descendant_pids(rows, 1)
        self.assertNotIn(1, result)

    def test_unrelated_subtree_is_excluded(self):
        rows = [
            {"pid": "1", "ppid": "0"},
            {"pid": "2", "ppid": "1"},
            {"pid": "10", "ppid": "0"},
            {"pid": "11", "ppid": "10"},
        ]
        self.assertEqual(doctor.build_descendant_pids(rows, 1), {2})

    def test_pid_with_no_children_returns_empty_set(self):
        rows = [
            {"pid": "1", "ppid": "0"},
            {"pid": "2", "ppid": "1"},
        ]
        self.assertEqual(doctor.build_descendant_pids(rows, 2), set())

    def test_cyclic_parentage_does_not_infinite_loop(self):
        # Pathological/corrupted data: 1 -> 2 -> 1 (cycle). Must terminate.
        rows = [
            {"pid": "1", "ppid": "2"},
            {"pid": "2", "ppid": "1"},
        ]
        result = doctor.build_descendant_pids(rows, 1)
        # Whatever the exact membership, this must return promptly (no hang)
        # and must be a set of ints.
        self.assertIsInstance(result, set)
        for pid in result:
            self.assertIsInstance(pid, int)


class NormalizeCommandBasenameTests(unittest.TestCase):
    def test_extracts_basename_of_first_token_with_path(self):
        self.assertEqual(
            doctor.normalize_command_basename("/usr/bin/claude --agent perri"), "claude"
        )

    def test_extracts_first_token_without_path(self):
        self.assertEqual(doctor.normalize_command_basename("claude --agent fred"), "claude")

    def test_blank_command_returns_empty_string(self):
        self.assertEqual(doctor.normalize_command_basename("  "), "")

    def test_empty_command_returns_empty_string(self):
        self.assertEqual(doctor.normalize_command_basename(""), "")

    def test_ignores_arguments_entirely(self):
        self.assertEqual(
            doctor.normalize_command_basename("/Users/hammer/.local/bin/nostromd --flag /path/with/slash"),
            "nostromd",
        )


class TallyCommandPileupTests(unittest.TestCase):
    def test_tallies_counts_by_normalized_basename(self):
        rows = [
            {"command": "/usr/bin/claude --agent perri"},
            {"command": "claude --agent fred"},
            {"command": "/usr/bin/claude --agent teri"},
            {"command": "/Users/hammer/.local/bin/nostromd"},
        ]
        counts = doctor.tally_command_pileup(rows)
        self.assertEqual(counts, {"claude": 3, "nostromd": 1})

    def test_empty_rows_yields_empty_tally(self):
        self.assertEqual(doctor.tally_command_pileup([]), {})


class ClassifyPileupCountsTests(unittest.TestCase):
    def test_count_below_warn_threshold_is_excluded(self):
        counts = {"stuck-thing": 7}
        result = doctor.classify_pileup_counts(counts)
        self.assertEqual(result, [])

    def test_count_at_warn_threshold_is_warn(self):
        counts = {"stuck-thing": 8}
        result = doctor.classify_pileup_counts(counts)
        self.assertEqual(result, [("stuck-thing", 8, doctor.STATUS_WARN)])

    def test_count_just_below_fail_threshold_is_warn(self):
        counts = {"stuck-thing": 24}
        result = doctor.classify_pileup_counts(counts)
        self.assertEqual(result, [("stuck-thing", 24, doctor.STATUS_WARN)])

    def test_count_at_fail_threshold_is_fail(self):
        counts = {"stuck-thing": 25}
        result = doctor.classify_pileup_counts(counts)
        self.assertEqual(result, [("stuck-thing", 25, doctor.STATUS_FAIL)])

    def test_incident_five_real_number_of_65_is_fail(self):
        counts = {"stuck-thing": 65}
        result = doctor.classify_pileup_counts(counts)
        self.assertEqual(result, [("stuck-thing", 65, doctor.STATUS_FAIL)])

    def test_multiple_commands_classified_independently(self):
        counts = {"quiet": 2, "warny": 10, "faily": 30}
        result = doctor.classify_pileup_counts(counts)
        self.assertEqual(
            set(result),
            {("warny", 10, doctor.STATUS_WARN), ("faily", 30, doctor.STATUS_FAIL)},
        )

    def test_custom_thresholds_are_respected(self):
        counts = {"thing": 5}
        result = doctor.classify_pileup_counts(counts, warn_threshold=5, fail_threshold=10)
        self.assertEqual(result, [("thing", 5, doctor.STATUS_WARN)])

    def test_boundary_table(self):
        cases = [
            (7, None),
            (8, doctor.STATUS_WARN),
            (24, doctor.STATUS_WARN),
            (25, doctor.STATUS_FAIL),
            (65, doctor.STATUS_FAIL),
        ]
        for count, expected_status in cases:
            with self.subTest(count=count):
                result = doctor.classify_pileup_counts({"x": count})
                if expected_status is None:
                    self.assertEqual(result, [])
                else:
                    self.assertEqual(result, [("x", count, expected_status)])


class FindZombieRowsTests(unittest.TestCase):
    def test_row_with_z_in_stat_is_a_zombie(self):
        rows = [{"stat": "Z", "command": "foo"}, {"stat": "S", "command": "bar"}]
        self.assertEqual(doctor.find_zombie_rows(rows), [rows[0]])

    def test_row_with_z_plus_other_stat_flags_is_a_zombie(self):
        rows = [{"stat": "Z+", "command": "foo"}]
        self.assertEqual(doctor.find_zombie_rows(rows), rows)

    def test_row_with_defunct_in_command_is_a_zombie(self):
        rows = [{"stat": "S", "command": "foo <defunct>"}]
        self.assertEqual(doctor.find_zombie_rows(rows), rows)

    def test_healthy_row_is_not_a_zombie(self):
        rows = [{"stat": "S", "command": "claude --agent perri"}]
        self.assertEqual(doctor.find_zombie_rows(rows), [])

    def test_missing_fields_default_gracefully_and_are_not_zombies(self):
        rows = [{}]
        self.assertEqual(doctor.find_zombie_rows(rows), [])

    def test_empty_rows_returns_empty_list(self):
        self.assertEqual(doctor.find_zombie_rows([]), [])

    def test_returns_matching_rows_unchanged(self):
        zombie_row = {"pid": "42", "stat": "Z", "command": "leftover"}
        rows = [zombie_row, {"pid": "1", "stat": "S", "command": "alive"}]
        result = doctor.find_zombie_rows(rows)
        self.assertEqual(result, [zombie_row])
        self.assertIs(result[0], zombie_row)


class ParseEtimeTests(unittest.TestCase):
    def test_minutes_seconds_format(self):
        self.assertEqual(doctor.parse_etime("04:22"), 4 * 60 + 22)

    def test_hours_minutes_seconds_format(self):
        self.assertEqual(doctor.parse_etime("01:04:22"), 1 * 3600 + 4 * 60 + 22)

    def test_days_hours_minutes_seconds_format(self):
        self.assertEqual(doctor.parse_etime("2-01:04:22"), 2 * 86400 + 1 * 3600 + 4 * 60 + 22)

    def test_seconds_only_edge_case(self):
        self.assertEqual(doctor.parse_etime("00:05"), 5)

    def test_zero_elapsed_time(self):
        self.assertEqual(doctor.parse_etime("00:00"), 0)

    def test_unparseable_input_raises_value_error(self):
        with self.assertRaises(ValueError):
            doctor.parse_etime("not-a-time")

    def test_empty_string_raises_value_error(self):
        with self.assertRaises(ValueError):
            doctor.parse_etime("")

    def test_format_table(self):
        cases = [
            ("04:22", 262),
            ("01:04:22", 3862),
            ("2-01:04:22", 176662),
        ]
        for etime, expected_seconds in cases:
            with self.subTest(etime=etime):
                self.assertEqual(doctor.parse_etime(etime), expected_seconds)


class ClassifyStalenessTests(unittest.TestCase):
    def test_artifact_absent_when_mtime_is_none(self):
        self.assertEqual(doctor.classify_staleness(None, 1000.0), "artifact_absent")

    def test_artifact_absent_takes_precedence_over_missing_commit_info(self):
        self.assertEqual(doctor.classify_staleness(None, None), "artifact_absent")

    def test_no_commit_info_when_commit_time_is_none_but_artifact_present(self):
        self.assertEqual(doctor.classify_staleness(1000.0, None), "no_commit_info")

    def test_current_when_artifact_newer_than_commit(self):
        self.assertEqual(doctor.classify_staleness(2000.0, 1000.0), "current")

    def test_current_when_artifact_mtime_exactly_equals_commit_time(self):
        self.assertEqual(doctor.classify_staleness(1000.0, 1000.0), "current")

    def test_current_when_within_tolerance_window(self):
        # artifact is 1.0s older than commit, tolerance is 2.0s -> still current
        self.assertEqual(doctor.classify_staleness(999.0, 1000.0, tolerance=2.0), "current")

    def test_stale_when_outside_tolerance_window(self):
        # artifact is 3.0s older than commit, tolerance is 2.0s -> stale
        self.assertEqual(doctor.classify_staleness(997.0, 1000.0, tolerance=2.0), "stale")

    def test_stale_when_artifact_is_far_older(self):
        self.assertEqual(doctor.classify_staleness(0.0, 1000000.0), "stale")

    def test_exactly_at_tolerance_boundary_is_current(self):
        # artifact_mtime == commit_time - tolerance -> current (>= comparison)
        self.assertEqual(doctor.classify_staleness(998.0, 1000.0, tolerance=2.0), "current")


class StalenessToStatusTests(unittest.TestCase):
    def test_mapping_table(self):
        cases = [
            ("current", doctor.STATUS_OK),
            ("stale", doctor.STATUS_WARN),
            ("artifact_absent", doctor.STATUS_INCONCLUSIVE),
            ("no_commit_info", doctor.STATUS_INCONCLUSIVE),
        ]
        for reason, expected_status in cases:
            with self.subTest(reason=reason):
                self.assertEqual(doctor.staleness_to_status(reason), expected_status)


class FilterRecentErrorLinesTests(unittest.TestCase):
    NOW = datetime.datetime(2026, 8, 10, 18, 20, 0, tzinfo=datetime.timezone.utc)
    NOW_TS = NOW.timestamp()
    WINDOW_SECONDS = 300.0  # 5 minutes

    @staticmethod
    def _iso(dt):
        return dt.strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

    def _line(self, level, offset_seconds, message="boom", target="nostromo::x"):
        ts = self._iso(self.NOW - datetime.timedelta(seconds=offset_seconds))
        return (
            '{"timestamp":"%s","level":"%s","fields":{"message":"%s"},"target":"%s"}'
            % (ts, level, message, target)
        )

    def test_recent_error_is_kept(self):
        lines = [self._line("ERROR", 10)]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["level"], "ERROR")

    def test_recent_warn_is_excluded(self):
        lines = [self._line("WARN", 10)]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(result, [])

    def test_recent_info_is_excluded(self):
        lines = [self._line("INFO", 10)]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(result, [])

    def test_old_error_outside_window_is_excluded(self):
        lines = [self._line("ERROR", self.WINDOW_SECONDS + 60)]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(result, [])

    def test_error_exactly_at_window_boundary_is_kept(self):
        lines = [self._line("ERROR", self.WINDOW_SECONDS)]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(len(result), 1)

    def test_malformed_json_line_is_skipped_without_raising(self):
        lines = ["not valid json {{{"]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(result, [])

    def test_valid_json_missing_level_key_is_skipped_without_raising(self):
        ts = self._iso(self.NOW - datetime.timedelta(seconds=5))
        lines = ['{"timestamp":"%s","fields":{"message":"boom"}}' % ts]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(result, [])

    def test_valid_json_missing_timestamp_key_is_skipped_without_raising(self):
        lines = ['{"level":"ERROR","fields":{"message":"boom"}}']
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(result, [])

    def test_unparseable_timestamp_is_skipped_without_raising(self):
        lines = ['{"level":"ERROR","timestamp":"not-a-timestamp"}']
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(result, [])

    def test_empty_list_input_yields_empty_list_output(self):
        self.assertEqual(doctor.filter_recent_error_lines([], self.NOW_TS, self.WINDOW_SECONDS), [])

    def test_multiple_recent_errors_all_kept_in_order(self):
        lines = [
            self._line("ERROR", 200, message="first"),
            self._line("WARN", 5, message="ignored"),
            self._line("ERROR", 100, message="second"),
            self._line("ERROR", 1, message="third"),
        ]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        messages = [entry["fields"]["message"] for entry in result]
        self.assertEqual(messages, ["first", "second", "third"])

    def test_mixed_malformed_and_valid_lines_only_keeps_valid_recent_errors(self):
        lines = [
            "garbage",
            self._line("ERROR", 10, message="keep-me"),
            '{"level":"ERROR"}',  # missing timestamp
            self._line("ERROR", self.WINDOW_SECONDS + 1, message="too-old"),
        ]
        result = doctor.filter_recent_error_lines(lines, self.NOW_TS, self.WINDOW_SECONDS)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["fields"]["message"], "keep-me")


class ClassifySessionSignalTests(unittest.TestCase):
    """The cry-wolf-critical classifier. Table-driven per the spec."""

    def test_signal_table(self):
        cases = [
            (
                "long idle is not a warn",
                dict(alive=True, state="Idle", transcript_age_seconds=99999, cpu_percent=0.5),
                (doctor.STATUS_OK, None),
            ),
            (
                "awaiting permission is not a warn",
                dict(alive=True, state="AwaitingPermission", transcript_age_seconds=99999, cpu_percent=0.1),
                (doctor.STATUS_OK, None),
            ),
            (
                "mid-turn recently active is ok",
                dict(alive=True, state="MidTurn", transcript_age_seconds=10, cpu_percent=50.0),
                (doctor.STATUS_OK, None),
            ),
            (
                "mid-turn stalled past threshold is warn",
                dict(alive=True, state="MidTurn", transcript_age_seconds=600, cpu_percent=50.0),
                (doctor.STATUS_WARN, "in-flight turn stalled"),
            ),
            (
                "crashed state is warn regardless of other fields",
                dict(alive=True, state="Crashed", transcript_age_seconds=10, cpu_percent=0.0),
                (doctor.STATUS_WARN, "crashed"),
            ),
            (
                "alive, idle, pinned cpu, and stale transcript is warn",
                dict(alive=True, state="Idle", transcript_age_seconds=600, cpu_percent=95.0),
                (doctor.STATUS_WARN, "alive but pinned"),
            ),
            (
                "pinned cpu but transcript just advanced is not yet stuck",
                dict(alive=True, state="Idle", transcript_age_seconds=10, cpu_percent=95.0),
                (doctor.STATUS_OK, None),
            ),
            (
                "child not running is inconclusive",
                dict(alive=False, state="Idle", transcript_age_seconds=None, cpu_percent=None),
                (doctor.STATUS_INCONCLUSIVE, "child not running"),
            ),
            (
                "alive with unknown age and cpu has nothing positive to flag",
                dict(alive=True, state="Idle", transcript_age_seconds=None, cpu_percent=None),
                (doctor.STATUS_OK, None),
            ),
        ]
        for description, kwargs, expected in cases:
            with self.subTest(description=description):
                result = doctor.classify_session_signal(**kwargs)
                self.assertEqual(result, expected)

    def test_crashed_takes_precedence_over_mid_turn_staleness(self):
        # Rule order: Crashed (rule 1) must win even if state/age would
        # otherwise match a later rule's shape (defensive against a state
        # value of "Crashed" being combined with the MidTurn-like fields).
        result = doctor.classify_session_signal(
            alive=True, state="Crashed", transcript_age_seconds=99999, cpu_percent=99.0
        )
        self.assertEqual(result, (doctor.STATUS_WARN, "crashed"))

    def test_mid_turn_without_age_information_does_not_warn(self):
        # Rule 2 requires transcript_age_seconds to be known; unknown age
        # must not be treated as "definitely stale".
        result = doctor.classify_session_signal(
            alive=True, state="MidTurn", transcript_age_seconds=None, cpu_percent=50.0
        )
        self.assertEqual(result, (doctor.STATUS_OK, None))

    def test_pinned_cpu_rule_requires_known_cpu_and_age(self):
        # alive + high cpu but age unknown must not trigger "alive but pinned".
        result = doctor.classify_session_signal(
            alive=True, state="Idle", transcript_age_seconds=None, cpu_percent=95.0
        )
        self.assertEqual(result, (doctor.STATUS_OK, None))

    def test_dead_child_is_inconclusive_even_with_crashed_state(self):
        # not-alive (rule 4) only fires when earlier rules don't match;
        # "Crashed" state matches rule 1 first regardless of alive.
        result = doctor.classify_session_signal(
            alive=False, state="Crashed", transcript_age_seconds=None, cpu_percent=None
        )
        self.assertEqual(result, (doctor.STATUS_WARN, "crashed"))

    def test_not_alive_with_idle_state_and_no_data_is_inconclusive(self):
        result = doctor.classify_session_signal(
            alive=False, state="Idle", transcript_age_seconds=None, cpu_percent=None
        )
        self.assertEqual(result, (doctor.STATUS_INCONCLUSIVE, "child not running"))

    def test_custom_thresholds_are_respected(self):
        # Lower thresholds should make the same inputs trip warn rules that
        # wouldn't trip under defaults.
        result = doctor.classify_session_signal(
            alive=True,
            state="MidTurn",
            transcript_age_seconds=50,
            cpu_percent=50.0,
            stale_turn_threshold=30,
        )
        self.assertEqual(result, (doctor.STATUS_WARN, "in-flight turn stalled"))

    def test_returns_a_two_tuple(self):
        result = doctor.classify_session_signal(
            alive=True, state="Idle", transcript_age_seconds=5, cpu_percent=1.0
        )
        self.assertIsInstance(result, tuple)
        self.assertEqual(len(result), 2)


if __name__ == "__main__":
    unittest.main()
