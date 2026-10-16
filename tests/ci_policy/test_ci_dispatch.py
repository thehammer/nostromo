"""Source-scanning policy tests over `.github/workflows/ci.yml` for the manual
`workflow_dispatch` trigger that `make ci-remote` uses to run slices of CI on
GitHub's runners.

RED phase: `ci.yml` has not been modified yet, so every real-file test below
that depends on the dispatch wiring is expected to fail until it is. Like
`test_macos_launch_smoke_workflow.py`, each rule is a text-scanning check
function returning a list of violations, a "bites" companion test proves the
check can fail (run on a synthetic workflow string), and real-file tests run the
checks against the committed `ci.yml`. No YAML parser: stdlib only.

Run with:
    python3 -m unittest discover -s tests/ci_policy -v
"""

import ast
import json
import os
import re
import unittest

REPO_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
CI_YML_PATH = os.path.join(REPO_ROOT, ".github", "workflows", "ci.yml")

ONLY_OPTIONS = ["all", "rust", "python", "swift", "mac", "kit", "ios"]

# job key -> (original display name, selector set that must run it)
JOBS = {
    "build": ("Build & Lint", {"all", "rust"}),
    "python-tooling": ("Python tooling tests", {"all", "python"}),
    "swift-tests-mac": ("Swift tests (Mac app)", {"all", "swift", "mac"}),
    "swift-tests-kit": ("Swift tests (NostromoKit)", {"all", "swift", "kit"}),
    "ios-simulator-build": ("iOS simulator build", {"all", "swift", "ios"}),
}

DISPATCH_NAME_RE = re.compile(
    r"^\s*\$\{\{\s*github\.event_name\s*==\s*'workflow_dispatch'\s*&&\s*'(?P<dispatch>[^']*)'"
    r"\s*\|\|\s*'(?P<plain>[^']*)'\s*\}\}\s*$"
)
IF_RE = re.compile(
    r"^\s*github\.event_name\s*!=\s*'workflow_dispatch'\s*\|\|\s*"
    r"contains\(\s*fromJSON\(\s*'(?P<list>\[[^']*\])'\s*\)\s*,\s*inputs\.only\s*\)\s*$"
)
CANCEL_EXPECTED = "${{ github.event_name == 'pull_request' }}"


# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

def _strip_comments(text):
    """Drop full-line comments (the real file's prose mentions keys such as
    path filters, which must not be mistaken for configuration)."""
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def _indent(l):
    return len(l) - len(l.lstrip(" "))


def _top_level_block(text, key):
    """Lines (without the key line) of a top-level `key:` mapping, comments and
    blanks removed. None if the key is absent."""
    lines = _strip_comments(text).splitlines()
    for i, l in enumerate(lines):
        if re.match(r"^%s:\s*$" % re.escape(key), l):
            body = []
            for nxt in lines[i + 1:]:
                if not nxt.strip():
                    continue
                if _indent(nxt) == 0:
                    break
                body.append(nxt)
            return body
    return None


def _job_blocks(text):
    """{job key: text of that job's block} for two-space-indented `key:` lines
    under `jobs:`. Comments are removed."""
    body = _top_level_block(text, "jobs")
    if body is None:
        return {}
    blocks = {}
    current = None
    for l in body:
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", l)
        if m:
            current = m.group(1)
            blocks[current] = []
        elif current is not None:
            blocks[current].append(l)
    return {k: "\n".join(v) for k, v in blocks.items()}


def _job_level(block, key):
    """Value of a four-space-indented `key: value` line in a job block."""
    m = re.search(r"(?m)^    %s:[ \t]*(.*?)[ \t]*$" % re.escape(key), block)
    return None if m is None else m.group(1)


