"""Isolated QA instance helpers: pure logic, env construction, fake claude, safety greps.

Run with:  python3 -m unittest discover -s tests/qa_instance -v
Never starts an app, a daemon or any real instance.
"""
import ast, importlib.machinery, importlib.util, json, os, re, subprocess, sys, tempfile, unittest

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


if __name__ == "__main__":
    unittest.main()
