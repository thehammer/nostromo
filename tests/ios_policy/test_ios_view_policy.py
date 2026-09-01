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


def _strip_line_comments(source):
    """Remove `//`-style line comments from `source`.

    Naive — doesn't understand string literals that happen to contain `//`,
    the same documented limitation as `_balanced_span` above. Exists so a
    check for a banned identifier isn't fooled by a comment that *names* the
    identifier only to explain why it's forbidden — e.g. a doc-comment
    saying "never read `cwd`" would otherwise trip a substring check for
    `cwd` even though no code anywhere reads it. Same self-reference trap
    `SuiteNeverSkipsTests` guards against for this file's own source, one
    level down: a check that can't tell "banned word in code" from "banned
    word in the comment banning it" is not a check anyone should trust.
    """
    return re.sub(r"//.*", "", source)


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


def _is_activity_path(path):
    """`True` when `path`'s normalized form contains `/Views/Activity/` —
    the directory this wedge (W4, ios-curated-view-parity) introduces for
    the ambient-activity ticker and its expanded sheet.
    """
    return "/Views/Activity/" in path.replace(os.sep, "/")


def check_ticker_bar_has_fixed_single_line_height(files):
    """`ActivityTickerBar.swift` must render at a fixed, single-line height
    that an arriving activity event can never change.

    This is the mechanism (wedge Decision D4) by which an arriving activity
    event cannot resize the space it occupies and shift the transcript's
    scroll offset underneath the operator: a `safeAreaInset` whose height
    changes shifts the enclosing scroll view's content inset with no scroll
    call ever being made, so the fix has to be "this view's height never
    changes," not "this view never calls scrollTo." A missing file counts as
    a violation too — an absent ticker can't be pinned to a fixed height
    either.
    """
    violations = []
    match = next(((p, s) for p, s in files if os.path.basename(p) == "ActivityTickerBar.swift"), None)
    path, source = match if match else ("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", "")

    if "lineLimit(1)" not in source:
        violations.append((path, "ActivityTickerBar.swift must call lineLimit(1)"))
    if ".frame(height:" not in source:
        violations.append((path, "ActivityTickerBar.swift must pin an explicit .frame(height:)"))
    if "lineLimit(nil)" in source:
        violations.append((path, "ActivityTickerBar.swift must never allow unbounded lineLimit(nil)"))
    if "fixedSize(horizontal: false, vertical: true)" in source:
        violations.append((path, "ActivityTickerBar.swift must never allow vertical growth via fixedSize"))
    return violations


def check_activity_path_never_scrolls_or_steals_focus(files):
    """No file under `Views/Activity/` scrolls the transcript, steals first
    responder/focus, or auto-dismisses.

    Ported from macOS's `ActivityTickerWiringTests.swift` (which greps a
    single named file as raw text) to this suite's `(path, source)`-list
    shape. `DispatchQueue.main.asyncAfter` is the auto-dismiss idiom's
    fingerprint (macOS's `ToastBannerView`) — the ticker is explicitly not a
    toast; it stays up permanently.
    """
    banned = ("scrollTo(", "@FocusState", "becomeFirstResponder", "DispatchQueue.main.asyncAfter")
    violations = []
    for path, source in files:
        if not _is_activity_path(path):
            continue
        stripped = _strip_line_comments(source)
        for needle in banned:
            if needle in stripped:
                violations.append((path, "`%s` found in an activity-path view" % needle))
    return violations


def check_transcriptview_autoscroll_still_keys_on_turns_count(files):
    """`TranscriptView.swift`'s autoscroll must still be keyed on
    `store.turns.count`, and no `onChange(of:...)` call in that file may
    reference anything activity-related.

    Guards the non-regression requirement that adding the ticker's bottom-
    accessory slot must not touch the existing count-keyed autoscroll
    trigger — an activity event arriving is not a new turn and must never
    itself move the transcript.
    """
    by_name = {os.path.basename(p): (p, s) for p, s in files}
    entry = by_name.get("TranscriptView.swift")
    path, source = entry if entry else ("iOS/Nostromo/Views/TranscriptView.swift", "")

    calls = _balanced_call_args(source, r"\bonChange\(")
    violations = []
    if not calls:
        violations.append((path, "no onChange(of:...) call found in TranscriptView.swift"))
        return violations

    if not any(re.search(r"of:\s*store\.turns\.count\b", c) for c in calls):
        violations.append((path, "no onChange(of:...) call is keyed on store.turns.count"))

    for c in calls:
        if re.search(r"of:[^,)]*activity", c, re.IGNORECASE):
            violations.append((path, "an onChange(of:...) call references activity: %s" % c))

    return violations


