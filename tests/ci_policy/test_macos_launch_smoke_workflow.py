"""Source-scanning policy tests over `.github/workflows/macos-launch-smoke.yml`.

This is **W2** of the launch-smoke-test work (`.claude/plans/launch-smoke-test-ci.md`
in the primary repo checkout; PRD: `.claude/prds/launch-smoke-test.md`, section
"Running on PRs"). W1 built `bin/nostromo-launch-smoke`, a one-command check
that builds the macOS app, launches it against a fixture daemon, and reports
PASS (0) / FAIL (1) / INCONCLUSIVE (2). This wedge wires that driver into CI
as a path-filtered, advisory job on a stock `macos-26` GitHub-hosted runner.

`.github/workflows/macos-launch-smoke.yml` does not exist yet as this file is
written (RED phase of red-green-refactor) — every test below is written
against the contract the plan hands down, and is expected to fail until that
workflow file is added. A missing file is handled as a clear, named assertion
failure (`RequiresWorkflowFile._workflow_text`), not a crash: `unittest`
would otherwise report a collection error indistinguishable from a typo.

Why regex/line-scanning instead of a YAML parser: this repo's Python test
suites (`tests/ios_policy`, `tests/doctor`, `tests/launch_smoke`,
`tests/transcript_load`) use only the standard library — nowhere imports
`yaml`/`PyYAML` — and this suite does not introduce a new third-party
dependency just to parse one workflow file. The same "textual heuristic, not
a control-flow proof" discipline `tests/ios_policy` documents for scanning
Swift applies here to scanning YAML/bash: these checks assume the ordinary,
idiomatic shapes (`paths:` as a plain YAML list, exit-code dispatch as a
shell `case ... esac`) rather than parsing arbitrary YAML/bash generally.

Every check below is a plain function taking the workflow file's text (or,
for `check_ci_yml_core_jobs_present`, `ci.yml`'s text) and returning a list
of violation strings (empty == pass). Each has a companion "bites" test, run
against a synthetic workflow string rather than the real file — proof the
check can actually fail, in the spirit of `tests/transcript_load`'s
`UniversalVacuityTests` / `VacuityTestActuallyBitesTests` pattern and
`tests/ios_policy`'s per-check bites tests.

This suite must never report a skip — the CI job (`.github/workflows/ci.yml`,
`python-tooling`) greps its output for `... skipped` / `(skipped=` and fails
the build if it finds either. `SuiteNeverSkipsTests` below is a second, local
guard against the same mistake, ported from `tests/ios_policy`.

Run with:
    python3 -m unittest discover -s tests/ci_policy -v
"""

import ast
import os
import re
import unittest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
WORKFLOW_PATH = os.path.join(
    REPO_ROOT, ".github", "workflows", "macos-launch-smoke.yml"
)
CI_YML_PATH = os.path.join(REPO_ROOT, ".github", "workflows", "ci.yml")

# The launch-behaviour-relevant paths from
# .claude/plans/launch-smoke-test-ci.md, step 2. A PR that cannot touch any
# of these must not pay for this job.
REQUIRED_PATHS = (
    "macOS/Nostromo/**",
    "macOS/Nostromo.xcodeproj/**",
    "Shared/NostromoKit/**",
    "bin/nostromo-launch-smoke",
    "tests/launch_smoke/**",
    "tests/fixtures/focus_layout_split.json",
    "macOS/scripts/ps-time-seconds.awk",
    "macOS/scripts/launch-smoke-validate.sh",
    "src/ipc/protocol.rs",
    "Makefile",
    ".github/workflows/macos-launch-smoke.yml",
)

# Deliberately NOT in the filter (plan step 2): a bare `src/**` would pull in
# every Rust change; `iOS/**`, `docs/**`, `.claude/**` cannot affect the
# macOS app's launch at all.
EXCLUDED_PATHS = ("src/**", "iOS/**", "docs/**", ".claude/**")


