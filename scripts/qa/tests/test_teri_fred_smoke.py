"""Behavioural tests for scripts/qa/teri-fred-smoke.sh, driven against fake_nostromo_app.py.

The smoke is a read-only QA tool for the live app, so the contract has two halves:
  * it must REPORT correctly (a healthy app passes; each kind of breakage produces a FAIL/WARN on
    the right step, and later steps still run), and
  * it must be SAFE (it only ever sends UI-only input, never presses Start / Open in... / Ask Fred /
    Refresh / Retry, never presses Return unless it has proof the text view has the keyboard, hands
    focus back, and never leaves anything outside its own scratch directory).

The fake logs every forbidden action it is asked to perform; every scenario asserts that log is
empty. Scenarios are independent sandboxes and are run concurrently once, in setUpModule.

"Read-only" is literal: the script runs against the user's real app with real data, so it also
  * leaves nothing changed that it can avoid (it reads before it clicks, never selects a row that is
    already selected, never visits Sentry or Picks, never switches to Teri unless told to), and
  * says what it did leave changed (the SUMMARY line's "| left changed: ..." suffix).
The fake records every UI action a click really triggered (actions.log): tests assert on those, not
on coordinates, wherever they can.
"""
import os
import re
import unittest

import qa_harness as H

LONG_TITLE = "".join(f"w{i:03d}-" for i in range(50))[:200]   # 200 chars, no repeated 61-grams
DARK = "#2d2d2d"
BADGES = {"Fred": "3", "Mother": "1", "Perri": "2", "Teri": "4"}
TWO_WINDOWS = [{"screen": "Built-in Retina Display", "focus": "Mother"},
               {"screen": "LG UltraFine", "focus": "Teri"}]
PICKS_CENTRE = (278.0, 34.0)   # centre of the Picks tab button in the fake's layout
JIRA_CENTRE = (542.0, 34.0)
TERI_WIN = [{"screen": "Built-in Retina Display", "focus": "Teri"}]   # Teri is the active focus when the run starts
SKIP_TERI = ("SKIP teri-fred: Teri is not the active focus (switching may start a paid Picks generation; "
             "set QA_ALLOW_TERI_SWITCH=1 to allow it)")
SENTRY_NOT_CLICKED = ("INFO c.sentry: not clicked (visiting it resets the 'new since last viewed' markers; "
                      "set QA_INCLUDE_SENTRY=1 to include)")
NO_FRED = {"inbox": [], "today": []}


# The suite's cost is the NUMBER of fake-app calls (each is a process spawn): a full smoke run is
# ~85 of them. So scenarios only populate as many tabs as they need: "all" for the healthy runs,
# "todos" where a selected item is needed (the Send to agent sheet opens from the first tab with
# rows), "none" everywhere else. Fred-only scenarios drop the Teri row so the run skips the Teri
# half entirely (it then also FAILs b.select-teri and h.teri, which those tests expect).
TABS = ("Todos", "Jira", "Sentry", "Repo docs")


def spec(scenario=None, env=None, rows="none", allow_switch=True):
    """allow_switch: the base environment sets QA_ALLOW_TERI_SWITCH=1 (the fake's default window is on Perri,
    so most scenarios need the switch to reach Teri); scenarios about the default environment turn it off."""
    base = {"badges": BADGES}
    base.update(scenario or {})
    populated = {"all": TABS, "todos": ("Todos",), "none": ()}[rows]
    base["rows"] = {**{t: [] for t in TABS if t not in populated}, **base.get("rows", {})}
    full_env = {"QA_ALLOW_TERI_SWITCH": "1"} if allow_switch else {}
    full_env.update(env or {})
    return {"script": H.SMOKE, "scenario": base, "env": full_env}


NO_TERI = ["Mother", "Perri", "Fred"]
FRED_ONLY_FAILS = {"b.select-teri", "h.teri"}

