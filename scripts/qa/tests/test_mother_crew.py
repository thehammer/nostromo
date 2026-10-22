"""Hermetic self-test of scripts/qa/mother-crew.sh.

The script drives the real app through `bin/nostromo-app` and a fake Mother broker. Here both are
real stand-ins: the REAL bin/fake-mother-broker (scenario crew_gates, in this process, on a socket
under /tmp) and a small fake app-control CLI written to a temp dir (QA_APP points at it). The fake
renders, from the broker's own job table, the accessibility strings the real panel would expose, so
the script's waits see what a VoiceOver user would hear, and nothing is on screen unless the script
asked for it (a job's detail is only drawn after `click --text <that job's title>`).

The replay-dependent assertions live in ONE script run (the script's replays take real time: about
8.5 s at speed 1 and 2 s at speed 2). The negative cases use a fake that answers at once and run in
about a second each.

Run with:  python3 -m unittest discover -s scripts/qa/tests      (or, from here, python3 -m unittest test_mother_crew)
"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

from qa_harness import QA_DIR, command_of

REPO = os.path.abspath(os.path.join(QA_DIR, "..", ".."))
BROKER = os.path.join(REPO, "bin", "fake-mother-broker")
SCRIPT = os.path.join(QA_DIR, "mother-crew.sh")

_loader = importlib.machinery.SourceFileLoader("fake_mother_broker_for_crew_qa", BROKER)
_spec = importlib.util.spec_from_file_location("fake_mother_broker_for_crew_qa", BROKER, loader=_loader)
fmb = importlib.util.module_from_spec(_spec)
_loader.exec_module(fmb)

# The fake app-control CLI. One process per call, state in files under $FAKE_CREW_DIR.
#   FAKE_CREW_MODE=normal         waits poll the rendered screen; the real thing
#   FAKE_CREW_MODE=wait_timeout   every `wait` times out at once
#   FAKE_CREW_MODE=lenient        wait / expect / click succeed at once (to reach the end of the script)
#                                 FAKE_CREW_LAYOUT picks what `layout-issues` reports there
FAKE_APP = r'''#!__PYTHON__
import json, os, socket, sys, time

D, SOCK, MODE = os.environ["FAKE_CREW_DIR"], os.environ["FAKE_CREW_SOCK"], os.environ.get("FAKE_CREW_MODE", "normal")
argv = sys.argv[1:]
with open(os.path.join(D, "calls.log"), "a") as f:
    f.write(json.dumps(argv) + "\n")

args = list(argv)
screen = None
while args and args[0].startswith("-"):          # global flags come before the subcommand
    if args[0] == "--screen":
        screen, args = args[1], args[2:]
    else:
        args = args[1:]
cmd, rest = (args[0] if args else ""), args[1:]


def out(text):
    print(text, flush=True)


def jobs():
    """The broker's job table, asked over its control socket (None when it cannot be read right now)."""
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        s.connect(SOCK + ".ctl")
        s.sendall(b'{"op":"jobs"}\n')
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            buf += chunk
        s.close()
        r = json.loads(buf)
        return r["result"] if r.get("ok") else None
    except Exception:
        return None


def selected():
    try:
        with open(os.path.join(D, "selected")) as f:
            return f.read()
    except OSError:
        return ""


def progress_line(j):
    """The spoken form of a job's progress."""
    p = j.get("progress")
    if not p:
        return None
    line = "About %s percent." % p["pct"]
    gates = (p.get("signals") or {}).get("gates")
    if gates:
        line += " %s of %s gates passed." % (gates["passed"], gates["total"])
    eta = p.get("eta") or {}
    if eta.get("label"):
        line += " Estimated %s." % eta["label"]
    return line


def gate_rows(j):
    g = j.get("gates")
    if not g:
        return []
    rows = ["Gates, attempt %s of %s, %s" % (g["attempt"], g["max_attempts"], g["status"])]
    for r in g.get("results") or []:
        row = "%s: %s, took %s seconds" % (r["name"], r["result"], r["duration_s"])
        if r["result"] == "failed":
            row += ", exit code %s" % r["exit_code"]
        row += ", blocking" if r.get("blocking") else ", advisory"
        rows.append(row + ", attempt %s of %s" % (g["attempt"], g["max_attempts"]))
    return rows


def lens_rows(j):
    w = j.get("review_wave")
    if not w:
        return []
    rows = []
    for lens in w.get("lenses") or []:
        row = "%s: %s" % (lens["reviewer"], lens["state"])
        if lens["state"] == "skipped":
            row += ", not in scope" if lens.get("skip_reason") == "path_scope" else ", %s" % lens.get("skip_reason")
        elif lens["state"] == "done":
            row += ", %s blocking, %s advisory" % (lens["findings"]["blocking"], lens["findings"]["advisory"])
        rows.append(row)
    c = w.get("claims")
    if c:
        rows.append("Citations found %s, not found %s, unverified %s" % (c["verified"], c["refuted"], c["unverified"]))
    return rows


