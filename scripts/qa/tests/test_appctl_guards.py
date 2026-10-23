"""Unit tests for the read-only guards in scripts/qa/lib/appctl.py.

appctl is the single doorway from the QA scripts to the live app, so its refusals are the safety
net behind "this QA run cannot send anything, start anything or type anything". These tests drive
App against a tiny stub CLI that records its argv: a refusal is only real if the stub was never run.

The contract (an ALLOW-list, verified on the live view hierarchy):
  * every click first asks the app what is under the point (`hittest X Y`, with --sheet for a sheet)
    and only clicks when the answer's `chain` (chain[0] = the hit view, then its superviews) satisfies
    the rule for the declared KIND of click; otherwise RefusedError and the stub's `click` never runs;
  * there is no way to click a bare coordinate, nor to send `click` / `key` through `_run` directly;
  * keys are limited to a handful of chords, each tied to the sheet (or not), and Return is only
    sent after a hit test proves the instruction text view has the keyboard.
"""
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import appctl   # noqa: E402
from appctl import App, AppError, RefusedError   # noqa: E402

FRAME = {"x": 10, "y": 20, "w": 100, "h": 40}   # centre (60, 40)
CENTRE = (60.0, 40.0)


def node(cls="NSButton", text=None, label=None, tooltip=None, frame=FRAME):
    n = {"class": cls, "frame": dict(frame)}
    for k, v in (("text", text), ("label", label), ("tooltip", tooltip)):
        if v is not None:
            n[k] = v
    return n


def view(cls, frame=FRAME, **extra):
    return dict({"class": cls, "frame": dict(frame), "isHidden": False}, **extra)


def moved(frame, dx=0, dy=0):
    return {"x": frame["x"] + dx, "y": frame["y"] + dy, "w": frame["w"], "h": frame["h"]}


def hit(*chain):
    return {"hit": chain[0]["class"] if chain else "none", "chain": list(chain)}


def text_view(frame=FRAME, editable=True, first_responder=True, field_editor=False, cls="NSTextView"):
    return view(cls, frame, isEditable=editable, isFirstResponder=first_responder, isFieldEditor=field_editor,
                isSelectable=True)


class StubCase(unittest.TestCase):
    """An executable that records its argv as JSON lines. `hittest` answers with `hit`; everything else `{"ok": true}`."""

    def make_stub(self, hit_reply=None, body=None):
        """The default stub is a /bin/sh script (a python start-up per call would dominate the suite's run time);
        a custom `body` (python source) is for the failure cases: a non-zero exit, bad JSON, silence, a hang."""
        d = tempfile.mkdtemp(prefix="qa-appctl-")
        self.addCleanup(__import__("shutil").rmtree, d, True)
        self.log = os.path.join(d, "argv.log")
        stub = os.path.join(d, "stub")
        if body is not None:
            body_py = os.path.join(d, "stub.py")
            with open(body_py, "w") as f:
                f.write("import json, sys\n"
                        f"open({self.log!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n{body}\n")
            script = f'#!/bin/sh\nexec "{sys.executable}" -S "{body_py}" "$@"\n'
        else:
            with open(os.path.join(d, "hit.json"), "w") as f:
                json.dump(hit_reply if hit_reply is not None else hit(), f)
            # log: every argument followed by NUL, every invocation closed by \001
            script = ('#!/bin/sh\n'
                      f'printf \'%s\\0\' "$@" >> "{self.log}"; printf \'\\001\' >> "{self.log}"\n'
                      'for a in "$@"; do\n'
                      f'  if [ "$a" = hittest ]; then cat "{os.path.join(d, "hit.json")}"; exit 0; fi\n'
                      'done\n'
                      'echo \'{"ok": true}\'\n')
        with open(stub, "w") as f:
            f.write(script)
        os.chmod(stub, os.stat(stub).st_mode | stat.S_IXUSR)
        return stub

    def app_seeing(self, *chain, **kw):
        """An App whose stub answers every hittest with this chain."""
        return App(self.make_stub(hit(*chain)), **kw)

    def invocations(self):
        try:
            with open(self.log, newline="") as f:
                raw = f.read()
        except FileNotFoundError:
            return []
        if "\x01" in raw:   # the sh stub's format
            return [rec.split("\x00")[:-1] for rec in raw.split("\x01") if rec]
        return [json.loads(line) for line in raw.splitlines() if line]   # the python stub's format

    @staticmethod
    def command(argv):
        i = 0
        while i < len(argv) and argv[i].startswith("-"):
            i += 2 if argv[i] in ("-w", "--window", "--screen") else 1
        return argv[i]

    def commands(self):
        return [self.command(a) for a in self.invocations()]

    def assertNoClickSent(self):
        self.assertNotIn("click", self.commands(), "a refused click must never reach the app")

    def assertClicked(self, x=CENTRE[0], y=CENTRE[1], sheet=False):
        """The log is exactly: hittest at the point, then click at the same point (same flags)."""
        calls = self.invocations()
        self.assertEqual([self.command(a) for a in calls], ["hittest", "click"], calls)
        hit_argv, click_argv = calls
        self.assertEqual(hit_argv[:-3], click_argv[:-3])   # same window selection and --sheet flag
        self.assertEqual([float(v) for v in hit_argv[-2:]], [float(v) for v in click_argv[-2:]])   # same point
        self.assertAlmostEqual(float(click_argv[-2]), x, delta=0.06)
        self.assertAlmostEqual(float(click_argv[-1]), y, delta=0.06)
        self.assertEqual("--sheet" in click_argv, sheet)

    def assertRefused(self, fn, *args, **kw):
        with self.assertRaises(RefusedError):
            fn(*args, **kw)
        self.assertNoClickSent()