SPECS = {
    # the app is healthy, and the first item of every list is a 200-character title (privacy)
    "healthy": spec({"rows": {t: [LONG_TITLE, "short"] for t in TABS},
                     "fred": {"inbox": [LONG_TITLE, "b", "c"], "today": [LONG_TITLE, "b"]}}, rows="all"),
    "healthy_picks": spec(env={"QA_INCLUDE_PICKS": "1"}, rows="all"),
    # (b) / (c) tab states
    "broken_tabs": spec({"initial_tab": "Todos",
                         "tabs": {"Jira": "Jira ○ Coming soon", "Sentry": "Sentry ◌ Loading"}},
                        {"QA_LOADING_TIMEOUT": "2", "QA_SLEEP_SCALE": "0.05"}),
    # Sentry is only clicked with the opt-in (the click is what starts the fake's flip) ...
    "sentry_recovers": spec({"tabs": {"Sentry": "Sentry ◌ Loading"},
                             "tab_flip": {"Sentry": {"after_reads": 3, "final": "Sentry 4"}}},
                            {"QA_LOADING_TIMEOUT": "120", "QA_SLEEP_SCALE": "0.05", "QA_INCLUDE_SENTRY": "1"}),
    # ... and without it the loading rules still apply to the title it shows without any click
    "sentry_recovers_unclicked": spec({"tabs": {"Sentry": "Sentry ◌ Loading"},
                                       "tab_flip": {"Sentry": {"after_reads": 3, "final": "Sentry 4", "any_read": True}}},
                                      {"QA_LOADING_TIMEOUT": "120", "QA_SLEEP_SCALE": "0.05"}),
    # (a.daemon) + (c) toolbar observability + (d) both states unreadable, in one run
    "ui_defects": spec({"banners": ["Disconnected from nostromd"], "banner_retry": True,
                        "toolbars": {t: ["All", "Open"] for t in TABS},
                        "colours": {"label": DARK}}),
    # (d) mid-contrast while active, unreadable only while inactive; with a title bar above the content
    "legibility_mixed": spec({"colours": {"label": "#808080", "label_inactive": DARK}, "content": {"title_bar": 28}}),
    # (e) unreachable
    "no_socket": spec({"ping_fail": True}),
    "socket_gone_after_wrapper_check": spec({"ping_fail_after": 1}),
    "app_dies_mid_run": spec({"die_after_calls": 25}),
    # (f) the Send to agent sheet
    "escape_ignored_and_editable_preview": spec({"sheet": {"escape_closes": False, "preview_editable": True}}, rows="todos"),
    "return_not_in_text_view": spec({"sheet": {"click_gives_focus": False}}, rows="todos"),
    "return_closes_sheet": spec({"sheet": {"return_closes": True}}, rows="todos"),
    "seeded_short_and_undo_broken": spec({"sheet": {"seed_text": "Look into PROJ-1", "undo_works": False}}, rows="todos"),
    "seeded_long": spec({"sheet": {"seed_text": "Investigate the failing webhook and propose a fix. " * 6}}, rows="todos"),
    "sheet_already_open": spec({"sheet": {"preopen": True}}, rows="todos"),
    "unexpected_sheet": spec({"sheet": {"title": "Rename focus"}}, rows="todos"),
    # (g) / (h) Fred and the sidebar
    "fred_badge_mismatch": spec({"sidebar": NO_TERI, "fred": {"inbox": ["a", "b", "c", "d"], "inbox_header_count": 4}}),
    "fred_empty": spec({"sidebar": NO_TERI, "fred": {"inbox": [], "today": []}, "badges": {"Mother": "1"}}),
    "fred_signed_out": spec({"sidebar": NO_TERI, "fred": {"signin": True}, "badges": {"Mother": "1"}}),
    "sidebar_missing_rows": spec({"sidebar": ["Mother"], "windows": [{"screen": "Built-in Retina Display", "focus": "Mother"}]}),
    # (j) windows
    "two_windows_default": spec({"windows": TWO_WINDOWS}, rows="todos"),
    "two_windows_lg": spec({"windows": TWO_WINDOWS}, {"QA_SCREEN": "LG"}),
    "two_windows_builtin": spec({"windows": TWO_WINDOWS}, {"QA_SCREEN": "built-in"}),
    "two_windows_unknown_screen": spec({"windows": TWO_WINDOWS}, {"QA_SCREEN": "Sceptre"}),
    # ---- read-only-run scenarios -------------------------------------------------------------
    # B2: the default environment: Perri is the active focus and QA_ALLOW_TERI_SWITCH is not set
    "default_env": spec(allow_switch=False),
    # B2 passive mode: Teri is active and showing Picks / Sentry / a tab nobody can identify (even with the switch allowed)
    "passive_picks": spec({"windows": TERI_WIN, "initial_tab": "Picks"}, rows="all"),
    "passive_sentry": spec({"windows": TERI_WIN, "initial_tab": "Sentry"}, rows="all"),
    "passive_undetectable": spec({"windows": TERI_WIN, "initial_tab": "Jira", "tab_pill": False}, rows="all"),
    # B2: Teri was switched to (QA_ALLOW_TERI_SWITCH=1) and its stored tab turns out to be unsafe to leave
    "switch_to_picks": spec({"initial_tab": "Picks"}, rows="all"),
    "switch_to_sentry": spec({"initial_tab": "Sentry"}, rows="all"),
    "switch_to_undetectable": spec({"tab_pill": False}, rows="all"),
    # B2 full mode without any switch: Teri is active on Jira
    "teri_active_jira": spec({"windows": TERI_WIN}, rows="all", allow_switch=False),
    # B1 opt-in, with Teri active on Sentry (so Sentry is the tab to put back)
    "sentry_optin": spec({"windows": TERI_WIN, "initial_tab": "Sentry"}, {"QA_INCLUDE_SENTRY": "1"}, rows="all", allow_switch=False),
    # 4h: rows that are already selected are not clicked
    "preselected_rows": spec({"windows": TERI_WIN, "preselected": {"Todos": 0, "Jira": 0, "Repo docs": 0},
                              "fred": NO_FRED, "badges": {"Mother": "1"}}, rows="all", allow_switch=False),
    "preselected_jira_only": spec({"windows": TERI_WIN, "preselected": {"Jira": 0}, "fred": NO_FRED,
                                   "badges": {"Mother": "1"}}, rows="all", allow_switch=False),
    "fred_preopen": spec({"sidebar": NO_TERI, "fred_preopen": ["inbox", 0]}),
    # 5: Fred signed out, seen from the sidebar pill (before any click) ...
    "fred_pill_signin": spec({"sidebar": NO_TERI, "fred": {"signin": True}, "badges": {"Mother": "1", "Fred": "Sign in"}}),
    # S1 + hit test before click
    "tab_overlay": spec({"windows": TERI_WIN, "initial_tab": "Todos",
                         "overlays": [{"class": "ToastOverlayView", "frame": {"x": 480, "y": 18, "w": 124, "h": 32}}]},
                        rows="todos", allow_switch=False),
    "row_marker": spec({"windows": TERI_WIN, "row_marker_button": True, "fred": NO_FRED, "badges": {"Mother": "1"}},
                       rows="todos", allow_switch=False),
    "drift_under_nothing": spec({"windows": TERI_WIN, "initial_tab": "Todos", "fred": NO_FRED, "badges": {"Mother": "1"},
                                 "sheet_drift": {"dx": 0, "dy": 400}}, rows="todos", allow_switch=False),
    "drift_onto_start": spec({"windows": TERI_WIN, "initial_tab": "Todos", "fred": NO_FRED, "badges": {"Mother": "1"},
                              "sheet_drift": {"dx": -401, "dy": -145}}, rows="todos", allow_switch=False),
    "drift_after_expand": spec({"windows": TERI_WIN, "initial_tab": "Todos", "fred": NO_FRED, "badges": {"Mother": "1"},
                                "sheet_drift": {"dx": 0, "dy": 30, "after_sheet_clicks": 1}}, rows="todos", allow_switch=False),
    # 4f: what the legibility check measures
    "chevron_hides_invisible_label": spec({"windows": TERI_WIN, "chevron": True, "fred": NO_FRED, "badges": {"Mother": "1"},
                                           "colours": {"label_by_class": {"NSPopUpButton": DARK}}}, allow_switch=False),
    "chevron_hides_invisible_label_text_child": spec(
        {"windows": TERI_WIN, "chevron": True, "popup_label_child": True, "fred": NO_FRED, "badges": {"Mother": "1"},
         "colours": {"label_by_class": {"NSPopUpButton": DARK}}}, allow_switch=False),
    "bezel_and_chevron_with_visible_labels": spec({"windows": TERI_WIN, "bezel": True, "chevron": True, "fred": NO_FRED,
                                                   "badges": {"Mother": "1"}}, allow_switch=False),
}

RUNS = {}


def setUpModule():
    RUNS.update(H.run_all(SPECS))


def tearDownModule():
    H.cleanup()


def clicks(run):
    out = []
    for argv in run.calls:
        if "click" in argv:
            xy = argv[argv.index("click") + 1:]
            out.append((float(xy[0]), float(xy[1])))
    return out


def teri_row_click(run):
    """Clicks that landed on the sidebar's Teri row (x < 200, y within the row at SIDEBAR_TOP + 40 * 2)."""
    return [(x, y) for x, y, sheet in run.clicks() if not sheet and x < 200 and 180 <= y < 216]


class Base(unittest.TestCase):
    def assertNoForbidden(self, run):
        self.assertEqual(run.forbidden, [], "the smoke performed an action a read-only QA run must never perform")

    def assertFailed(self, run, step, pattern=None):
        details = [d for _lv, _st, d in run.of("FAIL", step)]
        self.assertTrue(details, f"expected FAIL {step}; got:\n{run.stdout}")
        if pattern:
            self.assertTrue(any(re.search(pattern, d, re.I) for d in details),
                            f"FAIL {step} should match /{pattern}/: {details}")

    def assertPassed(self, run, step, pattern=None):
        details = [d for _lv, _st, d in run.of("PASS", step)]
        self.assertTrue(details, f"expected PASS {step}; got:\n{run.stdout}")
        if pattern:
            self.assertTrue(any(re.search(pattern, d, re.I) for d in details),
                            f"PASS {step} should match /{pattern}/: {details}")

    def assertNoFail(self, run):
        self.assertEqual(run.steps("FAIL"), [], run.stdout)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def assertNotRun(self, run, *prefixes, levels=("PASS", "FAIL", "WARN")):
        """No PASS/FAIL/WARN line for these steps (an INFO/SKIP line explaining why is fine)."""
        hits = [(lv, st) for lv, st, _ in run.lines if lv in levels and st.startswith(prefixes)]
        self.assertEqual(hits, [], run.stdout)

    def assertLeftChanged(self, run, *needles):
        """The SUMMARY lists an item that mentions every needle (case-insensitive)."""
        items = run.left_changed
        self.assertIsNotNone(items, f"SUMMARY has no '| left changed:' suffix:\n{run.summary_line}")
        self.assertTrue(any(all(n.lower() in i.lower() for n in needles) for i in items),
                        f"expected a left-changed item mentioning {needles}; got {items}")

    def assertNotLeftChanged(self, run, *needles):
        items = run.left_changed or []
        self.assertFalse(any(all(n.lower() in i.lower() for n in needles) for i in items),
                         f"did not expect a left-changed item mentioning {needles}; got {items}")


