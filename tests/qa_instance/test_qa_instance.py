"""Isolated QA instance helpers: pure logic, env construction, fake claude, safety greps.

Run with:  python3 -m unittest discover -s tests/qa_instance -v
Never starts an app, a daemon or any real instance.
"""
import ast, hashlib, importlib.machinery, importlib.util, json, os, re, struct, subprocess, sys, tempfile, unittest, zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "qa", "lib"))
import qa_instance as qa  # noqa: E402

_APP = os.path.join(ROOT, "bin", "nostromo-app")
_loader = importlib.machinery.SourceFileLoader("nostromo_app", _APP)
_spec = importlib.util.spec_from_file_location("nostromo_app", _APP, loader=_loader)
cli = importlib.util.module_from_spec(_spec)
_loader.exec_module(cli)


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


class TeardownPidReuseTests(unittest.TestCase):
    def test_kills_only_processes_whose_start_time_matches_the_record(self):
        killed = []
        starts = {10: "Sun Oct 18 10:00:00 2026", 20: "Sun Oct 18 12:34:56 2026"}  # 20 is a recycled pid
        state = {"app_pid": 10, "app_start": starts[10], "daemon_pid": 20, "daemon_start": "Sun Oct 18 10:00:01 2026"}
        qa.teardown("/x", state, start_of=starts.get, kill=killed.append)
        self.assertEqual(killed, [10])

    def test_no_recorded_start_means_never_kill(self):
        killed = []
        qa.teardown("/x", {"app_pid": 10, "daemon_pid": 20}, start_of=lambda p: "t", kill=killed.append)
        self.assertEqual(killed, [])

    def test_a_gone_process_is_not_killed(self):
        killed = []
        qa.teardown("/x", {"app_pid": 10, "app_start": "t"}, start_of=lambda p: None, kill=killed.append)
        self.assertEqual(killed, [])


class QAMotherProcessTests(unittest.TestCase):
    ROOT = "/var/folders/xx/nostromo-qa-abc"
    PS = "\n".join([
        "  PID   UID COMMAND",
        "75097   502 /opt/homebrew/bin/mother-runner supervise HOME=/var/folders/xx/nostromo-qa-abc/home PATH=/usr/bin",
        "95441   502 /usr/bin/env mother daemon start PATH=/usr/bin HOME=/var/folders/xx/nostromo-qa-abc/home",
        "  111   502 /opt/homebrew/bin/mother-runner supervise HOME=/Users/x PATH=/usr/bin",
        "  112   502 /opt/homebrew/bin/mother-runner supervise PATH=/usr/bin",
        "  113   502 /opt/homebrew/bin/mother-runner supervise HOME=/var/folders/xx/nostromo-qa-abc-other/home",
        "  114   501 /opt/homebrew/bin/mother-runner supervise HOME=/var/folders/xx/nostromo-qa-abc/home",
        "  115   502 /bin/zsh -c mother-runner HOME=/var/folders/xx/nostromo-qa-abc/home",
        "  116   502 /opt/homebrew/bin/mother-runner x HOME=/var/folders/xx/nostromo-qa-abc/home HOME=/Users/x",
        "  117   502 /opt/homebrew/bin/mother daemon status HOME=/var/folders/xx/nostromo-qa-abc",
    ])

    def test_only_same_user_mother_processes_with_home_under_the_root_match(self):
        self.assertEqual(qa.find_qa_mother_pids(self.PS, self.ROOT, 502), [117, 75097])

    def test_the_report_names_exactly_those_pids_and_kills_nothing(self):
        problems = qa.report_qa_mother(self.ROOT, ps_text=self.PS, uid=502)
        self.assertEqual(len(problems), 2)
        self.assertIn("pid 117", problems[0])
        self.assertIn("pid 75097", problems[1])
        self.assertFalse(hasattr(qa, "stop_qa_mother"), "detection only: nothing in the harness kills Mother processes")

    def test_the_real_runner_alone_reports_nothing(self):
        ps = "  111   502 /opt/homebrew/bin/mother-runner supervise HOME=/Users/x\n"
        self.assertEqual(qa.report_qa_mother(self.ROOT, ps_text=ps, uid=502), [])

    def test_dotdot_and_unnormalised_homes_do_not_match_outside_the_root(self):
        ps = "\n".join([
            "  201   502 /opt/homebrew/bin/mother-runner x HOME=/var/folders/xx/nostromo-qa-abc/../elsewhere",
            "  202   502 /opt/homebrew/bin/mother-runner x HOME=/var/folders/xx/nostromo-qa-abc/home/../../other",
            "  203   502 /opt/homebrew/bin/mother-runner x HOME=/var/folders/xx/nostromo-qa-abc//home",
        ])
        self.assertEqual(qa.find_qa_mother_pids(ps, self.ROOT, 502), [203])

    def test_no_kill_call_remains_for_mother_processes(self):
        src = read("scripts", "qa", "lib", "qa_instance.py")
        body = src[src.index("def report_qa_mother"):src.index("def cmd_start")]
        self.assertNotIn("kill(", body.replace("kill {pid}", ""))


class BuildSkipTests(unittest.TestCase):
    def test_the_build_is_skipped_only_when_asked_and_everything_exists(self):
        self.assertTrue(qa.build_can_be_skipped({"NOSTROMO_QA_SKIP_BUILD": "1"}, [True, True, True, True]))
        self.assertFalse(qa.build_can_be_skipped({}, [True, True, True, True]))
        self.assertFalse(qa.build_can_be_skipped({"NOSTROMO_QA_SKIP_BUILD": "0"}, [True, True, True, True]))
        self.assertFalse(qa.build_can_be_skipped({"NOSTROMO_QA_SKIP_BUILD": "1"}, [True, False, True, True]))
        self.assertFalse(qa.build_can_be_skipped({"NOSTROMO_QA_SKIP_BUILD": "1"}, []))


class CloneBuildTests(unittest.TestCase):
    def test_the_clone_is_built_and_cloned_from_the_release_app_not_the_debug_split_dylib_build(self):
        src = read("scripts", "qa", "lib", "qa_instance.py")
        self.assertIn('["make", "mac-release"]', src)
        self.assertNotIn('["make", "mac"]', src)
        self.assertIn('"Products", "Release", "Nostromo.app"', src)
        self.assertNotIn('"Products", "Debug"', src)


class PlistTests(unittest.TestCase):
    def test_clone_gets_the_qa_bundle_id_and_keeps_everything_else(self):
        info = {"CFBundleIdentifier": "com.hammer.nostromo", "CFBundleName": "Nostromo", "LSUIElement": True}
        out = qa.rewrite_clone_plist(info)
        self.assertEqual(out["CFBundleIdentifier"], "com.hammer.nostromo.qa")
        self.assertEqual(out["CFBundleName"], "Nostromo")
        self.assertIs(out["LSUIElement"], True)

    def test_input_plist_is_not_mutated(self):
        info = {"CFBundleIdentifier": "com.hammer.nostromo", "X": 1}
        qa.rewrite_clone_plist(info)
        self.assertEqual(info, {"CFBundleIdentifier": "com.hammer.nostromo", "X": 1})


PS = """  PID COMMAND
  100 /usr/local/bin/nostromd
  200 /Applications/Nostromo.app/Contents/MacOS/Nostromo
  300 claude --output-format stream-json
  400 /usr/bin/vim notes.txt
  500 /tmp/nostromo-qa-abc/Nostromo.app/Contents/MacOS/Nostromo
  600 /repo/target/debug/nostromd --root /tmp/nostromo-qa-abc
  700 /opt/bin/claude -p
garbage line
"""


