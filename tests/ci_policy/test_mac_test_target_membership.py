"""Every macOS/NostromoTests/*.swift file must be in the NostromoTests target of the Xcode project.

The project file lists test sources by hand, so a new test file that is not added to it is never
compiled and never run, in CI or locally (two Tracker fold test files went unlisted that way). These
tests read the real project file and the real directory, and prove the check can fail.
"""

import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PROJECT = os.path.join(ROOT, "macOS", "Nostromo.xcodeproj", "project.pbxproj")
TESTS_DIR = os.path.join(ROOT, "macOS", "NostromoTests")
TARGET = "NostromoTests"

# Files that live in macOS/NostromoTests but are deliberately not in the target: {file: reason}.
# Empty today: every file there is a real test or test support that compiles.
NOT_IN_TARGET_ON_PURPOSE = {}


def block(text, start):
    """The `{ ... }` body that opens at index `start` (the first brace at or after it)."""
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
    """File names compiled by `target`: its Sources build phase, build files resolved to paths."""
    m = re.search(r"\n\t\t(\w+) /\* %s \*/ = \{\s*isa = PBXNativeTarget;" % re.escape(target), project_text)
    if not m:
        raise AssertionError("no native target named %s in the project file" % target)
    target_body = block(project_text, m.start())
    phases = re.search(r"buildPhases = \((.*?)\);", target_body, re.S).group(1)
    phase_ids = re.findall(r"(\w+) /\* [^*]*\*/", phases)

    names = set()
    for phase_id in phase_ids:
        pm = re.search(r"\n\t\t%s /\* [^*]*\*/ = \{\s*isa = PBXSourcesBuildPhase;" % phase_id, project_text)
        if not pm:
            continue  # frameworks phase etc.
        files = re.search(r"files = \((.*?)\);", block(project_text, pm.start()), re.S).group(1)
        for build_id in re.findall(r"(\w+) /\*", files):
            bm = re.search(r"\n\t\t%s /\* [^*]*\*/ = \{isa = PBXBuildFile; fileRef = (\w+)" % build_id, project_text)
            if not bm:
                raise AssertionError("build file %s is not defined" % build_id)
            rm = re.search(r"\n\t\t%s /\* [^*]*\*/ = \{isa = PBXFileReference;[^}]*?path = ([^;]+);" % bm.group(1), project_text)
            if not rm:
                raise AssertionError("file reference %s is not defined" % bm.group(1))
            names.add(os.path.basename(rm.group(1).strip().strip('"')))
    return names


def unlisted(on_disk, in_target, allowed=NOT_IN_TARGET_ON_PURPOSE):
    return sorted(f for f in on_disk if f not in in_target and f not in allowed)


class MacTestTargetMembershipTests(unittest.TestCase):
    def setUp(self):
        with open(PROJECT, encoding="utf-8") as f:
            self.project = f.read()
        self.on_disk = {f for f in os.listdir(TESTS_DIR) if f.endswith(".swift")}
        self.in_target = target_source_files(self.project)

    def test_the_target_is_found_and_has_the_files_everyone_knows_about(self):
        self.assertGreater(len(self.in_target), 300)
        for name in ("TrackerFoldTests.swift", "TrackerFoldAppearanceTests.swift", "TrackerStoreTests.swift"):
            self.assertIn(name, self.in_target)

    def test_every_test_swift_file_is_in_the_nostromo_tests_target(self):
        self.assertEqual(
            unlisted(self.on_disk, self.in_target),
            [],
            "these files are in macOS/NostromoTests but not in the %s target of project.pbxproj, so "
            "they are never compiled or run: add them (file reference, build file, group, sources "
            "phase)" % TARGET,
        )

    def test_the_allow_list_only_names_files_that_exist_and_are_really_unlisted(self):
        for name, reason in NOT_IN_TARGET_ON_PURPOSE.items():
            self.assertTrue(reason.strip(), "%s needs a reason" % name)
            self.assertIn(name, self.on_disk, "%s is allow-listed but not on disk" % name)
            self.assertNotIn(name, self.in_target, "%s is allow-listed but is in the target" % name)

    def test_check_bites_when_an_entry_is_removed_from_the_sources_phase(self):
        build_line = re.search(
            r"\n(\t\t\t\t\w+ /\* TrackerFoldTests\.swift in Sources \*/,)", self.project
        ).group(1)
        mutated = self.project.replace("\n" + build_line, "", 1)
        self.assertNotEqual(mutated, self.project)
        in_target = target_source_files(mutated)
        self.assertEqual(unlisted(self.on_disk, in_target), ["TrackerFoldTests.swift"])

    def test_check_bites_when_a_file_is_on_disk_but_nowhere_in_the_project(self):
        self.assertEqual(unlisted(self.on_disk | {"BrandNewTests.swift"}, self.in_target), ["BrandNewTests.swift"])


if __name__ == "__main__":
    unittest.main()
