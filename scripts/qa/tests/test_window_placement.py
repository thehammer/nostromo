"""Behavioural tests for scripts/qa/window-placement-check.sh (one fullscreen window per display).

The script asks the (fake) app for its windows and reads the window-placement log, whose format is
the one the app writes (docs/diagnostics.md "Window placement log"; AppDelegate.logTopology /
openLaunchWindows / WindowPlacementController): topology and per-display lines first, then
"opening windows for N display(s)", then the `[win → UUID]` lines. The log is READ-ONLY input.
"""
import os
import re
import unittest

import qa_harness as H

U1 = "37D8832A-1111-4A2B-9C3D-0123456789AB"
U2 = "8C0A41F7-2222-4B3C-8D4E-123456789ABC"
BUILTIN = "Built-in Retina Display"
LG = "LG UltraFine"

TWO_WINDOWS = [
    {"screen": BUILTIN, "fullscreen": True, "frame": {"x": 0, "y": 0, "w": 1710, "h": 1073}},
    {"screen": LG, "fullscreen": True, "frame": {"x": 1710, "y": 0, "w": 2560, "h": 1440}},
]


def ts(n):
    return f"2026-10-11T14:03:{22 + n // 10:02d}.{(n % 10) * 100:03d}Z"


def launch_block(displays=2, spaces="true"):
    """The lines a normal launch writes before any window exists."""
    lines = [f"[launch] {displays} display(s); NSScreen.screensHaveSeparateSpaces={spaces}",
             f'[launch] screen#1 uuid={U1} frame=(0,0 1710x1073) visible=(0,0 1710x1049) scale=2.0 name="{BUILTIN}" main=true']
    if displays >= 2:
        lines.append(f'[launch] screen#2 uuid={U2} frame=(1710,0 2560x1440) visible=(1710,0 2560x1415) scale=2.0 name="{LG}" main=false')
    if displays >= 3:
        lines.append('[launch] screen#3 uuid=AAAAAAAA-3333-4444-8555-666666666666 frame=(4270,0 1920x1080) '
                     'visible=(4270,0 1920x1055) scale=1.0 name="Dell U2415" main=false')
    lines.append(f"[launch] opening windows for {displays} display(s)")
    return lines


def window_lines(uuid, name, w, h, on_target=True, fullscreen=True):
    target = "on target" if on_target else "NOT on target"
    other = U2 if uuid == U1 else U1
    screen = uuid if on_target else other
    return [f"[win → {uuid}] created: target=screen#? requested=(0,0 {w}x{h}) → frame=(0,0 {w}x{h}) screen={uuid}",
            f"[win → {uuid}] phase enteringFullScreen → fullScreen",
            f"[win → {uuid}] FINAL ({target}): frame=(0,0 {w}x{h}) screen={screen} ({name}) fullScreen={str(fullscreen).lower()} alpha=1.0"]


def healthy_log(extra_win_lines=(), displays=2, spaces="true"):
    lines = launch_block(displays, spaces)
    lines += window_lines(U1, BUILTIN, 1710, 1073) + window_lines(U2, LG, 2560, 1440)
    lines += list(extra_win_lines)
    return lines


LOG_ENV = {"QA_PLACEMENT_LOG": "@ROOT@/window-placement.log"}
OLD_MTIME_NS = 1_600_000_000_000_000_000   # a recognisable mtime in 2020


def render(lines):
    return "\n".join(f"{ts(i)} {ln}" for i, ln in enumerate(lines)) + "\n"


def write_log(lines):
    """A `preexisting` hook: write the log into the sandbox with a recognisable mtime."""
    def hook(root):
        path = os.path.join(root, "window-placement.log")
        with open(path, "w", encoding="utf-8") as f:
            f.write(render(lines))
        os.utime(path, ns=(OLD_MTIME_NS, OLD_MTIME_NS))
    return hook


class PlacementCase(H.QATestCase):
    def check(self, lines=None, windows=TWO_WINDOWS, scenario=None, log=True):
        sc = {"windows": windows}
        sc.update(scenario or {})
        hook = write_log(lines if lines is not None else healthy_log()) if log else None
        return self.run_script(H.PLACEMENT, sc, env=LOG_ENV, preexisting=hook)

    def assertFailed(self, run, step, pattern=None):
        details = [d for _lv, _st, d in run.of("FAIL", step)]
        self.assertTrue(details, f"expected FAIL {step}; got:\n{run.stdout}{run.stderr}")
        if pattern:
            self.assertTrue(any(re.search(pattern, d, re.I) for d in details), f"{step}: {details}")
        self.assertEqual(run.returncode, 1, run.stdout)


