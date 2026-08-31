"""Source-scanning policy tests over the iOS Swift view tree.

These exist because iOS has no compiler-enforced guardrail for the things
that matter most about how it renders agent-authored content, and its recent
history is three reactive switch-exhaustiveness fixes with comments
explaining why the case is a stub — a target maintained by the compiler
complaining, one incident at a time. Adding real renderers on top of that
regime (W4, W5, W7, W8, W9) produces renderers that break silently on the
next wire change. This suite is the L2 layer of the three-layer verification
model described in docs/ios-verification.md — wiring and policy, checked by
scanning `iOS/Nostromo/**/*.swift` as text.

Every check below is a plain function taking a list of `(path, source)`
pairs and returning a list of violations (empty == pass), in the same spirit
as macOS's own source-scanning fitness functions
(macOS/NostromoTests/DecisionStoreTests.swift,
macOS/NostromoTests/TurnInteractionTests.swift) — a textual heuristic, not a
control-flow proof. Regex/brace-counting over Swift source can be fooled by
a sufficiently adversarial rewrite; it is not fooled by the mistakes that
have actually happened here.

Each check has a companion "bites" test, run against a synthetic source
string rather than the real tree — proof the check can actually fail, in the
spirit of tests/transcript_load's UniversalVacuityTests /
VacuityTestActuallyBitesTests pattern. A check with no bites-test is a check
nobody verified can fail, which is the same defect class that pattern exists
to catch one level up.

A policy is added here by the wedge that makes it true. This file covers
exactly the checks W2 (ios-curated-view-parity) makes true; later wedges
(W4/W5/W7/W8/W9) add their own alongside their own feature work.

This suite must never report a skip — the CI job
(.github/workflows/ci.yml, `python-tooling`) greps its output for
`... skipped` / `(skipped=` and fails the build if it finds either, on the
theory that a skipped test is a vacuously passing test. See
SuiteNeverSkipsTests below, which asserts this file contains no skip
mechanism as a second, local guard against the same mistake.

Run with:
    python3 -m unittest discover -s tests/ios_policy -v
"""

import ast
import os
import re
import unittest

REPO_ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
IOS_SRC_ROOT = os.path.join(REPO_ROOT, "iOS", "Nostromo")


# --------------------------------------------------------------------------
# Source-tree access
# --------------------------------------------------------------------------

def _ios_swift_files():
    """Every `.swift` file under iOS/Nostromo, sorted for determinism.

    Scoped to iOS/Nostromo deliberately: Shared/ and macOS/ are out of this
    suite's remit (Shared/NostromoKit is where PaneSurfaceStub's real stub
    strings and the shared wire types live; macOS has its own equivalent
    fitness functions in Swift).
    """
    paths = []
    for dirpath, _dirnames, filenames in os.walk(IOS_SRC_ROOT):
        for name in filenames:
            if name.endswith(".swift"):
                paths.append(os.path.join(dirpath, name))
    return sorted(paths)


def _read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _load_real_tree():
    return [(p, _read(p)) for p in _ios_swift_files()]


# --------------------------------------------------------------------------
# Brace/paren-balancing helpers
# --------------------------------------------------------------------------