def check_no_secrets_in_activity_views(files):
    """No file under `Views/Activity/` references `toolInput`, `tool_input`,
    `cwd`, or `toolUseId`.

    The always-on ambient surface must only ever read `summary`/`agent`/
    `agentType`/`kind`/`ts` — never a tool's raw input or working directory
    (D6). Comments are stripped before matching: a doc-comment naming one of
    these identifiers only to explain that it must never be read (exactly
    what `ActivityTickerBar.swift`/`ActivityStreamsSheet.swift` do) must not
    itself trip this check.
    """
    banned = ("toolInput", "tool_input", "cwd", "toolUseId")
    violations = []
    for path, source in files:
        if not _is_activity_path(path):
            continue
        stripped = _strip_line_comments(source)
        for needle in banned:
            if needle in stripped:
                violations.append((path, "activity view references `%s`" % needle))
    return violations


def check_no_suppression_affordance_in_activity_views(files):
    """No file under `Views/Activity/` references `UserDefaults`,
    `@AppStorage`, or `Toggle`.

    The PRD requires no user-facing enable/disable control and no
    agent-callable suppression of the ambient surface (D7).
    """
    banned = ("UserDefaults", "@AppStorage", "Toggle")
    violations = []
    for path, source in files:
        if not _is_activity_path(path):
            continue
        for needle in banned:
            if needle in source:
                violations.append((path, "activity view references `%s`" % needle))
    return violations


def check_streams_sheet_presented_from_focus_view(files):
    """`DynamicFocusView.swift` presents `ActivityStreamsSheet` via a
    `.sheet(...)`; neither `TranscriptView.swift` nor
    `PaneSurfaceView.swift` construct it at all.

    The sheet must be owned by the focus view, not the transcript or the
    pane surface, so it survives whatever those are doing (rotation, tab
    switches) without disappearing underneath the operator.
    """
    by_name = {os.path.basename(p): (p, s) for p, s in files}
    violations = []

    focus_entry = by_name.get("DynamicFocusView.swift")
    focus_path, focus_source = focus_entry if focus_entry else ("iOS/Nostromo/Views/DynamicFocusView.swift", "")
    sheet_spans = _spans_after(focus_source, r"\.sheet\(")
    if not any("ActivityStreamsSheet(" in span for span in sheet_spans):
        violations.append((focus_path, "DynamicFocusView.swift has no .sheet {...} presenting ActivityStreamsSheet(...)"))

    for name in ("TranscriptView.swift", "PaneSurfaceView.swift"):
        entry = by_name.get(name)
        path, source = entry if entry else (name, "")
        if "ActivityStreamsSheet(" in source:
            violations.append((path, "%s constructs ActivityStreamsSheet(...) — must be owned by DynamicFocusView" % name))

    return violations


def _is_decision_path(path):
    """`True` when `path`'s basename contains "Decision" — the naming
    convention every file in this wedge (ios-curated-view-parity W3) uses
    for the `nostromo.ask_decision` surface (`DecisionSheetView.swift`).
    """
    return "Decision" in os.path.basename(path)


def check_no_answered_state_in_decision_views(files):
    """No `@State` declaration in a `Decision`-named file holds
    answered/resolved-shaped state.

    This is the `AskQuestionPrompt` shape (`@State private var answered`
    inside a view rendered from a `LazyVStack` — the recycle-and-re-arm
    hazard that forced `TurnInteractionStore` into existence on macOS),
    named as forbidden for the decision surface specifically. The answer-once
    gate lives in `NostromoKit.DecisionStore`, held outside every view;
    `DecisionSheetView` must never shadow it with a local flag.
    """
    banned = re.compile(r"@State[^\n]*\bvar\s+\w*(?:answered|hasAnswered|didAnswer|resolved)\w*", re.IGNORECASE)
    violations = []
    for path, source in files:
        if not _is_decision_path(path):
            continue
        stripped = _strip_line_comments(source)
        if banned.search(stripped):
            violations.append((path, "a @State declaration holds answered/resolved-shaped state"))
    return violations


