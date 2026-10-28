"""Behavioural tests for `scripts/ci_changes.py`, the path classifier the CI
`changes` job uses to decide whether the Swift jobs (Mac app tests + compile
gate, NostromoKit tests, iOS simulator build) can be skipped on a pull request.

Skipping a Swift job that should have run lets a broken build merge, so the
classifier is DEFAULT-RUN: `swift_jobs_needed` returns False only when EVERY
changed path is provably irrelevant to Swift. A path is skippable only if it is:

  1. under `docs/` or `.claude/`
  2. a `.rs` file under `tests/` that is NOT under `tests/fixtures/`
     (Swift tests read tests/fixtures/**)
  3. exactly `Cargo.toml`, `Cargo.lock` or `rust-toolchain.toml`

`src/**` is NOT skippable, at all: Swift Mac tests read the Rust sources
(ActivityStreamModelTests reads src/activity/store.rs, and
StatusBarPostureWindowsTests walks every `.rs` file under `src/`), so any
change under `src/` can change a Swift test's verdict.

Anything else, an empty list, or any odd-looking path (`..` segment, leading
`/` or `./`, backslash, empty string) means the Swift jobs run.

The module is loaded lazily via importlib so a load failure fails each test
clearly rather than as one collection error.

`SwiftSourcesDoNotReadSkippablePathsTests` is a drift guard: it scans the Swift
sources for repo-relative reads that point into the skippable set (string
literals passed to appendingPathComponent / URL(fileURLWithPath:), plus bare
"docs" / "tests" / ".claude" literals in `for x in [...]` directory walks). It
must pass against the real tree, and companion "bites" tests prove the scanner
can fail.

Run with:
    python3 -m unittest discover -s tests/ci_policy -p 'test_ci_changes.py' -v
"""

import importlib.util
import os
import re
import subprocess
import sys
import unittest

REPO_ROOT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
)
CI_CHANGES_PATH = os.path.join(REPO_ROOT, "scripts", "ci_changes.py")

_MODULE = None