# ------------------------------------------------------------------------------ the doorway

class TestNoWayAround(StubCase):
    def test_there_is_no_public_way_to_click_a_bare_coordinate(self):
        self.assertFalse(hasattr(App, "click_xy"))
        self.assertFalse(hasattr(App, "is_forbidden_button") or hasattr(appctl, "is_forbidden_button"))
        self.assertFalse(hasattr(appctl, "FORBIDDEN_BUTTONS"), "the deny-list is replaced by an allow-list")

    def test_click_and_key_cannot_be_sent_through_run_directly(self):
        app = App(self.make_stub())
        for cmd, args in (("click", ["10", "10"]), ("key", ["s", "--mod", "cmd,shift"]), ("key", ["\r"])):
            for sheet in (False, True):
                with self.subTest(cmd=cmd, sheet=sheet):
                    with self.assertRaises(RefusedError):
                        app._run(cmd, args, sheet=sheet)
        self.assertEqual(self.invocations(), [])

    def test_a_refusal_is_an_app_error_so_callers_that_catch_app_errors_see_it(self):
        self.assertTrue(issubclass(RefusedError, AppError))

    def test_the_click_kinds_are_exactly_the_six_the_scenarios_need(self):
        self.assertEqual(set(appctl.CLICK_KINDS),
                         {"sidebar-row", "tab", "list-row", "fred-row", "sheet-toggle", "sheet-text"})

    def test_an_unknown_kind_is_refused(self):
        app = self.app_seeing(view("NSButton"))
        for kind in ("", "button", "any", "start", "Tab", "tabs", None):
            with self.subTest(kind=kind):
                self.assertRefused(app.click_node, node("NSButton", "Todos 2"), kind)
                self.assertRefused(app.click_at, 5, 5, kind)


# ------------------------------------------------------------------------------ hit test first, every time

class TestHitTestBeforeEveryClick(StubCase):
    def test_a_click_is_always_preceded_by_a_hittest_at_the_same_point(self):
        app = self.app_seeing(view("NSButton"))
        app.click_node(node("NSButton", "Todos 2"), "tab")
        self.assertClicked()

    def test_the_window_selection_and_the_sheet_flag_apply_to_both_calls(self):
        app = self.app_seeing(view("NSButton", label="x"), window_args=["--screen", "LG"])
        app.click_node(node("NSButton", label="What will be shared"), "sheet-toggle", sheet=True)
        self.assertClicked(sheet=True)
        self.assertEqual(self.invocations()[0][:3], ["--screen", "LG", "--sheet"])
        self.assertEqual(self.invocations()[1][:3], ["--screen", "LG", "--sheet"])

    def test_click_at_hits_the_given_point_not_the_nodes_centre(self):
        app = self.app_seeing(view("WorkRowCellView"))
        app.click_at(123.4, 56.7, "list-row")
        self.assertClicked(123.4, 56.7)

    def test_a_failing_hittest_means_no_click(self):
        app = App(self.make_stub(body='sys.stderr.write("error: boom\\n"); sys.exit(1)'))
        with self.assertRaises(AppError):
            app.click_at(5, 5, "list-row")
        self.assertNoClickSent()

    def test_an_empty_or_missing_chain_means_no_click(self):
        for reply in ({"hit": "none", "chain": []}, {"hit": "none"}, {}):
            with self.subTest(reply=reply):
                app = App(self.make_stub(reply))
                self.assertRefused(app.click_at, 5, 5, "list-row")


