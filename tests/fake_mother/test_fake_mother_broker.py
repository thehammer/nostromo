"""Protocol-level tests for bin/fake-mother-broker, written as the app's
MotherBrokerClient would speak to it: hello → subscribe → snapshot → events,
and acked answer/cancel/retry/force-start commands.

Run with:  python3 -m unittest discover -s tests/fake_mother
"""
import importlib.machinery, importlib.util, json, os, shutil, socket, subprocess, tempfile, threading, time, unittest

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


# ── MC2: category filtering, query.get, crew scenarios, replay ────────────────────────────────────

FIXTURES = os.path.join(os.path.dirname(__file__), "..", "fixtures", "mother-contract")
CLASSIC_FIVE = ["state", "activity", "await", "current_activity", "quota"]
CREW_SCENARIOS = {"crew_gates": "gates_fix_pass.ndjson", "crew_wave": "lens_wave.ndjson",
                  "crew_hold": "gate_hold_answered.ndjson"}


def fixture(name):
    """A vendored contract fixture, read directly (never through the broker)."""
    with open(os.path.join(FIXTURES, name)) as f:
        return [json.loads(line) for line in f if line.strip()]


def fixture_events(name):
    """The `dir: event` lines of a fixture, without its hello."""
    return [m for m in fixture(name) if m["dir"] == "event" and m["t"] != "hello"]


def first_snapshot_jobs(name):
    """The jobs of the first snapshot that has any (the recordings open with an empty one)."""
    return next(m for m in fixture(name) if m["t"] == "snapshot" and m["data"]["jobs"])["data"]["jobs"]


class RawConn:
    """A client that reads with its own byte buffer, so a read timeout never corrupts the stream
    (a makefile() object breaks after a socket timeout). `received` keeps every raw line, in order."""

    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.buf = b""
        self.received = []

    def send(self, t, data=None, id_="c1"):
        self.s.sendall((json.dumps({"v": 1, "dir": "cmd", "t": t, "id": id_, "data": data or {}}) + "\n").encode())

    def read(self, timeout=3.0):
        """The next message, or None when nothing arrives within `timeout` seconds."""
        deadline = time.time() + timeout
        while b"\n" not in self.buf:
            left = deadline - time.time()
            if left <= 0:
                return None
            self.s.settimeout(left)
            try:
                chunk = self.s.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        self.received.append(line.decode())
        return json.loads(line)

    def read_all(self, quiet=0.3):
        """Everything that arrives until the stream has been quiet for `quiet` seconds."""
        out = []
        while True:
            m = self.read(quiet)
            if m is None:
                return out
            out.append(m)

    def close(self):
        self.s.close()


class MC2Base(unittest.TestCase):
    scenario = "basic"
    caps = None

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="fmb", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.sock = os.path.join(self.dir, "b.sock")
        self.start_broker(self.scenario)
        self.conns = []

    def start_broker(self, scenario, caps=None):
        self.broker, self.servers = fmb.serve(self.sock, fmb.SCENARIOS[scenario](), ping_secs=0,
                                              scenario=fmb.SCENARIOS[scenario], caps=caps)
        self.addCleanup(self.stop_broker)

    def stop_broker(self):
        for c in self.conns:
            c.close()
        self.conns = []
        # shutdown() waits out the serve loop's poll interval: do both servers at once
        stoppers = [threading.Thread(target=s.shutdown) for s in self.servers]
        for t in stoppers:
            t.start()
        for t in stoppers:
            t.join()
        for s in self.servers:
            s.server_close()

    def restart_broker(self, scenario, caps=None):
        self.stop_broker()
        self.start_broker(scenario, caps)

    def client(self, categories=None, subscribe=True):
        c = RawConn(self.sock); self.conns.append(c)
        hello = c.read()
        self.assertEqual(hello["t"], "hello")
        self.hello = hello
        if subscribe:
            data = {"sub": "queue", "jobs": ["all"]}
            if categories is not None:
                data["categories"] = categories
            c.send("subscribe", data, "sub1")
            ack = c.read()
            self.assertEqual((ack["dir"], ack["data"]["ok"]), ("ack", True))
            snap = c.read()
            self.assertEqual(snap["t"], "snapshot")
            c.snapshot = snap["data"]["jobs"]
        return c

    def ctl(self, **req):
        c = RawConn(self.sock + ".ctl"); self.conns.append(c)
        c.s.sendall((json.dumps(req) + "\n").encode())
        return c.read(30)

    def query_get(self, c, job_id):
        c.send("query.get", {"job": job_id}, "q-" + job_id)
        m = c.read()
        self.assertEqual((m["dir"], m["t"], m["id"]), ("ack", "query.get", "q-" + job_id))
        return m["data"]


