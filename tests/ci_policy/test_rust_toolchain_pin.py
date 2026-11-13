"""The Rust toolchain is pinned in three places; they must agree.

  * rust-toolchain.toml        `channel = "X"`
  * .github/workflows/ci.yml   every `dtolnay/rust-toolchain@X`
  * .rwx/sandbox.yml           `RUST_VERSION: X`

Run with:
    python3 -m unittest discover -s tests/ci_policy -p 'test_rust_toolchain_pin.py' -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VERSION = re.compile(r"^\d+\.\d+\.\d+$")


def toolchain_versions(toolchain_toml, ci_yml, sandbox_yml):
    """Return (channel, [ci refs], [sandbox versions]) from the three file texts."""
    channel = re.findall(r'^\s*channel\s*=\s*"([^"]+)"', toolchain_toml, re.M)
    ci = re.findall(r"dtolnay/rust-toolchain@(\S+)", ci_yml)
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
        out.append("ci.yml has no dtolnay/rust-toolchain step")
    out += [f"ci.yml uses dtolnay/rust-toolchain@{r}, expected {pin}" for r in ci if r != pin]
    if len(sandbox) != 1:
        out.append(f".rwx/sandbox.yml must set RUST_VERSION exactly once, found {sandbox}")
    out += [f".rwx/sandbox.yml RUST_VERSION {v}, expected {pin}" for v in sandbox if v != pin]
    return out


class RustToolchainPinTests(unittest.TestCase):
    def test_real_tree_agrees(self):
        texts = [
            (ROOT / p).read_text()
            for p in ("rust-toolchain.toml", ".github/workflows/ci.yml", ".rwx/sandbox.yml")
        ]
        self.assertEqual(violations(*texts), [])


class RustToolchainPinBitesTests(unittest.TestCase):
    TOML = '[toolchain]\nchannel = "1.100.0"\n'
    CI = "uses: dtolnay/rust-toolchain@1.100.0\nuses: dtolnay/rust-toolchain@1.100.0\n"
    SANDBOX = "env:\n  RUST_VERSION: 1.100.0\n"

    def test_consistent_passes(self):
        self.assertEqual(violations(self.TOML, self.CI, self.SANDBOX), [])

    def test_toml_drift_fails(self):
        self.assertTrue(violations(self.TOML.replace("1.100.0", "1.101.0"), self.CI, self.SANDBOX))

    def test_ci_drift_fails(self):
        ci = self.CI + "uses: dtolnay/rust-toolchain@stable\n"
        self.assertTrue(violations(self.TOML, ci, self.SANDBOX))

    def test_sandbox_drift_fails(self):
        self.assertTrue(violations(self.TOML, self.CI, self.SANDBOX.replace("1.100.0", "1.99.0")))

    def test_floating_channel_fails(self):
        self.assertTrue(violations(self.TOML.replace("1.100.0", "stable"), self.CI.replace("1.100.0", "stable"), self.SANDBOX.replace("1.100.0", "stable")))


if __name__ == "__main__":
    unittest.main()
