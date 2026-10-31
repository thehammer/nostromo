"""Tests for scripts/doctor-preflight.sh using fake Xcode tools on PATH.

The real Xcode tools are never called. Each fake fails only for the check named in
FAIL_CHECK (license | firstlaunch | metal).
"""

import os
import subprocess
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "doctor-preflight.sh")

FAKE_XCODEBUILD = """#!/bin/sh
case "$1" in
  -license) [ "$FAIL_CHECK" = license ] && exit 1 ;;
  -checkFirstLaunchStatus) [ "$FAIL_CHECK" = firstlaunch ] && exit 1 ;;
esac
exit 0
"""
FAKE_XCRUN = """#!/bin/sh
[ "$FAIL_CHECK" = metal ] && exit 1
exit 0
"""


class DoctorPreflightTests(unittest.TestCase):
    def setUp(self):
        self.bindir = tempfile.TemporaryDirectory()
        self.addCleanup(self.bindir.cleanup)
        for name, body in (("xcodebuild", FAKE_XCODEBUILD), ("xcrun", FAKE_XCRUN)):
            path = os.path.join(self.bindir.name, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)

    def run_script(self, fail_check=""):
        env = dict(os.environ)
        env["PATH"] = self.bindir.name + os.pathsep + env["PATH"]
        env["FAIL_CHECK"] = fail_check
        return subprocess.run(["/bin/bash", SCRIPT], env=env, capture_output=True, text=True)

    def test_all_pass(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("FAIL", r.stdout)
        self.assertEqual(r.stdout.count("OK"), 3)

    def assert_single_failure(self, fail_check, next_step):
        r = self.run_script(fail_check)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertEqual(r.stdout.count("FAIL"), 1, r.stdout)
        self.assertEqual(r.stdout.count("OK"), 2, r.stdout)
        self.assertIn(next_step, r.stdout)

    def test_license_failure(self):
        self.assert_single_failure("license", "sudo xcodebuild -license accept")

    def test_first_launch_failure(self):
        self.assert_single_failure("firstlaunch", "sudo xcodebuild -runFirstLaunch")

    def test_metal_failure(self):
        self.assert_single_failure("metal", "xcodebuild -downloadComponent MetalToolchain")


if __name__ == "__main__":
    unittest.main()