def check_decision_sheet_constructed_only_from_app_root(files):
    """`DecisionSheetView(` is constructed exactly from `NostromoApp.swift`,
    and from nowhere else under `iOS/Nostromo/Views/`.

    This is D1/B8 asserted structurally: the decision surface presents above
    the root `TabView`, never from a region or focus view, so it can never
    be inside a lazy container and never gets recycled across requests.
    """
    violations = []
    found_at_app_root = False
    for path, source in files:
        if "DecisionSheetView(" not in source:
            continue
        if os.path.basename(path) == "NostromoApp.swift":
            found_at_app_root = True
        else:
            violations.append((path, "DecisionSheetView(...) constructed outside NostromoApp.swift"))
    if not found_at_app_root:
        violations.append(("iOS/Nostromo/NostromoApp.swift", "DecisionSheetView(...) is never constructed from NostromoApp.swift"))
    return violations


def check_no_hardcoded_nil_resolution(files):
    """No construction site passes a hard-coded `resolution: nil`.

    `DecisionSheetView.init`'s `resolution` parameter has no default value
    specifically so every call site is forced to compute it from
    `DaemonStore.decisionStore.resolution(for:)` — a hard-coded `nil`
    literal would defeat that wiring check by construction.
    """
    violations = []
    for path, source in files:
        if re.search(r"resolution\s*:\s*nil\b", source):
            violations.append((path, "a construction site passes a hard-coded `resolution: nil`"))
    return violations


def check_claim_answer_precedes_answer_decision(files):
    """Exactly one `answerDecision(` call site exists under `iOS/`, and
    `claimAnswer` appears before it in file order.

    The gate, asserted: claiming the answer before sending it is what makes
    a second, contradictory answer for the same request structurally
    impossible on this client, not merely caught downstream by the daemon's
    `AlreadyAnswered` guard.
    """
    violations = []
    total_calls = 0
    for path, source in files:
        count = len(re.findall(r"\banswerDecision\(", source))
        if count == 0:
            continue
        total_calls += count
        claim_idx = source.find("claimAnswer")
        answer_idx = source.find("answerDecision(")
        if claim_idx == -1 or claim_idx > answer_idx:
            violations.append((path, "answerDecision( appears before claimAnswer (or claimAnswer is absent) in file order"))
    if total_calls != 1:
        violations.append(("iOS/Nostromo", "expected exactly one answerDecision( call site under iOS/, found %d" % total_calls))
    return violations


def _case_body_spans(source, case_pattern):
    """For each regex match of `case_pattern` (which must end right after a
    Swift `case ... :` label), return the body text from there up to
    whichever comes first: the next `case .` label, or the next line that is
    only a closing brace (`}`) — a best-effort text bound for a brace-less
    switch-case body, in the same "textual heuristic, not a control-flow
    proof" spirit as `_balanced_span`/`_spans_after` above.
    """
    spans = []
    for m in re.finditer(case_pattern, source):
        start = m.end()
        next_case = re.search(r"\bcase\s+\.", source[start:])
        next_close = re.search(r"\n[ \t]*\}", source[start:])
        ends = [x.start() for x in (next_case, next_close) if x is not None]
        end = start + min(ends) if ends else len(source)
        spans.append(source[start:end])
    return spans


def check_superseded_close_sends_nothing(files):
    """Every `case .supersededByDaemon:` body contains no `answerDecision(`,
    `onAnswer(`, or `onClose(`.

    D5's safety property: a system-initiated close (this request was already
    resolved elsewhere) must never send a `decision_answer` frame — a
    spurious one would read to the calling agent as an explicit choice or an
    implicit Skip the operator never made.
    """
    forbidden = ("answerDecision(", "onAnswer(", "onClose(")
    violations = []
    for path, source in files:
        for span in _case_body_spans(source, r"case\s+\.supersededByDaemon\s*:"):
            for needle in forbidden:
                if needle in span:
                    violations.append((path, "case .supersededByDaemon body calls %s" % needle))
    return violations