def _mod():
    """Load scripts/ci_changes.py (cached). Raises if it does not exist yet."""
    global _MODULE
    if _MODULE is None:
        spec = importlib.util.spec_from_file_location("ci_changes", CI_CHANGES_PATH)
        if spec is None or spec.loader is None:
            raise ImportError(f"cannot load {CI_CHANGES_PATH}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _MODULE = module
    return _MODULE


def swift_needed(paths):
    return _mod().swift_jobs_needed(list(paths))


def run_cli(stdin_bytes):
    return subprocess.run(
        [sys.executable, CI_CHANGES_PATH],
        input=stdin_bytes,
        capture_output=True,
        cwd=REPO_ROOT,
        timeout=60,
    )


def nul(*paths):
    return b"".join(p.encode("utf-8") + b"\0" for p in paths)


# ---------------------------------------------------------------------------
# Skippable paths: the only ways a change can avoid running Swift.
# ---------------------------------------------------------------------------
class SkippablePathsTests(unittest.TestCase):
    def test_docs_only_change_skips_swift(self):
        self.assertIs(swift_needed(["docs/architecture.md"]), False)

    def test_nested_docs_file_skips_swift(self):
        self.assertIs(swift_needed(["docs/plans/2026/q4/ci.md"]), False)

    def test_claude_dir_only_change_skips_swift(self):
        self.assertIs(swift_needed([".claude/prds/ci-speedup.md"]), False)

    def test_rust_integration_test_skips_swift(self):
        self.assertIs(swift_needed(["tests/terminal_pane.rs"]), False)

    def test_nested_rust_integration_test_skips_swift(self):
        self.assertIs(swift_needed(["tests/support/helpers/mod.rs"]), False)

    def test_cargo_manifest_lock_and_toolchain_skip_swift(self):
        self.assertIs(
            swift_needed(["Cargo.toml", "Cargo.lock", "rust-toolchain.toml"]), False
        )

    def test_mixed_docs_cargo_lock_and_rust_test_skip_swift(self):
        self.assertIs(
            swift_needed(["docs/a.md", "Cargo.lock", "tests/foo.rs"]), False
        )


# ---------------------------------------------------------------------------
# Default-run: everything not on the skippable list runs Swift.
# ---------------------------------------------------------------------------
class DefaultRunTests(unittest.TestCase):
    def test_empty_change_list_runs_swift(self):
        self.assertIs(swift_needed([]), True)

    def test_mac_app_swift_file_runs_swift(self):
        self.assertIs(swift_needed(["macOS/Nostromo/Data/AppStore.swift"]), True)

    def test_ios_file_runs_swift(self):
        self.assertIs(swift_needed(["iOS/Nostromo/App.swift"]), True)

    def test_shared_kit_source_runs_swift(self):
        self.assertIs(
            swift_needed(["Shared/NostromoKit/Sources/NostromoKit/Wire.swift"]), True
        )

    def test_package_manifest_runs_swift(self):
        self.assertIs(swift_needed(["Shared/NostromoKit/Package.swift"]), True)

    def test_kit_tests_run_swift(self):
        self.assertIs(
            swift_needed(
                ["Shared/NostromoKit/Tests/NostromoKitTests/MotherCrewWireTests.swift"]
            ),
            True,
        )

    def test_xcode_project_file_runs_swift(self):
        self.assertIs(swift_needed(["macOS/Nostromo.xcodeproj/project.pbxproj"]), True)

    def test_makefile_runs_swift(self):
        self.assertIs(swift_needed(["Makefile"]), True)

    def test_ci_workflow_runs_swift(self):
        self.assertIs(swift_needed([".github/workflows/ci.yml"]), True)

    def test_any_other_github_file_runs_swift(self):
        self.assertIs(swift_needed([".github/dependabot.yml"]), True)

    def test_bin_and_scripts_run_swift(self):
        self.assertIs(swift_needed(["bin/nostromo-dev"]), True)
        self.assertIs(swift_needed(["scripts/ci_changes.py"]), True)

    def test_readme_runs_swift(self):
        self.assertIs(swift_needed(["README.md"]), True)

    def test_unknown_root_level_file_runs_swift(self):
        self.assertIs(swift_needed([".swiftlint.yml"]), True)
        self.assertIs(swift_needed(["something-new-nobody-classified"]), True)

    def test_test_fixtures_run_swift(self):
        # Swift tests read tests/fixtures/** (work_query_cases.json, tracker/*,
        # approvals/*, mother-contract/*).
        self.assertIs(swift_needed(["tests/fixtures/work_query_cases.json"]), True)
        self.assertIs(swift_needed(["tests/fixtures/tracker/pane.json"]), True)
        self.assertIs(swift_needed(["tests/fixtures/approvals/q.json"]), True)
        self.assertIs(swift_needed(["tests/fixtures/mother-contract/x.json"]), True)

    def test_rust_file_inside_fixtures_runs_swift(self):
        self.assertIs(swift_needed(["tests/fixtures/sample.rs"]), True)

    def test_python_and_json_under_tests_run_swift(self):
        self.assertIs(swift_needed(["tests/ci_policy/test_ci_dispatch.py"]), True)
        self.assertIs(swift_needed(["tests/cases.json"]), True)

    def test_rs_suffix_lookalikes_under_tests_run_swift(self):
        # Only a real `.rs` extension makes a tests/ file skippable.
        self.assertIs(swift_needed(["tests/foo.rsx"]), True)
        self.assertIs(swift_needed(["tests/foo.rs.json"]), True)

    def test_tests_rs_file_is_skippable_control(self):
        # Control for the two lookalikes above.
        self.assertIs(swift_needed(["tests/foo.rs"]), False)

    def test_fixtures_lookalike_dirs_are_not_fixtures(self):
        # Only the exact `tests/fixtures/` directory is carved out. A sibling
        # whose name merely starts with "fixtures" is an ordinary Rust test path.
        self.assertIs(swift_needed(["tests/fixtures-old/x.rs"]), False)
        self.assertIs(swift_needed(["tests/fixtures.rs"]), False)

    def test_cargo_lookalikes_run_swift(self):
        self.assertIs(swift_needed(["Cargo.toml.bak"]), True)
        self.assertIs(swift_needed(["Shared/Cargo.toml"]), True)
        self.assertIs(swift_needed(["Cargo.TOML"]), True)
        self.assertIs(swift_needed(["rust-toolchain"]), True)
        self.assertIs(swift_needed(["rust-toolchain.toml.orig"]), True)


# ---------------------------------------------------------------------------
# src/** is never skippable: Swift tests read the Rust sources.
# ---------------------------------------------------------------------------
class SrcIsNotSkippableTests(unittest.TestCase):
    def test_every_path_under_src_runs_swift(self):
        for path in [
            "src/activity/store.rs",
            "src/activity/mod.rs",
            "src/activity/store.rs.bak",
            "src/store.rs",
            "src/lib.rs",
            "src/ipc/protocol.rs",
            "src/schema/queries.sql",
            "src/anything",
            "src/ünï/mod.rs",
        ]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_src_only_change_runs_swift(self):
        self.assertIs(swift_needed(["src/lib.rs"]), True)

    def test_src_among_otherwise_skippable_paths_runs_swift(self):
        self.assertIs(
            swift_needed(["docs/a.md", "src/lib.rs", "Cargo.lock"]), True
        )

    def test_rust_change_under_src_runs_swift_because_status_bar_test_walks_src(self):
        # Regression: macOS/NostromoTests/StatusBarPostureWindowsTests.swift
        # (testNoSourceReferencesTheTmuxRateLimitsFile, ~line 105) walks EVERY
        # `.rs` file under `src/` and fails if one mentions the tmux
        # rate-limits file. A PR touching only `src/foo.rs` can therefore flip
        # that Mac test, so the Mac test job must run.
        self.assertIs(swift_needed(["src/foo.rs"]), True)


# ---------------------------------------------------------------------------
# Prefix lookalikes and case sensitivity: must not be mistaken for skippable.
# ---------------------------------------------------------------------------
class PrefixLookalikeTests(unittest.TestCase):
    def test_docs_lookalike_directories_run_swift(self):
        for path in ["docs-old/x", "docsx/a.md", "docs.md"]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_src_lookalike_directories_run_swift(self):
        for path in ["srcs/x.rs", "src-old/lib.rs", "src.rs"]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_claude_lookalike_directories_run_swift(self):
        for path in [".claude-old/x", ".claudex/y.md", ".claude"]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_tests_lookalike_directories_run_swift(self):
        for path in ["tests-old/x.rs", "testsx/a.rs"]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_bare_directory_names_run_swift(self):
        for path in ["src", "docs", "tests"]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_matching_is_case_sensitive(self):
        for path in ["Docs/readme.md", "SRC/lib.rs", "Src/lib.rs", "Tests/a.rs", ".Claude/x.md"]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)


