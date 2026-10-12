"""Shared plumbing for the QA script tests: run a QA shell script against the fake app.

Hermetic by construction: HOME, TMPDIR and the fake's state directory are fresh temp dirs, QA_APP
points at fake_nostromo_app.py, and any QA_* / NOSTROMO_* variable from the caller's shell is
dropped so a developer's own environment cannot change a result.
"""
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
QA_DIR = os.path.dirname(TESTS_DIR)
FAKE = os.path.join(TESTS_DIR, "fake_nostromo_app.py")
SMOKE = os.path.join(QA_DIR, "teri-fred-smoke.sh")
PLACEMENT = os.path.join(QA_DIR, "window-placement-check.sh")

# git keeps the executable bit, but a checkout through some tools does not.
os.chmod(FAKE, os.stat(FAKE).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

LINE = re.compile(r"^(PASS|FAIL|WARN|INFO) ([^:]+): (.*)$")


class Run:
    """The outcome of one script run plus the fake's records of what was done to it."""

    def __init__(self, proc, app_dir, scratch_dir):
        self.returncode = proc.returncode
        self.stdout = proc.stdout
        self.stderr = proc.stderr
        self.app_dir = app_dir
        self.scratch_dir = scratch_dir

    # -- script output
    @property
    def lines(self):
        """[(level, step, detail)] for every PASS/FAIL/WARN/INFO line on stdout."""
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
    def state(self):
        with open(os.path.join(self.app_dir, "state.json")) as f:
            return json.load(f)

    def commands(self):
        """The subcommand of every call (global flags skipped), in order."""
        out = []
        for argv in self.calls:
            i = 0
            while i < len(argv) and argv[i].startswith("-"):
                i += 2 if argv[i] in ("-w", "--window", "--screen") else 1
            out.append(argv[i] if i < len(argv) else "")
        return out

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


def run_script(script, scenario=None, env=None, preexisting=None, args=()):
    """Run a QA script against the fake in a throw-away sandbox (safe to call from threads)."""
    root = tempfile.mkdtemp(prefix="qa-test-")
    _ROOTS.append(root)
    app_dir = os.path.join(root, "app")
    scratch = os.path.join(root, "scratch")
    home = os.path.join(root, "home")
    for d in (app_dir, scratch, home):
        os.mkdir(d)
    with open(os.path.join(app_dir, "scenario.json"), "w") as f:
        json.dump(scenario or {}, f)
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
                QA_SLEEP_SCALE="0", QA_LOADING_TIMEOUT="0")
    full.update({k: v.replace("@ROOT@", root) for k, v in (env or {}).items()})   # @ROOT@ = the sandbox dir
    proc = subprocess.run(["bash", script, *args], capture_output=True, text=True, timeout=120,
                          env=full, cwd=root)
    run = Run(proc, app_dir, scratch)
    run.root, run.home = root, home
    return run


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
