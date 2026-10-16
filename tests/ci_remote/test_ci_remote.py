"""Behavioural tests for `scripts/ci_remote.py` (the `make ci-remote` driver).

RED phase: the module does not exist yet. Two layers:

* Pure functions (`parse_failed_log`, `select_run`, `summarize`) tested against
  the real/synthetic fixtures in `tests/ci_remote/fixtures/` plus small inline
  strings for edge cases.
* The CLI, tested end to end as a subprocess with fake `gh` and `git`
  executables first on PATH. The fakes record every argv and serve canned
  responses, so no network and no real repository is touched.

Run with:
    python3 -m unittest discover -s tests/ci_remote -v
"""

import ast
import copy
import datetime as dt
import importlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCRIPTS_DIR = os.path.join(REPO_ROOT, "scripts")
SCRIPT = os.path.join(SCRIPTS_DIR, "ci_remote.py")
FIXTURES = os.path.join(HERE, "fixtures")


def fixture_text(name):
    with open(os.path.join(FIXTURES, name), "r", encoding="utf-8") as f:
        return f.read()


def fixture_json(name):
    return json.loads(fixture_text(name))


def load_module():
    if SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, SCRIPTS_DIR)
    try:
        return importlib.import_module("ci_remote")
    except ImportError as e:  # module absent in RED phase
        raise AssertionError(f"scripts/ci_remote.py is not importable: {e}")


