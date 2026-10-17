"""Hermetic tests for scripts/tracker/guard_false_alarm_scan.py.

The scan binary is replaced by a tiny fake that flags lines containing `FLAG`,
and the "home" is a temp directory, so nothing real is read.

Run with: python3 -m unittest discover -s scripts/tracker/tests -v
"""

import contextlib
import importlib.util
import io
import shlex
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "guard_false_alarm_scan.py"
spec = importlib.util.spec_from_file_location("guard_false_alarm_scan", SCRIPT)
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)

FAKE_SCANNER = (
    "import sys\n"
    "for n, line in enumerate(sys.stdin.buffer, 1):\n"
    "    if b'FLAG-SSN' in line: print(f'{n}\\tssn')\n"
    "    if b'FLAG-SECRET' in line: print(f'{n}\\tsecret')\n"
)


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class GuardScanScriptTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def run_main(self, *extra):
        cmd = shlex.join([sys.executable, "-c", FAKE_SCANNER])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = scan.main(["--scan-cmd", cmd, *extra], home=self.home)
        return code, out.getvalue()

    def test_finds_only_wip_index_files_in_both_roots(self):
        write(self.home / "Code/app/.claude/wip/topic/index.md", "a\n")
        write(self.home / "Code/app/.claude/wip/topic/other.md", "b\n")
        write(self.home / "Code/app/.claude/notes/index.md", "c\n")
        write(self.home / ".claude/wip/mine/index.md", "d\n")
        found = {str(p.relative_to(self.home)) for p in scan.find_wip_files(self.home)}
        self.assertEqual(
            found, {"Code/app/.claude/wip/topic/index.md", ".claude/wip/mine/index.md"}
        )

    def test_reports_per_class_counts_and_rates_without_any_text(self):
        write(self.home / "Code/app/.claude/wip/t/index.md", "ok\nFLAG-SSN secret-looking-text\nok\nok")
        write(self.home / ".claude/wip/u/index.md", "FLAG-SECRET and FLAG-SSN\nok\n")
        code, out = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("lines scanned: 6", out)
        self.assertRegex(out, r"ssn\s+2\s+33\.33%")
        self.assertRegex(out, r"secret\s+1\s+16\.67%")
        self.assertRegex(out, r"any class\s+2\s+33\.33%")
        self.assertNotIn("secret-looking-text", out)

    def test_list_maps_global_lines_back_to_file_and_line(self):
        write(self.home / "Code/app/.claude/wip/t/index.md", "ok\nok\n")
        write(self.home / ".claude/wip/u/index.md", "ok\nFLAG-SSN\n")
        _, out = self.run_main("--list")
        self.assertIn(f"{self.home / '.claude/wip/u/index.md'}:2  ssn", out)
        self.assertNotIn("FLAG-SSN", out)

    def test_file_without_trailing_newline_does_not_merge_with_the_next(self):
        write(self.home / "Code/a/.claude/wip/t/index.md", "no newline at end")
        write(self.home / ".claude/wip/u/index.md", "FLAG-SSN\n")
        _, out = self.run_main("--list")
        self.assertIn("lines scanned: 2", out)
        self.assertIn(".claude/wip/u/index.md:1  ssn", out)

    def test_writes_nothing_into_the_scanned_tree(self):
        write(self.home / ".claude/wip/u/index.md", "FLAG-SSN\n")
        before = sorted(str(p) for p in self.home.rglob("*"))
        self.run_main("--list")
        self.assertEqual(before, sorted(str(p) for p in self.home.rglob("*")))

    def test_empty_home_is_not_an_error(self):
        code, out = self.run_main()
        self.assertEqual(code, 0)
        self.assertIn("no wip index.md files found", out)

    def test_parse_scan_output_ignores_malformed_rows(self):
        rows = scan.parse_scan_output("3\tssn\nbogus\n4\tnot_a_class\nx\tssn\n5\tcard\n")
        self.assertEqual(rows, [(3, "ssn"), (5, "card")])

    def test_failing_scan_command_exits_nonzero(self):
        write(self.home / ".claude/wip/u/index.md", "ok\n")
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = scan.main(["--scan-cmd", shlex.join([sys.executable, "-c", "import sys; sys.exit(3)"])], home=self.home)
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
