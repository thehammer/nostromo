"""Source policy for iOS push enrichment (W16): five scans over the Notification Service Extension.

The extension (`iOS/NostromoNotificationService/`) runs for every alert push, before the notification
is shown, even after the app was force-quit. What it may do is small and checkable as text:

1. W16-3 (no answering verbs). No Swift file the extension is built from (`iOS/NostromoNotificationService/**`,
   Kit's `Push/**` and Kit's `Transport/WebSocketPushDetailTransport.swift`) names a verb that answers
   something on a Mac: `DecisionAnswer`, `ApprovalAnswer`, `MotherResume`, `MotherAction` or their wire
   spellings. The phone only reads. Comments are stripped first (a comment may say "never send ...").
2. The extension's `Info.plist` is a usernotifications service extension (`NSExtensionPointIdentifier`,
   a principal class ending `.NotificationService`) and allows local networking for App Transport
   Security and never arbitrary loads (the same rule as the app's plist).
3. Entitlements. The app and the extension both list the App Group `group.com.hammer.nostromo.ios` and the
   same Keychain access group (the extension reads the device token from the shared Keychain item); the
   extension holds NO `com.apple.developer.usernotifications.filtering` key (the capability that would let
   it hide a notification, which Apple must grant and which is not requested) and no `aps-environment`;
   and Kit's `SharedPushState.defaultAppGroup` is that same group.
4. `project.pbxproj` and the shared scheme. The extension is a native `app-extension` target, embedded in
   the app by an `Embed Foundation Extensions` copy phase (`dstSubfolderSpec = 13`) that the app target
   runs, the app depends on it, it links the NostromoKit package product, the shared scheme builds it,
   and no build configuration is named `Filtering`.
5. The extension source never logs: no `print(`, `NSLog(`, `os_log(`, `Logger(` (notification text is a
   repository's own words and must not reach a log).

Each check is a plain function over `(path, source)` pairs (or the file's bytes) returning violations
(empty == pass), with a companion "bites" test on synthetic input proving it can fail. This suite must
never report a skip.

Run with:
    python3 -I -m unittest discover -s tests/ios_policy -v
"""

import ast
import os
import plistlib
import re
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
IOS_ROOT = os.path.join(REPO_ROOT, "iOS")
EXT_DIR = os.path.join(IOS_ROOT, "NostromoNotificationService")
EXT_SOURCE = os.path.join(EXT_DIR, "NotificationService.swift")
EXT_PLIST = os.path.join(EXT_DIR, "Info.plist")
EXT_ENTITLEMENTS = os.path.join(EXT_DIR, "NostromoNotificationService.entitlements")
APP_ENTITLEMENTS = os.path.join(IOS_ROOT, "Nostromo", "Nostromo.entitlements")
PROJECT = os.path.join(IOS_ROOT, "Nostromo.xcodeproj", "project.pbxproj")
SCHEME = os.path.join(IOS_ROOT, "Nostromo.xcodeproj", "xcshareddata", "xcschemes", "Nostromo.xcscheme")
KIT_SOURCES = os.path.join(REPO_ROOT, "Shared", "NostromoKit", "Sources", "NostromoKit")
KIT_PUSH_DIR = os.path.join(KIT_SOURCES, "Push")
KIT_DETAIL_TRANSPORT = os.path.join(KIT_SOURCES, "Transport", "WebSocketPushDetailTransport.swift")
KIT_SHARED_STATE = os.path.join(KIT_PUSH_DIR, "SharedPushState.swift")

APP_GROUP = "group.com.hammer.nostromo.ios"
EXT_TARGET = "NostromoNotificationService"
APP_TARGET = "Nostromo"
EXT_POINT = "com.apple.usernotifications.service"
EMBED_PHASE = "Embed Foundation Extensions"

# The verbs that answer something on a Mac, in both spellings (`DecisionAnswer`, `decision_answer`).
ANSWER_VERBS = re.compile(r"decision_?answer|approval_?answer|mother_?resume|mother_?action", re.IGNORECASE)
# What logs: a call to any of these. A leading `.` or word character means it is some other name.
LOG_CALLS = re.compile(r"(?<![A-Za-z0-9_.])(?:print|debugPrint|dump|NSLog|os_log|Logger)\s*\(")


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def _swift_files(root):
    out = []
    for dirpath, _dirs, names in os.walk(root):
        out.extend(os.path.join(dirpath, n) for n in names if n.endswith(".swift"))
    return sorted(out)


