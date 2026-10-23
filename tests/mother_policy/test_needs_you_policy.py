"""Source-scanning policy for the "needs you" surface (MC4).

The promises: the Dock badge has one writer; a notification arriving never brings the app forward
(only a click may); the one place a notification's content is built is the Kit notifier (so the
no-content-leak wording lives in one reviewed file); and the UserNotifications framework is
touched only by the two files that own it on the Mac.

These are tests of what the source LOOKS like (a textual heuristic, not a control-flow proof),
in the same spirit as tests/ios_policy. Each check is a plain function over source text, with a
"bites" test on a synthetic source so a check that cannot fail would be noticed.

Run with:  python3 -m unittest discover -s tests/mother_policy -v
"""
import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MAC = os.path.join("macOS", "Nostromo")
APP_STORE = os.path.join(MAC, "Data", "AppStore.swift")
APP_DELEGATE = os.path.join(MAC, "AppDelegate.swift")
BROKER_CLIENT = os.path.join(MAC, "Data", "MotherBrokerClient.swift")
MOTHER_VIEW = os.path.join(MAC, "UI", "Views", "MotherView.swift")
TERI_BINDINGS = os.path.join(MAC, "UI", "Views", "TeriBindings.swift")
KIT_NEEDS_YOU_DIR = os.path.join("Shared", "NostromoKit", "Sources", "NostromoKit", "NeedsYou")
KIT_NOTIFIER = os.path.join(KIT_NEEDS_YOU_DIR, "NeedsYouNotifier.swift")


# --------------------------------------------------------------------------
# Source handling
# --------------------------------------------------------------------------

def code_view(src):
    """`src` with comments removed and string-literal text blanked, line for line.

    The code inside a string's `\\( ... )` interpolation is kept (it is code, and it is where a
    logged value would hide). Newlines are preserved so line numbers still match the original.
    """
    out, i, n = [], 0, len(src)

    def skip_string(i, quote):
        """Consume a string literal body starting after its opening quote; returns the index after it."""
        out.append('"')
        while i < n:
            if src.startswith(quote, i):
                out.append('"')
                return i + len(quote)
            c = src[i]
            if c == "\\" and i + 1 < n:
                if src[i + 1] == "(":                      # interpolation: keep its code
                    depth, j = 1, i + 2
                    while j < n and depth:
                        depth += {"(": 1, ")": -1}.get(src[j], 0)
                        j += 1
                    out.append(" " + code_view(src[i + 2:j - 1]) + " ")
                    i = j
                else:
                    i += 2
                continue
            out.append("\n" if c == "\n" else " ")
            i += 1
        return i

    while i < n:
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            end = src.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append("\n" * src.count("\n", i, end))
            i = end
        elif src.startswith('"""', i):
            i = skip_string(i + 3, '"""')
        elif src[i] == '"':
            i = skip_string(i + 1, '"')
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def swift_files(*roots):
    """Repo-relative paths of every .swift file under the given repo-relative roots (sorted)."""
    found = []
    for root in roots:
        for dirpath, _dirs, files in os.walk(os.path.join(REPO_ROOT, root)):
            for name in files:
                if name.endswith(".swift"):
                    found.append(os.path.relpath(os.path.join(dirpath, name), REPO_ROOT))
    return sorted(found)


def read(rel):
    with open(os.path.join(REPO_ROOT, rel), encoding="utf-8") as fh:
        return fh.read()


def files_matching(paths, pattern, sources=None):
    """Paths whose code view (comments and string text removed) matches `pattern`.

    `sources` maps a path to its text (used by the synthetic tests); otherwise files are read.
    """
    hits = []
    for rel in paths:
        text = sources[rel] if sources is not None else read(rel)
        if re.search(pattern, code_view(text)):
            hits.append(rel)
    return hits


