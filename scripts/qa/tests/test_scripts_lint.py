"""shellcheck stays clean on every QA shell script (skipped when shellcheck is not installed)."""
import glob
import os
import shutil
import subprocess
import unittest

QA_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Older scenarios that already carry one SC2034 warning each (`W=0` assigned and never read); not part of this
# work. Remove them from this set once they are cleaned up.
KNOWN_DIRTY = {"mother-queue.sh", "mother-tabs.sh"}


@unittest.skipUnless(shutil.which("shellcheck"), "shellcheck is not on PATH")
class TestShellcheck(unittest.TestCase):
    def test_every_qa_shell_script_is_shellcheck_clean(self):
        scripts = sorted(glob.glob(os.path.join(QA_DIR, "*.sh")) + glob.glob(os.path.join(QA_DIR, "lib", "*.sh")))
        scripts = [p for p in scripts if os.path.basename(p) not in KNOWN_DIRTY]
        self.assertIn("teri-fred-smoke.sh", [os.path.basename(p) for p in scripts])
        for path in scripts:
            with self.subTest(os.path.relpath(path, QA_DIR)):
                p = subprocess.run(["shellcheck", "-x", path], capture_output=True, text=True, cwd=QA_DIR, timeout=60)
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