# ---------------------------------------------------------------------------
# File access
# ---------------------------------------------------------------------------

def _read_or_none(path):
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------------------
# Naive YAML/bash text-scanning helpers (no PyYAML dependency — see module
# docstring). Every helper here is a textual heuristic over the ordinary,
# idiomatic shape a GitHub Actions workflow and its embedded shell take, not
# a general parser.
# ---------------------------------------------------------------------------

def _extract_all_path_entries(text):
    """Collect every `- <entry>` list item nested under any `paths:` key,
    anywhere in the file (both `pull_request:` and `push:` triggers, if they
    each declare their own `paths:` block). Duplicates across blocks are
    fine — callers only check membership.

    Handles the one YAML feature this file has an obvious reason to use: an
    anchor/alias pair (`paths: &name` ... `paths: *name`) so a `push:` and
    `pull_request:` trigger can share one literal list without duplicating
    it. An alias is resolved from anchors already seen earlier in the file
    (the ordinary write-once-then-reference order); an alias referenced
    before its anchor is defined resolves to nothing, which is an accepted
    limitation of this being a textual heuristic and not a YAML parser.
    """
    entries = []
    anchors = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]

        alias_m = re.match(r'^\s*paths:\s*\*(\S+)\s*$', line)
        if alias_m:
            entries.extend(anchors.get(alias_m.group(1), []))
            i += 1
            continue

        m = re.match(r'^(\s*)paths:\s*(?:&(\S+))?\s*$', line)
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        anchor_name = m.group(2)
        i += 1
        block_entries = []
        while i < len(lines):
            item = lines[i]
            if item.strip() == "":
                i += 1
                continue
            item_m = re.match(r'^(\s*)-\s*(.+?)\s*$', item)
            if item_m and len(item_m.group(1)) > indent:
                block_entries.append(item_m.group(2).strip().strip('"\''))
                i += 1
                continue
            break
        entries.extend(block_entries)
        if anchor_name:
            anchors[anchor_name] = block_entries
    return entries


def _extract_run_scripts(text):
    """Return the body text of every `run: |` (or `run: >`) block scalar in
    the file, in document order.
    """
    scripts = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r'^(\s*)run:\s*[|>][+-]?\s*$', lines[i])
        if not m:
            i += 1
            continue
        indent = len(m.group(1))
        i += 1
        body_lines = []
        while i < len(lines):
            line = lines[i]
            if line.strip() == "":
                body_lines.append(line)
                i += 1
                continue
            cur_indent = len(line) - len(line.lstrip(" "))
            if cur_indent > indent:
                body_lines.append(line)
                i += 1
            else:
                break
        scripts.append("\n".join(body_lines))
    return scripts


def _extract_case_branches(script):
    """Parse a top-level `case ... in ... esac` block into an ordered list
    of `(pattern, body)` pairs. `pattern` is the raw label text before the
    `)` (e.g. `"1"`, `2`, `*`); `body` is everything up to the next label or
    `esac`. Naive line-based scanning: assumes each label sits alone on its
    own line, which is how `case` is conventionally formatted in a YAML
    block scalar. Returns `[]` if no `case ... in` is found.
    """
    lines = script.splitlines()
    branches = []
    in_case = False
    current_key = None
    current_body = []

    def flush():
        if current_key is not None:
            branches.append((current_key, "\n".join(current_body)))

    for line in lines:
        stripped = line.strip()
        if not in_case:
            if re.match(r'^case\b.*\bin$', stripped):
                in_case = True
            continue
        if stripped == "esac":
            flush()
            current_key = None
            break
        label_m = re.match(r'^([^\s()]+(?:\s*\|\s*[^\s()]+)*)\)\s*(.*)$', stripped)
        if label_m:
            flush()
            current_key = label_m.group(1)
            trailing = label_m.group(2)
            current_body = [trailing] if trailing else []
        elif current_key is not None:
            current_body.append(line)
    else:
        flush()

    return branches