def function_bodies(code):
    """[(header text, body start, body end)] for each `func` in `code` (a code view), by brace matching."""
    out = []
    for m in re.finditer(r"\bfunc\b", code):
        i, depth = m.end(), 0
        while i < len(code):
            c = code[i]
            if c in "([<":
                depth += 1
            elif c in ")]>" and not (c == ">" and code[i - 1] == "-"):
                depth -= 1
            elif c == "{" and depth <= 0:
                break
            elif c == ";" and depth <= 0:
                i = len(code)
            i += 1
        if i >= len(code):
            continue
        start, depth = i, 0
        while i < len(code):
            if code[i] == "{":
                depth += 1
            elif code[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        out.append((code[m.start():start], start, i + 1))
    return out


def function_body(code, header_pattern):
    """The body text of the one function whose header matches `header_pattern`; AssertionError otherwise."""
    matches = [(h, s, e) for h, s, e in function_bodies(code) if re.search(header_pattern, h)]
    assert len(matches) == 1, f"expected exactly one function matching {header_pattern!r}, found {len(matches)}"
    _h, start, end = matches[0]
    return code[start:end]


def enclosing_function_header(code, pos):
    """Header of the innermost function containing offset `pos`, or None at file level."""
    best = None
    for header, start, end in function_bodies(code):
        if start <= pos < end and (best is None or start > best[1]):
            best = (header, start)
    return best[0] if best else None


# --------------------------------------------------------------------------
# Checks
# --------------------------------------------------------------------------

# Either word alone: a split spelling (`let tile = NSApp.dockTile` ... `tile.badgeLabel = x`) is a second
# writer too, and `dockTile` alone is how the tile is reached at all.
BADGE = r"\bdockTile\b|\bbadgeLabel\b"
# `NSApp.activate(...)` and any `x.activate(...)` (NSRunningApplication and the like). The layout
# system's `NSLayoutConstraint.activate([...])` is not about the app and is allowed.
APP_ACTIVATION = r"\bNSApp\s*\.\s*activate\b|(?<!NSLayoutConstraint)\s*\.\s*activate\s*\("
NSAPP_ACTIVATE = r"\bNSApp\s*\.\s*activate\b"
USER_NOTIFICATIONS_IMPORT = r"^\s*(?:@\w+\s+)*import\s+UserNotifications\b"
# The mutable class and the immutable one it subclasses: neither is named outside the builder.
MUTABLE_CONTENT = r"\bUN(?:Mutable)?NotificationContent\b"


def badge_writers(sources=None):
    """Swift files under macOS/ and Shared/ that name `dockTile` or `badgeLabel`."""
    paths = list(sources) if sources is not None else swift_files("macOS", "Shared")
    return files_matching(paths, BADGE, sources)


def activation_in_forbidden_files(sources=None):
    """Files that must never bring the app forward but mention doing so."""
    if sources is not None:
        paths = list(sources)
    else:
        paths = [APP_STORE, BROKER_CLIENT, MOTHER_VIEW, TERI_BINDINGS] + \
            swift_files(KIT_NEEDS_YOU_DIR)
    return files_matching(paths, APP_ACTIVATION, sources)


def delegate_activation_problems(src):
    """What is wrong with where AppDelegate activates the app (empty when fine)."""
    code = code_view(src)
    problems = []
    did_receive = function_body(code, r"userNotificationCenter\s*\([^{]*didReceive")
    will_present = function_body(code, r"userNotificationCenter\s*\([^{]*willPresent")
    if not re.search(NSAPP_ACTIVATE, did_receive):
        problems.append("didReceive (a click) must bring the app forward with NSApp.activate")
    if re.search(APP_ACTIVATION, will_present):
        problems.append("willPresent (an arrival) must never activate the app")
    for m in re.finditer(NSAPP_ACTIVATE, code):
        header = enclosing_function_header(code, m.start()) or ""
        if not re.search(r"\bopenLaunchWindows\b", header) and not re.search(r"didReceive", header):
            problems.append(f"NSApp.activate at offset {m.start()} is in {header.strip()[:60]!r}; "
                            "only openLaunchWindows and didReceive may activate")
    return problems


def mutable_content_files(sources=None):
    """Swift files under macOS/, Shared/ and iOS/ that name UNMutableNotificationContent (or UNNotificationContent)."""
    paths = list(sources) if sources is not None else swift_files("macOS", "Shared", "iOS")
    return files_matching(paths, MUTABLE_CONTENT, sources)


def user_notifications_importers(sources=None):
    """App and Kit source files (not test targets, which fake the notification center) that import UserNotifications."""
    paths = list(sources) if sources is not None else swift_files(MAC, os.path.join("Shared", "NostromoKit", "Sources"))
    hits = []
    for rel in paths:
        text = sources[rel] if sources is not None else read(rel)
        if re.search(USER_NOTIFICATIONS_IMPORT, code_view(text), re.MULTILINE):
            hits.append(rel)
    return hits


def under(rel, directory):
    return rel.startswith(directory + os.sep)


# --------------------------------------------------------------------------
# The policy over the repo
# --------------------------------------------------------------------------

class NeedsYouPolicyTests(unittest.TestCase):
    def test_only_the_app_store_writes_the_dock_badge(self):
        self.assertEqual(badge_writers(), [APP_STORE])

    def test_nothing_that_receives_or_routes_needs_you_items_activates_the_app(self):
        self.assertEqual(activation_in_forbidden_files(), [])

    def test_the_app_comes_forward_on_a_click_and_never_on_an_arrival(self):
        self.assertEqual(delegate_activation_problems(read(APP_DELEGATE)), [])

    def test_the_notification_content_is_built_only_in_the_kit_notifier(self):
        self.assertEqual(mutable_content_files(), [KIT_NOTIFIER])

    def test_only_the_notifier_the_delegate_and_the_app_store_import_user_notifications(self):
        allowed = {APP_DELEGATE, APP_STORE}
        stray = [p for p in user_notifications_importers() if p not in allowed and not under(p, KIT_NEEDS_YOU_DIR)]
        self.assertEqual(stray, [])

    def test_the_kit_notifier_does_import_user_notifications(self):
        self.assertIn(KIT_NOTIFIER, user_notifications_importers())


# --------------------------------------------------------------------------
# The checks bite
# --------------------------------------------------------------------------

class ChecksBiteTests(unittest.TestCase):
    def test_a_second_badge_writer_is_caught(self):
        sources = {"a/Store.swift": "NSApp.dockTile.badgeLabel = x", "b/Other.swift": "NSApp.dockTile.badgeLabel = nil"}
        self.assertEqual(badge_writers(sources), ["a/Store.swift", "b/Other.swift"])

    def test_a_split_spelling_of_the_badge_write_is_caught(self):
        for text in ["let tile = NSApp.dockTile\ntile.badgeLabel = \"3\"",
                     "NSApplication.shared.dockTile.display()",
                     "someTile.badgeLabel = nil",
                     "NSApp\n    .dockTile\n    .badgeLabel = x"]:
            self.assertEqual(badge_writers({"z/Sneaky.swift": text}), ["z/Sneaky.swift"], text)

    def test_a_badge_writer_in_a_comment_or_string_is_not_one(self):
        sources = {"a.swift": '// dockTile.badgeLabel = "1"\nlet s = "dockTile.badgeLabel"'}
        self.assertEqual(badge_writers(sources), [])

    def test_app_activation_is_caught_in_each_spelling(self):
        for line in ["NSApp.activate(ignoringOtherApps: true)", "NSApp.activate()", "app.activate(options: [])",
                     "others.first?.activate()", "NSApplication.shared.activate(ignoringOtherApps: true)"]:
            self.assertEqual(activation_in_forbidden_files({"x.swift": line}), ["x.swift"], line)

    def test_layout_constraint_activation_and_comments_are_not_app_activation(self):
        for line in ["NSLayoutConstraint.activate([a, b])", "// NSApp.activate(ignoringOtherApps: true)",
                     'let s = "NSApp.activate"']:
            self.assertEqual(activation_in_forbidden_files({"x.swift": line}), [], line)

    DELEGATE_OK = """
    func openLaunchWindows() { NSApp.activate(ignoringOtherApps: true) }
    extension AppDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            NSApp.activate(ignoringOtherApps: true)
        }
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner])
        }
    }
    """

    def test_a_correct_delegate_has_no_problems(self):
        self.assertEqual(delegate_activation_problems(self.DELEGATE_OK), [])

    def test_activating_on_arrival_is_caught(self):
        bad = self.DELEGATE_OK.replace("completionHandler([.banner])",
                                       "NSApp.activate(ignoringOtherApps: true); completionHandler([.banner])")
        problems = delegate_activation_problems(bad)
        self.assertTrue(any("willPresent" in p for p in problems), problems)

    def test_a_click_that_does_not_activate_is_caught(self):
        bad = self.DELEGATE_OK.replace("""didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            NSApp.activate(ignoringOtherApps: true)""", """didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            completionHandler()""")
        problems = delegate_activation_problems(bad)
        self.assertTrue(any("didReceive" in p for p in problems), problems)

    def test_activating_from_another_function_is_caught(self):
        bad = self.DELEGATE_OK + "\nfunc somethingElse() { NSApp.activate(ignoringOtherApps: true) }\n"
        problems = delegate_activation_problems(bad)
        self.assertTrue(any("only openLaunchWindows and didReceive" in p for p in problems), problems)

    def test_a_missing_delegate_method_is_an_error_not_a_pass(self):
        with self.assertRaises(AssertionError):
            delegate_activation_problems("func openLaunchWindows() { NSApp.activate(ignoringOtherApps: true) }")

    def test_content_built_outside_the_notifier_is_caught(self):
        sources = {"k/NeedsYouNotifier.swift": "let c = UNMutableNotificationContent()",
                   "m/Other.swift": "let c = UNMutableNotificationContent()"}
        self.assertEqual(mutable_content_files(sources), ["k/NeedsYouNotifier.swift", "m/Other.swift"])
        self.assertEqual(mutable_content_files({"m/Other.swift": "// UNMutableNotificationContent"}), [])

    def test_content_built_through_the_immutable_class_or_a_typealias_is_caught(self):
        for text in ["typealias C = UNMutableNotificationContent", "let c: UNNotificationContent = x.content",
                     "let c = UNMutableNotificationContent()\nc.title = \"x\""]:
            self.assertEqual(mutable_content_files({"m/Sneaky.swift": text}), ["m/Sneaky.swift"], text)

    def test_a_stray_user_notifications_import_is_caught(self):
        sources = {"a.swift": "import Foundation\nimport UserNotifications\n", "b.swift": "import Foundation\n",
                   "c.swift": "// import UserNotifications\n", "d.swift": "  @preconcurrency import UserNotifications\n"}
        self.assertEqual(user_notifications_importers(sources), ["a.swift", "d.swift"])


if __name__ == "__main__":
    unittest.main()