def _strip_comments(source):
    """`source` without `//` and (nested) `/* */` comments. String literals are kept whole, so a
    verb inside a string (a wire `type`) is still seen, and a `//` inside a string is not a comment."""
    out = []
    i, n = 0, len(source)
    while i < n:
        if source.startswith('"""', i):
            end = source.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append(source[i:end])
            i = end
        elif source[i] == '"':
            j = i + 1
            while j < n and source[j] not in '"\n':
                j += 2 if source[j] == "\\" else 1
            out.append(source[i:j + 1])
            i = j + 1
        elif source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end < 0 else end
        elif source.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if source.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif source.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    out.append("\n" if source[j] == "\n" else "")
                    j += 1
            i = j
        else:
            out.append(source[i])
            i += 1
    return "".join(out)


def _extension_swift_files():
    """Everything the extension is built from: its own sources, Kit's Push/**, and the detail transport."""
    return _swift_files(EXT_DIR) + _swift_files(KIT_PUSH_DIR) + [KIT_DETAIL_TRANSPORT]


# --------------------------------------------------------------------------
# Check 1: no answering verbs (W16-3)
# --------------------------------------------------------------------------

def answer_verb_violations(files):
    """An answering verb named anywhere in code (comments ignored)."""
    out = []
    for path, source in files:
        for m in ANSWER_VERBS.finditer(_strip_comments(source)):
            out.append((path, m.group(0)))
    return out


# --------------------------------------------------------------------------
# Check 2: the extension's Info.plist
# --------------------------------------------------------------------------

def ats_violations(plist_bytes):
    """App Transport Security: local networking on, arbitrary loads never on.
    (Copied from test_ios_backplane_policy.py: each policy dir runs under `discover -s`, so the
    sibling module is not reliably importable.)"""
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


def extension_plist_violations(plist_bytes):
    """A usernotifications service extension whose principal class is `NotificationService`, with ATS
    as for the app."""
    info = plistlib.loads(plist_bytes)
    ext = info.get("NSExtension")
    out = []
    if not isinstance(ext, dict):
        out.append("Info.plist has no NSExtension dictionary")
    else:
        point = ext.get("NSExtensionPointIdentifier")
        if point != EXT_POINT:
            out.append("NSExtensionPointIdentifier is %r, not %r" % (point, EXT_POINT))
        principal = ext.get("NSExtensionPrincipalClass")
        if not isinstance(principal, str) or not principal.endswith(".NotificationService"):
            out.append("NSExtensionPrincipalClass is %r, not <module>.NotificationService" % (principal,))
        if "NSExtensionMainStoryboard" in ext:
            out.append("a service extension has no storyboard")
    return out + ats_violations(plist_bytes)


# --------------------------------------------------------------------------
# Check 3: entitlements
# --------------------------------------------------------------------------

FILTERING_PREFIX = "com.apple.developer.usernotifications.filtering"


def _entitlement_list(info, key):
    value = info.get(key)
    return list(value) if isinstance(value, list) else []


def kit_app_group(kit_source):
    """The literal in `static let defaultAppGroup = "..."` (comments ignored), or None."""
    m = re.search(r'static let defaultAppGroup\s*=\s*"([^"]*)"', _strip_comments(kit_source))
    return m.group(1) if m else None


def entitlement_violations(app_bytes, ext_bytes, kit_source):
    app, ext = plistlib.loads(app_bytes), plistlib.loads(ext_bytes)
    out = []
    for label, info in (("the app", app), ("the extension", ext)):
        if APP_GROUP not in _entitlement_list(info, "com.apple.security.application-groups"):
            out.append("%s does not list the App Group %s" % (label, APP_GROUP))
    app_keychain = _entitlement_list(app, "keychain-access-groups")
    ext_keychain = _entitlement_list(ext, "keychain-access-groups")
    if not app_keychain:
        out.append("the app lists no keychain-access-groups")
    if not ext_keychain:
        out.append("the extension lists no keychain-access-groups")
    if app_keychain and ext_keychain and sorted(app_keychain) != sorted(ext_keychain):
        out.append("the keychain access groups differ: app %r, extension %r" % (app_keychain, ext_keychain))
    for key in sorted(ext):
        if key.startswith(FILTERING_PREFIX):
            out.append("the extension holds %s: it must not be able to hide a notification" % key)
    if "aps-environment" in ext:
        out.append("the extension holds aps-environment: only the app registers for pushes")
    literal = kit_app_group(kit_source)
    if literal is None:
        out.append("SharedPushState.defaultAppGroup was not found")
    elif literal != APP_GROUP:
        out.append("SharedPushState.defaultAppGroup is %r, not %r" % (literal, APP_GROUP))
    return out