# ------------------------------------------------------------------------------ sidebar-row

class TestSidebarRowClicks(StubCase):
    LABEL = node("NSTextField", "Teri")

    def test_a_label_or_row_inside_a_nav_tab_item_is_clicked(self):
        for chain in ([view("NSTextField"), view("NavTabItem"), view("NSView")],
                      [view("NavTabItem"), view("NSView")]):
            with self.subTest(first=chain[0]["class"]):
                app = self.app_seeing(*chain)
                app.click_node(self.LABEL, "sidebar-row")
                self.assertClicked()

    def test_anything_else_under_the_point_is_refused(self):
        refused = {
            "a button on the row": [view("NSButton"), view("NavTabItem")],
            "a button nested under the label": [view("NSTextField"), view("NSButton"), view("NavTabItem")],
            "a pop-up button above the row": [view("NSTextField"), view("NavTabItem"), view("NSPopUpButton")],
            "a custom button class": [view("NSTextField"), view("NavTabItemCloseButton"), view("NavTabItem")],
            "an image (not a label or the row)": [view("NSImageView"), view("NavTabItem")],
            "not a sidebar row at all": [view("NSTextField"), view("TeriSurfaceView")],
            "nothing": [],
        }
        for what, chain in refused.items():
            with self.subTest(what):
                app = self.app_seeing(*chain)
                self.assertRefused(app.click_node, self.LABEL, "sidebar-row")


# ------------------------------------------------------------------------------ tab

class TestTabClicks(StubCase):
    def button_chain(self, **kw):
        return [view("NSButton", **kw), view("NSStackView")]

    def test_the_default_allowed_tabs_are_todos_jira_and_repo_docs(self):
        for title in ("Todos 2", "Todos", "Jira 12", "Jira ◌ Loading", "Jira ○ Coming soon", "Repo docs 4"):
            with self.subTest(title=title):
                app = self.app_seeing(*self.button_chain())
                app.click_node(node("NSButton", title), "tab")
                self.assertClicked()

    def test_sentry_is_refused_unless_the_app_was_built_with_it_allowed(self):
        sentry = node("NSButton", "Sentry 2")
        self.assertRefused(self.app_seeing(*self.button_chain()).click_node, sentry, "tab")
        app = self.app_seeing(*self.button_chain(), allowed_tabs=("Todos", "Jira", "Repo docs", "Sentry"))
        app.click_node(sentry, "tab")
        self.assertClicked()

    def test_picks_is_never_clickable_even_when_it_is_passed_as_allowed(self):
        picks = node("NSButton", "Picks 3")
        self.assertRefused(self.app_seeing(*self.button_chain()).click_node, picks, "tab")
        app = self.app_seeing(*self.button_chain(), allowed_tabs=("Picks", "Todos", "Jira", "Repo docs", "Sentry"))
        self.assertRefused(app.click_node, picks, "tab")

    def test_allowed_tabs_override_replaces_the_default(self):
        app = self.app_seeing(*self.button_chain(), allowed_tabs=("Jira",))
        self.assertRefused(app.click_node, node("NSButton", "Todos 2"), "tab")

    def test_a_button_that_is_not_a_tab_is_refused(self):
        for title in ("Start", "Send to agent…", "Retry", "Refresh picks", "Open in Outlook", "All", "Cancel", "", None):
            with self.subTest(title=title):
                app = self.app_seeing(*self.button_chain())
                self.assertRefused(app.click_node, node("NSButton", title), "tab")

    def test_a_tab_click_needs_the_node(self):
        app = self.app_seeing(*self.button_chain())
        self.assertRefused(app.click_at, 60, 40, "tab")

    def test_the_view_under_the_point_must_be_that_very_button(self):
        todos = node("NSButton", "Todos 2")
        refused = {
            "an overlay swallows the click": [view("ToastOverlayView"), view("MainLayout")],
            "a text field on top": [view("NSTextField"), view("NSButton"), view("NSStackView")],
            "a pop-up button": [view("NSPopUpButton"), view("NSStackView")],
            "another button elsewhere (3pt off)": [view("NSButton", frame=moved(FRAME, dx=3))],
            "another button elsewhere (3pt off vertically)": [view("NSButton", frame=moved(FRAME, dy=-3))],
            "a different button of another size": [view("NSButton", frame={"x": 10, "y": 20, "w": 90, "h": 40})],
            "nothing": [],
        }
        for what, chain in refused.items():
            with self.subTest(what):
                self.assertRefused(self.app_seeing(*chain).click_node, todos, "tab")

    def test_a_frame_within_two_points_is_the_same_button(self):
        app = self.app_seeing(view("NSButton", frame=moved(FRAME, dx=1.5, dy=-1.0)), view("NSStackView"))
        app.click_node(node("NSButton", "Todos 2"), "tab")
        self.assertClicked()

    def test_the_node_itself_must_be_an_nsbutton(self):
        app = self.app_seeing(*self.button_chain())
        for cls in ("NSTextField", "NSPopUpButton", "NSView"):
            with self.subTest(cls=cls):
                app = self.app_seeing(*self.button_chain())
                self.assertRefused(app.click_node, node(cls, "Todos 2"), "tab")


