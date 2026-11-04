"""terminal-remote.sh, terminal-local.sh and terminal-hazard.sh promise no tokens and no foreign state, so each
refuses to run (exit 2, before anything starts, nothing on stdout) when

  * a real model binary is configured (NOSTROMO_QA_CLAUDE_BIN), or
  * the real ~/.nostromo/focuses.json already carries a QA marker (the leftover of an earlier breach).

These scripts hard-wire their qa-instance.sh and bin/nostromo-app relative to their own location, so every run
here happens in a throw-away copy of the scripts (plus lib/) whose qa-instance.sh and bin/nostromo-app are stubs
that only record they were called and fail. A script WITHOUT its guard therefore ends harmlessly at the stub
instead of starting a real daemon.
"""
import os
import shutil
import subprocess
import tempfile
import unittest

from qa_harness import QA_DIR

SCRIPTS = ("terminal-remote.sh", "terminal-local.sh", "terminal-hazard.sh")
MARKERS = ("FIXTURE:x", "com.hammer.nostromo.qa", "/tmp/nostromo-qa-1234", "cody-qa-x", "qa-approvals")

STUB = """#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
exit 1
"""


class Tree:
    """A copy of scripts/qa (scripts + lib) under <root>/scripts/qa, with stub instance and app."""

    def __init__(self, test):
        self.root = tempfile.mkdtemp(prefix="qa-guard-")
        test.addCleanup(shutil.rmtree, self.root, True)
        qa = os.path.join(self.root, "scripts", "qa")
        os.makedirs(qa)
        shutil.copytree(os.path.join(QA_DIR, "lib"), os.path.join(qa, "lib"),
                        ignore=shutil.ignore_patterns("__pycache__"))
        for name in SCRIPTS:
            shutil.copy(os.path.join(QA_DIR, name), os.path.join(qa, name))
        os.makedirs(os.path.join(self.root, "bin"))
        for stub in (os.path.join(qa, "qa-instance.sh"), os.path.join(self.root, "bin", "nostromo-app")):
            with open(stub, "w") as f:
                f.write(STUB)
            os.chmod(stub, 0o755)
        self.qa = qa
        self.home = os.path.join(self.root, "home")
        self.tmp = os.path.join(self.root, "tmp")
        os.makedirs(self.home)
        os.makedirs(self.tmp)
        self.log = os.path.join(self.root, "stub.log")

    def write_focuses(self, text):
        os.makedirs(os.path.join(self.home, ".nostromo"), exist_ok=True)
        with open(os.path.join(self.home, ".nostromo", "focuses.json"), "w") as f:
            f.write(text)

    def stub_calls(self):
        try:
            with open(self.log) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def run(self, script, env=None):
        full = {k: v for k, v in os.environ.items()
                if not k.startswith(("QA_", "NOSTROMO_", "FAKE_")) and k not in ("HOME", "TMPDIR")}
        full.update(HOME=self.home, TMPDIR=self.tmp, STUB_LOG=self.log, QA_SLEEP_SCALE="0")
        full.update(env or {})
        return subprocess.run(["bash", os.path.join(self.qa, script)], capture_output=True, text=True,
                              timeout=60, env=full, cwd=self.root)