class CategoryFilteringTest(MC2Base):
    def emit_activity_progress_then_running(self):
        self.assertTrue(self.ctl(op="emit", t="gate_result", data={"job": "j-run", "name": "lint", "result": "passed"})["ok"])
        self.assertTrue(self.ctl(op="emit", t="progress_updated", data={"job": "j-run", "pct": 40})["ok"])
        self.assertTrue(self.ctl(op="event", kind="running", job="j-q1")["ok"])

    def test_a_state_only_subscriber_gets_state_events_but_not_activity_or_progress(self):
        c = self.client(["state"])
        self.emit_activity_progress_then_running()
        got = c.read_all()
        self.assertEqual([m["t"] for m in got], ["running"])
        self.assertEqual(got[0]["data"]["job"], "j-q1")

    def test_a_subscriber_with_no_categories_gets_everything_and_events_carry_their_category(self):
        c = self.client(None)
        self.emit_activity_progress_then_running()
        got = c.read_all()
        self.assertEqual([(m["t"], m["data"]["category"]) for m in got],
                         [("gate_result", "activity"), ("progress_updated", "progress"), ("running", "state")])

    def test_the_snapshot_is_always_sent_whatever_the_categories(self):
        c = self.client(["progress"])
        self.assertEqual({j["id"] for j in c.snapshot},
                         {"j-run", "j-ask", "j-pause", "j-q1", "j-q2", "j-pipe", "j-ok", "j-bad", "j-cx"})

    def test_a_filtered_client_stays_connected_and_still_gets_later_events_of_its_categories(self):
        c = self.client(["state"])
        self.ctl(op="emit", t="gate_result", data={"job": "j-run", "name": "lint", "result": "passed"})
        self.assertIsNone(c.read(0.3))                        # nothing for it, and still open
        self.ctl(op="event", kind="running", job="j-q1")
        self.assertEqual(c.read()["t"], "running")
        self.ctl(op="emit", t="progress_updated", data={"job": "j-run", "pct": 41})
        self.ctl(op="event", kind="cancelled", job="j-run")
        self.assertEqual(c.read()["t"], "cancelled")           # the filtered progress event did not wedge it
        c.send("cancel", {"job": "j-ask"}, "x1")               # and it can still talk to the broker
        self.assertEqual({c.read()["dir"], c.read()["dir"]}, {"ack", "event"})

    def test_two_clients_are_filtered_independently(self):
        only_state = self.client(["state"])
        only_activity = self.client(["activity"])
        self.emit_activity_progress_then_running()
        self.assertEqual([m["t"] for m in only_state.read_all()], ["running"])
        self.assertEqual([m["t"] for m in only_activity.read_all()], ["gate_result"])


class QueryGetTest(MC2Base):
    def test_query_get_acks_the_raw_job_from_the_table(self):
        c = self.client()
        data = self.query_get(c, "j-run")
        self.assertTrue(data["ok"])
        table = {j["id"]: j for j in self.ctl(op="jobs")["result"]}
        self.assertEqual(data["job"], table["j-run"])

    def test_query_get_returns_a_crew_jobs_gates_and_progress(self):
        self.restart_broker("crew_gates")
        c = self.client()
        data = self.query_get(c, "j-gates1")
        self.assertTrue(data["ok"])
        job = data["job"]
        self.assertEqual(job["gates"]["status"], "failed")
        self.assertEqual((job["gates"]["attempt"], job["gates"]["max_attempts"]), (1, 3))
        self.assertEqual((job["progress"]["pct"], job["progress"]["stage"]), (80, "rework"))

    def test_query_get_for_an_unknown_job_is_a_coded_error(self):
        c = self.client()
        data = self.query_get(c, "j-nope")
        self.assertFalse(data["ok"])
        self.assertEqual(data["error"]["code"], "no_such_job")

    def test_query_get_is_not_recorded_as_a_command(self):
        c = self.client()
        self.query_get(c, "j-run")
        self.query_get(c, "j-nope")
        self.assertEqual(self.ctl(op="commands")["result"], [])
        c.send("cancel", {"job": "j-run"}, "x1")               # a real command still is
        c.read_all()
        self.assertEqual([x["type"] for x in self.ctl(op="commands")["result"]], ["cancel"])


