"""Schema checks for .mother/crew.yml (Mother headless-crew config, version 1).

    python3 -m unittest discover -s tests/gates -v

The YAML is read through the system Ruby (present on every macOS runner), then
PyYAML. If neither exists the tests fail on macOS (CI must never skip them) and
skip with a reason elsewhere. If Mother's own validator is on this machine it is
run against a committed copy of the file in a throwaway git repo; otherwise that
test returns early with a printed note (never reported as skipped).
"""
import json
import platform
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    yaml = None

ROOT = Path(__file__).resolve().parents[2]
CREW = ROOT / ".mother/crew.yml"
VALIDATOR = Path.home() / "Code/mother/plugins/mother/lib/crew_config.py"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
LENSES = {"correctness", "phi-security", "tests", "ops-infra"}
RUST_PATHS = {
    "src/**", "tests/*.rs", "tests/**/*.rs", "tests/fixtures/**",
    "Cargo.toml", "Cargo.lock", "rust-toolchain.toml", ".rwx/**",
}
PYTHON_PATHS = {"tests/**", "scripts/**", "bin/**", "Makefile", "*.py", "**/*.py"}


RUBY = "/usr/bin/ruby"
RUBY_SCRIPT = "puts JSON.generate(YAML.load_file(ARGV[0]))"


def load_crew():
    """Parse .mother/crew.yml with system Ruby, else PyYAML, else None."""
    if Path(RUBY).exists():
        try:
            r = subprocess.run(
                [RUBY, "-ryaml", "-rjson", "-e", RUBY_SCRIPT, str(CREW)],
                capture_output=True, text=True, timeout=30,
            )
            if r.returncode == 0:
                return json.loads(r.stdout)
            print("ruby failed: " + r.stderr, file=sys.stderr)
        except (OSError, subprocess.TimeoutExpired, ValueError) as e:
            print("ruby unusable: %s" % e, file=sys.stderr)
    if yaml is not None:
        return yaml.safe_load(CREW.read_text())
    return None


class CrewConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.doc = load_crew()
        if cls.doc is None:
            msg = "neither %s nor PyYAML available to parse .mother/crew.yml" % RUBY
            if platform.system() == "Darwin":
                raise AssertionError(msg)  # CI runs on macOS: never skip silently
            raise unittest.SkipTest(msg)
        cls.checks = cls.doc["gates"]["checks"]

    def test_observe_mode(self):
        self.assertEqual(self.doc["version"], 1)
        self.assertEqual(self.doc["gates"]["mode"], "observe")
        self.assertEqual(self.doc["lenses"]["mode"], "observe")

    def test_gate_names_match_schema_and_are_unique(self):
        names = [c["name"] for c in self.checks]
        self.assertEqual(len(names), len(set(names)))
        for n in names:
            self.assertRegex(n, NAME_RE)

    def test_lens_names_are_in_the_closed_set(self):
        lenses = self.doc["lenses"]
        used = set(lenses["default"]) | set(lenses.get("mandatory", [])) | set(lenses["scopes"])
        for paths in lenses["scopes"].values():
            self.assertIsInstance(paths, list)  # Mother wants a bare glob list, not {paths: [...]}
        self.assertTrue(used <= LENSES, used - LENSES)

    def test_no_run_embeds_rwx_sandbox(self):
        for c in self.checks:
            self.assertFalse(c["run"].lstrip().startswith("rwx sandbox"), c["name"])
            self.assertNotIn("rwx sandbox", c["run"], c["name"])

    def test_sandbox_gates_are_path_scoped_to_their_language(self):
        for c in self.checks:
            if c.get("where") != "sandbox":
                continue
            paths = set(c.get("when", {}).get("paths", []))
            allowed = PYTHON_PATHS if c["name"] == "python-test" else RUST_PATHS
            self.assertTrue(paths and paths <= allowed, "%s: %s" % (c["name"], paths - allowed))

    def test_swift_ci_scoped_and_advisory_gates(self):
        by = {c["name"]: c for c in self.checks}
        self.assertEqual(set(by["swift-ci"]["when"]["paths"]), {"macOS/**", "iOS/**", "Shared/**"})
        self.assertEqual(by["swift-ci"]["where"], "any")
        # Python goes through the RWX sandbox like Rust: a change to `where: any` would silently drop
        # python-test out of the sandbox-gate loop above, so pin it explicitly.
        self.assertEqual(by["python-test"]["where"], "sandbox")
        self.assertIs(by["actionlint"]["blocking"], False)
        self.assertIs(by["mother-contract"]["blocking"], False)

    def test_budget_and_hints(self):
        self.assertEqual(self.doc["gates"]["budget_minutes"], 45)
        for c in self.checks:
            self.assertLessEqual(len(c.get("hint", "")), 500)
            self.assertTrue(1 <= c.get("timeout_s", 900) <= 3600)

    def test_gate_scripts_referenced_exist(self):
        for c in self.checks:
            first = c["run"].split()[0]
            if first.startswith("scripts/"):
                self.assertTrue((ROOT / first).exists(), first)

    def test_validates_with_mothers_crew_config(self):
        if not VALIDATOR.exists():
            print("note: Mother crew_config.py not on this machine; validator run omitted")
            return
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            (repo / ".mother").mkdir()
            (repo / ".mother/crew.yml").write_text(CREW.read_text())
            # 'where: sandbox' gates require the sandbox definition at the same ref.
            (repo / ".rwx").mkdir()
            (repo / ".rwx/sandbox.yml").write_text((ROOT / ".rwx/sandbox.yml").read_text())
            git = ["git", "-c", "user.email=t@t", "-c", "user.name=t", "-C", d]
            subprocess.run(git + ["init", "-q"], check=True)
            subprocess.run(git + ["add", "."], check=True)
            subprocess.run(git + ["commit", "-q", "-m", "x"], check=True)
            r = subprocess.run(
                ["python3", str(VALIDATOR), "resolve", d, "HEAD", "nostromo"],
                capture_output=True, text=True,
            )
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