# ------------------------------------------------------------------------------ (a) healthy

class TestHealthyApp(Base):
    def test_healthy_app_exits_zero_with_no_failures_or_warnings(self):
        run = RUNS["healthy"]
        self.assertNoFail(run)
        self.assertEqual(run.steps("WARN"), [], run.stdout)
        self.assertRegex(run.stdout, r"SUMMARY: \d+ pass, 0 fail, 0 warn")

    def test_every_step_family_a_to_h_is_reported_as_passing(self):
        run = RUNS["healthy"]
        passed = set(run.steps("PASS"))
        # Sentry is not visited by default (that resets its 'new since last viewed' markers): its TAB is
        # checked from its title (c.sentry) but no row is selected there (no e.sentry)
        expected = {"a.ping", "b.select-teri", "a.daemon", "c.todos", "c.jira", "c.sentry", "c.picks", "c.repo-docs",
                    "e.todos", "e.jira", "e.repo-docs", "f.sheet",
                    "d.legibility[active]", "d.legibility[inactive]", "g.inbox", "g.today",
                    "h.fred", "h.mother", "h.perri", "h.teri"}
        self.assertEqual(expected - passed, set(), run.stdout)
        self.assertNotIn("e.sentry", passed)

    def test_picks_is_not_opened_by_default_because_it_can_start_a_paid_generation(self):
        run = RUNS["healthy"]
        info = run.detail("INFO", "c.picks")
        self.assertIn("not clicked", info)
        self.assertNotIn(PICKS_CENTRE, clicks(run))
        self.assertNotIn("Picks", run.state["clicked"])

    def test_picks_is_never_clicked_whatever_the_environment_says(self):
        # QA_INCLUDE_PICKS used to opt in; it no longer exists. The Picks tab is checked from its title only.
        run = RUNS["healthy_picks"]
        self.assertNoFail(run)
        self.assertNotIn(PICKS_CENTRE, clicks(run))
        self.assertNotIn("tab:Picks", run.action_names())
        self.assertNotIn("Picks", run.state["clicked"])
        self.assertIn("not clicked", run.detail("INFO", "c.picks"))
        self.assertPassed(run, "c.picks", r"Picks 3")
        self.assertNoForbidden(run)   # the Refresh picks button sits on that view

    def test_sentry_is_not_clicked_by_default_but_its_tab_is_still_verified(self):
        run = RUNS["healthy"]
        self.assertIn(SENTRY_NOT_CLICKED, run.stdout.splitlines())
        self.assertNotIn("Sentry", run.state["clicked"])
        self.assertNotIn("tab:Sentry", run.action_names())
        self.assertPassed(run, "c.sentry", r"Sentry 2")   # the tab button exists and its title is a count

    def test_only_todos_jira_and_repo_docs_tabs_are_clicked(self):
        run = RUNS["healthy"]
        self.assertEqual(set(run.state["clicked"]), {"Todos", "Jira", "Repo docs"})

    def test_the_summary_counts_skips_and_lists_what_was_left_changed(self):
        run = RUNS["healthy"]
        self.assertRegex(run.summary_line, r"^SUMMARY: \d+ pass, 0 fail, 0 warn, \d+ info, 0 skip \| left changed: ")
        self.assertEqual(run.stdout.splitlines()[-1], run.summary_line, "SUMMARY is the last line")

    def test_it_reports_every_row_it_selected_and_the_fred_row_it_opened_but_not_what_it_put_back(self):
        run = RUNS["healthy"]
        for tab in ("Todos", "Jira", "Repo docs"):
            self.assertLeftChanged(run, tab, "first row selected")
        self.assertLeftChanged(run, "Fred", "Inbox", "first row open in detail")
        self.assertNotLeftChanged(run, "Sentry")
        self.assertNotLeftChanged(run, "Picks")
        self.assertNotLeftChanged(run, "focus")   # the previous focus was put back
        self.assertEqual(run.state["windows"][0]["focus"], "Perri")


    def test_the_users_focus_and_selected_tab_are_put_back(self):
        run = RUNS["healthy"]
        win = run.state["windows"][0]
        self.assertEqual(win["focus"], "Perri")   # the fixture starts on Perri, not Teri
        self.assertEqual(win["tab"], "Jira")      # ... with Jira selected inside Teri
        self.assertFalse(win["sheet"], "the Send to agent sheet must not be left open")
        self.assertIn("put back on Jira", run.detail("INFO", "c.tabs"))
        self.assertIn("put back on Perri", run.detail("INFO", "b.focus"))

    def test_keyboard_focus_is_handed_back_as_the_very_last_call(self):
        run = RUNS["healthy"]
        cmds = run.commands()
        self.assertEqual(cmds[-1], "restore")
        self.assertIn("activate", cmds)
        self.assertFalse(run.state["windows"][0]["key"])

    def test_it_never_performs_a_forbidden_action_or_has_a_click_swallowed(self):
        run = RUNS["healthy"]
        self.assertNoForbidden(run)
        self.assertEqual(run.notes, [], "a click was ignored (window not key / sheet in the way)")

    def test_it_only_sends_the_documented_key_chords(self):
        run = RUNS["healthy"]
        allowed = {("s", "cmd,shift"), ("\r", ""), ("z", "cmd"), ("\x1b", ""), ("\x7f", "")}
        self.assertTrue(set(run.keys()) <= allowed, run.keys())
        self.assertEqual(run.keys().count(("s", "cmd,shift")), 1)

    def test_the_sheet_is_cancelled_with_escape_and_start_is_never_pressed(self):
        run = RUNS["healthy"]
        self.assertPassed(run, "f.sheet", r"Escape closed the sheet; Start was never pressed")
        self.assertPassed(run, "f.sheet", r"plain Return inserted a newline and the sheet stayed open")
        self.assertNoForbidden(run)


# ------------------------------------------------------------------------------ (b) (c) tabs