def _balanced_span(source, open_index):
    """Given the index of an opening `{` in `source`, return the index just
    past its matching closing `}` (brace depth returns to zero).

    Naive character counting — does not understand string literals or
    comments containing brace characters. Every real call site scanned by
    this suite is ordinary SwiftUI view code with no braces inside string
    literals, so this is an accepted, documented limitation rather than a
    parser.
    """
    if source[open_index] != "{":
        raise ValueError("_balanced_span must be called with the index of a '{'")
    depth = 0
    i = open_index
    while i < len(source):
        c = source[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced braces starting at index %d" % open_index)


def _spans_after(source, needle_pattern):
    """For each regex match of `needle_pattern`, find the next `{` after the
    match and return the balanced-brace span's text (braces included).
    Skips a match with no following `{` at all.
    """
    spans = []
    for m in re.finditer(needle_pattern, source):
        brace_index = source.find("{", m.end())
        if brace_index == -1:
            continue
        end = _balanced_span(source, brace_index)
        spans.append(source[m.start():end])
    return spans


def _balanced_call_args(source, call_open_pattern):
    """For each regex match of `call_open_pattern` (which must end at the
    literal `(` of a call), return the text of the balanced parenthesised
    argument list (parens included).
    """
    calls = []
    for m in re.finditer(call_open_pattern, source):
        open_index = m.end() - 1
        if source[open_index] != "(":
            continue
        depth = 0
        i = open_index
        while i < len(source):
            c = source[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    calls.append(source[open_index:i + 1])
                    break
            i += 1
    return calls


# --------------------------------------------------------------------------
# Checks — each takes a list of (path, source) pairs, returns a list of
# (path, message) violations. Empty == pass.
# --------------------------------------------------------------------------

def check_no_default_in_panecontentwire_switch(files):
    """No `switch` over `PaneContentWire` has a `default:` arm.

    This is the exhaustiveness criterion: a case added to `PaneContentWire`
    later must break the iOS compile, not fall silently into a catch-all.
    """
    violations = []
    for path, source in files:
        if "PaneContentWire" not in source:
            continue
        for span in _spans_after(source, r"switch\s+(?:self\.)?content\b"):
            if re.search(r"\bdefault\s*:", span):
                violations.append((path, "switch over PaneContentWire has a `default:` arm"))
    return violations


def check_every_toRowModel_call_passes_marked(files):
    """No `toRowModel(` call omits `marked:`."""
    violations = []
    for path, source in files:
        for call in _balanced_call_args(source, r"\btoRowModel\("):
            if "marked:" not in call:
                violations.append((path, "toRowModel(...) call omits `marked:`: %s" % call))
    return violations


def check_payload_text_not_referenced(files):
    """`payload.text` appears nowhere — the deleted raw-text `.code` dump."""
    violations = []
    for path, source in files:
        if "payload.text" in source:
            violations.append((path, "`payload.text` referenced — the deleted raw-text code dump"))
    return violations


def check_address_plumbed_into_pane_surface(files):
    """DynamicFocusView passes `address:` into the pane surface, and the
    pane surface accepts an `address` parameter.
    """
    by_name = {os.path.basename(path): source for path, source in files}
    violations = []

    focus_source = by_name.get("DynamicFocusView.swift", "")
    calls = _balanced_call_args(focus_source, r"PaneSurfaceView\(")
    if not calls:
        violations.append(("DynamicFocusView.swift", "no PaneSurfaceView(...) construction found"))
    elif not any("address:" in c for c in calls):
        violations.append(("DynamicFocusView.swift", "PaneSurfaceView(...) construction omits `address:`"))

    surface_source = by_name.get("PaneSurfaceView.swift", "")
    if not re.search(r"\baddress\s*:\s*PaneAddress\??", surface_source):
        violations.append(("PaneSurfaceView.swift", "no `address: PaneAddress?` parameter/property found"))

    return violations


def check_swipe_actions_do_not_reference_address(files):
    """The swipe-to-approve staged value must derive from the iterated item,
    never from the pane's addressing — marking is visual only (D6).
    """
    violations = []
    for path, source in files:
        for span in _spans_after(source, r"\.swipeActions\("):
            if re.search(r"\baddress\b", span) or "marks(" in span:
                violations.append((
                    path,
                    "swipeActions block references `address`/`marks(` — the staged "
                    "approval must derive from the iterated item, not the pane's address"
                ))
    return violations


def check_stub_strings_come_from_PaneSurfaceStub(files):
    """No view file hard-codes the deferred-content stub copy — it must come
    from `PaneSurfaceStub.message(for:)` (NostromoKit), so W7/W8/W9 delete a
    table entry instead of hunting a string in a view.
    """
    violations = []
    for path, source in files:
        if "isn't available on iOS yet" in source:
            violations.append((path, "literal stub text found — must come from PaneSurfaceStub.message(for:)"))
    return violations


CHECKS = (
    check_no_default_in_panecontentwire_switch,
    check_every_toRowModel_call_passes_marked,
    check_payload_text_not_referenced,
    check_address_plumbed_into_pane_surface,
    check_swipe_actions_do_not_reference_address,
    check_stub_strings_come_from_PaneSurfaceStub,
)


# --------------------------------------------------------------------------
# Helper-function tests
# --------------------------------------------------------------------------

class BalancedSpanTests(unittest.TestCase):
    def test_returns_the_matching_close_brace_for_a_flat_span(self):
        source = "switch content { case .a: foo() }"
        open_index = source.index("{")
        end = _balanced_span(source, open_index)
        self.assertEqual(source[open_index:end], "{ case .a: foo() }")

    def test_handles_nested_braces(self):
        source = "{ if x { y() } z() } trailing"
        end = _balanced_span(source, 0)
        self.assertEqual(source[:end], "{ if x { y() } z() }")

    def test_raises_on_unbalanced_input(self):
        with self.assertRaises(ValueError):
            _balanced_span("{ if x { y() }", 0)


class BalancedCallArgsTests(unittest.TestCase):
    def test_captures_nested_parens_in_call_arguments(self):
        # The returned text is the parenthesised argument list (parens
        # included) — not the call name, which the caller's pattern already
        # matched.
        source = "toRowModel(marked: address?.marks(repo: r, number: n) ?? false)"
        calls = _balanced_call_args(source, r"\btoRowModel\(")
        self.assertEqual(calls, ["(marked: address?.marks(repo: r, number: n) ?? false)"])

    def test_captures_an_empty_argument_list(self):
        calls = _balanced_call_args("item.toRowModel()", r"\btoRowModel\(")
        self.assertEqual(calls, ["()"])

    def test_finds_every_call_site_not_just_the_first(self):
        source = "a.toRowModel(marked: true)\nb.toRowModel(marked: false)"
        calls = _balanced_call_args(source, r"\btoRowModel\(")
        self.assertEqual(len(calls), 2)


# --------------------------------------------------------------------------
# Per-check bites tests — each check runs against a synthetic violation
# first (proving it CAN fail) and a synthetic clean input second (proving
# it isn't just always-fail).
# --------------------------------------------------------------------------

class NoDefaultInPaneContentWireSwitchTests(unittest.TestCase):
    def test_bites_on_a_switch_with_a_default_arm(self):
        source = (
            "import NostromoKit\n"
            "struct V: View {\n"
            "    var content: PaneContentWire?\n"
            "    var body: some View {\n"
            "        switch content {\n"
            "        case .text(let t): Text(t)\n"
            "        default: EmptyView()\n"
            "        }\n"
            "    }\n"
            "}\n"
        )
        violations = check_no_default_in_panecontentwire_switch([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_an_exhaustive_switch_with_no_default(self):
        source = (
            "var content: PaneContentWire?\n"
            "switch content {\n"
            "case .text(let t): Text(t)\n"
            "case nil: EmptyView()\n"
            "}\n"
        )
        self.assertEqual(check_no_default_in_panecontentwire_switch([("Synthetic.swift", source)]), [])

    def test_ignores_files_that_never_mention_PaneContentWire(self):
        # A `default:` inside some unrelated switch is not this check's business.
        source = "switch someOtherEnum {\ndefault: break\n}\n"
        self.assertEqual(check_no_default_in_panecontentwire_switch([("Synthetic.swift", source)]), [])


class ToRowModelMarkedTests(unittest.TestCase):
    def test_bites_on_a_call_that_omits_marked(self):
        source = "NostromoKit.PerriPRRow(model: item.toRowModel(), onLoad: {}, onClear: {})"
        violations = check_every_toRowModel_call_passes_marked([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_marked_is_present(self):
        source = "item.toRowModel(marked: address?.marks(repo: r, number: n) ?? false)"
        self.assertEqual(check_every_toRowModel_call_passes_marked([("Synthetic.swift", source)]), [])


class PayloadTextTests(unittest.TestCase):
    def test_bites_on_the_deleted_raw_text_dump(self):
        source = "ScrollView { textView(payload.text) }"
        violations = check_payload_text_not_referenced([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_absent(self):
        source = "ScrollView { textView(text) }"
        self.assertEqual(check_payload_text_not_referenced([("Synthetic.swift", source)]), [])


class AddressPlumbingTests(unittest.TestCase):
    def test_bites_when_the_construction_call_omits_address(self):
        files = [
            ("DynamicFocusView.swift", "PaneSurfaceView(paneId: id, content: c, freshness: f)"),
            ("PaneSurfaceView.swift", "let address: PaneAddress?"),
        ]
        violations = check_address_plumbed_into_pane_surface(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_the_surface_has_no_address_parameter(self):
        files = [
            ("DynamicFocusView.swift", "PaneSurfaceView(paneId: id, content: c, freshness: f, address: a)"),
            ("PaneSurfaceView.swift", "let content: PaneContentWire?"),
        ]
        violations = check_address_plumbed_into_pane_surface(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_no_construction_call_exists_at_all(self):
        files = [
            ("DynamicFocusView.swift", "// no PaneSurfaceView here"),
            ("PaneSurfaceView.swift", "let address: PaneAddress?"),
        ]
        violations = check_address_plumbed_into_pane_surface(files)
        self.assertEqual(len(violations), 1)

    def test_passes_on_the_real_wiring_shape(self):
        files = [
            ("DynamicFocusView.swift", "PaneSurfaceView(paneId: id, content: c, freshness: f, address: a)"),
            ("PaneSurfaceView.swift", "let address:   PaneAddress?"),
        ]
        self.assertEqual(check_address_plumbed_into_pane_surface(files), [])


class SwipeActionsAddressTests(unittest.TestCase):
    def test_bites_when_a_swipe_action_stages_a_value_derived_from_address(self):
        source = (
            ".swipeActions(edge: .trailing, allowsFullSwipe: false) {\n"
            "    Button {\n"
            "        pendingApproval = (repo: address!.anchorRepo, number: address!.anchorNumber)\n"
            "    } label: { Label(\"Approve\", systemImage: \"checkmark\") }\n"
            "}\n"
        )
        violations = check_swipe_actions_do_not_reference_address([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_when_a_swipe_action_calls_marks(self):
        source = (
            ".swipeActions(edge: .trailing, allowsFullSwipe: false) {\n"
            "    Button {\n"
            "        if marks(repo: item.repo, number: item.number) { pendingApproval = item }\n"
            "    } label: { Label(\"Approve\", systemImage: \"checkmark\") }\n"
            "}\n"
        )
        violations = check_swipe_actions_do_not_reference_address([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_the_staged_value_derives_from_the_iterated_item(self):
        source = (
            ".swipeActions(edge: .trailing, allowsFullSwipe: false) {\n"
            "    Button {\n"
            "        pendingApproval = (repo: item.repo, number: item.number)\n"
            "    } label: { Label(\"Approve\", systemImage: \"checkmark\") }\n"
            "}\n"
        )
        self.assertEqual(check_swipe_actions_do_not_reference_address([("Synthetic.swift", source)]), [])


class StubStringOriginTests(unittest.TestCase):
    def test_bites_on_a_hardcoded_stub_string(self):
        source = 'Text("Code view isn\'t available on iOS yet.")'
        violations = check_stub_strings_come_from_PaneSurfaceStub([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_the_message_comes_from_PaneSurfaceStub(self):
        source = "if let message = PaneSurfaceStub.message(for: content) { stubView(headline: message.headline, detail: message.detail) }"
        self.assertEqual(check_stub_strings_come_from_PaneSurfaceStub([("Synthetic.swift", source)]), [])


# --------------------------------------------------------------------------
# The real gate: every check against the actual iOS/Nostromo tree.
# --------------------------------------------------------------------------

class RealIOSTreeTests(unittest.TestCase):
    """The bites-tests above prove each check CAN fail. This proves none of
    them currently DO fail, against the tree these checks exist to guard —
    the mandatory positive counterpart, without which every bites-test above
    would be satisfiable by a check that always fails.
    """

    @classmethod
    def setUpClass(cls):
        cls.files = _load_real_tree()

    def test_the_ios_tree_is_not_empty(self):
        # If this ever returns zero files, every check below passes
        # vacuously because there is nothing to check — IOS_SRC_ROOT moved
        # or is wrong.
        self.assertGreater(len(self.files), 0, "no .swift files found under iOS/Nostromo")

    def test_no_default_arm_in_a_panecontentwire_switch(self):
        violations = check_no_default_in_panecontentwire_switch(self.files)
        self.assertEqual(violations, [], violations)

    def test_every_toRowModel_call_passes_marked(self):
        violations = check_every_toRowModel_call_passes_marked(self.files)
        self.assertEqual(violations, [], violations)

    def test_payload_text_is_referenced_nowhere(self):
        violations = check_payload_text_not_referenced(self.files)
        self.assertEqual(violations, [], violations)

    def test_address_is_plumbed_into_the_pane_surface(self):
        violations = check_address_plumbed_into_pane_surface(self.files)
        self.assertEqual(violations, [], violations)

    def test_swipe_actions_never_reference_address_or_marks(self):
        violations = check_swipe_actions_do_not_reference_address(self.files)
        self.assertEqual(violations, [], violations)

    def test_stub_strings_come_from_PaneSurfaceStub_everywhere(self):
        violations = check_stub_strings_come_from_PaneSurfaceStub(self.files)
        self.assertEqual(violations, [], violations)


# --------------------------------------------------------------------------
# Belt and braces: this suite itself must never skip.
# --------------------------------------------------------------------------

class SuiteNeverSkipsTests(unittest.TestCase):
    """The CI job greps its output for `... skipped` / `(skipped=` and fails
    the build on either. This is a local, source-level second guard: if a
    skip mechanism is ever added to this file, this test fails before the
    grep would even need to run.

    Parsed with `ast` rather than a substring search deliberately: a naive
    `"@unittest.skip" not in source` check would trip on its own assertion
    literal (this very check has to *say* "@unittest.skip" to describe what
    it's looking for) — the same self-reference trap a grep-for-the-word
    guard hits on `test_blank_lines_are_skipped`-style test names elsewhere
    in this repo (see the comment in .github/workflows/ci.yml). Walking the
    parse tree for an actual decorator or an actual `.skipTest(` call
    sidesteps it: a string literal is a `Constant` node, not a `Call` or a
    decorator, so this test can describe the pattern it forbids without
    matching itself.
    """

    def test_this_module_defines_no_skip_decorator_or_skipTest_call(self):
        tree = ast.parse(_read(__file__))
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
