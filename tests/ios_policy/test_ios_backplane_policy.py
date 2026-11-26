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

W11 fix round 1 adds five more source checks (each with a "bites" test):
  - the client's `allowedTypes` equals the daemon's `NETWORK_ALLOWED` (`src/ipc/peer.rs`), and its
    separate `pairedDeviceTypes` is exactly the four W13 push verbs (`register_push`,
    `set_push_prefs`, `push_sent_log`, `push_waiting`), none of them in `NETWORK_ALLOWED`, and
    `operator_presence` in neither list;
  - `Info.plist` allows local networking for App Transport Security and never arbitrary loads;
  - the pairing start screen reaches the legacy local-network transport;
  - the controls that change state on the Mac sit behind `canMutate`;
  - the confirmation screen shows the address, port and code.

Each check is a plain function over `(path, source)` pairs returning violations (empty == pass),
with a companion "bites" test on synthetic input. This suite must never report a skip.

Run with:
    python3 -I -m unittest discover -s tests/ios_policy -v
"""

import ast
import os
import plistlib
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IOS_DIR = os.path.join(REPO_ROOT, "iOS", "Nostromo")
KIT_DIR = os.path.join(REPO_ROOT, "Shared", "NostromoKit", "Sources")
PAIRING_COPY = os.path.join(KIT_DIR, "NostromoKit", "Pairing", "PairingCopy.swift")
PEER_RS = os.path.join(REPO_ROOT, "src", "ipc", "peer.rs")
INFO_PLIST = os.path.join(IOS_DIR, "Info.plist")

QUEUE_VERBS = re.compile(r"session_queue_(?:watch|take_back|remove)|SessionQueue(?:Watch|TakeBack|Remove)")
QUEUE_ALLOWED_FILE = "WebSocketClient.swift"
WS_CLIENT = os.path.join(KIT_DIR, "NostromoKit", "Transport", QUEUE_ALLOWED_FILE)

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


RUST_ALLOWED_RE = re.compile(r"const NETWORK_ALLOWED: &\[&str\] = &\[(.*?)\];", re.S)
SWIFT_ALLOWED_RE = re.compile(r"static let allowedTypes: Set<String> = \[(.*?)\]", re.S)


def rust_network_allowed(source):
    """The wire `type` values of the daemon's `NETWORK_ALLOWED` (Rust variant names -> snake_case)."""
    m = RUST_ALLOWED_RE.search(source)
    if not m:
        return set()
    names = re.findall(r'"([A-Za-z0-9]+)"', m.group(1))
    return {re.sub(r"(?<!^)(?=[A-Z])", "_", n).lower() for n in names}


def swift_allowed_types(source):
    """The strings in `OutboundPolicy.allowedTypes` (comments ignored)."""
    m = SWIFT_ALLOWED_RE.search(_strip_line_comments(source))
    if not m:
        return set()
    return set(re.findall(r'"([a-z0-9_]+)"', m.group(1)))


def allow_list_violations(rust_source, swift_source):
    rust, swift = rust_network_allowed(rust_source), swift_allowed_types(swift_source)
    if not rust:
        return ["NETWORK_ALLOWED was not found in src/ipc/peer.rs"]
    if not swift:
        return ["OutboundPolicy.allowedTypes was not found in WebSocketClient.swift"]
    out = ["daemon allows %r, the phone does not list it" % t for t in sorted(rust - swift)]
    out += ["the phone lists %r, the daemon's NETWORK_ALLOWED does not" % t for t in sorted(swift - rust)]
    return out


PUSH_VERBS = {"register_push", "set_push_prefs", "push_sent_log", "push_waiting"}
SWIFT_PAIRED_RE = re.compile(r"static let pairedDeviceTypes: Set<String> = \[(.*?)\]", re.S)


def swift_paired_device_types(source):
    """The strings in `OutboundPolicy.pairedDeviceTypes` (comments ignored)."""
    m = SWIFT_PAIRED_RE.search(_strip_line_comments(source))
    if not m:
        return set()
    return set(re.findall(r'"([a-z0-9_]+)"', m.group(1)))


def paired_device_violations(rust_source, swift_source):
    """`pairedDeviceTypes` is exactly the four push verbs, outside NETWORK_ALLOWED and `allowedTypes`;
    `operator_presence` (the Mac app's verb) is on neither list."""
    paired = swift_paired_device_types(swift_source)
    allowed = swift_allowed_types(swift_source)
    network = rust_network_allowed(rust_source)
    if not paired:
        return ["OutboundPolicy.pairedDeviceTypes was not found in WebSocketClient.swift"]
    out = ["pairedDeviceTypes lists %r, which is not a W13 push verb" % t for t in sorted(paired - PUSH_VERBS)]
    out += ["pairedDeviceTypes does not list the push verb %r" % t for t in sorted(PUSH_VERBS - paired)]
    out += ["%r is in the daemon's NETWORK_ALLOWED; the push verbs are not network verbs" % t
            for t in sorted(PUSH_VERBS & network)]
    out += ["%r is in allowedTypes as well as pairedDeviceTypes" % t for t in sorted(PUSH_VERBS & allowed)]
    for t in ("operator_presence",):
        if t in paired or t in allowed or t in network:
            out.append("%r must be on no list: only the Mac app sends it" % t)
    return out