def _unquote(v):
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'" and not v.startswith("'${{"):
        return v[1:-1]
    return v


# ---------------------------------------------------------------------------
# Checks (each returns a list of violation strings)
# ---------------------------------------------------------------------------

def check_dispatch_trigger_and_only_input(text):
    on = _top_level_block(text, "on")
    if on is None:
        return ["no top-level `on:` block"]
    try:
        wd = next(i for i, l in enumerate(on) if re.match(r"^  workflow_dispatch:\s*$", l))
    except StopIteration:
        return ["`on:` has no `workflow_dispatch:` trigger"]
    wd_lines = []
    for l in on[wd + 1:]:
        if _indent(l) <= 2:
            break
        wd_lines.append(l)
    try:
        only = next(i for i, l in enumerate(wd_lines) if re.match(r"^      only:\s*$", l))
    except StopIteration:
        return ["`workflow_dispatch` has no `only:` input"]
    only_lines = []
    for l in wd_lines[only + 1:]:
        if _indent(l) <= 6:
            break
        only_lines.append(l)

    violations = []
    if not any(re.match(r"^\s+type:\s*choice\s*$", l) for l in only_lines):
        violations.append("`only` input is not `type: choice`")
    if not any(re.match(r"^\s+default:\s*['\"]?all['\"]?\s*$", l) for l in only_lines):
        violations.append("`only` input does not have `default: all`")
    options = []
    in_options = False
    for l in only_lines:
        flow = re.match(r"^\s+options:\s*\[(.*)\]\s*$", l)
        if flow:
            options = [o.strip().strip("'\"") for o in flow.group(1).split(",") if o.strip()]
            continue
        if re.match(r"^\s+options:\s*$", l):
            in_options = True
            continue
        if in_options:
            m = re.match(r"^\s+-\s*['\"]?([^'\"\s]+)['\"]?\s*$", l)
            if m:
                options.append(m.group(1))
            else:
                in_options = False
    if not options:
        violations.append("`only` input has no `options:` list")
    elif sorted(options) != sorted(ONLY_OPTIONS) or len(options) != len(set(options)):
        violations.append(
            "`only` options are %r, expected exactly %r" % (options, ONLY_OPTIONS)
        )
    return violations


def check_job_names_carry_dispatch_suffix(text):
    blocks = _job_blocks(text)
    violations = []
    for key, (original, _) in JOBS.items():
        if key not in blocks:
            violations.append("job `%s` is missing" % key)
            continue
        raw = _job_level(blocks[key], "name")
        if raw is None:
            violations.append("job `%s` has no `name:`" % key)
            continue
        m = DISPATCH_NAME_RE.match(_unquote(raw))
        if m is None:
            violations.append(
                "job `%s` name is %r, not the `github.event_name == 'workflow_dispatch' "
                "&& '<name> (dispatch)' || '<name>'` expression" % (key, raw)
            )
            continue
        if m.group("plain") != original:
            violations.append(
                "job `%s` non-dispatch name is %r, must be exactly %r"
                % (key, m.group("plain"), original)
            )
        if m.group("dispatch") != original + " (dispatch)":
            violations.append(
                "job `%s` dispatch name is %r, must be exactly %r"
                % (key, m.group("dispatch"), original + " (dispatch)")
            )
    return violations


def check_job_if_selects_by_only_input(text):
    blocks = _job_blocks(text)
    violations = []
    for key, (_, selectors) in JOBS.items():
        if key not in blocks:
            violations.append("job `%s` is missing" % key)
            continue
        raw = _job_level(blocks[key], "if")
        if raw is None:
            violations.append("job `%s` has no job-level `if:`" % key)
            continue
        expr = _unquote(raw).strip()
        wrapped = re.match(r"^\$\{\{\s*(.*?)\s*\}\}$", expr)
        if wrapped:
            expr = wrapped.group(1)
        m = IF_RE.match(expr)
        if m is None:
            violations.append(
                "job `%s` `if:` is %r; expected `github.event_name != 'workflow_dispatch' "
                "|| contains(fromJSON('[...]'), inputs.only)` (the `!=` escape keeps "
                "push/PR runs running every job)" % (key, raw)
            )
            continue
        try:
            got = json.loads(m.group("list"))
        except ValueError:
            violations.append("job `%s` selector list is not valid JSON: %r" % (key, m.group("list")))
            continue
        if set(got) != selectors or len(got) != len(set(got)):
            violations.append(
                "job `%s` selectors are %r, expected exactly %r"
                % (key, sorted(got), sorted(selectors))
            )
    return violations


def check_concurrency_is_per_event_and_cancels_only_prs(text):
    clean = _strip_comments(text)
    groups = re.findall(r"(?m)^\s*group:[ \t]*(.*?)[ \t]*$", clean)
    cancels = re.findall(r"(?m)^\s*cancel-in-progress:[ \t]*(.*?)[ \t]*$", clean)
    violations = []
    if len(groups) < 3:
        violations.append("expected at least 3 concurrency groups (the swift jobs), found %d" % len(groups))
    for g in groups:
        if "github.event_name" not in g:
            violations.append(
                "concurrency group %r does not include `github.event_name`; a dispatch "
                "run would share a group with (and cancel) a PR run" % g
            )
    if len(cancels) < 3:
        violations.append("expected at least 3 `cancel-in-progress:` lines, found %d" % len(cancels))
    for c in cancels:
        if _unquote(c) != CANCEL_EXPECTED:
            violations.append(
                "`cancel-in-progress: %s` must be exactly `%s`" % (c, CANCEL_EXPECTED)
            )
    return violations


def check_permissions_are_read_only(text):
    body = _top_level_block(text, "permissions")
    violations = []
    if body is None:
        violations.append("no workflow-level `permissions:` block")
    elif [l.strip() for l in body] != ["contents: read"]:
        violations.append(
            "workflow `permissions:` is %r, must be exactly ['contents: read']"
            % [l.strip() for l in body]
        )
    for m in re.finditer(r"(?m)^\s*([a-z-]+):\s*write\b", _strip_comments(text)):
        violations.append("a `%s: write` permission is present" % m.group(1))
    return violations


def check_no_path_filters(text):
    return [
        "path filter `%s` is present; a skipped path-filtered job reports as passing" % m.group(1)
        for m in re.finditer(r"(?m)^\s*(paths(?:-ignore)?):", _strip_comments(text))
    ]


# ---------------------------------------------------------------------------
# Synthetic workflow used by the "bites" tests
# ---------------------------------------------------------------------------

def good_workflow(
    options=tuple(ONLY_OPTIONS),
    names=None,
    ifs=None,
    group_suffix="${{ github.event_name }}-${{ github.ref }}",
    cancel=CANCEL_EXPECTED,
    permissions=("contents: read",),
    extra_job_lines="",
    only_type="choice",
    only_default="all",
):
    names = names or {}
    ifs = ifs or {}
    opts = "\n".join("          - %s" % o for o in options)
    perms = "\n".join("  %s" % p for p in permissions)
    out = [
        "name: CI",
        "",
        "on:",
        "  push:",
        "    branches: [main]",
        "  pull_request:",
        "    branches: [main]",
        "  workflow_dispatch:",
        "    inputs:",
        "      only:",
        "        description: which slice",
        "        type: %s" % only_type,
        "        default: %s" % only_default,
        "        options:",
        opts,
        "",
        "# a comment mentioning paths: and actions: write must be ignored",
        "permissions:",
        perms,
        "",
        "jobs:",
    ]
    for key, (original, selectors) in JOBS.items():
        name = names.get(
            key,
            "${{ github.event_name == 'workflow_dispatch' && '%s (dispatch)' || '%s' }}"
            % (original, original),
        )
        cond = ifs.get(
            key,
            "github.event_name != 'workflow_dispatch' || contains(fromJSON('%s'), inputs.only)"
            % json.dumps(sorted(selectors)),
        )
        out.append("  %s:" % key)
        if name is not None:
            out.append("    name: %s" % name)
        if cond is not None:
            out.append("    if: %s" % cond)
        out.append("    runs-on: ubuntu-latest")
        out.append("    concurrency:")
        out.append("      group: %s-%s" % (key, group_suffix))
        out.append("      cancel-in-progress: %s" % cancel)
        if extra_job_lines:
            out.append(extra_job_lines)
        out += [
            "    steps:",
            "      - uses: actions/checkout@v4",
            "      - name: Build & Lint inside a step",
            "        if: failure()",
            "        run: true",
            "",
        ]
    return "\n".join(out)


def _without_line(text, predicate):
    return "\n".join(l for l in text.splitlines() if not predicate(l))


def _real_ci_yml():
    with open(CI_YML_PATH, "r", encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------------------
# Synthetic baseline sanity
# ---------------------------------------------------------------------------

class SyntheticBaselineTests(unittest.TestCase):
    def test_the_good_synthetic_workflow_satisfies_every_check(self):
        text = good_workflow()
        for check in (
            check_dispatch_trigger_and_only_input,
            check_job_names_carry_dispatch_suffix,
            check_job_if_selects_by_only_input,
            check_concurrency_is_per_event_and_cancels_only_prs,
            check_permissions_are_read_only,
            check_no_path_filters,
        ):
            self.assertEqual(check(text), [], check.__name__)

    def test_job_block_splitter_finds_all_five_jobs(self):
        self.assertEqual(sorted(_job_blocks(good_workflow())), sorted(JOBS))


# ---------------------------------------------------------------------------
# 1. workflow_dispatch with an `only` choice input
# ---------------------------------------------------------------------------

class DispatchTriggerTests(unittest.TestCase):
    def test_bites_without_workflow_dispatch(self):
        text = good_workflow().replace("  workflow_dispatch:", "  schedule:")
        self.assertTrue(check_dispatch_trigger_and_only_input(text))

    def test_bites_when_option_missing(self):
        self.assertTrue(check_dispatch_trigger_and_only_input(
            good_workflow(options=[o for o in ONLY_OPTIONS if o != "ios"])))

    def test_bites_when_extra_option(self):
        self.assertTrue(check_dispatch_trigger_and_only_input(
            good_workflow(options=ONLY_OPTIONS + ["docs"])))

    def test_flow_style_options_list_is_accepted_and_still_checked(self):
        block = "        options:\n" + "\n".join("          - %s" % o for o in ONLY_OPTIONS)
        good = good_workflow()
        self.assertIn(block, good)
        flow = good.replace(block, "        options: [%s]" % ", ".join(ONLY_OPTIONS))
        self.assertEqual(check_dispatch_trigger_and_only_input(flow), [])
        bad = good.replace(block, "        options: [all, rust]")
        self.assertTrue(check_dispatch_trigger_and_only_input(bad))

    def test_bites_when_not_a_choice(self):
        self.assertTrue(check_dispatch_trigger_and_only_input(good_workflow(only_type="string")))

    def test_bites_when_default_is_not_all(self):
        self.assertTrue(check_dispatch_trigger_and_only_input(good_workflow(only_default="kit")))

    def test_real_ci_yml_has_dispatch_with_only_choice_input(self):
        self.assertEqual(check_dispatch_trigger_and_only_input(_real_ci_yml()), [])


# ---------------------------------------------------------------------------
# 2. job names
# ---------------------------------------------------------------------------

class JobNameTests(unittest.TestCase):
    def test_bites_on_plain_name(self):
        text = good_workflow(names={"build": "Build & Lint"})
        self.assertTrue(check_job_names_carry_dispatch_suffix(text))

    def test_bites_on_mismatched_non_dispatch_branch(self):
        bad = ("${{ github.event_name == 'workflow_dispatch' && 'Build & Lint (dispatch)' "
               "|| 'Build and Lint' }}")
        self.assertTrue(check_job_names_carry_dispatch_suffix(good_workflow(names={"build": bad})))

    def test_bites_on_missing_suffix(self):
        bad = ("${{ github.event_name == 'workflow_dispatch' && 'Build & Lint' "
               "|| 'Build & Lint' }}")
        self.assertTrue(check_job_names_carry_dispatch_suffix(good_workflow(names={"build": bad})))

    def test_bites_on_missing_name_line(self):
        text = _without_line(good_workflow(), lambda l: l.startswith("    name: ${{") and "Python tooling" in l)
        self.assertTrue(check_job_names_carry_dispatch_suffix(text))

    def test_real_ci_yml_job_names_carry_dispatch_suffix(self):
        self.assertEqual(check_job_names_carry_dispatch_suffix(_real_ci_yml()), [])


# ---------------------------------------------------------------------------
# 3. job if: selectors
# ---------------------------------------------------------------------------

class JobIfTests(unittest.TestCase):
    def test_bites_on_missing_if(self):
        text = _without_line(good_workflow(), lambda l: l.startswith("    if: "))
        self.assertTrue(check_job_if_selects_by_only_input(text))

    def test_bites_on_missing_dispatch_escape(self):
        bad = "contains(fromJSON('[\"all\",\"rust\"]'), inputs.only)"
        violations = check_job_if_selects_by_only_input(good_workflow(ifs={"build": bad}))
        self.assertTrue(violations)

    def test_bites_on_wrong_selector_set(self):
        bad = ("github.event_name != 'workflow_dispatch' || "
               "contains(fromJSON('[\"all\",\"rust\",\"kit\"]'), inputs.only)")
        self.assertTrue(check_job_if_selects_by_only_input(good_workflow(ifs={"build": bad})))

    def test_selector_order_does_not_matter(self):
        ok = ("github.event_name != 'workflow_dispatch' || "
              "contains(fromJSON('[\"mac\",\"all\",\"swift\"]'), inputs.only)")
        self.assertEqual(
            check_job_if_selects_by_only_input(good_workflow(ifs={"swift-tests-mac": ok})), [])

    def test_step_level_if_does_not_satisfy_the_job_level_requirement(self):
        text = _without_line(good_workflow(), lambda l: l.startswith("    if: "))
        self.assertTrue(check_job_if_selects_by_only_input(text))  # steps still carry `if: failure()`

    def test_real_ci_yml_job_if_selectors(self):
        self.assertEqual(check_job_if_selects_by_only_input(_real_ci_yml()), [])


# ---------------------------------------------------------------------------
# 4. concurrency
# ---------------------------------------------------------------------------

class ConcurrencyTests(unittest.TestCase):
    def test_bites_when_group_lacks_event_name(self):
        self.assertTrue(check_concurrency_is_per_event_and_cancels_only_prs(
            good_workflow(group_suffix="${{ github.ref }}")))

    def test_bites_when_cancel_in_progress_is_unconditional(self):
        self.assertTrue(check_concurrency_is_per_event_and_cancels_only_prs(
            good_workflow(cancel="true")))

    def test_bites_when_cancel_condition_is_wrong(self):
        self.assertTrue(check_concurrency_is_per_event_and_cancels_only_prs(
            good_workflow(cancel="${{ github.event_name != 'push' }}")))

    def test_bites_with_fewer_than_three_groups(self):
        lines = good_workflow().splitlines()
        kept, dropping = [], False
        for l in lines:
            if l.startswith("    concurrency:") and sum("concurrency:" in k for k in kept) >= 2:
                dropping = True
                continue
            if dropping and l.startswith("      "):
                continue
            dropping = False
            kept.append(l)
        self.assertTrue(check_concurrency_is_per_event_and_cancels_only_prs("\n".join(kept)))

    def test_real_ci_yml_concurrency(self):
        self.assertEqual(check_concurrency_is_per_event_and_cancels_only_prs(_real_ci_yml()), [])


# ---------------------------------------------------------------------------
# 5. permissions
# ---------------------------------------------------------------------------

class PermissionsTests(unittest.TestCase):
    def test_bites_on_extra_permission(self):
        self.assertTrue(check_permissions_are_read_only(
            good_workflow(permissions=("contents: read", "pull-requests: read"))))

    def test_bites_on_actions_write(self):
        self.assertTrue(check_permissions_are_read_only(
            good_workflow(permissions=("contents: read", "actions: write"))))

    def test_bites_on_contents_write(self):
        self.assertTrue(check_permissions_are_read_only(
            good_workflow(permissions=("contents: write",))))

    def test_bites_on_write_permission_inside_a_job(self):
        self.assertTrue(check_permissions_are_read_only(
            good_workflow(extra_job_lines="    permissions:\n      actions: write")))

    def test_bites_on_missing_block(self):
        text = good_workflow().replace("permissions:\n  contents: read\n", "")
        self.assertTrue(check_permissions_are_read_only(text))

    def test_real_ci_yml_permissions(self):
        self.assertEqual(check_permissions_are_read_only(_real_ci_yml()), [])


# ---------------------------------------------------------------------------
# 6. no path filters
# ---------------------------------------------------------------------------

class NoPathFilterTests(unittest.TestCase):
    def test_bites_on_paths(self):
        self.assertTrue(check_no_path_filters(
            good_workflow(extra_job_lines="    paths:\n      - 'src/**'")))

    def test_bites_on_paths_ignore(self):
        text = good_workflow().replace(
            "  pull_request:\n    branches: [main]",
            "  pull_request:\n    branches: [main]\n    paths-ignore:\n      - 'docs/**'",
        )
        self.assertTrue(check_no_path_filters(text))

    def test_real_ci_yml_has_no_path_filters(self):
        self.assertEqual(check_no_path_filters(_real_ci_yml()), [])


# ---------------------------------------------------------------------------
# Belt and braces: this suite itself must never skip.
# ---------------------------------------------------------------------------

class SuiteNeverSkipsTests(unittest.TestCase):
    """The CI job greps this suite's output for the skip report and fails on
    it; this is a source-level second guard, parsed with `ast` so the check
    can describe what it forbids without matching itself."""

    def test_this_module_defines_no_skip_decorator_or_skipTest_call(self):
        with open(__file__, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for dec in node.decorator_list:
                    self.assertNotIn(
                        "skip", ast.dump(dec).lower(),
                        f"{node.name} carries a skip-shaped decorator: {ast.dump(dec)}",
                    )
            if isinstance(node, ast.Call):
                target = node.func
                name = getattr(target, "attr", None) or getattr(target, "id", None)
                self.assertNotEqual(name, "skipTest", "a skipTest(...) call was found in this module")


if __name__ == "__main__":
    unittest.main()
