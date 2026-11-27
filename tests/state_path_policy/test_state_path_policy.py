"""Policy: the Mac app reaches the user's state on disk only through `NostromoHome`.

Under XCTest `NostromoHome` resolves into a per-process temporary directory, so a test can never read,
write or delete the operator's real `~/.nostromo`, `~/.mother`, `~/.claude` or `~/Library/Application
Support`. That only holds while every path is built from it. This suite scans the Swift sources and
fails when something else starts to:

  1. asking the system for the home directory (`homeDirectoryForCurrentUser`, `NSHomeDirectory()`,
     `.applicationSupportDirectory`, ...), or spelling a `~/.nostromo` path;
  2. building a `.nostromo`, `.mother` or `.claude` path whose base is not `NostromoHome` (the string literal must have
     `NostromoHome.` in the same statement: the few lines before it).

The allow-list below is deliberately tiny and explicit: file -> token -> the most occurrences allowed,
each with the reason it never reads or writes state. A new entry needs a reason a reviewer accepts.

Textual check, not a control-flow proof (same discipline as `tests/hit_test_policy`). It never skips.

Run with:  python3 -m unittest discover -s tests/state_path_policy -v
"""
import os
import re
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCAN_ROOTS = [
    os.path.join(REPO, "macOS", "Nostromo"),
    os.path.join(REPO, "Shared", "NostromoKit", "Sources"),
]
SEAM = "macOS/Nostromo/Data/NostromoHome.swift"

# Ways to reach the user's home without going through the seam (regexes; `NostromoHome.<name>` is the seam's own).
FORBIDDEN = {
    "homeDirectoryForCurrentUser": r"homeDirectoryForCurrentUser",
    "NSHomeDirectory(": r"NSHomeDirectory(?:ForUser)?\(",
    ".applicationSupportDirectory": r"(?<!NostromoHome)\.applicationSupportDirectory",
    ".libraryDirectory": r"\.libraryDirectory",
    ".cachesDirectory": r"\.cachesDirectory",
    "getpwuid": r"getpwuid",
    'environment["HOME"]': r'environment\[\s*"HOME"\s*\]',
    "getenv(HOME)": r'getenv\(\s*"HOME"',
    "expandingTildeInPath": r"expandingTildeInPath",
    "/Users/ literal": r'"/Users/',
    '"~/.nostromo': r'"~/\.nostromo',
}
# A path component `.nostromo` / `.mother` / `.claude` inside a string literal ("com.hammer.nostromo" is a
# bundle id, not a path; `~/.claude/...` is text shown to the operator: Swift never expands a `~`, and
# `expandingTildeInPath` is forbidden above).
NOSTROMO_LITERAL = re.compile(r'"[^"\n]*(?<![A-Za-z0-9_])(?<!~/)\.(?:nostromo|mother|claude)(?=["/])')
LOOKBACK_LINES = 4

PATH_LITERAL = "a dot-directory path literal"

