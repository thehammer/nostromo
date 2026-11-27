"""The Rust toolchain is pinned in three places; they must agree.

  * rust-toolchain.toml        `channel = "X"`
  * every workflow             each `dtolnay/rust-toolchain@<full commit SHA>` step names
                               `with: toolchain: X` (the action reads the version from that input
                               when it is pinned by SHA; `@X` would be a movable branch)
  * .rwx/sandbox.yml           `RUST_VERSION: X`

Run with:
    python3 -m unittest discover -s tests/ci_policy -p 'test_rust_toolchain_pin.py' -v
"""

import re
import unittest
from pathlib import Path

from test_linux_runner_pin import workflow_files
from workflow_steps import uses_steps

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"^\d+\.\d+\.\d+$")
SHA = re.compile(r"^[0-9a-f]{40}$")


def toolchain_versions(toolchain_toml, ci_yml, sandbox_yml):
    """Return (channel, [(ref, toolchain input) per workflow step], [sandbox versions])."""
    channel = re.findall(r'^\s*channel\s*=\s*"([^"]+)"', toolchain_toml, re.M)
    ci = [
        (s["ref"], s["inputs"].get("toolchain"))
        for s in uses_steps(ci_yml)
        if s["action"] == "dtolnay/rust-toolchain"
    ]
    sandbox = re.findall(r"^\s*RUST_VERSION:\s*(\S+)", sandbox_yml, re.M)
    return channel, ci, sandbox


def violations(toolchain_toml, ci_yml, sandbox_yml):
    channel, ci, sandbox = toolchain_versions(toolchain_toml, ci_yml, sandbox_yml)
    out = []
    if len(channel) != 1:
        return [f"rust-toolchain.toml must have exactly one channel, found {channel}"]
    pin = channel[0]
    if not VERSION.match(pin):
        out.append(f"rust-toolchain.toml channel {pin!r} is not an exact X.Y.Z version")
    if not ci:
        out.append("the workflows have no dtolnay/rust-toolchain step")
    for ref, toolchain in ci:
        if not SHA.match(ref):
            out.append(f"dtolnay/rust-toolchain@{ref} is not a full commit SHA")
        if toolchain != pin:
            out.append(f"a dtolnay/rust-toolchain step names toolchain {toolchain!r}, expected {pin}")
    if len(sandbox) != 1:
        out.append(f".rwx/sandbox.yml must set RUST_VERSION exactly once, found {sandbox}")
    out += [f".rwx/sandbox.yml RUST_VERSION {v}, expected {pin}" for v in sandbox if v != pin]
    return out


class RustToolchainPinTests(unittest.TestCase):
    def test_real_tree_agrees(self):
        workflows = "\n".join(f.read_text() for f in workflow_files(ROOT / ".github" / "workflows"))
        toml = (ROOT / "rust-toolchain.toml").read_text()
        sandbox = (ROOT / ".rwx" / "sandbox.yml").read_text()
        self.assertEqual(violations(toml, workflows, sandbox), [])
        # Not vacuous: ci.yml (3), push-relay.yml and deep-fuzz.yml install the toolchain.
        _, steps, _ = toolchain_versions(toml, workflows, sandbox)
        self.assertGreaterEqual(len(steps), 5)


class RustToolchainPinBitesTests(unittest.TestCase):
    TOML = '[toolchain]\nchannel = "1.100.0"\n'
    SHA = "df2a88e9fe4098bad09cb42c3dec7187f15861fc"
    STEP = (
        "      - name: Install Rust toolchain\n"
        f"        uses: dtolnay/rust-toolchain@{SHA} # master\n"
        "        with:\n"
        "          toolchain: 1.100.0\n"
        "          components: clippy\n"
    )
    CI = STEP + STEP
    SANDBOX = "env:\n  RUST_VERSION: 1.100.0\n"

    def test_consistent_passes(self):
        self.assertEqual(violations(self.TOML, self.CI, self.SANDBOX), [])

    def test_toml_drift_fails(self):
        self.assertTrue(violations(self.TOML.replace("1.100.0", "1.101.0"), self.CI, self.SANDBOX))

    def test_ci_drift_fails(self):
        ci = self.CI + self.STEP.replace("toolchain: 1.100.0", "toolchain: stable")
        self.assertTrue(violations(self.TOML, ci, self.SANDBOX))
        self.assertTrue(violations(self.TOML, self.CI.replace("toolchain: 1.100.0", "toolchain: 1.99.0"), self.SANDBOX))

    def test_a_step_with_no_toolchain_input_fails(self):
        self.assertTrue(violations(self.TOML, self.CI.replace("          toolchain: 1.100.0\n", ""), self.SANDBOX))
        self.assertTrue(violations(self.TOML, self.STEP.split("        with:")[0], self.SANDBOX))

    def test_a_movable_ref_instead_of_a_sha_fails(self):
        self.assertTrue(violations(self.TOML, self.CI.replace(self.SHA, "1.100.0"), self.SANDBOX))
        self.assertTrue(violations(self.TOML, self.CI.replace(self.SHA, "master"), self.SANDBOX))

    def test_no_toolchain_step_at_all_fails(self):
        self.assertTrue(violations(self.TOML, "jobs: {}\n", self.SANDBOX))

    def test_sandbox_drift_fails(self):
        self.assertTrue(violations(self.TOML, self.CI, self.SANDBOX.replace("1.100.0", "1.99.0")))

    def test_floating_channel_fails(self):
        self.assertTrue(violations(self.TOML.replace("1.100.0", "stable"), self.CI.replace("1.100.0", "stable"), self.SANDBOX.replace("1.100.0", "stable")))


if __name__ == "__main__":
    unittest.main()