def ats_violations(plist_bytes):
    """App Transport Security: local networking on, arbitrary loads never on."""
    info = plistlib.loads(plist_bytes)
    ats = info.get("NSAppTransportSecurity")
    if not isinstance(ats, dict):
        return ["Info.plist has no NSAppTransportSecurity dictionary"]
    out = []
    if ats.get("NSAllowsLocalNetworking") is not True:
        out.append("NSAllowsLocalNetworking is not true: iOS 17 blocks plain ws:// to IP literals")
    for key in ("NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia"):
        if ats.get(key):
            out.append("%s must stay absent or false (least privilege)" % key)
    if "NSExceptionDomains" in ats:
        out.append("NSExceptionDomains is not allowed without a documented, narrowly scoped reason")
    return out


def legacy_path_violations(start_view, flow_view):
    """The pairing start screen must offer the legacy transport and the flow must switch to it."""
    out = []
    if "Use local network (legacy)" not in start_view:
        out.append("PairWithNostromoView has no 'Use local network (legacy)' control")
    if "onUseLegacy" not in start_view:
        out.append("PairWithNostromoView does not call onUseLegacy")
    if not re.search(r"setTransport\(\s*\.legacyTCP\s*\)", flow_view):
        out.append("PairingFlowView does not switch the transport to .legacyTCP")
    return out


def gating_violations(files):
    """Every control that changes state on the Mac must sit behind `canMutate`.

    Checked per site: an `InputBar(` composer, an Approve swipe action, the transcript toolbar menu
    and the decision sheet's read-only flag. `files` maps a path suffix to its source."""
    out = []
    for path, source in files.items():
        code = _strip_line_comments(source)
        if path.endswith("TranscriptView.swift"):
            if not re.search(r"if store\.canMutate \{\s*InputBar\(", code):
                out.append("%s: the composer is not behind `if store.canMutate`" % path)
            if not re.search(r"\.toolbar \{\s*if store\.canMutate \{\s*ToolbarItem", code):
                out.append("%s: the Restart/Stop/New Session menu is not behind `if store.canMutate`" % path)
            if "canAnswer: store.canMutate" not in code:
                out.append("%s: turn-card answer buttons do not receive canMutate" % path)
        if path.endswith(("PerriView.swift", "PaneSurfaceView.swift")):
            for m in re.finditer(r"\.swipeActions\([^)]*\) \{(.*?)\n\s*\}\n", code, re.S):
                if "Approve" in m.group(1) and "if store.canMutate" not in m.group(1):
                    out.append("%s: an Approve swipe action is not behind `if store.canMutate`" % path)
            if "actionsEnabled: store.canMutate" not in code:
                out.append("%s: PerriPRRow rows do not receive actionsEnabled: store.canMutate" % path)
        if path.endswith("NostromoApp.swift"):
            if not re.search(r"readOnlyDecisions: Bool \{ !store\.canMutate \}", code):
                out.append("%s: readOnlyDecisions is not derived from store.canMutate" % path)
    return out


def confirmation_violations(source):
    out = []
    for needle in ("confirmation.address", "confirmation.port", "confirmation.code"):
        if needle not in source:
            out.append("ConfirmPairingView does not show %s" % needle)
    return out


class QueueVerbPolicyTests(unittest.TestCase):
    def test_no_ios_or_kit_code_names_a_queue_verb_outside_the_refusal_list(self):
        files = [(p, _read(p)) for p in _swift_files(IOS_DIR) + _swift_files(KIT_DIR)]
        self.assertGreater(len(files), 10, "the scan must not pass over an empty tree")
        self.assertEqual(queue_verb_violations(files), [])

    def test_the_transport_refuses_all_three_queue_verbs(self):
        # The transport is an allow-list, so a verb is refused by not being on it.
        allowed = swift_allowed_types(_read(WS_CLIENT))
        self.assertGreater(len(allowed), 5, "the allow-list must have been found")
        for verb in ("session_queue_watch", "session_queue_take_back", "session_queue_remove"):
            self.assertNotIn(verb, allowed)

    def test_bites_on_a_sender(self):
        bad = [("iOS/Nostromo/X.swift", 'let type_ = "session_queue_watch"')]
        self.assertEqual(len(queue_verb_violations(bad)), 1)
        bad = [("Shared/NostromoKit/Sources/ClientMsg.swift", "struct ClientSessionQueueWatch: Encodable {}")]
        self.assertEqual(len(queue_verb_violations(bad)), 1)

    def test_a_comment_or_the_refusal_list_is_not_a_violation(self):
        self.assertEqual(queue_verb_violations([("X.swift", "// never send session_queue_watch")]), [])
        self.assertEqual(
            queue_verb_violations([("Transport/WebSocketClient.swift", '"session_queue_watch",')]), [])