class TestTabStates(Base):
    # "broken_tabs" has Jira on a 'Coming soon' placeholder AND Sentry stuck on 'Loading'.
    def test_a_coming_soon_tab_fails_but_the_rest_of_the_run_continues(self):
        run = RUNS["broken_tabs"]
        self.assertFailed(run, "c.jira", r"placeholder|coming soon")
        self.assertNotEqual(run.returncode, 0)
        # keep-going: everything after the broken tab still ran and passed
        for step in ("c.todos", "c.repo-docs", "d.legibility[active]", "d.legibility[inactive]", "g.inbox", "g.today", "h.fred"):
            self.assertPassed(run, step)
        self.assertEqual(sorted(set(run.steps("FAIL"))), ["c.jira", "c.sentry"], run.stdout)
        self.assertNoForbidden(run)

    def test_a_coming_soon_tab_is_not_clicked(self):
        run = RUNS["broken_tabs"]
        jira_centre = (216 + 132 * 2 + 62.0, 34.0)
        self.assertNotIn(jira_centre, clicks(run))

    def test_a_tab_stuck_on_loading_fails_and_says_so(self):
        run = RUNS["broken_tabs"]
        self.assertFailed(run, "c.sentry", r"stuck loading")
        self.assertNotEqual(run.returncode, 0)

    def test_a_tab_that_is_loading_at_first_but_settles_to_a_count_passes(self):
        run = RUNS["sentry_recovers"]
        self.assertNoFail(run)
        self.assertPassed(run, "c.sentry", r"Sentry 4")

    # "ui_defects": a Disconnected banner (with a Retry button), identical toolbars on every
    # tab, and unreadable (dark-on-dark) labels, all in one run.
    def test_a_disconnected_banner_fails_a_daemon_and_retry_is_never_pressed(self):
        run = RUNS["ui_defects"]
        self.assertFailed(run, "a.daemon", r"Disconnected")
        self.assertNoForbidden(run)

    def test_identical_toolbars_on_consecutive_tabs_warn_that_selection_is_not_observable(self):
        run = RUNS["ui_defects"]
        self.assertIn("identical to the previous tab", run.detail("WARN", "c.jira"))
        self.assertNotIn("c.jira", run.steps("FAIL"))


# ------------------------------------------------------------------------------ (d) legibility

class TestLegibility(Base):
    def test_dark_on_dark_tab_labels_fail_with_the_measured_contrast(self):
        run = RUNS["ui_defects"]   # labels #2d2d2d on the #1e1e1e surface in both window states
        for state in ("active", "inactive"):
            self.assertFailed(run, f"d.legibility[{state}]", r"contrast \d+\.\d+:1")
        self.assertIn("#2d2d2d", run.detail("FAIL", "d.legibility[active]"))
        self.assertNotEqual(run.returncode, 0)
        self.assertPassed(run, "g.inbox")   # keep-going: Fred was still checked

    # "legibility_mixed": labels #808080 (about 4.2:1) while active, #2d2d2d once the window is
    # inactive, in a window that has a 28pt title bar above the content view.
    def test_labels_that_vanish_only_when_the_window_is_inactive_fail_only_the_inactive_check(self):
        run = RUNS["legibility_mixed"]
        self.assertFailed(run, "d.legibility[inactive]", r"contrast \d+\.\d+:1")
        self.assertEqual(set(run.steps("FAIL")), {"d.legibility[inactive]"}, run.stdout)
        self.assertPassed(run, "d.legibility[active]")
        self.assertNotEqual(run.returncode, 0)

    def test_mid_contrast_labels_warn_but_do_not_fail(self):
        run = RUNS["legibility_mixed"]
        self.assertRegex(run.detail("WARN", "d.legibility[active]"), r"contrast [34]\.\d:1")
        self.assertNotIn("d.legibility[active]", run.steps("FAIL"))


# ------------------------------------------------------------------------------ (e) unreachable

class TestAppControlUnreachable(Base):
    def test_a_missing_socket_exits_2_and_says_the_socket_is_opt_in_and_not_enabled_by_the_script(self):
        run = RUNS["no_socket"]
        self.assertEqual(run.returncode, 2)
        self.assertIn("opt-in", run.stderr)
        self.assertRegex(run.stderr, r"will not turn it on|not (turn|enable)")
        self.assertIn("cannot reach", run.stderr)
        self.assertIn("AppControlEnabled", run.stderr)
        self.assertEqual(run.steps("PASS") + run.steps("FAIL"), [])

    def test_a_missing_socket_means_nothing_was_enabled_clicked_or_typed(self):
        run = RUNS["no_socket"]
        self.assertEqual(run.calls, [["ping"]])
        self.assertNoForbidden(run)

    def test_a_socket_that_vanishes_after_the_first_check_is_reported_and_exits_2(self):
        run = RUNS["socket_gone_after_wrapper_check"]
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertFailed(run, "a.ping", r"not reachable")
        self.assertEqual(run.commands(), ["ping", "ping"], "nothing but pings may be sent")

    def test_an_app_that_dies_mid_run_ends_with_failures_not_a_crash_or_a_hang(self):
        run = RUNS["app_dies_mid_run"]
        self.assertEqual(run.returncode, 1, run.stdout + run.stderr)
        self.assertNotIn("Traceback", run.all_output)
        self.assertTrue(run.of("FAIL"), run.stdout)
        self.assertRegex(run.stdout, r"SUMMARY: \d+ pass, [1-9]\d* fail")
        self.assertNoForbidden(run)


# ------------------------------------------------------------------------------ (f) the sheet

class TestSendToAgentSheetSafety(Base):
    def test_a_sheet_that_ignores_escape_fails_and_the_cleanup_tries_escape_again(self):
        run = RUNS["escape_ignored_and_editable_preview"]
        self.assertFailed(run, "f.sheet", r"still open")
        self.assertNotEqual(run.returncode, 0)
        self.assertGreaterEqual(run.keys().count(("\x1b", "")), 2, "step f and the exit cleanup should each press Escape")
        self.assertTrue(run.of("WARN", "cleanup"), "the user must be told to close the sheet by hand")
        self.assertNoForbidden(run)   # in particular: no Start click

    def test_return_is_never_sent_unless_the_instruction_view_provably_has_the_keyboard(self):
        run = RUNS["return_not_in_text_view"]
        self.assertNotIn(("\r", ""), run.keys())
        self.assertFailed(run, "f.sheet", r"NOT pressing Return|cannot prove")
        self.assertNotEqual(run.returncode, 0)
        self.assertNoForbidden(run)   # the fake flags any Return outside the instruction view
        self.assertFalse(run.state["windows"][0]["sheet"], "the sheet is still cancelled with Escape")

    def test_a_return_that_closes_the_sheet_is_a_failure_that_warns_about_a_possible_send(self):
        run = RUNS["return_closes_sheet"]
        self.assertFailed(run, "f.sheet", r"CLOSED")
        self.assertNotEqual(run.returncode, 0)
        self.assertNoForbidden(run)

    def test_the_newline_check_works_with_a_short_seeded_instruction(self):
        run = RUNS["seeded_short_and_undo_broken"]
        self.assertNoFail(run)
        self.assertPassed(run, "f.sheet", r"inserted a newline")

    def test_the_newline_check_works_when_the_seeded_instruction_is_longer_than_the_160_chars_app_control_reports(self):
        # AppControlServer.text(of:) truncates view text to 160 chars + "…", so before/after look
        # identical to the script for a long seeded instruction (Picks seeds one).
        # The script cannot see the newline then, so it says so rather than claiming it: what it can
        # prove (the sheet stayed open, nothing started) is the PASS.
        run = RUNS["seeded_long"]
        self.assertNoFail(run)
        self.assertPassed(run, "f.sheet", r"left the sheet open")

    def test_a_cmd_z_that_does_nothing_is_undone_with_delete_instead(self):
        run = RUNS["seeded_short_and_undo_broken"]
        self.assertNoFail(run)
        self.assertIn(("\x7f", ""), run.keys())
        self.assertEqual(run.of("WARN", "f.sheet"), [])

    def test_an_editable_shared_context_preview_fails(self):
        run = RUNS["escape_ignored_and_editable_preview"]
        self.assertFailed(run, "f.sheet", r"EDITABLE")
        self.assertNoForbidden(run)

    def test_a_sheet_the_user_already_had_open_is_never_driven_or_cancelled(self):
        # An open sheet blocks every click, so the run stops with a clear FAIL and sends nothing at all.
        run = RUNS["sheet_already_open"]
        self.assertNoForbidden(run)
        self.assertFailed(run, "a.focus", r"already open")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(run.keys(), [], "no key may be sent to a sheet the script did not open")
        self.assertEqual(clicks(run), [])

    def test_an_unexpected_sheet_is_left_completely_alone(self):
        run = RUNS["unexpected_sheet"]
        self.assertFailed(run, "f.sheet", r"unexpected sheet")
        self.assertNotEqual(run.returncode, 0)
        self.assertNotIn(("\x1b", ""), run.keys())
        self.assertNotIn(("\r", ""), run.keys())
        self.assertTrue(run.state["windows"][0]["sheet"])
        self.assertNoForbidden(run)


