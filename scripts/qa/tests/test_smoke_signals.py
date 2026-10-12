"""teri-fred-smoke.sh must clean up after itself when it is interrupted.

The smoke takes keyboard focus, may have switched the window to Teri, may have a Send to agent sheet open,
and has a scratch directory full of screenshots of the user's real data. When it is stopped (Ctrl-C, a
`kill`, the terminal closing) all of that must still be put back. The wrapper `exec`s python, so a signal
sent to the wrapper's pid is the python process's own: its `finally` runs.

Each scenario makes the FAKE app hang (a killable sleep, after writing a `hanging` marker file) on a chosen
call, so the script is provably in the middle of something when the signal arrives. The tests wait for the
marker with a polling deadline (no timing assertions), signal the Popen pid, and then look at what is left.
"""
import os
import re
import signal
import unittest
from concurrent.futures import ThreadPoolExecutor

import qa_harness as H

BADGES = {"Fred": "3", "Mother": "1", "Perri": "2", "Teri": "4"}
NO_ROWS = {t: [] for t in ("Todos", "Jira", "Sentry", "Repo docs")}   # no row, so no sheet is ever opened
TODOS_ONLY = {"Jira": [], "Sentry": [], "Repo docs": []}   # the sheet opens from the first tab with rows (Todos)
ENV = {"QA_ALLOW_TERI_SWITCH": "1"}                          # the fake window starts on Perri; the run switches to Teri

# name -> (scenario, signal). The default hang is inside the d legibility step: the 1st screenshot is the
# "which tab was selected" read, the 2nd is the legibility measurement, by which time Teri is showing.
LEGIBILITY = {"hang": {"cmd": "screenshot", "nth": 2}, "rows": NO_ROWS}
SHEET_OPEN = {"rows": TODOS_ONLY, "badges": BADGES}

CASES = {
    "sigint_in_legibility": ({**LEGIBILITY, "badges": BADGES}, signal.SIGINT),
    "sigterm_in_legibility": ({**LEGIBILITY, "badges": BADGES}, signal.SIGTERM),
    "sighup_in_legibility": ({**LEGIBILITY, "badges": BADGES}, signal.SIGHUP),
    # the sheet is open when the signal arrives: while reading it, and while pressing a key in it
    "sigterm_reading_the_open_sheet": ({**SHEET_OPEN, "hang": {"cmd": "tree", "sheet": True, "nth": 1}}, signal.SIGTERM),
    "sigint_pressing_a_key_in_the_sheet": ({**SHEET_OPEN, "hang": {"cmd": "key", "nth": 2}}, signal.SIGINT),
}
RESULTS = {}


def interrupt(scenario, sig):
    started = H.start_script(H.SMOKE, scenario, ENV)
    result = {"hung": False}
    try:
        marker = started.wait_for_marker("hanging", timeout=60)
        result["hung"] = marker is not None
        if marker is not None:
            result["state_at_hang"] = started.state()
            started.send(sig)   # to the Popen pid: the wrapper pid, which must BE the python process
        result["run"] = started.finish(timeout=20)
    finally:
        started.kill()
    return result


def setUpModule():
    with ThreadPoolExecutor(max_workers=len(CASES)) as pool:
        futures = {k: pool.submit(interrupt, sc, sig) for k, (sc, sig) in CASES.items()}
        RESULTS.update({k: f.result() for k, f in futures.items()})


def tearDownModule():
    H.cleanup()


class Base(unittest.TestCase):
    def result(self, key):
        r = RESULTS[key]
        self.assertTrue(r["hung"], "the fake never reached the call it was told to hang on (the script never got that far)")
        run = r["run"]
        self.assertFalse(run.timed_out, f"the script did not end within 20 s of the signal:\n{run.stdout}")
        return r, run


class TestInterruptedInTheMiddleOfAStep(Base):
    CASES = ("sigint_in_legibility", "sigterm_in_legibility", "sighup_in_legibility")

    def test_the_scenario_really_is_in_teri_when_the_signal_arrives(self):
        for key in self.CASES:
            with self.subTest(key):
                r, _run = self.result(key)
                self.assertEqual(r["state_at_hang"]["windows"][0]["focus"], "Teri", "the run had switched Perri -> Teri")

    def test_the_previous_focus_is_put_back_and_keyboard_focus_handed_back(self):
        for key in self.CASES:
            with self.subTest(key):
                _r, run = self.result(key)
                self.assertEqual(run.state["windows"][0]["focus"], "Perri")
                self.assertEqual(run.commands()[-1], "restore", "restore must be the very last call")
                self.assertFalse(run.state["windows"][0]["key"])

    def test_the_run_says_it_was_interrupted_and_still_prints_a_summary(self):
        for key in self.CASES:
            with self.subTest(key):
                _r, run = self.result(key)
                self.assertTrue([d for _lv, _st, d in run.of("FAIL") if re.search(r"interrupted", d, re.I)], run.stdout)
                self.assertIsNotNone(run.summary, run.stdout)
                self.assertNotEqual(run.returncode, 0)
                self.assertNotIn("Traceback", run.all_output)

    def test_the_scratch_directory_with_the_screenshots_is_removed(self):
        for key in self.CASES:
            with self.subTest(key):
                _r, run = self.result(key)
                self.assertEqual(os.listdir(run.scratch_dir), [])

    def test_nothing_forbidden_happened_and_the_clean_up_sent_no_keys(self):
        for key in self.CASES:
            with self.subTest(key):
                _r, run = self.result(key)
                self.assertEqual(run.forbidden, [])
                self.assertEqual(run.keys(), [], "no sheet was open, so no key may be sent during the clean-up")


class TestInterruptedWithTheSendToAgentSheetOpen(Base):
    CASES = ("sigterm_reading_the_open_sheet", "sigint_pressing_a_key_in_the_sheet")

    def test_the_sheet_is_open_when_the_signal_arrives(self):
        for key in self.CASES:
            with self.subTest(key):
                r, _run = self.result(key)
                self.assertTrue(r["state_at_hang"]["windows"][0]["sheet"])

    def test_the_clean_up_cancels_the_sheet_with_escape_and_never_presses_start(self):
        for key in self.CASES:
            with self.subTest(key):
                _r, run = self.result(key)
                self.assertIn(("\x1b", ""), run.keys(), "Escape (Cancel) must be sent to the sheet during the clean-up")
                self.assertFalse(run.state["windows"][0]["sheet"])
                self.assertEqual(run.forbidden, [], "in particular: Start was never pressed")

    def test_everything_else_is_still_handed_back(self):
        for key in self.CASES:
            with self.subTest(key):
                _r, run = self.result(key)
                self.assertEqual(run.state["windows"][0]["focus"], "Perri")
                self.assertEqual(run.commands()[-1], "restore")
                self.assertEqual(os.listdir(run.scratch_dir), [])
                self.assertTrue([d for _lv, _st, d in run.of("FAIL") if re.search(r"interrupted", d, re.I)], run.stdout)
                self.assertIsNotNone(run.summary, run.stdout)


if __name__ == "__main__":
    unittest.main()
