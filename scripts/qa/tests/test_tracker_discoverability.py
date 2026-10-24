"""Hermetic tests of scripts/qa/tracker-discoverability.sh: the dry run starts nothing, and the checks are right."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

from qa_harness import QA_DIR

SCRIPT = os.path.join(QA_DIR, "tracker-discoverability.sh")
sys.path.insert(0, os.path.join(QA_DIR, "lib"))
import tracker_discoverability as td  # noqa: E402


class TestDryRun(unittest.TestCase):
    def run_script(self, *args):
        env = {"PATH": os.environ["PATH"], "HOME": tempfile.mkdtemp()}  # no QA root: a live run would fail
        return subprocess.run([SCRIPT, *args], capture_output=True, text=True, env=env, timeout=30)

    def test_dry_run_prints_the_plan_for_both_agents_and_starts_nothing(self):
        p = self.run_script("--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        for needle in ("dry run", "agent cody:", "agent claudia:", "qa-tracker-1", "qa-tracker-10", "keep a tracker of what we're doing"):
            self.assertIn(needle, p.stdout)

    def test_dry_run_honours_runs(self):
        p = self.run_script("--dry-run", "--runs", "2", "--agents", "claudia")
        self.assertIn("qa-tracker-2", p.stdout)
        self.assertNotIn("qa-tracker-3", p.stdout)
        self.assertNotIn("agent cody:", p.stdout)

    def test_unknown_flag_is_refused(self):
        self.assertNotEqual(self.run_script("--bogus").returncode, 0)


class TestChecks(unittest.TestCase):
    def test_searches_before_the_tracker_call(self):
        T = td.TRACKER_TOOL
        self.assertEqual(td.tool_searches_before_tracker([T]), 0)
        self.assertEqual(td.tool_searches_before_tracker(["ToolSearch", T, "ToolSearch"]), 1)
        self.assertEqual(td.tool_searches_before_tracker(["ToolSearch", "ToolSearch", T]), 2)
        self.assertIsNone(td.tool_searches_before_tracker(["ToolSearch"]))

    def test_a_run_passes_only_with_a_board_and_at_most_one_search(self):
        T = td.TRACKER_TOOL
        self.assertTrue(td.run_passes(True, ["ToolSearch", T])[0])
        self.assertFalse(td.run_passes(False, [T])[0])
        self.assertFalse(td.run_passes(True, ["ToolSearch", "ToolSearch", T])[0])
        self.assertFalse(td.run_passes(True, [])[0])

    def test_tool_calls_reads_a_jsonl_transcript(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as f:
            f.write(json.dumps({"message": {"content": [{"type": "tool_use", "name": "ToolSearch"}, {"type": "text", "text": "x"}]}}) + "\n")
            f.write("not json\n")
            f.write(json.dumps({"message": {"content": [{"type": "tool_use", "name": td.TRACKER_TOOL}]}}) + "\n")
        self.addCleanup(os.unlink, f.name)
        self.assertEqual(td.tool_calls(f.name), ["ToolSearch", td.TRACKER_TOOL])


if __name__ == "__main__":
    unittest.main()
