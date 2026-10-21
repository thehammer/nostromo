"""Hermetic tests for scripts/gates/*.sh using fake shellcheck/actionlint on PATH.

    python3 -m unittest discover -s tests/gates -v
"""
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHELLCHECK_GATE = ROOT / "scripts/gates/shellcheck-changed.sh"
ACTIONLINT_GATE = ROOT / "scripts/gates/actionlint.sh"

FAKE_TOOL = """#!/bin/sh
echo "$@" > "$FAKE_ARGS_FILE"
exit "${FAKE_EXIT:-0}"
"""


class GateScriptTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.work = self.tmp / "work"
        self.work.mkdir()
        self.args_file = self.tmp / "args.txt"
        # PATH holds only what the scripts need, so a real shellcheck/actionlint
        # installed on the host (e.g. /usr/bin) can't leak into the tests.
        for tool in ("dirname", "sh"):
            (self.bin / tool).symlink_to(shutil.which(tool))

    def fake(self, name):
        p = self.bin / name
        p.write_text(FAKE_TOOL)
        p.chmod(p.stat().st_mode | stat.S_IXUSR)

    def write(self, rel, body):
        p = self.work / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)

    def run_gate(self, script, changed="", exit_code=0, cwd=None):
        env = {
            "PATH": str(self.bin),
            "MOTHER_GATE_CHANGED_FILES": changed,
            "FAKE_ARGS_FILE": str(self.args_file),
            "FAKE_EXIT": str(exit_code),
            "MOTHER_GATE_FALLBACK_DIRS": "",
        }
        return subprocess.run(
            ["/bin/bash", str(script)], env=env, cwd=cwd or self.work,
            capture_output=True, text=True,
        )

    def passed_args(self):
        return self.args_file.read_text().split()

    # shellcheck gate

    def test_files_are_passed_after_a_double_dash_so_a_dash_name_is_not_an_option(self):
        self.fake("shellcheck")
        self.write("-x.sh", "#!/bin/bash\n")
        r = self.run_gate(SHELLCHECK_GATE, "-x.sh\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        args = self.passed_args()
        self.assertEqual(args, ["-x", "--", "-x.sh"])

    def test_a_git_quoted_path_is_reported_and_fails_instead_of_passing_silently(self):
        self.fake("shellcheck")
        self.write("ok.sh", "#!/bin/bash\n")
        r = self.run_gate(SHELLCHECK_GATE, 'ok.sh\n"caf\\303\\251.sh"\n')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("could not be checked", r.stderr)
        # only a quoted path: still not a silent pass
        r = self.run_gate(SHELLCHECK_GATE, '"caf\\303\\251.sh"\n')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_no_changed_files_exits_zero_without_running_tool(self):
        self.fake("shellcheck")
        r = self.run_gate(SHELLCHECK_GATE, "")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.args_file.exists())

    def test_only_sh_and_shebang_files_are_checked(self):
        self.fake("shellcheck")
        self.write("a.sh", "echo hi\n")
        self.write("bin/tool", "#!/usr/bin/env bash\necho hi\n")
        self.write("bin/posix", "#!/bin/sh\necho hi\n")
        self.write("bin/pytool", "#!/usr/bin/env python3\nprint(1)\n")
        self.write("README.md", "hi\n")
        r = self.run_gate(SHELLCHECK_GATE, "a.sh\nbin/tool\nbin/posix\nbin/pytool\nREADME.md\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.passed_args(), ["-x", "--", "a.sh", "bin/tool", "bin/posix"])
        self.assertIn("a.sh", r.stdout)

    def test_deleted_files_are_skipped(self):
        self.fake("shellcheck")
        self.write("keep.sh", "echo hi\n")
        r = self.run_gate(SHELLCHECK_GATE, "gone.sh\nkeep.sh\n")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.passed_args(), ["-x", "--", "keep.sh"])

    def test_only_deleted_files_exits_zero(self):
        self.fake("shellcheck")
        r = self.run_gate(SHELLCHECK_GATE, "gone.sh\n")
        self.assertEqual(r.returncode, 0)
        self.assertFalse(self.args_file.exists())

    def test_finding_gives_nonzero(self):
        self.fake("shellcheck")
        self.write("a.sh", "echo hi\n")
        r = self.run_gate(SHELLCHECK_GATE, "a.sh\n", exit_code=1)
        self.assertEqual(r.returncode, 1)

    def test_missing_shellcheck_exits_two_with_message(self):
        self.write("a.sh", "echo hi\n")
        r = self.run_gate(SHELLCHECK_GATE, "a.sh\n")
        self.assertEqual(r.returncode, 2)
        self.assertIn("shellcheck not installed", r.stdout + r.stderr)

    # actionlint gate

    def test_actionlint_runs_over_workflows(self):
        self.fake("actionlint")
        r = self.run_gate(ACTIONLINT_GATE, cwd=ROOT)
        self.assertEqual(r.returncode, 0, r.stderr)
        args = self.passed_args()
        self.assertTrue(args)
        self.assertTrue(all(a.startswith(".github/workflows/") and a.endswith(".yml") for a in args))

    def test_actionlint_finding_gives_nonzero(self):
        self.fake("actionlint")
        r = self.run_gate(ACTIONLINT_GATE, exit_code=1, cwd=ROOT)
        self.assertEqual(r.returncode, 1)

    def test_missing_actionlint_exits_two_with_message(self):
        r = self.run_gate(ACTIONLINT_GATE)
        self.assertEqual(r.returncode, 2)
        self.assertIn("actionlint not installed", r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