# file -> {token: most occurrences allowed}: why each is not state access.
ALLOWED = {
    # Display only: a path shown as `~/...` in the approval card; nothing is read or written with it.
    "macOS/Nostromo/UI/Approvals/ApprovalCardView.swift": {"NSHomeDirectory(": 3},
    # Display only: default of an injected `home` used to abbreviate paths in the persisted-rules list.
    "macOS/Nostromo/UI/Approvals/PersistedRulesView.swift": {"NSHomeDirectory(": 1},
    # Display / `~` expansion of project paths in the remote shell picker; injected in tests, never written.
    "macOS/Nostromo/UI/Terminal/NewRemoteShellSheet.swift": {"NSHomeDirectory(": 1},
    # Display only: the terminal header shortens the cwd to `~/...`.
    "macOS/Nostromo/Data/TerminalSessionStore.swift": {"NSHomeDirectory(": 1},
    # Looks for tool binaries (`gh`, `mother`, ...) in the user's real bin directories: it must see the
    # real ones and only checks they are executable.
    "macOS/Nostromo/Data/AppStore.swift": {"homeDirectoryForCurrentUser": 1, PATH_LITERAL: 1},
    # Project-relative file names (`.claude/settings.json` under a project root), not paths in the home.
    "macOS/Nostromo/Data/NoCodebaseFolder.swift": {PATH_LITERAL: 2},
    # Synthetic fixture text (demo plan paths, a fake tool-call transcript); nothing is opened.
    "macOS/Nostromo/UI/Views/MotherView.swift": {"/Users/ literal": 2, PATH_LITERAL: 2},
    "macOS/Nostromo/Data/TranscriptLoadHarness.swift": {"/Users/ literal": 1},
    # NostromoKit is shared with iOS and cannot see `NostromoHome`: the default `home` of a pure resolver.
    # The Mac callers (`CreateFocusSheet`, `NoCodebaseFolder`) pass `NostromoHome.userHome`.
    "Shared/NostromoKit/Sources/NostromoKit/Config/CodeRoot.swift": {"NSHomeDirectory(": 1},
    # The iOS app's own content cache (its sandbox container); no Mac code constructs it.
    "Shared/NostromoKit/Sources/NostromoKit/Store/ContentCache.swift": {".applicationSupportDirectory": 1},
    # Help text naming the rules file (a string shown to the operator), not a path that is opened.
    "Shared/NostromoKit/Sources/NostromoKit/Approvals/PersistedRulesText.swift": {'"~/.nostromo': 1},
}


def strip_comments(source):
    """Source with `//` and `/* */` comments blanked (line structure kept); string contents kept."""
    out, i, n = [], 0, len(source)
    in_string = False
    block = 0
    while i < n:
        c = source[i]
        two = source[i:i + 2]
        if block:
            if two == "*/":
                block -= 1
                out.append("  ")
                i += 2
            elif two == "/*":
                block += 1
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
            continue
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if c == '"' or c == "\n":
                in_string = False
            i += 1
            continue
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif two == "//":
            while i < n and source[i] != "\n":
                i += 1
        elif two == "/*":
            block = 1
            out.append("  ")
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def occurrences(source):
    """(token, line number) for each reach into the home that is not built from the seam, comments ignored."""
    lines = strip_comments(source).split("\n")
    found = []
    for number, line in enumerate(lines, 1):
        for token, pattern in FORBIDDEN.items():
            found.extend((token, number) for _ in re.findall(pattern, line))
        if NOSTROMO_LITERAL.search(line):
            window = "\n".join(lines[max(0, number - 1 - LOOKBACK_LINES):number])
            if "NostromoHome." not in window:
                found.append((PATH_LITERAL, number))
    return found


def violations(files):
    """`files` is a list of (repo-relative path, source). Returns a sorted list of violation strings."""
    found = []
    for path, source in files:
        if path == SEAM:
            continue
        seen = {}
        for token, number in occurrences(source):
            seen[token] = seen.get(token, 0) + 1
            if seen[token] > ALLOWED.get(path, {}).get(token, 0):
                what = ("a `.nostromo`/`.mother`/`.claude` path not built from NostromoHome" if token == PATH_LITERAL
                        else f"`{token}` reaches the user's home without NostromoHome")
                found.append(f"{path}:{number}: {what}")
    return sorted(set(found))


def swift_files():
    files = []
    for root in SCAN_ROOTS:
        for dirpath, _, names in os.walk(root):
            for name in sorted(names):
                if name.endswith(".swift"):
                    full = os.path.join(dirpath, name)
                    with open(full, encoding="utf-8") as f:
                        files.append((os.path.relpath(full, REPO).replace(os.sep, "/"), f.read()))
    return files


