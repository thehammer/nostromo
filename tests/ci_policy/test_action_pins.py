"""Every action a workflow uses is pinned to a full commit SHA, with a version comment.

A tag (`@v4`, even `@v4.4.0`) is a movable ref: whoever controls the action's repository, or
whoever compromises it, can change what the tag runs in this repository's CI (which holds the
release and signing context). A commit SHA cannot move. The trailing `# vX.Y.Z` comment says which
release the SHA is, so a bump reads as a diff between two versions.

Policy: first-party actions (`actions/*`) are pinned too; there is no allow-list. Local actions
(`uses: ./path`) are in this repository already and need no pin. `docker://` references must name
an `@sha256:` digest. This covers step-level and job-level (`uses:` of a reusable workflow) lines in
every `.github/workflows/*.y*ml`.

To bump one: resolve the new release tag to its commit with
`gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object` (a tag object, `type: tag`, needs one
more `git/tags/<sha>` hop), confirm the SHA is the tag's with `git ls-remote --tags
https://github.com/<owner>/<repo>.git`, then write `@<sha> # <tag>`.

Run with (from the repo root):
    python3 -I -m unittest discover -s tests/ci_policy -p 'test_action_pins.py' -v
"""

import re
import unittest
from pathlib import Path

from test_linux_runner_pin import workflow_files

ROOT = Path(__file__).resolve().parents[2]
USES_LINE = re.compile(r"^[ \t]*(?:-[ \t]+)?uses:[ \t]*(?P<value>[^\s#]+)(?:[ \t]+#[ \t]*(?P<comment>.*?))?[ \t]*$")
SHA = re.compile(r"^[0-9a-f]{40}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")


def violations(name, text):
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        m = USES_LINE.match(line)
        if not m:
            if re.match(r"^[ \t]*(?:-[ \t]+)?uses:", line):
                out.append(f"{name}:{n}: unreadable `uses:` line {line.strip()!r}")
            continue
        value, comment = m.group("value").strip("'\""), m.group("comment")
        where = f"{name}:{n}: {value}"
        if value.startswith("./"):
            continue
        if value.startswith("docker://"):
            if not DIGEST.match(value.partition("@")[2]):
                out.append(f"{where} is not pinned to an @sha256: digest")
            continue
        _, at, ref = value.partition("@")
        if not at or not SHA.match(ref):
            out.append(f"{where} is not pinned to a full 40-character commit SHA")
        elif not comment:
            out.append(f"{where} has no trailing `# vX.Y.Z` comment naming the release")
    return out


class ActionPinTests(unittest.TestCase):
    def test_every_action_in_every_workflow_is_pinned_by_sha_with_a_version_comment(self):
        files = workflow_files(ROOT / ".github" / "workflows")
        self.assertTrue(files)
        found, out = 0, []
        for f in files:
            text = f.read_text()
            found += len(re.findall(r"(?m)^[ \t]*(?:-[ \t]+)?uses:", text))
            out += violations(f.name, text)
        self.assertGreater(found, 0)
        self.assertEqual(out, [])


class ActionPinBitesTests(unittest.TestCase):
    SHA_A = "11d5960a326750d5838078e36cf38b85af677262"

    def line(self, value, comment=" # v4.4.0"):
        return f"      - uses: {value}{comment}\n"

    def test_a_sha_with_a_comment_passes(self):
        self.assertEqual(violations("x", self.line(f"actions/checkout@{self.SHA_A}")), [])
        self.assertEqual(violations("x", f"    steps:\n      - name: n\n        uses: a/b@{self.SHA_A} # v1\n"), [])

    def test_a_tag_fails_even_a_full_version(self):
        self.assertTrue(violations("x", self.line("actions/checkout@v4", "")))
        self.assertTrue(violations("x", self.line("actions/checkout@v4.4.0")))

    def test_a_branch_a_missing_ref_and_a_short_or_upper_sha_fail(self):
        self.assertTrue(violations("x", self.line("a/b@main")))
        self.assertTrue(violations("x", self.line("a/b")))
        self.assertTrue(violations("x", self.line(f"a/b@{self.SHA_A[:7]}")))
        self.assertTrue(violations("x", self.line(f"a/b@{self.SHA_A.upper()}")))
        self.assertTrue(violations("x", self.line(f"a/b@{self.SHA_A}0")))

    def test_a_third_party_action_is_held_to_the_same_rule_as_first_party(self):
        self.assertTrue(violations("x", self.line("taiki-e/install-action@v2")))
        self.assertTrue(violations("x", self.line("dtolnay/rust-toolchain@stable")))

    def test_a_sha_without_a_version_comment_fails(self):
        self.assertTrue(violations("x", self.line(f"a/b@{self.SHA_A}", "")))
        self.assertTrue(violations("x", self.line(f"a/b@{self.SHA_A}", " #")))

    def test_a_job_level_reusable_workflow_is_checked_too(self):
        self.assertTrue(violations("x", "  call:\n    uses: org/repo/.github/workflows/w.yml@main\n"))
        ok = f"  call:\n    uses: org/repo/.github/workflows/w.yml@{self.SHA_A} # v1.0.0\n"
        self.assertEqual(violations("x", ok), [])

    def test_a_local_action_needs_no_pin(self):
        self.assertEqual(violations("x", self.line("./.github/actions/thing", "")), [])

    def test_a_docker_reference_needs_a_digest(self):
        self.assertTrue(violations("x", self.line("docker://alpine:3.20", "")))
        self.assertEqual(violations("x", self.line("docker://alpine@sha256:" + "a" * 64, "")), [])

    def test_a_commented_out_uses_line_is_ignored_and_quotes_are_read(self):
        self.assertEqual(violations("x", "      # - uses: actions/checkout@v4\n"), [])
        self.assertTrue(violations("x", self.line("'actions/checkout@v4'", "")))

    def test_an_unreadable_uses_line_fails_closed(self):
        self.assertTrue(violations("x", "      - uses:\n"))


if __name__ == "__main__":
    unittest.main()
