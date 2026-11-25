"""L5 policy for the hosted iOS unit-test target (`iOS/NostromoTests/`).

docs/ios-verification.md, "L5 - iOS simulator (backplane runtime only)": only behaviour that
needs an iOS process (Keychain access groups, URL handling / onOpenURL, file protection class,
extension / App Group wiring, the hosted harness itself) belongs in L5. Everything else stays
L1 (NostromoKit) or L2 (Python scans). To make that visible mechanically, every Swift file in
the target must START with a header comment line `// L5: <description>` naming the iOS-only
behaviour the file needs; the header may continue on following `//` lines.

Checks, each a plain function over `(path, source)` pairs returning violations (empty == pass),
each with a companion "bites" test on synthetic input proving it can fail:

1. l5_header_violations: the first non-blank line is `// L5:` plus a real description.
   Decisions: the spelling is strict. `//L5:`, `// L5` (no colon), `// l5:` and `/// L5:` are
   all rejected, because a grep for `// L5:` is how people find L5 files and a lenient variant
   would be invisible to it. The description must have at least MIN_DESCRIPTION_CHARS
   non-space characters on the header line itself, and may not open with a placeholder word
   (TODO, TBD, FIXME, XXX, WIP, N/A).
2. non_vacuous: the directory holds at least one .swift file, so check 1 cannot pass over an
   empty tree.
3. target_membership: every .swift file on disk is compiled by the `NostromoTests` target of
   iOS/Nostromo.xcodeproj (PBXNativeTarget -> Sources phase -> PBXBuildFile ->
   PBXFileReference), and every file the target compiles from that directory exists on disk.
   The parsing helpers are copied from tests/ci_policy/test_mac_test_target_membership.py
   (each policy dir runs under `discover -s <dir>`, so they cannot be imported).

This suite must never report a skip (CI greps for skips); SuiteNeverSkipsTests guards it.

Run with:
    python3 -I -m unittest discover -s tests/ios_policy -v
"""

import ast
import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
L5_DIR = os.path.join(REPO_ROOT, "iOS", "NostromoTests")
PROJECT = os.path.join(REPO_ROOT, "iOS", "Nostromo.xcodeproj", "project.pbxproj")
TARGET = "NostromoTests"

MIN_DESCRIPTION_CHARS = 20
PLACEHOLDERS = ("todo", "tbd", "fixme", "xxx", "wip", "n/a")

_HEADER_RE = re.compile(r"^// L5:[ \t]+(\S.*?)[ \t]*$")


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _l5_swift_files():
    paths = []
    for dirpath, _dirs, names in os.walk(L5_DIR):
        paths.extend(os.path.join(dirpath, n) for n in names if n.endswith(".swift"))
    return sorted(paths)


def _load_real_tree():
    return [(p, _read(p)) for p in _l5_swift_files()]


# --------------------------------------------------------------------------
# Check 1: header
# --------------------------------------------------------------------------

def l5_header_violations(files):
    out = []
    for path, source in files:
        first = next((ln for ln in source.lstrip("﻿").splitlines() if ln.strip()), None)
        if first is None:
            out.append(f"{path}: file is empty; it must start with `// L5: <iOS-only behaviour>`")
            continue
        m = _HEADER_RE.match(first)
        if not m:
            out.append(
                f"{path}: first non-blank line must be `// L5: <description>`, got {first.strip()!r}"
            )
            continue
        desc = m.group(1)
        if desc.lower().split()[0].rstrip(":.,;-") in PLACEHOLDERS:
            out.append(f"{path}: L5 description is a placeholder: {desc!r}")
        elif len(re.sub(r"\s", "", desc)) < MIN_DESCRIPTION_CHARS:
            out.append(
                f"{path}: L5 description under {MIN_DESCRIPTION_CHARS} non-space characters: {desc!r}"
            )
    return out


# --------------------------------------------------------------------------
# Check 2: non-vacuous
# --------------------------------------------------------------------------

def non_vacuous_violations(files):
    if not files:
        return ["no .swift files under iOS/NostromoTests: the L5 checks would pass vacuously"]
    return []


