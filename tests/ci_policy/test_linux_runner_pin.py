"""Linux runners are pinned to an explicit `ubuntu-NN.NN`, never `*-latest`.

`ubuntu-latest` rolled to 26.04 on 2026-11-16 and broke the PTY tests in
tests/mcp_terminal_guards.rs (the shell emits OSC 3008 markers). Same reason
as the Rust toolchain pin. macOS runners are out of scope here.

Run with (from the repo root):
    python3 -I -m unittest discover -s tests/ci_policy -p 'test_linux_runner_pin.py' -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNS_ON = re.compile(r"^\s*runs-on:\s*(.+?)\s*$", re.M)
QUOTED = re.compile(r"'([^']*)'")
EXPLICIT_UBUNTU = re.compile(r"^ubuntu-\d\d\.\d\d$")


def violations(name, text):
    out = []
    for runner in RUNS_ON.findall(text):
        # An expression (`${{ cond && 'macos-26' || 'ubuntu-24.04' }}`) is checked
        # on each quoted literal it can yield.
        runners = [q for q in QUOTED.findall(runner) if q not in ("true", "false")] if runner.startswith("${{") else [runner.strip("'\"")]
        for r in runners:
            if r.startswith("macos-") or r.startswith("windows-"):
                continue
            if not EXPLICIT_UBUNTU.match(r):
                out.append(f"{name}: runs-on {r!r} is not an explicit ubuntu-NN.NN")
    return out


class LinuxRunnerPinTests(unittest.TestCase):
    def test_real_workflows_pinned(self):
        files = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
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


if __name__ == "__main__":
    unittest.main()
