"""Behavioural tests for scripts/qa/teri-fred-smoke.sh, driven against fake_nostromo_app.py.

The smoke is a read-only QA tool for the live app, so the contract has two halves:
  * it must REPORT correctly (a healthy app passes; each kind of breakage produces a FAIL/WARN on
    the right step, and later steps still run), and
  * it must be SAFE (it only ever sends UI-only input, never presses Start / Open in... / Ask Fred /
    Refresh / Retry, never presses Return unless it has proof the text view has the keyboard, hands
    focus back, and never leaves anything outside its own scratch directory).

The fake logs every forbidden action it is asked to perform; every scenario asserts that log is
empty. Scenarios are independent sandboxes and are run concurrently once, in setUpModule.
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


# The suite's cost is the NUMBER of fake-app calls (each is a process spawn): a full smoke run is
# ~85 of them. So scenarios only populate as many tabs as they need: "all" for the healthy runs,
# "todos" where a selected item is needed (the Send to agent sheet opens from the first tab with
# rows), "none" everywhere else. Fred-only scenarios drop the Teri row so the run skips the Teri
# half entirely (it then also FAILs b.select-teri and h.teri, which those tests expect).
TABS = ("Todos", "Jira", "Sentry", "Repo docs")


def spec(scenario=None, env=None, rows="none"):
    base = {"badges": BADGES}
    base.update(scenario or {})
    populated = {"all": TABS, "todos": ("Todos",), "none": ()}[rows]
    base["rows"] = {**{t: [] for t in TABS if t not in populated}, **base.get("rows", {})}
    return {"script": H.SMOKE, "scenario": base, "env": env or {}}


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
    "sentry_recovers": spec({"tabs": {"Sentry": "Sentry ◌ Loading"},
                             "tab_flip": {"Sentry": {"after_reads": 3, "final": "Sentry 4"}}},
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
        expected = {"a.ping", "b.select-teri", "a.daemon", "c.todos", "c.jira", "c.sentry", "c.repo-docs",
                    "e.todos", "e.jira", "e.sentry", "e.repo-docs", "f.sheet",
                    "d.legibility[active]", "d.legibility[inactive]", "g.inbox", "g.today",
                    "h.fred", "h.mother", "h.perri", "h.teri"}
        self.assertEqual(expected - passed, set(), run.stdout)

    def test_picks_is_not_opened_by_default_because_it_can_start_a_paid_generation(self):
        run = RUNS["healthy"]
        info = run.detail("INFO", "c.picks")
        self.assertIn("not clicked", info)
        self.assertNotIn(PICKS_CENTRE, clicks(run))
        self.assertNotIn("Picks", run.state["clicked"])

    def test_picks_is_opened_and_checked_with_include_picks(self):
        run = RUNS["healthy_picks"]
        self.assertNoFail(run)
        self.assertIn(PICKS_CENTRE, clicks(run))
        self.assertPassed(run, "c.picks", r"Picks view renders: 3 row")
        self.assertEqual(run.of("INFO", "c.picks"), [], "Picks was clicked, so it must not report 'not clicked'")
        self.assertNoForbidden(run)   # the Refresh picks button sits on that view

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

    def test_the_signed_out_state_passes(self):
        run = RUNS["fred_signed_out"]
        self.assertOnlyTeriMissing(run)
        self.assertPassed(run, "g.inbox", r"sign-in prompt")
        self.assertPassed(run, "g.today", r"sign-in prompt")

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


if __name__ == "__main__":
    unittest.main()