class ModuleTestCase(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()


def line(job, text, step="step", ts="2026-10-16T00:00:00.0000000Z"):
    return f"{job}\t{step}\t{ts} {text}"


# ---------------------------------------------------------------------------
# parse_failed_log
# ---------------------------------------------------------------------------

class ParseFailedLogFixtureTests(ModuleTestCase):
    def parse(self, name):
        return self.mod.parse_failed_log(fixture_text(name))

    def test_xctest_failures_are_module_class_slash_test(self):
        self.assertEqual(
            self.parse("mac_xctest_failure.log"),
            {"Swift tests (Mac app)": [
                "NostromoTests.ChatTurnViewLayoutTests/testRenderedHeightMatchesGoldensWithContentAvailable",
                "NostromoTests.ChatTurnViewLayoutTests/testRenderedHeightMatchesGoldensWithContentUnavailable",
            ]},
        )

    def test_cargo_failed_tests_are_listed_and_summary_line_is_not(self):
        self.assertEqual(
            self.parse("cargo_test_failure.log"),
            {"Build & Lint": [
                "a_doc_with_hostile_names_and_values_gives_a_safe_detail_for_the_id_it_was_listed_under",
                "hostile_doc_values_and_names_reach_the_list_only_as_fenced_one_line_data",
            ]},
        )

    def test_clippy_error_is_file_line_and_message(self):
        self.assertEqual(
            self.parse("clippy_error.log"),
            {"Build & Lint": ["src/ipc/tasks.rs:909 consider using `sort_by_key`"]},
        )

    def test_rustc_errors_are_listed_and_could_not_compile_is_not(self):
        self.assertEqual(
            self.parse("rustc_compile_error.log"),
            {"Build & Lint": [
                "src/ipc/panes.rs:214 cannot find value `pane_idd` in this scope",
                "src/data/store.rs:77 mismatched types",
            ]},
        )

    def test_python_unittest_failures_are_dotted_test_ids(self):
        self.assertEqual(
            self.parse("python_unittest_failure.log"),
            {"Python tooling tests": [
                "test_transcript_load_tooling.FixtureOpenReportTests.test_cli_fixture_only_exit_codes",
                "test_transcript_load_tooling.FixtureOpenReportTests.test_log_with_fixture_lines_prints_median_and_sha",
                "test_transcript_load_tooling.FixtureOpenReportTests.test_matching_sha_tag_is_included",
            ]},
        )

    def test_python_subtest_failures_dedupe_to_one_item(self):
        self.assertEqual(
            self.parse("python_unittest_subtest_failure.log"),
            {"Python tooling tests": [
                "test_hit_test_policy.HitTestPolicy.test_overrides_convert_from_the_superview",
            ]},
        )

    def test_kit_log_mixes_xctest_and_swift_testing_items_in_first_seen_order(self):
        self.assertEqual(
            self.parse("kit_swift_test_failure.log"),
            {"Swift tests (NostromoKit)": [
                "NostromoKitTests.FrameCodecTests/testOversizedFrameIsRejected",
                "NostromoKitTests.FrameCodecTests/testRoundTrip",
                "decodesEveryFrameKind()",
                "Pane titles survive a round trip",
            ]},
        )

    def test_swift_compiler_errors_drop_checkout_prefix_and_warnings_and_dupes(self):
        self.assertEqual(
            self.parse("swift_compile_error.log"),
            {"iOS simulator build": [
                "iOS/Nostromo/Views/PaneListView.swift:88 cannot find 'paneTitle' in scope",
                "Shared/NostromoKit/Sources/NostromoKit/Wire.swift:130 "
                "missing return in instance method expected to return 'Int'",
            ]},
        )

    def test_unrecognised_failure_falls_back_to_last_30_lines_tagged_unparsed(self):
        text = fixture_text("unrecognised_failure.log")
        ansi = re.compile(r"\x1b\[[0-9;]*m|\^\[\[[0-9;]*m")
        stripped = []
        for raw in text.splitlines():
            third = raw.split("\t", 2)[2]
            body = third.split(" ", 1)[1] if " " in third else ""
            stripped.append(ansi.sub("", body).rstrip())
        expected = ["[unparsed] " + s for s in stripped[-30:]]

        result = self.mod.parse_failed_log(text)
        self.assertEqual(list(result), ["Build & Lint"])
        got = [s.rstrip() for s in result["Build & Lint"]]
        self.assertEqual(len(got), 30)
        self.assertEqual(got, [e.rstrip() for e in expected])


class ParseFailedLogEdgeTests(ModuleTestCase):
    def test_empty_input_gives_empty_mapping(self):
        self.assertEqual(self.mod.parse_failed_log(""), {})

    def test_real_escape_bytes_are_stripped(self):
        text = line("J", "\x1b[1m\x1b[91merror\x1b[0m\x1b[1m: boom\x1b[0m") + "\n" + \
            line("J", "   \x1b[1m\x1b[94m--> \x1b[0msrc/a.rs:3:4") + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["src/a.rs:3 boom"]})

    def test_caret_bracket_text_escapes_are_stripped(self):
        # `gh` renders ESC as the literal two characters "^[".
        text = line("J", "^[[1m^[[91merror^[[0m^[[1m: boom^[[0m") + "\n" + \
            line("J", "   ^[[1m^[[94m--> ^[[0msrc/a.rs:3:4") + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["src/a.rs:3 boom"]})

    def test_caret_bracket_escapes_are_stripped_from_test_names(self):
        text = line("J", "^[[31mtest a::b ... FAILED^[[0m") + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["a::b"]})

    def test_leading_bom_is_ignored(self):
        text = "﻿" + line("J", "test a::b ... FAILED") + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["a::b"]})

    def test_duplicates_are_removed_keeping_first_position(self):
        text = "\n".join([
            line("J", "test b::two ... FAILED"),
            line("J", "test a::one ... FAILED"),
            line("J", "test b::two ... FAILED"),
        ]) + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["b::two", "a::one"]})

    def test_jobs_are_kept_separate(self):
        text = "\n".join([
            line("Job A", "test a::one ... FAILED"),
            line("Job B", "test b::one ... FAILED"),
            line("Job A", "test a::two ... FAILED"),
        ]) + "\n"
        self.assertEqual(
            self.mod.parse_failed_log(text),
            {"Job A": ["a::one", "a::two"], "Job B": ["b::one"]},
        )

    def test_swift_testing_run_summary_is_not_a_test_item(self):
        text = line("J", "✘ Test run with 2 tests in 1 suite failed after 0.006 seconds with 2 issues.") + "\n"
        result = self.mod.parse_failed_log(text)
        self.assertEqual(list(result), ["J"])
        self.assertTrue(all(i.startswith("[unparsed] ") for i in result["J"]))

    def test_swift_testing_failed_line_by_name_and_by_display_name(self):
        text = "\n".join([
            line("J", "✘ Test decodes() failed after 0.004 seconds with 1 issue."),
            line("J", '✘ Test "Nice display name" failed after 0.004 seconds with 1 issue.'),
        ]) + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["decodes()", "Nice display name"]})

    def test_xctest_error_line_without_column_is_not_a_compile_error(self):
        text = line("J", "/Users/runner/work/r/r/T.swift:718: error: -[Mod.Cls test] : XCTAssertTrue failed") + "\n"
        result = self.mod.parse_failed_log(text)
        self.assertTrue(all(i.startswith("[unparsed] ") for i in result["J"]))

    def test_swift_error_with_column_is_listed_with_linux_checkout_prefix_removed(self):
        text = line("J", "/home/runner/work/repo/repo/Sources/X.swift:7:3: error: bad thing") + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["Sources/X.swift:7 bad thing"]})

    def test_older_unittest_form_with_only_the_class_in_parens(self):
        text = line("J", "ERROR: test_x (mod.Class)") + "\n"
        self.assertEqual(self.mod.parse_failed_log(text), {"J": ["mod.Class.test_x"]})

    def test_job_without_recognised_items_gets_all_its_lines_when_fewer_than_30(self):
        text = "\n".join(line("J", f"noise {i}") for i in range(5)) + "\n"
        result = self.mod.parse_failed_log(text)
        self.assertEqual(
            [s.rstrip() for s in result["J"]],
            [f"[unparsed] noise {i}" for i in range(5)],
        )

    def test_unrecognised_job_does_not_hide_recognised_job_and_is_never_empty(self):
        text = "\n".join([
            line("Good", "test a::b ... FAILED"),
            line("Quiet", "something happened"),
        ]) + "\n"
        result = self.mod.parse_failed_log(text)
        self.assertEqual(result["Good"], ["a::b"])
        self.assertEqual([s.rstrip() for s in result["Quiet"]], ["[unparsed] something happened"])