def _branch_matches_code(label, code):
    parts = [p.strip().strip('"\'') for p in label.split("|")]
    return code in parts


def _extract_job_names(text):
    """Return the top-level job keys under the file's `jobs:` mapping."""
    lines = text.splitlines()
    names = []
    in_jobs = False
    jobs_indent = None
    for line in lines:
        if not in_jobs:
            if re.match(r'^jobs:\s*$', line):
                in_jobs = True
            continue
        if line.strip() == "":
            continue
        indent = len(line) - len(line.lstrip(" "))
        if jobs_indent is None:
            jobs_indent = indent
        if indent < jobs_indent:
            break
        if indent == jobs_indent:
            m = re.match(r'^([A-Za-z0-9_-]+):\s*$', line.strip())
            if m:
                names.append(m.group(1))
    return names


# ---------------------------------------------------------------------------
# Checks — each takes workflow text, returns a list of violation strings.
# Empty == pass.
# ---------------------------------------------------------------------------

def check_runs_on_pinned_to_macos_26(text):
    """The job's `runs-on:` is exactly `macos-26`, never a floating label
    like `macos-latest`. A silent runner-image rollover must not be
    reachable without an explicit, reviewable edit to this file.
    """
    values = re.findall(r'^\s*runs-on:\s*(\S+)\s*$', text, re.MULTILINE)
    if not values:
        return ["no `runs-on:` line found"]
    violations = []
    for v in values:
        cleaned = v.strip().strip('"\'')
        if cleaned != "macos-26":
            violations.append("runs-on is `%s`, not the pinned `macos-26`" % cleaned)
    return violations


def check_paths_filter_includes_all_required(text):
    """Every launch-behaviour-relevant path prefix from the plan is present
    in the `paths:` filter, so a PR touching any of them actually runs the
    job.
    """
    entries = _extract_all_path_entries(text)
    return [
        "required path `%s` is missing from the `paths:` filter" % p
        for p in REQUIRED_PATHS
        if p not in entries
    ]


def check_paths_filter_excludes_broad_or_unrelated(text):
    """The filter never lists a bare `src/**` (only the narrow
    `src/ipc/protocol.rs`), and never lists `iOS/**`, `docs/**`, or
    `.claude/**` — none of those can affect the macOS app's launch, and a
    PR that cannot affect it must not pay for this job.
    """
    entries = _extract_all_path_entries(text)
    return [
        "`%s` is present in the `paths:` filter — too broad or unrelated" % p
        for p in EXCLUDED_PATHS
        if p in entries
    ]


def check_smoke_step_is_advisory(text):
    """The step running the smoke check carries `continue-on-error: true`,
    so neither FAIL nor INCONCLUSIVE blocks a merge yet.

    This repo tracks no branch-protection configuration file (checked as
    part of writing this suite), so there is nothing else to scan to confirm
    the job is absent from required-status-check configuration; that half of
    "advisory, not blocking" is a human/GitHub-repo-settings fact, not
    something this repo's tracked files can assert on.
    """
    if not re.search(r'continue-on-error:\s*true\b', text):
        return ["no `continue-on-error: true` found — the smoke step must stay advisory"]
    return []


def check_no_retry_logic(text):
    """No retry-to-green mechanism exists anywhere in the workflow: no
    retry action (`nick-fields/retry` or equivalent), no shell retry loop.
    An app that crashes once in three launches is the finding, not a flake
    to smooth over — the only thing eligible for a retry is a human
    re-running the job.
    """
    violations = []
    if re.search(r'uses:\s*\S*retry\S*', text, re.IGNORECASE):
        violations.append("a retry action (`uses: ...retry...`) is present — no retry-to-green allowed")
    if re.search(r'for\s+\w+\s+in\s+1\s+2\s+3\b', text):
        violations.append("a shell retry loop (`for i in 1 2 3`) is present")
    return violations