class TerminalScriptGuardsTest(unittest.TestCase):
    def refused(self, run, tree, why):
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("REFUSING TO RUN", run.stderr)
        self.assertNotIn("evidence directory", run.stdout)
        self.assertEqual(tree.stub_calls(), [], "nothing may be started before the refusal")
        self.assertIn(why, run.stderr)

    def test_each_script_refuses_when_a_real_model_binary_is_configured(self):
        for script in SCRIPTS:
            with self.subTest(script):
                tree = Tree(self)
                run = tree.run(script, {"NOSTROMO_QA_CLAUDE_BIN": "/usr/local/bin/claude"})
                self.refused(run, tree, "NOSTROMO_QA_CLAUDE_BIN")
                self.assertIn("spend tokens", run.stderr)

    def test_each_script_refuses_when_the_real_focuses_file_carries_a_qa_marker(self):
        for script in SCRIPTS:
            for marker in MARKERS:
                with self.subTest(script=script, marker=marker):
                    tree = Tree(self)
                    tree.write_focuses('{"focuses":[{"tag":"%s"}]}' % marker)
                    run = tree.run(script)
                    self.refused(run, tree, "focuses.json")

    def test_the_marker_refusal_comes_before_anything_else_when_both_conditions_hold(self):
        for script in SCRIPTS:
            with self.subTest(script):
                tree = Tree(self)
                tree.write_focuses('{"focuses":[{"tag":"cody-qa-x"}]}')
                run = tree.run(script, {"NOSTROMO_QA_CLAUDE_BIN": "/usr/local/bin/claude"})
                self.refused(run, tree, "REFUSING TO RUN")

    def test_each_script_gets_past_the_guards_in_a_clean_environment(self):
        """Control: without either condition the guard stays out of the way (the stub then ends the run)."""
        clean_homes = {
            "no ~/.nostromo at all": None,
            "an ordinary focuses.json": '{"focuses":[{"tag":"mother"},{"tag":"daily"}]}',
        }
        for script in SCRIPTS:
            for label, content in clean_homes.items():
                with self.subTest(script=script, home=label):
                    tree = Tree(self)
                    if content is not None:
                        tree.write_focuses(content)
                    run = tree.run(script)
                    self.assertNotIn("REFUSING TO RUN", run.stderr, run.stdout + run.stderr)
                    self.assertIn("evidence directory", run.stdout)


class TerminalScriptSourceTest(unittest.TestCase):
    """The scripts call the shared guards right after sourcing lib/qa-visible.sh, before they start anything."""

    def read(self, *parts):
        with open(os.path.join(QA_DIR, *parts)) as f:
            return f.read()

    def test_the_shared_library_defines_both_guards_and_a_combined_entry_point(self):
        lib = self.read("lib", "qa-visible.sh")
        self.assertRegex(lib, r"(?m)^qa_refuse_real_model\(\)")
        self.assertRegex(lib, r"(?m)^qa_refuse_dirty_real_home\(\)")
        for marker in (r"FIXTURE:", r"com\.hammer\.nostromo\.qa", r"nostromo-qa-", r"cody-qa-", r"qa-approvals"):
            self.assertIn(marker, lib)

    def test_each_script_calls_both_guards_before_it_starts_anything(self):
        lib = self.read("lib", "qa-visible.sh")
        combined = [ln for ln in lib.splitlines() if ln.startswith("qa_refuse_unsafe_start")]
        for script in SCRIPTS:
            with self.subTest(script):
                src = self.read(script)
                code = "\n".join(ln for ln in src.splitlines() if not ln.lstrip().startswith("#"))
                self.assertIn("lib/qa-visible.sh", code, "the script must source the shared library")
                direct = "qa_refuse_real_model" in code and "qa_refuse_dirty_real_home" in code
                via_combined = "qa_refuse_unsafe_start" in code
                if via_combined:
                    start = lib.index("qa_refuse_unsafe_start()")
                    body = lib[start:lib.index("\n}", start)]
                    self.assertIn("qa_refuse_real_model", body)
                    self.assertIn("qa_refuse_dirty_real_home", body)
                    self.assertTrue(combined)
                self.assertTrue(direct or via_combined, "no shared guard call in " + script)
                guard_at = min(code.index(name) for name in
                               ("qa_refuse_real_model", "qa_refuse_unsafe_start") if name in code)
                for started in ('"$instance" start', "mktemp -d", "evidence directory"):
                    if started in code:
                        self.assertLess(guard_at, code.index(started), "guard must come before " + started)


if __name__ == "__main__":
    unittest.main()