# --------------------------------------------------------------------------
# Check 3: target membership (parsing helpers copied from the macOS analogue)
# --------------------------------------------------------------------------

def _block(text, start):
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i : j + 1]
    raise ValueError("unbalanced braces in the project file")


def target_source_files(project_text, target=TARGET):
    """File names compiled by `target`: its Sources phase, build files resolved to paths."""
    m = re.search(r"\n\t\t(\w+) /\* %s \*/ = \{\s*isa = PBXNativeTarget;" % re.escape(target), project_text)
    if not m:
        raise AssertionError("no native target named %s in the project file" % target)
    target_body = _block(project_text, m.start())
    phases = re.search(r"buildPhases = \((.*?)\);", target_body, re.S).group(1)
    phase_ids = re.findall(r"(\w+) /\* [^*]*\*/", phases)

    names = set()
    for phase_id in phase_ids:
        pm = re.search(r"\n\t\t%s /\* [^*]*\*/ = \{\s*isa = PBXSourcesBuildPhase;" % phase_id, project_text)
        if not pm:
            continue  # frameworks phase etc.
        files = re.search(r"files = \((.*?)\);", _block(project_text, pm.start()), re.S).group(1)
        for build_id in re.findall(r"(\w+) /\*", files):
            bm = re.search(r"\n\t\t%s /\* [^*]*\*/ = \{isa = PBXBuildFile; fileRef = (\w+)" % build_id, project_text)
            if not bm:
                raise AssertionError("build file %s is not defined" % build_id)
            rm = re.search(
                r"\n\t\t%s /\* [^*]*\*/ = \{isa = PBXFileReference;[^}]*?path = ([^;]+);" % bm.group(1),
                project_text,
            )
            if not rm:
                raise AssertionError("file reference %s is not defined" % bm.group(1))
            names.add(os.path.basename(rm.group(1).strip().strip('"')))
    return names


def membership_violations(on_disk, project_text, target=TARGET):
    """`on_disk` is a set of .swift base names in iOS/NostromoTests."""
    in_target = target_source_files(project_text, target)
    out = [
        f"{n}: in iOS/NostromoTests but not compiled by the {target} target (never runs)"
        for n in sorted(on_disk - in_target)
    ]
    out += [
        f"{n}: compiled by the {target} target but missing from iOS/NostromoTests"
        for n in sorted(in_target - on_disk)
    ]
    return out


# --------------------------------------------------------------------------
# Real-tree tests
# --------------------------------------------------------------------------

class RealTreeTests(unittest.TestCase):
    def test_every_l5_test_file_starts_with_an_l5_header(self):
        self.assertEqual(l5_header_violations(_load_real_tree()), [])

    def test_the_l5_directory_is_not_empty(self):
        self.assertEqual(non_vacuous_violations(_load_real_tree()), [])

    def test_every_l5_test_file_is_compiled_by_the_nostromo_tests_target(self):
        on_disk = {os.path.basename(p) for p in _l5_swift_files()}
        self.assertEqual(membership_violations(on_disk, _read(PROJECT)), [])


# --------------------------------------------------------------------------
# Bites tests
# --------------------------------------------------------------------------

GOOD = "// L5: needs a Keychain access group, which only exists in an iOS process\nimport XCTest\n"


class HeaderBitesTests(unittest.TestCase):
    def check(self, source):
        return l5_header_violations([("X.swift", source)])

    def test_accepts_a_conforming_header_with_continuation_lines_and_leading_blank_lines(self):
        self.assertEqual(self.check(GOOD), [])
        self.assertEqual(self.check("\n\n" + GOOD + "// more detail\n"), [])

    def test_rejects_an_empty_header(self):
        self.assertTrue(self.check("// L5:\nimport XCTest\n"))
        self.assertTrue(self.check("// L5:   \nimport XCTest\n"))

    def test_rejects_placeholder_and_too_short_descriptions(self):
        self.assertTrue(self.check("// L5: TODO\nimport XCTest\n"))
        self.assertTrue(self.check("// L5: TODO: write this later when we know more\nimport XCTest\n"))
        self.assertTrue(self.check("// L5: needs iOS\nimport XCTest\n"))

    def test_rejects_a_header_that_is_not_the_first_line(self):
        self.assertTrue(self.check("import XCTest\n" + GOOD))
        self.assertTrue(self.check("// Copyright\n" + GOOD))

    def test_rejects_ambiguous_spellings(self):
        body = "needs a Keychain access group, which only exists in an iOS process\n"
        for variant in ("//L5: ", "// L5 ", "// l5: ", "/// L5: ", "/* L5: "):
            self.assertTrue(self.check(variant + body), variant)

    def test_rejects_an_empty_file(self):
        self.assertTrue(self.check(""))
        self.assertTrue(self.check("\n  \n"))


