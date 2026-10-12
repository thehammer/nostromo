"""Unit tests for the read-only guards in scripts/qa/lib/appctl.py.

appctl is the single doorway from the QA scripts to the live app, so its refusals are the safety
net behind "this QA run cannot send anything, start anything or type anything". These tests drive
App against a tiny stub CLI that records its argv: a refusal is only real if the stub was never run.
"""
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import appctl   # noqa: E402
from appctl import App, AppError, RefusedError, is_forbidden_button   # noqa: E402


def btn(text=None, label=None, tooltip=None, cls="NSButton"):
    node = {"class": cls, "frame": {"x": 10, "y": 20, "w": 100, "h": 40}}
    for k, v in (("text", text), ("label", label), ("tooltip", tooltip)):
        if v is not None:
            node[k] = v
    return node


class TestForbiddenButtons(unittest.TestCase):
    def test_controls_with_side_effects_are_forbidden(self):
        cases = [
            btn("Start"),
            btn("Start", tooltip="Start (⌘Return)"),
            btn(tooltip="Start (⌘Return)"),
            btn("Send to agent…"),
            btn("Send to agent"),
            btn("Open in Outlook"),
            btn("Ask Fred…"),
            btn("Prep with Fred"),
            btn("Refresh picks"),
            btn("Retry"),
            btn("Open in…", cls="NSPopUpButton"),
            btn("Start", cls="NSPopUpButton"),
            btn("Send to agent…", cls="NSPopUpButton"),
            btn("Retry", cls="NSPopUpButton"),
            btn("Go to existing focus"),
            btn("Go to existing job"),
        ]
        for node in cases:
            with self.subTest(node=node):
                self.assertTrue(is_forbidden_button(node))

    def test_the_match_is_case_insensitive_and_ignores_padding_and_ellipsis(self):
        for text in ("START", "  Start  ", "retry…", "Retry...", "ASK FRED…", "Send To Agent…"):
            with self.subTest(text=text):
                self.assertTrue(is_forbidden_button(btn(text)))

    def test_the_accessibility_label_and_tooltip_count_as_well_as_the_title(self):
        self.assertTrue(is_forbidden_button(btn(label="Retry")))
        self.assertTrue(is_forbidden_button(btn("▶", label="Send to agent")))
        self.assertTrue(is_forbidden_button(btn("", tooltip="Refresh picks")))

    def test_navigation_controls_are_allowed(self):
        for node in (btn("Todos 2"), btn("Jira ◌ Loading"), btn("Jira ○ Coming soon"), btn("Picks 3"),
                     btn("Repo docs 4"), btn("All"), btn("Cancel"), btn("Sort: Recent", cls="NSPopUpButton"),
                     btn(label="Filter: Mine"), btn()):
            with self.subTest(node=node):
                self.assertFalse(is_forbidden_button(node))

    def test_a_text_view_whose_text_merely_starts_with_a_forbidden_word_is_allowed(self):
        self.assertFalse(is_forbidden_button(btn("Start the migration", cls="NSTextView")))
        self.assertFalse(is_forbidden_button(btn("Retry the webhook", cls="NSTextField")))

    def test_a_list_row_titled_like_a_forbidden_button_is_allowed(self):
        row = {"class": "WorkRowCellView", "frame": {"x": 0, "y": 0, "w": 500, "h": 56}, "text": "Retry the webhook"}
        self.assertFalse(is_forbidden_button(row))
        self.assertFalse(is_forbidden_button(dict(row, text="Start")))   # not a button class at all

    def test_a_button_that_only_begins_with_the_same_letters_is_allowed(self):
        for text in ("Starting soon", "Restart", "Startup guide", "Retrying later", "Open items", "Choosey"):
            with self.subTest(text=text):
                self.assertFalse(is_forbidden_button(btn(text)), text)


class StubCase(unittest.TestCase):
    """An executable that records its argv as JSON lines and answers `{"ok": true}`."""

    def make_stub(self, body=None):
        d = tempfile.mkdtemp(prefix="qa-appctl-")
        self.addCleanup(__import__("shutil").rmtree, d, True)
        self.log = os.path.join(d, "argv.log")
        stub = os.path.join(d, "stub")
        body = body or 'print(json.dumps({"ok": True}))'
        with open(stub, "w") as f:
            f.write(f"#!{sys.executable}\nimport json, sys\n"
                    f"open({self.log!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n{body}\n")
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
        return stub

    def invocations(self):
        try:
            with open(self.log) as f:
                return [json.loads(line) for line in f]
        except FileNotFoundError:
            return []