class StatePathPolicyTests(unittest.TestCase):
    def test_the_scan_sees_the_sources_and_the_seam(self):
        paths = {p for p, _ in swift_files()}
        self.assertIn(SEAM, paths)
        self.assertGreater(len(paths), 100)

    def test_nothing_reaches_the_users_state_except_through_nostromo_home(self):
        self.assertEqual(violations(swift_files()), [])

    def test_every_allow_list_entry_still_exists_and_is_used(self):
        by_path = dict(swift_files())
        for path, tokens in ALLOWED.items():
            self.assertIn(path, by_path, f"allow-list names a file that is gone: {path}")
            used = {}
            for token, _ in occurrences(by_path[path]):
                used[token] = used.get(token, 0) + 1
            for token, most in tokens.items():
                self.assertGreaterEqual(used.get(token, 0), 1, f"{path}: allow-list entry `{token}` is unused; drop it")
                self.assertLessEqual(used.get(token, 0), most)

    def test_the_seam_owns_the_test_home_redirect(self):
        source = dict(swift_files())[SEAM]
        self.assertIn("underTests: isRunningUnderTests", source)
        self.assertIn("isRunningUnderTests ? testHome : FileManager.default.homeDirectoryForCurrentUser", source)
        self.assertIn("if isRunningUnderTests {", source)  # applicationSupportDirectory


class BitesTests(unittest.TestCase):
    """The scan can fail: each rule fires on a synthetic source."""

    def check(self, source, path="macOS/Nostromo/Data/Thing.swift"):
        return violations([(path, source)])

    def test_home_directory_for_current_user_is_flagged(self):
        self.assertTrue(self.check("let h = FileManager.default.homeDirectoryForCurrentUser"))

    def test_ns_home_directory_is_flagged(self):
        self.assertTrue(self.check("let h = NSHomeDirectory()"))

    def test_application_support_lookup_is_flagged(self):
        self.assertTrue(self.check("FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)"))

    def test_a_dot_nostromo_path_on_another_base_is_flagged(self):
        self.assertTrue(self.check('let u = base.appendingPathComponent(".nostromo/x.json")'))

    def test_a_mother_or_claude_path_on_another_base_is_flagged(self):
        self.assertTrue(self.check('let u = base.appendingPathComponent(".mother/broker.sock")'))
        self.assertTrue(self.check('let u = "\\(home)/.claude/agents"'))

    def test_a_home_taken_from_the_environment_is_flagged(self):
        self.assertTrue(self.check('let h = ProcessInfo.processInfo.environment["HOME"]!'))
        self.assertTrue(self.check('let p = ("~/x" as NSString).expandingTildeInPath'))
        self.assertTrue(self.check('let p = "/Users/someone/x"'))

    def test_operator_facing_tilde_text_is_not_a_path(self):
        self.assertEqual(self.check('let m = "see ~/.claude/ecs-local.json"'), [])

    def test_a_tilde_nostromo_literal_is_flagged(self):
        self.assertTrue(self.check('let p = "~/.nostromo/focuses.json"'))

    def test_a_dot_nostromo_path_from_the_seam_passes(self):
        self.assertEqual(self.check('let u = NostromoHome.current\n    .appendingPathComponent(".nostromo/x.json")'), [])

    def test_a_dot_nostromo_path_far_from_the_seam_is_flagged(self):
        source = "let home = NostromoHome.current\n" + "\n" * 8 + 'let u = other.appendingPathComponent(".nostromo/x")'
        self.assertTrue(self.check(source))

    def test_comments_are_ignored(self):
        self.assertEqual(self.check('// NSHomeDirectory() and ".nostromo/x"\n/* homeDirectoryForCurrentUser */'), [])

    def test_a_url_in_a_string_is_not_taken_for_a_comment(self):
        self.assertTrue(self.check('let s = "https://x"; let h = NSHomeDirectory()'))

    def test_the_seam_file_itself_is_exempt(self):
        self.assertEqual(self.check("let h = NSHomeDirectory()", path=SEAM), [])

    def test_an_allow_listed_use_passes_but_one_more_does_not(self):
        path = "macOS/Nostromo/UI/Terminal/NewRemoteShellSheet.swift"
        self.assertEqual(self.check("let a = NSHomeDirectory()", path=path), [])
        self.assertTrue(self.check("let a = NSHomeDirectory()\nlet b = NSHomeDirectory()", path=path))


class SuiteNeverSkipsTests(unittest.TestCase):
    def test_this_file_has_no_skip_mechanism(self):
        with open(__file__, encoding="utf-8") as f:
            text = f.read()
        for marker in ("unittest.sk" + "ip", "skip" + "Test(", "XCT" + "Skip"):
            self.assertNotIn(marker, text)


if __name__ == "__main__":
    unittest.main()
