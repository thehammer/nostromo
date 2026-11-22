"""`make python-test` is split into fast and slow suite lists. Nothing may drop out of the split."""
import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# The suites `make python-test` ran before it was split. Adding a suite is fine; removing one is not.
ORIGINAL = {
    "tests/transcript_load", "tests/doctor", "tests/doctor_preflight", "tests/ios_policy", "tests/fake_mother",
    "tests/fake_claude_perm", "tests/mother_contract", "tests/mother_policy", "tests/hit_test_policy",
    "tests/app_control", "tests/qa_instance", "tests/launch_smoke", "tests/ci_policy", "tests/operator_pin",
    "tests/ci_remote", "tests/mac_shards", "scripts/qa/tests", "scripts/tracker/tests", "tests/gates",
    "tests/restart_guard",
}


def _makefile():
    with open(os.path.join(REPO, "Makefile")) as f:
        return f.read()


def _list(name):
    m = re.search(rf"^{name} := (.*)$", _makefile(), re.M)
    assert m, f"no {name} in the Makefile"
    return m.group(1).split()


class PythonTestSplitTests(unittest.TestCase):
    def test_every_original_suite_is_in_exactly_one_list(self):
        fast, slow = _list("PY_FAST_SUITES"), _list("PY_SLOW_SUITES")
        self.assertEqual(set(fast) & set(slow), set(), "a suite is in both lists")
        self.assertEqual(len(fast), len(set(fast)))
        self.assertEqual(len(slow), len(set(slow)))
        self.assertLessEqual(ORIGINAL, set(fast) | set(slow), "a suite fell out of the split")

    def test_python_test_recipe_and_the_two_lists_name_the_same_suites(self):
        m = re.search(r"^python-test:\n((?:\t.*\n)+)", _makefile(), re.M)
        self.assertIsNotNone(m, "no python-test recipe")
        recipe = re.findall(r"^\tpython3 -m unittest discover -s (\S+) -v$", m.group(1), re.M)
        self.assertEqual(len(recipe), len(m.group(1).strip().splitlines()), "an unexpected line in the recipe")
        self.assertEqual(sorted(recipe), sorted(_list("PY_FAST_SUITES") + _list("PY_SLOW_SUITES")))

    def test_every_listed_suite_exists(self):
        for d in _list("PY_FAST_SUITES") + _list("PY_SLOW_SUITES"):
            self.assertTrue(os.path.isdir(os.path.join(REPO, d)), d)


if __name__ == "__main__":
    unittest.main()
