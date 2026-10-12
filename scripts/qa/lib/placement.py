#!/usr/bin/env python3
"""Window placement check (driven by window-placement-check.sh). READ-ONLY.

Asks the app (`windows`) where each window is, and, when ~/.nostromo/logs/window-placement.log
exists, reads it (never writes it) to compare with the display geometry the app logged at launch
and to summarise each window's final `window.screen`.

Environment: QA_APP, QA_PLACEMENT_LOG (default ~/.nostromo/logs/window-placement.log),
QA_SYSTEM_PROFILER (the read-only `system_profiler` used to count attached displays; default
`system_profiler`, the self-test points it at a fake). Standard library only.
"""
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from appctl import App, AppError   # noqa: E402
from report import Report          # noqa: E402
from uitree import safe            # noqa: E402

TOPOLOGY = re.compile(r"\[[^\]]+\] (\d+) display\(s\); NSScreen\.screensHaveSeparateSpaces=(\w+)")
SCREEN = re.compile(r"\[[^\]]+\] screen#(\d+) uuid=(\S+) frame=\((-?\d+),(-?\d+) (\d+)x(\d+)\).* name=\"([^\"]*)\"")
WIN_SCOPE = re.compile(r"\[win[^\]]*?→\s*([0-9A-Fa-f-]+)\]")
FINAL = re.compile(r"FINAL \((on target|NOT on target)\): frame=\((-?\d+),(-?\d+) (\d+)x(\d+)\) "
                   r"screen=(\S+) \((.*)\) fullScreen=")
HOT_PLUG = re.compile(r"\[screensDidChange\]")
WIN_CREATED = re.compile(r"\[win[^\]]*?→\s*([0-9A-Fa-f-]+)\] created:")
GAVE_UP = re.compile(r"gave up|giving up|retry exhausted", re.I)
# The launch's display-topology line comes first; "opening windows for" is logged after the screen# lines.
LAUNCH_START = re.compile(r"\[launch\] \d+ display\(s\); NSScreen\.screensHaveSeparateSpaces=")
LAUNCH_FALLBACK = re.compile(r"\[launch\] opening windows for")


def check_windows(report, wins):
    if not wins:
        report.fail("p.windows", "the app reports no windows")
        return
    report.info("p.windows", f"{len(wins)} window(s)")
    seen = {}
    for w in wins:
        i, screen, f = w.get("index"), str(w.get("screen", "none")), w.get("frame", {})
        step = f"p.window[{i}]"
        if screen == "none":
            report.fail(step, "window is on no display")
        if w.get("fullscreen"):
            report.passed(step, f"fullscreen on '{safe(screen, 40)}' ({int(f.get('w', 0))}x{int(f.get('h', 0))})")
        else:
            report.fail(step, f"not fullscreen (on '{safe(screen, 40)}', {int(f.get('w', 0))}x{int(f.get('h', 0))})")
        if w.get("visible") is False or float(w.get("alpha", 1)) < 0.99:
            report.warn(step, f"not fully visible (alpha {w.get('alpha')}, visible {w.get('visible')}): display asleep or locked?")
        key = (screen, round(f.get("x", 0)), round(f.get("y", 0)))
        if key in seen:
            report.fail("p.distinct", f"windows {seen[key]} and {i} share the display '{safe(screen, 40)}' at ({key[1]},{key[2]})")
        seen.setdefault(key, i)
    if len(seen) == len(wins):
        report.passed("p.distinct", f"{len(wins)} window(s) on {len(seen)} distinct display(s)")


def attached_displays():
    """How many displays are attached right now, from `system_profiler SPDisplaysDataType -json`
    (read-only), or None when that cannot be found out."""
    binary = os.environ.get("QA_SYSTEM_PROFILER") or "system_profiler"
    try:
        p = subprocess.run([binary, "SPDisplaysDataType", "-json"], capture_output=True, text=True,
                           timeout=20, check=False)
        if p.returncode != 0:
            return None
        gpus = json.loads(p.stdout)["SPDisplaysDataType"]
        return sum(len(g.get("spdisplays_ndrvs") or []) for g in gpus)
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.TimeoutExpired):
        return None


def check_live_displays(report, wins):
    """One window per attached display, counted from the system rather than from the log."""
    n = attached_displays()
    if n is None:
        report.info("p.displays", "cannot count the attached displays (system_profiler unavailable or unreadable)")
    elif n == len(wins):
        report.passed("p.displays", f"{n} display(s) attached, {len(wins)} window(s) open")
    else:
        report.fail("p.displays", f"{n} display(s) attached but {len(wins)} window(s) open")


def log_is_stale(launch, displays):
    """True when the last launch's display topology is older than evidence of a later change: a
    hot-plug line (`[screensDidChange]`) after it, or a window created for a display that is not in it."""
    last_topology = max((i for i, line in enumerate(launch) if TOPOLOGY.search(line)), default=-1)
    if any(HOT_PLUG.search(line) for line in launch[last_topology + 1:]):
        return True
    logged = {d[0].lower() for d in displays}
    created = (m.group(1).lower() for m in map(WIN_CREATED.search, launch) if m)
    return bool(logged) and any(c not in logged for c in created)


