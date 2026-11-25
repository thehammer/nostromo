"""Backplane policy for the iOS client (W11): two source scans.

W11-16 (Ada D7, operator Q7). The phone shows nothing from the message queue, so no code the iOS
target uses may send `session_queue_watch`, `session_queue_take_back` or `session_queue_remove`.
The one allowed mention is `OutboundPolicy.refusedTypes` in Kit's WebSocketClient.swift, which is
the list of verbs the transport REFUSES to send. Scanned: `iOS/Nostromo/**` and
`Shared/NostromoKit/Sources/**`.

W11-21 (operator Q2, PRD AC56 and "Final v1 copy"). In v1 mail, calendar and todos stay on the Mac
with no way to turn sharing on, and the only sentence in the app about them is
"Mail, calendar and todos stay on your Mac in this version." (Fred tab, Teri tab, device Settings).
So no string literal under `iOS/Nostromo/**` may mention mail, calendar or todos, and the one
sentence lives in Kit's `PairingCopy.notShared` exactly as written.

Each check is a plain function over `(path, source)` pairs returning violations (empty == pass),
with a companion "bites" test on synthetic input. This suite must never report a skip.

Run with:
    python3 -I -m unittest discover -s tests/ios_policy -v
"""

import ast
import os
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IOS_DIR = os.path.join(REPO_ROOT, "iOS", "Nostromo")
KIT_DIR = os.path.join(REPO_ROOT, "Shared", "NostromoKit", "Sources")
PAIRING_COPY = os.path.join(KIT_DIR, "NostromoKit", "Pairing", "PairingCopy.swift")

QUEUE_VERBS = re.compile(r"session_queue_(?:watch|take_back|remove)|SessionQueue(?:Watch|TakeBack|Remove)")
QUEUE_ALLOWED_FILE = "WebSocketClient.swift"

NOT_SHARED = "Mail, calendar and todos stay on your Mac in this version."
TOPIC_WORDS = re.compile(r"\b(?:e-?mails?|mailbox(?:es)?|inbox(?:es)?|calendars?|todos?|to-dos?)\b", re.IGNORECASE)
STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _swift_files(root):
    out = []
    for dirpath, _dirs, names in os.walk(root):
        out.extend(os.path.join(dirpath, n) for n in names if n.endswith(".swift"))
    return sorted(out)


def _strip_line_comments(source):
    return "\n".join(re.sub(r"//.*$", "", line) for line in source.splitlines())


def queue_verb_violations(files):
    """A queue verb named anywhere but the transport's refusal list."""
    violations = []
    for path, source in files:
        if os.path.basename(path) == QUEUE_ALLOWED_FILE:
            continue
        for m in QUEUE_VERBS.finditer(_strip_line_comments(source)):
            violations.append((path, m.group(0)))
    return violations


def topic_string_violations(files):
    """A string literal that mentions mail, calendar or todos."""
    violations = []
    for path, source in files:
        for m in STRING_LITERAL.finditer(_strip_line_comments(source)):
            if TOPIC_WORDS.search(m.group(1)):
                violations.append((path, m.group(1)))
    return violations


class QueueVerbPolicyTests(unittest.TestCase):
    def test_no_ios_or_kit_code_names_a_queue_verb_outside_the_refusal_list(self):
        files = [(p, _read(p)) for p in _swift_files(IOS_DIR) + _swift_files(KIT_DIR)]
        self.assertGreater(len(files), 10, "the scan must not pass over an empty tree")
        self.assertEqual(queue_verb_violations(files), [])

    def test_the_transport_refuses_all_three_queue_verbs(self):
        source = _read(os.path.join(KIT_DIR, "NostromoKit", "Transport", QUEUE_ALLOWED_FILE))
        for verb in ("session_queue_watch", "session_queue_take_back", "session_queue_remove"):
            self.assertIn('"%s"' % verb, source)

    def test_bites_on_a_sender(self):
        bad = [("iOS/Nostromo/X.swift", 'let type_ = "session_queue_watch"')]
        self.assertEqual(len(queue_verb_violations(bad)), 1)
        bad = [("Shared/NostromoKit/Sources/ClientMsg.swift", "struct ClientSessionQueueWatch: Encodable {}")]
        self.assertEqual(len(queue_verb_violations(bad)), 1)

    def test_a_comment_or_the_refusal_list_is_not_a_violation(self):
        self.assertEqual(queue_verb_violations([("X.swift", "// never send session_queue_watch")]), [])
        self.assertEqual(
            queue_verb_violations([("Transport/WebSocketClient.swift", '"session_queue_watch",')]), [])


class MailCalendarTodosCopyPolicyTests(unittest.TestCase):
    def test_no_ios_string_mentions_mail_calendar_or_todos(self):
        files = [(p, _read(p)) for p in _swift_files(IOS_DIR)]
        self.assertGreater(len(files), 10, "the scan must not pass over an empty tree")
        self.assertEqual(topic_string_violations(files), [])

    def test_the_one_sentence_is_exactly_the_final_v1_copy(self):
        source = _read(PAIRING_COPY)
        self.assertIn('"%s"' % NOT_SHARED, source)
        self.assertEqual(len(re.findall(re.escape(NOT_SHARED), source)), 1)

    def test_fred_teri_and_settings_use_that_sentence(self):
        for rel in ("Views/FredView.swift", "Views/TeriView.swift", "Views/DeviceSettingsView.swift"):
            source = _read(os.path.join(IOS_DIR, rel))
            self.assertTrue("PairingCopy.notShared" in source or "NotSharedView" in source, rel)

    def test_no_control_can_turn_sharing_on(self):
        # Nothing on a device names a sharing scope: no `sensitive`, `device_scope` or `share` setting.
        for path in _swift_files(IOS_DIR):
            code = _strip_line_comments(_read(path))
            self.assertNotRegex(code, r"device_scope|deviceScope|sharesMail|shareMail", path)

    def test_bites_on_a_mail_string(self):
        for text in ("Inbox empty", "Error loading mailbox", "No events today and a Calendar", "Teri's todo list"):
            bad = [("iOS/Nostromo/V.swift", 'Text("%s")' % text)]
            self.assertEqual(len(topic_string_violations(bad)), 1, text)

    def test_ignores_code_and_comments_that_only_name_the_words(self):
        ok = [("iOS/Nostromo/V.swift", "// the mail tab\nlet todoCount = 3\nText(PairingCopy.notShared)")]
        self.assertEqual(topic_string_violations(ok), [])


class SuiteNeverSkipsTests(unittest.TestCase):
    def test_this_module_defines_no_skip_decorator_or_skiptest_call(self):
        tree = ast.parse(_read(__file__))
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for dec in node.decorator_list:
                    self.assertNotIn("skip", ast.dump(dec).lower(), node.name)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                self.assertNotEqual(node.func.attr, "skipTest")


if __name__ == "__main__":
    unittest.main()
