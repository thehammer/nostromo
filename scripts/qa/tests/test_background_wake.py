"""Hermetic tests of scripts/qa/background-wake.sh and lib/background_wake.py.

The script never sees a real app: QA_APP is fake_nostromo_app.py in its `wake` scenario and QA_INSTANCE is a
stub qa-instance.sh that only prints a QA root made inside the sandbox.
"""
import json
import os
import subprocess
import sys
import unittest

from qa_harness import QA_DIR, QATestCase

SCRIPT = os.path.join(QA_DIR, "background-wake.sh")
sys.path.insert(0, os.path.join(QA_DIR, "lib"))
import background_wake as bw  # noqa: E402

STUB_INSTANCE = """#!/bin/sh
echo "$1 $*" >> "$QA_ROOT_DIR/instance.log"
case "$1" in
  start) echo "QA_ROOT=$QA_ROOT_DIR" ;;
  focus) echo "QA_FOCUS_TAG=cody-qa-test"; echo "QA_FOCUS_LABEL=QA approvals" ;;
  stop) exit "${STUB_STOP_RC:-0}" ;;
esac
"""


def sandbox(root):
    """A QA root with its marker and the stub instance script, inside the test sandbox."""
    qa_root = os.path.join(root, "qa-root")
    os.mkdir(qa_root)
    open(os.path.join(qa_root, ".nostromo-qa-root"), "w").close()
    stub = os.path.join(root, "stub-instance.sh")
    with open(stub, "w") as f:
        f.write(STUB_INSTANCE)
    os.chmod(stub, 0o755)


