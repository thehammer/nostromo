"""The nightly deep fuzz (`.github/workflows/deep-fuzz.yml`).

A failing nightly must not be a red run nobody opens, and neither of its two steps may hide the
other. The properties a YAML edit could silently lose, each with a "bites" test (stdlib only):

1. the second Rust step runs even when the first failed (`if: always()`), so one night reports both;
2. a `notify-failure` job opens (or comments on) an issue when a SCHEDULED run fails: it needs the
   fuzz job, runs only on `failure()` of a `schedule` event, and creates an issue with the repo's own
   token;
3. permissions stay minimal: the workflow is `contents: read` and `issues: write` appears only on the
   notify job, which has no checkout and no secrets.

Run with (from the repo root):
    python3 -I -m unittest discover -s tests/ci_policy -p 'test_deep_fuzz_workflow.py' -v
"""

import re
import unittest
from pathlib import Path

import test_ci_dispatch as d
from workflow_steps import step_blocks

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "deep-fuzz.yml"


def _step_if(block):
    m = re.search(r"(?m)^        if:[ \t]*(.*?)[ \t]*$", block)
    return None if m is None else m.group(1)


def violations(text):
    out = []
    blocks = d._job_blocks(text)

    fuzz = blocks.get("deep-fuzz", "")
    cargo_steps = [b for b in step_blocks(fuzz) if re.search(r"(?m)^        run: cargo test\b", b)]
    if len(cargo_steps) != 2:
        out.append(f"deep-fuzz must run two `cargo test` steps, found {len(cargo_steps)}")
    elif not re.search(r"\balways\(\)", _step_if(cargo_steps[1]) or ""):
        out.append("the second `cargo test` step must have `if: always()` so it runs after a failure of the first")
    elif _step_if(cargo_steps[0]):
        out.append("the first `cargo test` step must not be conditional")

    notify = blocks.get("notify-failure")
    if notify is None:
        out.append("no `notify-failure` job: a failed nightly opens no issue")
    else:
        if not re.search(r"(?m)^    needs:\s*(\[\s*deep-fuzz\s*\]|deep-fuzz)\s*$", notify):
            out.append("notify-failure must need deep-fuzz")
        cond = d._job_level(notify, "if") or ""
        if "failure()" not in cond or "github.event_name == 'schedule'" not in cond:
            out.append("notify-failure must run only on `failure()` of a scheduled run")
        if "gh issue create" not in notify:
            out.append("notify-failure never runs `gh issue create`")
        if "GH_TOKEN: ${{ github.token }}" not in notify:
            out.append("notify-failure must use the workflow's own token (github.token)")
        if re.search(r"(?m)^    permissions:\n      issues: write\n(?!      )", notify) is None:
            out.append("notify-failure's permissions must be exactly `issues: write`")
        if "actions/checkout" in notify or "secrets." in notify:
            out.append("notify-failure needs no checkout and no secrets")

    if not re.search(r"(?m)^permissions:\n  contents: read\n", text):
        out.append("workflow-level permissions must be `contents: read`")
    for key, block in blocks.items():
        if key != "notify-failure" and re.search(r"(?m)^    permissions:", block):
            out.append(f"job `{key}` must not widen permissions")
    code = d._strip_comments(text)
    if len(re.findall(r"issues:\s*write", code)) != 1:
        out.append("`issues: write` must appear exactly once (on the notify job)")
    if re.search(r"(?m)^\s*(contents|actions|pull-requests|id-token):\s*write", code):
        out.append("no job here needs a write scope other than `issues`")
    return out


GOOD = """name: deep-fuzz
on:
  schedule:
    - cron: "17 7 * * *"
permissions:
  contents: read
jobs:
  deep-fuzz:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
      - name: Tracker lost-edit oracle
        run: cargo test --test tracker_concurrency -- --nocapture
      - name: Queue race tests
        if: always()
        run: cargo test --lib ipc::session_manager::queue_tests -- --nocapture
  notify-failure:
    needs: deep-fuzz
    if: ${{ failure() && github.event_name == 'schedule' }}
    runs-on: ubuntu-24.04
    permissions:
      issues: write
    steps:
      - name: Open an issue
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh issue create --title t --body b
"""


class DeepFuzzWorkflowTests(unittest.TestCase):
    def test_the_real_workflow_holds_every_property(self):
        self.assertEqual(violations(WORKFLOW.read_text()), [])

    def test_the_synthetic_good_workflow_passes(self):
        self.assertEqual(violations(GOOD), [])

    def test_bites_without_always_on_the_second_step(self):
        bad = GOOD.replace("        if: always()\n", "")
        self.assertTrue(any("always()" in v for v in violations(bad)))

    def test_a_comment_mentioning_always_does_not_satisfy_the_second_step(self):
        bad = GOOD.replace("        if: always()\n", "        # if: always()\n")
        self.assertTrue(violations(bad))

    def test_bites_on_a_conditional_first_step(self):
        bad = GOOD.replace("      - name: Tracker lost-edit oracle\n", "      - name: Tracker lost-edit oracle\n        if: success()\n")
        self.assertTrue(violations(bad))

    def test_bites_without_the_notify_job(self):
        bad = GOOD[:GOOD.index("  notify-failure:")]
        self.assertTrue(any("notify-failure" in v for v in violations(bad)))

    def test_bites_when_notify_runs_on_every_failure_or_on_success(self):
        self.assertTrue(violations(GOOD.replace(" && github.event_name == 'schedule'", "")))
        self.assertTrue(violations(GOOD.replace("failure() && ", "")))
        self.assertTrue(violations(GOOD.replace("    needs: deep-fuzz\n", "")))

    def test_bites_on_widened_permissions(self):
        self.assertTrue(violations(GOOD.replace("      issues: write\n", "      issues: write\n      contents: write\n")))
        self.assertTrue(violations(GOOD.replace("permissions:\n  contents: read\n", "permissions:\n  contents: read\n  issues: write\n")))
        self.assertTrue(violations(GOOD.replace("    permissions:\n      issues: write\n", "")))
        wide = GOOD.replace("    runs-on: ubuntu-24.04\n    steps:\n      - uses", "    runs-on: ubuntu-24.04\n    permissions:\n      issues: write\n    steps:\n      - uses", 1)
        self.assertTrue(violations(wide))

    def test_bites_on_a_checkout_or_secret_in_the_notify_job(self):
        bad = GOOD.replace("      - name: Open an issue\n", "      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0\n      - name: Open an issue\n")
        self.assertTrue(violations(bad))
        self.assertTrue(violations(GOOD.replace("${{ github.token }}", "${{ secrets.PAT }}")))


if __name__ == "__main__":
    unittest.main()