# ---------------------------------------------------------------------------
# Traversal and odd paths: anything unusual runs Swift for the whole change.
# ---------------------------------------------------------------------------
class OddPathTests(unittest.TestCase):
    def test_traversal_out_of_docs_runs_swift(self):
        self.assertIs(swift_needed(["docs/../macOS/App.swift"]), True)

    def test_traversal_out_of_src_runs_swift(self):
        self.assertIs(swift_needed(["src/../Makefile"]), True)

    def test_parent_segment_anywhere_runs_swift(self):
        for path in ["../docs/x", "docs/x/..", "docs/..", "..", "tests/a/../fixtures/b.rs"]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_absolute_path_runs_swift(self):
        self.assertIs(swift_needed(["/docs/x"]), True)
        self.assertIs(swift_needed(["/src/lib.rs"]), True)

    def test_leading_dot_slash_runs_swift(self):
        self.assertIs(swift_needed(["./docs/x"]), True)
        self.assertIs(swift_needed(["./src/lib.rs"]), True)

    def test_backslash_runs_swift(self):
        self.assertIs(swift_needed(["docs\\..\\macOS"]), True)
        self.assertIs(swift_needed(["docs\\x.md"]), True)
        self.assertIs(swift_needed(["docs/a\\b.md"]), True)

    def test_empty_path_runs_swift(self):
        self.assertIs(swift_needed([""]), True)
        self.assertIs(swift_needed(["docs/a.md", ""]), True)


