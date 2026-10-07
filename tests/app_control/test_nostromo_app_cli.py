"""wait/expect logic in bin/nostromo-app, with the socket call stubbed out.

Run with:  python3 -m unittest discover -s tests/app_control
"""
import importlib.machinery, importlib.util, os, unittest

PATH = os.path.join(os.path.dirname(__file__), "..", "..", "bin", "nostromo-app")
_loader = importlib.machinery.SourceFileLoader("nostromo_app", PATH)
_spec = importlib.util.spec_from_file_location("nostromo_app", PATH, loader=_loader)
cli = importlib.util.module_from_spec(_spec)
_loader.exec_module(cli)


class WaitTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.real = cli.call
        cli.call = self.fake

    def tearDown(self):
        cli.call = self.real

    def fake(self, req):
        self.calls.append(req)
        return self.script.pop(0) if len(self.script) > 1 else self.script[0]

    def test_present_once_it_appears(self):
        self.script = [[], [], [{"class": "NSTextField"}]]
        self.assertTrue(cli.wait_for("x", 0, gone=False, timeout=5, poll=0))
        self.assertEqual(len(self.calls), 3)

    def test_times_out_when_it_never_appears(self):
        self.script = [[]]
        self.assertFalse(cli.wait_for("x", 0, gone=False, timeout=0, poll=0))

    def test_gone_waits_for_disappearance(self):
        self.script = [[{"a": 1}], [{"a": 1}], []]
        self.assertTrue(cli.wait_for("x", 0, gone=True, timeout=5, poll=0))

    def test_missing_sheet_counts_as_absent_not_as_an_error(self):
        def boom(req): raise SystemExit("error: not found: window 0 has no sheet")
        cli.call = boom
        self.assertTrue(cli.wait_for("x", 0, gone=True, timeout=0, sheet=True, poll=0))
        self.assertFalse(cli.wait_for("x", 0, gone=False, timeout=0, sheet=True, poll=0))

    def test_find_count_passes_the_sheet_flag(self):
        self.script = [[]]
        cli.find_count("x", 2, sheet=True)
        self.assertEqual(self.calls[0], {"cmd": "find", "window": 2, "text": "x", "sheet": True})


if __name__ == "__main__":
    unittest.main()