class CrewScenariosTest(MC2Base):
    def test_each_crew_scenario_is_seeded_from_its_fixtures_first_snapshot(self):
        for scenario, name in CREW_SCENARIOS.items():
            with self.subTest(scenario):
                self.restart_broker(scenario)
                expected = first_snapshot_jobs(name)
                got = self.ctl(op="jobs")["result"]
                self.assertEqual([j["id"] for j in got], [j["id"] for j in expected])
                for want, have in zip(expected, got):
                    for key in ("title", "state", "repo", "activity", "paused_reason", "question"):
                        self.assertEqual(have.get(key), want.get(key), key)
                    for key in ("gates", "review_wave", "decision", "progress"):
                        self.assertEqual(have.get(key), want.get(key), key)

    def test_the_first_snapshot_jobs_are_what_the_fixtures_say_they_are(self):
        # pins the facts the scenario tests below lean on, read from the fixture files themselves
        gates, wave, hold = (first_snapshot_jobs(n)[0] for n in CREW_SCENARIOS.values())
        self.assertEqual((gates["id"], hold["id"], wave["id"]), ("j-gates1", "j-hold1", "j-wave1"))

    def hello_caps_from_cli(self, *extra):
        """The capabilities in the hello of `bin/fake-mother-broker <extra>`, run as the QA instructions run it."""
        sock = os.path.join(self.dir, "cli.sock")
        proc = subprocess.Popen([PATH, "--sock", sock, *extra], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertIn("fake Mother broker", proc.stdout.readline())   # printed once it is listening
            c = RawConn(sock)
            try:
                return c.read()["data"]["capabilities"]
            finally:
                c.close()
        finally:
            proc.kill(); proc.wait(timeout=10)
            proc.stdout.close(); proc.stderr.close()

    def test_crew_scenarios_advertise_the_fixture_hellos_capabilities(self):
        want = next(m for m in fixture("gates_fix_pass.ndjson") if m["t"] == "hello")["data"]["capabilities"]
        for needed in ("progress", "answer.option", "ack"):
            self.assertIn(needed, want)
        for scenario in CREW_SCENARIOS:
            with self.subTest(scenario):
                self.assertEqual(self.hello_caps_from_cli("--scenario", scenario), want)

    def test_basic_still_advertises_exactly_the_classic_five_and_its_jobs(self):
        c = self.client()
        self.assertEqual(self.hello["data"]["capabilities"], CLASSIC_FIVE)
        self.assertEqual(self.hello["data"]["protocol_version"], 1)
        self.assertEqual({j["id"] for j in c.snapshot},
                         {"j-run", "j-ask", "j-pause", "j-q1", "j-q2", "j-pipe", "j-ok", "j-bad", "j-cx"})
        self.assertTrue(all("gates" not in j and "progress" not in j for j in c.snapshot))

    def test_the_caps_parameter_overrides_the_advertised_capabilities(self):
        self.restart_broker("crew_gates", caps=["state", "x.y"])
        self.client(subscribe=False)
        self.assertEqual(self.hello["data"]["capabilities"], ["state", "x.y"])

    def test_the_caps_flag_on_the_command_line_overrides_and_the_classic_five_stay_the_default(self):
        self.assertEqual(self.hello_caps_from_cli("--scenario", "basic", "--caps", "a,b"), ["a", "b"])
        self.assertEqual(self.hello_caps_from_cli("--scenario", "crew_gates", "--caps", "state,progress"), ["state", "progress"])
        self.assertEqual(self.hello_caps_from_cli("--scenario", "basic"), CLASSIC_FIVE)


class ReplayTest(MC2Base):
    scenario = "crew_gates"

    def replay(self, file, **kw):
        return self.ctl(op="replay", file=file, speed=0, wait=True, **kw)

    def test_replaying_gates_fix_pass_streams_the_fixtures_events_in_order(self):
        c = self.client(["state", "activity", "await", "progress"])
        r = self.replay("gates_fix_pass.ndjson")
        self.assertTrue(r["ok"], r)
        got = c.read_all()
        want = [m["t"] for m in fixture_events("gates_fix_pass.ndjson") if m["t"] != "snapshot"]
        self.assertEqual([m["t"] for m in got], want)
        self.assertEqual([m["data"]["job"] for m in got], ["j-gates1"] * len(want))
        gate_names = [(m["data"]["attempt"], m["data"]["name"], m["data"]["result"]) for m in got if m["t"] == "gate_result"]
        self.assertEqual(gate_names, [(m["data"]["attempt"], m["data"]["name"], m["data"]["result"])
                                      for m in fixture_events("gates_fix_pass.ndjson") if m["t"] == "gate_result"])

    def test_progress_events_get_strictly_increasing_updated_at_and_land_in_the_jobs_progress(self):
        c = self.client()
        self.replay("gates_fix_pass.ndjson")
        progress = [m["data"] for m in c.read_all() if m["t"] == "progress_updated"]
        self.assertEqual([p["pct"] for p in progress], [5, 80, 100])
        stamps = [p["updated_at"] for p in progress]
        self.assertEqual(stamps, sorted(set(stamps)), "updated_at must be strictly increasing")
        self.assertTrue(all(p["category"] == "progress" for p in progress))
        job = self.query_get(c, "j-gates1")["job"]
        self.assertEqual(job["progress"]["pct"], 100)
        self.assertEqual(job["progress"]["updated_at"], stamps[-1])
        self.assertEqual(job["progress"]["signals"]["gates"],
                         {"passed": 5, "failed": 0, "total": 5, "attempt": 2, "max_attempts": 3})

    def test_after_the_replay_query_get_shows_the_passed_second_attempt(self):
        c = self.client()
        self.replay("gates_fix_pass.ndjson")
        c.read_all()
        job = self.query_get(c, "j-gates1")["job"]
        gates = job["gates"]
        self.assertEqual((gates["status"], gates["attempt"]), ("passed", 2))
        self.assertEqual({r["name"]: r["result"] for r in gates["results"]},
                         {"clean_tree": "passed", "pushed": "passed", "lint": "passed", "unit": "passed", "static": "passed"})
        self.assertEqual(len(gates["results"]), 5)
        self.assertEqual(job["progress"]["pct"], 100)

    def test_a_replay_cut_after_the_first_attempt_leaves_the_failed_unit_gate_in_the_job(self):
        # attempt 1 ended red, attempt 2 reset the rows: a client that re-reads the job after the
        # `gates_completed` of attempt 1 would have seen exactly that. Drive it with a fixture cut at that point.
        events = fixture_events("gates_fix_pass.ndjson")
        cut = next(i for i, m in enumerate(events) if m["t"] == "gates_completed") + 1
        path = os.path.join(self.dir, "cut.ndjson")
        with open(path, "w") as f:
            f.write("".join(json.dumps(m) + "\n" for m in events[:cut]))
        c = self.client()
        self.replay(path)
        c.read_all()
        gates = self.query_get(c, "j-gates1")["job"]["gates"]
        self.assertEqual((gates["status"], gates["attempt"]), ("failed", 1))
        self.assertEqual({r["name"]: r["result"] for r in gates["results"]},
                         {"clean_tree": "passed", "pushed": "passed", "lint": "passed", "unit": "failed", "static": "passed"})
        unit = next(r for r in gates["results"] if r["name"] == "unit")
        self.assertEqual((unit["exit_code"], unit["blocking"]), (1, True))

    def test_replaying_lens_wave_announces_the_new_job_with_its_full_payload_then_folds_the_wave(self):
        c = self.client()
        self.replay("lens_wave.ndjson")
        got = c.read_all()
        self.assertEqual(got[0]["t"], "queued")
        self.assertEqual(got[0]["data"]["id"], "j-wave1")
        self.assertEqual(got[0]["data"]["title"], next(m for m in fixture_events("lens_wave.ndjson") if m["t"] == "queued")["data"]["title"])
        self.assertIn("crew", got[0]["data"], "the announcement carries the job's full payload")
        self.assertEqual([m["t"] for m in got[1:]], [m["t"] for m in fixture_events("lens_wave.ndjson") if m["t"] not in ("snapshot", "queued")])
        job = self.query_get(c, "j-wave1")["job"]
        lenses = {x["reviewer"]: x for x in job["review_wave"]["lenses"]}
        self.assertEqual(lenses["perri:ops-infra"]["state"], "skipped")
        self.assertEqual(lenses["perri:ops-infra"]["skip_reason"], "path_scope")
        self.assertEqual(lenses["perri:correctness"]["state"], "done")
        self.assertEqual(lenses["perri:correctness"]["findings"]["blocking"], 1)
        self.assertEqual(lenses["perri:phi-security"]["state"], "done")
        self.assertEqual(job["review_wave"]["adherence"]["state"], "done")   # adherence is its own key now, not a lens
        claims = job["review_wave"]["claims"]
        self.assertEqual((claims["verified"], claims["refuted"], claims["unverified"]), (1, 1, 0))
        self.assertEqual(job["review_wave"]["status"], "held")
        self.assertEqual(job["state"], "awaiting")
        self.assertEqual(job["activity"], "review_hold")
        # the job the scenario started with is untouched
        self.assertEqual(self.query_get(c, "j-gates1")["job"]["gates"]["status"], "failed")

    def test_replaying_gate_hold_answered_on_crew_hold_ends_ready_with_the_decision_resolved(self):
        self.restart_broker("crew_hold")
        c = self.client()
        before = self.query_get(c, "j-hold1")["job"]
        self.assertEqual((before["state"], before["decision"]["resolved_at"]), ("awaiting", None))
        self.replay("gate_hold_answered.ndjson")
        got = c.read_all()
        self.assertEqual([m["t"] for m in got],
                         [m["t"] for m in fixture_events("gate_hold_answered.ndjson") if m["t"] != "snapshot"])
        job = self.query_get(c, "j-hold1")["job"]
        self.assertEqual(job["state"], "ready")
        self.assertEqual(job["decision"]["id"], "d-0001")
        self.assertIsNotNone(job["decision"]["resolved_at"])
        self.assertEqual(job["decision"]["resolution"]["option"], "resume_with_guidance")
        self.assertIsNone(job.get("activity"))
        self.assertEqual(job.get("attention", []), [])

    def test_an_event_for_a_job_the_table_does_not_have_is_skipped_without_error(self):
        ghost = {"v": 1, "dir": "event", "t": "gate_result", "id": "g1", "ts": "2026-10-17T12:00:00.000Z",
                 "data": {"attempt": 1, "name": "lint", "result": "passed", "blocking": True, "duration_s": 1,
                          "exit_code": 0, "job": "j-ghost", "category": "activity"}}
        real = dict(ghost, id="g2", data=dict(ghost["data"], job="j-gates1", name="unit"))
        path = os.path.join(self.dir, "ghost.ndjson")
        with open(path, "w") as f:
            f.write(json.dumps(ghost) + "\n" + json.dumps(real) + "\n")
        c = self.client()
        r = self.replay(path)
        self.assertTrue(r["ok"], r)
        got = c.read_all()
        self.assertEqual([(m["t"], m["data"]["job"], m["data"]["name"]) for m in got], [("gate_result", "j-gates1", "unit")])
        self.assertNotIn("j-ghost", [j["id"] for j in self.ctl(op="jobs")["result"]])

    def test_replay_without_wait_returns_at_once_with_the_event_count_and_keeps_streaming(self):
        events = fixture_events("gates_fix_pass.ndjson")
        slow = [m for m in events if m["t"] == "gate_result"][:4]
        path = os.path.join(self.dir, "slow.ndjson")
        with open(path, "w") as f:
            f.write("".join(json.dumps(m) + "\n" for m in slow))
        c = self.client()
        started = time.time()
        r = self.ctl(op="replay", file=path, speed=2)        # 0.25 s per event: about a second in all
        elapsed = time.time() - started
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"], 4)
        self.assertLess(elapsed, 0.5, "replay without wait must not block on the stream")
        arrived = []
        while len(arrived) < 4:
            m = c.read(3)
            self.assertIsNotNone(m, f"only {len(arrived)} of 4 events arrived")
            arrived.append(m["t"])
        self.assertEqual(arrived, ["gate_result"] * 4)

    def test_replay_by_basename_counts_the_events_a_waiting_replay_sent(self):
        r = self.replay("lens_wave.ndjson")
        self.assertTrue(r["ok"], r)
        # every event of the recording (snapshots and the new job's `queued` included), and never the hello
        self.assertEqual(r["result"], len(fixture_events("lens_wave.ndjson")))

    def test_an_unknown_replay_file_is_an_error(self):
        r = self.ctl(op="replay", file="no-such-file.ndjson", speed=0, wait=True)
        self.assertFalse(r["ok"])
        r = self.ctl(op="replay", file="no-such-file.ndjson", speed=0)
        self.assertFalse(r["ok"])
        self.assertTrue(self.ctl(op="jobs")["ok"])           # and the broker is still up


class ContractTest(MC2Base):
    """Everything the broker sends is accepted by Mother's own contract checker."""

    def test_every_broker_message_conforms_to_mothers_contract_check(self):
        repo = os.path.expanduser(os.environ.get("NOSTROMO_MOTHER_REPO", "~/Code/mother"))
        checker = os.path.join(repo, "plugins", "mother", "scripts", "contract-check.sh")
        if not os.path.isfile(checker):
            self.skipTest(f"no Mother checkout with contract-check.sh at {checker} (set NOSTROMO_MOTHER_REPO)")
        if shutil.which("jq") is None:
            self.skipTest("jq is not installed (contract-check.sh needs it)")
        recorded = []
        for scenario, name in CREW_SCENARIOS.items():
            self.restart_broker(scenario)
            c = self.client(["state", "activity", "await", "progress"])      # hello, ack and snapshot
            r = self.ctl(op="replay", file=name, speed=0, wait=True)
            self.assertTrue(r["ok"], r)
            c.read_all()
            job_id = first_snapshot_jobs(name)[0]["id"]
            self.assertTrue(self.query_get(c, job_id)["ok"])
            self.assertFalse(self.query_get(c, "j-nope")["ok"])
            recorded.extend(c.received)
        self.assertGreater(len(recorded), 30)                                # it recorded the whole conversation
        path = os.path.join(self.dir, "broker-output.ndjson")
        with open(path, "w") as f:
            f.write("\n".join(recorded) + "\n")
        out = subprocess.run(["bash", checker, path], capture_output=True, text=True, timeout=120)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)


