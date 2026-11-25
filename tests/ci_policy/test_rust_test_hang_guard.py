"""A hung Rust test must fail `Rust tests` with its name, well inside the job limit.

Before this guard a test that never returned left the job silent until its
30-minute limit cancelled it, and a cancelled job names nothing. The `Test`
step now has its own limit, under the job's, and a follow-up step prints the
tests still running. `Build & Lint` must keep needing the job.
"""

import os
import re
import subprocess
import tempfile
import unittest

CI_YML = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", ".github", "workflows", "ci.yml"
)


FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "nextest_slow.log")


def _run_script(step):
    """The step's `run: |` block, as the text bash would get."""
    m = re.search(r"^        run: \|\n((?:          .*\n|\n)+)", step, re.M)
    assert m, "the step has no run block"
    return "".join(line[10:] for line in m.group(1).splitlines(True))


def _names_reported(script, log_text):
    with tempfile.TemporaryDirectory() as tmp:
        with open(os.path.join(tmp, "nextest.log"), "w") as f:
            f.write(log_text)
        out = subprocess.run(
            ["bash", "-c", script], env={**os.environ, "RUNNER_TEMP": tmp},
            capture_output=True, text=True, check=True,
        ).stdout
    prefix = "::error::still running when the step ended: "
    return [line[len(prefix):] for line in out.splitlines() if line.startswith(prefix)]


def _job(text, key):
    m = re.search(rf"^  {re.escape(key)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text, re.S | re.M)
    assert m, f"job {key} not found"
    return m.group(1)


def _step(job, name):
    m = re.search(rf"^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", job, re.S | re.M)
    assert m, f"step {name!r} not found"
    return m.group(1)


class RustTestHangGuardTests(unittest.TestCase):
    def setUp(self):
        with open(CI_YML) as f:
            self.text = f.read()
        self.job = _job(self.text, "rust-test")

    def check_step_limit(self, job):
        step = _step(job, "Test")
        m = re.search(r"^        timeout-minutes: (\d+)$", step, re.M)
        self.assertIsNotNone(m, "the Test step has no timeout-minutes of its own")
        job_limit = int(re.search(r"^    timeout-minutes: (\d+)$", job, re.M).group(1))
        self.assertLess(int(m.group(1)), job_limit)
        # Over a green run (about 14 minutes with the build), or the guard fails good runs.
        self.assertGreaterEqual(int(m.group(1)), 18)

    def test_the_test_step_has_a_limit_under_the_job_limit(self):
        self.check_step_limit(self.job)

    def test_the_guard_bites_without_a_step_limit(self):
        mutated = re.sub(r"^        timeout-minutes: \d+\n", "", self.job, flags=re.M)
        with self.assertRaises(AssertionError):
            self.check_step_limit(mutated)

    def test_the_step_runs_every_test_binary_and_keeps_a_failing_exit_status(self):
        step = _step(self.job, "Test")
        self.assertIn("--no-fail-fast", step)
        # `tee` must not hide cargo's exit status.
        self.assertRegex(step, r"(?m)^        shell: bash$")
        self.assertRegex(step, r"cargo nextest run .*\| tee ")

    def test_doc_tests_keep_their_own_step_because_nextest_skips_them(self):
        step = _step(self.job, "Doc tests")
        self.assertRegex(step, r"(?m)^        run: cargo test --doc$")

    def test_a_follow_up_step_names_the_tests_still_running(self):
        step = _step(self.job, "Name the tests still running")
        self.assertIn("always()", step)
        self.assertIn("SLOW", step)

    # The fixture is real nextest 0.9.152 output (slow-timeout 100 ms, through tee):
    # SLOW lines carry the placeholder counter `(───────)`, PASS lines `(103/103)`.
    def _fixture(self):
        with open(FIXTURE, encoding="utf-8") as f:
            return f.read()

    def _script(self):
        return _run_script(_step(self.job, "Name the tests still running"))

    def _pass_line(self, log, test):
        return next(l for l in log.splitlines(True) if l.lstrip().startswith("PASS") and test in l)

    def test_the_fixture_has_slow_lines_with_a_placeholder_counter(self):
        log = self._fixture()
        self.assertRegex(log, r"SLOW \[[^]]*\] \(─+\) ")
        self.assertRegex(log, r"PASS \[[^]]*\] \(\s*\d+/\d+\) ")

    def test_the_step_reports_nothing_when_every_slow_test_finished(self):
        self.assertEqual(_names_reported(self._script(), self._fixture()), [])

    def test_the_step_names_exactly_the_slow_test_whose_finish_line_is_missing(self):
        log = self._fixture()
        test = "the_result_frame_of_a_one_mebibyte_read_stays_under_the_f"
        line = self._pass_line(log, test)
        names = _names_reported(self._script(), log.replace(line, ""))
        self.assertEqual(len(names), 1)
        self.assertTrue(names[0].startswith("nostromo ipc::task_output::tests::" + test), names)
        self.assertNotIn("(", names[0])

    def test_a_fail_line_counts_as_finished(self):
        log = self._fixture()
        line = self._pass_line(log, "the_result_frame_of_a_one_mebibyte_read_stays_under_the_f")
        failed = log.replace(line, line.replace("PASS", "FAIL", 1))
        self.assertEqual(_names_reported(self._script(), failed), [])

    def test_the_step_bites_without_stripping_the_counter(self):
        script = self._script()
        mutated = script.replace("(\\([^)]*\\) +)?", "")
        self.assertNotEqual(mutated, script)
        self.assertNotEqual(_names_reported(mutated, self._fixture()), [])

    def test_the_test_step_cannot_swallow_nextests_exit_status(self):
        step = _step(self.job, "Test")
        self.assertRegex(step, r"(?m)^        shell: bash$")  # bash -e -o pipefail
        run = re.search(r"(?m)^        run: (.*)$", step).group(1)
        self.assertNotRegex(run, r"\|\|\s*(true|:)")
        self.assertNotRegex(run, r";\s*(true|:)\b")
        self.assertRegex(run, r"^cargo nextest run [^;|]*\| tee [^;|]*$")

    def test_build_and_lint_still_needs_the_job_and_demands_success(self):
        build = _job(self.text, "build")
        self.assertRegex(build, r"needs: \[[^\]]*rust-test[^\]]*\]")
        self.assertIn('[ "$TEST" = success ]', build)


if __name__ == "__main__":
    unittest.main()
