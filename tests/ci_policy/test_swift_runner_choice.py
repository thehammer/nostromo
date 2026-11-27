"""The Swift jobs must not need a macOS runner when the path classifier skipped their steps.

Docs-only PRs #521 and #522 (2026-11-23, GitHub macOS capacity shortage) sat 40-49 min on
`Mac tests shard N/3` and `Swift tests (NostromoKit)` waiting for a macOS runner to run zero
steps, then failed. The shard, NostromoKit and iOS jobs therefore pick `runs-on` from
`needs.changes.outputs.swift`. A job-level `if:` on the classifier is NOT the fix: a skipped job
posts its check under the raw `name:` expression, so a required check stays "Expected" (PR #370).

Each rule is a check function over the workflow text; the "bites" tests mutate the real file in
memory and require the check to fail. Stdlib only.

    python3 -I -m unittest discover -s tests/ci_policy -p 'test_swift_runner_choice.py' -v
"""

import re
import unittest
from pathlib import Path

import test_ci_dispatch as d

CI_YML = Path(d.CI_YML_PATH)
RUNNER_JOBS = (d.SHARD_JOB, "swift-tests-kit", "ios-simulator-build")
# Check names GitHub branch protection requires on main -> job key whose `name:` yields them.
REQUIRED = {
    "Build & Lint": "build",
    "Swift tests (Mac app)": "swift-tests-mac",
    "Swift tests (NostromoKit)": "swift-tests-kit",
    "iOS simulator build": "ios-simulator-build",
}


def check_runs_on_follows_the_classifier(text):
    blocks = d._job_blocks(text)
    out = []
    for key in RUNNER_JOBS:
        got = d._job_level(blocks.get(key, ""), "runs-on")
        if got != d.SWIFT_RUNS_ON:
            out.append("job `%s` runs-on is %r, expected %r" % (key, got, d.SWIFT_RUNS_ON))
    return out


def check_no_job_level_if_on_the_classifier(text):
    blocks = d._job_blocks(text)
    out = []
    for key in RUNNER_JOBS:
        cond = d._job_level(blocks.get(key, ""), "if") or ""
        if "outputs.swift" in cond:
            out.append("job `%s` has a job-level `if:` on the classifier: %r" % (key, cond))
    return out


def _split_top_level(expr, op):
    """`expr` split on `op` outside quotes and parentheses (GitHub expression syntax: strings are
    single-quoted, `''` is a quote inside one)."""
    parts, depth, start, i = [], 0, 0, 0
    while i < len(expr):
        c = expr[i]
        if c == "'":
            i += 1
            while i < len(expr) and not (expr[i] == "'" and expr[i + 1:i + 2] != "'"):
                i += 2 if expr[i:i + 2] == "''" else 1
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and expr.startswith(op, i):
            parts.append(expr[start:i])
            start = i + len(op)
            i += len(op) - 1
        i += 1
    parts.append(expr[start:])
    return [p.strip() for p in parts]


def _literal(operand):
    """The string a single-quoted literal or `format('literal', ...)` call produces, else None."""
    m = re.fullmatch(r"'((?:[^']|'')*)'", operand)
    if m is None:
        m = re.fullmatch(r"format\(\s*'((?:[^']|'')*)'\s*(?:,.*)?\)", operand, re.S)
    return None if m is None else m.group(1).replace("''", "'")


def final_name(name_value):
    """The check name a job's `name:` value yields when no earlier branch applies.

    A plain scalar is its own value. An expression `${{ A && 'x' || B || 'Check' }}` is read by
    splitting on its top-level `||` and taking the last operand, so spacing, quoting style and
    a `format('Check', ...)` call do not matter. None when the last operand is not a literal.
    """
    value = d._unquote(name_value.strip())
    m = re.fullmatch(r"\$\{\{(.*)\}\}", value, re.S)
    if m is None:
        return value
    return _literal(_split_top_level(m.group(1).strip(), "||")[-1])


def check_required_names_are_produced(text):
    """The final branch of each required job's `name:` is exactly the required check."""
    blocks = d._job_blocks(text)
    out = []
    for check, key in REQUIRED.items():
        name = d._job_level(blocks.get(key, ""), "name") or ""
        if final_name(name) != check:
            out.append("job `%s` name %r does not evaluate to %r" % (key, name, check))
    return out


def check_macos_label_when_swift_true(text):
    expr = d._job_level(d._job_blocks(text).get(d.SHARD_JOB, ""), "runs-on") or ""
    return [] if re.search(r"== 'true' && 'macos-26' \|\|", expr) else ["swift=true no longer selects macos-26"]


def check_python_tooling_stays_on_macos_ungated(text):
    # Python tooling tests stays on macOS, ungated (needs codesign/lipo).
    block = d._job_blocks(text).get("python-tooling", "")
    out = []
    if d._job_level(block, "runs-on") != "macos-26":
        out.append("python-tooling must stay on macos-26 (pinned, not macos-latest)")
    if "needs.changes" in block:
        out.append("python-tooling must stay ungated")
    return out


CHECKS = (
    check_runs_on_follows_the_classifier,
    check_no_job_level_if_on_the_classifier,
    check_required_names_are_produced,
    check_macos_label_when_swift_true,
    check_python_tooling_stays_on_macos_ungated,
)