# ------------------------------------------------------------------------------ (g) (h) Fred

class TestFredAndSidebar(Base):
    # The Fred scenarios have no Teri row, so the run skips the Teri half; the two failures that
    # causes (b.select-teri, h.teri) are expected and are the only ones allowed.
    def assertOnlyTeriMissing(self, run):
        self.assertEqual(set(run.steps("FAIL")), FRED_ONLY_FAILS, run.stdout)

    def test_an_inbox_header_that_disagrees_with_the_sidebar_badge_fails(self):
        run = RUNS["fred_badge_mismatch"]
        self.assertFailed(run, "g.inbox", r"does NOT match")
        self.assertPassed(run, "g.today")
        self.assertNoForbidden(run)

    def test_empty_inbox_and_today_are_deliberate_states_that_pass(self):
        run = RUNS["fred_empty"]
        self.assertOnlyTeriMissing(run)
        self.assertPassed(run, "g.inbox", r"No messages in your Inbox")
        self.assertPassed(run, "g.today", r"No meetings today")
        self.assertNoForbidden(run)

    def test_the_signed_out_state_is_information_not_a_pass_and_nothing_inside_fred_is_clicked(self):
        # the pill shows nothing numeric... here no pill at all; the panes only say "Sign in to Microsoft 365"
        run = RUNS["fred_signed_out"]
        self.assertOnlyTeriMissing(run)
        self.assertNotRun(run, "g.")
        infos = [d for _lv, st, d in run.of("INFO", prefix="g.")]
        self.assertTrue(infos, run.stdout)
        self.assertTrue(any(re.search(r"sign", d, re.I) for d in infos), infos)
        self.assertEqual(run.action_names(), ["focus:Fred", "focus:Perri"], "no row, no button: only the focus was switched and put back")
        self.assertNoForbidden(run)
        self.assertEqual(run.state["windows"][0]["focus"], "Perri")

    def test_a_non_numeric_sidebar_pill_means_the_fred_row_is_not_even_clicked(self):
        run = RUNS["fred_pill_signin"]
        self.assertOnlyTeriMissing(run)
        self.assertTrue(run.of("INFO", "g.fred"), run.stdout)
        self.assertNotRun(run, "g.")
        self.assertEqual(run.action_names(), [], "the Fred row must not be clicked")
        self.assertEqual(run.state["windows"][0]["focus"], "Perri")
        self.assertNotLeftChanged(run, "Fred")

    def test_a_healthy_fred_run_puts_the_focus_back_where_it_was(self):
        run = RUNS["fred_empty"]
        self.assertEqual(run.state["windows"][0]["focus"], "Perri")
        self.assertEqual(run.commands()[-1], "restore")

    # "sidebar_missing_rows": the sidebar has only a Mother row.
    def test_a_missing_sidebar_row_fails_that_rows_badge_step_and_the_rest_still_runs(self):
        run = RUNS["sidebar_missing_rows"]
        self.assertFailed(run, "h.perri", r"no such row")
        self.assertNotEqual(run.returncode, 0)
        self.assertPassed(run, "h.mother")

    def test_a_missing_fred_row_fails_both_the_fred_and_badge_steps(self):
        run = RUNS["sidebar_missing_rows"]
        self.assertFailed(run, "g.fred", r"no 'Fred' row")
        self.assertFailed(run, "h.fred", r"no such row")


# ------------------------------------------------------------------------------ (i) privacy

class TestPrivacy(Base):
    # the "healthy" run's first row of every list (and Fred's first inbox/today row) is a
    # 200-character title standing in for a real Jira/Sentry/mail subject
    def test_a_200_character_item_title_is_never_printed_in_full(self):
        run = RUNS["healthy"]
        self.assertEqual(run.returncode, 0, run.stdout)
        out = run.all_output
        for i in range(len(LONG_TITLE) - 60):
            self.assertNotIn(LONG_TITLE[i:i + 61], out, "61+ consecutive characters of a user title were printed")
        self.assertIn(LONG_TITLE[:40], out, "the fixture title should still appear (truncated) in the report")

    def test_nothing_is_left_in_the_scratch_directory_or_home_after_a_run(self):
        run = RUNS["healthy"]
        self.assertEqual(os.listdir(run.scratch_dir), [], "screenshots (real user data) must be removed on exit")
        self.assertEqual(os.listdir(run.home), [])

    def test_scratch_is_cleaned_even_when_the_run_fails(self):
        run = RUNS["broken_tabs"]
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(os.listdir(run.scratch_dir), [])

    def test_screenshots_are_taken_only_inside_the_scratch_directory(self):
        run = RUNS["healthy"]
        shots = [argv[argv.index("screenshot") + 1] for argv in run.calls if "screenshot" in argv]
        self.assertTrue(shots)
        for p in shots:
            self.assertTrue(p.startswith(os.path.realpath(run.scratch_dir) + os.sep)
                            or p.startswith(run.scratch_dir + os.sep), p)


# ------------------------------------------------------------------------------ (j) windows

def only_window(run, index):
    """Every window-targeted call after discovery used `-w index` (none touched another)."""
    targeted = [a for a in run.calls if any(c in a for c in ("click", "key", "activate", "hittest", "screenshot"))]
    return targeted and all(a[:2] == ["-w", str(index)] for a in targeted)


class TestWindowSelection(Base):
    def test_by_default_the_window_that_shows_teri_is_tested(self):
        run = RUNS["two_windows_default"]
        self.assertNoFail(run)
        self.assertIn("window 1", run.detail("INFO", "a.window"))
        self.assertTrue(only_window(run, 1), run.calls)
        other = run.state["windows"][0]
        self.assertEqual((other["focus"], other["tab"], other["key"], other["fred_row"]), ("Mother", "Jira", False, None))

    def test_qa_screen_selects_the_window_on_that_display(self):
        run = RUNS["two_windows_lg"]
        self.assertNoFail(run)
        self.assertIn("LG UltraFine", run.detail("INFO", "a.window"))
        targeted = [a for a in run.calls if "click" in a or "activate" in a]
        self.assertTrue(targeted and all(a[:2] == ["--screen", "LG"] for a in targeted), targeted)
        self.assertEqual(run.state["windows"][0]["focus"], "Mother")
        self.assertFalse(run.state["windows"][0]["key"])

    def test_qa_screen_is_case_insensitive_and_wins_over_where_teri_is_showing(self):
        run = RUNS["two_windows_builtin"]
        self.assertNoFail(run)
        self.assertIn("Built-in", run.detail("INFO", "a.window"))
        built_in, lg = run.state["windows"]
        self.assertEqual(built_in["focus"], "Mother", "the focus is put back on what it was")
        self.assertEqual((lg["focus"], lg["tab"], lg["row"], lg["fred_row"], lg["key"]), ("Teri", "Jira", None, None, False),
                         "the other display's window must not be touched")

    def test_an_unknown_qa_screen_fails_without_touching_any_window(self):
        run = RUNS["two_windows_unknown_screen"]
        self.assertFailed(run, "a.window", r"no window on a display named like")
        self.assertEqual(run.returncode, 1)
        self.assertEqual(set(run.commands()) - {"ping", "windows"}, set(), run.calls)