class WakeScriptTest(QATestCase):
    ENV = {"QA_INSTANCE": "@ROOT@/stub-instance.sh", "QA_ROOT_DIR": "@ROOT@/qa-root"}

    def go(self, wake=None, env=None, preexisting=None):
        def prep(root):
            sandbox(root)
            if preexisting:
                preexisting(root)
        return self.run_script(SCRIPT, scenario={"wake": wake or {}}, env={**self.ENV, **(env or {})},
                               preexisting=prep)

    def verdicts(self, run):
        return {ln.split(":")[0].split(" ", 1)[1]: ln.split(" ", 1)[0]
                for ln in run.stdout.splitlines() if ln.startswith(("PASS ", "FAIL ", "INCONCLUSIVE "))}

    def test_happy_path_passes_every_check(self):
        run = self.go()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        verdicts = self.verdicts(run)
        self.assertNotIn("FAIL", verdicts.values())
        for k in (1, 2, 3, 4):
            for part in ("anchor-before", "marker", "reply", "anchor-after"):
                self.assertEqual(verdicts["wake-%d-%s" % (k, part)], "PASS")
        for name in ("raw-notification", "event-sentinel", "result-sentinel", "bidi-override", "hangul-filler"):
            self.assertEqual(verdicts["absent-" + name], "PASS")
        for name in ("chip-running", "task-monitor", "task-shell", "ax-marker-label", "ax-row-label",
                     "marker-click-opens-window", "escape-closes-window"):
            self.assertEqual(verdicts[name], "PASS")
        self.assertIn("RESULT: PASS", run.stdout)
        self.assertEqual(run.forbidden, [])

    def test_the_instance_is_started_focused_and_stopped(self):
        run = self.go()
        with open(os.path.join(run.root, "qa-root", "instance.log")) as f:
            verbs = [ln.split()[0] for ln in f]
        self.assertEqual(verbs, ["start", "focus", "stop"])

    def test_only_allow_listed_verbs_and_the_qa_socket_are_used(self):
        run = self.go()
        self.assertEqual(run.forbidden, [])
        sock = os.path.join(run.root, "qa-root", "app-control.sock")
        allowed = {"windows", "wait", "click", "hittest", "type", "key", "tasks", "transcript-anchor",
                   "expect", "find"}
        for argv in run.calls:
            self.assertEqual(argv[:2], ["--socket", sock])
            self.assertIn(argv[2], allowed)
        types = [argv for argv in run.calls if argv[2] == "type"]
        self.assertEqual(len(types), 1)
        self.assertTrue(types[0][3].startswith("WAKE:basic:" + os.path.join(run.root, "qa-root")))

    def test_anchor_drift_after_a_wake_fails(self):
        steady = {"turnKey": "t", "itemKey": "i", "offsetPt": 0, "bottomOffsetPt": 0, "following": True}
        # reads: wake-1 before, wake-1 after (scrolled off the tail), then steady.
        drifted = {**steady, "bottomOffsetPt": 40, "following": False}
        run = self.go(wake={"anchors": [steady, drifted, steady]})
        self.assertEqual(run.returncode, 1)
        self.assertEqual(self.verdicts(run)["wake-1-anchor-after"], "FAIL")
        self.assertEqual(self.verdicts(run)["wake-2-anchor-after"], "PASS")
        self.assertIn("RESULT: FAIL", run.stdout)

    def test_a_bottom_offset_that_is_not_zero_fails_even_when_following(self):
        steady = {"following": True, "bottomOffsetPt": 0}
        run = self.go(wake={"anchors": [steady, {"following": True, "bottomOffsetPt": 3}, steady]})
        self.assertEqual(run.returncode, 1)
        self.assertEqual(self.verdicts(run)["wake-1-anchor-after"], "FAIL")

    def test_a_sentinel_in_the_window_fails_and_is_not_echoed(self):
        run = self.go(wake={"extra_texts": ["SECRET-OUTPUT-EVENT tick 1"]})
        self.assertEqual(run.returncode, 1)
        self.assertEqual(self.verdicts(run)["absent-event-sentinel"], "FAIL")
        self.assertEqual(self.verdicts(run)["absent-result-sentinel"], "PASS")
        self.assertNotIn("tick 1", run.stdout)

    def test_a_raw_notification_or_bidi_character_in_the_window_fails(self):
        run = self.go(wake={"extra_texts": ["<task-notification><task-id>", "x‮y"]})
        self.assertEqual(run.returncode, 1)
        v = self.verdicts(run)
        self.assertEqual(v["absent-raw-notification"], "FAIL")
        self.assertEqual(v["absent-bidi-override"], "FAIL")
        self.assertNotIn("‮", run.stdout)

    def test_a_missing_marker_fails(self):
        run = self.go(wake={"drop_texts": ["3 background"]})
        self.assertEqual(run.returncode, 1)
        self.assertEqual(self.verdicts(run)["wake-4-marker"], "FAIL")
        self.assertEqual(self.verdicts(run)["wake-3-marker"], "PASS")

    def test_escape_that_does_not_close_the_window_is_inconclusive_not_fail(self):
        run = self.go(wake={"escape_ignored": True})
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertEqual(self.verdicts(run)["escape-closes-window"], "INCONCLUSIVE")
        self.assertEqual(self.verdicts(run)["marker-click-opens-window"], "PASS")

    def test_a_chip_that_never_runs_aborts_with_fail(self):
        run = self.go(wake={"chip_state": "hidden"})
        self.assertEqual(run.returncode, 1)
        self.assertEqual(self.verdicts(run)["chip-running"], "FAIL")
        with open(os.path.join(run.root, "qa-root", "instance.log")) as f:
            self.assertEqual(f.read().splitlines()[-1].split()[0], "stop")

    def test_an_isolation_guard_failure_fails_the_run(self):
        run = self.go(env={"STUB_STOP_RC": "1"})
        self.assertEqual(run.returncode, 1)
        self.assertEqual(self.verdicts(run)["isolation-guard"], "FAIL")

    def test_refuses_when_the_real_focuses_file_carries_a_qa_marker(self):
        def prep(root):
            d = os.path.join(root, "home", ".nostromo")
            os.makedirs(d)
            with open(os.path.join(d, "focuses.json"), "w") as f:
                json.dump({"x": "WAKE:basic:/tmp/leak"}, f)
        run = self.go(preexisting=prep)
        self.assertEqual(run.returncode, 2)
        self.assertIn("REFUSING TO RUN", run.stderr)
        self.assertEqual(run.calls, [])
        self.assertFalse(os.path.exists(os.path.join(run.root, "qa-root", "instance.log")))

    def test_refuses_a_socket_outside_a_qa_root(self):
        run = self.go(env={"NOSTROMO_APP_CONTROL_SOCKET": "@ROOT@/home/.nostromo/app-control.sock"})
        self.assertEqual(run.returncode, 2)
        self.assertIn("outside a QA root", run.stderr)
        self.assertEqual(run.calls, [])
        self.assertFalse(os.path.exists(os.path.join(run.root, "qa-root", "instance.log")))

    def test_a_socket_inside_a_qa_root_is_accepted_but_never_used(self):
        run = self.go(env={"NOSTROMO_APP_CONTROL_SOCKET": "@ROOT@/qa-root/app-control.sock"})
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_a_locked_display_is_inconclusive(self):
        run = self.go(wake={"windows_hidden": True})
        self.assertEqual(run.returncode, 3, run.stdout)
        self.assertIn("RESULT: INCONCLUSIVE", run.stdout)

    def test_arguments_are_refused(self):
        run = self.run_script(SCRIPT, scenario={"wake": {}}, env=self.ENV, preexisting=sandbox, args=["--bogus"])
        self.assertEqual(run.returncode, 2)