def screen_text():
    """Every accessibility string currently on screen: the queue, and the selected job's detail."""
    texts = ["Mother"]
    for j in jobs() or []:
        texts.append(j["title"])
        line = progress_line(j)
        if line:
            texts.append(line)
        if j["id"] == selected():
            texts += gate_rows(j) + lens_rows(j)
    return texts


def present(text):
    return any(text in t for t in screen_text())


def flag(name, default=None):
    return rest[rest.index(name) + 1] if name in rest else default


positional = [a for i, a in enumerate(rest) if not a.startswith("--") and (i == 0 or rest[i - 1] != "--timeout")]
lenient = MODE == "lenient"

if cmd in ("activate", "restore"):
    out("ok: %s" % cmd)
elif cmd == "click":
    text = flag("--text")
    titles = {j["title"]: j["id"] for j in jobs() or []}
    if lenient or text == "Mother":
        out("ok: clicked %r" % text)
    elif text in titles:
        with open(os.path.join(D, "selected"), "w") as f:
            f.write(titles[text])
        out("ok: clicked %r" % text)
    else:
        print("FAIL: no element with text %r" % text, file=sys.stderr)
        sys.exit(1)
elif cmd == "wait":
    text, gone = positional[0], "--gone" in rest
    if MODE == "wait_timeout":
        out("TIMEOUT: %r" % text)
        sys.exit(1)
    deadline = time.time() + float(flag("--timeout", "10"))
    while not lenient:
        if present(text) != gone:
            break
        if time.time() > deadline:
            out("TIMEOUT: %r %s after %ss" % (text, "still there" if gone else "not found", flag("--timeout", "10")))
            sys.exit(1)
        time.sleep(0.05)
    out("ok: %r %s" % (text, "gone" if gone else "found"))
elif cmd == "expect":
    text, absent = positional[0], "--absent" in rest
    if lenient or present(text) != absent:
        out("ok: %r %s" % (text, "absent" if absent else "present"))
    else:
        out("FAIL: %r %s" % (text, "is present" if absent else "is not on screen"))
        sys.exit(1)
elif cmd == "find":
    out(json.dumps([{"class": "ax:AXStaticText", "text": t} for t in screen_text()]))
elif cmd == "layout-issues":
    layout = os.environ.get("FAKE_CREW_LAYOUT", "none")
    issues = {
        "none": [],
        "content_ambiguous": [{"class": "NSView", "ambiguous": True, "frame": {"x": 300, "y": 40, "w": 200, "h": 20}}],
        # none of these is the content area's own: the sidebar, AppKit plumbing, and a sound view
        "ignorable": [{"class": "NSView", "ambiguous": True, "frame": {"x": 20, "y": 40, "w": 100, "h": 20}},
                      {"class": "_NSTextContainer", "ambiguous": True, "frame": {"x": 300, "y": 40, "w": 10, "h": 10}},
                      {"class": "NSTextField", "ambiguous": True, "frame": {"x": 300, "y": 80, "w": 10, "h": 10}},
                      {"class": "NSStackView", "ambiguous": True, "frame": {"x": 300, "y": 90, "w": 10, "h": 10}},
                      {"class": "NSView", "ambiguous": False, "frame": {"x": 300, "y": 40, "w": 200, "h": 20}}],
    }[layout]
    out(json.dumps(issues))
else:
    print("fake app: unknown command %r" % cmd, file=sys.stderr)
    sys.exit(2)