# ------------------------------------------------------------------------------ B1 / B2: what it is willing to touch

class TestTeriIsNotSwitchedToByDefault(Base):
    # "default_env": the window is on Perri and QA_ALLOW_TERI_SWITCH is not set. Selecting Teri opens the tab it
    # was last left on; if that is Picks the app may start a paid generation. So the default is: do not go there.
    def test_it_says_why_the_teri_steps_were_skipped(self):
        run = RUNS["default_env"]
        self.assertIn(SKIP_TERI, run.stdout.splitlines())
        self.assertEqual(run.summary[4], 1, run.summary_line)
        self.assertRegex(run.summary_line, r"^SUMMARY: \d+ pass, \d+ fail, \d+ warn, \d+ info, 1 skip \| left changed: ")

    def test_the_teri_sidebar_row_is_never_clicked_and_no_tab_is_touched(self):
        run = RUNS["default_env"]
        self.assertNotIn("focus:Teri", run.action_names())
        self.assertEqual(teri_row_click(run), [])
        self.assertEqual(run.action_names("tab"), [])
        self.assertEqual(run.state["clicked"], {})

    def test_the_teri_steps_do_not_run(self):
        run = RUNS["default_env"]
        self.assertNotRun(run, "b.select-teri", "a.daemon", "c.", "d.", "e.", "f.")
        self.assertEqual(run.keys(), [], "no sheet was opened")

    def test_fred_and_the_badges_are_still_checked_and_the_previous_focus_is_restored(self):
        run = RUNS["default_env"]
        self.assertNoFail(run)
        for step in ("g.inbox", "g.today", "h.fred", "h.mother", "h.perri", "h.teri"):
            self.assertPassed(run, step)
        self.assertEqual(run.state["windows"][0]["focus"], "Perri")
        self.assertEqual(run.commands()[-1], "restore")
        self.assertEqual(run.action_names("focus"), ["focus:Fred", "focus:Perri"])
        self.assertNoForbidden(run)

    def test_only_the_fred_row_it_opened_is_reported_as_left_changed(self):
        run = RUNS["default_env"]
        self.assertLeftChanged(run, "Fred", "Inbox", "first row open in detail")
        self.assertNotLeftChanged(run, "Teri")

    def test_the_window_is_read_before_it_is_activated(self):
        cmds = RUNS["default_env"].commands()   # (a light guard: what is active has to be known before anything is done)
        self.assertLess(cmds.index("tree"), cmds.index("activate"))


class TestPassiveMode(Base):
    # Teri is the active focus and shows Picks, or Sentry (leaving it would reset its markers), or a tab the
    # screenshot cannot identify (it might be either). Not one click, no activate, no focus switch: switching
    # away from Picks and back could start a paid generation.
    PASSIVE = ("passive_picks", "passive_sentry", "passive_undetectable")

    def test_not_a_single_click_key_activate_or_restore_is_sent(self):
        for key in self.PASSIVE:
            with self.subTest(key):
                run = RUNS[key]
                self.assertEqual({"click", "key", "activate", "restore"} & set(run.commands()), set(), run.calls)
                self.assertEqual(run.actions, [])
                self.assertEqual(run.state["clicked"], {})
                win = run.state["windows"][0]
                self.assertEqual(win["focus"], "Teri")
                self.assertFalse(win["key"], "the window was never made key")
                self.assertNoForbidden(run)

    def test_nothing_is_left_changed_and_the_run_passes(self):
        for key in self.PASSIVE:
            with self.subTest(key):
                run = RUNS[key]
                self.assertNoFail(run)
                self.assertEqual(run.left_changed, [], run.summary_line)

    def test_it_explains_itself(self):
        for key in self.PASSIVE:
            with self.subTest(key):
                run = RUNS[key]
                notes = [d for lv, st, d in run.lines if lv in ("INFO", "SKIP") and not st.startswith("c.")
                         and re.search(r"click", d, re.I)
                         and re.search(r"passive|read-only|not click|no click|without click|nothing", d, re.I)]
                self.assertTrue(notes, f"an INFO/SKIP line must say that nothing is clicked in this mode:\n{run.stdout}")

    def test_the_steps_that_need_no_click_still_run(self):
        for key in self.PASSIVE:
            with self.subTest(key):
                run = RUNS[key]
                self.assertPassed(run, "a.daemon")
                for step in ("c.todos", "c.jira", "c.sentry", "c.picks", "c.repo-docs"):
                    self.assertPassed(run, step)
                for step in ("h.fred", "h.mother", "h.perri", "h.teri"):
                    self.assertPassed(run, step)
                self.assertIn(SENTRY_NOT_CLICKED, run.stdout.splitlines())
                self.assertIn("not clicked", run.detail("INFO", "c.picks"))

    def test_the_clicking_steps_and_fred_do_not_run(self):
        for key in self.PASSIVE:
            with self.subTest(key):
                run = RUNS[key]
                self.assertNotRun(run, "d.", "e.", "f.", "g.")
                self.assertNotIn("focus:Fred", run.action_names())


class TestSwitchedToTeriWhoseTabIsNotSafeToLeave(Base):
    # QA_ALLOW_TERI_SWITCH=1 moved the window from Perri to Teri, and the tab Teri opened on is Picks, Sentry, or
    # cannot be told. No tab clicks and no d/e/f; Fred still runs; the previous focus comes back.
    CASES = ("switch_to_picks", "switch_to_sentry", "switch_to_undetectable")

    def test_no_tab_is_clicked_and_no_legibility_row_or_sheet_step_runs(self):
        for key in self.CASES:
            with self.subTest(key):
                run = RUNS[key]
                self.assertEqual(run.state["clicked"], {})
                self.assertEqual(run.action_names("tab"), [])
                self.assertNotRun(run, "d.", "e.", "f.")
                self.assertEqual(run.keys(), [])
                self.assertNoForbidden(run)

    def test_teri_was_switched_to_fred_still_ran_and_the_previous_focus_was_restored(self):
        for key in self.CASES:
            with self.subTest(key):
                run = RUNS[key]
                self.assertNoFail(run)
                self.assertIn("focus:Teri", run.action_names())
                self.assertPassed(run, "g.inbox")
                self.assertPassed(run, "g.today")
                self.assertEqual(run.state["windows"][0]["focus"], "Perri")
                self.assertEqual(run.commands()[-1], "restore")

    def test_the_tab_teri_was_on_is_left_exactly_as_it_was(self):
        for key, tab in (("switch_to_picks", "Picks"), ("switch_to_sentry", "Sentry"), ("switch_to_undetectable", "Jira")):
            with self.subTest(key):
                self.assertEqual(RUNS[key].state["windows"][0]["tab"], tab)
                self.assertNotLeftChanged(RUNS[key], "tab")