# --------------------------------------------------------------------------
# Check 4: project.pbxproj and the shared scheme
# --------------------------------------------------------------------------

_OBJECT_START = re.compile(r"^\t\t([A-Z0-9]{24})(?: /\*.*?\*/)? = \{", re.M)
_ID = re.compile(r"\b([A-Z0-9]{24})\b")


def pbx_objects(text):
    """Every object of the project (id -> body between its braces), by brace matching."""
    objects = {}
    for m in _OBJECT_START.finditer(text):
        i, depth = m.end(), 1
        while depth and i < len(text):
            c = text[i]
            if c == '"':
                i += 1
                while i < len(text) and text[i] != '"':
                    i += 2 if text[i] == "\\" else 1
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            i += 1
        objects[m.group(1)] = text[m.end():i - 1]
    return objects


def pbx_scalar(body, key):
    m = re.search(r'(?<![A-Za-z])%s = (?:"((?:[^"\\]|\\.)*)"|([^;\s]+))(?:\s*/\*.*?\*/)?\s*;' % re.escape(key), body)
    if not m:
        return None
    return m.group(1) if m.group(1) is not None else m.group(2)


def pbx_ids(body, key):
    m = re.search(r"(?<![A-Za-z])%s = \(\s*(.*?)\s*\);" % re.escape(key), body, re.S)
    return _ID.findall(m.group(1)) if m else []


def _find(objects, isa, **fields):
    """The (id, body) of the objects of type `isa` whose scalar fields equal `fields`."""
    found = []
    for oid, body in objects.items():
        if pbx_scalar(body, "isa") == isa and all(pbx_scalar(body, k) == v for k, v in fields.items()):
            found.append((oid, body))
    return found


def project_violations(text):
    objects = pbx_objects(text)
    exts = _find(objects, "PBXNativeTarget", name=EXT_TARGET)
    apps = _find(objects, "PBXNativeTarget", name=APP_TARGET)
    if len(exts) != 1:
        return ["expected one native target named %s, found %d" % (EXT_TARGET, len(exts))]
    if len(apps) != 1:
        return ["expected one native target named %s, found %d" % (APP_TARGET, len(apps))]
    (ext_id, ext), (_app_id, app) = exts[0], apps[0]
    out = []

    if pbx_scalar(ext, "productType") != "com.apple.product-type.app-extension":
        out.append("%s is not an app-extension target (productType %r)" % (EXT_TARGET, pbx_scalar(ext, "productType")))
    if pbx_scalar(app, "productType") != "com.apple.product-type.application":
        out.append("%s is not an application target" % APP_TARGET)

    # The embed phase: named, destination Plug-Ins/Foundation Extensions (13), run by the app, carrying the .appex.
    phases = _find(objects, "PBXCopyFilesBuildPhase", name='"%s"' % EMBED_PHASE) \
        or _find(objects, "PBXCopyFilesBuildPhase", name=EMBED_PHASE)
    if len(phases) != 1:
        out.append("expected one %r copy phase, found %d" % (EMBED_PHASE, len(phases)))
    else:
        phase_id, phase = phases[0]
        if pbx_scalar(phase, "dstSubfolderSpec") != "13":
            out.append("%r has dstSubfolderSpec %r, not 13" % (EMBED_PHASE, pbx_scalar(phase, "dstSubfolderSpec")))
        if phase_id not in pbx_ids(app, "buildPhases"):
            out.append("the %s target does not run the %r phase" % (APP_TARGET, EMBED_PHASE))
        product = pbx_scalar(ext, "productReference")
        embedded = [pbx_scalar(objects.get(f, ""), "fileRef") for f in pbx_ids(phase, "files")]
        if product is None or product not in embedded:
            out.append("%r does not embed %s's product" % (EMBED_PHASE, EXT_TARGET))

    # The app depends on the extension, so building the app builds and embeds it.
    depends_on = [pbx_scalar(objects.get(d, ""), "target") for d in pbx_ids(app, "dependencies")]
    if ext_id not in depends_on:
        out.append("the %s target has no PBXTargetDependency on %s" % (APP_TARGET, EXT_TARGET))

    # The extension links Kit.
    products = [oid for oid, body in objects.items()
                if pbx_scalar(body, "isa") == "XCSwiftPackageProductDependency"
                and pbx_scalar(body, "productName") == "NostromoKit"]
    ext_products = [p for p in pbx_ids(ext, "packageProductDependencies") if p in products]
    if not ext_products:
        out.append("%s does not list the NostromoKit package product" % EXT_TARGET)
    else:
        frameworks = [objects.get(p, "") for p in pbx_ids(ext, "buildPhases")]
        linked = []
        for phase in frameworks:
            if pbx_scalar(phase, "isa") == "PBXFrameworksBuildPhase":
                linked += [pbx_scalar(objects.get(f, ""), "productRef") for f in pbx_ids(phase, "files")]
        if not set(ext_products) & set(linked):
            out.append("%s's Frameworks phase does not link NostromoKit" % EXT_TARGET)

    # The extension compiles NotificationService.swift.
    compiled = []
    for p in pbx_ids(ext, "buildPhases"):
        phase = objects.get(p, "")
        if pbx_scalar(phase, "isa") == "PBXSourcesBuildPhase":
            for f in pbx_ids(phase, "files"):
                ref = objects.get(pbx_scalar(objects.get(f, ""), "fileRef") or "", "")
                compiled.append(pbx_scalar(ref, "path"))
    if "NotificationService.swift" not in compiled:
        out.append("%s does not compile NotificationService.swift" % EXT_TARGET)

    # No configuration that could carry the filtering capability.
    for oid, body in _find(objects, "XCBuildConfiguration"):
        name = pbx_scalar(body, "name")
        if name and name.lower() == "filtering":
            out.append("build configuration %s is named Filtering" % oid)
    return out


