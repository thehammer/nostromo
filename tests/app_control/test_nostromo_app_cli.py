"""wait/expect logic in bin/nostromo-app, with the socket call stubbed out.

Run with:  python3 -m unittest discover -s tests/app_control
"""
import importlib.machinery, importlib.util, io, os, unittest
from contextlib import redirect_stdout
from unittest import mock

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


class TranscriptAnchorTests(unittest.TestCase):
    def run_cli(self, argv, reply):
        sent = []
        def fake(req):
            sent.append(req)
            if isinstance(reply, BaseException): raise reply
            return reply
        out = io.StringIO()
        with mock.patch.object(cli, "call", fake), mock.patch("sys.argv", ["nostromo-app"] + argv), redirect_stdout(out):
            try:
                cli.main(); code = 0
            except SystemExit as e:
                code = e.code
        return sent, code, out.getvalue()

    def test_maps_arguments(self):
        sent, code, out = self.run_cli(["-w", "2", "transcript-anchor", "--focus", "kate"], {"tag": "kate"})
        self.assertEqual(sent, [{"cmd": "transcript-anchor", "window": 2, "focus": "kate"}])
        self.assertEqual(code, 0)
        self.assertIn('"tag": "kate"', out)

    def test_focus_is_optional(self):
        sent, _, _ = self.run_cli(["transcript-anchor"], {})
        self.assertEqual(sent, [{"cmd": "transcript-anchor", "window": 0}])

    def test_exits_1_on_an_error_reply(self):
        _, code, _ = self.run_cli(["transcript-anchor"], SystemExit(1))
        self.assertEqual(code, 1)

    def test_error_reply_from_the_app_exits_1(self):
        sock = mock.MagicMock()
        sock.recv.return_value = b'{"ok": false, "error": "not found: no pane"}\n'
        with mock.patch.object(cli.socket, "socket", return_value=sock):
            with self.assertRaises(SystemExit) as cm:
                cli.call({"cmd": "transcript-anchor", "window": 0})
        self.assertIn("no pane", str(cm.exception.code))
        sent, code, _ = self.run_cli(["transcript-anchor"], SystemExit("error: not found"))
        self.assertNotEqual(code, 0)

    def test_help_documents_flags(self):
        out = io.StringIO()
        with mock.patch("sys.argv", ["nostromo-app", "transcript-anchor", "--help"]), redirect_stdout(out):
            with self.assertRaises(SystemExit) as cm: cli.main()
        self.assertEqual(cm.exception.code, 0)
        self.assertIn("--focus", out.getvalue())