def mutate_job(text, key, fn):
    """Apply `fn` to the raw (comments kept) text of job `key`; assert something changed."""
    m = re.search(r"(?ms)^  %s:\n.*?(?=^  [A-Za-z0-9_-]+:\n|\Z)" % re.escape(key), text)
    assert m, key
    new = fn(m.group(0))
    assert new != m.group(0), "mutation was a no-op"
    return text[:m.start()] + new + text[m.end():]


class RealWorkflowTests(unittest.TestCase):
    def test_real_ci_yml_passes_every_check(self):
        text = CI_YML.read_text()
        for check in CHECKS:
            with self.subTest(check=check.__name__):
                self.assertEqual(check(text), [])


class BitesTests(unittest.TestCase):
    """Mutation proofs: each deliberate regression must trip its check."""

    def setUp(self):
        self.text = CI_YML.read_text()

    def test_reverting_runs_on_to_macos_fails(self):
        for key in RUNNER_JOBS:
            mutated = mutate_job(self.text, key, lambda b: b.replace(d.SWIFT_RUNS_ON, "macos-26"))
            with self.subTest(job=key):
                self.assertTrue(check_runs_on_follows_the_classifier(mutated))

    def test_always_linux_fails_the_macos_label_check(self):
        mutated = mutate_job(
            self.text, d.SHARD_JOB, lambda b: b.replace(d.SWIFT_RUNS_ON, "ubuntu-24.04"))
        self.assertTrue(check_macos_label_when_swift_true(mutated))

    def test_job_level_if_on_the_classifier_fails(self):
        for key in RUNNER_JOBS:
            mutated = mutate_job(
                self.text, key,
                lambda b: b.replace("\n    if: ", "\n    if: needs.changes.outputs.swift == 'true' && ", 1))
            with self.subTest(job=key):
                self.assertTrue(check_no_job_level_if_on_the_classifier(mutated))

    def test_renaming_a_required_job_fails(self):
        for check, key in REQUIRED.items():
            mutated = mutate_job(
                self.text, key,
                lambda b: re.sub(r"(?m)^    name: .*$", "    name: Renamed check", b, count=1))
            with self.subTest(check=check):
                self.assertTrue(check_required_names_are_produced(mutated))

    def test_moving_python_tooling_off_macos_fails(self):
        mutated = mutate_job(
            self.text, "python-tooling", lambda b: b.replace("macos-26", "ubuntu-24.04"))
        self.assertTrue(check_python_tooling_stays_on_macos_ungated(mutated))

    def test_unpinning_python_tooling_fails(self):
        mutated = mutate_job(
            self.text, "python-tooling", lambda b: b.replace("macos-26", "macos-latest"))
        self.assertTrue(check_python_tooling_stays_on_macos_ungated(mutated))


class FinalNameParserTests(unittest.TestCase):
    """The name parser reads the expression, not one spelling of it."""

    def test_the_real_spelling(self):
        self.assertEqual(
            final_name("${{ github.event_name == 'workflow_dispatch' && 'Build & Lint (dispatch)' || 'Build & Lint' }}"),
            "Build & Lint")

    def test_a_harmless_reformat_still_parses(self):
        for value in (
            "${{github.event_name=='workflow_dispatch'&&'X (dispatch)'||'X'}}",
            "${{   github.event_name == 'workflow_dispatch'   &&   'X (dispatch)'   ||   'X'   }}",
            '"${{ github.event_name == \'workflow_dispatch\' && \'X (dispatch)\' || \'X\' }}"',
            "X",
            "'X'",
            "${{ format('X') }}",
            "${{ github.event_name == 'workflow_dispatch' && format('X {0} (dispatch)', matrix.shard) || format('X', matrix.shard) }}",
        ):
            with self.subTest(value=value):
                self.assertEqual(final_name(value), "X")

    def test_an_or_inside_a_string_or_call_is_not_a_branch(self):
        self.assertEqual(final_name("${{ a && 'p || q' || 'X' }}"), "X")
        self.assertEqual(final_name("${{ a && 'p' || format('X || {0}', b) }}"), "X || {0}")
        self.assertEqual(final_name("${{ a && 'it''s' || 'X' }}"), "X")
        self.assertEqual(final_name("${{ a && 'x' || 'p || X' }}"), "p || X")
        self.assertEqual(final_name("${{ a && 'x' || format('p ) || X', b) }}"), "p ) || X")

    def test_a_final_branch_that_is_not_a_literal_is_none(self):
        self.assertIsNone(final_name("${{ a && 'X' || github.job }}"))
        self.assertIsNone(final_name("${{ a && 'X' || b.c }}"))

    def test_a_reformatted_real_workflow_still_passes_the_check(self):
        text = CI_YML.read_text()
        reformatted = text.replace("' || 'Build & Lint' }}", "'||'Build & Lint'}}")
        self.assertNotEqual(reformatted, text)
        self.assertEqual(check_required_names_are_produced(reformatted), [])

    def test_a_wrong_final_branch_fails_the_check(self):
        text = CI_YML.read_text()
        mutated = text.replace("|| 'Build & Lint' }}", "|| 'Build and Lint' }}")
        self.assertNotEqual(mutated, text)
        self.assertTrue(check_required_names_are_produced(mutated))


if __name__ == "__main__":
    unittest.main()