def project_ext_id(text):
    exts = _find(pbx_objects(text), "PBXNativeTarget", name=EXT_TARGET)
    return exts[0][0] if exts else None


def scheme_violations(scheme_text, ext_id):
    """The shared scheme builds the extension: a BuildableReference with the target's identifier."""
    if not ext_id:
        return ["the extension target was not found, so the scheme cannot be checked"]
    all_refs = [dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', m.group(1)))
                for m in re.finditer(r"<BuildableReference\b(.*?)>", scheme_text, re.S)]
    refs = [r for r in all_refs if r.get("BlueprintIdentifier") == ext_id]
    if not refs:
        return ["the scheme does not build the extension (no BlueprintIdentifier %s)" % ext_id]
    out = []
    if not any(r.get("BlueprintName") == EXT_TARGET for r in refs):
        out.append("the scheme names the extension's identifier under a different BlueprintName")
    if not any(r.get("BuildableName") == EXT_TARGET + ".appex" for r in refs):
        out.append("the scheme's BuildableName for the extension is not %s.appex" % EXT_TARGET)
    return out


# --------------------------------------------------------------------------
# Check 5: nothing logs
# --------------------------------------------------------------------------

def logging_violations(files):
    """A call that logs (comments ignored)."""
    out = []
    for path, source in files:
        for m in LOG_CALLS.finditer(_strip_comments(source)):
            out.append((path, m.group(0)))
    return out


# --------------------------------------------------------------------------
# Tests
# --------------------------------------------------------------------------