def check_exit_code_annotation_mapping(text):
    """The step that maps the driver's exit code to a PR-visible annotation
    dispatches via a `case ... esac` on the exit code with:

    - a `1` branch emitting `::error::` whose message contains
      `launch smoke FAIL`
    - a `2` branch emitting `::warning::` whose message contains
      `launch smoke INCONCLUSIVE`
    - a `*` fallback branch that still emits `::warning::` — an
      unrecognised exit code must never be silently treated as success.
    """
    scripts = _extract_run_scripts(text)
    annotation_script = next(
        (s for s in scripts if "::error::" in s or "::warning::" in s), None
    )
    if annotation_script is None:
        return ["no `run:` step emits `::error::`/`::warning::` annotations for the exit-code mapping"]

    branches = _extract_case_branches(annotation_script)
    if not branches:
        return [
            "no `case ... in ... esac` dispatch on the exit code found in the "
            "annotation step (expected explicit branches for 1, 2, and a `*` fallback)"
        ]

    def body_for(code):
        for label, body in branches:
            if _branch_matches_code(label, code):
                return body
        return None

    violations = []

    fail_body = body_for("1")
    if fail_body is None:
        violations.append("no case branch for exit code 1 (FAIL)")
    else:
        if "::error::" not in fail_body:
            violations.append("exit-code-1 branch does not emit `::error::`")
        if "launch smoke FAIL" not in fail_body:
            violations.append("exit-code-1 branch's message does not contain `launch smoke FAIL`")

    inconclusive_body = body_for("2")
    if inconclusive_body is None:
        violations.append("no case branch for exit code 2 (INCONCLUSIVE)")
    else:
        if "::warning::" not in inconclusive_body:
            violations.append("exit-code-2 branch does not emit `::warning::`")
        if "launch smoke INCONCLUSIVE" not in inconclusive_body:
            violations.append("exit-code-2 branch's message does not contain `launch smoke INCONCLUSIVE`")

    fallback_body = body_for("*")
    if fallback_body is None:
        violations.append("no fallback `*)` case branch for an unrecognised exit code")
    elif "::warning::" not in fallback_body:
        violations.append(
            "fallback branch does not emit `::warning::` — an unrecognised exit code "
            "must never be silently treated as success"
        )

    return violations


def check_single_job_builds_and_launches(text):
    """Exactly one job exists (build and launch happen in the same job, per
    the quarantine-attribute constraint the plan documents), that job
    invokes the driver (`make mac-smoke` or `bin/nostromo-launch-smoke`
    directly), and the `.app` is never shipped between jobs via a paired
    `actions/upload-artifact` + `actions/download-artifact` (a lone
    `upload-artifact` for diagnostics is fine and expected).
    """
    violations = []
    jobs = _extract_job_names(text)
    if len(jobs) != 1:
        violations.append("expected exactly one job, found %d: %r" % (len(jobs), jobs))
    if "make mac-smoke" not in text and "nostromo-launch-smoke" not in text:
        violations.append(
            "no reference to `make mac-smoke` / `bin/nostromo-launch-smoke` found — "
            "build and launch must happen via the driver in this job"
        )
    if "actions/upload-artifact" in text and "actions/download-artifact" in text:
        violations.append(
            "both `actions/upload-artifact` and `actions/download-artifact` are present — "
            "the .app must never move between jobs"
        )
    return violations


def check_ci_yml_core_jobs_present(text):
    """`ci.yml`'s pre-existing jobs are untouched by this feature: `build`
    (on `ubuntu-latest`) and `python-tooling` (on `macos-latest`) are both
    still defined. Guards against someone "fixing" this feature by editing
    the wrong workflow file.
    """
    violations = []
    if not re.search(r'^\s*build:\s*$', text, re.MULTILINE):
        violations.append("no `build:` job found")
    if not re.search(r'^\s*python-tooling:\s*$', text, re.MULTILINE):
        violations.append("no `python-tooling:` job found")
    if "runs-on: ubuntu-latest" not in text:
        violations.append("no job runs on `ubuntu-latest` (expected for `build`)")
    if "runs-on: macos-latest" not in text:
        violations.append("no job runs on `macos-latest` (expected for `python-tooling`)")
    return violations