class OutboundAllowListTests(unittest.TestCase):
    def test_the_phone_allow_list_equals_the_daemons_network_allowed(self):
        self.assertEqual(allow_list_violations(_read(PEER_RS), _read(WS_CLIENT)), [])

    def test_the_paired_device_set_is_exactly_the_four_push_verbs(self):
        self.assertEqual(paired_device_violations(_read(PEER_RS), _read(WS_CLIENT)), [])
        self.assertEqual(swift_paired_device_types(_read(WS_CLIENT)), PUSH_VERBS)

    def test_paired_device_bites_on_a_fifth_verb_a_missing_verb_and_presence(self):
        rust = 'const NETWORK_ALLOWED: &[&str] = &["Hello"];'

        def swift(paired, allowed='"hello"'):
            return ('static let allowedTypes: Set<String> = [%s]\n'
                    'static let pairedDeviceTypes: Set<String> = [%s]' % (allowed, paired))
        four = '"register_push", "set_push_prefs", "push_sent_log", "push_waiting"'
        self.assertEqual(paired_device_violations(rust, swift(four)), [])
        self.assertEqual(len(paired_device_violations(rust, swift(four + ', "mother_action"'))), 1)
        self.assertEqual(len(paired_device_violations(rust, swift('"register_push", "set_push_prefs", "push_waiting"'))), 1)
        self.assertEqual(len(paired_device_violations(rust, swift(four + ', "operator_presence"'))), 2)
        self.assertEqual(len(paired_device_violations(rust, swift(four, '"hello", "push_waiting"'))), 1)
        self.assertEqual(len(paired_device_violations(
            'const NETWORK_ALLOWED: &[&str] = &["Hello", "PushWaiting"];', swift(four))), 1)
        self.assertEqual(len(paired_device_violations(rust, "// gone")), 1)

    def test_the_rust_list_is_found_and_converted_to_wire_names(self):
        rust = rust_network_allowed(_read(PEER_RS))
        self.assertIn("session_list", rust)
        self.assertIn("activity_snapshot_request", rust)
        self.assertNotIn("perri_action", rust)

    def test_no_denied_verb_is_on_the_phone_list(self):
        allowed = swift_allowed_types(_read(WS_CLIENT))
        for verb in ("perri_action", "session_send", "session_interrupt", "close_pane",
                     "session_model_set", "approval_answer", "decision_answer", "mother_action"):
            self.assertNotIn(verb, allowed)

    def test_bites_when_the_phone_lists_a_verb_the_daemon_refuses(self):
        rust = 'const NETWORK_ALLOWED: &[&str] = &[\n"Hello",\n"SessionList",\n];'
        swift = 'static let allowedTypes: Set<String> = [\n"hello",\n"session_list",\n"perri_action",\n]'
        self.assertEqual(len(allow_list_violations(rust, swift)), 1)

    def test_bites_when_the_daemon_allows_a_verb_the_phone_forgot(self):
        rust = 'const NETWORK_ALLOWED: &[&str] = &[\n"Hello",\n"SessionList",\n"PtyList",\n];'
        swift = 'static let allowedTypes: Set<String> = [\n"hello",\n"session_list",\n]'
        self.assertEqual(len(allow_list_violations(rust, swift)), 1)

    def test_bites_when_either_list_is_missing(self):
        self.assertTrue(allow_list_violations("", 'static let allowedTypes: Set<String> = ["hello"]'))
        self.assertTrue(allow_list_violations('const NETWORK_ALLOWED: &[&str] = &["Hello"];', "// gone"))

    def test_a_commented_out_verb_does_not_count(self):
        rust = 'const NETWORK_ALLOWED: &[&str] = &["Hello"];'
        swift = 'static let allowedTypes: Set<String> = [\n"hello",\n// "perri_action",\n]'
        self.assertEqual(allow_list_violations(rust, swift), [])