# ---------------------------------------------------------------------------
# Whole-change semantics: any single relevant path wins.
# ---------------------------------------------------------------------------
class MixedChangeTests(unittest.TestCase):
    def test_docs_plus_one_mac_file_runs_swift(self):
        self.assertIs(
            swift_needed(["docs/a.md", "macOS/Nostromo/Data/AppStore.swift"]), True
        )

    def test_relevant_path_first_runs_swift(self):
        self.assertIs(swift_needed(["Makefile", "docs/a.md", "tests/foo.rs"]), True)

    def test_mixed_change_with_fixture_runs_swift(self):
        self.assertIs(
            swift_needed(["docs/a.md", "src/lib.rs", "tests/fixtures/x.json"]), True
        )

    def test_rename_into_docs_still_counts_old_path(self):
        # `git diff --name-only --no-renames` reports a rename as delete (old
        # path) plus add (new path). The old path lived in the Mac app.
        self.assertIs(
            swift_needed(["macOS/Nostromo/A.swift", "docs/A.swift"]), True
        )

    def test_rename_out_of_docs_still_counts_new_path(self):
        self.assertIs(
            swift_needed(["docs/A.swift", "macOS/Nostromo/A.swift"]), True
        )

    def test_rename_between_skippable_locations_skips_swift(self):
        self.assertIs(swift_needed(["docs/old.md", "docs/new.md"]), False)

    def test_input_list_is_not_mutated(self):
        paths = ["docs/a.md", "tests/foo.rs"]
        swift_needed(paths)
        self.assertEqual(paths, ["docs/a.md", "tests/foo.rs"])


class UnicodeAndScaleTests(unittest.TestCase):
    def test_unicode_and_spaces_in_skippable_paths_skip_swift(self):
        for path in [
            "docs/résumé 日本語.md",
            "docs/with space/a b.md",
            "tests/ünï/mod.rs",
            ".claude/notes/\U0001f680 launch.md",
        ]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), False)

    def test_unicode_and_spaces_in_relevant_paths_run_swift(self):
        for path in [
            "macOS/Nostromo/Vue é.swift",
            "Shared/NostromoKit/Sources/日本/A B.swift",
        ]:
            with self.subTest(path=path):
                self.assertIs(swift_needed([path]), True)

    def test_five_thousand_skippable_paths_skip_swift(self):
        paths = [f"docs/generated/page-{i}.md" for i in range(5000)]
        self.assertIs(swift_needed(paths), False)

    def test_five_thousand_skippable_paths_plus_one_mac_path_run_swift(self):
        paths = [f"docs/generated/page-{i}.md" for i in range(5000)]
        paths.append("macOS/Nostromo/Data/AppStore.swift")
        self.assertIs(swift_needed(paths), True)