# ---------------------------------------------------------------------------
# select_run
# ---------------------------------------------------------------------------

class SelectRunTests(ModuleTestCase):
    SHA = "a" * 40
    NOT_BEFORE = dt.datetime(2026, 10, 16, 12, 0, 0, tzinfo=dt.timezone.utc)

    def run_(self, rid, created, sha=None, event="workflow_dispatch"):
        return {
            "databaseId": rid, "headSha": sha or self.SHA, "createdAt": created,
            "url": f"https://example.invalid/runs/{rid}", "event": event,
        }

    def select(self, runs):
        return self.mod.select_run(runs, self.SHA, self.NOT_BEFORE)

    def test_empty_list_gives_none(self):
        self.assertIsNone(self.select([]))

    def test_matching_run_is_returned(self):
        r = self.run_(1, "2026-10-16T12:00:05Z")
        self.assertEqual(self.select([r]), r)

    def test_wrong_event_is_ignored(self):
        self.assertIsNone(self.select([self.run_(1, "2026-10-16T12:00:05Z", event="push")]))

    def test_wrong_sha_is_ignored(self):
        self.assertIsNone(self.select([self.run_(1, "2026-10-16T12:00:05Z", sha="b" * 40)]))

    def test_run_just_outside_the_ten_second_slack_is_ignored(self):
        self.assertIsNone(self.select([self.run_(1, "2026-10-16T11:59:49Z")]))

    def test_run_inside_the_ten_second_slack_is_accepted(self):
        r = self.run_(1, "2026-10-16T11:59:51Z")
        self.assertEqual(self.select([r]), r)

    def test_newest_of_several_matches_wins_regardless_of_list_order(self):
        old = self.run_(1, "2026-10-16T12:00:01Z")
        new = self.run_(2, "2026-10-16T12:00:09Z")
        mid = self.run_(3, "2026-10-16T12:00:04Z")
        self.assertEqual(self.select([old, new, mid]), new)
        self.assertEqual(self.select([new, mid, old]), new)

    def test_non_matching_newer_run_does_not_beat_matching_older_run(self):
        good = self.run_(1, "2026-10-16T12:00:01Z")
        other = self.run_(2, "2026-10-16T12:00:30Z", event="push")
        self.assertEqual(self.select([other, good]), good)


# ---------------------------------------------------------------------------
# summarize
# ---------------------------------------------------------------------------