class ParseProcessesTests(unittest.TestCase):
    def test_finds_daemon_app_and_claude_only(self):
        found = {(p["pid"], p["name"]) for p in qa.parse_processes(PS)}
        self.assertEqual(found, {(100, "nostromd"), (200, "Nostromo"), (300, "claude"),
                                 (500, "Nostromo"), (600, "nostromd"), (700, "claude")})

    def test_lines_containing_the_qa_root_are_excluded(self):
        found = {p["pid"] for p in qa.parse_processes(PS, "/tmp/nostromo-qa-abc")}
        self.assertEqual(found, {100, 200, 300, 700})


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = self.tmp.name
        self.ns = os.path.join(self.home, ".nostromo")
        os.makedirs(os.path.join(self.ns, "approvals"))
        for n in qa.WATCHED_FILES:
            self.write(n, "original " + n)
        self.write("approvals/a.json", "{}")
        self.write("app-control.sock", "stand-in")
        self.ps = "  1 /bin/nostromd\n  2 /A/Nostromo.app/Contents/MacOS/Nostromo\n"
        self.defaults = "{ key = value; }"
        self.before = self.snap()

    def write(self, rel, text):
        with open(os.path.join(self.ns, rel), "w") as f:
            f.write(text)

    def snap(self, ps=None, defaults=None, qa_root=None):
        return qa.take_snapshot(self.home, self.ps if ps is None else ps,
                                self.defaults if defaults is None else defaults, qa_root)

    def test_unchanged_state_has_no_problems(self):
        self.assertEqual(qa.compare_snapshots(self.before, self.snap()), [])

    def test_each_watched_file_change_is_reported(self):
        for n in qa.WATCHED_FILES:
            with self.subTest(file=n):
                self.write(n, "tampered")
                self.assertTrue(any(n in p for p in qa.compare_snapshots(self.before, self.snap())))
                self.write(n, "original " + n)

    def test_watched_file_deleted_is_reported(self):
        os.remove(os.path.join(self.ns, "focuses.json"))
        self.assertTrue(qa.compare_snapshots(self.before, self.snap()))

    def test_new_approvals_file_is_reported(self):
        self.write("approvals/b.json", "{}")
        self.assertTrue(qa.compare_snapshots(self.before, self.snap()))

    def test_resized_approvals_file_is_reported(self):
        self.write("approvals/a.json", '{"grown": true}')
        self.assertTrue(qa.compare_snapshots(self.before, self.snap()))

    def test_replaced_control_socket_is_reported(self):
        p = os.path.join(self.ns, "app-control.sock")
        os.link(p, p + ".keep")  # keep the old inode alive so the replacement cannot reuse it
        self.addCleanup(os.remove, p + ".keep")
        os.remove(p)
        with open(p, "w") as f:
            f.write("stand-in")
        probs = qa.compare_snapshots(self.before, self.snap())
        self.assertTrue(any("app-control.sock" in x for x in probs))

    def test_control_socket_with_new_inode_is_reported(self):
        p = os.path.join(self.ns, "app-control.sock")
        before = dict(self.before, control_socket_inode=qa.socket_inode(p) + 12345)
        self.assertTrue(any("app-control.sock" in x for x in qa.compare_snapshots(before, self.snap())))

    def test_changed_defaults_are_reported(self):
        self.assertTrue(qa.compare_snapshots(self.before, self.snap(defaults="{ key = other; }")))

    def test_users_daemon_vanishing_is_reported(self):
        after = self.snap(ps="  2 /A/Nostromo.app/Contents/MacOS/Nostromo\n")
        self.assertTrue(any("nostromd" in x for x in qa.compare_snapshots(self.before, after)))

    def test_users_app_vanishing_is_reported(self):
        after = self.snap(ps="  1 /bin/nostromd\n")
        self.assertTrue(any("Nostromo" in x for x in qa.compare_snapshots(self.before, after)))

    def test_new_claude_process_is_reported(self):
        after = self.snap(ps=self.ps + "  9 claude -p\n")
        self.assertTrue(any("claude" in x for x in qa.compare_snapshots(self.before, after)))

    def test_qa_instances_own_processes_do_not_count(self):
        ps = self.ps + "  9 /tmp/qa-x/bin/claude -p\n  10 /tmp/qa-x/Nostromo.app/Contents/MacOS/Nostromo\n"
        self.assertEqual(qa.compare_snapshots(self.before, self.snap(ps=ps, qa_root="/tmp/qa-x")), [])

    def test_snapshot_tolerates_missing_nostromo_dir(self):
        empty = tempfile.mkdtemp()
        s = qa.take_snapshot(empty, "", "")
        self.assertEqual(qa.compare_snapshots(s, qa.take_snapshot(empty, "", "")), [])


class EnvTests(unittest.TestCase):
    ROOT_DIR = "/tmp/nostromo-qa-xyz"
    BASE = {"HOME": "/Users/real", "PATH": "/usr/bin", "SECRET_TOKEN": "s3cret",
            "NOSTROMO_APP_CONTROL_SOCKET": "/Users/real/.nostromo/app-control.sock"}

    def test_daemon_env(self):
        env = qa.daemon_env(self.ROOT_DIR, self.BASE, "/r/fake-claude", "/r/guard")
        home = self.ROOT_DIR + "/home"
        self.assertEqual(env["HOME"], home)
        self.assertEqual(env["NOSTROMO_QA_DAEMON"], "1")
        self.assertEqual(env["NOSTROMO_CLAUDE_BIN"], "/r/fake-claude")
        self.assertEqual(env["NOSTROMO_GUARD_BIN"], "/r/guard")
        self.assertTrue(env["NOSTROMO_APPROVALS_DIR"].startswith(home + os.sep))
        self.assertNotIn("SECRET_TOKEN", env)
        self.assertNotIn("/Users/real", "".join(env.values()))

    def test_daemon_env_trusts_the_clone_exe_as_operator_app(self):
        env = qa.daemon_env(self.ROOT_DIR, self.BASE, "f", "g")
        self.assertEqual(env["NOSTROMO_OPERATOR_APP_PATH"],
                         self.ROOT_DIR + "/Nostromo.app/Contents/MacOS/Nostromo")

    def test_app_env_synthetic_on(self):
        env = qa.app_env(self.ROOT_DIR, self.BASE, synthetic=True)
        self.assertEqual(env["NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT"], "1")
        self.assertEqual(env["NOSTROMO_APP_CONTROL_SOCKET"], self.ROOT_DIR + "/app-control.sock")
        self.assertEqual(env["HOME"], self.ROOT_DIR + "/home")
        self.assertNotIn("/Users/real", "".join(env.values()))

    def test_app_env_synthetic_off_omits_the_switch(self):
        env = qa.app_env(self.ROOT_DIR, self.BASE, synthetic=False)
        self.assertNotIn("NOSTROMO_QA_ALLOW_SYNTHETIC_INPUT", env)
        self.assertEqual(env["NOSTROMO_APP_CONTROL_SOCKET"], self.ROOT_DIR + "/app-control.sock")

    def test_old_terminal_input_name_is_never_used(self):
        for synthetic in (True, False):
            env = qa.app_env(self.ROOT_DIR, self.BASE, synthetic=synthetic)
            self.assertFalse([k for k in env if k.endswith("_TERMINAL_INPUT")])
        self.assertFalse([k for k in qa.daemon_env(self.ROOT_DIR, self.BASE, "f", "g") if k.endswith("_TERMINAL_INPUT")])


class SocketResolutionTests(unittest.TestCase):
    def test_arg_beats_env_beats_default(self):
        env = {"NOSTROMO_APP_CONTROL_SOCKET": "/env.sock"}
        self.assertEqual(cli.resolve_socket("/arg.sock", env), "/arg.sock")
        self.assertEqual(cli.resolve_socket(None, env), "/env.sock")
        self.assertEqual(cli.resolve_socket(None, {}), os.path.expanduser("~/.nostromo/app-control.sock"))

    def test_app_reads_the_same_env_var(self):
        self.assertIn("NOSTROMO_APP_CONTROL_SOCKET", read("macOS", "Nostromo", "AppControl", "AppControlServer.swift"))