class TestFullModeOnTeriThatIsAlreadyActive(Base):
    # "teri_active_jira": Teri is the active focus on Jira, no QA_ALLOW_TERI_SWITCH: no switch is needed to test it
    def test_it_runs_without_a_teri_switch_and_ends_back_on_jira(self):
        run = RUNS["teri_active_jira"]
        self.assertNoFail(run)
        self.assertEqual(run.of("SKIP"), [])
        self.assertEqual(run.summary[4], 0)
        win = run.state["windows"][0]
        self.assertEqual((win["focus"], win["tab"]), ("Teri", "Jira"))
        self.assertTrue(set(run.action_names("focus")) <= {"focus:Fred", "focus:Teri"}, run.action_names("focus"))
        self.assertEqual(run.commands()[-1], "restore")

    def test_only_todos_jira_and_repo_docs_are_clicked_never_sentry_or_picks(self):
        run = RUNS["teri_active_jira"]
        self.assertEqual(set(run.state["clicked"]), {"Todos", "Jira", "Repo docs"})
        self.assertIn(SENTRY_NOT_CLICKED, run.stdout.splitlines())
        self.assertPassed(run, "e.todos")
        self.assertPassed(run, "f.sheet")

    def test_the_fred_pass_switches_away_and_back_to_teri(self):
        run = RUNS["teri_active_jira"]
        self.assertEqual(run.action_names("focus"), ["focus:Fred", "focus:Teri"])


class TestSentryOptIn(Base):
    # "sentry_optin": QA_INCLUDE_SENTRY=1 with Teri active on Sentry
    def test_sentry_is_clicked_like_the_other_tabs_and_checked(self):
        run = RUNS["sentry_optin"]
        self.assertNoFail(run)
        self.assertEqual(set(run.state["clicked"]), {"Todos", "Jira", "Sentry", "Repo docs"})
        self.assertPassed(run, "c.sentry")
        self.assertPassed(run, "e.sentry")
        self.assertNotIn(SENTRY_NOT_CLICKED, run.stdout.splitlines())

    def test_picks_is_still_never_clicked_and_sentry_is_put_back(self):
        run = RUNS["sentry_optin"]
        self.assertNotIn("Picks", run.state["clicked"])
        self.assertEqual(run.state["windows"][0]["tab"], "Sentry")
        self.assertNoForbidden(run)

    def test_the_unclicked_loading_rules_apply_to_the_title_without_the_opt_in(self):
        run = RUNS["sentry_recovers_unclicked"]
        self.assertNoFail(run)
        self.assertNotIn("Sentry", run.state["clicked"])
        self.assertPassed(run, "c.sentry", r"Sentry 4")


class TestOnlyTheTabsItClicksAreEligible(Base):
    def test_a_tab_swallowed_by_an_overlay_is_not_clicked_at_all(self):
        run = RUNS["tab_overlay"]   # a view on top of the Jira tab swallows the point
        self.assertNotIn(JIRA_CENTRE, [(x, y) for x, y, _s in run.clicks()], "no click may be sent at a point another view covers")
        self.assertNotIn("Jira", run.state["clicked"])
        self.assertFailed(run, "c.jira")
        self.assertPassed(run, "c.todos")
        self.assertPassed(run, "c.repo-docs")
        self.assertNotEqual(run.returncode, 0)
        self.assertNoForbidden(run)


# ------------------------------------------------------------------------------ 4h: state left behind

class TestStateLeftBehind(Base):
    def test_a_row_that_is_already_selected_is_not_clicked_and_nothing_is_reported_changed(self):
        run = RUNS["preselected_rows"]   # Todos, Jira and Repo docs each had their first row selected already
        self.assertNoFail(run)
        self.assertEqual(run.action_names("row"), [], "no row may be clicked when the detail already shows an item")
        self.assertEqual(run.left_changed, [])
        self.assertRegex(run.summary_line, r" \| left changed: nothing$")

    def test_the_detail_that_was_already_showing_is_still_verified(self):
        run = RUNS["preselected_rows"]
        for tab in ("todos", "jira", "repo-docs"):
            self.assertPassed(run, f"e.{tab}")

    def test_the_send_to_agent_sheet_still_works_on_an_already_selected_row(self):
        run = RUNS["preselected_rows"]
        self.assertPassed(run, "f.sheet", r"Escape closed the sheet; Start was never pressed")
        self.assertFalse(run.state["windows"][0]["sheet"])
        self.assertNoForbidden(run)

    def test_only_the_tabs_without_a_selection_get_their_first_row_selected_and_reported(self):
        run = RUNS["preselected_jira_only"]
        self.assertNoFail(run)
        row_tabs = {a["tab"] for a in run.actions if a["action"].startswith("row:")}
        self.assertEqual(row_tabs, {"Todos", "Repo docs"})
        self.assertLeftChanged(run, "Todos", "first row selected")
        self.assertLeftChanged(run, "Repo docs", "first row selected")
        self.assertNotLeftChanged(run, "Jira")
        self.assertPassed(run, "e.jira")

    def test_a_fred_detail_that_was_already_open_is_not_reopened(self):
        run = RUNS["fred_preopen"]
        self.assertEqual(run.action_names("fredrow"), [])
        self.assertEqual(run.state["windows"][0]["fred_row"], ["inbox", 0])
        self.assertNotIn("g.inbox", run.steps("FAIL"))
        self.assertNotLeftChanged(run, "Fred")
        self.assertEqual(run.state["windows"][0]["focus"], "Perri")

    def test_opening_fred_rows_is_reported_when_it_was_the_scripts_doing(self):
        run = RUNS["healthy"]
        self.assertTrue(run.action_names("fredrow"))
        self.assertLeftChanged(run, "Fred", "Inbox", "first row open in detail")


# ------------------------------------------------------------------------------ S1 / hit-test-before-click

class TestHitTestBeforeEveryClick(Base):
    def assertEveryClickIsHitTestedFirst(self, run, label):
        calls = run.calls
        for i, argv in enumerate(calls):
            cmd = H.command_of(argv)
            if cmd == "click":
                prev = calls[i - 1] if i else []
                self.assertEqual(H.command_of(prev), "hittest", f"{label}: click #{i} {argv} is not right after a hittest (got {prev})")
                self.assertEqual(prev[:-3], argv[:-3], f"{label}: hittest and click must target the same window / sheet")
                self.assertEqual([float(v) for v in prev[-2:]], [float(v) for v in argv[-2:]],
                                 f"{label}: click at a different point than the hit test")
            if cmd == "key" and argv[argv.index("key") + 1] == "\r":
                prev = calls[i - 1] if i else []
                self.assertEqual(H.command_of(prev), "hittest", f"{label}: Return without a hit test right before it")
                self.assertIn("--sheet", prev)

    def test_every_click_in_every_run_is_preceded_by_a_hit_test_at_the_same_point(self):
        checked = 0
        for key, run in RUNS.items():
            with self.subTest(key):
                self.assertEveryClickIsHitTestedFirst(run, key)
                checked += len(run.clicks())
        self.assertGreater(checked, 100, "the scenarios should have exercised many clicks")
        self.assertGreater(sum(r.keys().count(("\r", "")) for r in RUNS.values()), 0, "and sent Return at least once")