class SummarizeTests(ModuleTestCase):
    def test_green_fixture_exits_zero_with_every_job_success(self):
        jobs, code = self.mod.summarize(fixture_json("run_view_success.json"))
        self.assertEqual(code, 0)
        self.assertEqual(
            jobs,
            {
                "Python tooling tests": "success",
                "Swift tests (Mac app)": "success",
                "Build & Lint": "success",
                "Swift tests (NostromoKit)": "success",
                "iOS simulator build": "success",
            },
        )

    def test_failed_fixture_exits_one_and_names_the_failed_job(self):
        jobs, code = self.mod.summarize(fixture_json("run_view_failed.json"))
        self.assertEqual(code, 1)
        self.assertEqual(jobs["Build & Lint"], "failure")
        self.assertEqual(jobs["iOS simulator build"], "success")

    def test_skipped_jobs_alongside_successes_pass(self):
        data = fixture_json("run_view_success.json")
        for j in data["jobs"][:3]:
            j["conclusion"] = "skipped"
        jobs, code = self.mod.summarize(data)
        self.assertEqual(code, 0)
        self.assertEqual(sorted(set(jobs.values())), ["skipped", "success"])

    def test_cancelled_run_fails_even_if_jobs_look_fine(self):
        data = fixture_json("run_view_success.json")
        data["conclusion"] = "cancelled"
        self.assertEqual(self.mod.summarize(data)[1], 1)

    def test_timed_out_run_fails(self):
        data = fixture_json("run_view_success.json")
        data["conclusion"] = "timed_out"
        self.assertEqual(self.mod.summarize(data)[1], 1)

    def test_startup_failure_run_fails(self):
        data = fixture_json("run_view_success.json")
        data["conclusion"] = "startup_failure"
        self.assertEqual(self.mod.summarize(data)[1], 1)

    def test_one_cancelled_job_fails_the_run(self):
        data = copy.deepcopy(fixture_json("run_view_success.json"))
        data["jobs"][1]["conclusion"] = "cancelled"
        jobs, code = self.mod.summarize(data)
        self.assertEqual(code, 1)
        self.assertEqual(jobs[data["jobs"][1]["name"]], "cancelled")

    def test_job_without_conclusion_maps_to_its_status_and_fails(self):
        for empty in (None, ""):
            data = copy.deepcopy(fixture_json("run_view_success.json"))
            data["jobs"][0]["status"] = "in_progress"
            data["jobs"][0]["conclusion"] = empty
            jobs, code = self.mod.summarize(data)
            self.assertEqual(jobs[data["jobs"][0]["name"]], "in_progress")
            self.assertEqual(code, 1)


# ---------------------------------------------------------------------------
# CLI end to end with fake gh / git
# ---------------------------------------------------------------------------

FAKE_TOOL = r'''#!{python}
import datetime, json, os, sys

d = os.environ["FAKE_DIR"]
tool = os.path.basename(sys.argv[0])
args = sys.argv[1:]
with open(os.path.join(d, "calls.jsonl"), "a") as f:
    f.write(json.dumps([tool] + args) + "\n")
cfg = json.load(open(os.path.join(d, "config.json")))


def out(s=""):
    sys.stdout.write(s)
    sys.stdout.flush()


def counter(name):
    p = os.path.join(d, "counter_" + name)
    n = int(open(p).read()) if os.path.exists(p) else 0
    open(p, "w").write(str(n + 1))
    return n


if tool == "git":
    if args == ["rev-parse", "HEAD"]:
        out(cfg["head"] + "\n")
    elif args == ["rev-parse", "--abbrev-ref", "HEAD"]:
        out(cfg["branch"] + "\n")
    elif args[:1] == ["ls-remote"]:
        sha = cfg.get("remote_sha")
        if sha:
            out(sha + "\t" + args[-1] + "\n")
    else:
        sys.stderr.write("fake git: unsupported " + repr(args) + "\n")
        sys.exit(1)
elif tool == "gh":
    if args[:2] == ["auth", "status"]:
        if not cfg.get("auth_ok", True):
            sys.stderr.write("You are not logged into any GitHub hosts.\n")
            sys.exit(1)
    elif args[:2] == ["workflow", "run"]:
        wr = cfg.get("workflow_run", {{}})
        if wr.get("rc", 0):
            sys.stderr.write(wr.get("stderr", "") + "\n")
            sys.exit(wr["rc"])
    elif args[:2] == ["run", "list"]:
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        runs = [
            {{"databaseId": 1, "headSha": "0" * 40, "createdAt": "2020-01-01T00:00:00Z",
             "url": "https://example.invalid/runs/1", "event": "workflow_dispatch"}},
            {{"databaseId": 2, "headSha": cfg["head"], "createdAt": now,
             "url": "https://example.invalid/runs/2", "event": "push"}},
        ]
        if cfg.get("discoverable", True):
            runs.insert(0, {{"databaseId": cfg["run_id"], "headSha": cfg["head"],
                            "createdAt": now, "url": cfg["run_url"],
                            "event": "workflow_dispatch"}})
        out(json.dumps(runs))
    elif args[:2] == ["run", "view"] and "--log-failed" in args:
        out(cfg.get("log_failed", ""))
    elif args[:2] == ["run", "view"]:
        views = cfg["views"]
        n = counter("view")
        out(json.dumps(views[min(n, len(views) - 1)]))
    else:
        sys.stderr.write("fake gh: unsupported " + repr(args) + "\n")
        sys.exit(1)
'''