class TestKeyAllowList(StubCase):
    def test_only_the_five_documented_chords_may_be_sent(self):
        app = App(self.make_stub())
        for chars, mods in sorted(appctl.ALLOWED_KEYS):
            with self.subTest(chars=chars, mods=mods):
                self.assertEqual(app.key(chars, mods), {"ok": True})
        self.assertEqual(len(self.invocations()), len(appctl.ALLOWED_KEYS))

    def test_modifier_order_does_not_matter(self):
        app = App(self.make_stub())
        app.key("s", ("shift", "cmd"))
        argv = self.invocations()[0]
        self.assertEqual(argv[0], "key")
        self.assertEqual(set(argv[argv.index("--mod") + 1].split(",")), {"cmd", "shift"})

    def test_everything_outside_the_allow_list_is_refused_without_running_the_cli(self):
        refused = [
            ("a", ()), ("A", ("shift",)), ("", ()), ("hello", ()), ("\n", ()), ("\t", ()),
            ("\r", ("cmd",)),            # Cmd-Return CONFIRMS the send
            ("\r", ("shift",)), ("\r", ("cmd", "shift")),
            ("s", ()), ("s", ("cmd",)), ("s", ("shift",)),
            ("z", ()), ("z", ("cmd", "shift")),   # redo
            ("\x1b", ("cmd",)),
            ("w", ("cmd",)), ("q", ("cmd",)), ("v", ("cmd",)), ("c", ("cmd",)), (".", ("cmd",)),
            ("\x7f", ("cmd",)),          # Cmd-Delete
            ("s", ("cmd", "shift", "alt")),
        ]
        app = App(self.make_stub())
        for chars, mods in refused:
            with self.subTest(chars=chars, mods=mods):
                with self.assertRaises(RefusedError):
                    app.key(chars, mods)
        self.assertEqual(self.invocations(), [], "a refused key must never reach the app")

    def test_a_refusal_is_an_app_error_so_callers_that_catch_app_errors_see_it(self):
        self.assertTrue(issubclass(RefusedError, AppError))

    def test_key_code_and_sheet_flag_are_passed_through_for_allowed_keys(self):
        app = App(self.make_stub(), window_args=["-w", "1"])
        app.key("\x1b", key_code=53, sheet=True)
        self.assertEqual(self.invocations()[0], ["-w", "1", "--sheet", "key", "\x1b", "--key-code", "53"])


class TestCommandAllowList(StubCase):
    def test_commands_outside_the_allow_list_are_refused_without_running_the_cli(self):
        app = App(self.make_stub())
        for cmd in ("type", "paste", "drop", "drag", "layout-issues", "ax", "wait", "expect", "bogus", ""):
            with self.subTest(cmd=cmd):
                with self.assertRaises(RefusedError):
                    app._run(cmd, ["hello"])
        self.assertEqual(self.invocations(), [])

    def test_the_allow_list_has_no_text_entry_or_drag_commands(self):
        self.assertFalse({"type", "paste", "drop", "drag"} & set(appctl.ALLOWED_COMMANDS))

    def test_every_allowed_command_reaches_the_cli(self):
        app = App(self.make_stub())
        for cmd in sorted(appctl.ALLOWED_COMMANDS):
            with self.subTest(cmd=cmd):
                self.assertEqual(app._run(cmd), {"ok": True})
        self.assertEqual(len(self.invocations()), len(appctl.ALLOWED_COMMANDS))


class TestClicks(StubCase):
    def test_a_forbidden_button_is_never_clicked(self):
        app = App(self.make_stub())
        for node in (btn("Start"), btn("Send to agent…"), btn("Open in Outlook"), btn("Ask Fred…"),
                     btn("Refresh picks"), btn("Retry"), btn("Open in…", cls="NSPopUpButton")):
            with self.subTest(node=node):
                with self.assertRaises(RefusedError):
                    app.click_node(node)
        self.assertEqual(self.invocations(), [])

    def test_an_allowed_node_is_clicked_at_its_centre(self):
        app = App(self.make_stub())
        app.click_node(btn("Todos 2"))
        self.assertEqual(self.invocations(), [["click", "60.0", "40.0"]])

    def test_clicks_can_target_the_sheet_window(self):
        app = App(self.make_stub(), window_args=["--screen", "LG"])
        app.click_xy(1.5, 2.5, sheet=True)
        self.assertEqual(self.invocations(), [["--screen", "LG", "--sheet", "click", "1.5", "2.5"]])


class TestArgvConstruction(StubCase):
    def test_window_selection_goes_before_the_subcommand_except_for_app_wide_commands(self):
        app = App(self.make_stub(), window_args=["-w", "1"])
        app.ping()
        app.windows()
        app.restore()
        app.tree()
        app.find("Instruction")
        app.hittest(5, 6)
        app.activate()
        app.screenshot("/tmp/x.png")
        self.assertEqual(self.invocations(), [
            ["ping"], ["windows"], ["restore"],
            ["-w", "1", "tree", "--depth", "40"],
            ["-w", "1", "find", "Instruction"],
            ["-w", "1", "hittest", "5", "6"],
            ["-w", "1", "activate"],
            ["-w", "1", "screenshot", "/tmp/x.png"],
        ])

    def test_the_sheet_flag_follows_the_window_selection(self):
        app = App(self.make_stub(), window_args=["-w", "2"])
        app.tree(sheet=True)
        self.assertEqual(self.invocations(), [["-w", "2", "--sheet", "tree", "--depth", "40"]])


class TestFailureHandling(StubCase):
    def test_a_failing_cli_becomes_an_app_error_carrying_its_first_error_line(self):
        app = App(self.make_stub('sys.stderr.write("cannot reach /x/sock: nope\\nmore\\n"); sys.exit(1)'))
        with self.assertRaises(AppError) as cm:
            app.ping()
        self.assertIn("cannot reach /x/sock: nope", str(cm.exception))
        self.assertNotIn("more", str(cm.exception))

    def test_a_reply_that_is_not_json_becomes_an_app_error(self):
        app = App(self.make_stub('print("not json")'))
        with self.assertRaises(AppError):
            app.windows()

    def test_an_empty_reply_is_none(self):
        self.assertIsNone(App(self.make_stub('pass')).restore())

    def test_a_cli_that_does_not_answer_in_time_becomes_an_app_error(self):
        app = App(self.make_stub('import time; time.sleep(5)'))
        with self.assertRaises(AppError) as cm:
            app._run("ping", timeout=0.3)
        self.assertIn("no answer", str(cm.exception))

    def test_a_missing_cli_becomes_an_app_error(self):
        with self.assertRaises(AppError):
            App("/nonexistent/nostromo-app").ping()


if __name__ == "__main__":
    unittest.main()