class TrackerCommandTests(unittest.TestCase):
    """`tracker show|file` and `tracker-anchor` (agent tracker pane, T1): argument mapping, errors, help and the
    READ-ONLY marking. The commands only ever ask; the CLI must never send anything else on their behalf."""

    def run_cli(self, argv, reply):
        sent = []
        def fake(req):
            sent.append(req)
            if isinstance(reply, BaseException): raise reply
            return reply
        out = io.StringIO()
        with mock.patch.object(cli, "call", fake), mock.patch("sys.argv", ["nostromo-app"] + argv), redirect_stdout(out):
            try:
                cli.main(); code = 0
            except SystemExit as e:
                code = e.code
        return sent, code, out.getvalue()

    def help_text(self, argv):
        out = io.StringIO()
        with mock.patch("sys.argv", ["nostromo-app"] + argv + ["--help"]), redirect_stdout(out):
            with self.assertRaises(SystemExit) as cm: cli.main()
        self.assertEqual(cm.exception.code, 0)
        return out.getvalue()

    # -- tracker show / file ----------------------------------------------------------

    def test_window_may_follow_the_subcommand(self):
        sent, code, _ = self.run_cli(["tracker-anchor", "--focus", "kate", "-w", "2"], {})
        self.assertEqual(code, 0)
        self.assertEqual(sent, [{"cmd": "tracker-anchor", "window": 2, "focus": "kate"}])
        sent, _, _ = self.run_cli(["tracker", "file", "-w", "1"], {})
        self.assertEqual(sent, [{"cmd": "tracker", "window": 1, "sub": "file"}])
        sent, _, _ = self.run_cli(["-w", "3", "tracker", "show"], {})
        self.assertEqual(sent, [{"cmd": "tracker", "window": 3, "sub": "show"}])

    def test_show_maps_arguments(self):
        sent, code, out = self.run_cli(["tracker", "show", "--focus", "kate"], {"tag": "kate"})
        self.assertEqual(sent, [{"cmd": "tracker", "window": 0, "sub": "show", "focus": "kate"}])
        self.assertEqual(code, 0)
        self.assertIn('"tag": "kate"', out)

    def test_show_focus_is_optional(self):
        sent, code, _ = self.run_cli(["tracker", "show"], {})
        self.assertEqual(sent, [{"cmd": "tracker", "window": 0, "sub": "show"}])
        self.assertEqual(code, 0)

    def test_show_takes_the_window_from_the_global_flag(self):
        sent, _, _ = self.run_cli(["-w", "2", "tracker", "show", "--focus", "kate"], {})
        self.assertEqual(sent, [{"cmd": "tracker", "window": 2, "sub": "show", "focus": "kate"}])

    def test_file_maps_arguments(self):
        sent, code, out = self.run_cli(["tracker", "file", "--focus", "kate"], {"path": "/repo/index.md", "size": 7306})
        self.assertEqual(sent, [{"cmd": "tracker", "window": 0, "sub": "file", "focus": "kate"}])
        self.assertEqual(code, 0)
        self.assertIn('"size": 7306', out)

    def test_file_focus_is_optional_and_window_is_mapped(self):
        sent, _, _ = self.run_cli(["-w", "1", "tracker", "file"], {})
        self.assertEqual(sent, [{"cmd": "tracker", "window": 1, "sub": "file"}])

    def test_the_reply_is_printed_as_json(self):
        import json
        reply = {"tag": "kate", "waiting": False, "sections": [{"id": "now", "items": []}], "strip": {"count": 0}}
        _, _, out = self.run_cli(["tracker", "show"], reply)
        self.assertEqual(json.loads(out), reply)

    def test_tracker_needs_a_known_subcommand(self):
        for argv in (["tracker"], ["tracker", "edit"], ["tracker", "set-status"]):
            with self.subTest(argv=argv):
                sent = []
                with mock.patch.object(cli, "call", lambda req: sent.append(req)), \
                        mock.patch("sys.argv", ["nostromo-app"] + argv), \
                        mock.patch("sys.stderr", io.StringIO()), redirect_stdout(io.StringIO()):
                    with self.assertRaises(SystemExit) as cm: cli.main()
                self.assertEqual(cm.exception.code, 2)
                self.assertEqual(sent, [], "an unknown tracker subcommand must send nothing")

    def test_show_and_file_exit_1_on_an_error_reply(self):
        for sub in ("show", "file"):
            with self.subTest(sub=sub):
                _, code, _ = self.run_cli(["tracker", sub], SystemExit(1))
                self.assertEqual(code, 1)

    # -- tracker-anchor ---------------------------------------------------------------

    def test_anchor_maps_arguments(self):
        sent, code, out = self.run_cli(["-w", "2", "tracker-anchor", "--focus", "kate"], {"tag": "kate"})
        self.assertEqual(sent, [{"cmd": "tracker-anchor", "window": 2, "focus": "kate"}])
        self.assertEqual(code, 0)
        self.assertIn('"tag": "kate"', out)

    def test_anchor_focus_is_optional(self):
        sent, _, _ = self.run_cli(["tracker-anchor"], {})
        self.assertEqual(sent, [{"cmd": "tracker-anchor", "window": 0}])

    def test_anchor_exits_1_on_an_error_reply(self):
        _, code, _ = self.run_cli(["tracker-anchor"], SystemExit(1))
        self.assertEqual(code, 1)

    # -- failures through the real transport -------------------------------------------

    def test_error_reply_from_the_app_exits_non_zero_with_the_apps_message(self):
        for req in ({"cmd": "tracker", "window": 0, "sub": "show"}, {"cmd": "tracker-anchor", "window": 0}):
            with self.subTest(cmd=req["cmd"]):
                sock = mock.MagicMock()
                sock.recv.return_value = b'{"ok": false, "error": "not found: no tracker pane"}\n'
                with mock.patch.object(cli.socket, "socket", return_value=sock):
                    with self.assertRaises(SystemExit) as cm:
                        cli.call(req)
                self.assertIn("no tracker pane", str(cm.exception.code))

    def test_an_unreachable_app_exits_non_zero_and_says_where_it_looked(self):
        sock = mock.MagicMock()
        sock.connect.side_effect = FileNotFoundError("no socket")
        with mock.patch.object(cli.socket, "socket", return_value=sock):
            with self.assertRaises(SystemExit) as cm:
                cli.call({"cmd": "tracker-anchor", "window": 0})
        self.assertIn("cannot reach", str(cm.exception.code))
        sock.sendall.assert_not_called()

    # -- help and the READ-ONLY marking ------------------------------------------------

    def test_help_documents_focus(self):
        self.assertIn("--focus", self.help_text(["tracker"]))
        self.assertIn("--focus", self.help_text(["tracker-anchor"]))

    def test_help_documents_the_subcommands(self):
        text = self.help_text(["tracker"])
        self.assertIn("show", text)
        self.assertIn("file", text)

    def test_every_tracker_command_is_marked_read_only_in_the_module_docstring(self):
        doc = cli.__doc__ or ""
        lines = [l for l in doc.splitlines()
                 if l.strip().startswith(("nostromo-app tracker show", "nostromo-app tracker file", "nostromo-app tracker-anchor"))]
        self.assertEqual(len(lines), 3, "tracker show, tracker file and tracker-anchor are each documented once")
        for line in lines:
            with self.subTest(line=line.strip()[:40]):
                self.assertIn("READ-ONLY", line)

    def test_the_top_level_help_lists_both_commands_as_read_only(self):
        out = io.StringIO()
        with mock.patch("sys.argv", ["nostromo-app", "--help"]), redirect_stdout(out):
            with self.assertRaises(SystemExit): cli.main()
        text = out.getvalue()
        for name in ("tracker", "tracker-anchor"):
            with self.subTest(command=name):
                row = [l for l in text.splitlines() if l.startswith(f"    {name}  ")]
                self.assertTrue(row, f"{name} is listed in --help")
                self.assertIn("READ-ONLY", " ".join(row))

    def test_the_tracker_commands_send_one_request_and_nothing_that_acts(self):
        acting = {"click", "drag", "key", "type", "paste", "drop", "activate", "restore"}
        for argv in (["tracker", "show"], ["tracker", "file"], ["tracker-anchor"]):
            with self.subTest(argv=argv):
                sent, _, _ = self.run_cli(argv, {})
                self.assertEqual(len(sent), 1)
                self.assertNotIn(sent[0]["cmd"], acting)
                self.assertIn(sent[0]["cmd"], ("tracker", "tracker-anchor"))
                self.assertNotIn("modifiers", sent[0])