HEAD = "c" * 40
RUN_ID = 424242
RUN_URL = "https://github.com/example/nostromo/actions/runs/424242"


def view(status, conclusion, jobs, url=RUN_URL):
    """jobs: list of (name, status, conclusion)."""
    return {
        "status": status,
        "conclusion": conclusion,
        "url": url,
        "jobs": [{"name": n, "status": s, "conclusion": c} for n, s, c in jobs],
    }


class CliHarness(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name
        self.bin = os.path.join(self.dir, "bin")
        os.mkdir(self.bin)
        body = FAKE_TOOL.format(python=sys.executable)
        for tool in ("gh", "git"):
            p = os.path.join(self.bin, tool)
            with open(p, "w") as f:
                f.write(body)
            os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.config = {
            "head": HEAD, "branch": "feature/x", "remote_sha": HEAD, "auth_ok": True,
            "workflow_run": {"rc": 0}, "run_id": RUN_ID, "run_url": RUN_URL,
            "discoverable": True,
            "views": [view("completed", "success", [("Job", "completed", "success")])],
            "log_failed": "",
        }

    def run_cli(self, *argv):
        self.assertTrue(os.path.exists(SCRIPT), "scripts/ci_remote.py does not exist yet")
        with open(os.path.join(self.dir, "config.json"), "w") as f:
            json.dump(self.config, f)
        env = dict(os.environ)
        env["PATH"] = self.bin + os.pathsep + env.get("PATH", "")
        env["FAKE_DIR"] = self.dir
        proc = subprocess.run(
            [sys.executable, SCRIPT] + list(argv),
            cwd=self.dir, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True, timeout=60,
        )
        self.proc = proc
        self.combined = proc.stdout + proc.stderr
        return proc

    def calls(self):
        path = os.path.join(self.dir, "calls.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(l) for l in f if l.strip()]

    def calls_matching(self, *prefix):
        n = len(prefix)
        return [c for c in self.calls() if tuple(c[:n]) == prefix]

    FAST = ("--interval-s", "0", "--discover-interval-s", "0", "--discover-timeout-s", "2")


class CliPreflightTests(CliHarness):
    def test_unpushed_head_exits_2_telling_the_user_to_push_first(self):
        self.config["remote_sha"] = "d" * 40
        p = self.run_cli("--branch", "feature/x", "--only", "kit", *self.FAST)
        self.assertEqual(p.returncode, 2, self.combined)
        self.assertIn("push first", self.combined)
        self.assertEqual(self.calls_matching("gh", "workflow", "run"), [])

    def test_branch_missing_on_remote_exits_2_telling_the_user_to_push_first(self):
        self.config["remote_sha"] = ""
        p = self.run_cli("--branch", "feature/x", "--only", "kit", *self.FAST)
        self.assertEqual(p.returncode, 2, self.combined)
        self.assertIn("push first", self.combined)
        self.assertEqual(self.calls_matching("gh", "workflow", "run"), [])

    def test_gh_not_authenticated_exits_2_pointing_at_gh_auth_login(self):
        self.config["auth_ok"] = False
        p = self.run_cli("--branch", "feature/x", "--only", "kit", *self.FAST)
        self.assertEqual(p.returncode, 2, self.combined)
        self.assertIn("gh auth login", self.combined)
        self.assertEqual(self.calls_matching("gh", "workflow", "run"), [])

    def test_invalid_only_value_is_an_argparse_error(self):
        p = self.run_cli("--branch", "feature/x", "--only", "bogus", *self.FAST)
        self.assertEqual(p.returncode, 2, self.combined)
        self.assertEqual(self.calls_matching("gh", "workflow", "run"), [])

    def test_branch_defaults_to_the_current_git_branch(self):
        self.config["branch"] = "feature/current"
        self.config["remote_sha"] = HEAD
        self.config["views"] = [view("completed", "success", [("Job", "completed", "success")])]
        p = self.run_cli("--only", "kit", *self.FAST)
        self.assertEqual(p.returncode, 0, self.combined)
        self.assertEqual(
            self.calls_matching("gh", "workflow", "run"),
            [["gh", "workflow", "run", "ci.yml", "--ref", "feature/current", "-f", "only=kit"]],
        )


class CliDispatchTests(CliHarness):
    def test_workflow_without_dispatch_trigger_explains_rebase_onto_main(self):
        self.config["workflow_run"] = {
            "rc": 1,
            "stderr": "could not create workflow dispatch event: HTTP 422: "
                      "Workflow does not have 'workflow_dispatch' trigger",
        }
        p = self.run_cli("--branch", "feature/x", "--only", "kit", *self.FAST)
        self.assertEqual(p.returncode, 2, self.combined)
        self.assertIn("predates the dispatch trigger", self.combined)
        self.assertIn("rebase onto main", self.combined)

    def test_happy_path_dispatches_discovers_waits_and_reports_success(self):
        self.config["views"] = [
            view("in_progress", None, [("Swift tests (NostromoKit) (dispatch)", "in_progress", None)]),
            view("completed", "success", [("Swift tests (NostromoKit) (dispatch)", "completed", "success")]),
        ]
        p = self.run_cli("--branch", "feature/x", "--only", "kit", *self.FAST)
        self.assertEqual(p.returncode, 0, self.combined)

        self.assertEqual(
            self.calls_matching("gh", "workflow", "run"),
            [["gh", "workflow", "run", "ci.yml", "--ref", "feature/x", "-f", "only=kit"]],
        )
        first_list = self.calls_matching("gh", "run", "list")[0]
        self.assertEqual(
            first_list,
            ["gh", "run", "list", "--workflow", "ci.yml", "--branch", "feature/x",
             "--event", "workflow_dispatch", "--limit", "10",
             "--json", "databaseId,headSha,createdAt,url,event"],
        )
        views = self.calls_matching("gh", "run", "view", str(RUN_ID))
        self.assertGreaterEqual(len(views), 2)
        self.assertIn(
            ["gh", "run", "view", str(RUN_ID), "--json", "status,conclusion,jobs,url"], views
        )
        self.assertEqual(self.combined.count(RUN_URL), 1, self.combined)
        self.assertRegex(
            self.combined,
            r"(?m)^.*Swift tests \(NostromoKit\) \(dispatch\).*success.*$",
        )
        self.assertEqual(
            [c for c in self.calls() if "--log-failed" in c], [],
            "a green run must not fetch failure logs",
        )

    def test_run_that_never_finishes_exits_3_with_resume_hint_and_never_cancels(self):
        self.config["views"] = [
            view("in_progress", None, [("Job", "in_progress", None)])
        ]
        p = self.run_cli("--branch", "feature/x", "--only", "kit", "--timeout-min", "0", *self.FAST)
        self.assertEqual(p.returncode, 3, self.combined)
        self.assertIn(RUN_URL, self.combined)
        self.assertIn(f"make ci-remote RUN={RUN_ID}", self.combined)
        self.assertEqual(self.calls_matching("gh", "run", "cancel"), [])

    def test_run_never_discovered_exits_3_saying_it_could_not_be_found(self):
        self.config["discoverable"] = False
        p = self.run_cli("--branch", "feature/x", "--only", "kit", *self.FAST)
        self.assertEqual(p.returncode, 3, self.combined)
        self.assertRegex(
            self.combined.lower(),
            r"(could not|couldn't|unable to) (be )?(find|found|discover)|not found",
        )
        self.assertEqual(self.calls_matching("gh", "run", "cancel"), [])

    def test_job_state_lines_print_once_per_change_not_once_per_poll(self):
        A, B = "Alpha job", "Beta job"
        self.config["views"] = [
            view("in_progress", None, [(A, "in_progress", None), (B, "queued", None)]),
            view("in_progress", None, [(A, "completed", "success"), (B, "in_progress", None)]),
            view("in_progress", None, [(A, "completed", "success"), (B, "in_progress", None)]),
            view("in_progress", None, [(A, "completed", "success"), (B, "in_progress", None)]),
            view("completed", "success", [(A, "completed", "success"), (B, "completed", "success")]),
        ]
        p = self.run_cli("--branch", "feature/x", "--only", "all", *self.FAST)
        self.assertEqual(p.returncode, 0, self.combined)

        def count(job, status_re):
            return len([
                l for l in self.combined.splitlines()
                if job in l and re.search(status_re, l)
            ])

        # B stays in_progress across three polls: it is announced once.
        self.assertEqual(count(B, r"in[_ ]progress"), 1, self.combined)
        self.assertEqual(count(A, r"in[_ ]progress"), 1, self.combined)
        # A's success is announced at the change, and may be repeated once in
        # the final summary, but never once per poll (3 polls saw it).
        self.assertGreaterEqual(count(A, r"success"), 1)
        self.assertLessEqual(count(A, r"success"), 2, self.combined)
        self.assertGreaterEqual(count(B, r"success"), 1)


class CliRunIdTests(CliHarness):
    def test_run_id_skips_dispatch_remote_check_and_run_list(self):
        self.config["views"] = [fixture_json("run_view_success.json")]
        p = self.run_cli("--run-id", "38900814201", *self.FAST)
        self.assertEqual(p.returncode, 0, self.combined)
        self.assertEqual(self.calls_matching("gh", "workflow", "run"), [])
        self.assertEqual(self.calls_matching("git", "ls-remote"), [])
        self.assertEqual(self.calls_matching("gh", "run", "list"), [])
        self.assertTrue(self.calls_matching("gh", "run", "view", "38900814201"))

    def test_green_run_by_id_exits_0_with_no_failed_lines_and_no_log_fetch(self):
        self.config["views"] = [fixture_json("run_view_success.json")]
        p = self.run_cli("--run-id", "38900814201", *self.FAST)
        self.assertEqual(p.returncode, 0, self.combined)
        self.assertNotRegex(p.stdout, r"(?m)^FAILED ")
        self.assertEqual([c for c in self.calls() if "--log-failed" in c], [])

    def test_failed_run_by_id_exits_1_and_prints_a_FAILED_line_per_parsed_failure(self):
        self.config["views"] = [fixture_json("run_view_failed.json")]
        self.config["log_failed"] = fixture_text("cargo_test_failure.log")
        p = self.run_cli("--run-id", "38812665891", *self.FAST)
        self.assertEqual(p.returncode, 1, self.combined)
        self.assertTrue(self.calls_matching("gh", "run", "view", "38812665891", "--log-failed"))
        failed_lines = [l for l in p.stdout.splitlines() if l.startswith("FAILED ")]
        self.assertEqual(
            failed_lines,
            [
                "FAILED Build & Lint: a_doc_with_hostile_names_and_values_gives_a_safe_detail_for_the_id_it_was_listed_under",
                "FAILED Build & Lint: hostile_doc_values_and_names_reach_the_list_only_as_fenced_one_line_data",
            ],
        )

    def test_failed_run_by_id_with_xctest_log_names_each_test(self):
        self.config["views"] = [fixture_json("run_view_failed.json")]
        log = fixture_text("mac_xctest_failure.log").replace("Swift tests (Mac app)", "Build & Lint")
        self.config["log_failed"] = log
        p = self.run_cli("--run-id", "38812665891", *self.FAST)
        self.assertEqual(p.returncode, 1, self.combined)
        for name in ("testRenderedHeightMatchesGoldensWithContentAvailable",
                     "testRenderedHeightMatchesGoldensWithContentUnavailable"):
            self.assertIn(
                f"FAILED Build & Lint: NostromoTests.ChatTurnViewLayoutTests/{name}",
                p.stdout.splitlines(),
            )
        self.assertEqual(self.calls_matching("gh", "run", "cancel"), [])


# ---------------------------------------------------------------------------
# Belt and braces: this suite itself must never skip.
# ---------------------------------------------------------------------------

class SuiteNeverSkipsTests(unittest.TestCase):
    """The CI job greps this suite's output for the skip report and fails on
    it; this is a source-level second guard, parsed with `ast` so the check
    can describe what it forbids without matching itself."""

    def test_this_module_defines_no_skip_decorator_or_skipTest_call(self):
        with open(__file__, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for dec in node.decorator_list:
                    self.assertNotIn(
                        "skip", ast.dump(dec).lower(),
                        f"{node.name} carries a skip-shaped decorator: {ast.dump(dec)}",
                    )
            if isinstance(node, ast.Call):
                target = node.func
                name = getattr(target, "attr", None) or getattr(target, "id", None)
                self.assertNotEqual(name, "skipTest", "a skipTest(...) call was found in this module")


if __name__ == "__main__":
    unittest.main()
