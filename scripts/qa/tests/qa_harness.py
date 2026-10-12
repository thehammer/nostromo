"""Shared plumbing for the QA script tests: run a QA shell script against the fake app.

Hermetic by construction: HOME, TMPDIR and the fake's state directory are fresh temp dirs, QA_APP
points at fake_nostromo_app.py, and any QA_* / NOSTROMO_* variable from the caller's shell is
dropped so a developer's own environment cannot change a result.
"""
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
QA_DIR = os.path.dirname(TESTS_DIR)
FAKE = os.path.join(TESTS_DIR, "fake_nostromo_app.py")
FAKE_PROFILER = os.path.join(TESTS_DIR, "fake_system_profiler.py")
QA_LIB = os.path.join(QA_DIR, "lib")
SMOKE = os.path.join(QA_DIR, "teri-fred-smoke.sh")
PLACEMENT = os.path.join(QA_DIR, "window-placement-check.sh")

# git keeps the executable bit, but a checkout through some tools does not.
os.chmod(FAKE, os.stat(FAKE).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

LINE = re.compile(r"^(PASS|FAIL|WARN|INFO|SKIP) ([^:]+): (.*)$")
SUMMARY = re.compile(r"^SUMMARY: (\d+) pass, (\d+) fail, (\d+) warn, (\d+) info, (\d+) skip(?: \| left changed: (.*))?$")


def command_of(argv):
    """The subcommand of one fake-app call (global flags -w N / --screen NAME / --sheet skipped)."""
    i = 0
    while i < len(argv) and argv[i].startswith("-"):
        i += 2 if argv[i] in ("-w", "--window", "--screen") else 1
    return argv[i] if i < len(argv) else ""


class Run:
    """The outcome of one script run plus the fake's records of what was done to it."""

    timed_out = False

    def __init__(self, proc, app_dir, scratch_dir):
        self.returncode = proc.returncode
        self.stdout = proc.stdout
        self.stderr = proc.stderr
        self.app_dir = app_dir
        self.scratch_dir = scratch_dir

    # -- script output
    @property
    def lines(self):
        """[(level, step, detail)] for every PASS/FAIL/WARN/INFO/SKIP line on stdout."""
        out = []
        for raw in self.stdout.splitlines():
            m = LINE.match(raw)
            if m:
                out.append(m.groups())
        return out

    def of(self, level=None, step=None, prefix=None):
        """Report lines filtered by level and by exact step id or step-id prefix."""
        return [(lv, st, d) for lv, st, d in self.lines
                if (level is None or lv == level)
                and (step is None or st == step)
                and (prefix is None or st.startswith(prefix))]

    def steps(self, level):
        return [st for lv, st, _ in self.lines if lv == level]

    def detail(self, level, step):
        return " | ".join(d for lv, st, d in self.lines if lv == level and st == step)

    @property
    def summary_line(self):
        """The last SUMMARY line, or None."""
        found = [ln for ln in self.stdout.splitlines() if ln.startswith("SUMMARY:")]
        return found[-1] if found else None

    @property
    def summary(self):
        """(pass, fail, warn, info, skip) counts from the SUMMARY line, or None when it is malformed."""
        m = SUMMARY.match(self.summary_line or "")
        return tuple(int(g) for g in m.groups()[:5]) if m else None

    @property
    def left_changed(self):
        """None when the SUMMARY line has no ' | left changed: ...' suffix, [] for 'nothing', else the items."""
        m = SUMMARY.match(self.summary_line or "")
        if not m or m.group(6) is None:
            return None
        text = m.group(6).strip()
        return [] if text == "nothing" else [i.strip() for i in text.split(";") if i.strip()]

    @property
    def all_output(self):
        return self.stdout + "\n" + self.stderr

    # -- what the fake saw
    def _read_lines(self, name):
        try:
            with open(os.path.join(self.app_dir, name)) as f:
                return [ln for ln in f.read().splitlines() if ln]
        except FileNotFoundError:
            return []

    @property
    def calls(self):
        return [json.loads(ln) for ln in self._read_lines("calls.log")]

    @property
    def forbidden(self):
        return [json.loads(ln) for ln in self._read_lines("forbidden.log")]

    @property
    def notes(self):
        return self._read_lines("notes.log")

    @property
    def actions(self):
        """What the fake's clicks actually triggered: [{"action": "tab:Jira", "window", "tab", "focus"}]."""
        return [json.loads(ln) for ln in self._read_lines("actions.log")]

    def action_names(self, kind=None):
        return [a["action"] for a in self.actions if kind is None or a["action"].startswith(kind + ":")]

    @property
    def state(self):
        with open(os.path.join(self.app_dir, "state.json")) as f:
            return json.load(f)

    def clicks(self):
        """[(x, y, sheet)] of every `click` call."""
        out = []
        for argv in self.calls:
            if "click" in argv:
                xy = argv[argv.index("click") + 1:]
                out.append((float(xy[0]), float(xy[1]), "--sheet" in argv))
        return out

    def commands(self):
        """The subcommand of every call (global flags skipped), in order."""
        return [command_of(argv) for argv in self.calls]

    def keys(self):
        """[(chars, mods)] for every `key` call."""
        out = []
        for argv in self.calls:
            if "key" not in argv:
                continue
            rest = argv[argv.index("key") + 1:]
            mods = rest[rest.index("--mod") + 1] if "--mod" in rest else ""
            out.append((rest[0], mods))
        return out


_ROOTS = []


def _profiler_spec(profiler):
    """What the fake `system_profiler SPDisplaysDataType -json` prints (see fake_system_profiler.py)."""
    if profiler is None:
        profiler = 2
    if isinstance(profiler, int):
        return {"gpus": [[f"Display {chr(65 + i)}" for i in range(profiler)]]}
    if isinstance(profiler, list):
        return {"gpus": profiler}   # one entry per GPU: a list of display names, or None for a GPU without displays
    return profiler                 # {"exit": 1} / {"raw": "not json"}


def _prepare(script, scenario, env, preexisting, profiler):
    root = tempfile.mkdtemp(prefix="qa-test-")
    _ROOTS.append(root)
    app_dir = os.path.join(root, "app")
    scratch = os.path.join(root, "scratch")
    home = os.path.join(root, "home")
    for d in (app_dir, scratch, home):
        os.mkdir(d)
    with open(os.path.join(app_dir, "scenario.json"), "w") as f:
        json.dump(scenario or {}, f)
    # A hermetic stand-in for `system_profiler`: the placement check counts attached displays with it, and a
    # developer's real displays must never leak into a result. It lives in the app dir (the sandbox root is
    # asserted to hold nothing else). profiler="missing" points QA_SYSTEM_PROFILER at a path that does not exist.
    with open(os.path.join(app_dir, "profiler.json"), "w") as f:
        json.dump(_profiler_spec(profiler), f)
    profiler_bin = os.path.join(app_dir, "system_profiler")
    with open(profiler_bin, "w") as f:
        f.write(f'#!/bin/sh\nexec "{sys.executable}" -S "{FAKE_PROFILER}" "$@"\n')
    os.chmod(profiler_bin, 0o755)
    if preexisting:
        preexisting(root)
    full = {k: v for k, v in os.environ.items()
            if not k.startswith(("QA_", "NOSTROMO_", "FAKE_")) and k not in ("TMPDIR", "HOME")}
    # `python -S` skips site/sitecustomize: ~10 ms less per call, and a full smoke run makes ~85 calls.
    wrapper = os.path.join(root, "nostromo-app")
    with open(wrapper, "w") as f:
        f.write(f'#!/bin/sh\nexec "{sys.executable}" -S "{FAKE}" "$@"\n')
    os.chmod(wrapper, 0o755)
    full.update(HOME=home, TMPDIR=scratch, QA_APP=wrapper, FAKE_APP_DIR=app_dir,
                QA_SYSTEM_PROFILER=(os.path.join(root, "no-such-system-profiler") if profiler == "missing" else profiler_bin),
                QA_SLEEP_SCALE="0", QA_LOADING_TIMEOUT="0")
    for k, v in (env or {}).items():   # @ROOT@ = the sandbox dir; None removes the variable
        if v is None:
            full.pop(k, None)
        else:
            full[k] = v.replace("@ROOT@", root)
    argv = [sys.executable, "-B", "-I", script] if script.endswith(".py") else ["bash", script]
    return root, app_dir, scratch, home, argv, full


def run_script(script, scenario=None, env=None, preexisting=None, args=(), profiler=None):
    """Run a QA script against the fake in a throw-away sandbox (safe to call from threads).

    `script` is a .sh wrapper or, to exercise the python half directly, a lib/*.py file.
    profiler: the number of attached displays the fake system_profiler reports (default 2), a list with one
    list of display names per GPU, {"exit": 1} / {"raw": "..."}, or "missing" (the binary does not exist).
    """
    root, app_dir, scratch, home, argv, full = _prepare(script, scenario, env, preexisting, profiler)
    proc = subprocess.run([*argv, *args], capture_output=True, text=True, timeout=120, env=full, cwd=root)
    run = Run(proc, app_dir, scratch)
    run.root, run.home = root, home
    return run


class Started:
    """A script that is running (Popen) in its own sandbox and process group, for tests that signal it."""

    def __init__(self, proc, root, app_dir, scratch, home):
        self.proc, self.root, self.app_dir, self.scratch, self.home = proc, root, app_dir, scratch, home

    def wait_for_marker(self, name, timeout=60.0):
        """Poll (bounded) for a file the fake writes in its app dir; returns its text, or None."""
        path = os.path.join(self.app_dir, name)
        end = time.time() + timeout
        while time.time() < end:
            if os.path.exists(path):
                with open(path) as f:
                    text = f.read()
                if text:
                    return text
            if self.proc.poll() is not None:
                return None
            time.sleep(0.05)
        return None

    def state(self):
        with open(os.path.join(self.app_dir, "state.json")) as f:
            return json.load(f)

    def send(self, sig):
        os.kill(self.proc.pid, sig)

    def finish(self, timeout=30.0):
        """Wait (bounded) for the script to end and collect its output as a Run."""
        timed_out = False
        try:
            out, err = self.proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            self.kill()
            out, err = self.proc.communicate()
        run = Run(types.SimpleNamespace(returncode=self.proc.returncode, stdout=out, stderr=err), self.app_dir, self.scratch)
        run.root, run.home, run.timed_out = self.root, self.home, timed_out
        return run

    def kill(self):
        """Nothing (script, wrapper, a hanging fake) may outlive the test."""
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        try:
            with open(os.path.join(self.app_dir, "hanging")) as f:
                os.kill(int(f.read().strip()), signal.SIGKILL)
        except (OSError, ValueError):
            pass


def start_script(script, scenario=None, env=None, preexisting=None, args=(), profiler=None):
    """Like run_script but returns at once with a Started handle (the script keeps running)."""
    root, app_dir, scratch, home, argv, full = _prepare(script, scenario, env, preexisting, profiler)
    proc = subprocess.Popen([*argv, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            env=full, cwd=root, start_new_session=True)
    return Started(proc, root, app_dir, scratch, home)


def run_all(specs, workers=8):
    """Run many scenarios concurrently (each is its own sandbox + process tree).

    specs: {key: dict(script=..., scenario=..., env=...)}. Returns {key: Run}. A full smoke run
    makes ~90 fake-app calls (~4 s), so the suite runs its scenarios in parallel to stay fast.
    """
    from concurrent.futures import ThreadPoolExecutor
    workers = max(1, min(workers, os.cpu_count() or 2))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {k: pool.submit(run_script, **spec) for k, spec in specs.items()}
        return {k: f.result() for k, f in futures.items()}


def cleanup():
    while _ROOTS:
        shutil.rmtree(_ROOTS.pop(), ignore_errors=True)


class QATestCase(unittest.TestCase):
    """Base class for tests that run a script themselves (cleanup is automatic)."""

    def run_script(self, script, scenario=None, env=None, **kw):
        run = run_script(script, scenario, env, **kw)
        self.addCleanup(shutil.rmtree, run.root, True)
        return run