# ---------------------------------------------------------------------------
# Real-file tests — run every check above against the actual workflow (and,
# for the ci.yml guard, the actual ci.yml). A missing file fails clearly
# rather than crashing the whole module at import/collection time.
# ---------------------------------------------------------------------------

class RequiresWorkflowFile:
    def _workflow_text(self):
        text = _read_or_none(WORKFLOW_PATH)
        if text is None:
            self.fail(
                "workflow file not found at %s — "
                ".github/workflows/macos-launch-smoke.yml has not been created yet "
                "(see .claude/plans/launch-smoke-test-ci.md, W2)" % WORKFLOW_PATH
            )
        return text


class RealWorkflowPolicyTests(RequiresWorkflowFile, unittest.TestCase):
    def test_runs_on_pinned_to_macos_26(self):
        violations = check_runs_on_pinned_to_macos_26(self._workflow_text())
        self.assertEqual(violations, [], violations)

    def test_paths_filter_includes_all_required(self):
        violations = check_paths_filter_includes_all_required(self._workflow_text())
        self.assertEqual(violations, [], violations)

    def test_paths_filter_excludes_broad_or_unrelated(self):
        violations = check_paths_filter_excludes_broad_or_unrelated(self._workflow_text())
        self.assertEqual(violations, [], violations)

    def test_smoke_step_is_advisory(self):
        violations = check_smoke_step_is_advisory(self._workflow_text())
        self.assertEqual(violations, [], violations)

    def test_no_retry_logic(self):
        violations = check_no_retry_logic(self._workflow_text())
        self.assertEqual(violations, [], violations)

    def test_exit_code_annotation_mapping(self):
        violations = check_exit_code_annotation_mapping(self._workflow_text())
        self.assertEqual(violations, [], violations)

    def test_single_job_builds_and_launches(self):
        violations = check_single_job_builds_and_launches(self._workflow_text())
        self.assertEqual(violations, [], violations)


class CiYmlUntouchedTests(unittest.TestCase):
    def test_ci_yml_core_jobs_present(self):
        text = _read_or_none(CI_YML_PATH)
        if text is None:
            self.fail("ci.yml not found at %s" % CI_YML_PATH)
        violations = check_ci_yml_core_jobs_present(text)
        self.assertEqual(violations, [], violations)


# ---------------------------------------------------------------------------
# Per-check bites tests — each proves the check can actually fail against a
# synthetic, adversarial workflow string, then proves it passes clean input.
# ---------------------------------------------------------------------------

class RunsOnPinnedTests(unittest.TestCase):
    def test_bites_on_macos_latest(self):
        text = "jobs:\n  smoke:\n    runs-on: macos-latest\n"
        violations = check_runs_on_pinned_to_macos_26(text)
        self.assertEqual(len(violations), 1)

    def test_passes_on_macos_26(self):
        text = "jobs:\n  smoke:\n    runs-on: macos-26\n"
        self.assertEqual(check_runs_on_pinned_to_macos_26(text), [])

    def test_bites_when_no_runs_on_at_all(self):
        self.assertEqual(len(check_runs_on_pinned_to_macos_26("jobs:\n  smoke:\n")), 1)