class TasksCommandTests(unittest.TestCase):
    """`tasks list|chip` (Background activity, BA3): argument mapping, errors, help and the READ-ONLY marking.
    The commands only ever ask; the CLI must never send anything else (no stop, no output read) on their behalf."""

    def run_cli(self, argv, reply):
        sent = []
        def fake(req):
            sent.append(req)
            if isinstance(reply, BaseException): raise reply
            return reply
        out = io.StringIO()
        with mock.patch.object(cli, "call", fake), mock.patch("sys.argv", ["nostromo-app"] + argv), redirect_stdout(out):
            try:
                cli.main(); code = 0
            except SystemExit as e:
                code = e.code
        return sent, code, out.getvalue()

    def rejected(self, argv):
        """Run `argv` expecting an argument error: (exit code, requests sent)."""
        sent = []
        with mock.patch.object(cli, "call", lambda req: sent.append(req)), \
                mock.patch("sys.argv", ["nostromo-app"] + argv), \
                mock.patch("sys.stderr", io.StringIO()), redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as cm: cli.main()
        return cm.exception.code, sent

    def help_text(self, argv):
        out = io.StringIO()
        with mock.patch("sys.argv", ["nostromo-app"] + argv + ["--help"]), redirect_stdout(out):
            with self.assertRaises(SystemExit) as cm: cli.main()
        self.assertEqual(cm.exception.code, 0)
        return out.getvalue()

    # -- tasks list -------------------------------------------------------------------

    def test_list_maps_to_one_tasks_request_for_window_0(self):
        sent, code, _ = self.run_cli(["tasks", "list"], {})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 0, "sub": "list"}])
        self.assertEqual(code, 0)

    def test_list_focus_is_sent_when_given(self):
        sent, code, out = self.run_cli(["tasks", "list", "--focus", "kate"], {"tag": "kate"})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 0, "sub": "list", "focus": "kate"}])
        self.assertEqual(code, 0)
        self.assertIn('"tag": "kate"', out)

    def test_list_all_asks_for_the_ended_and_housekeeping_rows_too(self):
        sent, code, _ = self.run_cli(["tasks", "list", "--all"], {})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 0, "sub": "list", "all": True}])
        self.assertEqual(code, 0)

    def test_list_without_all_does_not_send_all(self):
        sent, _, _ = self.run_cli(["tasks", "list", "--focus", "kate"], {})
        self.assertNotIn("all", sent[0])

    def test_list_takes_focus_and_all_together(self):
        sent, _, _ = self.run_cli(["tasks", "list", "--all", "--focus", "kate"], {})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 0, "sub": "list", "focus": "kate", "all": True}])

    def test_window_may_come_before_or_after_the_subcommand(self):
        sent, code, _ = self.run_cli(["-w", "2", "tasks", "list"], {})
        self.assertEqual(code, 0)
        self.assertEqual(sent, [{"cmd": "tasks", "window": 2, "sub": "list"}])
        sent, _, _ = self.run_cli(["tasks", "list", "-w", "2"], {})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 2, "sub": "list"}])
        sent, _, _ = self.run_cli(["tasks", "list", "--focus", "kate", "--all", "-w", "3"], {})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 3, "sub": "list", "focus": "kate", "all": True}])
        sent, _, _ = self.run_cli(["tasks", "chip", "-w", "1"], {})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 1, "sub": "chip"}])

    def test_the_reply_is_printed_as_json(self):
        import json
        reply = {"tag": "kate", "running": 1, "chip": {"tag": "kate", "text": "\u25f7 1 running", "state": "running"},
                 "tasks": [{"id": "b1", "section": "running", "title": "npm run dev", "elapsed_ms": 4100}]}
        _, _, out = self.run_cli(["tasks", "list"], reply)
        self.assertEqual(json.loads(out), reply)

    # -- tasks chip -------------------------------------------------------------------

    def test_chip_maps_arguments(self):
        sent, code, out = self.run_cli(["tasks", "chip"], {"tag": "kate", "text": None, "state": "hidden"})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 0, "sub": "chip"}])
        self.assertEqual(code, 0)
        self.assertIn('"state": "hidden"', out)

    def test_chip_focus_is_sent_when_given(self):
        sent, _, _ = self.run_cli(["tasks", "chip", "--focus", "kate"], {})
        self.assertEqual(sent, [{"cmd": "tasks", "window": 0, "sub": "chip", "focus": "kate"}])

    def test_chip_does_not_take_all_and_sends_nothing(self):
        code, sent = self.rejected(["tasks", "chip", "--all"])
        self.assertEqual(code, 2)
        self.assertEqual(sent, [], "a rejected invocation must not reach the app")

    # -- what the CLI refuses ---------------------------------------------------------

    def test_tasks_needs_a_known_subcommand_and_sends_nothing_otherwise(self):
        # `stop` and `output` are not part of this slice: they must not reach the app from this CLI.
        for argv in (["tasks"], ["tasks", "stop"], ["tasks", "stop", "b1"], ["tasks", "output"], ["tasks", "output", "b1"],
                     ["tasks", "kill"], ["tasks", "clear"]):
            with self.subTest(argv=argv):
                code, sent = self.rejected(argv)
                self.assertEqual(code, 2)
                self.assertEqual(sent, [], "an unknown tasks subcommand must send nothing")

    # -- failures ---------------------------------------------------------------------

    def test_list_and_chip_exit_1_on_an_error_reply(self):
        for sub in ("list", "chip"):
            with self.subTest(sub=sub):
                _, code, _ = self.run_cli(["tasks", sub], SystemExit(1))
                self.assertEqual(code, 1)

    def test_error_reply_from_the_app_exits_non_zero_with_the_apps_message(self):
        for req in ({"cmd": "tasks", "window": 0, "sub": "list"}, {"cmd": "tasks", "window": 0, "sub": "chip"}):
            with self.subTest(sub=req["sub"]):
                sock = mock.MagicMock()
                sock.recv.return_value = b'{"ok": false, "error": "not found: no pane for focus kate"}\n'
                with mock.patch.object(cli.socket, "socket", return_value=sock):
                    with self.assertRaises(SystemExit) as cm:
                        cli.call(req)
                self.assertIn("no pane for focus kate", str(cm.exception.code))

    # -- help and the READ-ONLY marking -----------------------------------------------

    def test_help_documents_the_subcommands_and_options(self):
        text = self.help_text(["tasks"])
        for word in ("list", "chip", "--focus", "--all"):
            with self.subTest(word=word):
                self.assertIn(word, text)

    def test_every_tasks_command_is_marked_read_only_in_the_module_docstring(self):
        doc = cli.__doc__ or ""
        lines = [l for l in doc.splitlines()
                 if l.strip().startswith(("nostromo-app tasks list", "nostromo-app tasks chip"))]
        self.assertEqual(len(lines), 2, "tasks list and tasks chip are each documented once")
        for line in lines:
            with self.subTest(line=line.strip()[:40]):
                self.assertIn("READ-ONLY", line)

    def test_the_top_level_help_lists_tasks_as_read_only(self):
        out = io.StringIO()
        with mock.patch("sys.argv", ["nostromo-app", "--help"]), redirect_stdout(out):
            with self.assertRaises(SystemExit): cli.main()
        row = [l for l in out.getvalue().splitlines() if l.startswith("    tasks  ")]
        self.assertTrue(row, "tasks is listed in --help")
        self.assertIn("READ-ONLY", " ".join(row))

    def test_the_tasks_commands_send_one_request_and_nothing_that_acts(self):
        acting = {"click", "drag", "key", "type", "paste", "drop", "activate", "restore"}
        for argv in (["tasks", "list"], ["tasks", "list", "--all"], ["tasks", "chip"]):
            with self.subTest(argv=argv):
                sent, _, _ = self.run_cli(argv, {})
                self.assertEqual(len(sent), 1)
                self.assertNotIn(sent[0]["cmd"], acting)
                self.assertEqual(sent[0]["cmd"], "tasks")
                self.assertIn(sent[0]["sub"], ("list", "chip"))


if __name__ == "__main__":
    unittest.main()