# ------------------------------------------------------------------------------ list rows

class TestListRowClicks(StubCase):
    def test_a_point_that_is_the_row_or_plain_text_in_it_is_clicked(self):
        for chain in ([view("WorkRowCellView"), view("WorkOutlineView")],
                      [view("NSTextField"), view("WorkRowCellView"), view("WorkOutlineView")]):
            with self.subTest(first=chain[0]["class"]):
                self.app_seeing(*chain).click_node(node("WorkRowCellView"), "list-row")
                self.assertClicked()

    def test_any_button_anywhere_in_the_chain_refuses_the_click(self):
        # the old check looked at the leaf only: a 'sent to ...' marker button under a non-Button leaf slipped by
        refused = {
            "leaf is a button": [view("NSButton"), view("WorkRowCellView")],
            "button nested under an image leaf": [view("NSImageView"), view("NSButton"), view("WorkRowCellView")],
            "pop-up button two levels up": [view("NSTextField"), view("NSView"), view("NSPopUpButton"), view("WorkRowCellView")],
            "custom button class": [view("NSTextField"), view("RowMarkerButton"), view("WorkRowCellView")],
            "a button ABOVE the row in the chain": [view("NSTextField"), view("WorkRowCellView"), view("NSButton")],
        }
        for what, chain in refused.items():
            with self.subTest(what):
                self.assertRefused(self.app_seeing(*chain).click_at, 20, 30, "list-row")

    def test_a_point_that_is_not_in_a_row_is_refused(self):
        for chain in ([view("NSTextField"), view("WorkListView")], [view("NSScrollView")], [view("FredInboxCell")], []):
            with self.subTest(first=chain[0]["class"] if chain else "nothing"):
                self.assertRefused(self.app_seeing(*chain).click_at, 20, 30, "list-row")


class TestFredRowClicks(StubCase):
    def test_inbox_and_today_cells_are_clicked(self):
        for cell in ("FredInboxCell", "FredTodayCell"):
            for chain in ([view(cell)], [view("NSTextField"), view(cell), view("FredPane")]):
                with self.subTest(cell=cell, first=chain[0]["class"]):
                    self.app_seeing(*chain).click_at(20, 30, "fred-row")
                    self.assertClicked(20, 30)

    def test_any_button_anywhere_in_the_chain_refuses_the_click(self):
        refused = {
            "leaf is a button": [view("NSButton"), view("FredInboxCell")],
            "button nested under a label": [view("NSTextField"), view("NSButton"), view("FredTodayCell")],
            "pop-up button above the cell": [view("NSTextField"), view("FredInboxCell"), view("NSPopUpButton")],
        }
        for what, chain in refused.items():
            with self.subTest(what):
                self.assertRefused(self.app_seeing(*chain).click_at, 20, 30, "fred-row")

    def test_a_point_that_is_not_in_a_fred_cell_is_refused(self):
        for chain in ([view("NSTextField"), view("FredPane")], [view("WorkRowCellView")], [view("FredDetailView")]):
            with self.subTest(first=chain[0]["class"]):
                self.assertRefused(self.app_seeing(*chain).click_at, 20, 30, "fred-row")


