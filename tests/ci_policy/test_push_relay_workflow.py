"""The push relay's CI workflow (`.github/workflows/push-relay.yml`).

`infra/push-relay` is a standalone crate that ci.yml never builds, so it has its own workflow. It is
meant to be a REQUIRED status check, which constrains its shape: a workflow that a `paths:` filter
stops from starting reports nothing, so a required check from it would stay "Expected" and block
every unrelated PR. It therefore has no `paths:` filter; a `changes` job decides whether the relay
job runs, and a job skipped by its `if:` counts as passed. The properties a YAML edit could silently
lose, each with a "bites" test (stdlib only, as in the rest of this directory):

1. it runs fmt, clippy with `-D warnings` and the tests, in the crate's directory;
2. it always starts: no `paths:` filter on any trigger; pull_request, push and workflow_dispatch;
3. the relay job has the stable literal name `Push relay (fmt, clippy, tests)`, needs `changes`, and
   is skipped only when `changes` succeeded and found nothing (fail closed otherwise);
4. the `changes` classifier is exercised on real merge commits: relay files run the job, anything
   else skips it on a pull request, and every push or dispatch runs it;
5. the Rust toolchain is the repo's pinned one (SHA-pinned action, `toolchain:` input);
6. every Linux runner is an explicit ubuntu-NN.NN;
7. permissions are read-only, no secrets.

Run with (from the repo root):
    python3 -I -m unittest discover -s tests/ci_policy -p 'test_push_relay_workflow.py' -v
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_ci_dispatch as d
import test_rust_test_hang_guard as hg
import test_rust_toolchain_pin as tc

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "push-relay.yml"
TOOLCHAIN = ROOT / "rust-toolchain.toml"

# The check name the operator adds to branch protection (docs/ci.md has the command).
CHECK_NAME = "Push relay (fmt, clippy, tests)"
CLIPPY = "cargo clip" + "py"  # spelled in two parts so a repo-wide grep for the tool finds only real uses


# The relay job's gate, spelled once: skipped (counts as passed) only when `changes` succeeded and
# found nothing, never when cancelled, and run when `changes` failed.
RELAY_IF = "${{ !cancelled() && (needs.changes.result != 'success' || needs.changes.outputs.relay == 'true') }}"


def pinned_channel(toolchain_toml):
    m = re.search(r'^\s*channel\s*=\s*"([^"]+)"', toolchain_toml, re.M)
    return m.group(1) if m else None


def violations(text, channel):
    out = []
    blocks = d._job_blocks(text)
    relay = blocks.get("push-relay")
    # The commands must be real commands of the relay job (an `echo cargo fmt` or a command in
    # another job does not count).
    commands = []
    for line in (relay or "").splitlines():
        commands.append(re.sub(r"^\s*(?:- )?(?:run:\s*)?", "", line))
    for needed in ("cargo fmt --check", f"{CLIPPY} --all-targets -- -D warnings", f"{CLIPPY} --all-targets --no-default-features -- -D warnings", "cargo test", "cargo test --no-default-features"):
        if not any(c.startswith(needed) for c in commands):
            out.append(f"the relay job never runs `{needed}`")
    if not re.search(r"working-directory:\s*infra/push-relay\b", text):
        out.append("steps do not run in infra/push-relay")
    if re.search(r"(?m)^\s*continue-on-error:\s*(?!false\b)", text):
        out.append("no step or job may set continue-on-error: a failure would not fail the check")

    on = d._top_level_block(text, "on") or []
    triggers = {m.group(1) for l in on if (m := re.match(r"^  ([a-z_]+):", l))}
    for event in ("pull_request", "push", "workflow_dispatch"):
        if event not in triggers:
            out.append(f"`on:` has no {event} trigger")
    if any(re.match(r"^\s+paths(-ignore)?:", l) for l in on):
        out.append("a `paths:` filter stops the workflow from reporting, so it can never be a required check")

    if "changes" not in blocks:
        out.append("no `changes` job to decide whether the relay job is needed")
    if relay is None:
        out.append("no `push-relay` job")
    else:
        name = d._unquote(d._job_level(relay, "name") or "")
        if name != CHECK_NAME:
            out.append(f"the relay job's name must be the literal {CHECK_NAME!r}, found {name!r}")
        if not re.search(r"(?m)^    needs:\s*(\[\s*changes\s*\]|changes)\s*$", relay):
            out.append("the relay job must need `changes`")
        cond = re.sub(r"\s+", " ", d._job_level(relay, "if") or "")
        if cond != RELAY_IF:
            out.append(f"the relay job's `if:` must be exactly {RELAY_IF!r} (skip only when `changes` succeeded and found nothing; fail closed), found {cond!r}")

    toolchains = tc.toolchain_versions(f'[toolchain]\nchannel = "{channel}"\n', text, "")[1]
    if not toolchains:
        out.append("no dtolnay/rust-toolchain step")
    for ref, toolchain in toolchains:
        if not tc.SHA.match(ref):
            out.append(f"dtolnay/rust-toolchain@{ref} is not a full commit SHA")
        if toolchain != channel:
            out.append(f"dtolnay/rust-toolchain names toolchain {toolchain!r}, expected the repo's pin {channel}")
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
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
jobs:
  changes:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
  push-relay:
    name: {CHECK_NAME}
    needs: changes
    if: {RELAY_IF}
    runs-on: ubuntu-24.04
    defaults:
      run:
        working-directory: infra/push-relay
    steps:
      - uses: dtolnay/rust-toolchain@df2a88e9fe4098bad09cb42c3dec7187f15861fc # master
        with:
          toolchain: 1.100.0
      - run: cargo fmt --check
      - run: {CLIPPY} --all-targets -- -D warnings
      - run: {CLIPPY} --all-targets --no-default-features -- -D warnings
      - run: cargo test
      - run: cargo test --no-default-features
"""