'''


def _write_executable(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class CrewScriptTest(unittest.TestCase):
    def setUp(self):
        # /tmp, not TMPDIR: unix socket paths are length-limited (SUN_LEN)
        self.dir = tempfile.mkdtemp(prefix="qa-crew-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.sock = os.path.join(self.dir, "b.sock")
        self.broker, self.servers = fmb.serve(self.sock, fmb.SCENARIOS["crew_gates"](), ping_secs=0,
                                              scenario=fmb.SCENARIOS["crew_gates"])
        self.addCleanup(self.stop_broker)
        self.app_dir = os.path.join(self.dir, "app")
        self.home = os.path.join(self.dir, "home")
        self.tmp = os.path.join(self.dir, "tmp")
        for d in (self.app_dir, self.home, self.tmp):
            os.mkdir(d)
        self.app = os.path.join(self.app_dir, "nostromo-app")
        _write_executable(self.app, FAKE_APP.replace("__PYTHON__", sys.executable))

    def stop_broker(self):
        import threading
        stoppers = [threading.Thread(target=s.shutdown) for s in self.servers]
        for t in stoppers:
            t.start()
        for t in stoppers:
            t.join(timeout=10)
        for s in self.servers:
            s.server_close()

    def run_script(self, mode="normal", layout="none", timeout=180):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("QA_", "NOSTROMO_", "FAKE_"))}
        env.update(HOME=self.home, TMPDIR=self.tmp, QA_APP=self.app, QA_FMB_SOCK=self.sock, QA_SETTLE="0",
                   QA_SCREEN="Test", FAKE_CREW_DIR=self.app_dir, FAKE_CREW_SOCK=self.sock,
                   FAKE_CREW_MODE=mode, FAKE_CREW_LAYOUT=layout)
        return subprocess.run(["bash", SCRIPT], capture_output=True, text=True, env=env, cwd=self.dir, timeout=timeout)

    def calls(self):
        with open(os.path.join(self.app_dir, "calls.log")) as f:
            return [json.loads(line) for line in f if line.strip()]

    def ctl(self, req):
        import socket
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        s.connect(self.sock + ".ctl")
        try:
            s.sendall((json.dumps(req) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(1 << 16)
                if not chunk:
                    break
                buf += chunk
            return json.loads(buf)
        finally:
            s.close()

    @staticmethod
    def waits(calls):
        """The text of every `wait` call, in order."""
        out = []
        for argv in calls:
            if command_of(argv) == "wait":
                rest = argv[argv.index("wait") + 1:]
                out.append(next(a for i, a in enumerate(rest) if not a.startswith("--") and (i == 0 or rest[i - 1] != "--timeout")))
        return out

    # -- the whole scenario, in one run ------------------------------------------------------------

    def test_the_crew_scenario_passes_end_to_end_against_the_real_fake_broker(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], "mother-crew: PASS")

        calls = self.calls()
        waits = self.waits(calls)
        self.assertIn("4 of 5 gates passed", waits)
        self.assertIn("5 of 5 gates passed", waits)
        self.assertLess(waits.index("4 of 5 gates passed"), waits.index("5 of 5 gates passed"),
                        "the gate run is read step by step: progress 4/5 (one red) before 5/5")
        # the lens wave job is only opened after it has been announced
        self.assertLess(waits.index("Rework consent form validation"), waits.index("perri:ops-infra: skipped"))

        # every call targets the QA display, and the last thing the script does is give focus back
        self.assertTrue(all(argv[:2] == ["--screen", "Test"] for argv in calls), calls)
        self.assertEqual(calls[0], ["--screen", "Test", "activate"])
        self.assertEqual(calls[-1], ["--screen", "Test", "restore"])
        self.assertEqual([command_of(a) for a in calls].count("restore"), 1)

        # the scenario sends the broker no command: it only watches
        self.assertEqual(self.ctl({"op": "commands"})["result"], [])

        # and what the script saw really was the replayed run
        job = next(j for j in self.ctl({"op": "jobs"})["result"] if j["id"] == "j-gates1")
        self.assertEqual((job["gates"]["status"], job["gates"]["attempt"]), ("passed", 2))

    # -- failure paths (fast) ----------------------------------------------------------------------

    def test_a_wait_that_times_out_fails_the_script_and_it_never_claims_a_pass(self):
        r = self.run_script(mode="wait_timeout")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("PASS", r.stdout + r.stderr)
        self.assertEqual(self.waits(self.calls())[:1], ["Add facility export endpoint"])   # it stopped at the first failure
        self.assertEqual(len(self.waits(self.calls())), 1)

    def test_focus_is_given_back_even_when_the_script_fails(self):
        r = self.run_script(mode="wait_timeout")
        self.assertNotEqual(r.returncode, 0)
        calls = self.calls()
        self.assertEqual(calls[-1], ["--screen", "Test", "restore"])
        self.assertEqual(command_of(calls[0]), "activate")

    def test_an_ambiguous_view_in_the_content_area_fails_the_script_naming_layout_issues(self):
        r = self.run_script(mode="lenient", layout="content_ambiguous")
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("layout issues", r.stdout + r.stderr)
        self.assertNotIn("PASS", r.stdout + r.stderr)
        self.assertEqual(self.calls()[-1], ["--screen", "Test", "restore"])

    def test_layout_noise_outside_the_content_area_does_not_fail_the_script(self):
        r = self.run_script(mode="lenient", layout="ignorable")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.strip().splitlines()[-1], "mother-crew: PASS")

    def test_the_script_resets_the_broker_first_so_it_always_starts_from_the_scenarios_jobs(self):
        # a leftover from a previous run (the job already answered, gates passed) must not leak in
        self.assertTrue(self.ctl({"op": "replay", "file": "gates_fix_pass.ndjson", "speed": 0, "wait": True})["ok"])
        passed = next(j for j in self.ctl({"op": "jobs"})["result"] if j["id"] == "j-gates1")
        self.assertEqual(passed["gates"]["status"], "passed")
        r = self.run_script(mode="wait_timeout")                   # fails at its first wait, after the reset
        self.assertNotEqual(r.returncode, 0)
        job = next(j for j in self.ctl({"op": "jobs"})["result"] if j["id"] == "j-gates1")
        self.assertEqual((job["gates"]["status"], job["progress"]["pct"]), ("failed", 80))   # the recorded mid-run state: attempt 1 red, 80%


if __name__ == "__main__":
    unittest.main()
