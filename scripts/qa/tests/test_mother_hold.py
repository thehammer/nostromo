"""Hermetic self-test of scripts/qa/mother-hold.sh (the PRD's "gate-exhausted hold").

The script drives the real app through `bin/nostromo-app` and a fake Mother broker. Here both are
stand-ins: the REAL bin/fake-mother-broker (scenario crew_hold, in this process, on a socket under
/tmp) and a small fake app-control CLI written to a temp dir (QA_APP points at it). The fake renders,
from the broker's own job table, what the real pane shows for a held job (the option labels with their
consequence text, the guidance field), takes typed text, and plays the app's answer button:

  FAKE_HOLD_GATE=allow    the click is a human gesture (a QA bundle with synthetic input allowed): the fake
                          sends the broker `answer {job, option, source: nostromo_app, text}` once
  FAKE_HOLD_GATE=refuse   the gate refuses the click: the fake sends the broker nothing
  FAKE_HOLD_GATE=double   (a broken app) the click sends the answer twice
  FAKE_HOLD_GATE=wrong    (a broken app) the click sends a different source

Run with:  python3 -m unittest discover -s scripts/qa/tests      (or, from here, python3 -m unittest test_mother_hold)
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import unittest

from qa_harness import QA_DIR, command_of

REPO = os.path.abspath(os.path.join(QA_DIR, "..", ".."))
BROKER = os.path.join(REPO, "bin", "fake-mother-broker")
SCRIPT = os.path.join(QA_DIR, "mother-hold.sh")

_loader = importlib.machinery.SourceFileLoader("fake_mother_broker_for_hold_qa", BROKER)
_spec = importlib.util.spec_from_file_location("fake_mother_broker_for_hold_qa", BROKER, loader=_loader)
fmb = importlib.util.module_from_spec(_spec)
_loader.exec_module(fmb)

FAKE_APP = r'''#!__PYTHON__
import json, os, socket, sys, time, uuid

D, SOCK, GATE = os.environ["FAKE_HOLD_DIR"], os.environ["FAKE_HOLD_SOCK"], os.environ.get("FAKE_HOLD_GATE", "allow")
argv = sys.argv[1:]
with open(os.path.join(D, "calls.log"), "a") as f:
    f.write(json.dumps(argv) + "\n")

args = list(argv)
while args and args[0].startswith("-"):          # global flags come before the subcommand
    args = args[2:] if args[0] == "--screen" else args[1:]
cmd, rest = (args[0] if args else ""), args[1:]


def ctl(op):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(3)
    s.connect(SOCK + ".ctl")
    s.sendall((json.dumps({"op": op}) + "\n").encode())
    r = json.loads(s.makefile().readline())
    s.close()
    return r["result"]


def read(name, default=""):
    try:
        with open(os.path.join(D, name)) as f:
            return f.read()
    except OSError:
        return default


def write(name, text):
    with open(os.path.join(D, name), "w") as f:
        f.write(text)


def send_answer(data):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(SOCK)
    f = s.makefile("rw")
    f.readline()                                  # hello
    f.write(json.dumps({"v": 1, "dir": "cmd", "t": "answer", "id": str(uuid.uuid4()), "ts": "2026-10-18T12:00:00.000Z", "data": data}) + "\n")
    f.flush()
    f.readline()                                  # ack
    s.close()


def screen_text():
    texts = ["Mother"]
    for j in ctl("jobs"):
        texts.append(j["title"])
        d = j.get("decision")
        if j["id"] == read("selected") and j["state"] == "awaiting" and d and not d.get("resolved_at"):
            texts.append("Guidance for the worker")
            for o in d["options"]:
                texts += [o["label"], o["consequence"]]
    return texts


def present(text):
    return any(text in t for t in screen_text())


def flag(name, default=None):
    return rest[rest.index(name) + 1] if name in rest else default


positional = [a for i, a in enumerate(rest) if not a.startswith("--") and (i == 0 or rest[i - 1] != "--timeout")]

if cmd in ("activate", "restore"):
    print("ok: %s" % cmd)
elif cmd == "click":
    text = flag("--text")
    titles = {j["title"]: j["id"] for j in ctl("jobs")}
    if text == "Mother" or text == "Guidance for the worker":
        print("ok: clicked %r" % text)
    elif text in titles:
        write("selected", titles[text])
        print("ok: clicked %r" % text)
    elif text == "Resume with guidance" and present(text):
        want = {"job": read("selected"), "option": "resume_with_guidance", "source": "nostromo_app", "text": read("typed")}
        if GATE in ("allow", "double"):
            send_answer(want)
        if GATE == "double":
            send_answer(want)
        if GATE == "wrong":
            send_answer(dict(want, source="cli"))
        print("ok: clicked %r" % text)
    else:
        print("FAIL: no element with text %r" % text, file=sys.stderr)
        sys.exit(1)
elif cmd == "type":
    write("typed", positional[0])
    print("ok: typed")
elif cmd == "wait":
    text, gone = positional[0], "--gone" in rest
    deadline = time.time() + float(flag("--timeout", "10"))
    while present(text) == gone:
        if time.time() > deadline:
            print("TIMEOUT: %r %s" % (text, "still there" if gone else "not found"))
            sys.exit(1)
        time.sleep(0.05)
    print("ok: %r %s" % (text, "gone" if gone else "found"))
elif cmd == "expect":
    text, absent = positional[0], "--absent" in rest
    if present(text) != absent:
        print("ok: %r" % text)
    else:
        print("FAIL: %r" % text)
        sys.exit(1)
else:
    print("fake app: unknown command %r" % cmd, file=sys.stderr)
    sys.exit(2)
'''

GUIDANCE = "Fix the seed data, then re-run the unit gate."


def _write_executable(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class HoldScriptTest(unittest.TestCase):
    def setUp(self):
        # /tmp, not TMPDIR: unix socket paths are length-limited (SUN_LEN)
        self.dir = tempfile.mkdtemp(prefix="qa-hold-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.sock = os.path.join(self.dir, "b.sock")
        self.broker, self.servers = fmb.serve(self.sock, fmb.SCENARIOS["crew_hold"](), ping_secs=0,
                                              scenario=fmb.SCENARIOS["crew_hold"])
        self.addCleanup(self.stop_broker)
        self.app_dir = os.path.join(self.dir, "app")
        self.home = os.path.join(self.dir, "home")
        self.tmp = os.path.join(self.dir, "tmp")
        for d in (self.app_dir, self.home, self.tmp):
            os.mkdir(d)
        self.app = os.path.join(self.app_dir, "nostromo-app")
        _write_executable(self.app, FAKE_APP.replace("__PYTHON__", sys.executable))

    def stop_broker(self):
        stoppers = [threading.Thread(target=s.shutdown) for s in self.servers]
        for t in stoppers:
            t.start()
        for t in stoppers:
            t.join(timeout=10)
        for s in self.servers:
            s.server_close()

    def run_script(self, gate, expect="allowed", timeout=120):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("QA_", "NOSTROMO_", "FAKE_"))}
        env.update(HOME=self.home, TMPDIR=self.tmp, QA_APP=self.app, QA_FMB_SOCK=self.sock, QA_SETTLE="0",
                   QA_SCREEN="Test", QA_GUIDANCE=GUIDANCE, QA_EXPECT_GATE=expect,
                   FAKE_HOLD_DIR=self.app_dir, FAKE_HOLD_SOCK=self.sock, FAKE_HOLD_GATE=gate)
        return subprocess.run(["bash", SCRIPT], capture_output=True, text=True, env=env, cwd=self.dir, timeout=timeout)

    def ctl(self, op):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        s.connect(self.sock + ".ctl")
        try:
            s.sendall((json.dumps({"op": op}) + "\n").encode())
            return json.loads(s.makefile().readline())["result"]
        finally:
            s.close()

    def calls(self):
        with open(os.path.join(self.app_dir, "calls.log")) as f:
            return [json.loads(line) for line in f if line.strip()]

    def answers(self):
        return [c for c in self.ctl("commands") if c["type"] == "answer"]

    # -- the allowed run ---------------------------------------------------------------------------

    def test_a_human_click_sends_exactly_one_answer_and_the_job_leaves_awaiting(self):
        r = self.run_script("allow")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], "mother-hold (allowed): PASS")

        self.assertEqual([a["data"] for a in self.answers()], [
            {"job": "j-hold1", "option": "resume_with_guidance", "source": "nostromo_app", "text": GUIDANCE}])
        job = next(j for j in self.ctl("jobs") if j["id"] == "j-hold1")
        self.assertEqual(job["state"], "ready")

        calls = self.calls()
        self.assertTrue(all(argv[:2] == ["--screen", "Test"] for argv in calls), calls)
        self.assertEqual(calls[0], ["--screen", "Test", "activate"])
        self.assertEqual(calls[-1], ["--screen", "Test", "restore"])
        # the four options and their consequences were read before the click
        waits = [argv[argv.index("wait") + 1] for argv in calls if command_of(argv) == "wait"]
        for text in ("Resume with guidance", "Escalate", "Open anyway", "Cancel",
                     "Resumes the worker with your written guidance as its next instruction."):
            self.assertIn(text, waits)

    def test_it_fails_when_the_app_sends_the_answer_twice(self):
        r = self.run_script("double")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("PASS", r.stdout + r.stderr)

    def test_it_fails_when_the_answer_does_not_carry_the_apps_source(self):
        r = self.run_script("wrong")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("PASS", r.stdout + r.stderr)

    def test_it_fails_when_the_click_sends_nothing_in_the_allowed_run(self):
        r = self.run_script("refuse", timeout=60)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("PASS", r.stdout + r.stderr)
        self.assertEqual(self.calls()[-1], ["--screen", "Test", "restore"])    # focus is given back even on failure

    # -- the negative run: the live proof that the gate is on --------------------------------------

    def test_a_click_the_gate_refuses_sends_nothing_and_the_refused_run_passes(self):
        r = self.run_script("refuse", expect="refused")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], "mother-hold (refused): PASS")
        self.assertEqual(self.answers(), [])
        self.assertEqual(next(j for j in self.ctl("jobs") if j["id"] == "j-hold1")["state"], "awaiting")

    def test_the_refused_run_fails_when_a_click_got_through(self):
        r = self.run_script("allow", expect="refused")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("the gate is NOT live", r.stdout + r.stderr)
        self.assertNotIn("PASS", r.stdout + r.stderr)

    def test_an_unknown_gate_expectation_is_a_usage_error_that_touches_nothing(self):
        r = self.run_script("allow", expect="sometimes")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.app_dir, "calls.log")))


if __name__ == "__main__":
    unittest.main()