# ------------------------------------------------------------------------------ sheet

class TestSheetClicks(StubCase):
    TOGGLE = node("NSButton", label="What will be shared")
    INSTR = node("NSTextView", label="Instruction for the agent")

    def test_the_what_will_be_shared_toggle_is_clicked_in_the_sheet(self):
        self.app_seeing(view("NSButton")).click_node(self.TOGGLE, "sheet-toggle", sheet=True)
        self.assertClicked(sheet=True)

    def test_the_toggle_is_refused_when_what_is_under_the_point_is_not_that_button(self):
        start = moved(FRAME, dx=300, dy=140)   # e.g. Start after the layout moved
        refused = {
            "another button at that point (Start)": [view("NSButton", frame=start)],
            "the same button but moved 30pt (stale centre)": [view("NSButton", frame=moved(FRAME, dy=30))],
            "the instruction text view": [text_view()],
            "a label": [view("NSTextField")],
            "empty space": [view("NSView")],
            "nothing": [],
        }
        for what, chain in refused.items():
            with self.subTest(what):
                self.assertRefused(self.app_seeing(*chain).click_node, self.TOGGLE, "sheet-toggle", sheet=True)

    def test_only_the_what_will_be_shared_button_can_be_a_toggle(self):
        for n in (node("NSButton", "Start", tooltip="Start (⌘Return)"), node("NSButton", "Cancel"),
                  node("NSButton", label="Destination"), node("NSButton"), node("NSButton", label="What will be shared with the agent, read only")):
            with self.subTest(node=n):
                self.assertRefused(self.app_seeing(view("NSButton")).click_node, n, "sheet-toggle", sheet=True)

    def test_the_instruction_text_view_is_clicked_only_when_it_is_editable_and_exactly_there(self):
        self.app_seeing(text_view()).click_node(self.INSTR, "sheet-text", sheet=True)
        self.assertClicked(sheet=True)
        self.app_seeing(text_view(first_responder=False)).click_node(self.INSTR, "sheet-text", sheet=True)   # not yet focused: that is why we click
        self.assertClicked(sheet=True)
        self.app_seeing(text_view(cls="InstructionTextView")).click_node(self.INSTR, "sheet-text", sheet=True)
        self.assertClicked(sheet=True)

    def test_the_instruction_click_is_refused_for_anything_else(self):
        refused = {
            "read-only text view": [text_view(editable=False)],
            "a button over it": [view("NSButton", frame=FRAME)],
            "a text field": [view("NSTextField")],
            "the editable view displaced by 30pt": [text_view(frame=moved(FRAME, dy=30))],
            "nothing": [],
        }
        for what, chain in refused.items():
            with self.subTest(what):
                self.assertRefused(self.app_seeing(*chain).click_node, self.INSTR, "sheet-text", sheet=True)

    def test_the_read_only_preview_is_not_an_instruction_view(self):
        preview = node("NSTextView", label="What will be shared with the agent, read only")
        self.assertRefused(self.app_seeing(text_view()).click_node, preview, "sheet-text", sheet=True)

    def test_sheet_kinds_need_the_sheet_and_other_kinds_must_not_have_it(self):
        any_chain = [view("NSButton")]
        self.assertRefused(self.app_seeing(*any_chain).click_node, self.TOGGLE, "sheet-toggle")
        self.assertRefused(self.app_seeing(text_view()).click_node, self.INSTR, "sheet-text")
        for kind, n in (("tab", node("NSButton", "Todos 2")), ("sidebar-row", node("NSTextField", "Teri")),
                        ("list-row", node("WorkRowCellView")), ("fred-row", node("FredInboxCell"))):
            with self.subTest(kind=kind):
                self.assertRefused(self.app_seeing(view("NSButton"), view("NavTabItem"), view("WorkRowCellView"), view("FredInboxCell")).click_node,
                                   n, kind, sheet=True)


# ------------------------------------------------------------------------------ keys