class AnswerVerbPolicyTests(unittest.TestCase):
    def test_no_extension_or_push_kit_source_names_an_answering_verb(self):
        paths = _extension_swift_files()
        names = {os.path.basename(p) for p in paths}
        # Non-vacuous: the scan really covers the extension and the files it is built from.
        for expected in ("NotificationService.swift", "NotificationEnricher.swift", "PushDetailWire.swift",
                         "NotificationContentComposer.swift", "WebSocketPushDetailTransport.swift"):
            self.assertIn(expected, names)
        self.assertEqual(answer_verb_violations([(p, _read(p)) for p in paths]), [])

    def test_bites_on_each_verb_in_each_spelling(self):
        for verb in ("DecisionAnswer", "decision_answer", "ApprovalAnswer", "approval_answer",
                     "MotherResume", "mother_resume", "MotherAction", "mother_action"):
            for source in ('let type_ = "%s"' % verb, "struct Client%s: Encodable {}" % verb):
                found = answer_verb_violations([("iOS/NostromoNotificationService/X.swift", source)])
                self.assertEqual(len(found), 1, source)

    def test_bites_on_a_camel_case_variable_too(self):
        self.assertEqual(len(answer_verb_violations([("X.swift", "let decisionAnswer = 1")])), 1)

    def test_a_comment_is_not_a_violation_but_a_string_is(self):
        self.assertEqual(answer_verb_violations([("X.swift", "// never send decision_answer")]), [])
        self.assertEqual(answer_verb_violations([("X.swift", "/* no MotherAction here\n or approval_answer */")]), [])
        self.assertEqual(answer_verb_violations([("X.swift", '/* a /* nested */ MotherResume */ let x = 1')]), [])
        self.assertEqual(len(answer_verb_violations([("X.swift", 'let s = "// decision_answer"')])), 1)
        self.assertEqual(len(answer_verb_violations([("X.swift", "/* ok */ let t = mother_action")])), 1)