# ---------------------------------------------------------------------------
# parse_nul_separated: `git diff -z --name-only --no-renames` output.
# ---------------------------------------------------------------------------
class ParseNulSeparatedTests(unittest.TestCase):
    def parse(self, data):
        return _mod().parse_nul_separated(data)

    def test_splits_on_nul_with_trailing_nul(self):
        self.assertEqual(self.parse(b"docs/a.md\0src/lib.rs\0"), ["docs/a.md", "src/lib.rs"])

    def test_splits_on_nul_without_trailing_nul(self):
        self.assertEqual(self.parse(b"docs/a.md\0src/lib.rs"), ["docs/a.md", "src/lib.rs"])

    def test_empty_bytes_yield_no_paths(self):
        self.assertEqual(self.parse(b""), [])

    def test_single_path_with_trailing_nul(self):
        self.assertEqual(self.parse(b"Makefile\0"), ["Makefile"])

    def test_embedded_newline_in_filename_is_preserved(self):
        self.assertEqual(self.parse(b"docs/a\nb.md\0Makefile\0"), ["docs/a\nb.md", "Makefile"])

    def test_utf8_filenames_are_decoded(self):
        self.assertEqual(
            self.parse("docs/résumé.md\0".encode("utf-8")),
            ["docs/résumé.md"],
        )

    def test_invalid_utf8_does_not_raise(self):
        result = self.parse(b"macOS/Nostromo/\xff\xfe.swift\0docs/a.md\0")
        self.assertEqual(len(result), 2)
        self.assertTrue(all(isinstance(p, str) for p in result))

    def test_invalid_utf8_path_under_mac_app_still_runs_swift(self):
        paths = self.parse(b"macOS/Nostromo/\xff\xfe.swift\0")
        self.assertIs(swift_needed(paths), True)


# ---------------------------------------------------------------------------
# CLI: stdin NUL-separated paths -> exactly one `swift=...` line, exit 0.
# ---------------------------------------------------------------------------
class CliTests(unittest.TestCase):
    def assert_cli(self, stdin_bytes, expected_line):
        result = run_cli(stdin_bytes)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        self.assertEqual(result.stdout, (expected_line + "\n").encode("ascii"))

    def test_docs_only_input_prints_swift_false(self):
        self.assert_cli(nul("docs/a.md"), "swift=false")

    def test_skippable_mix_without_trailing_nul_prints_swift_false(self):
        self.assert_cli(b"docs/a.md\0tests/foo.rs\0Cargo.lock", "swift=false")

    def test_src_input_prints_swift_true(self):
        self.assert_cli(nul("docs/a.md", "src/lib.rs"), "swift=true")

    def test_mac_app_input_prints_swift_true(self):
        self.assert_cli(nul("macOS/Nostromo/Data/AppStore.swift"), "swift=true")

    def test_mixed_input_prints_swift_true(self):
        self.assert_cli(nul("docs/a.md", "tests/fixtures/x.json"), "swift=true")

    def test_empty_stdin_prints_swift_true(self):
        self.assert_cli(b"", "swift=true")

    def test_garbage_bytes_print_swift_true_and_exit_zero(self):
        self.assert_cli(b"\xff\xfe\x00\x01\x80garbage\xc3\x28\x00\x00", "swift=true")


# ---------------------------------------------------------------------------
# Drift guard: Swift sources must not read repo files the classifier skips.
#
# If a Swift test starts reading e.g. `docs/x.md` or `tests/helper.rs`, a
# change to that file would be classified skippable and the Swift job that reads
# it would silently not run. (`src/` reads are fine: src/** is not skippable.) This scans the Swift sources for repo-relative
# reads and asserts the classifier treats each one as NOT skippable.
# ---------------------------------------------------------------------------
SWIFT_ROOTS = ["macOS", "iOS", "Shared"]
SKIP_DIR_NAMES = {"build", ".build"}

# A string literal passed to appendingPathComponent( or URL(fileURLWithPath:.
# Whitespace (including newlines) is allowed between the paren and the literal.
READ_LITERAL_RE = re.compile(
    r'(?:appendingPathComponent\(|URL\(fileURLWithPath:)\s*"((?:[^"\\]|\\.)*)"',
    re.DOTALL,
)