class TestKeys(StubCase):
    def sent(self):
        return [a for a in self.invocations() if self.command(a) == "key"]

    def test_the_documented_chords_are_sent_only_in_their_own_context(self):
        app = self.app_seeing(text_view())
        cases = [
            ("s", ("cmd", "shift"), False, {}),           # open the sheet: not from inside a sheet
            ("\x1b", (), True, {"key_code": 53}),         # Escape: the sheet
            ("z", ("cmd",), True, {"key_code": 6}),       # undo in the sheet
            ("\x7f", (), True, {"key_code": 51}),         # delete in the sheet
            ("\r", (), True, {"key_code": 36, "return_target": (30.0, 40.0)}),
        ]
        for chars, mods, sheet, extra in cases:
            with self.subTest(chars=chars, mods=mods):
                before = len(self.sent())
                self.assertEqual(app.key(chars, mods, sheet=sheet, **extra), {"ok": True})
                self.assertEqual(len(self.sent()), before + 1)

    def test_modifier_order_does_not_matter(self):
        app = App(self.make_stub())
        app.key("s", ("shift", "cmd"))
        argv = self.sent()[0]
        self.assertEqual(argv[0], "key")
        self.assertEqual(set(argv[argv.index("--mod") + 1].split(",")), {"cmd", "shift"})

    def test_sheet_chords_are_refused_without_the_sheet(self):
        app = self.app_seeing(text_view())
        for chars, mods, extra in (("\x1b", (), {}), ("z", ("cmd",), {}), ("\x7f", (), {}),
                                   ("\r", (), {"return_target": (30.0, 40.0)})):
            with self.subTest(chars=chars):
                with self.assertRaises(RefusedError):
                    app.key(chars, mods, sheet=False, **extra)
        self.assertEqual(self.sent(), [])

    def test_the_open_sheet_chord_is_refused_inside_a_sheet(self):
        app = App(self.make_stub())
        with self.assertRaises(RefusedError):
            app.key("s", ("cmd", "shift"), sheet=True)
        self.assertEqual(self.invocations(), [])

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
        app = self.app_seeing(text_view())
        for chars, mods in refused:
            for sheet in (False, True):
                with self.subTest(chars=chars, mods=mods, sheet=sheet):
                    with self.assertRaises(RefusedError):
                        app.key(chars, mods, sheet=sheet, return_target=(30.0, 40.0))
        self.assertEqual(self.sent(), [], "a refused key must never reach the app")

    def test_key_code_and_sheet_flag_are_passed_through_for_allowed_keys(self):
        app = App(self.make_stub(), window_args=["-w", "1"])
        app.key("\x1b", key_code=53, sheet=True)
        self.assertEqual(self.invocations()[0], ["-w", "1", "--sheet", "key", "\x1b", "--key-code", "53"])


class TestReturnNeedsProofTheTextViewHasTheKeyboard(StubCase):
    TARGET = (30.0, 40.0)

    def press(self, *chain, **kw):
        app = self.app_seeing(*chain, **kw)
        return app.key("\r", (), key_code=36, sheet=True, return_target=self.TARGET)

    def test_return_without_a_target_is_refused(self):
        app = self.app_seeing(text_view())
        with self.assertRaises(RefusedError):
            app.key("\r", (), key_code=36, sheet=True)
        self.assertEqual(self.invocations(), [])

    def test_return_is_sent_right_after_a_sheet_hittest_at_the_target(self):
        self.assertEqual(self.press(text_view(), view("NSScrollView")), {"ok": True})
        calls = self.invocations()
        self.assertEqual([self.command(a) for a in calls], ["hittest", "key"], "the proof must come immediately before the key")
        self.assertIn("--sheet", calls[0])
        self.assertEqual([float(v) for v in calls[0][-2:]], list(self.TARGET))
        self.assertIn("--sheet", calls[1])
        self.assertEqual(calls[1][calls[1].index("key") + 1], "\r")

    def test_the_target_hittest_uses_the_window_selection(self):
        self.press(text_view(), window_args=["-w", "2"])
        self.assertEqual(self.invocations()[0][:2], ["-w", "2"])

    def test_return_is_refused_unless_the_hit_view_is_the_editable_focused_text_view(self):
        refused = {
            "a button": [view("NSButton", isFirstResponder=True)],
            "the Start button, focused": [view("NSButton", isFirstResponder=True, isEditable=True)],
            "a text field": [view("NSTextField")],
            "text view without the keyboard": [text_view(first_responder=False)],
            "read-only text view": [text_view(editable=False)],
            "the field editor of a text field": [text_view(field_editor=True)],
            "text view that does not say whether it has the keyboard":
                [view("NSTextView", isEditable=True, isFieldEditor=False)],
            "text view that does not say whether it is editable":
                [view("NSTextView", isFirstResponder=True, isFieldEditor=False)],
            "nothing": [],
        }
        for what, chain in refused.items():
            with self.subTest(what):
                app = self.app_seeing(*chain)
                with self.assertRaises(RefusedError):
                    app.key("\r", (), key_code=36, sheet=True, return_target=self.TARGET)
                self.assertNotIn("key", self.commands(), "Return outside the instruction view would confirm the send")

    def test_a_failing_proof_means_no_return(self):
        app = App(self.make_stub(body='sys.stderr.write("error: boom\\n"); sys.exit(1)'))
        with self.assertRaises(AppError):
            app.key("\r", (), key_code=36, sheet=True, return_target=self.TARGET)
        self.assertNotIn("key", self.commands())