class NonVacuousBitesTests(unittest.TestCase):
    def test_empty_tree_is_reported(self):
        self.assertTrue(non_vacuous_violations([]))

    def test_non_empty_tree_passes(self):
        self.assertEqual(non_vacuous_violations([("X.swift", GOOD)]), [])


SYNTHETIC_PROJECT = """
/* Begin PBXBuildFile section */
\t\tBB01 /* A.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB11 /* A.swift */; };
\t\tBB02 /* B.swift in Sources */ = {isa = PBXBuildFile; fileRef = BB12 /* B.swift */; };
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
\t\tBB11 /* A.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = A.swift; sourceTree = "<group>"; };
\t\tBB12 /* B.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = B.swift; sourceTree = "<group>"; };
/* End PBXFileReference section */
/* Begin PBXNativeTarget section */
\t\tBB0A /* NostromoTests */ = {
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = (
\t\t\t\tBB0E /* Sources */,
\t\t\t);
\t\t\tname = NostromoTests;
\t\t};
/* End PBXNativeTarget section */
/* Begin PBXSourcesBuildPhase section */
\t\tBB0E /* Sources */ = {
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tfiles = (
\t\t\t\tBB01 /* A.swift in Sources */,
\t\t\t\tBB02 /* B.swift in Sources */,
\t\t\t);
\t\t};
/* End PBXSourcesBuildPhase section */
"""


class MembershipBitesTests(unittest.TestCase):
    def test_synthetic_project_in_sync_passes(self):
        self.assertEqual(membership_violations({"A.swift", "B.swift"}, SYNTHETIC_PROJECT), [])

    def test_file_on_disk_but_missing_from_the_sources_phase_is_reported(self):
        mutated = SYNTHETIC_PROJECT.replace("\t\t\t\tBB02 /* B.swift in Sources */,\n", "")
        self.assertNotEqual(mutated, SYNTHETIC_PROJECT)
        out = membership_violations({"A.swift", "B.swift"}, mutated)
        self.assertEqual(len(out), 1)
        self.assertIn("B.swift", out[0])

    def test_file_on_disk_but_unknown_to_the_project_is_reported(self):
        out = membership_violations({"A.swift", "B.swift", "C.swift"}, SYNTHETIC_PROJECT)
        self.assertEqual(len(out), 1)
        self.assertIn("C.swift", out[0])

    def test_file_in_the_project_but_not_on_disk_is_reported(self):
        out = membership_violations({"A.swift"}, SYNTHETIC_PROJECT)
        self.assertEqual(len(out), 1)
        self.assertIn("B.swift", out[0])

    def test_missing_target_is_an_error_not_a_pass(self):
        with self.assertRaises(AssertionError):
            target_source_files(SYNTHETIC_PROJECT, target="NoSuchTarget")


class SuiteNeverSkipsTests(unittest.TestCase):
    """Source-level guard (via ast, so this docstring may name what it forbids) that this
    module defines no skip decorator and makes no skipTest call."""

    def test_this_module_defines_no_skip_decorator_or_skipTest_call(self):
        tree = ast.parse(_read(__file__))
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                for dec in node.decorator_list:
                    self.assertNotIn("skip", ast.dump(dec).lower(), f"{node.name} has a skip decorator")
            if isinstance(node, ast.Call):
                name = getattr(node.func, "attr", None) or getattr(node.func, "id", None)
                self.assertNotEqual(name, "skipTest", "a skipTest(...) call was found")


if __name__ == "__main__":
    unittest.main()