# `src` is listed so the scanner still sees src reads (and the vacuity guard can
# prove it scans), but the classifier treats every src path as needing Swift, so
# they never become violations.
# `.claude` is deliberately absent here: Swift legitimately reads `.claude/...`
# under the user's home directory (not the repo), so only the narrower
# `for x in [...]` walk heuristic below treats a bare ".claude" as a repo read.
SKIPPABLE_DIR_NAMES = ("src", "tests", "docs")
# Bare directory names that, inside `for x in [...]`, mean a directory walk.
WALKED_DIR_NAMES = ("docs", "tests", ".claude")
STRING_LITERAL_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
SKIPPABLE_FILE_NAMES = ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml")


def _literal_targets_skippable_area(value):
    if value in SKIPPABLE_DIR_NAMES or value in SKIPPABLE_FILE_NAMES:
        return True
    return any(value.startswith(d + "/") for d in SKIPPABLE_DIR_NAMES)


def _candidates(value):
    """Concrete repo paths to ask the classifier about for one literal."""
    if value.endswith("/"):
        directory = value.rstrip("/")
        return [directory, directory + "/x", directory + "/x.rs"]
    if value in SKIPPABLE_DIR_NAMES or value in WALKED_DIR_NAMES:
        return [value, value + "/x", value + "/x.rs"]
    return [value]


def find_directory_walk_literals(swift_text):
    """Bare "docs" / "tests" / ".claude" literals inside an array literal on a
    `for ... in [` line: the shape of a directory walk such as
    `for dir in ["macOS/Nostromo", "src"]`."""
    found = []
    for line in swift_text.splitlines():
        if "for " not in line or " in [" not in line:
            continue
        array_part = line[line.index(" in [") + len(" in ["):]
        for match in STRING_LITERAL_RE.finditer(array_part):
            if match.group(1) in WALKED_DIR_NAMES:
                found.append(match.group(1))
    return found


def find_repo_relative_reads(swift_text):
    """Literals in `swift_text` that point into src/, tests/, docs/, .claude/ or
    the Cargo / toolchain files, plus bare directory names in `for ... in [`
    walks. Interpolations are cut at the first `\\(`."""
    reads = []
    for match in READ_LITERAL_RE.finditer(swift_text):
        value = match.group(1)
        cut = value.find("\\(")
        if cut != -1:
            value = value[:cut]
        if _literal_targets_skippable_area(value):
            reads.append(value)
    reads.extend(find_directory_walk_literals(swift_text))
    return reads


def find_violations(swift_text, needed, label="<snippet>"):
    """Reads that the classifier would consider skippable (a drift bug)."""
    violations = []
    for value in find_repo_relative_reads(swift_text):
        for candidate in _candidates(value):
            if needed([candidate]) is not True:
                violations.append(
                    f"{label}: reads {value!r} but classifier treats {candidate!r} as skippable"
                )
                break
    return violations


def iter_swift_files(root=REPO_ROOT):
    for top in SWIFT_ROOTS:
        for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
            for name in filenames:
                if name.endswith(".swift"):
                    yield os.path.join(dirpath, name)


def _read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


class SwiftSourcesDoNotReadSkippablePathsTests(unittest.TestCase):
    def test_no_swift_source_reads_a_path_the_classifier_would_skip(self):
        needed = _mod().swift_jobs_needed
        violations = []
        for path in iter_swift_files():
            rel = os.path.relpath(path, REPO_ROOT)
            violations.extend(find_violations(_read(path), needed, label=rel))
        self.assertEqual(
            violations,
            [],
            "Swift sources read repo files that ci_changes.py would let CI skip. "
            "Either carve the path out of the skippable set in scripts/ci_changes.py "
            "or stop reading it from Swift:\n" + "\n".join(violations),
        )

    def test_scanner_finds_the_known_repo_reads(self):
        # Vacuity guard: if the scan silently finds nothing, the test above
        # proves nothing. These reads exist today.
        found = set()
        for path in iter_swift_files():
            found.update(find_repo_relative_reads(_read(path)))
        for expected in [
            "tests/fixtures/work_query_cases.json",
            "src/activity/store.rs",
            "tests/fixtures/mother-contract",
        ]:
            self.assertIn(expected, found)
        self.assertTrue(any(v.startswith("tests/fixtures/tracker/") for v in found), found)
        self.assertTrue(any(v.startswith("tests/fixtures/approvals/") for v in found), found)


