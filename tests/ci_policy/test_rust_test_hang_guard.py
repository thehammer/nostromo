"""A hung Rust test must fail `Rust tests` with its name, well inside the job limit.

Before this guard a test that never returned left the job silent until its
30-minute limit cancelled it, and a cancelled job names nothing. The `Test`
step now has its own limit, under the job's, and a follow-up step prints the
tests still running. `Build & Lint` must keep needing the job.
"""

import os
import re
import unittest

CI_YML = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", ".github", "workflows", "ci.yml"
)


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

    def test_build_and_lint_still_needs_the_job_and_demands_success(self):
        build = _job(self.text, "build")
        self.assertRegex(build, r"needs: \[[^\]]*rust-test[^\]]*\]")
        self.assertIn('[ "$TEST" = success ]', build)


if __name__ == "__main__":
    unittest.main()
