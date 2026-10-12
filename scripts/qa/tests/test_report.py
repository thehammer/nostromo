"""The PASS/FAIL/WARN/INFO/SKIP reporter shared by the QA scripts (lib/report.py)."""
import contextlib
import io
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from report import Report   # noqa: E402


def capture(fn):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = fn()
    return out.getvalue(), result


class TestSkipLevel(unittest.TestCase):
    def test_a_skip_prints_as_SKIP_step_detail(self):
        r = Report()
        out, _ = capture(lambda: r.skip("teri-fred", "Teri is not the active focus"))
        self.assertEqual(out, "SKIP teri-fred: Teri is not the active focus\n")

    def test_the_summary_counts_five_levels_in_order(self):
        r = Report()

        def run():
            r.passed("a", "x")
            r.passed("a", "x")
            r.fail("b", "x")
            r.warn("c", "x")
            r.info("d", "x")
            r.info("d", "x")
            r.info("d", "x")
            r.skip("e", "x")
            return r.summary()
        out, _status = capture(run)
        self.assertEqual(out.splitlines()[-1], "SUMMARY: 2 pass, 1 fail, 1 warn, 3 info, 1 skip")

    def test_the_old_summary_prefix_is_still_valid(self):
        r = Report()
        out, _ = capture(r.summary)
        self.assertRegex(out, r"^SUMMARY: \d+ pass, \d+ fail, \d+ warn")
        self.assertEqual(out.strip(), "SUMMARY: 0 pass, 0 fail, 0 warn, 0 info, 0 skip")

    def test_a_skip_is_not_a_failure(self):
        r = Report()
        _out, status = capture(lambda: (r.skip("x", "y"), r.summary())[1])
        self.assertEqual(status, 0)

    def test_a_fail_still_makes_the_exit_status_1(self):
        r = Report()
        _out, status = capture(lambda: (r.skip("x", "y"), r.fail("z", "boom"), r.summary())[2])
        self.assertEqual(status, 1)


if __name__ == "__main__":
    unittest.main()