class PathFilterIncludesRequiredTests(unittest.TestCase):
    _CLEAN = (
        "on:\n"
        "  pull_request:\n"
        "    paths:\n"
        + "".join("      - '%s'\n" % p for p in REQUIRED_PATHS)
    )

    def test_bites_when_a_required_path_is_missing(self):
        text = (
            "on:\n"
            "  pull_request:\n"
            "    paths:\n"
            "      - 'macOS/Nostromo/**'\n"
            # 'Makefile' and everything else omitted.
        )
        violations = check_paths_filter_includes_all_required(text)
        self.assertGreater(len(violations), 0)
        self.assertTrue(any("Makefile" in v for v in violations))

    def test_passes_when_every_required_path_is_present(self):
        self.assertEqual(check_paths_filter_includes_all_required(self._CLEAN), [])


class PathFilterExcludesBroadTests(unittest.TestCase):
    def test_bites_on_bare_src_glob(self):
        text = (
            "on:\n"
            "  pull_request:\n"
            "    paths:\n"
            "      - 'src/**'\n"
        )
        violations = check_paths_filter_excludes_broad_or_unrelated(text)
        self.assertEqual(len(violations), 1)
        self.assertIn("src/**", violations[0])

    def test_bites_on_ios_docs_or_claude(self):
        for excluded in ("iOS/**", "docs/**", ".claude/**"):
            text = "on:\n  pull_request:\n    paths:\n      - '%s'\n" % excluded
            violations = check_paths_filter_excludes_broad_or_unrelated(text)
            self.assertEqual(len(violations), 1, excluded)

    def test_passes_when_only_the_narrow_protocol_path_is_present(self):
        text = "on:\n  pull_request:\n    paths:\n      - 'src/ipc/protocol.rs'\n"
        self.assertEqual(check_paths_filter_excludes_broad_or_unrelated(text), [])


class SmokeStepAdvisoryTests(unittest.TestCase):
    def test_bites_when_continue_on_error_absent(self):
        text = "jobs:\n  smoke:\n    steps:\n      - run: make mac-smoke\n"
        violations = check_smoke_step_is_advisory(text)
        self.assertEqual(len(violations), 1)

    def test_passes_when_continue_on_error_true_present(self):
        text = (
            "jobs:\n  smoke:\n    steps:\n"
            "      - run: make mac-smoke\n"
            "        continue-on-error: true\n"
        )
        self.assertEqual(check_smoke_step_is_advisory(text), [])


class NoRetryLogicTests(unittest.TestCase):
    def test_bites_on_retry_action(self):
        text = "steps:\n  - uses: nick-fields/retry@v2\n"
        violations = check_no_retry_logic(text)
        self.assertEqual(len(violations), 1)

    def test_bites_on_shell_retry_loop(self):
        text = "steps:\n  - run: |\n      for i in 1 2 3; do make mac-smoke && break; done\n"
        violations = check_no_retry_logic(text)
        self.assertEqual(len(violations), 1)

    def test_passes_with_no_retry_mechanism(self):
        text = "steps:\n  - run: make mac-smoke\n    continue-on-error: true\n"
        self.assertEqual(check_no_retry_logic(text), [])


def _wrap_case_script(case_body):
    return (
        "jobs:\n"
        "  smoke:\n"
        "    steps:\n"
        "      - name: Report verdict\n"
        "        run: |\n"
        "          EXIT_CODE=$?\n"
        "          case \"$EXIT_CODE\" in\n"
        + case_body +
        "          esac\n"
    )