class FakeClaudeTests(unittest.TestCase):
    def test_plain_turn_completes(self):
        with tempfile.TemporaryDirectory() as d:
            user = json.dumps({"type": "user", "message": {"role": "user", "content": "hello"}})
            r = subprocess.run([os.path.join(ROOT, "scripts", "qa", "fake-claude")], input=user + "\n",
                               text=True, capture_output=True, timeout=30,
                               env={"PATH": os.environ["PATH"], "FAKE_CLAUDE_LOG_DIR": d})
        self.assertEqual(r.returncode, 0, r.stderr)
        events = [json.loads(l) for l in r.stdout.splitlines() if l.strip()]
        types = [(e["type"], e.get("subtype")) for e in events]
        self.assertEqual(types[0], ("system", "init"))
        self.assertIn(("user", None), types)
        self.assertIn(("assistant", None), types)
        self.assertEqual(types[-1][0], "result")
        self.assertFalse(events[-1]["is_error"])
        text = [b["text"] for e in events if e["type"] == "assistant" for b in e["message"]["content"]]
        self.assertTrue(text and text[0])


class NoNetworkNoPatternKillTests(unittest.TestCase):
    NET = {"socket", "urllib", "http", "requests", "ssl", "asyncio", "ftplib", "smtplib"}

    def check_no_network(self, src):
        for node in ast.walk(ast.parse(src)):
            mods = []
            if isinstance(node, ast.Import):
                mods = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                mods = [node.module or ""]
            for m in mods:
                self.assertNotIn(m.split(".")[0], self.NET, f"imports {m}")
        self.assertIsNone(re.search(r"\burllib\b|\bsocket\.|__import__|https?\.client|\bimport requests", src))

    def test_fake_claude_perm_has_no_network_use(self):
        self.check_no_network(read("tests", "support", "fake_claude_perm.py"))

    def test_fake_claude_wrapper_has_no_network_use(self):
        src = read("scripts", "qa", "fake-claude")
        self.assertIsNone(re.search(r"\b(curl|wget|nc|urllib|requests|socket)\b", src))
        self.assertIn("fake_claude_perm.py", src)

    def test_qa_scripts_never_kill_by_pattern(self):
        for rel in ("approvals-qa-smoke.sh", "qa-instance.sh"):
            self.assertIsNone(re.search(r"\b(pkill|killall)\b", read("scripts", "qa", rel)), rel)
        self.assertIsNone(re.search(r"\b(pkill|killall)\b", read("scripts", "qa", "lib", "qa_instance.py")))

    def test_smoke_script_records_its_input_mode(self):
        src = read("scripts", "qa", "approvals-qa-smoke.sh")
        self.assertIn("synthetic input", src)
        self.assertIn("--no-synthetic", src)