# ------------------------------------------------------------------------------ plumbing that did not change

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

    def test_every_allowed_read_and_focus_command_reaches_the_cli(self):
        app = App(self.make_stub())
        reachable = sorted(set(appctl.ALLOWED_COMMANDS) - {"click", "key"})   # click and key only through the guarded methods
        self.assertTrue({"ping", "windows", "tree", "find", "hittest", "screenshot", "activate", "restore"} <= set(reachable))
        for cmd in reachable:
            with self.subTest(cmd=cmd):
                self.assertIsNotNone(app._run(cmd))
        self.assertEqual(len(self.invocations()), len(reachable))


class TestTrackerCommandsAreAllowedAndReadOnly(StubCase):
    """`tracker` (show|file) and `tracker-anchor` only read the tracker pane, so QA scripts may use them."""

    def test_both_tracker_commands_are_on_the_allow_list(self):
        self.assertIn("tracker", appctl.ALLOWED_COMMANDS)
        self.assertIn("tracker-anchor", appctl.ALLOWED_COMMANDS)

    def test_they_are_not_guarded_like_click_and_key(self):
        self.assertFalse({"tracker", "tracker-anchor"} & appctl._GUARDED_COMMANDS)

    def test_tracker_show_and_file_reach_the_cli_under_the_window_selection(self):
        app = App(self.make_stub(), window_args=["-w", "1"])
        self.assertIsNotNone(app._run("tracker", ["show", "--focus", "kate"]))
        self.assertIsNotNone(app._run("tracker", ["file"]))
        self.assertEqual(self.invocations(), [
            ["-w", "1", "tracker", "show", "--focus", "kate"],
            ["-w", "1", "tracker", "file"],
        ])

    def test_tracker_anchor_reaches_the_cli_under_the_window_selection(self):
        app = App(self.make_stub(), window_args=["-w", "2"])
        self.assertIsNotNone(app._run("tracker-anchor", ["--focus", "kate"]))
        self.assertEqual(self.invocations(), [["-w", "2", "tracker-anchor", "--focus", "kate"]])

    def test_nothing_that_edits_or_acts_on_the_tracker_is_allowed(self):
        edits = {"tracker-edit", "tracker-set", "tracker-add", "tracker-run", "tracker-open-link"}
        self.assertFalse(edits & set(appctl.ALLOWED_COMMANDS))
        app = App(self.make_stub())
        for cmd in sorted(edits):
            with self.subTest(cmd=cmd):
                with self.assertRaises(RefusedError):
                    app._run(cmd, [])
        self.assertEqual(self.invocations(), [])


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
        app = App(self.make_stub(body='sys.stderr.write("cannot reach /x/sock: nope\\nmore\\n"); sys.exit(1)'))
        with self.assertRaises(AppError) as cm:
            app.ping()
        self.assertIn("cannot reach /x/sock: nope", str(cm.exception))
        self.assertNotIn("more", str(cm.exception))

    def test_a_reply_that_is_not_json_becomes_an_app_error(self):
        app = App(self.make_stub(body='print("not json")'))
        with self.assertRaises(AppError):
            app.windows()

    def test_an_empty_reply_is_none(self):
        self.assertIsNone(App(self.make_stub(body='pass')).restore())

    def test_a_cli_that_does_not_answer_in_time_becomes_an_app_error(self):
        app = App(self.make_stub(body='import time; time.sleep(5)'))
        with self.assertRaises(AppError) as cm:
            app._run("ping", timeout=0.3)
        self.assertIn("no answer", str(cm.exception))

    def test_a_missing_cli_becomes_an_app_error(self):
        with self.assertRaises(AppError):
            App("/nonexistent/nostromo-app").ping()


if __name__ == "__main__":
    unittest.main()