# ── MC3: answering a hold by option, and acknowledging attention ──────────────────────────────────

DECISION_EVENTS = ("decision_resolved", "resumed", "ready", "cancelled")


class MC3Base(MC2Base):
    scenario = "crew_hold"
    job_id = "j-hold1"

    def command(self, c, t, data, id_="m1"):
        """Send one command and collect what follows: (the ack's data, the events that came with it).

        The ack for `id_` is required; whether it lands before or after the events is not part of the contract.
        """
        c.send(t, data, id_)
        msgs = c.read_all()
        acks = [m for m in msgs if m["dir"] == "ack" and m["id"] == id_]
        self.assertEqual(len(acks), 1, f"expected exactly one ack for {t} {id_}, got {msgs}")
        self.assertEqual(acks[0]["t"], t)
        return acks[0]["data"], [m for m in msgs if m["dir"] == "event"]

    def answer(self, c, **data):
        return self.command(c, "answer", {"job": self.job_id, **data}, "a1")

    def ack(self, c, **data):
        return self.command(c, "ack", {"job": self.job_id, **data}, "k1")

    def job(self, c):
        return self.query_get(c, self.job_id)["job"]

    def event_data(self, events, kind):
        """The data of the one `kind` event among `events` (a failure, not a StopIteration, when it is missing)."""
        found = [m["data"] for m in events if m["t"] == kind]
        self.assertEqual(len(found), 1, f"expected one {kind} event, got {[m['t'] for m in events]}")
        return found[0]

    def hello_caps_from_cli(self, scenario):
        """The capabilities in the hello of `bin/fake-mother-broker --scenario <scenario>`, run as the QA instructions run it.

        (Through the command line on purpose: that is where a crew scenario takes the fixture's capabilities.)
        """
        sock = os.path.join(self.dir, "cli.sock")
        proc = subprocess.Popen([PATH, "--sock", sock, "--scenario", scenario], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertIn("fake Mother broker", proc.stdout.readline())   # printed once it is listening
            c = RawConn(sock)
            try:
                return c.read()["data"]["capabilities"]
            finally:
                c.close()
        finally:
            proc.kill(); proc.wait(timeout=10)
            proc.stdout.close(); proc.stderr.close()

    def assertInvalidState(self, ack):
        self.assertFalse(ack["ok"], ack)
        self.assertEqual(ack["error"]["code"], "invalid_state", ack)

    def recorded(self):
        return self.ctl(op="commands")["result"]

    def raise_attention(self, *reasons):
        """Raise attention reasons on the hold job the way a recording would (an `attention_raised` event)."""
        events = [{"v": 1, "dir": "event", "t": "attention_raised", "id": f"att{i}", "ts": "2026-10-18T12:00:00.000Z",
                   "data": {"job": self.job_id, "reason": reason, "category": "activity"}} for i, reason in enumerate(reasons)]
        path = os.path.join(self.dir, "attention.ndjson")
        with open(path, "w") as f:
            f.write("".join(json.dumps(m) + "\n" for m in events))
        r = self.ctl(op="replay", file=path, speed=0, wait=True)
        self.assertTrue(r["ok"], r)


class MC3CapabilitiesTest(MC3Base):
    def test_crew_scenarios_advertise_option_answers_and_acknowledgement_and_basic_does_not(self):
        for scenario in CREW_SCENARIOS:
            with self.subTest(scenario):
                caps = self.hello_caps_from_cli(scenario)
                for needed in ("answer.option", "ack"):
                    self.assertIn(needed, caps)
        caps = self.hello_caps_from_cli("basic")
        for absent in ("answer.option", "ack"):
            self.assertNotIn(absent, caps)


class AnswerByOptionTest(MC3Base):
    OPTIONS = {"resume_with_guidance": "Guidance for the worker.", "escalate": None, "override_open": None}

    def answer_with(self, c, option, text=None, **extra):
        data = {"option": option, **extra}
        if text is not None:
            data["text"] = text
        return self.answer(c, **data)

    def test_the_hold_starts_open_and_awaiting(self):
        c = self.client()
        job = self.job(c)
        self.assertEqual((job["state"], job["decision"]["id"], job["decision"]["resolved_at"]), ("awaiting", "d-0001", None))
        self.assertEqual([o["id"] for o in job["decision"]["options"]],
                         ["resume_with_guidance", "escalate", "override_open", "cancel"])

    def test_answering_with_an_option_other_than_cancel_resolves_the_decision_and_readies_the_job(self):
        for option, text in self.OPTIONS.items():
            with self.subTest(option):
                self.restart_broker("crew_hold")
                c = self.client()
                ack, events = self.answer_with(c, option, text)
                self.assertTrue(ack["ok"], ack)
                job = self.job(c)
                self.assertEqual(job["state"], "ready")
                self.assertIsNotNone(job["decision"]["resolved_at"])
                self.assertEqual(job["decision"]["resolution"]["option"], option)
                self.assertEqual(job["decision"]["resolution"]["source"], "broker_client")
                self.assertIsNone(job.get("activity"), "the hold is over")
                self.assertEqual(job.get("attention", []), [], "decision_awaiting is cleared")
                self.assertNotIn("decision_awaiting", [r["reason"] for r in job.get("attention_reasons", [])])
                self.assertEqual(self.recorded(), [{"type": "answer", "data": {"job": "j-hold1", "option": option,
                                                                              **({"text": text} if text else {})}}])
                self.assertEqual([m["t"] for m in events if m["t"] in DECISION_EVENTS],
                                 ["decision_resolved", "resumed", "ready"], [m["t"] for m in events])
                by_kind = {m["t"]: m["data"] for m in events}
                self.assertEqual(by_kind["decision_resolved"]["job"], "j-hold1")
                self.assertEqual(by_kind["decision_resolved"]["decision_id"], "d-0001")
                for kind in ("decision_resolved", "resumed"):
                    self.assertEqual((by_kind[kind]["option"], by_kind[kind]["source"]), (option, "broker_client"), kind)
                self.assertEqual(by_kind["resumed"]["job"], "j-hold1")
                self.assertEqual(by_kind["ready"]["job"], "j-hold1")

    def test_cancel_resolves_the_decision_and_cancels_the_job_without_resuming_it(self):
        c = self.client()
        ack, events = self.answer_with(c, "cancel")
        self.assertTrue(ack["ok"], ack)
        kinds = [m["t"] for m in events if m["t"] in DECISION_EVENTS]
        self.assertEqual(kinds, ["decision_resolved", "cancelled"], [m["t"] for m in events])
        resolved = self.event_data(events, "decision_resolved")
        self.assertEqual((resolved["job"], resolved["decision_id"], resolved["option"], resolved["source"]),
                         ("j-hold1", "d-0001", "cancel", "broker_client"))
        self.assertEqual(self.event_data(events, "cancelled")["job"], "j-hold1")
        job = self.job(c)
        self.assertEqual(job["state"], "cancelled")
        self.assertEqual(job["decision"]["resolution"]["option"], "cancel")
        self.assertIsNotNone(job["decision"]["resolved_at"])
        self.assertEqual(job.get("attention", []), [])
        self.assertEqual(self.recorded()[-1]["data"]["option"], "cancel")

    def test_the_source_defaults_to_broker_client_and_a_sent_source_is_honoured(self):
        c = self.client()
        _, events = self.answer_with(c, "escalate")
        self.assertEqual(self.event_data(events, "decision_resolved")["source"], "broker_client")
        for option in ("escalate", "cancel"):
            with self.subTest(option):
                self.restart_broker("crew_hold")
                c = self.client()
                _, events = self.answer_with(c, option, source="nostromo_app")
                self.assertEqual(self.event_data(events, "decision_resolved")["source"], "nostromo_app")
                if option != "cancel":
                    self.assertEqual(self.event_data(events, "resumed")["source"], "nostromo_app")
                self.assertEqual(self.job(c)["decision"]["resolution"]["source"], "nostromo_app")

    def test_a_second_option_answer_for_the_resolved_decision_is_invalid_state_and_changes_nothing(self):
        c = self.client()
        first, _ = self.answer_with(c, "escalate")
        self.assertTrue(first["ok"], first)
        before = self.job(c)
        self.assertEqual((before["state"], before["decision"]["resolved_at"] is not None), ("ready", True))
        ack, events = self.answer_with(c, "cancel")
        self.assertInvalidState(ack)
        self.assertEqual([m for m in events if m["t"] in DECISION_EVENTS], [])
        self.assertEqual(self.job(c), before)
        self.assertEqual((before["state"], before["decision"]["resolution"]["option"]), ("ready", "escalate"))
        self.assertEqual([x["data"]["option"] for x in self.recorded()], ["escalate", "cancel"], "the refused command is still recorded")

    def test_an_option_that_is_not_one_of_the_decisions_options_is_invalid_state_and_changes_nothing(self):
        c = self.client()
        before = self.job(c)
        ack, events = self.answer_with(c, "do_something_else")
        self.assertInvalidState(ack)
        self.assertEqual([m for m in events if m["t"] in DECISION_EVENTS], [])
        self.assertEqual(self.job(c), before)
        self.assertEqual((before["state"], before["decision"]["resolved_at"]), ("awaiting", None))
        self.assertEqual(self.recorded()[-1]["data"]["option"], "do_something_else")
        ack, _ = self.answer_with(c, "escalate")           # and the hold can still be answered properly
        self.assertTrue(ack["ok"], ack)

    def test_an_option_answer_for_a_job_with_no_open_decision_is_invalid_state_and_changes_nothing(self):
        self.restart_broker("basic")
        c = self.client()
        self.job_id = "j-ask"                              # awaiting, but asked a free-text question: no structured decision
        before = self.job(c)
        self.assertEqual(before["state"], "awaiting")
        self.assertNotIn("decision", before)
        ack, events = self.answer_with(c, "escalate")
        self.assertInvalidState(ack)
        self.assertEqual([m for m in events if m["t"] in DECISION_EVENTS + ("running",)], [])
        self.assertEqual(self.job(c), before)
        self.assertEqual(self.recorded()[-1]["data"]["option"], "escalate")

    def test_an_answer_without_an_option_keeps_its_old_behaviour(self):
        self.restart_broker("basic")
        c = self.client()
        self.job_id = "j-ask"
        ack, events = self.answer(c, text="Keep it and mark it deprecated.")
        self.assertTrue(ack["ok"], ack)
        self.assertEqual(self.job(c)["state"], "running")
        self.assertIn("running", [m["t"] for m in events])
        self.assertEqual([m for m in events if m["t"] in DECISION_EVENTS], [])
        self.assertEqual(self.recorded(), [{"type": "answer", "data": {"job": "j-ask", "text": "Keep it and mark it deprecated."}}])


class AcknowledgeTest(MC3Base):
    def test_acknowledging_a_raised_reason_marks_it_acked_and_removes_it_from_attention(self):
        c = self.client()
        self.raise_attention("progress_stalled", "burn_ahead")
        c.read_all()
        job = self.job(c)
        self.assertEqual({r["reason"] for r in job["attention"]}, {"decision_awaiting", "progress_stalled", "burn_ahead"})
        ack, events = self.ack(c, reason="progress_stalled")
        self.assertTrue(ack["ok"], ack)
        acked = [m["data"] for m in events if m["t"] == "attention_acked"]
        self.assertEqual(len(acked), 1, [m["t"] for m in events])
        self.assertEqual((acked[0]["job"], acked[0]["reason"], acked[0]["source"]), ("j-hold1", "progress_stalled", "broker_client"))
        job = self.job(c)
        by_reason = {r["reason"]: r for r in job["attention_reasons"]}
        self.assertTrue(by_reason["progress_stalled"]["acked"])
        self.assertFalse(by_reason["burn_ahead"]["acked"], "only the acknowledged reason changes")
        self.assertFalse(by_reason["decision_awaiting"]["acked"])
        self.assertEqual({r["reason"] for r in job["attention"]}, {"decision_awaiting", "burn_ahead"})
        self.assertEqual(self.recorded(), [{"type": "ack", "data": {"job": "j-hold1", "reason": "progress_stalled"}}])

    def test_a_sent_source_is_honoured_on_the_acknowledgement(self):
        c = self.client()
        self.raise_attention("burn_ahead")
        c.read_all()
        ack, events = self.ack(c, reason="burn_ahead", source="nostromo_app")
        self.assertTrue(ack["ok"], ack)
        self.assertEqual(self.event_data(events, "attention_acked")["source"], "nostromo_app")

    def test_acknowledging_a_reason_that_is_not_raised_is_invalid_state_and_changes_nothing(self):
        c = self.client()
        before = self.job(c)
        ack, events = self.ack(c, reason="burn_ahead")
        self.assertInvalidState(ack)
        self.assertEqual([m for m in events if m["t"] == "attention_acked"], [])
        self.assertEqual(self.job(c), before)
        self.assertEqual(self.recorded(), [{"type": "ack", "data": {"job": "j-hold1", "reason": "burn_ahead"}}])

    def test_acknowledging_on_a_job_that_has_never_had_attention_is_invalid_state(self):
        self.restart_broker("basic")
        c = self.client()
        self.job_id = "j-run"
        ack, events = self.ack(c, reason="progress_stalled")
        self.assertInvalidState(ack)
        self.assertEqual([m for m in events if m["t"] == "attention_acked"], [])


if __name__ == "__main__":
    unittest.main()