class ResolveRootTests(unittest.TestCase):
    def test_refuses_a_dir_without_the_marker(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(SystemExit):
                qa.resolve_root(d)

    def test_accepts_a_marked_dir(self):
        with tempfile.TemporaryDirectory() as d:
            open(os.path.join(d, qa.ROOT_MARKER), "w").close()
            self.assertEqual(qa.resolve_root(d), os.path.realpath(d))


import hashlib, socket, threading  # noqa: E402


class ApprovalsAuditIsolationTests(unittest.TestCase):
    SECRET = "SECRET-PAYLOAD-xyzzy-7731"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = self.tmp.name
        self.ns = os.path.join(self.home, ".nostromo")
        self.appr = os.path.join(self.ns, "approvals")
        os.makedirs(self.appr)
        for n in qa.WATCHED_FILES:
            self.write(n, "original " + n)
        self.write("approvals/a.json", "{}")
        self.qa_root = "/tmp/qa-root-does-not-matter/instance-1"
        self.audit = "approvals/audit-2026-10-19.jsonl"
        self.write(self.audit, '{"n":1,"note":"%s"}\n{"n":2}\n' % self.SECRET)
        self.ps = "  1 /bin/nostromd\n  2 /A/Nostromo.app/Contents/MacOS/Nostromo\n"
        self.defaults = "{ key = value; }"
        self.before = self.snap()

    def write(self, rel, text, mode="w"):
        with open(os.path.join(self.ns, rel), mode) as f:
            f.write(text)

    def snap(self):
        return qa.take_snapshot(self.home, self.ps, self.defaults, self.qa_root)

    def problems(self):
        return qa.compare_snapshots(self.before, self.snap(), approvals_dir=self.appr, qa_root=self.qa_root)

    def test_snapshot_records_audit_length_and_sha256_never_contents(self):
        data = open(os.path.join(self.ns, self.audit), "rb").read()
        entry = self.before["approvals_audit"]["audit-2026-10-19.jsonl"]
        self.assertEqual(entry["len"], len(data))
        self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
        self.assertNotIn(self.SECRET, json.dumps(self.before))

    def test_audit_files_are_not_in_the_plain_approvals_listing(self):
        self.assertNotIn("audit-2026-10-19.jsonl", json.dumps(self.before["approvals"]))

    def test_append_only_audit_growth_is_not_a_problem(self):
        self.write(self.audit, '{"n":3,"note":"real user approval elsewhere"}\n', "a")
        self.assertEqual(self.problems(), [])

    def test_unchanged_audit_is_not_a_problem(self):
        self.assertEqual(self.problems(), [])

    def test_a_marker_split_across_the_snapshot_boundary_is_found(self):
        self.write(self.audit, '{"n":3,"cmd":"FIXT', "a")  # the daemon was mid-line when the snapshot was taken
        self.before = self.snap()
        self.write(self.audit, 'URE:simple_rm"}\n', "a")
        self.assertTrue(any("FIXTURE" in p for p in self.problems()))

    def test_rewriting_the_old_prefix_and_appending_is_a_problem(self):
        p = os.path.join(self.ns, self.audit)
        data = open(p, "rb").read()
        with open(p, "wb") as f:
            f.write(b"X" + data[1:] + b'{"n":3}\n')
        self.assertTrue(self.problems())

    def test_rewriting_the_old_prefix_at_same_length_is_a_problem(self):
        p = os.path.join(self.ns, self.audit)
        data = open(p, "rb").read()
        with open(p, "wb") as f:
            f.write(b"X" + data[1:])
        self.assertTrue(self.problems())

    def test_shrunk_audit_file_is_a_problem(self):
        p = os.path.join(self.ns, self.audit)
        data = open(p, "rb").read()
        with open(p, "wb") as f:
            f.write(data[:10])
        self.assertTrue(self.problems())

    def test_deleted_audit_file_is_a_problem(self):
        os.remove(os.path.join(self.ns, self.audit))
        self.assertTrue(self.problems())

    def test_appended_line_carrying_a_qa_marker_is_a_problem_that_does_not_echo_the_line(self):
        markers = [self.qa_root + "/home/x", "FIXTURE:simple_rm", "com.hammer.nostromo.qa"]
        for m in markers:
            with self.subTest(marker=m):
                self.setUp()
                line = '{"n":3,"cmd":"%s","leak":"UNIQUE-LINE-BODY-4242"}\n' % m
                self.write(self.audit, line, "a")
                probs = self.problems()
                self.assertTrue(probs)
                blob = "\n".join(probs)
                self.assertNotIn("UNIQUE-LINE-BODY-4242", blob)
                self.assertNotIn(line.strip(), blob)
                self.assertNotIn(self.SECRET, blob)

    def test_new_non_audit_approvals_file_is_a_problem(self):
        self.write("approvals/b.json", "{}")
        self.assertTrue(self.problems())

    def test_new_dated_audit_file_without_qa_marker_is_not_a_problem(self):
        self.write("approvals/audit-2026-10-20.jsonl", '{"n":1,"cmd":"ls"}\n')
        self.assertEqual(self.problems(), [])

    def test_new_dated_audit_file_with_qa_marker_is_a_problem(self):
        for m in [self.qa_root, "FIXTURE:simple_rm", "com.hammer.nostromo.qa"]:
            with self.subTest(marker=m):
                self.setUp()
                self.write("approvals/audit-2026-10-20.jsonl", '{"cmd":"%s"}\n' % m)
                self.assertTrue(self.problems())

    def test_other_guard_rules_still_apply_with_audit_present(self):
        self.write("focuses.json", "tampered")
        self.assertTrue(self.problems())


def _mk_qa_root(marker=True):
    d = tempfile.mkdtemp(dir="/tmp", prefix="qh")
    if marker:
        open(os.path.join(d, ".nostromo-qa-root"), "w").close()
    return d


class SocketPathGuardTests(unittest.TestCase):
    def setUp(self):
        self.root = _mk_qa_root()
        self.outside = tempfile.mkdtemp(dir="/tmp", prefix="qo")
        import shutil
        self.addCleanup(shutil.rmtree, self.root, True)
        self.addCleanup(shutil.rmtree, self.outside, True)

    def test_path_inside_a_marked_root_returns_its_realpath(self):
        p = os.path.join(self.root, "mcp.sock")
        self.assertEqual(qa.guard_socket_path(self.root, p), os.path.realpath(p))

    def test_path_outside_the_root_is_refused(self):
        with self.assertRaises(ValueError):
            qa.guard_socket_path(self.root, os.path.join(self.outside, "mcp.sock"))

    def test_dotdot_escape_is_refused(self):
        with self.assertRaises(ValueError):
            qa.guard_socket_path(self.root, os.path.join(self.root, "..", os.path.basename(self.outside), "mcp.sock"))

    def test_symlink_inside_the_root_pointing_outside_is_refused(self):
        link = os.path.join(self.root, "mcp.sock")
        os.symlink(os.path.join(self.outside, "mcp.sock"), link)
        with self.assertRaises(ValueError):
            qa.guard_socket_path(self.root, link)

    def test_root_without_the_marker_is_refused(self):
        bare = _mk_qa_root(marker=False)
        self.addCleanup(__import__("shutil").rmtree, bare, True)
        with self.assertRaises(ValueError):
            qa.guard_socket_path(bare, os.path.join(bare, "mcp.sock"))

    def test_path_under_the_users_real_nostromo_dir_is_refused(self):
        with self.assertRaises(ValueError):
            qa.guard_socket_path(self.root, os.path.expanduser("~/.nostromo/mcp.sock"))


class FakeMcpServer:
    """AF_UNIX listener speaking the daemon's newline-delimited JSON protocol."""

    def __init__(self, path, outcome):
        self.path, self.outcome = path, outcome
        self.lines, self.accepted = [], 0
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(path)
        self.sock.listen(4)
        self.sock.settimeout(10)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except (OSError, socket.timeout):
                return
            self.accepted += 1
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        conn.settimeout(10)
        buf = b""
        try:
            while True:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    if not raw.strip():
                        continue
                    msg = json.loads(raw)
                    self.lines.append(msg)
                    self._reply(conn, msg)
        except (OSError, socket.timeout, ValueError):
            return
        finally:
            conn.close()

    def _reply(self, conn, msg):
        if not isinstance(msg, dict) or "id" not in msg:
            return
        if msg.get("method") == "initialize":
            result = {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fake", "version": "0"}}
        else:
            result = {"content": [{"type": "text", "text": json.dumps(self.outcome)}]}
        conn.sendall((json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": result}) + "\n").encode())

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class McpCreateFocusTests(unittest.TestCase):
    def setUp(self):
        import shutil
        self.root = _mk_qa_root()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.servers = []
        self.dirs = []

    def tearDown(self):
        import shutil
        for s in self.servers:
            s.close()
        for d in self.dirs:
            shutil.rmtree(d, True)

    def serve(self, path, outcome):
        s = FakeMcpServer(path, outcome)
        self.servers.append(s)
        return s

    def test_creates_a_focus_over_the_qa_roots_mcp_socket_and_returns_the_outcome(self):
        outcome = {"kind": "created", "focus_id": "cody-qa-approvals", "label": "QA approvals"}
        srv = self.serve(os.path.join(self.root, "mcp.sock"), outcome)
        got = qa.mcp_create_focus(self.root, "/tmp/some-cwd", timeout=10)
        self.assertEqual(got, outcome)
        self.assertEqual(srv.lines[0], {"type": "hello"})
        methods = [m.get("method") for m in srv.lines[1:]]
        self.assertEqual(methods[0], "initialize")
        self.assertIn("tools/call", methods)
        self.assertLess(methods.index("initialize"), methods.index("tools/call"))
        call = next(m for m in srv.lines if m.get("method") == "tools/call")
        self.assertEqual(call["params"]["name"], "nostromo.create_focus")
        args = call["params"]["arguments"]
        self.assertEqual(args["agent"], "cody")
        self.assertEqual(args["title"], "qa-approvals")
        self.assertEqual(args["label"], "QA approvals")
        self.assertEqual(args["working_directory"], "/tmp/some-cwd")

    def test_passes_custom_label_title_and_agent_through(self):
        srv = self.serve(os.path.join(self.root, "mcp.sock"), {"kind": "created", "focus_id": "x"})
        qa.mcp_create_focus(self.root, "/w", label="L", title="t", agent="marty", timeout=10)
        args = next(m for m in srv.lines if m.get("method") == "tools/call")["params"]["arguments"]
        self.assertEqual((args["label"], args["title"], args["agent"]), ("L", "t", "marty"))

    def test_an_error_payload_raises_runtime_error(self):
        self.serve(os.path.join(self.root, "mcp.sock"), {"error": "spawn_failed", "detail": "x"})
        with self.assertRaises(RuntimeError):
            qa.mcp_create_focus(self.root, "/w", timeout=10)

    def test_never_connects_to_a_socket_outside_the_qa_root_even_via_symlink(self):
        outside = tempfile.mkdtemp(dir="/tmp", prefix="qo")
        self.dirs.append(outside)
        srv = self.serve(os.path.join(outside, "mcp.sock"), {"kind": "created", "focus_id": "x"})
        os.symlink(os.path.join(outside, "mcp.sock"), os.path.join(self.root, "mcp.sock"))
        with self.assertRaises(ValueError):
            qa.mcp_create_focus(self.root, "/w", timeout=3)
        threading.Event().wait(0.3)
        self.assertEqual(srv.accepted, 0)
        self.assertEqual(srv.lines, [])

    def test_a_root_without_the_marker_raises_and_connects_nowhere(self):
        bare = _mk_qa_root(marker=False)
        self.dirs.append(bare)
        srv = self.serve(os.path.join(bare, "mcp.sock"), {"kind": "created", "focus_id": "x"})
        with self.assertRaises(ValueError):
            qa.mcp_create_focus(bare, "/w", timeout=3)
        threading.Event().wait(0.3)
        self.assertEqual(srv.accepted, 0)


class ApprovalsCardScriptShapeTests(unittest.TestCase):
    def setUp(self):
        self.sh = read("scripts", "qa", "approvals-card.sh")

    def test_a_focus_is_created_before_the_first_cue_is_sent(self):
        self.assertIn('"$instance" focus', self.sh)
        self.assertLess(self.sh.index('"$instance" focus'), self.sh.index('send_cue "$fixture"'))

    def test_the_message_box_is_awaited_before_the_cue_is_sent(self):
        self.assertIn('wait "Message', self.sh)
        self.assertLess(self.sh.index('wait "Message'), self.sh.index('send_cue "$fixture"'))

    def test_a_debug_evidence_dump_exists_and_covers_the_key_sources(self):
        for needle in ["windows", "tree --depth 3", "window-placement.log", "nostromd.log", "approvals"]:
            with self.subTest(needle=needle):
                self.assertIn(needle, self.sh)

    def test_the_debug_evidence_function_is_invoked_on_fail_paths(self):
        m = re.search(r"^\s*(?:function\s+)?(\w*(?:debug|evidence|dump)\w*)\s*\(\)", self.sh, re.M | re.I)
        self.assertIsNotNone(m, "no debug/evidence function defined")
        name = m.group(1)
        calls = [l for l in self.sh.splitlines() if re.search(r"\b%s\b" % name, l) and "()" not in l]
        self.assertTrue(calls, "evidence function is never invoked")
        fails = [i for i, l in enumerate(self.sh.splitlines()) if "FAIL" in l]
        self.assertTrue(fails)
        lines = self.sh.splitlines()
        near = any(re.search(r"\b%s\b" % name, "\n".join(lines[max(0, i - 4):i + 5])) for i in fails)
        self.assertTrue(near, "evidence function is not called near a FAIL path")

    def test_cards_are_matched_by_content(self):
        self.assertIn("wait_card_for", self.sh)

    def test_allow_is_clicked_only_after_waiting_for_enabled(self):
        self.assertLess(self.sh.index('wait_allow "$rid"'), self.sh.index('click_card_button "$rid" "Allow once"'))

    def test_deny_and_allow_are_never_clicked_by_a_substring_text_match(self):
        # `ctl click --text` is a case-insensitive substring match: it could hit "Deny & stop". The only
        # --text "Allow once" left is the --no-synthetic refusal probe, which clicks nothing but that text.
        code = "\n".join(l for l in self.sh.splitlines() if not l.lstrip().startswith("#"))
        self.assertNotRegex(code, r'click --text "Deny')
        self.assertEqual(code.count('click --text "Allow once"'), 1)
        self.assertIn('"Deny"', code)

    def test_the_text_drawn_proof_is_pixels_and_screenshots_live_in_a_private_dir(self):
        self.assertIn("text not drawn", read("scripts", "qa", "lib", "card_checks.py"))
        self.assertIn("mktemp -d", self.sh)
        self.assertNotIn("/tmp/qa-card-", self.sh)
        self.assertIn('prove_drawn "$rid" "$fixture"', self.sh)
        self.assertIn('"$checks" prove', self.sh)

    def test_the_card_text_view_is_focused_and_the_key_target_recorded_before_the_end_key(self):
        i_focus = self.sh.index('focus_card_text "$rid"')
        i_key = self.sh.index('key "$(printf')
        self.assertLess(i_focus, i_key)
        self.assertIn("key target", self.sh)

    # ---- round 3

    def code(self):
        return "\n".join(l for l in self.sh.splitlines() if not l.lstrip().startswith("#"))

    def test_the_allow_check_reads_the_log_chosen_by_content_not_the_first_responses_file(self):
        code = self.code()
        self.assertNotIn("find \"$root\" -name responses.jsonl", code)
        self.assertNotIn("head -1)\"\n          echo \"--- fake CLI log", code)
        self.assertIn('"$checks" fakelog "$root"', code)
        self.assertIn("seq 1 20", code[code.index("fake_cli_allowed() {"):])   # polls 20 x 0.25 s = 5 s

    def test_the_composer_is_refocused_before_every_cue(self):
        code = self.code()
        body = code[code.index("send_cue() {"):]
        body = body[:body.index("\n}\n")]
        self.assertIn("focus_composer", body)
        self.assertLess(body.index("focus_composer"), body.index("ctl type"))
        fc = code[code.index("focus_composer() {"):code.index("send_cue() {")]
        for needle in ("wait_cards gone", 'click --text "Message', "hittest", '"$checks" composer', "1 2 3", "10"):
            with self.subTest(needle=needle):
                self.assertIn(needle, fc)
        self.assertNotIn("activate", fc)
        self.assertIn("last seen: $composer_seen", code)

    def test_every_fixture_gets_its_own_instance_in_both_modes(self):
        code = self.code()
        loop = code[code.index('for fixture in "${fixtures[@]}"; do'):]
        self.assertLess(loop.index("start_instance"), loop.index('run_fixture "$fixture"'))
        self.assertLess(loop.index('run_fixture "$fixture"'), loop.index("stop_instance"))
        self.assertNotIn('"$synthetic"', loop)          # no mode switch: one instance per fixture either way
        self.assertNotIn("if [ \"$instance_up\" = 0 ]", loop)
        self.assertNotIn("clear_cards", code)           # no cross-fixture clearing is needed any more

    def test_a_gated_card_is_refused_via_the_exact_deny_button_and_stays_pending(self):
        code = self.code()
        run = code[code.index("run_fixture() {"):]
        gated = run[run.index('= gated ]'):run.index("synthetic answers refused")]
        self.assertIn('click_card_button "$rid" "Deny"', gated)
        self.assertIn('focus_card_text "$rid"', gated)
        self.assertIn("--key-code 36", gated)
        self.assertIn("--key-code 49", gated)
        self.assertIn("wait_cards present", run)
        self.assertIn("card still pending", gated)

    def test_failed_fixtures_are_failed_and_aborted_is_only_for_fixtures_that_did_not_run(self):
        code = self.code()
        run = code[code.index("run_fixture() {"):code.index('for fixture in "${fixtures[@]}"; do')]
        self.assertNotIn("ABORTED", run)
        self.assertIn("-- FAILED:", code)
        self.assertEqual(code.count("ABORTED"), 1)      # report() only

    def test_start_adopts_the_root_early_and_on_exit_tolerates_a_missing_rc(self):
        code = self.code()
        self.assertIn("adopt_root", code[code.index("on_exit() {"):])
        self.assertIn('|| rc=1', code[code.index("on_exit() {"):])
        self.assertIn('>"$work/start.out"', code)

    def test_the_default_fixtures_include_bidi(self):
        self.assertIn("fixtures=(simple_rm heredoc_300 bidi)", self.sh)

    def test_no_synthetic_reports_the_gated_allow_label_for_heredoc_300(self):
        run = self.code()
        run = run[run.index("run_fixture() {"):]
        tail = run[run.index("synthetic answers refused") - 1500:run.index("synthetic answers refused")]
        self.assertIn("Allow label gated", run)
        self.assertIn("Scroll to the end to allow", tail + run[run.index("Allow label gated") - 400:])

    def test_every_exit_path_prints_summaries_and_a_result_line_before_the_evidence(self):
        code = self.code()
        rep = code[code.index("report() {"):code.index("finish() {")]
        self.assertIn("ABORTED:", rep)
        self.assertLess(rep.index("RESULT:"), rep.index("evidence_file"))
        self.assertIn("INCONCLUSIVE", rep)
        for call in ("finish 3", "finish 0", "finish 1"):
            self.assertIn(call, code)
        exit_fn = code[code.index("on_exit() {"):]
        self.assertIn("report 1", exit_fn)      # an unexpected set -e death still gets a RESULT
        self.assertIn("trap on_exit EXIT", code)

    def test_the_readme_documents_round_3_behaviour(self):
        readme = read("scripts", "qa", "README.md")
        for needle in ("one QA instance per fixture", "stdin.jsonl", "RESULT:", "ChatTextView"):
            with self.subTest(needle=needle):
                self.assertIn(needle, readme)

    def test_the_readme_documents_keeping_the_session_for_inspection(self):
        readme = read("scripts", "qa", "README.md")
        self.assertIn("KEEP=1", readme)
        self.assertIn("session", readme.lower())

    def test_the_readme_describes_the_pixel_proof_not_the_old_find_proof(self):
        readme = read("scripts", "qa", "README.md")
        self.assertIn("glyph", readme)
        self.assertIn("text in view tree", readme)
        self.assertNotIn("Known limit: `approvals list` has no card frame", readme)

    def run_script(self, *args):
        with tempfile.TemporaryDirectory() as home:
            env = {"HOME": home, "PATH": os.environ.get("PATH", "")}
            return subprocess.run(["bash", os.path.join(ROOT, "scripts", "qa", "approvals-card.sh"), *args],
                                  env=env, capture_output=True, text=True, timeout=60)

    def test_fixture_names_outside_the_safe_pattern_exit_2_before_anything_starts(self):
        for bad in ("../x", "a/b", "Simple", "a b", "x;y", ""):
            with self.subTest(name=bad):
                r = self.run_script(bad)
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertNotIn("QA_ROOT=", r.stdout)

    def test_an_unknown_fixture_exits_2(self):
        r = self.run_script("no_such_fixture")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertIn("no_such_fixture", r.stderr)


class ApprovalsCardReportTests(unittest.TestCase):
    """report/on_exit/finish from the script, with stubbed stop_instance and a scratch work dir."""

    def run_fns(self, body, work_rc=True):
        with tempfile.TemporaryDirectory() as d:
            script = r'''
set -uo pipefail
repo=%(root)s; work=%(d)s; synthetic=0
root=/nowhere; instance_up=1; verdict=PASS; fail_count=0; inst_fail_base=0; abort_reason=""; reported=0
fixtures_done=0; force_evidence=0; evidence_file="$work/ev"; : >"$evidence_file"
fixtures=(a b c)
eval "$(sed -n '/^report() {/,/^trap on_exit EXIT/p' "$repo/scripts/qa/approvals-card.sh" | sed '$d')"
remove_work() { :; }
adopt_root() { :; }
stop_instance() { echo "stopped"; instance_up=0; }
trap on_exit EXIT
%(body)s
''' % {"root": json.dumps(ROOT), "d": json.dumps(d), "body": body}
            return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)

    def test_a_fixture_that_did_not_run_is_aborted_with_the_reason(self):
        r = self.run_fns('fixtures_done=1; abort_reason="boom"; verdict=FAIL; finish 1')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertNotIn("SUMMARY a:", r.stdout)
        self.assertIn("SUMMARY b: ABORTED: boom", r.stdout)
        self.assertIn("SUMMARY c: ABORTED: boom", r.stdout)
        self.assertIn("RESULT: FAIL", r.stdout)
        self.assertIn("stopped", r.stdout)

    def test_an_unexpected_death_still_tears_down_and_prints_a_result(self):
        r = self.run_fns('false; exit 7')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("stopped", r.stdout)
        self.assertIn("RESULT: FAIL", r.stdout)
        self.assertIn("ABORTED: script error (exit 7)", r.stdout)

    def test_a_missing_rc_file_does_not_break_on_exit_or_finish(self):
        r = self.run_fns('reported=1; exit 5')          # on_exit with nothing reported keeps the exit code
        self.assertEqual(r.returncode, 5, r.stdout + r.stderr)
        r = self.run_fns('report() { reported=1; }; abort_reason=x; finish 0')   # report never wrote $work/rc
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_inconclusive_is_exit_3_and_a_fail_outranks_it(self):
        r = self.run_fns('finish 3')
        self.assertEqual(r.returncode, 3)
        self.assertIn("RESULT: INCONCLUSIVE", r.stdout)
        r = self.run_fns('verdict=FAIL; finish 3')
        self.assertEqual(r.returncode, 1)


def _png(width, height, pixel):
    """A tiny RGB PNG (filter 0), `pixel(x, y)` -> (r, g, b)."""
    raw = b"".join(b"\0" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def _node(cls, x, y, w, h, text=None, children=None):
    n = {"class": cls, "frame": {"x": x, "y": y, "w": w, "h": h}}
    if text:
        n["text"] = text
    if children:
        n["children"] = children
    return n


CARD_TREE = _node("NSView", 0, 0, 200, 150, children=[_node("ApprovalCardView", 10, 10, 180, 120, children=[
    _node("ApprovalInputView", 10, 20, 180, 60, children=[
        _node("NSClipView", 30, 20, 160, 60, children=[_node("ApprovalTextView", 30, 20, 160, 400, "rm -rf /tmp/x/a")])]),
    _node("NSView", 10, 100, 180, 26, children=[
        _node("ApprovalButton", 10, 100, 50, 26, "Deny"),
        _node("ApprovalButton", 70, 100, 40, 26, "Deny & stop"),
        _node("ApprovalButton", 120, 100, 60, 26, "Allow once")])])])


def _card(rid, text):
    return {"request_id": rid, "input": text, "lines": [{"number": 1, "text": text}], "windows": [0],
            "options": [{"id": "allow_once", "enabled": True, "label": "Allow once"}]}


class ApprovalsCardShellFunctionTests(unittest.TestCase):
    """Runs the script's own helper functions against a stubbed `ctl` (canned JSON; clicks are logged)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.d = self.tmp.name

    def put(self, name, data):
        mode = "wb" if isinstance(data, bytes) else "w"
        with open(os.path.join(self.d, name), mode) as f:
            f.write(data if isinstance(data, bytes) else json.dumps(data))

    def run_fn(self, call, listing, png=None, label_hits=None, tree=CARD_TREE, find_hits=None, after=None):
        if after is not None:
            self.put("listing.after.json", {"approvals": after})
        self.put("tree.json", tree)
        self.put("listing.json", {"approvals": listing})
        self.put("find.json", find_hits if find_hits is not None else [{"class": "ApprovalTextView",
                                                                         "frame": {"x": 30, "y": 20, "w": 160, "h": 400}}])
        self.put("label.json", label_hits if label_hits is not None else [{"class": "NSTableRowView"}])
        if png is not None:
            self.put("shot.png", png)
        script = r'''
set -euo pipefail
repo=%(root)s; D=%(d)s; checks="$repo/scripts/qa/lib/card_checks.py"
work="$D/work"; mkdir -p "$work"; label=QA; fixture=t; verdict=PASS
fail() { verdict=FAIL; echo "FAIL: $*"; }
ctl() {
  echo "ctl $*" >>"$D/calls.log"
  while [ "${1:-}" = -w ]; do shift 2; done
  case "$1" in
    tree) cat "$D/tree.json" ;;
    find) if [ "$2" = QA ]; then cat "$D/label.json"; else cat "$D/find.json"; fi ;;
    screenshot) if [ -f "$D/shot.png" ]; then cp "$D/shot.png" "$2"; else echo no >&2; return 1; fi ;;
    approvals) if [ -f "$D/clicked" ] && [ -f "$D/listing.after.json" ]; then cat "$D/listing.after.json"; else cat "$D/listing.json"; fi ;;
    click) touch "$D/clicked"; echo '{}' ;;
    *) echo '{}' ;;
  esac
}
listing_json() { ctl approvals list; }
wait_cards() { return 0; }
eval "$(sed -n '/^fixture_command() {/,/^for fixture in/p' "$repo/scripts/qa/approvals-card.sh" | sed '$d')"
%(call)s
''' % {"root": json.dumps(ROOT), "d": json.dumps(self.d), "call": call}
        return subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)

    def clicks(self):
        try:
            with open(os.path.join(self.d, "calls.log")) as f:
                return [l.strip() for l in f if " click " in l]
        except FileNotFoundError:
            return []

    def test_deny_clicks_the_exact_deny_button_never_deny_and_stop(self):
        r = self.run_fn('click_card_button r1 Deny', [_card("r1", "rm -rf /tmp/x/a")])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.clicks(), ["ctl -w 0 click 35 113"])   # Deny's centre (10+50/2, 100+26/2)

    def test_a_missing_button_clicks_nothing_and_fails(self):
        r = self.run_fn('click_card_button r1 "Nope"', [_card("r1", "rm -rf /tmp/x/a")])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.clicks(), [])
        self.assertIn("no button titled", r.stdout)

    def test_a_card_not_visible_in_the_tree_is_never_clicked(self):
        r = self.run_fn('click_card_button r2 Deny', [_card("r1", "rm -rf /tmp/x/a"), _card("r2", "ls -la /elsewhere")])
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.clicks(), [])

    def test_the_session_surviving_a_deny_is_checked_on_its_sidebar_row(self):
        ok = self.run_fn('session_survives', [_card("r1", "x")])
        self.assertEqual(ok.returncode, 0, ok.stdout + ok.stderr)
        gone = self.run_fn('session_survives', [_card("r1", "x")], label_hits=[])
        self.assertNotEqual(gone.returncode, 0)

    def test_deny_and_assert_passes_when_the_request_goes_and_the_session_row_stays(self):
        r = self.run_fn('deny_and_assert r1 || true; echo "verdict=$verdict"', [_card("r1", "rm -rf /tmp/x/a")], after=[])
        self.assertIn("verdict=PASS", r.stdout, r.stdout + r.stderr)
        self.assertIn("survived", r.stdout)

    def test_deny_and_assert_fails_loudly_when_the_session_disappears(self):
        r = self.run_fn('deny_and_assert r1 || true; echo "verdict=$verdict"', [_card("r1", "rm -rf /tmp/x/a")], after=[],
                        label_hits=[])
        self.assertIn("verdict=FAIL", r.stdout, r.stdout + r.stderr)
        self.assertIn("SESSION DISAPPEARED", r.stdout)

    def test_deny_and_assert_fails_when_the_request_is_still_listed(self):
        r = self.run_fn('deny_and_assert r1 || true; echo "verdict=$verdict"', [_card("r1", "rm -rf /tmp/x/a")])
        self.assertIn("verdict=FAIL", r.stdout, r.stdout + r.stderr)
        self.assertIn("still listed", r.stdout)

    def test_two_matching_cards_are_ambiguous_and_never_picked_by_position(self):
        r = self.run_fn('rc=0; out="$(wait_card_for "echo ")" || rc=$?; echo "rc=$rc $out"',
                        [_card("a", "echo one"), _card("b", "echo two")])
        self.assertIn("rc=4", r.stdout)
        self.assertIn("ambiguous card selection", r.stdout)

    def test_prove_drawn_fails_on_a_blank_screenshot(self):
        r = self.run_fn('prove_drawn r1 t && echo PASSED || echo "FAILED: $drawn_why"', [_card("r1", "rm -rf /tmp/x/a")],
                        png=_png(400, 300, lambda x, y: (20, 20, 20)))
        self.assertIn("FAILED", r.stdout)
        self.assertIn("text area is blank", r.stdout)
        self.assertNotIn("PASSED", r.stdout)

    def test_prove_drawn_passes_with_glyph_pixels_in_the_text_area(self):
        light = lambda x, y: (230, 230, 230) if 60 <= x < 200 and 60 <= y < 80 else (20, 20, 20)  # noqa: E731
        r = self.run_fn('prove_drawn r1 t && echo PASSED || echo "FAILED: $drawn_why"', [_card("r1", "rm -rf /tmp/x/a")],
                        png=_png(400, 300, light))
        self.assertIn("PASSED", r.stdout, r.stdout + r.stderr)
        self.assertIn("text drawn", r.stdout)

    def test_prove_drawn_fails_closed_on_a_corrupt_or_missing_screenshot(self):
        good = _png(400, 300, lambda x, y: (230, 230, 230) if 60 <= x < 200 and 60 <= y < 80 else (20, 20, 20))
        for name, png in (("truncated", good[:70]), ("garbage", b"not a png at all" * 8), ("missing", None)):
            with self.subTest(png=name):
                r = self.run_fn('prove_drawn r1 t && echo PASSED || echo "FAILED: $drawn_why"', [_card("r1", "rm -rf /tmp/x/a")],
                                png=png)
                self.assertNotIn("PASSED", r.stdout)
                self.assertIn("could not read screenshot", r.stdout)
            try:
                os.remove(os.path.join(self.d, "shot.png"))
            except FileNotFoundError:
                pass

    def test_prove_drawn_fails_when_the_card_text_area_cannot_be_located(self):
        r = self.run_fn('prove_drawn r1 t && echo PASSED || echo "FAILED: $drawn_why"', [_card("r1", "rm -rf /tmp/x/a")],
                        png=_png(400, 300, lambda x, y: (230, 230, 230) if 60 <= x < 200 and 60 <= y < 80 else (20, 20, 20)),
                        tree=_node("NSView", 0, 0, 200, 150, children=[_node("ApprovalOverlayHost", 0, 0, 200, 150)]))
        self.assertNotIn("PASSED", r.stdout)
        self.assertIn("cannot locate the card text area", r.stdout)
        self.assertIn("tree excerpt", r.stdout)
        self.assertIn("ApprovalOverlayHost", r.stdout)

    def test_prove_drawn_keeps_its_files_in_the_work_directory(self):
        self.run_fn('prove_drawn r1 t || true', [_card("r1", "rm -rf /tmp/x/a")],
                    png=_png(400, 300, lambda x, y: (20, 20, 20)))
        self.assertTrue(os.path.exists(os.path.join(self.d, "work", "t.png")))
        self.assertTrue(os.path.exists(os.path.join(self.d, "work", "t.tree.json")))
        with open(os.path.join(self.d, "calls.log")) as f:
            calls = f.read()
        self.assertNotIn("/tmp/qa-card", calls)
        self.assertIn(os.path.join(self.d, "work", "t.png"), calls)


# ---- QHI: the QA app must never write into the user's real ~/.nostromo ----

MARKER_KINDS = {
    "fixture": "FIXTURE:simple_rm",
    "bundle": "com.hammer.nostromo.qa",
    "qa_root": "/tmp/nostromo-qa-abc123/home",
    "cody_tag": "cody-qa-xyz",
    "title": "qa-approvals",
}


class AppEnvQAHomeTests(unittest.TestCase):
    ROOT_DIR = "/tmp/nostromo-qa-xyz"
    BASE = {"HOME": "/Users/real", "PATH": "/usr/bin"}

    def test_app_env_points_the_app_at_a_home_inside_the_qa_root(self):
        for synthetic in (True, False):
            with self.subTest(synthetic=synthetic):
                env = qa.app_env(self.ROOT_DIR, self.BASE, synthetic=synthetic)
                self.assertEqual(env["NOSTROMO_QA_HOME"], self.ROOT_DIR + "/home")
                self.assertEqual(os.path.commonpath([env["NOSTROMO_QA_HOME"], self.ROOT_DIR]), self.ROOT_DIR)


class StateFileGuardTests(unittest.TestCase):
    SECRET = "SECRET-PAYLOAD-xyzzy-4412"
    QA_ROOT = "/tmp/nostromo-qa-abc123"
    LOG = "logs/window-placement.log"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = self.tmp.name
        self.ns = os.path.join(self.home, ".nostromo")
        os.makedirs(os.path.join(self.ns, "approvals"))
        os.makedirs(os.path.join(self.ns, "logs"))
        for n in qa.WATCHED_FILES:
            self.write(n, "original " + n)
        self.write("daemon-sessions-extra.json", '{"a":1}\n')
        self.write(self.LOG, "line one\nline two\n")
        self.ps = "  1 /bin/nostromd\n"
        self.before = self.snap()

    def write(self, rel, text, mode="w"):
        with open(os.path.join(self.ns, rel), mode) as f:
            f.write(text)

    def snap(self):
        return qa.take_snapshot(self.home, self.ps, "", self.QA_ROOT)

    def problems(self, nostromo_dir=True):
        return qa.compare_snapshots(self.before, self.snap(), os.path.join(self.ns, "approvals"), self.QA_ROOT,
                                    self.ns if nostromo_dir else None)

    def marker(self, kind):
        m = MARKER_KINDS[kind]
        return self.QA_ROOT + "/home" if kind == "qa_root" else m

    def assertClean(self, problems=None):
        self.assertEqual(self.problems() if problems is None else problems, [])

    def assertNoLeak(self, problems):
        joined = "\n".join(problems)
        self.assertNotIn(self.SECRET, joined)

    def test_snapshot_holds_only_length_and_hash_of_state_files(self):
        self.write("daemon-sessions-extra.json", '{"k":"%s"}' % self.SECRET)
        snap = self.snap()
        entry = snap["state_files"]["daemon-sessions-extra.json"]
        self.assertEqual(set(entry), {"len", "sha256"})
        self.assertNotIn(self.SECRET, json.dumps(snap))
        self.assertIn(self.LOG, snap["state_files"])
        for n in qa.WATCHED_FILES:
            self.assertNotIn(n, snap["state_files"])

    def test_unchanged_state_is_clean(self):
        self.assertClean()

    def test_a_top_level_json_rewritten_without_a_marker_is_fine(self):
        self.write("daemon-sessions-extra.json", '{"a":2,"note":"%s"}' % self.SECRET)
        self.assertClean()

    def test_a_top_level_json_rewritten_with_each_marker_kind_is_a_problem(self):
        for kind in MARKER_KINDS:
            with self.subTest(kind=kind):
                self.write("daemon-sessions-extra.json", '{"x":"%s %s"}' % (self.SECRET, self.marker(kind)))
                probs = self.problems()
                self.assertTrue(any("daemon-sessions-extra.json" in p for p in probs), probs)
                self.assertNoLeak(probs)

    def test_a_log_appended_without_a_marker_is_fine(self):
        self.write(self.LOG, "ordinary %s\n" % self.SECRET, "a")
        self.assertClean()

    def test_a_log_appended_with_each_marker_kind_is_a_problem(self):
        with open(os.path.join(self.ns, self.LOG)) as f:
            original = f.read()
        for kind in MARKER_KINDS:
            with self.subTest(kind=kind):
                self.write(self.LOG, original + "%s %s\n" % (self.SECRET, self.marker(kind)))
                probs = self.problems()
                self.assertTrue(any(self.LOG in p for p in probs), probs)
                self.assertNoLeak(probs)

    def test_a_marker_already_in_the_old_bytes_is_not_blamed_on_the_run(self):
        self.write(self.LOG, "old com.hammer.nostromo.qa line\n")
        self.before = self.snap()
        self.write(self.LOG, "clean new line\n", "a")
        self.assertClean()

    def test_a_marker_split_across_the_snapshot_boundary_is_found(self):
        self.write(self.LOG, "first\npartial line FIXT")
        self.before = self.snap()
        self.write(self.LOG, "URE:simple_rm %s\n" % self.SECRET, "a")
        probs = self.problems()
        self.assertTrue(any(self.LOG in p for p in probs), probs)
        self.assertNoLeak(probs)

    def test_a_new_file_with_a_marker_is_a_problem_and_without_is_fine(self):
        self.write("brand-new.json", '{"v":"%s"}' % self.SECRET)
        self.assertClean()
        self.write("logs/new.log", "%s cody-qa-1\n" % self.SECRET)
        probs = self.problems()
        self.assertTrue(any("logs/new.log" in p for p in probs), probs)
        self.assertFalse(any("brand-new.json" in p for p in probs), probs)
        self.assertNoLeak(probs)

    def test_focuses_json_changing_at_all_is_a_problem(self):
        self.write("focuses.json", "changed %s" % self.SECRET)
        probs = self.problems()
        self.assertTrue(any("focuses.json" in p for p in probs), probs)
        self.assertNoLeak(probs)

    def test_a_changed_state_file_is_reported_as_not_inspected_without_a_nostromo_dir(self):
        self.write("daemon-sessions-extra.json", '{"a":3}')
        probs = self.problems(nostromo_dir=False)
        self.assertTrue(any("daemon-sessions-extra.json" in p and "not inspected" in p for p in probs), probs)

    def test_other_file_types_are_ignored(self):
        self.write("foo.txt", "x")
        self.write("logs/x.txt", "x")
        self.before = self.snap()
        self.write("foo.txt", "com.hammer.nostromo.qa " + self.SECRET)
        self.write("logs/x.txt", "FIXTURE: " + self.SECRET)
        self.assertNotIn("foo.txt", self.before["state_files"])
        self.assertNotIn("logs/x.txt", self.before["state_files"])
        self.assertClean()


class RealFocusesRefusalTests(unittest.TestCase):
    SCRIPT = os.path.join(ROOT, "scripts", "qa", "approvals-card.sh")
    SECRET = "SECRET-PAYLOAD-xyzzy-9090"

    def run_with_focuses(self, content):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".nostromo"))
            path = os.path.join(home, ".nostromo", "focuses.json")
            with open(path, "w") as f:
                f.write(content)
            env = {"HOME": home, "PATH": os.environ.get("PATH", "")}
            r = subprocess.run(["bash", self.SCRIPT], env=env, capture_output=True, text=True, timeout=60)
            return r, path

    def test_a_real_focuses_json_carrying_any_qa_marker_is_refused_before_anything_starts(self):
        for marker in ("FIXTURE:", "com.hammer.nostromo.qa", "nostromo-qa-", "cody-qa-", "qa-approvals"):
            with self.subTest(marker=marker):
                r, path = self.run_with_focuses('{"title":"%s %s"}' % (self.SECRET, marker))
                self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
                self.assertIn(path, r.stderr)
                out = r.stdout + r.stderr
                self.assertNotIn(self.SECRET, out)
                self.assertNotIn("QA_ROOT=", r.stdout)

    def test_the_refusal_comes_before_the_instance_is_started(self):
        sh = read("scripts", "qa", "approvals-card.sh")
        self.assertIn("exit 2", sh)
        self.assertIn(".nostromo/focuses.json", sh)
        self.assertLess(sh.index(".nostromo/focuses.json"), sh.index('"$instance" start'))
        self.assertLess(sh.index("exit 2"), sh.index('"$instance" start'))


def read_abs(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


class NoDirectHomeNostromoPathsTests(unittest.TestCase):
    """Every path under ~/.nostromo in the Swift sources must come from NostromoHome.current."""
    SOURCES = [("macOS", "Nostromo"), ("Shared", "NostromoKit", "Sources")]
    TOKENS = ("homeDirectoryForCurrentUser", "NSHomeDirectory()")
    # NostromoHome.swift is the one place allowed to read the system home.
    ALLOWED = {"NostromoHome.swift"}

    @classmethod
    def code_lines(cls, text):
        return [("" if l.lstrip().startswith("//") else l) for l in text.splitlines()]

    @classmethod
    def violations(cls, text):
        """Line numbers (1-based) where the system home feeds a `.nostromo` path."""
        lines = cls.code_lines(text)
        bad = set()
        for i, l in enumerate(lines):
            if not any(t in l for t in cls.TOKENS):
                continue
            if any(".nostromo" in w for w in lines[i:i + 5]):
                bad.add(i + 1)
            m = re.match(r"\s*(?:let|var)\s+(\w+)\b", l)
            if m:
                name = m.group(1)
                for w in lines[i + 1:i + 7]:
                    if ".nostromo" in w and re.search(r"\b%s\b" % re.escape(name), w):
                        bad.add(i + 1)
        return sorted(bad)

    def swift_files(self):
        for parts in self.SOURCES:
            for d, _, names in os.walk(os.path.join(ROOT, *parts)):
                for n in names:
                    if n.endswith(".swift"):
                        yield os.path.join(d, n)

    def test_no_swift_source_builds_a_nostromo_path_from_the_system_home(self):
        offenders = []
        for path in self.swift_files():
            if os.path.basename(path) in self.ALLOWED:
                continue
            with open(path, encoding="utf-8") as f:
                hits = self.violations(f.read())
            offenders += ["%s:%d" % (os.path.relpath(path, ROOT), n) for n in hits]
        self.assertEqual(offenders, [], "use NostromoHome.current instead of the system home")

    def test_the_scan_is_not_vacuous(self):
        seen = {os.path.basename(p) for p in self.swift_files() if any(t in read_abs(p) for t in self.TOKENS)}
        self.assertIn("NostromoHome.swift", seen)

    def test_the_detector_flags_a_direct_home_nostromo_path(self):
        snippet = 'let u = FileManager.default.homeDirectoryForCurrentUser\n    .appendingPathComponent(".nostromo/x")\n'
        self.assertTrue(self.violations(snippet))
        indirect = 'let home = NSHomeDirectory()\nlet p = "\\(home)/.nostromo/x"\n'
        self.assertTrue(self.violations(indirect))

    def test_the_detector_ignores_comments_and_unrelated_paths(self):
        self.assertFalse(self.violations('// homeDirectoryForCurrentUser .nostromo\n'))
        self.assertFalse(self.violations('let h = NSHomeDirectory()\nlet p = h + "/.claude/agents"\n'))

    def test_the_state_stores_use_nostromo_home(self):
        for rel in ("Data/FocusStore.swift", "Data/WindowPlacementLog.swift", "Data/TranscriptFoldStore.swift",
                    "Data/ImagePasteboard.swift", "Data/NostromodClient.swift", "Data/DaemonDiagnostics.swift",
                    "AppControl/AppControlServer.swift"):
            with self.subTest(file=rel):
                self.assertIn("NostromoHome.current", read("macOS", "Nostromo", *rel.split("/")))


if __name__ == "__main__":
    unittest.main()