def _confirmation_dialog_trailing_spans(source):
    """For each `.confirmationDialog(` call, return the (start, end) index
    spans of its trailing closure(s) — the button block, and the `message:`
    block when present. Skips past the call's own parenthesised argument
    list first (which itself may contain `{ ... }` closures, e.g. `Binding(
    get: { ... }, set: { ... })`) before looking for the trailing `{`, so
    those nested closures are never mistaken for the trailing one.
    """
    spans = []
    for m in re.finditer(r"\.confirmationDialog\(", source):
        open_paren = m.end() - 1
        if source[open_paren] != "(":
            continue
        depth = 0
        i = open_paren
        end_parens = None
        while i < len(source):
            c = source[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    end_parens = i + 1
                    break
            i += 1
        if end_parens is None:
            continue
        brace_index = source.find("{", end_parens)
        if brace_index == -1:
            continue
        end = _balanced_span(source, brace_index)
        spans.append((brace_index, end))
        tail = source[end:end + 60]
        m2 = re.match(r"\s*\w+\s*:\s*\{", tail)
        if m2:
            brace_index2 = end + tail.index("{")
            end2 = _balanced_span(source, brace_index2)
            spans.append((brace_index2, end2))
    return spans


def check_one_tap_decision_asymmetry(files):
    """No `Decision`-named file contains `confirmationDialog`, and every
    `perriApprove(` call site under `iOS/` sits inside a `confirmationDialog`
    block.

    One check, both halves of a deliberate asymmetry (D6): a decision answer
    takes exactly one tap (the modal itself already interrupted the operator
    with full context — the tap IS the confirmation), while a queue approval
    always stays gated, because it posts to GitHub.
    """
    violations = []
    for path, source in files:
        if _is_decision_path(path) and "confirmationDialog" in source:
            violations.append((path, "confirmationDialog found in a Decision-named file — one-tap must stay ungated"))
        spans = _confirmation_dialog_trailing_spans(source)
        for m in re.finditer(r"\bperriApprove\(", source):
            idx = m.start()
            if not any(s <= idx < e for s, e in spans):
                violations.append((path, "perriApprove( call is not inside a confirmationDialog block"))
    return violations


CHECKS = (
    check_no_default_in_panecontentwire_switch,
    check_every_toRowModel_call_passes_marked,
    check_payload_text_not_referenced,
    check_address_plumbed_into_pane_surface,
    check_swipe_actions_do_not_reference_address,
    check_stub_strings_come_from_PaneSurfaceStub,
    check_ticker_bar_has_fixed_single_line_height,
    check_activity_path_never_scrolls_or_steals_focus,
    check_transcriptview_autoscroll_still_keys_on_turns_count,
    check_no_secrets_in_activity_views,
    check_no_suppression_affordance_in_activity_views,
    check_streams_sheet_presented_from_focus_view,
    check_no_answered_state_in_decision_views,
    check_decision_sheet_constructed_only_from_app_root,
    check_no_hardcoded_nil_resolution,
    check_claim_answer_precedes_answer_decision,
    check_superseded_close_sends_nothing,
    check_one_tap_decision_asymmetry,
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


class StripLineCommentsTests(unittest.TestCase):
    def test_removes_a_trailing_line_comment(self):
        self.assertEqual(_strip_line_comments("let x = 1 // comment"), "let x = 1 ")

    def test_removes_a_whole_comment_line(self):
        self.assertEqual(_strip_line_comments("// cwd must never be read\nlet x = 1"), "\nlet x = 1")

    def test_leaves_code_with_no_comments_untouched(self):
        self.assertEqual(_strip_line_comments("let x = 1"), "let x = 1")


class TickerBarFixedHeightTests(unittest.TestCase):
    def test_bites_when_lineLimit_1_is_missing(self):
        source = 'Text(text).frame(height: 28)'
        violations = check_ticker_bar_has_fixed_single_line_height([("ActivityTickerBar.swift", source)])
        self.assertTrue(any("lineLimit(1)" in msg for _, msg in violations))

    def test_bites_when_frame_height_is_missing(self):
        source = 'Text(text).lineLimit(1)'
        violations = check_ticker_bar_has_fixed_single_line_height([("ActivityTickerBar.swift", source)])
        self.assertTrue(any("frame(height:" in msg for _, msg in violations))

    def test_bites_when_lineLimit_nil_is_present(self):
        source = 'Text(text).lineLimit(nil).frame(height: 28)'
        violations = check_ticker_bar_has_fixed_single_line_height([("ActivityTickerBar.swift", source)])
        self.assertTrue(any("lineLimit(nil)" in msg for _, msg in violations))

    def test_bites_when_vertical_fixedSize_growth_is_present(self):
        source = 'Text(text).lineLimit(1).frame(height: 28).fixedSize(horizontal: false, vertical: true)'
        violations = check_ticker_bar_has_fixed_single_line_height([("ActivityTickerBar.swift", source)])
        self.assertTrue(any("fixedSize" in msg for _, msg in violations))

    def test_bites_when_the_file_does_not_exist(self):
        violations = check_ticker_bar_has_fixed_single_line_height([("SomeOtherFile.swift", "irrelevant")])
        self.assertTrue(len(violations) > 0)

    def test_passes_on_a_fixed_single_line_bar(self):
        source = 'Text(text).lineLimit(1).truncationMode(.tail).frame(height: 28)'
        self.assertEqual(check_ticker_bar_has_fixed_single_line_height([("ActivityTickerBar.swift", source)]), [])


class ActivityPathNeverScrollsOrStealsFocusTests(unittest.TestCase):
    def test_bites_on_scrollTo(self):
        source = "proxy.scrollTo(id, anchor: .bottom)"
        violations = check_activity_path_never_scrolls_or_steals_focus(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_FocusState(self):
        source = "@FocusState private var isFocused: Bool"
        violations = check_activity_path_never_scrolls_or_steals_focus(
            [("iOS/Nostromo/Views/Activity/ActivityStreamsSheet.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_becomeFirstResponder(self):
        source = "textField.becomeFirstResponder()"
        violations = check_activity_path_never_scrolls_or_steals_focus(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_dispatch_async_after_the_toast_auto_dismiss_idiom(self):
        source = "DispatchQueue.main.asyncAfter(deadline: .now() + 3) { dismiss() }"
        violations = check_activity_path_never_scrolls_or_steals_focus(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_ignores_files_outside_the_activity_directory(self):
        source = "proxy.scrollTo(id, anchor: .bottom)"
        violations = check_activity_path_never_scrolls_or_steals_focus(
            [("iOS/Nostromo/Views/TranscriptView.swift", source)])
        self.assertEqual(violations, [])

    def test_passes_on_clean_activity_source(self):
        source = "Text(text).lineLimit(1).frame(height: 28)"
        violations = check_activity_path_never_scrolls_or_steals_focus(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(violations, [])


class TranscriptAutoscrollKeysOnTurnsCountTests(unittest.TestCase):
    def test_bites_when_no_onChange_call_exists_at_all(self):
        source = "struct TranscriptView: View { var body: some View { Text(\"hi\") } }"
        violations = check_transcriptview_autoscroll_still_keys_on_turns_count([("TranscriptView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_when_no_onChange_call_is_keyed_on_turns_count(self):
        source = ".onChange(of: someOtherThing) { _, _ in doStuff() }"
        violations = check_transcriptview_autoscroll_still_keys_on_turns_count([("TranscriptView.swift", source)])
        self.assertTrue(any("turns.count" in msg for _, msg in violations))

    def test_bites_when_an_onChange_call_references_activity(self):
        source = (
            ".onChange(of: store.turns.count) { _, _ in scroll() }\n"
            ".onChange(of: activityModel.tickerSummary) { _, _ in doStuff() }\n"
        )
        violations = check_transcriptview_autoscroll_still_keys_on_turns_count([("TranscriptView.swift", source)])
        self.assertTrue(any("activity" in msg.lower() for _, msg in violations))

    def test_passes_when_only_turns_count_is_keyed(self):
        source = ".onChange(of: store.turns.count) { _, _ in scroll() }"
        self.assertEqual(check_transcriptview_autoscroll_still_keys_on_turns_count([("TranscriptView.swift", source)]), [])


class NoSecretsInActivityViewsTests(unittest.TestCase):
    def test_bites_on_an_actual_toolInput_reference(self):
        source = "Text(event.toolInput ?? \"\")"
        violations = check_no_secrets_in_activity_views([("iOS/Nostromo/Views/Activity/ActivityStreamsSheet.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_an_actual_cwd_reference(self):
        source = "Text(event.cwd ?? \"\")"
        violations = check_no_secrets_in_activity_views([("iOS/Nostromo/Views/Activity/ActivityStreamsSheet.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_an_actual_toolUseId_reference(self):
        source = "Text(event.toolUseId ?? \"\")"
        violations = check_no_secrets_in_activity_views([("iOS/Nostromo/Views/Activity/ActivityStreamsSheet.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_does_not_false_positive_on_a_comment_explaining_the_ban(self):
        # This is the exact shape ActivityTickerBar.swift/ActivityStreamsSheet.swift
        # use to document D6 — must not itself trip the check.
        source = "// D6: reads only summary/agent/agentType/kind — never toolInput, cwd, or toolUseId.\nText(event.summary)"
        self.assertEqual(check_no_secrets_in_activity_views([("iOS/Nostromo/Views/Activity/ActivityStreamsSheet.swift", source)]), [])

    def test_ignores_files_outside_the_activity_directory(self):
        source = "Text(event.cwd ?? \"\")"
        violations = check_no_secrets_in_activity_views([("iOS/Nostromo/Views/Panes/PaneSurfaceView.swift", source)])
        self.assertEqual(violations, [])


class NoSuppressionAffordanceInActivityViewsTests(unittest.TestCase):
    def test_bites_on_UserDefaults(self):
        source = "UserDefaults.standard.set(true, forKey: \"activityEnabled\")"
        violations = check_no_suppression_affordance_in_activity_views(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_AppStorage(self):
        source = "@AppStorage(\"activityEnabled\") private var activityEnabled = true"
        violations = check_no_suppression_affordance_in_activity_views(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_Toggle(self):
        source = 'Toggle("Show activity", isOn: $activityEnabled)'
        violations = check_no_suppression_affordance_in_activity_views(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_ignores_files_outside_the_activity_directory(self):
        source = 'Toggle("Remote control", isOn: $remoteControl)'
        violations = check_no_suppression_affordance_in_activity_views(
            [("iOS/Nostromo/Views/Panes/PaneSurfaceView.swift", source)])
        self.assertEqual(violations, [])

    def test_passes_on_clean_activity_source(self):
        source = "Text(text).lineLimit(1).frame(height: 28)"
        violations = check_no_suppression_affordance_in_activity_views(
            [("iOS/Nostromo/Views/Activity/ActivityTickerBar.swift", source)])
        self.assertEqual(violations, [])


class NoAnsweredStateInDecisionViewsTests(unittest.TestCase):
    def test_bites_on_a_plain_answered_flag(self):
        source = "struct DecisionSheetView: View {\n    @State private var answered = false\n}\n"
        violations = check_no_answered_state_in_decision_views([("DecisionSheetView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_hasAnswered_didAnswer_or_resolved_variants(self):
        for name in ("hasAnswered", "didAnswer", "resolvedFlag"):
            source = "@State private var %s = false" % name
            violations = check_no_answered_state_in_decision_views([("DecisionSheetView.swift", source)])
            self.assertEqual(len(violations), 1, "expected a violation for @State var %s" % name)

    def test_ignores_files_without_decision_in_the_name(self):
        source = "@State private var answered = false"
        self.assertEqual(check_no_answered_state_in_decision_views([("AskQuestionPrompt.swift", source)]), [])

    def test_ignores_a_comment_explaining_the_ban(self):
        source = "// must never hold @State private var answered here\nlet resolution: DecisionResolutionRecord?"
        self.assertEqual(check_no_answered_state_in_decision_views([("DecisionSheetView.swift", source)]), [])

    def test_passes_on_the_real_shape(self):
        source = "let resolution: DecisionResolutionRecord?\nlet onClose: (DecisionCloseReason) -> Void"
        self.assertEqual(check_no_answered_state_in_decision_views([("DecisionSheetView.swift", source)]), [])


class DecisionSheetConstructedOnlyFromAppRootTests(unittest.TestCase):
    def test_bites_when_constructed_from_another_view_file(self):
        files = [
            ("NostromoApp.swift", "// no construction here"),
            ("DynamicFocusView.swift", "DecisionSheetView(request: r, askingFocusName: n, resolution: res, onClose: c)"),
        ]
        violations = check_decision_sheet_constructed_only_from_app_root(files)
        self.assertEqual(len(violations), 2, "expected both: wrong-file construction AND app-root has none")

    def test_bites_when_never_constructed_anywhere(self):
        files = [("NostromoApp.swift", "// nothing")]
        violations = check_decision_sheet_constructed_only_from_app_root(files)
        self.assertEqual(len(violations), 1)

    def test_passes_when_constructed_only_from_app_root(self):
        files = [
            ("NostromoApp.swift", "DecisionSheetView(request: r, askingFocusName: n, resolution: res, onClose: c)"),
            ("DynamicFocusView.swift", "// no mention"),
        ]
        self.assertEqual(check_decision_sheet_constructed_only_from_app_root(files), [])


class NoHardcodedNilResolutionTests(unittest.TestCase):
    def test_bites_on_a_hardcoded_nil(self):
        source = "DecisionSheetView(request: r, askingFocusName: n, resolution: nil, onClose: c)"
        violations = check_no_hardcoded_nil_resolution([("NostromoApp.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_computed_from_the_store(self):
        source = "DecisionSheetView(request: r, askingFocusName: n, resolution: store.decisionStore.resolution(for: r.requestId), onClose: c)"
        self.assertEqual(check_no_hardcoded_nil_resolution([("NostromoApp.swift", source)]), [])


class ClaimAnswerPrecedesAnswerDecisionTests(unittest.TestCase):
    def test_bites_when_claimAnswer_is_absent(self):
        source = "store.answerDecision(requestId: id, choiceId: c)"
        violations = check_claim_answer_precedes_answer_decision([("NostromoApp.swift", source)])
        self.assertTrue(any("claimAnswer" in msg for _, msg in violations))

    def test_bites_when_answerDecision_appears_before_claimAnswer(self):
        source = "store.answerDecision(requestId: id, choiceId: c)\nstore.decisionStore.claimAnswer(requestId: id, record: r)"
        violations = check_claim_answer_precedes_answer_decision([("NostromoApp.swift", source)])
        self.assertTrue(any("claimAnswer" in msg for _, msg in violations))

    def test_bites_when_there_are_two_call_sites(self):
        files = [
            ("NostromoApp.swift", "store.decisionStore.claimAnswer(requestId: id, record: r)\nstore.answerDecision(requestId: id, choiceId: c)"),
            ("SomeOtherView.swift", "store.answerDecision(requestId: id2, choiceId: c2)"),
        ]
        violations = check_claim_answer_precedes_answer_decision(files)
        self.assertTrue(any("exactly one" in msg for _, msg in violations))

    def test_passes_on_the_real_shape(self):
        source = "if store.decisionStore.claimAnswer(requestId: requestId, record: record) {\n    store.answerDecision(requestId: requestId, choiceId: choiceId)\n}"
        self.assertEqual(check_claim_answer_precedes_answer_decision([("NostromoApp.swift", source)]), [])


class SupersededCloseSendsNothingTests(unittest.TestCase):
    def test_bites_when_the_case_forwards_to_onAnswer(self):
        source = "switch reason {\ncase .supersededByDaemon:\n    onAnswer(nil)\ncase .operatorDismissed:\n    onAnswer(nil)\n}"
        violations = check_superseded_close_sends_nothing([("NostromoApp.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_when_the_case_calls_answerDecision_directly(self):
        source = "switch reason {\ncase .supersededByDaemon:\n    store.answerDecision(requestId: id, choiceId: nil)\n}"
        violations = check_superseded_close_sends_nothing([("NostromoApp.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_the_case_is_a_no_op(self):
        source = (
            "switch reason {\n"
            "case .operatorChose(let id):\n"
            "    closeDecision(.operatorChose(id), for: requestId)\n"
            "case .operatorDismissed:\n"
            "    closeDecision(.operatorDismissed, for: requestId)\n"
            "case .supersededByDaemon:\n"
            "    break\n"
            "}\n"
        )
        self.assertEqual(check_superseded_close_sends_nothing([("NostromoApp.swift", source)]), [])

    def test_passes_when_no_supersededByDaemon_case_exists_in_the_file(self):
        source = "let x = 1"
        self.assertEqual(check_superseded_close_sends_nothing([("Unrelated.swift", source)]), [])


class OneTapDecisionAsymmetryTests(unittest.TestCase):
    def test_bites_on_confirmationDialog_in_a_decision_file(self):
        source = ".confirmationDialog(\"Sure?\", isPresented: $x) { Button(\"OK\") {} }"
        violations = check_one_tap_decision_asymmetry([("DecisionSheetView.swift", source)])
        self.assertTrue(any("Decision-named file" in msg for _, msg in violations))

    def test_bites_when_perriApprove_is_not_inside_a_confirmationDialog(self):
        source = "Button(\"Approve\") { store.perriApprove(number: n, repo: r) }"
        violations = check_one_tap_decision_asymmetry([("PerriView.swift", source)])
        self.assertTrue(any("perriApprove" in msg for _, msg in violations))

    def test_passes_on_the_real_perriview_shape_with_nested_closures_before_the_trailing_one(self):
        source = (
            ".confirmationDialog(\n"
            "    pendingApproval.map { \"Approve PR #\\($0.number)?\" } ?? \"\",\n"
            "    isPresented: Binding(\n"
            "        get:  { pendingApproval != nil },\n"
            "        set:  { if !$0 { pendingApproval = nil } }\n"
            "    ),\n"
            "    titleVisibility: .visible\n"
            ") {\n"
            "    if let item = pendingApproval {\n"
            "        Button(\"Approve\") {\n"
            "            store.perriApprove(number: item.number, repo: item.repo)\n"
            "            pendingApproval = nil\n"
            "        }\n"
            "    }\n"
            "    Button(\"Cancel\", role: .cancel) { pendingApproval = nil }\n"
            "} message: {\n"
            "    Text(\"Posted to GitHub.\")\n"
            "}\n"
        )
        self.assertEqual(check_one_tap_decision_asymmetry([("PerriView.swift", source)]), [])


class StreamsSheetPresentedFromFocusViewTests(unittest.TestCase):
    def test_bites_when_DynamicFocusView_has_a_sheet_but_not_for_ActivityStreamsSheet(self):
        files = [
            ("DynamicFocusView.swift", ".sheet(isPresented: $x) { SomeOtherSheet() }"),
            ("TranscriptView.swift", "struct TranscriptView: View {}"),
            ("PaneSurfaceView.swift", "struct PaneSurfaceView: View {}"),
        ]
        violations = check_streams_sheet_presented_from_focus_view(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_DynamicFocusView_has_no_sheet_at_all(self):
        files = [
            ("DynamicFocusView.swift", "struct DynamicFocusView: View {}"),
            ("TranscriptView.swift", "struct TranscriptView: View {}"),
            ("PaneSurfaceView.swift", "struct PaneSurfaceView: View {}"),
        ]
        violations = check_streams_sheet_presented_from_focus_view(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_TranscriptView_constructs_the_sheet_itself(self):
        files = [
            ("DynamicFocusView.swift", ".sheet(isPresented: $x) { ActivityStreamsSheet(model: m) }"),
            ("TranscriptView.swift", "ActivityStreamsSheet(model: m)"),
            ("PaneSurfaceView.swift", "struct PaneSurfaceView: View {}"),
        ]
        violations = check_streams_sheet_presented_from_focus_view(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_PaneSurfaceView_constructs_the_sheet_itself(self):
        files = [
            ("DynamicFocusView.swift", ".sheet(isPresented: $x) { ActivityStreamsSheet(model: m) }"),
            ("TranscriptView.swift", "struct TranscriptView: View {}"),
            ("PaneSurfaceView.swift", "ActivityStreamsSheet(model: m)"),
        ]
        violations = check_streams_sheet_presented_from_focus_view(files)
        self.assertEqual(len(violations), 1)

    def test_passes_on_the_correct_ownership_shape(self):
        files = [
            ("DynamicFocusView.swift", ".sheet(isPresented: $x) { ActivityStreamsSheet(model: m) }"),
            ("TranscriptView.swift", "struct TranscriptView: View {}"),
            ("PaneSurfaceView.swift", "struct PaneSurfaceView: View {}"),
        ]
        self.assertEqual(check_streams_sheet_presented_from_focus_view(files), [])


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

    def test_ticker_bar_has_a_fixed_single_line_height(self):
        violations = check_ticker_bar_has_fixed_single_line_height(self.files)
        self.assertEqual(violations, [], violations)

    def test_activity_path_never_scrolls_or_steals_focus(self):
        violations = check_activity_path_never_scrolls_or_steals_focus(self.files)
        self.assertEqual(violations, [], violations)

    def test_transcriptview_autoscroll_still_keys_on_turns_count(self):
        violations = check_transcriptview_autoscroll_still_keys_on_turns_count(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_secrets_in_activity_views(self):
        violations = check_no_secrets_in_activity_views(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_suppression_affordance_in_activity_views(self):
        violations = check_no_suppression_affordance_in_activity_views(self.files)
        self.assertEqual(violations, [], violations)

    def test_streams_sheet_presented_from_focus_view(self):
        violations = check_streams_sheet_presented_from_focus_view(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_answered_state_in_decision_views(self):
        violations = check_no_answered_state_in_decision_views(self.files)
        self.assertEqual(violations, [], violations)

    def test_decision_sheet_constructed_only_from_app_root(self):
        violations = check_decision_sheet_constructed_only_from_app_root(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_hardcoded_nil_resolution(self):
        violations = check_no_hardcoded_nil_resolution(self.files)
        self.assertEqual(violations, [], violations)

    def test_claim_answer_precedes_answer_decision(self):
        violations = check_claim_answer_precedes_answer_decision(self.files)
        self.assertEqual(violations, [], violations)

    def test_superseded_close_sends_nothing(self):
        violations = check_superseded_close_sends_nothing(self.files)
        self.assertEqual(violations, [], violations)

    def test_one_tap_decision_asymmetry(self):
        violations = check_one_tap_decision_asymmetry(self.files)
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
