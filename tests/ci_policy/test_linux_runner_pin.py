"""Every runner is pinned to an explicit image, never `*-latest`.

`ubuntu-latest` rolled to 26.04 on 2026-11-16 and broke the PTY tests in
tests/mcp_terminal_guards.rs (the shell prints OSC 3008 markers). Those tests now strip OSC
sequences and always run against a shell that prints them, so they no longer depend on the image;
the pin stays anyway, on purpose: a pin is a feature. A runner image changes the compiler
environment, the system shell, the preinstalled tools and the Python the policy suites run under,
and a rollover should show up as a diff in the pull request that bumps it, not as an unexplained
red on an unrelated PR.

To bump an image deliberately: change the literal in every workflow (this test lists them), dispatch
`ci.yml` (and any other workflow you touched) on the branch (`gh workflow run ci.yml --ref <branch>`),
and merge only when it is green. Never replace the pin with `*-latest`.

Accepted: `ubuntu-NN.NN`, `macos-NN`, `windows-YYYY`. A `runs-on` expression is checked on each
quoted literal it can yield, and an expression with no literal at all (`${{ matrix.os }}`) is
rejected: what it yields cannot be checked here.

Run with (from the repo root):
    python3 -I -m unittest discover -s tests/ci_policy -p 'test_linux_runner_pin.py' -v
"""

import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
RUNS_ON = re.compile(r"^\s*runs-on:\s*(.+?)\s*$", re.M)
QUOTED = re.compile(r"'([^']*)'")
EXPLICIT_RUNNER = re.compile(r"^(ubuntu-\d\d\.\d\d|macos-\d+|windows-\d{4})$")


def workflow_files(directory):
    """Every workflow file: GitHub reads both `.yml` and `.yaml`."""
    return sorted(directory.glob("*.y*ml"))


def violations(name, text):
    out = []
    for runner in RUNS_ON.findall(text):
        # A comment after the value is not part of it.
        runner = re.sub(r"\s+#.*$", "", runner)
        if runner.startswith("${{"):
            # An expression (`${{ cond && 'macos-26' || 'ubuntu-24.04' }}`) is checked on each
            # quoted literal it can yield; one that yields no literal cannot be checked.
            runners = [q for q in QUOTED.findall(runner) if q not in ("true", "false")]
            if not runners:
                out.append(f"{name}: runs-on {runner!r} is an expression with no literal runner to check")
        else:
            runners = [runner.strip("'\"")]
        for r in runners:
            if not EXPLICIT_RUNNER.match(r):
                out.append(f"{name}: runs-on {r!r} is not an explicit ubuntu-NN.NN, macos-NN or windows-YYYY")
    return out


class LinuxRunnerPinTests(unittest.TestCase):
    def test_real_workflows_pinned(self):
        files = workflow_files(WORKFLOWS)
        self.assertTrue(files)
        found = 0
        out = []
        for f in files:
            text = f.read_text()
            found += len(RUNS_ON.findall(text))
            out += violations(f.name, text)
        self.assertGreater(found, 0)
        self.assertEqual(out, [])


class LinuxRunnerPinBitesTests(unittest.TestCase):
    def test_pinned_passes(self):
        self.assertEqual(violations("x", "    runs-on: ubuntu-24.04\n    runs-on: macos-26\n"), [])

    def test_latest_fails(self):
        self.assertTrue(violations("x", "    runs-on: ubuntu-latest\n"))

    def test_other_latest_linux_fails(self):
        self.assertTrue(violations("x", "    runs-on: ubuntu-slim-latest\n"))

    def test_expression_literals_are_checked(self):
        ok = "    runs-on: ${{ needs.c.outputs.s == 'true' && 'macos-26' || 'ubuntu-24.04' }}\n"
        self.assertEqual(violations("x", ok), [])
        self.assertTrue(violations("x", ok.replace("ubuntu-24.04", "ubuntu-latest")))

    def test_unversioned_fails(self):
        self.assertTrue(violations("x", "    runs-on: ubuntu-24\n"))

    def test_macos_latest_and_windows_latest_fail(self):
        self.assertTrue(violations("x", "    runs-on: macos-latest\n"))
        self.assertTrue(violations("x", "    runs-on: macos-26-xlarge-latest\n"))
        self.assertTrue(violations("x", "    runs-on: windows-latest\n"))
        self.assertEqual(violations("x", "    runs-on: windows-2025\n"), [])

    def test_a_matrix_expression_is_rejected_because_it_yields_no_literal(self):
        text = "    strategy:\n      matrix:\n        os: [ubuntu-latest, macos-26]\n    runs-on: ${{ matrix.os }}\n"
        self.assertTrue(violations("x", text))

    def test_an_expression_literal_hiding_behind_a_matrix_is_still_checked(self):
        text = "    runs-on: ${{ matrix.big && 'ubuntu-latest' || matrix.os }}\n"
        self.assertTrue(violations("x", text))

    def test_a_flow_list_of_labels_fails(self):
        self.assertTrue(violations("x", "    runs-on: [self-hosted, linux]\n"))

    def test_a_trailing_comment_does_not_hide_or_cause_a_violation(self):
        self.assertEqual(violations("x", "    runs-on: ubuntu-24.04  # pinned\n"), [])
        self.assertTrue(violations("x", "    runs-on: ubuntu-latest  # ubuntu-24.04\n"))


class WorkflowGlobTests(unittest.TestCase):
    def test_yaml_spelled_both_ways_is_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("a.yml", "b.yaml", "c.txt", "d.yml.bak"):
                (Path(tmp) / name).write_text("")
            self.assertEqual([f.name for f in workflow_files(Path(tmp))], ["a.yml", "b.yaml"])


if __name__ == "__main__":
    unittest.main()