class TestLayoutThatMovesBetweenTheTreeAndTheClick(Base):
    # The sheet's layout changes (the preview toggle, a late relayout) between `tree --sheet` and the click: the
    # centre the script computed from the tree may now be Start, the editable text view, or empty space.
    def assertRefusedAndSafe(self, run, sheet_clicks=0):
        self.assertNoForbidden(run)   # in particular: Start was never clicked
        sent = [(x, y) for x, y, sheet in run.clicks() if sheet]
        self.assertEqual(len(sent), sheet_clicks, f"sheet clicks sent: {sent}")
        self.assertNotIn(("\r", ""), run.keys(), "Return must not be sent when the text view cannot be proven to have the keyboard")
        refusals = [d for lv, st, d in run.lines if st == "f.sheet" and lv in ("FAIL", "WARN")
                    and re.search(r"refus", d, re.I)]
        self.assertTrue(refusals, f"expected a FAIL/WARN on f.sheet saying the click was refused (every RefusedError "
                                  f"message must say 'refus...'):\n{run.stdout}")
        self.assertNotEqual(run.returncode, 0)
        # the sheet is cancelled right away, so the refusal does not cascade: a sheet left open would block every later click
        self.assertEqual(set(run.steps("FAIL")), {"f.sheet"}, run.stdout)
        self.assertPassed(run, "g.inbox")
        self.assertPassed(run, "d.legibility[inactive]")
        self.assertFalse(run.state["windows"][0]["sheet"], "the sheet is cancelled with Escape in the clean-up")
        self.assertIn(("\x1b", ""), run.keys())

    def test_a_stale_centre_that_now_lands_on_nothing_is_refused(self):
        self.assertRefusedAndSafe(RUNS["drift_under_nothing"])

    def test_a_stale_centre_that_now_lands_on_start_is_refused_and_start_is_never_clicked(self):
        self.assertRefusedAndSafe(RUNS["drift_onto_start"])

    def test_when_only_the_collapse_click_is_stale_the_expand_click_was_fine_and_the_collapse_is_refused(self):
        run = RUNS["drift_after_expand"]
        self.assertRefusedAndSafe(run, sheet_clicks=1)
        (x, y), = [(x, y) for x, y, sheet in run.clicks() if sheet]
        self.assertAlmostEqual(x, 29.0, delta=0.5)   # the toggle's centre in the fake's sheet
        self.assertAlmostEqual(y, 229.0, delta=0.5)


class TestRowsCoveredByAButton(Base):
    def test_a_row_whose_centre_is_covered_by_a_button_nested_under_a_non_button_leaf_is_not_clicked(self):
        run = RUNS["row_marker"]
        self.assertNoForbidden(run)   # the fake logs a click on the marker button
        self.assertEqual(run.action_names("row"), [])
        self.assertFailed(run, "e.todos", r"nothing was clicked|button|covered")
        self.assertNotEqual(run.returncode, 0)


# ------------------------------------------------------------------------------ 4f: what legibility measures

class TestLegibilityIgnoresControlChrome(Base):
    # The pop-up's label is invisible (#2d2d2d on #1e1e1e) but its chevron is bright white: measuring the whole control
    # rectangle takes the chevron for the label and passes.
    def test_an_invisible_label_is_a_failure_even_with_a_bright_chevron_at_the_right_end(self):
        run = RUNS["chevron_hides_invisible_label"]
        for state in ("active", "inactive"):
            self.assertFailed(run, f"d.legibility[{state}]", r"NSPopUpButton|Sort")
        self.assertNotEqual(run.returncode, 0)
        self.assertNoForbidden(run)

    def test_only_the_popup_is_blamed(self):
        run = RUNS["chevron_hides_invisible_label"]
        fails = run.of("FAIL", prefix="d.legibility")
        self.assertTrue(fails, run.stdout)
        for _lv, _st, detail in fails:
            self.assertRegex(detail, r"NSPopUpButton|Sort")
            self.assertNotRegex(detail, r"tab '", "the tab buttons have readable labels")

    def test_the_label_frame_is_preferred_when_the_tree_has_a_text_child_under_the_control(self):
        run = RUNS["chevron_hides_invisible_label_text_child"]
        for state in ("active", "inactive"):
            self.assertFailed(run, f"d.legibility[{state}]", r"NSPopUpButton|Sort")

    def test_a_visible_label_inside_a_bright_bezel_with_chevrons_passes_without_warnings(self):
        run = RUNS["bezel_and_chevron_with_visible_labels"]
        self.assertNoFail(run)
        self.assertEqual(run.steps("WARN"), [], run.stdout)
        self.assertPassed(run, "d.legibility[active]")
        self.assertPassed(run, "d.legibility[inactive]")


# ------------------------------------------------------------------------------ cross-cutting, every scenario

class TestEveryRun(Base):
    def test_the_scratch_directory_is_empty_after_every_run_whatever_happened(self):
        for key, run in RUNS.items():
            with self.subTest(key):
                self.assertEqual(os.listdir(run.scratch_dir), [], "screenshots (real user data) must be removed on exit")

    def test_picks_is_never_clicked_in_any_scenario(self):
        for key, run in RUNS.items():
            with self.subTest(key):
                self.assertNotIn("tab:Picks", run.action_names())
                self.assertNotIn("Picks", run.state["clicked"])
                self.assertNotIn(PICKS_CENTRE, clicks(run))

    def test_sentry_is_only_clicked_with_the_explicit_opt_in(self):
        for key, run in RUNS.items():
            with self.subTest(key):
                if key in ("sentry_optin", "sentry_recovers"):
                    continue
                self.assertNotIn("tab:Sentry", run.action_names())

    def test_nothing_forbidden_happens_in_any_scenario(self):
        for key, run in RUNS.items():
            with self.subTest(key):
                self.assertNoForbidden(run)

    def test_every_summary_has_the_five_counters_and_the_smoke_adds_what_it_left_changed(self):
        for key, run in RUNS.items():
            if key in ("no_socket", "socket_gone_after_wrapper_check", "two_windows_unknown_screen"):
                continue   # exits before there is a run to describe
            with self.subTest(key):
                self.assertIsNotNone(run.summary, run.summary_line)
                self.assertIsNotNone(run.left_changed, f"no '| left changed:' suffix: {run.summary_line}")
                self.assertTrue(run.stdout.rstrip().endswith(run.summary_line), "SUMMARY is the last line")


class TestScratchRemovalByThePythonHalf(H.QATestCase):
    # teri-fred-smoke.sh exec()s python, so the wrapper has no EXIT trap any more: python removes QA_TMPDIR itself,
    # but only a directory the wrapper made (nostromo-qa.*), never one it was merely pointed at.
    SMOKE_PY = os.path.join(H.QA_LIB, "smoke.py")

    def run_py(self, dirname):
        def hook(root):
            d = os.path.join(root, "scratch", dirname)
            os.mkdir(d)
            with open(os.path.join(d, "precious.txt"), "w") as f:
                f.write("keep")
        return self.run_script(self.SMOKE_PY, {"ping_fail": True}, env={"QA_TMPDIR": "@ROOT@/scratch/" + dirname},
                               preexisting=hook), os.path.join("scratch", dirname)

    def test_a_directory_made_by_the_wrapper_is_removed_even_when_the_run_ends_early(self):
        run, rel = self.run_py("nostromo-qa.AbC123")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)   # ping failed: the earliest possible exit
        self.assertFalse(os.path.exists(os.path.join(run.root, rel)))

    def test_any_other_directory_is_left_alone(self):
        run, rel = self.run_py("my-precious-dir")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertEqual(os.listdir(os.path.join(run.root, rel)), ["precious.txt"])



if __name__ == "__main__":
    unittest.main()