class TestPlacementReporting(PlacementCase):
    def test_a_healthy_two_display_setup_passes(self):
        run = self.check()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.steps("FAIL"), [], run.stdout)
        self.assertEqual(run.steps("WARN"), [], run.stdout)
        self.assertTrue(run.of("PASS", "p.distinct"))
        self.assertEqual(len(run.of("PASS", "p.final")), 2, "one FINAL per window")
        self.assertTrue(run.of("PASS", "p.displays"))

    def test_a_window_that_is_not_fullscreen_fails(self):
        windows = [TWO_WINDOWS[0], dict(TWO_WINDOWS[1], fullscreen=False)]
        run = self.check(windows=windows)
        self.assertFailed(run, "p.window[1]", r"not fullscreen")
        self.assertEqual(run.of("FAIL", "p.window[0]"), [])

    def test_two_windows_on_the_same_display_fail(self):
        windows = [TWO_WINDOWS[0], dict(TWO_WINDOWS[0])]
        run = self.check(windows=windows, lines=launch_block(1) + window_lines(U1, BUILTIN, 1710, 1073))
        self.assertFailed(run, "p.distinct", r"share the display")

    def test_a_final_line_that_is_not_on_target_fails(self):
        lines = launch_block(2) + window_lines(U1, BUILTIN, 1710, 1073) + window_lines(U2, LG, 2560, 1440, on_target=False)
        run = self.check(lines=lines)
        self.assertFailed(run, "p.final", r"NOT on target")

    def test_giving_up_in_the_last_launch_fails(self):
        for phrase in ("retry budget exhausted, giving up (window stays on nil)",
                       "startup retry — gave up waiting for in-flight transitions",
                       "retry exhausted"):
            with self.subTest(phrase):
                run = self.check(lines=healthy_log([f"[win → {U2}] {phrase}"]))
                self.assertFailed(run, "p.gave-up")

    def test_fewer_windows_than_logged_displays_fails(self):
        # 3 displays were attached at launch but only 2 windows exist
        run = self.check(lines=healthy_log(displays=3))
        self.assertFailed(run, "p.displays", r"3 display\(s\) logged but 2 window")

    def test_displays_sharing_one_space_fails_even_though_the_windows_look_fine(self):
        run = self.check(lines=healthy_log(spaces="false"))
        self.assertFailed(run, "p.spaces", r"separate Spaces")

    def test_only_the_last_launch_counts(self):
        old = launch_block(2) + window_lines(U1, BUILTIN, 1710, 1073) + [f"[win → {U1}] retry budget exhausted, giving up"] \
            + window_lines(U2, LG, 2560, 1440, on_target=False)
        run = self.check(lines=old + healthy_log())
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assertEqual(run.steps("FAIL"), [], run.stdout)

    def test_display_names_that_contain_parentheses_are_matched_whole(self):
        # two identical monitors: macOS names the second "LG UltraFine (2)"; the app logs
        # "screen=<uuid> (LG UltraFine (2))" in FINAL lines
        name = "LG UltraFine (2)"
        lines = launch_block(2) + window_lines(U1, BUILTIN, 1710, 1073) + window_lines(U2, name, 2560, 1440)
        lines = [ln.replace(f'name="{LG}"', f'name="{name}"') for ln in lines]
        windows = [TWO_WINDOWS[0], dict(TWO_WINDOWS[1], screen=name)]
        run = self.check(lines=lines, windows=windows)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(run.steps("FAIL"), [], run.stdout)

    def test_no_windows_at_all_fails(self):
        run = self.check(windows=[], log=False)
        self.assertFailed(run, "p.windows", r"no windows")

    def test_final_screens_in_the_log_that_disagree_with_where_the_windows_are_fails(self):
        # the log says the LG window ended on the built-in display, but the app reports it on the LG
        lines = launch_block(2) + window_lines(U1, BUILTIN, 1710, 1073) + window_lines(U2, BUILTIN, 2560, 1440)
        run = self.check(lines=lines)
        self.assertFailed(run, "p.final", r"differ")


class TestPlacementWithoutALog(PlacementCase):
    def test_a_missing_log_is_informational_and_the_window_checks_still_run(self):
        run = self.check(log=False)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("no placement log", run.detail("INFO", "p.log"))
        self.assertTrue(run.of("PASS", "p.distinct"))
        self.assertEqual(run.steps("FAIL"), [])

    def test_a_missing_log_does_not_create_one(self):
        run = self.check(log=False)
        self.assertEqual(os.listdir(run.root).count("window-placement.log"), 0)


class TestPlacementIsReadOnly(PlacementCase):
    def test_the_log_file_is_byte_and_mtime_identical_after_a_run(self):
        # include the lines that make the check shout: a read-only tool must not "fix" the log either
        lines = healthy_log([f"[win → {U2}] WARNING: something odd", f"[win → {U2}] retry exhausted"])
        run = self.check(lines=lines)
        self.assertEqual(run.returncode, 1, "the giving-up line should fail the run")
        path = os.path.join(run.root, "window-placement.log")
        with open(path, encoding="utf-8") as f:
            self.assertEqual(f.read(), render(lines))
        self.assertEqual(os.stat(path).st_mtime_ns, OLD_MTIME_NS)
        self.assertEqual(sorted(os.listdir(run.root)), ["app", "home", "nostromo-app", "scratch", "window-placement.log"])

    def test_only_read_only_app_commands_are_used(self):
        run = self.check()
        self.assertEqual(set(run.commands()), {"ping", "windows"}, "no clicks, keys, activation or focus changes")
        self.assertEqual(run.forbidden, [])

    def test_nothing_is_written_to_home_or_scratch(self):
        run = self.check()
        self.assertEqual(os.listdir(run.home), [])
        self.assertEqual(os.listdir(run.scratch_dir), [])


class TestPlacementUnreachable(PlacementCase):
    def test_an_unreachable_socket_exits_2_and_never_enables_it(self):
        run = self.check(scenario={"ping_fail": True})
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("opt-in", run.stderr)
        self.assertEqual(run.calls, [["ping"]])


if __name__ == "__main__":
    unittest.main()