class HelperTest(unittest.TestCase):
    def test_markers(self):
        self.assertEqual(bw.MARKERS[1], '⟲ Monitor: new output "qa-ticker"')
        self.assertEqual(bw.MARKERS[2], '⟲ Shell: completed "qa-sleep 60"')
        self.assertEqual(bw.MARKERS[3], "⟲ 2 background events")
        self.assertEqual(bw.MARKERS[4], "⟲ 3 background events")

    def test_anchor_checks(self):
        self.assertTrue(bw.anchor_following({"following": True, "bottomOffsetPt": 12}))
        self.assertFalse(bw.anchor_following({"following": False}))
        self.assertTrue(bw.anchor_at_bottom({"following": True, "bottomOffsetPt": 0}))
        self.assertTrue(bw.anchor_at_bottom({"following": True, "bottomOffsetPt": 0.0}))
        self.assertFalse(bw.anchor_at_bottom({"following": True, "bottomOffsetPt": 0.5}))
        self.assertFalse(bw.anchor_at_bottom({"following": True}))
        self.assertFalse(bw.anchor_at_bottom({"following": False, "bottomOffsetPt": 0}))
        self.assertFalse(bw.anchor_at_bottom({"following": True, "bottomOffsetPt": False}))
        self.assertFalse(bw.anchor_at_bottom(None))

    def test_task_checks(self):
        listing = {"tasks": [{"id": "a", "kind": "Monitor", "description": "qa-ticker", "window_open": True},
                             {"id": "b", "kind": "Shell", "description": "qa-sleep 60", "window_open": None}]}
        self.assertTrue(bw.has_task(listing, "Monitor", "qa-ticker"))
        self.assertFalse(bw.has_task(listing, "Shell", "qa-ticker"))
        self.assertIs(bw.window_open(listing, "a"), True)
        self.assertIsNone(bw.window_open(listing, "b"))
        self.assertIsNone(bw.window_open(listing, "zzz"))

    def test_chip_and_find(self):
        self.assertTrue(bw.chip_running({"state": "running"}))
        self.assertFalse(bw.chip_running({"state": "done"}))
        self.assertTrue(bw.found([{"text": "x"}]))
        self.assertFalse(bw.found([]))
        self.assertFalse(bw.found({"error": 1}))

    def test_absent_texts_hold_the_hostile_characters(self):
        self.assertEqual(bw.ABSENT_TEXTS["bidi-override"], "‮")
        self.assertEqual(bw.ABSENT_TEXTS["hangul-filler"], "ㅤ")
        out = subprocess.run([sys.executable, "-I", os.path.join(QA_DIR, "lib", "background_wake.py"), "absent", "bidi-override"],
                             capture_output=True, text=True)
        self.assertEqual(out.stdout, "‮")


if __name__ == "__main__":
    unittest.main()