class ExitCodeAnnotationMappingTests(unittest.TestCase):
    _CLEAN = _wrap_case_script(
        "            0)\n"
        "              echo \"PASS\" >> \"$GITHUB_STEP_SUMMARY\"\n"
        "              ;;\n"
        "            1)\n"
        "              echo \"::error::launch smoke FAIL: crash detected\"\n"
        "              ;;\n"
        "            2)\n"
        "              echo \"::warning::launch smoke INCONCLUSIVE: cause here\"\n"
        "              ;;\n"
        "            *)\n"
        "              echo \"::warning::driver exited unexpectedly (code $EXIT_CODE)\"\n"
        "              ;;\n"
    )

    def test_passes_on_a_complete_mapping(self):
        self.assertEqual(check_exit_code_annotation_mapping(self._CLEAN), [])

    def test_bites_when_fail_branch_is_missing(self):
        text = _wrap_case_script(
            "            2)\n"
            "              echo \"::warning::launch smoke INCONCLUSIVE: cause here\"\n"
            "              ;;\n"
            "            *)\n"
            "              echo \"::warning::driver exited unexpectedly (code $EXIT_CODE)\"\n"
            "              ;;\n"
        )
        violations = check_exit_code_annotation_mapping(text)
        self.assertTrue(any("exit code 1" in v for v in violations), violations)

    def test_bites_when_unknown_code_silently_treated_as_success(self):
        text = _wrap_case_script(
            "            1)\n"
            "              echo \"::error::launch smoke FAIL: crash detected\"\n"
            "              ;;\n"
            "            2)\n"
            "              echo \"::warning::launch smoke INCONCLUSIVE: cause here\"\n"
            "              ;;\n"
            "            *)\n"
            "              exit 0\n"
            "              ;;\n"
        )
        violations = check_exit_code_annotation_mapping(text)
        self.assertTrue(
            any("fallback branch does not emit" in v for v in violations), violations
        )

    def test_bites_when_no_annotations_emitted_at_all(self):
        text = "jobs:\n  smoke:\n    steps:\n      - run: make mac-smoke\n"
        violations = check_exit_code_annotation_mapping(text)
        self.assertEqual(len(violations), 1)


class SingleJobBuildsAndLaunchesTests(unittest.TestCase):
    def test_bites_on_two_jobs(self):
        text = (
            "jobs:\n"
            "  build:\n"
            "    runs-on: macos-26\n"
            "    steps:\n"
            "      - run: make mac-smoke\n"
            "  launch:\n"
            "    runs-on: macos-26\n"
            "    steps:\n"
            "      - run: echo hi\n"
        )
        violations = check_single_job_builds_and_launches(text)
        self.assertTrue(any("exactly one job" in v for v in violations), violations)

    def test_bites_when_driver_never_invoked(self):
        text = "jobs:\n  smoke:\n    runs-on: macos-26\n    steps:\n      - run: echo hi\n"
        violations = check_single_job_builds_and_launches(text)
        self.assertTrue(any("make mac-smoke" in v for v in violations), violations)

    def test_bites_when_app_shipped_between_jobs(self):
        text = (
            "jobs:\n"
            "  smoke:\n"
            "    runs-on: macos-26\n"
            "    steps:\n"
            "      - run: make mac-smoke\n"
            "      - uses: actions/upload-artifact@v4\n"
            "      - uses: actions/download-artifact@v4\n"
        )
        violations = check_single_job_builds_and_launches(text)
        self.assertTrue(any("upload-artifact" in v for v in violations), violations)

    def test_passes_on_one_job_with_the_driver_and_no_artifact_pair(self):
        text = (
            "jobs:\n"
            "  smoke:\n"
            "    runs-on: macos-26\n"
            "    steps:\n"
            "      - run: make mac-smoke\n"
            "      - uses: actions/upload-artifact@v4\n"
            "        if: always()\n"
        )
        self.assertEqual(check_single_job_builds_and_launches(text), [])


class CiYmlCoreJobsPresentTests(unittest.TestCase):
    def test_bites_when_python_tooling_job_is_removed(self):
        text = (
            "jobs:\n"
            "  build:\n"
            "    runs-on: ubuntu-latest\n"
        )
        violations = check_ci_yml_core_jobs_present(text)
        self.assertTrue(any("python-tooling" in v for v in violations), violations)

    def test_bites_when_build_job_runner_changes(self):
        text = (
            "jobs:\n"
            "  build:\n"
            "    runs-on: macos-26\n"
            "  python-tooling:\n"
            "    runs-on: macos-latest\n"
        )
        violations = check_ci_yml_core_jobs_present(text)
        self.assertTrue(any("ubuntu-latest" in v for v in violations), violations)

    def test_passes_when_both_jobs_present_with_original_runners(self):
        text = (
            "jobs:\n"
            "  build:\n"
            "    runs-on: ubuntu-latest\n"
            "  python-tooling:\n"
            "    runs-on: macos-latest\n"
        )
        self.assertEqual(check_ci_yml_core_jobs_present(text), [])


