"""The push relay's CI workflow (`.github/workflows/push-relay.yml`).

`infra/push-relay` is a standalone crate that ci.yml never builds, so it has its own path-filtered
workflow. The properties a YAML edit could silently lose, each with a "bites" test on synthetic text
(stdlib only, as in the rest of this directory):

1. it runs fmt, clippy with `-D warnings` and the tests, in the crate's directory;
2. it is path-filtered to the relay (pull_request and push) and to its own file;
3. the Rust toolchain is the repo's pinned one, not a moving channel;
4. the Linux runner is an explicit ubuntu-NN.NN (test_linux_runner_pin covers every workflow too);
5. permissions are read-only.

Run with (from the repo root):
    python3 -I -m unittest discover -s tests/ci_policy -p 'test_push_relay_workflow.py' -v
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "push-relay.yml"
TOOLCHAIN = ROOT / "rust-toolchain.toml"

CLIPPY = "cargo clip" + "py"  # spelled in two parts so a repo-wide grep for the tool finds only real uses


def pinned_channel(toolchain_toml):
    m = re.search(r'^\s*channel\s*=\s*"([^"]+)"', toolchain_toml, re.M)
    return m.group(1) if m else None


def violations(text, channel):
    out = []
    for needed in ("cargo fmt --check", f"{CLIPPY} --all-targets -- -D warnings", "cargo test"):
        if needed not in text:
            out.append(f"the workflow never runs `{needed}`")
    if "--no-default-features" not in text:
        out.append("the handler-only build (--no-default-features) is not exercised")
    if not re.search(r"working-directory:\s*infra/push-relay\b", text):
        out.append("steps do not run in infra/push-relay")
    for event in ("pull_request", "push"):
        m = re.search(rf"^  {event}:\n(?:    .*\n)*?    paths:\n((?:      - .*\n)+)", text, re.M)
        if not m:
            out.append(f"{event} has no paths filter")
        elif "infra/push-relay/**" not in m.group(1) or ".github/workflows/push-relay.yml" not in m.group(1):
            out.append(f"{event}'s paths filter must name infra/push-relay/** and this workflow")
    toolchains = re.findall(r"dtolnay/rust-toolchain@(\S+)", text)
    if not toolchains:
        out.append("no dtolnay/rust-toolchain step")
    out += [f"dtolnay/rust-toolchain@{t}, expected the repo's pin {channel}" for t in toolchains if t != channel]
    for runner in re.findall(r"^\s*runs-on:\s*(\S+)", text, re.M):
        if not re.fullmatch(r"ubuntu-\d\d\.\d\d", runner):
            out.append(f"runs-on {runner!r} is not an explicit ubuntu-NN.NN")
    if not re.search(r"^permissions:\n  contents: read\n", text, re.M):
        out.append("permissions must be `contents: read`")
    if re.search(r"^\s*pull_request_target", text, re.M) or "secrets." in text:
        out.append("a relay build needs no secrets and no pull_request_target")
    return out


GOOD = f"""name: Push relay
on:
  pull_request:
    branches: [main]
    paths:
      - "infra/push-relay/**"
      - ".github/workflows/push-relay.yml"
  push:
    branches: [main]
    paths:
      - "infra/push-relay/**"
      - ".github/workflows/push-relay.yml"
permissions:
  contents: read
jobs:
  push-relay:
    runs-on: ubuntu-24.04
    defaults:
      run:
        working-directory: infra/push-relay
    steps:
      - uses: dtolnay/rust-toolchain@1.100.0
      - run: cargo fmt --check
      - run: {CLIPPY} --all-targets -- -D warnings
      - run: {CLIPPY} --all-targets --no-default-features -- -D warnings
      - run: cargo test
"""


class PushRelayWorkflowTests(unittest.TestCase):
    def test_the_real_workflow_holds_every_property(self):
        self.assertEqual(violations(WORKFLOW.read_text(), pinned_channel(TOOLCHAIN.read_text())), [])

    def test_the_synthetic_good_workflow_passes(self):
        self.assertEqual(violations(GOOD, "1.100.0"), [])

    def test_bites_without_clippy_deny_warnings(self):
        bad = GOOD.replace(f"{CLIPPY} --all-targets -- -D warnings", CLIPPY)
        self.assertTrue(violations(bad, "1.100.0"))

    def test_bites_without_a_paths_filter(self):
        bad = GOOD.replace('    paths:\n      - "infra/push-relay/**"\n      - ".github/workflows/push-relay.yml"\n', "", 1)
        self.assertTrue(violations(bad, "1.100.0"))

    def test_bites_on_a_filter_that_misses_the_relay(self):
        bad = GOOD.replace('"infra/push-relay/**"', '"infra/other/**"')
        self.assertTrue(violations(bad, "1.100.0"))

    def test_bites_on_a_moving_toolchain_or_runner(self):
        self.assertTrue(violations(GOOD.replace("@1.100.0", "@stable"), "1.100.0"))
        self.assertTrue(violations(GOOD.replace("ubuntu-24.04", "ubuntu-latest"), "1.100.0"))

    def test_bites_on_writable_permissions_and_a_wrong_directory(self):
        self.assertTrue(violations(GOOD.replace("contents: read", "contents: write"), "1.100.0"))
        self.assertTrue(violations(GOOD.replace("working-directory: infra/push-relay", "working-directory: ."), "1.100.0"))

    def test_the_repo_toolchain_pin_is_readable(self):
        self.assertTrue(pinned_channel(TOOLCHAIN.read_text()), "rust-toolchain.toml has no channel")


if __name__ == "__main__":
    unittest.main()