class SwiftReadScannerBitesTests(unittest.TestCase):
    """The scanner must be able to fail, or the guard above proves nothing."""

    def violations(self, snippet):
        return find_violations(snippet, _mod().swift_jobs_needed)

    def test_reports_read_of_skippable_docs_file(self):
        snippet = 'let u = root.appendingPathComponent("docs/ci.md")\n'
        self.assertEqual(len(self.violations(snippet)), 1)

    def test_reports_read_of_skippable_rust_test_helper(self):
        snippet = 'let u = root.appendingPathComponent("tests/helper.rs")\n'
        self.assertEqual(len(self.violations(snippet)), 1)

    def test_reports_read_of_cargo_manifest(self):
        snippet = 'let u = root.appendingPathComponent("Cargo.toml")\n'
        self.assertEqual(len(self.violations(snippet)), 1)

    def test_reports_read_when_literal_is_on_the_following_line(self):
        snippet = (
            "let u = root\n"
            "    .appendingPathComponent(\n"
            '        "docs/ci.md"\n'
            "    )\n"
        )
        self.assertEqual(len(self.violations(snippet)), 1)

    def test_reports_read_via_url_file_url_with_path(self):
        snippet = 'let u = URL(fileURLWithPath: "docs/architecture.md")\n'
        self.assertEqual(len(self.violations(snippet)), 1)

    def test_reports_read_of_skippable_directory(self):
        snippet = 'let d = root.appendingPathComponent("docs/")\n'
        self.assertEqual(len(self.violations(snippet)), 1)

    def test_reports_read_of_skippable_directory_without_trailing_slash(self):
        snippet = 'let d = root.appendingPathComponent("tests")\n'
        self.assertEqual(len(self.violations(snippet)), 1)

    def test_reports_bare_skippable_directory_in_for_in_array_walk(self):
        for name in ["docs", "tests", ".claude"]:
            with self.subTest(name=name):
                snippet = f'for dir in ["macOS/Nostromo", "{name}"] {{\n'
                self.assertEqual(len(self.violations(snippet)), 1)

    def test_does_not_report_src_in_for_in_array_walk(self):
        # The StatusBarPostureWindowsTests pattern: src/** is not skippable.
        snippet = '        for dir in ["macOS/Nostromo", "src"] {\n'
        self.assertEqual(self.violations(snippet), [])

    def test_does_not_report_bare_directory_literal_outside_a_for_in_walk(self):
        snippet = 'let names = ["docs", "tests"]\n'
        self.assertEqual(self.violations(snippet), [])

    def test_does_not_report_read_of_mac_app_source(self):
        snippet = 'let u = root.appendingPathComponent("macOS/Nostromo/Data/AppStore.swift")\n'
        self.assertEqual(self.violations(snippet), [])

    def test_does_not_report_src_reads(self):
        snippet = (
            'a.appendingPathComponent("src/activity/store.rs")\n'
            'b.appendingPathComponent("src/ipc/protocol.rs")\n'
            'c.appendingPathComponent("src/")\n'
        )
        self.assertEqual(self.violations(snippet), [])

    def test_does_not_report_known_carved_out_reads(self):
        snippet = (
            'b.appendingPathComponent("tests/fixtures/tracker/\\(name)")\n'
            'c.appendingPathComponent("tests/fixtures/mother-contract")\n'
        )
        self.assertEqual(self.violations(snippet), [])


if __name__ == "__main__":
    unittest.main()