# ---------------------------------------------------------------------------
# Helper-function tests
# ---------------------------------------------------------------------------

class ExtractAllPathEntriesTests(unittest.TestCase):
    def test_collects_entries_from_multiple_paths_blocks(self):
        text = (
            "on:\n"
            "  pull_request:\n"
            "    paths:\n"
            "      - 'a/**'\n"
            "      - 'b/**'\n"
            "  push:\n"
            "    paths:\n"
            "      - 'c/**'\n"
        )
        self.assertEqual(_extract_all_path_entries(text), ["a/**", "b/**", "c/**"])

    def test_strips_quotes(self):
        text = "paths:\n  - \"quoted/**\"\n  - 'single/**'\n"
        self.assertEqual(_extract_all_path_entries(text), ["quoted/**", "single/**"])

    def test_resolves_an_anchor_alias_pair(self):
        text = (
            "on:\n"
            "  push:\n"
            "    paths: &shared\n"
            "      - 'a/**'\n"
            "      - 'b/**'\n"
            "  pull_request:\n"
            "    paths: *shared\n"
        )
        self.assertEqual(_extract_all_path_entries(text), ["a/**", "b/**", "a/**", "b/**"])


class ExtractCaseBranchesTests(unittest.TestCase):
    def test_splits_labels_and_bodies(self):
        script = (
            "case \"$X\" in\n"
            "  1)\n"
            "    echo one\n"
            "    ;;\n"
            "  *)\n"
            "    echo other\n"
            "    ;;\n"
            "esac\n"
        )
        branches = _extract_case_branches(script)
        keys = [k for k, _ in branches]
        self.assertEqual(keys, ["1", "*"])
        self.assertIn("echo one", dict(branches)["1"])
        self.assertIn("echo other", dict(branches)["*"])

    def test_returns_empty_list_when_no_case_statement(self):
        self.assertEqual(_extract_case_branches("echo hello\n"), [])


class ExtractJobNamesTests(unittest.TestCase):
    def test_finds_top_level_job_keys_only(self):
        text = (
            "on: push\n"
            "jobs:\n"
            "  build:\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - run: echo hi\n"
            "  test:\n"
            "    runs-on: ubuntu-latest\n"
        )
        self.assertEqual(_extract_job_names(text), ["build", "test"])


# ---------------------------------------------------------------------------
# Belt and braces: this suite itself must never skip.
# ---------------------------------------------------------------------------

class SuiteNeverSkipsTests(unittest.TestCase):
    """Ported from `tests/ios_policy`'s guard of the same name. The CI job
    greps this suite's output for `... skipped` / `(skipped=` and fails the
    build on either; this is a local, source-level second guard, parsed with
    `ast` rather than a substring search so the check can describe the
    pattern it forbids without matching itself (this docstring says
    "skipped" and "skipTest" to explain what's banned, which a naive
    substring search over the file would trip on).
    """

    def test_this_module_defines_no_skip_decorator_or_skipTest_call(self):
        with open(__file__, "r", encoding="utf-8") as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for dec in node.decorator_list:
                    self.assertNotIn(
                        "skip", ast.dump(dec).lower(),
                        f"{node.name} carries a skip-shaped decorator: {ast.dump(dec)}"
                    )
            if isinstance(node, ast.Call):
                target = node.func
                name = getattr(target, "attr", None) or getattr(target, "id", None)
                self.assertNotEqual(name, "skipTest", "a skipTest(...) call was found in this module")


if __name__ == "__main__":
    unittest.main()
