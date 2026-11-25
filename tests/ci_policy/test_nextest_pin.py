"""cargo-nextest is pinned, and runs without retries.

  * `taiki-e/install-action` is pinned to a full commit SHA (a tag can move).
  * `tool:` names `cargo-nextest@X.Y.Z`, an exact version (no `latest`, no range).
  * `.config/nextest.toml` sets `retries = 0`: a retry would hide a flaky test.

Run with:
    python3 -m unittest discover -s tests/ci_policy -p 'test_nextest_pin.py' -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHA = re.compile(r"^[0-9a-f]{40}$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")


def violations(ci_yml, nextest_toml):
    out = []
    refs = re.findall(r"uses:\s*taiki-e/install-action@(\S+)", ci_yml)
    if not refs:
        out.append("ci.yml has no taiki-e/install-action step")
    out += [f"taiki-e/install-action@{r} is not a full commit SHA" for r in refs if not SHA.match(r)]
    tools = re.findall(r"^\s*tool:\s*(\S+)", ci_yml, re.M)
    nextest = [t for t in tools if t.startswith("cargo-nextest")]
    if len(nextest) != 1:
        out.append(f"ci.yml must install cargo-nextest exactly once, found {nextest}")
    for t in nextest:
        m = re.fullmatch(r"cargo-nextest@(\S+)", t)
        if not m or not VERSION.match(m.group(1)):
            out.append(f"cargo-nextest must be pinned to an exact X.Y.Z, found {t!r}")
    if not re.search(r"cargo nextest run\b", ci_yml):
        out.append("ci.yml does not run `cargo nextest run`")
    retries = re.findall(r"^\s*retries\s*=\s*(.+?)\s*$", nextest_toml, re.M)
    if retries != ["0"]:
        out.append(f".config/nextest.toml must set retries = 0 exactly once, found {retries}")
    return out


class NextestPinTests(unittest.TestCase):
    def test_real_tree_is_pinned(self):
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        toml = (ROOT / ".config/nextest.toml").read_text()
        self.assertEqual(violations(ci, toml), [])


class NextestPinBitesTests(unittest.TestCase):
    CI = (
        "uses: taiki-e/install-action@fe3acb53a98b62c772db35de75ce0e4595e7ca8c # v2.90.8\n"
        "with:\n  tool: cargo-nextest@0.9.152\n"
        "run: cargo nextest run --no-fail-fast\n"
    )
    TOML = "[profile.default]\nretries = 0\n"

    def test_consistent_passes(self):
        self.assertEqual(violations(self.CI, self.TOML), [])

    def test_tag_instead_of_sha_fails(self):
        self.assertTrue(violations(self.CI.replace("fe3acb53a98b62c772db35de75ce0e4595e7ca8c", "v2"), self.TOML))

    def test_floating_version_fails(self):
        self.assertTrue(violations(self.CI.replace("@0.9.152", ""), self.TOML))
        self.assertTrue(violations(self.CI.replace("@0.9.152", "@latest"), self.TOML))
        self.assertTrue(violations(self.CI.replace("@0.9.152", "@0.9"), self.TOML))

    def test_retries_fail(self):
        self.assertTrue(violations(self.CI, "[profile.default]\nretries = 2\n"))
        self.assertTrue(violations(self.CI, "[profile.default]\n"))

    def test_not_running_nextest_fails(self):
        self.assertTrue(violations(self.CI.replace("cargo nextest run", "cargo test"), self.TOML))


if __name__ == "__main__":
    unittest.main()