PATHS = '    paths:\n      - "infra/push-relay/**"\n'


class PushRelayWorkflowTests(unittest.TestCase):
    def test_the_real_workflow_holds_every_property(self):
        self.assertEqual(violations(WORKFLOW.read_text(), pinned_channel(TOOLCHAIN.read_text())), [])

    def test_the_synthetic_good_workflow_passes(self):
        self.assertEqual(violations(GOOD, "1.100.0"), [])

    def test_bites_without_clippy_deny_warnings(self):
        bad = GOOD.replace(f"{CLIPPY} --all-targets -- -D warnings", CLIPPY)
        self.assertTrue(violations(bad, "1.100.0"))

    def test_bites_on_a_paths_filter_on_either_trigger(self):
        for event in ("pull_request", "push"):
            bad = GOOD.replace(f"  {event}:\n    branches: [main]\n", f"  {event}:\n    branches: [main]\n{PATHS}", 1)
            self.assertNotEqual(bad, GOOD)
            with self.subTest(event=event):
                self.assertTrue(any("paths" in v for v in violations(bad, "1.100.0")))
        ignore = GOOD.replace("  push:\n    branches: [main]\n", "  push:\n    branches: [main]\n    paths-ignore:\n      - docs/**\n")
        self.assertTrue(any("paths" in v for v in violations(ignore, "1.100.0")))

    def test_bites_without_a_trigger(self):
        for event in ("pull_request", "push", "workflow_dispatch"):
            bad = GOOD.replace(f"  {event}:", f"  not_{event}:")
            with self.subTest(event=event):
                self.assertTrue(violations(bad, "1.100.0"))

    def test_bites_on_an_unstable_or_renamed_check(self):
        renamed = GOOD.replace(f"name: {CHECK_NAME}", "name: Push relay")
        self.assertTrue(any("literal" in v for v in violations(renamed, "1.100.0")))
        expr = GOOD.replace(f"name: {CHECK_NAME}", "name: ${{ github.event_name == 'workflow_dispatch' && 'x' || 'Push relay (fmt, clippy, tests)' }}")
        self.assertTrue(any("literal" in v for v in violations(expr, "1.100.0")))

    def test_bites_without_the_changes_gate(self):
        self.assertTrue(violations(GOOD.replace("    needs: changes\n", ""), "1.100.0"))
        no_if = re.sub(r"(?m)^    if: .*\n", "", GOOD)
        self.assertTrue(violations(no_if, "1.100.0"))
        self.assertTrue(violations(GOOD.replace("  changes:\n", "  classify:\n").replace("needs: changes", "needs: classify"), "1.100.0"))

    def test_bites_when_the_relay_if_is_edited_in_any_way(self):
        for label, bad in (
            ("fail-open (no result test)", GOOD.replace("needs.changes.result != 'success' || ", "")),
            ("always() for !cancelled()", GOOD.replace("!cancelled()", "always()")),
            ("no !cancelled()", GOOD.replace("!cancelled() && ", "")),
            ("AND for OR", GOOD.replace("'success' || needs", "'success' && needs")),
            ("always skipped", GOOD.replace("(needs.changes.result", "false && (needs.changes.result")),
            ("extra condition", GOOD.replace(" }}\n    runs-on", " && github.event_name == 'x' }}\n    runs-on", 1)),
            ("inverted output", GOOD.replace("relay == 'true'", "relay == 'false'")),
        ):
            with self.subTest(label=label):
                self.assertNotEqual(bad, GOOD)
                self.assertTrue(any("`if:`" in v for v in violations(bad, "1.100.0")), label)
        spaced = GOOD.replace("!cancelled() &&", "!cancelled()   &&")
        self.assertEqual(violations(spaced, "1.100.0"), [])

    def test_bites_when_a_command_is_not_really_run_by_the_relay_job(self):
        self.assertTrue(violations(GOOD.replace("- run: cargo fmt --check", "- run: echo cargo fmt --check"), "1.100.0"))
        moved = GOOD.replace("      - run: cargo test\n      - run: cargo test --no-default-features\n", "").replace(
            "      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0\n",
            "      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0\n      - run: cargo test\n      - run: cargo test --no-default-features\n", 1)
        self.assertNotEqual(moved, GOOD)
        self.assertTrue(violations(moved, "1.100.0"))
        self.assertTrue(violations(GOOD.replace("      - run: cargo fmt --check\n", "      - run: cargo fmt --check\n        continue-on-error: true\n"), "1.100.0"))

    def test_bites_on_a_moving_toolchain_or_runner(self):
        self.assertTrue(violations(GOOD.replace("df2a88e9fe4098bad09cb42c3dec7187f15861fc", "stable"), "1.100.0"))
        self.assertTrue(violations(GOOD.replace("toolchain: 1.100.0", "toolchain: stable"), "1.100.0"))
        self.assertTrue(violations(GOOD.replace("ubuntu-24.04", "ubuntu-latest"), "1.100.0"))

    def test_bites_on_writable_permissions_and_a_wrong_directory(self):
        self.assertTrue(violations(GOOD.replace("contents: read", "contents: write"), "1.100.0"))
        self.assertTrue(violations(GOOD.replace("working-directory: infra/push-relay", "working-directory: ."), "1.100.0"))

    def test_the_repo_toolchain_pin_is_readable(self):
        self.assertTrue(pinned_channel(TOOLCHAIN.read_text()), "rust-toolchain.toml has no channel")


GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_SYSTEM": os.devnull,
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
}


def classify(script, event, changed, merge=True):
    """Run the `changes` step's script in a throwaway repo and return its `relay=` output.

    `changed` are the paths the PR changes; with `merge` the checked-out HEAD is the merge commit of
    the PR head into the base (as GitHub's pull_request checkout is), otherwise a plain commit.
    """
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp) / "repo"
        repo.mkdir()
        env = {**os.environ, **GIT_ENV}

        def git(*args):
            subprocess.run(["git", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main", *args],
                           cwd=repo, env=env, check=True, capture_output=True)

        def write(paths, content):
            for p in paths:
                (repo / p).parent.mkdir(parents=True, exist_ok=True)
                (repo / p).write_text(content)

        git("init", "-q")
        write(["README.md", "infra/push-relay/Cargo.toml", ".github/workflows/push-relay.yml"], "base\n")
        git("add", "-A")
        git("commit", "-q", "-m", "base")
        if merge:
            git("checkout", "-q", "-b", "pr")
            write(changed, "changed\n")
            git("add", "-A")
            git("commit", "-q", "-m", "pr")
            git("checkout", "-q", "main")
            write(["other.txt"], "x\n")  # the base moved on: the PR diff must be HEAD^1..HEAD, not main..pr
            git("add", "-A")
            git("commit", "-q", "-m", "base moved")
            git("merge", "-q", "--no-ff", "-m", "merge", "pr")
        else:
            write(changed, "changed\n")
            git("add", "-A")
            git("commit", "-q", "-m", "push")
        out_file = Path(tmp) / "output"
        # GitHub runs `run:` steps as `bash --noprofile --norc -eo pipefail {0}`.
        run = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script], cwd=repo, capture_output=True, text=True,
                             env={**env, "EVENT_NAME": event, "GITHUB_OUTPUT": str(out_file)})
        assert run.returncode == 0, run.stderr
        return out_file.read_text().strip()


class PushRelayChangesClassifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        text = WORKFLOW.read_text()
        cls.script = hg._run_script(hg._step(hg._job(text, "changes"), "Classify changed paths"))

    def test_a_pull_request_touching_only_other_paths_skips_the_relay(self):
        self.assertEqual(classify(self.script, "pull_request", ["README.md", "docs/a.md"]), "relay=false")

    def test_a_pull_request_touching_the_relay_runs_it(self):
        self.assertEqual(classify(self.script, "pull_request", ["infra/push-relay/src/main.rs"]), "relay=true")
        self.assertEqual(classify(self.script, "pull_request", ["README.md", "infra/push-relay/Cargo.toml"]), "relay=true")

    def test_a_pull_request_touching_the_workflow_file_runs_it(self):
        self.assertEqual(classify(self.script, "pull_request", [".github/workflows/push-relay.yml"]), "relay=true")

    def test_a_very_long_changed_file_list_still_finds_the_relay(self):
        # Past the 64 KB pipe buffer an early-exiting `grep -q` fed by `printf |` kills printf with
        # SIGPIPE, and under `pipefail` a negated pipeline then reads as "no match".
        many = [f"docs/generated/{'x' * 60}-{i:04d}.md" for i in range(1500)]  # about 115 KB of names
        self.assertEqual(classify(self.script, "pull_request", [".github/workflows/push-relay.yml", *many]), "relay=true")

    def test_a_lookalike_path_does_not_run_it(self):
        self.assertEqual(classify(self.script, "pull_request", ["infra/push-relay-docs/a.md", "x/infra/push-relay/a"]), "relay=false")

    def test_pushes_and_dispatches_always_run_it(self):
        self.assertEqual(classify(self.script, "push", ["README.md"], merge=False), "relay=true")
        self.assertEqual(classify(self.script, "workflow_dispatch", ["README.md"], merge=False), "relay=true")
        self.assertEqual(classify(self.script, "push", ["README.md"]), "relay=true")

    def test_a_pull_request_checkout_that_is_not_a_merge_commit_runs_it(self):
        self.assertEqual(classify(self.script, "pull_request", ["README.md"], merge=False), "relay=true")

    def test_the_classifier_bites_when_it_never_skips_or_never_runs(self):
        always = self.script.replace("relay=false", "relay=true")
        self.assertNotEqual(always, self.script)
        self.assertEqual(classify(always, "pull_request", ["README.md"]), "relay=true")  # what a broken skip yields
        never = self.script.replace("relay=true\n", "relay=false\n", 1)
        self.assertNotEqual(never, self.script)
        self.assertEqual(classify(never, "push", ["README.md"], merge=False), "relay=false")


if __name__ == "__main__":
    unittest.main()
