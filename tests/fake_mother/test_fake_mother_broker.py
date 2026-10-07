"""Protocol-level tests for bin/fake-mother-broker, written as the app's
MotherBrokerClient would speak to it: hello → subscribe → snapshot → events,
and acked answer/cancel/retry/force-start commands.

Run with:  python3 -m unittest discover -s tests/fake_mother
"""
import importlib.machinery, importlib.util, json, os, socket, tempfile, time, unittest

PATH = os.path.join(os.path.dirname(__file__), "..", "..", "bin", "fake-mother-broker")
_loader = importlib.machinery.SourceFileLoader("fake_mother_broker", PATH)
_spec = importlib.util.spec_from_file_location("fake_mother_broker", PATH, loader=_loader)
fmb = importlib.util.module_from_spec(_spec)
_loader.exec_module(fmb)


class Conn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(3)
        self.s.connect(path)
        self.f = self.s.makefile("rb")

    def read(self):
        return json.loads(self.f.readline())

    def send(self, t, data=None, id_="c1"):
        self.s.sendall((json.dumps({"v": 1, "dir": "cmd", "t": t, "id": id_, "data": data or {}}) + "\n").encode())

    def close(self):
        self.s.close()


class FakeBrokerTest(unittest.TestCase):
    def setUp(self):
        # /tmp, not TMPDIR: unix socket paths are length-limited (SUN_LEN)
        self.dir = tempfile.mkdtemp(prefix="fmb", dir="/tmp")
        self.sock = os.path.join(self.dir, "b.sock")
        self.broker, self.servers = fmb.serve(self.sock, fmb.SCENARIOS["basic"](), ping_secs=0,
                                              scenario=fmb.SCENARIOS["basic"])
        self.conns = []

    def tearDown(self):
        for c in self.conns:
            c.close()
        for s in self.servers:
            s.shutdown(); s.server_close()

    def connect(self):
        c = Conn(self.sock); self.conns.append(c)
        return c

    def subscribed(self):
        c = self.connect()
        self.assertEqual(c.read()["t"], "hello")
        c.send("subscribe", {"sub": "queue", "jobs": ["all"], "categories": fmb.CAPS}, "sub1")
        self.assertEqual(c.read()["dir"], "ack")
        snap = c.read()
        self.assertEqual(snap["t"], "snapshot")
        return c, snap["data"]["jobs"]

    def test_hello_advertises_protocol_and_capabilities(self):
        c = self.connect()
        hello = c.read()
        self.assertEqual((hello["dir"], hello["t"]), ("event", "hello"))
        self.assertEqual(hello["data"]["protocol_version"], 1)
        self.assertIn("state", hello["data"]["capabilities"])

    def test_snapshot_covers_every_state_the_app_renders(self):
        _, jobs = self.subscribed()
        states = {j["state"] for j in jobs}
        self.assertTrue({"running", "awaiting", "queued", "ready", "succeeded", "failed", "cancelled"} <= states)
        pipe = next(j for j in jobs if j["kind"] == "pipeline")
        self.assertEqual(len(pipe["cycles"]), 2)
        self.assertTrue(any(j["question"] for j in jobs))
        self.assertTrue(any(j["paused_reason"] for j in jobs))

    def test_cancel_acks_and_broadcasts_the_state_change(self):
        c, _ = self.subscribed()
        c.send("cancel", {"job": "j-run"}, "x1")
        msgs = [c.read(), c.read()]
        ack = next(m for m in msgs if m["dir"] == "ack")
        ev = next(m for m in msgs if m["dir"] == "event")
        self.assertEqual((ack["id"], ack["data"]["ok"]), ("x1", True))
        self.assertEqual((ev["t"], ev["data"]["job"]), ("cancelled", "j-run"))

    def test_invalid_state_and_unknown_job_are_coded_errors(self):
        c, _ = self.subscribed()
        c.send("retry", {"job": "j-run"}, "r1")   # running jobs cannot be retried
        self.assertEqual(c.read()["data"]["error"]["code"], "invalid_state")
        c.send("cancel", {"job": "nope"}, "r2")
        self.assertEqual(c.read()["data"]["error"]["code"], "no_such_job")

    def test_answer_resumes_an_awaiting_job(self):
        c, _ = self.subscribed()
        c.send("answer", {"job": "j-ask", "text": "yes"}, "a1")
        kinds = {c.read()["t"] for _ in range(2)}
        self.assertEqual(kinds, {"answer", "running"})
        self.assertEqual(self.broker.jobs["j-ask"]["state"], "running")
        self.assertEqual(self.broker.commands[-1]["data"]["text"], "yes")

    def test_retry_and_force_start(self):
        c, _ = self.subscribed()
        c.send("retry", {"job": "j-bad"}, "r1"); c.read(); c.read()
        self.assertEqual(self.broker.jobs["j-bad"]["state"], "ready")
        c.send("force-start", {"job": "j-q1"}, "f1"); c.read(); c.read()
        self.assertEqual(self.broker.jobs["j-q1"]["state"], "running")

    def test_control_socket_can_add_jobs_and_drop_clients(self):
        c, _ = self.subscribed()
        ctl = Conn(self.sock + ".ctl"); self.conns.append(ctl)
        ctl.s.sendall((json.dumps({"op": "add_job", "job": fmb.job("j-new", "New one", "queued")}) + "\n").encode())
        self.assertTrue(ctl.read()["ok"])
        ev = c.read()
        self.assertEqual((ev["t"], ev["data"]["id"]), ("queued", "j-new"))   # full payload, like the real broker
        ctl.s.sendall((json.dumps({"op": "drop"}) + "\n").encode())
        self.assertGreaterEqual(ctl.read()["result"], 1)
        self.assertEqual(c.f.readline(), b"")   # connection closed → client must reconnect

    def test_reset_restores_the_scenario_forgets_commands_and_drops_clients(self):
        c, _ = self.subscribed()
        c.send("cancel", {"job": "j-run"}, "x1"); c.read(); c.read()
        self.assertEqual(self.broker.jobs["j-run"]["state"], "cancelled")
        ctl = Conn(self.sock + ".ctl"); self.conns.append(ctl)
        ctl.s.sendall((json.dumps({"op": "reset"}) + "\n").encode())
        self.assertTrue(ctl.read()["ok"])
        self.assertEqual(self.broker.jobs["j-run"]["state"], "running")
        self.assertEqual(self.broker.commands, [])
        self.assertEqual(c.f.readline(), b"")        # dropped: the app reconnects and re-snapshots
        c2, jobs = self.subscribed()                  # a fresh client sees the restored jobs
        self.assertEqual(next(j for j in jobs if j["id"] == "j-run")["state"], "running")

    def test_refuses_to_run_in_the_real_mother_directory(self):
        import subprocess
        r = subprocess.run([PATH, "--sock", os.path.expanduser("~/.mother/fake.sock")], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refusing", r.stderr + r.stdout)


if __name__ == "__main__":
    unittest.main()