class AppTransportSecurityPolicyTests(unittest.TestCase):
    PLIST = (b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
             b'<key>NSAppTransportSecurity</key><dict>%s</dict></dict></plist>')

    def test_the_real_info_plist_allows_local_networking_and_no_arbitrary_loads(self):
        with open(INFO_PLIST, "rb") as f:
            self.assertEqual(ats_violations(f.read()), [])

    def test_bites_when_local_networking_is_removed_or_false(self):
        self.assertTrue(ats_violations(self.PLIST % b""))
        self.assertTrue(ats_violations(self.PLIST % b"<key>NSAllowsLocalNetworking</key><false/>"))
        self.assertTrue(ats_violations(b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'))

    def test_bites_on_arbitrary_loads_even_with_local_networking(self):
        ok = b"<key>NSAllowsLocalNetworking</key><true/>"
        self.assertEqual(ats_violations(self.PLIST % ok), [])
        self.assertTrue(ats_violations(self.PLIST % (ok + b"<key>NSAllowsArbitraryLoads</key><true/>")))
        self.assertTrue(ats_violations(self.PLIST % (ok + b"<key>NSAllowsArbitraryLoadsInWebContent</key><true/>")))
        self.assertEqual(ats_violations(self.PLIST % (ok + b"<key>NSAllowsArbitraryLoads</key><false/>")), [])

    def test_bites_on_an_exception_domains_entry(self):
        ok = b"<key>NSAllowsLocalNetworking</key><true/>"
        self.assertTrue(ats_violations(self.PLIST % (ok + b"<key>NSExceptionDomains</key><dict/>")))

    def test_no_ats_build_setting_overrides_the_plist(self):
        # An INFOPLIST_KEY_ build setting would be merged into the built plist behind its back.
        with open(os.path.join(REPO_ROOT, "iOS", "Nostromo.xcodeproj", "project.pbxproj"), encoding="utf-8") as f:
            self.assertNotRegex(f.read(), r"INFOPLIST_KEY_NSAppTransportSecurity|NSAllowsArbitraryLoads")


class LegacyPathPolicyTests(unittest.TestCase):
    def _views(self):
        base = os.path.join(IOS_DIR, "Views", "Pairing")
        return _read(os.path.join(base, "PairWithNostromoView.swift")), _read(os.path.join(base, "PairingFlowView.swift"))

    def test_the_start_screen_reaches_the_legacy_transport(self):
        self.assertEqual(legacy_path_violations(*self._views()), [])

    def test_bites_without_the_control_or_the_switch(self):
        start, flow = self._views()
        self.assertTrue(legacy_path_violations(start.replace("Use local network (legacy)", "Other"), flow))
        self.assertTrue(legacy_path_violations(start.replace("onUseLegacy", "onNothing"), flow))
        self.assertTrue(legacy_path_violations(start, flow.replace(".legacyTCP", ".webSocket")))

    def test_the_legacy_toggle_is_still_in_settings(self):
        self.assertIn("setTransport(on ? .legacyTCP : .webSocket)",
                      _read(os.path.join(IOS_DIR, "Views", "DeviceSettingsView.swift")))


class MutatingControlGatingPolicyTests(unittest.TestCase):
    PATHS = ("Views/TranscriptView.swift", "Views/PerriView.swift", "Views/Panes/PaneSurfaceView.swift", "NostromoApp.swift")

    def _files(self):
        return {p: _read(os.path.join(IOS_DIR, p)) for p in self.PATHS}

    def test_every_state_changing_control_is_behind_can_mutate(self):
        self.assertEqual(gating_violations(self._files()), [])

    def test_bites_when_a_gate_is_removed(self):
        files = self._files()
        cases = (
            ("Views/TranscriptView.swift", "if store.canMutate {\n                    InputBar(", "if true {\n                    InputBar("),
            ("Views/TranscriptView.swift", "canAnswer: store.canMutate", "canAnswer: true"),
            ("Views/PerriView.swift", "if store.canMutate {\n                                Button {", "if true {\n                                Button {"),
            ("Views/PerriView.swift", "actionsEnabled: store.canMutate", "actionsEnabled: true"),
            ("Views/Panes/PaneSurfaceView.swift", "if store.canMutate {\n                                        Button {", "if true {\n                                        Button {"),
            ("NostromoApp.swift", "{ !store.canMutate }", "{ false }"),
        )
        for path, old, new in cases:
            self.assertIn(old, files[path], "%s: the pattern to mutate must exist" % path)
            mutated = dict(files)
            mutated[path] = files[path].replace(old, new, 1)
            self.assertTrue(gating_violations(mutated), "%s: %r -> %r must be caught" % (path, old, new))


class ConfirmationScreenPolicyTests(unittest.TestCase):
    def test_the_confirmation_shows_address_port_and_code(self):
        source = _read(os.path.join(IOS_DIR, "Views", "Pairing", "ConfirmPairingView.swift"))
        self.assertEqual(confirmation_violations(source), [])

    def test_bites_when_one_is_dropped(self):
        source = _read(os.path.join(IOS_DIR, "Views", "Pairing", "ConfirmPairingView.swift"))
        for needle in ("confirmation.port", "confirmation.code"):
            self.assertTrue(confirmation_violations(source.replace(needle, "x")), needle)


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