class ExtensionInfoPlistPolicyTests(unittest.TestCase):
    PLIST = (b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
             b'<key>NSExtension</key><dict>%s</dict>'
             b'<key>NSAppTransportSecurity</key><dict>%s</dict></dict></plist>')
    GOOD_EXT = (b"<key>NSExtensionPointIdentifier</key><string>com.apple.usernotifications.service</string>"
                b"<key>NSExtensionPrincipalClass</key><string>$(PRODUCT_MODULE_NAME).NotificationService</string>")
    GOOD_ATS = b"<key>NSAllowsLocalNetworking</key><true/>"

    def _plist(self, ext=None, ats=None):
        return self.PLIST % (self.GOOD_EXT if ext is None else ext, self.GOOD_ATS if ats is None else ats)

    def test_the_real_extension_plist_is_a_notification_service_with_local_networking_only(self):
        self.assertEqual(extension_plist_violations(_read_bytes(EXT_PLIST)), [])

    def test_the_principal_class_is_defined_in_the_extension_source(self):
        code = _strip_comments(_read(EXT_SOURCE))
        self.assertRegex(code, r"class NotificationService\s*:\s*UNNotificationServiceExtension")

    def test_the_synthetic_good_plist_passes(self):
        self.assertEqual(extension_plist_violations(self._plist()), [])

    def test_bites_on_the_wrong_extension_point(self):
        ext = (b"<key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>"
               b"<key>NSExtensionPrincipalClass</key><string>X.NotificationService</string>")
        self.assertTrue(extension_plist_violations(self._plist(ext=ext)))

    def test_bites_on_a_missing_or_wrong_principal_class(self):
        point = b"<key>NSExtensionPointIdentifier</key><string>com.apple.usernotifications.service</string>"
        self.assertTrue(extension_plist_violations(self._plist(ext=point)))
        other = point + b"<key>NSExtensionPrincipalClass</key><string>X.SomethingElse</string>"
        self.assertTrue(extension_plist_violations(self._plist(ext=other)))

    def test_bites_without_an_nsextension_dictionary(self):
        bare = (b'<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                b"<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict></dict></plist>")
        self.assertTrue(extension_plist_violations(bare))

    def test_bites_when_local_networking_is_missing_or_arbitrary_loads_is_on(self):
        self.assertTrue(extension_plist_violations(self._plist(ats=b"")))
        self.assertTrue(extension_plist_violations(self._plist(ats=b"<key>NSAllowsLocalNetworking</key><false/>")))
        loads = self.GOOD_ATS + b"<key>NSAllowsArbitraryLoads</key><true/>"
        self.assertTrue(extension_plist_violations(self._plist(ats=loads)))
        domains = self.GOOD_ATS + b"<key>NSExceptionDomains</key><dict/>"
        self.assertTrue(extension_plist_violations(self._plist(ats=domains)))


class EntitlementsPolicyTests(unittest.TestCase):
    KIT = 'public struct SharedPushState {\n    public static let defaultAppGroup = "%s"\n}' % APP_GROUP

    @staticmethod
    def _entitlements(groups=(APP_GROUP,), keychain=("$(AppIdentifierPrefix)com.hammer.nostromo.ios",), extra=None):
        info = {"com.apple.security.application-groups": list(groups),
                "keychain-access-groups": list(keychain)}
        info.update(extra or {})
        return plistlib.dumps(info)

    def test_the_real_entitlements_share_the_group_and_the_extension_cannot_filter(self):
        found = entitlement_violations(_read_bytes(APP_ENTITLEMENTS), _read_bytes(EXT_ENTITLEMENTS),
                                       _read(KIT_SHARED_STATE))
        self.assertEqual(found, [])

    def test_the_kit_literal_is_read_from_the_real_source(self):
        self.assertEqual(kit_app_group(_read(KIT_SHARED_STATE)), APP_GROUP)

    def test_the_synthetic_good_pair_passes(self):
        self.assertEqual(entitlement_violations(self._entitlements(), self._entitlements(), self.KIT), [])

    def test_bites_when_either_side_drops_the_group(self):
        no_group = self._entitlements(groups=())
        self.assertTrue(entitlement_violations(no_group, self._entitlements(), self.KIT))
        self.assertTrue(entitlement_violations(self._entitlements(), no_group, self.KIT))
        other = self._entitlements(groups=("group.com.example.other",))
        self.assertTrue(entitlement_violations(self._entitlements(), other, self.KIT))

    def test_bites_when_the_keychain_groups_differ_or_are_missing(self):
        other = self._entitlements(keychain=("$(AppIdentifierPrefix)com.example.other",))
        self.assertTrue(entitlement_violations(self._entitlements(), other, self.KIT))
        self.assertTrue(entitlement_violations(self._entitlements(), self._entitlements(keychain=()), self.KIT))
        self.assertTrue(entitlement_violations(self._entitlements(keychain=()), self._entitlements(), self.KIT))

    def test_bites_when_the_extension_holds_the_filtering_entitlement(self):
        filtering = self._entitlements(extra={FILTERING_PREFIX: True})
        self.assertEqual(len(entitlement_violations(self._entitlements(), filtering, self.KIT)), 1)
        # The app is not the extension: only the extension is barred from it.
        self.assertEqual(entitlement_violations(filtering, self._entitlements(), self.KIT), [])

    def test_bites_when_the_extension_holds_aps_environment(self):
        aps = self._entitlements(extra={"aps-environment": "development"})
        self.assertEqual(len(entitlement_violations(self._entitlements(), aps, self.KIT)), 1)
        self.assertEqual(entitlement_violations(aps, self._entitlements(), self.KIT), [])

    def test_bites_when_the_kit_literal_is_another_group_or_missing(self):
        wrong = self.KIT.replace(APP_GROUP, "group.com.example.other")
        self.assertEqual(len(entitlement_violations(self._entitlements(), self._entitlements(), wrong)), 1)
        self.assertEqual(len(entitlement_violations(self._entitlements(), self._entitlements(), "// gone")), 1)
        commented = "// static let defaultAppGroup = \"%s\"" % APP_GROUP
        self.assertEqual(len(entitlement_violations(self._entitlements(), self._entitlements(), commented)), 1)


class ProjectPolicyTests(unittest.TestCase):
    def setUp(self):
        self.text = _read(PROJECT)

    def _mutated(self, old, new):
        self.assertIn(old, self.text, "the pattern to mutate must exist: %r" % old)
        return self.text.replace(old, new, 1)

    def test_the_real_project_embeds_the_extension_and_has_no_filtering_configuration(self):
        self.assertEqual(project_violations(self.text), [])

    def test_the_parser_finds_the_targets_it_checks(self):
        objects = pbx_objects(self.text)
        self.assertGreater(len(objects), 50, "the scan must not pass over an empty project")
        self.assertEqual(len(_find(objects, "PBXNativeTarget", name=EXT_TARGET)), 1)
        self.assertEqual(len(_find(objects, "PBXNativeTarget", name=APP_TARGET)), 1)

    def test_bites_when_the_extension_is_not_an_app_extension(self):
        text = self._mutated('productType = "com.apple.product-type.app-extension";',
                             'productType = "com.apple.product-type.application";')
        self.assertTrue(project_violations(text))

    def test_bites_when_the_copy_phase_goes_to_the_wrong_place(self):
        text = self._mutated("dstSubfolderSpec = 13;", "dstSubfolderSpec = 10;")
        self.assertTrue(project_violations(text))

    def test_bites_when_the_app_no_longer_runs_the_embed_phase(self):
        text = self._mutated("BP1600000000000000000010 /* Embed Foundation Extensions */,\n", "")
        self.assertTrue(project_violations(text))

    def test_bites_when_the_embed_phase_no_longer_carries_the_appex(self):
        text = self._mutated("BP1600000000000000000006 /* NostromoNotificationService.appex in Embed Foundation Extensions */,\n", "")
        self.assertTrue(project_violations(text))

    def test_bites_when_the_app_no_longer_depends_on_the_extension(self):
        text = self._mutated("BP1600000000000000000012 /* PBXTargetDependency */,\n", "")
        self.assertTrue(project_violations(text))

    def test_bites_when_the_extension_no_longer_lists_the_kit_product(self):
        text = self._mutated("BP160000000000000000000B /* NostromoKit */,\n", "")
        self.assertTrue(project_violations(text))

    def test_bites_when_the_extension_no_longer_links_the_kit_product(self):
        text = self._mutated("BP160000000000000000000A /* NostromoKit in Frameworks */,\n", "")
        self.assertTrue(project_violations(text))

    def test_bites_when_the_extension_stops_compiling_its_source(self):
        text = self._mutated("BP1600000000000000000002 /* NotificationService.swift in Sources */,\n", "")
        self.assertTrue(project_violations(text))

    def test_bites_on_a_configuration_named_filtering(self):
        # Rename the extension's Release configuration: its `name = Release;` follows its settings block.
        start = self.text.index("BP160000000000000000000F /* Release */")
        end = self.text.index("name = Release;", start)
        renamed = self.text[:end] + "name = Filtering;" + self.text[end + len("name = Release;"):]
        found = project_violations(renamed)
        self.assertEqual(len(found), 1, found)
        self.assertIn("Filtering", found[0])

    def test_an_empty_project_is_not_a_pass(self):
        self.assertTrue(project_violations(""))


class SchemePolicyTests(unittest.TestCase):
    def setUp(self):
        self.scheme = _read(SCHEME)
        self.ext_id = project_ext_id(_read(PROJECT))

    def test_the_shared_scheme_builds_the_extension(self):
        self.assertIsNotNone(self.ext_id)
        self.assertEqual(scheme_violations(self.scheme, self.ext_id), [])

    def test_bites_when_the_extension_is_dropped_from_the_scheme(self):
        self.assertIn(self.ext_id, self.scheme)
        self.assertTrue(scheme_violations(self.scheme.replace(self.ext_id, "ZZ0000000000000000000000"), self.ext_id))

    def test_bites_when_the_scheme_names_the_wrong_product(self):
        mutated = self.scheme.replace("NostromoNotificationService.appex", "Other.appex")
        self.assertNotEqual(mutated, self.scheme)
        self.assertTrue(scheme_violations(mutated, self.ext_id))

    def test_bites_when_the_target_is_missing_from_the_project(self):
        self.assertTrue(scheme_violations(self.scheme, None))


class ExtensionLoggingPolicyTests(unittest.TestCase):
    def test_the_extension_source_never_logs(self):
        self.assertTrue(os.path.exists(EXT_SOURCE))
        paths = _swift_files(EXT_DIR) + [os.path.join(KIT_PUSH_DIR, n) for n in (
            "NotificationEnricher.swift", "NotificationContentComposer.swift", "PushDetailFetcher.swift",
            "PushDetailWire.swift")] + [KIT_DETAIL_TRANSPORT]
        self.assertGreaterEqual(len(paths), 6)
        self.assertEqual(logging_violations([(p, _read(p)) for p in paths]), [])

    def test_bites_on_each_way_to_log(self):
        for source in ('print("x")', 'print (body)', 'NSLog("%@", body)', 'os_log("x")',
                       'let log = Logger(subsystem: "a", category: "b")', 'debugPrint(body)', 'dump(content)'):
            self.assertEqual(len(logging_violations([("NotificationService.swift", source)])), 1, source)

    def test_a_comment_or_a_longer_name_is_not_logging(self):
        for source in ("// print(body) would leak", "/* NSLog(body) */", "let blueprint = 1; blueprint(1)",
                       "reprint(x)", "model.print(x)"):
            self.assertEqual(logging_violations([("X.swift", source)]), [], source)


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