def last_launch(lines):
    starts = [i for i, line in enumerate(lines) if LAUNCH_START.search(line)]
    if not starts:
        starts = [i for i, line in enumerate(lines) if LAUNCH_FALLBACK.search(line)]
    return lines[starts[-1]:] if starts else lines


def last_topology(lines):
    """(separate_spaces, [(uuid, x, y, w, h, name)]) from the last display block in `lines`."""
    block, spaces = [], None
    for line in lines:
        m = TOPOLOGY.search(line)
        if m:
            block, spaces = [], m.group(2)
            continue
        s = SCREEN.search(line)
        if s:
            block.append((s.group(2), int(s.group(3)), int(s.group(4)), int(s.group(5)), int(s.group(6)), s.group(7)))
    return spaces, block


def check_log(report, wins, path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        report.warn("p.log", f"cannot read {path}: {safe(e, 80)}")
        return
    launch = last_launch(lines)
    report.info("p.log", f"{len(launch)} line(s) from the last launch in {path}")
    spaces, displays = last_topology(launch)
    if spaces == "false":
        report.fail("p.spaces", "'Displays have separate Spaces' is OFF: windows cannot each get a full-screen Space")
    if displays:
        stale = log_is_stale(launch, displays)
        if len(displays) == len(wins):
            report.passed("p.displays", f"{len(displays)} display(s) logged, {len(wins)} window(s) open")
        elif stale:
            report.info("p.displays", f"{len(displays)} display(s) logged but {len(wins)} window(s) open: the log is older "
                        "than a display hot-plug / window created since, so it is not the evidence; comparing with the attached displays")
            check_live_displays(report, wins)
        else:
            report.fail("p.displays", f"{len(displays)} display(s) logged but {len(wins)} window(s) open")
        for w in wins:
            f = w.get("frame", {})
            match = [d for d in displays if d[5] == w.get("screen") and abs(d[3] - f.get("w", 0)) <= 2 and abs(d[4] - f.get("h", 0)) <= 2]
            if not match and w.get("fullscreen"):
                (report.info if stale else report.fail)(
                    f"p.size[{w.get('index')}]", f"fullscreen frame {int(f.get('w', 0))}x{int(f.get('h', 0))} matches no logged display named '{safe(w.get('screen'), 40)}'"
                    + (" (the log is older than a display change)" if stale else ""))
    else:
        report.info("p.displays", "no display geometry in the last launch's log lines")

    finals, flagged = {}, []
    for line in launch:
        scope = WIN_SCOPE.search(line)
        if GAVE_UP.search(line):
            flagged.append(line)
        if scope:
            m = FINAL.search(line)
            if m:
                finals[scope.group(1)] = m
    for line in flagged[:5]:
        report.fail("p.gave-up", safe(line.split(" ", 1)[-1], 160))
    log_names = []
    for uuid, m in finals.items():
        short = uuid[:8]
        name = m.group(7)
        log_names.append(name)
        if m.group(1) == "on target" and m.group(6) == uuid:
            report.passed("p.final", f"window {short}…: window.screen = '{safe(name, 40)}' ({m.group(4)}x{m.group(5)}), on target")
        elif m.group(1) == "on target":
            report.fail("p.final", f"window {short}…: logged 'on target' but window.screen is {m.group(6)[:8]}…")
        else:
            report.fail("p.final", f"window {short}…: FINAL NOT on target, window.screen = '{safe(name, 40)}'")
    if not finals:
        report.warn("p.final", "no FINAL placement lines in the last launch (windows still settling, or the log was trimmed)")
    elif sorted(log_names) != sorted(str(w.get("screen")) for w in wins):
        report.fail("p.final", f"displays in the log's FINAL lines {sorted(safe(n, 30) for n in log_names)} "
                    f"differ from where the app says its windows are {sorted(safe(str(w.get('screen')), 30) for w in wins)}")
    warns = [ln for ln in launch if "WARNING" in ln or "NOT on target" in ln]
    if warns and not flagged:
        report.warn("p.log", f"{len(warns)} WARNING line(s) in the last launch (e.g. '{safe(warns[0].split(' ', 1)[-1], 100)}')")


def main():
    binary = os.environ.get("QA_APP")
    if not binary:
        sys.exit("placement.py is run by window-placement-check.sh (QA_APP must be set)")
    report = Report()
    app = App(binary)
    try:
        pong = app.ping() or {}
        report.passed("p.ping", f"app-control reachable (pid {pong.get('pid', '?')})")
        wins = app.windows() or []
    except AppError as e:
        report.fail("p.ping", f"app-control not reachable: {safe(e, 120)}")
        report.summary()
        return 2
    check_windows(report, wins)
    path = os.environ.get("QA_PLACEMENT_LOG") or os.path.expanduser("~/.nostromo/logs/window-placement.log")
    if os.path.isfile(path):
        check_log(report, wins, path)
    else:
        report.info("p.log", f"no placement log at {path}: log checks skipped")
        check_live_displays(report, wins)
    return report.summary()


if __name__ == "__main__":
    sys.exit(main())
