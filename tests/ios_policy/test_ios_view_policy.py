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


def check_payload_text_only_inside_codedocument_construction(files):
    """`payload.text` may be referenced only inside a `CodeDocument(`
    construction's argument list (ios-curated-view-parity W7).

    Supersedes W2's absolute "`payload.text` appears nowhere" prohibition.
    That prohibition was the whole property that mattered when `.code` had
    no renderer at all — any reference to it was necessarily the deleted raw
    dump. Now that `CodeSurfaceView` (W7) renders `.code` for real, the raw
    text has to reach the screen somehow; the property that actually matters
    is that it only ever does so by being split into `CodeDocument.lines`
    and addressed through it, never handed straight to a rendering view.

    Comments are stripped first — the same carve-out `_strip_line_comments`
    makes everywhere else in this suite — so a comment merely *naming* the
    old behaviour (as `CodeSurfaceView.swift`'s own header comment does,
    explaining why W2 deleted the dump) cannot trip this check.
    """
    violations = []
    for path, source in files:
        stripped = _strip_line_comments(source)
        if "payload.text" not in stripped:
            continue
        calls = _balanced_call_args(stripped, r"\bCodeDocument\(")
        if not any("payload.text" in call for call in calls):
            violations.append((path, "`payload.text` referenced outside a CodeDocument( construction"))
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


def check_no_pane_id_visible_via_capitalized(files):
    """No pane id ever reaches the operator's eyes via `.capitalized`.

    This is W5's core defect: today's `DynamicFocusView` derives every
    non-repl tab label from `paneId.capitalized` (e.g. a pane id of
    `"detail-1"` renders the literal label "Detail-1"). The fix is
    `TabPlan.fallbackLabel`/tab metadata — a curated label, never a
    reformatted wire identifier.

    Heuristic (textual, not a type-flow proof, per this suite's documented
    philosophy): a `.capitalized` call whose receiver expression contains
    `paneId`/`selectedTab` (case-insensitive substring match), or a
    `Text(`/`Label(` call whose balanced argument text interpolates a bare
    `\\(paneId)` or `\\(paneId.capitalized)`.
    """
    violations = []
    for path, source in files:
        stripped = _strip_line_comments(source)
        for m in re.finditer(r"([A-Za-z0-9_.?!]+)\.capitalized\b", stripped):
            receiver = m.group(1)
            if "paneid" in receiver.lower() or "selectedtab" in receiver.lower():
                violations.append((
                    path,
                    "`.capitalized` called on a paneId/selectedTab-shaped expression: %s" % m.group(0)
                ))
        for call in _balanced_call_args(stripped, r"\bText\(") + _balanced_call_args(stripped, r"\bLabel\("):
            if r"\(paneId)" in call or r"\(paneId.capitalized)" in call:
                violations.append((path, "Text(...)/Label(...) interpolates a bare paneId: %s" % call))
    return violations


def check_no_second_bottom_tab_bar(files):
    """`TabView` and `.tabItem` appear only in `NostromoApp.swift` — the
    app's real root 5-tab bar. No file under `Views/` may nest a second
    bottom tab bar inside it (today's `DynamicFocusView`'s per-focus
    `TabView`, the thing this wedge removes).
    """
    violations = []
    for path, source in files:
        normalized = path.replace(os.sep, "/")
        if normalized.endswith("NostromoApp.swift"):
            continue
        if "/Views/" not in normalized:
            continue
        # Comments are stripped first: a doc-comment merely *mentioning*
        # TabView (e.g. explaining what a sibling file does) must not itself
        # trip this check — same self-reference trap `_strip_line_comments`
        # exists to avoid elsewhere in this suite.
        stripped = _strip_line_comments(source)
        if "TabView" in stripped:
            violations.append((path, "TabView found outside NostromoApp.swift"))
        if ".tabItem" in stripped:
            violations.append((path, ".tabItem found outside NostromoApp.swift"))
    return violations


def check_no_root_tab_hijack(files):
    """No file under `Views/` mutates the root tab selection or the
    NavigationStack's path programmatically.

    Heuristic, deliberately simple: ban the literal patterns
    `navigationPath.append(`, `navigationPath.removeLast(`, and
    `self.selection = ` anywhere under `Views/` — no current file does
    programmatic NavigationStack path mutation or root-tab reassignment at
    all, so these are unambiguous fingerprints for a regression, not a
    general parse of assignment/call expressions.
    """
    banned = ("navigationPath.append(", "navigationPath.removeLast(", "self.selection = ")
    violations = []
    for path, source in files:
        normalized = path.replace(os.sep, "/")
        if "/Views/" not in normalized:
            continue
        stripped = _strip_line_comments(source)
        for needle in banned:
            if needle in stripped:
                violations.append((path, "`%s` found under Views/" % needle))
    return violations


def check_no_frontmost_tab_state_in_view(files):
    """No `@State` declaration anywhere under `iOS/Nostromo/` names a
    frontmost-pane variable locally.

    The frontmost pane must come from `FocusRegionState`, not view-local
    `@State` — the exact shape of today's defect,
    `DynamicFocusView.swift`'s `@State private var selectedTab: String`.
    """
    pattern = re.compile(r"@State\s+(private\s+)?var\s+\w*(selectedTab|activeTab|frontmost)\w*", re.IGNORECASE)
    violations = []
    for path, source in files:
        stripped = _strip_line_comments(source)
        if pattern.search(stripped):
            violations.append((path, "@State declares frontmost-pane-shaped local state"))
    return violations


def check_no_local_placement_or_ratio_persistence(files):
    """iOS must resolve no placement and persist no geometry, ever.

    No file under `iOS/Nostromo/` references `UserDefaults`/`@AppStorage`
    with a key matching `ratio|dynlayout` (case-insensitive substring on the
    string literal argument), and no identifier anywhere under
    `iOS/Nostromo/` matches `evict|tabCap|placement|typeOrder`
    (case-insensitive) — those are macOS's curated-placement-engine
    vocabulary (see `nostromo.show`'s deterministic placement engine),
    which iOS deliberately has no equivalent of.

    `placement` alone would also match SwiftUI's own
    `ToolbarItem(placement:)`/`.toolbar(placement:)` keyword argument, used
    throughout this tree for entirely unrelated toolbar layout and never a
    signal of persisted-geometry logic — those two call shapes are stripped
    out before matching, the same "known-benign shape" carve-out
    `_strip_line_comments` makes for explanatory comments.
    """
    key_call_pattern = re.compile(r"(UserDefaults[^\n]*|@AppStorage\([^)]*\))", re.IGNORECASE)
    key_needle = re.compile(r"ratio|dynlayout", re.IGNORECASE)
    ident_pattern = re.compile(r"evict|tabCap|placement|typeOrder", re.IGNORECASE)
    benign_placement_call = re.compile(r"(ToolbarItem|\.toolbar)\(\s*placement\s*:", re.IGNORECASE)
    violations = []
    for path, source in files:
        stripped = _strip_line_comments(source)
        for m in key_call_pattern.finditer(stripped):
            if key_needle.search(m.group(0)):
                violations.append((
                    path, "UserDefaults/@AppStorage key matching ratio|dynlayout: %s" % m.group(0)
                ))
        ident_source = benign_placement_call.sub("", stripped)
        for m in ident_pattern.finditer(ident_source):
            violations.append((
                path, "identifier matching evict|tabCap|placement|typeOrder: %s" % m.group(0)
            ))
    return violations


def check_unread_glyph_uses_opacity_not_conditional_insertion(files):
    """`Views/Panes/TabStripView.swift` must render its unread indicator via
    a `.opacity(` modifier rather than an `if unread { ... }`/
    `if isUnread { ... }`-conditional view insertion.

    An inserted/removed view retriggers layout of the strip; a fixed view
    whose opacity toggles never does. A missing file counts as a violation
    too — the same `check_ticker_bar_has_fixed_single_line_height` pattern
    for `ActivityTickerBar.swift` when absent: this file doesn't exist yet
    (W5 creates it), so the default empty source naturally fails the
    `.opacity(` check below.
    """
    violations = []
    match = next(((p, s) for p, s in files if os.path.basename(p) == "TabStripView.swift"), None)
    path, source = match if match else ("iOS/Nostromo/Views/Panes/TabStripView.swift", "")

    if ".opacity(" not in source:
        violations.append((path, "TabStripView.swift must render its unread indicator via .opacity("))
    if re.search(r"if\s+(unread|isUnread)\s*\{", source):
        violations.append((
            path, "TabStripView.swift must not use `if unread`/`if isUnread` conditional view insertion"
        ))
    return violations


def check_ticker_survives_the_rewrite(files):
    """`DynamicFocusView.swift` still references `ActivityTickerBar`.

    A guard against the W5 rewrite accidentally dropping the ambient-
    activity ticker wired up in W4 — this passes against today's tree
    already; its job is to keep passing through the rewrite.
    """
    violations = []
    match = next(((p, s) for p, s in files if os.path.basename(p) == "DynamicFocusView.swift"), None)
    path, source = match if match else ("iOS/Nostromo/Views/DynamicFocusView.swift", "")
    if "ActivityTickerBar" not in source:
        violations.append((path, "DynamicFocusView.swift no longer references ActivityTickerBar"))
    return violations



# --------------------------------------------------------------------------
# W6 — ios-curated-view-parity: two presentations, one width test.
#
# Every check below is one this wedge MAKES true, in the suite's standing
# convention that a policy is added by the wedge that satisfies it. They are
# textual heuristics over Swift source, not control-flow proofs — the same
# documented limitation the rest of this file carries — and each has a
# companion bites-test below proving it can actually fail.
# --------------------------------------------------------------------------

#: The complete list of files permitted to name `WidthClass` (or the
#: `nostromoWidthClass` environment key) at all. Explicit rather than a
#: pattern, so ADDING a consumer requires editing this list and therefore
#: noticing. W8 adds `DiffSurfaceView.swift`, the `pr_diff` renderer's
#: container — its file-list-beside-hunks arrangement at regular width is a
#: property of that renderer, not of the region layout, and is the single
#: intended consumer of the published width. Its two leaf views
#: (`DiffFileListView.swift`, `DiffFileContentView.swift`) take identical
#: parameters at both widths and must NOT be on this list. Anything else is
#: the first "just this one thing different on iPad" exception, which is the
#: PRD's stated revisit condition for this whole design.
WIDTH_CLASS_ALLOWLIST = (
    "DynamicFocusView.swift",
    "RegionContainerView.swift",
    "DiffSurfaceView.swift",
)

#: Files that render a region's interior. None may present a sheet.
REGION_INTERIOR_FILES = (
    "RegionContainerView.swift",
    "TabStripView.swift",
    "PaneSurfaceView.swift",
)


def check_nothing_branches_on_the_device(files):
    """No file under `iOS/Nostromo/` references a device, screen, or
    orientation API.

    The presentation is selected by the app's current horizontal width class
    and by nothing else. Both halves of the PRD's rule — "an iPad in a
    narrow multitasking window presents the compact layout" and "a phone
    never presents the regular one" — follow from the size class for free,
    and both break the instant anything else is consulted. This is the check
    that keeps "the width test is the only branch" true over time, which is
    the claim the whole design rests on: every other criterion in the PRD is
    identical in both presentations, and a second branch is what would make
    that stop being so.
    """
    banned = re.compile(
        r"\bUIDevice\b|\buserInterfaceIdiom\b|\bUIScreen\b"
        r"|\bUIInterfaceOrientation\w*\b|\borientation\b|willTransition\(\s*to\b"
    )
    violations = []
    for path, source in files:
        for m in banned.finditer(_strip_line_comments(source)):
            violations.append((path, "device/screen/orientation API referenced: %s" % m.group(0)))
    return violations


def check_horizontal_size_class_read_in_exactly_one_file(files):
    r"""`@Environment(\.horizontalSizeClass)` is declared in exactly one file
    — `DynamicFocusView.swift` — and nowhere else.

    D1: the width is read once, mapped once through `WidthClass`, and passed
    down as a value. A second reader is how the two presentations start
    disagreeing with each other in ways no test can see.

    Setting the value (`.environment(\.horizontalSizeClass, .regular)`) is a
    different act from reading it and is permitted inside the `WidthClass`
    allowlist, where `#Preview` blocks use it to look at the regular
    arrangement during development (D7 forbids a runtime override, not a
    preview).
    """
    read_pattern = re.compile(r"@Environment\(\s*\\\.horizontalSizeClass")
    set_pattern = re.compile(r"\.environment\(\s*\\\.horizontalSizeClass")
    violations = []
    readers = []
    for path, source in files:
        stripped = _strip_line_comments(source)
        name = os.path.basename(path)
        if read_pattern.search(stripped):
            readers.append(name)
            if name != "DynamicFocusView.swift":
                violations.append((path, "%s reads @Environment(\\.horizontalSizeClass) — only DynamicFocusView.swift may" % name))
        # The SET carve-out applies ONLY inside the allowlist. Stripping it
        # unconditionally would quietly let any file publish a width class,
        # which is a second branch by another name.
        residue = read_pattern.sub("", stripped)
        if name in WIDTH_CLASS_ALLOWLIST:
            residue = set_pattern.sub("", residue)
        if "horizontalSizeClass" in residue and name not in WIDTH_CLASS_ALLOWLIST:
            violations.append((path, "%s mentions horizontalSizeClass outside the WidthClass allowlist" % name))
    if "DynamicFocusView.swift" not in readers:
        violations.append((
            "iOS/Nostromo/Views/DynamicFocusView.swift",
            "DynamicFocusView.swift no longer reads @Environment(\\.horizontalSizeClass) — nothing selects the presentation"
        ))
    return violations


def check_width_class_referenced_only_by_the_allowlist(files):
    """`WidthClass` (and the `nostromoWidthClass` environment key that
    carries it) is named only by the files in `WIDTH_CLASS_ALLOWLIST`.

    D8. The width is published downward so that ONE renderer — `pr_diff`,
    in W8 — can rearrange its own two parts when there is room. That is a
    deliberate, bounded exception, and it is bounded by this list rather
    than by good intentions.
    """
    violations = []
    for path, source in files:
        name = os.path.basename(path)
        if name in WIDTH_CLASS_ALLOWLIST:
            continue
        if re.search(r"\bWidthClass\b|\bnostromoWidthClass\b", _strip_line_comments(source)):
            violations.append((path, "%s references WidthClass — not on the allowlist (see WIDTH_CLASS_ALLOWLIST)" % name))
    return violations


def check_no_region_resize_affordance(files):
    """`RegionContainerView.swift` attaches no gesture, and no file under
    `iOS/Nostromo/` persists a split ratio.

    D6, and it is a line rather than an omission. The operator cannot resize
    a region: no drag, no divider handle, no collapse/expand, no locally
    persisted ratio that could diverge from the daemon's. A visible divider
    between two regions is an obvious thing to try to make draggable, so
    this check exists to make adding one a deliberate act. macOS's
    ratio-persistence machinery (`clearSavedRatios`, the
    `nostromo.dynlayout.<tag>.<path>` keys, the split-signature classifier)
    is the hairiest part of its layout code and the parent PRD flagged it as
    a hazard that silently eats the operator's dragged layout; deferring the
    gesture is what keeps the layout decision a pure function of
    (tree, width class), which is what makes it testable without a device.
    """
    violations = []
    match = next(((p, s) for p, s in files if os.path.basename(p) == "RegionContainerView.swift"), None)
    path, source = match if match else ("iOS/Nostromo/Views/Panes/RegionContainerView.swift", "")
    stripped = _strip_line_comments(source)
    if re.search(r"\bDragGesture\b|\.gesture\(|\.simultaneousGesture\(|\bonDrag\b", stripped):
        violations.append((path, "RegionContainerView.swift attaches a gesture — regions are not resizable (D6)"))

    key_call_pattern = re.compile(r"(UserDefaults[^\n]*|@AppStorage\([^)]*\))", re.IGNORECASE)
    key_needle = re.compile(r"ratio|dynlayout|split", re.IGNORECASE)
    for p, s in files:
        for m in key_call_pattern.finditer(_strip_line_comments(s)):
            if key_needle.search(m.group(0)):
                violations.append((p, "persisted layout key matching ratio|dynlayout|split: %s" % m.group(0)))
    return violations


def check_no_sheet_presented_from_inside_a_region(files):
    """None of `RegionContainerView.swift`, `TabStripView.swift`, or
    `PaneSurfaceView.swift` presents a `.sheet(`.

    This is the structural form of two of the wedge's preservation criteria
    — that an open activity surface and a presented decision both survive a
    width-class change. A width change destroys and rebuilds the entire
    region hierarchy; a sheet presented from inside a region goes with it,
    vanishing under the operator mid-rotation. Sheets are presented from
    above that hierarchy (the activity sheet from `DynamicFocusView`, the
    decision surface from the app root) precisely so there is nothing to
    preserve. Asserting the structure is stronger than asserting the
    outcome, because the outcome is only observable on a device.
    """
    by_name = {os.path.basename(p): (p, s) for p, s in files}
    violations = []
    for name in REGION_INTERIOR_FILES:
        entry = by_name.get(name)
        path, source = entry if entry else (name, "")
        if ".sheet(" in _strip_line_comments(source):
            violations.append((path, "%s presents a .sheet( from inside a region — it would vanish on a width-class change" % name))
    return violations


def check_region_container_computes_no_layout_fraction(files):
    """`RegionContainerView.swift` divides space only by the plan's
    `shares`, never by a fraction of its own.

    The layout DECISION is a pure function tested with no device and no
    simulator (`LayoutPlanTests`); this view's job is to obey it. A literal
    fraction appearing in a sizing expression here means some part of the
    arrangement has escaped back into the view, where nothing can check it —
    on the one target in this repo that has no test target at all.

    A heuristic over arithmetic, and a narrow one: it looks for a decimal
    literal strictly between 0 and 1 on a line that also sizes something
    (`.frame(`) or measures the container (`geometry.size`). It will not
    catch a fraction laundered through a named constant, and says so.
    """
    violations = []
    match = next(((p, s) for p, s in files if os.path.basename(p) == "RegionContainerView.swift"), None)
    path, source = match if match else ("iOS/Nostromo/Views/Panes/RegionContainerView.swift", "")
    stripped = _strip_line_comments(source)

    if "shares" not in stripped:
        violations.append((path, "RegionContainerView.swift never references the plan's `shares` — proportions must come from the plan"))

    fraction = re.compile(r"0\.\d+")
    for line in stripped.splitlines():
        if ".frame(" not in line and "geometry.size" not in line:
            continue
        for m in fraction.finditer(line):
            if 0 < float(m.group(0)) < 1:
                violations.append((path, "layout fraction literal in a sizing expression: %s" % line.strip()))
    return violations


def check_no_scroll_restore_key_in_view_state(files):
    """No `@State` under `iOS/Nostromo/` holds a durable scroll-restore key.

    W5's `check_no_frontmost_tab_state_in_view` companion, for the other
    half of what must survive a width-class change. A width change destroys
    the view hierarchy, so anything the transition needs to preserve cannot
    live in it: the frontmost tab and unread marks live in
    `FocusRegionState`, and the scroll-restore key lives in `DaemonStore`.
    View-local tracking of what is *currently* on screen is fine and
    expected — that is not state anyone is trying to preserve — so this
    matches only the saved-key vocabulary.
    """
    pattern = re.compile(
        r"@State\s+(private\s+)?var\s+\w*(scrollKey|savedScroll|scrollRestore|restoreKey)\w*",
        re.IGNORECASE,
    )
    violations = []
    for path, source in files:
        if pattern.search(_strip_line_comments(source)):
            violations.append((path, "@State holds a durable scroll-restore key — it must come from DaemonStore"))
    return violations


def check_region_container_reuses_the_shared_tab_strip(files):
    """`RegionContainerView.swift` renders a tabbed region with
    `TabStripView`, the same view the compact strip uses.

    The width test is the only branch: a region's strip is not a second,
    iPad-only strip that could drift from the phone's in labels, unread
    marks, or `reason` captions. W5 parameterised `TabStripView` by region
    for exactly this, so "each tabbed region has its own tab strip and its
    own frontmost tab" is one view instantiated per region rather than a
    parallel implementation.
    """
    violations = []
    match = next(((p, s) for p, s in files if os.path.basename(p) == "RegionContainerView.swift"), None)
    path, source = match if match else ("iOS/Nostromo/Views/Panes/RegionContainerView.swift", "")
    if "TabStripView(" not in _strip_line_comments(source):
        violations.append((path, "RegionContainerView.swift does not instantiate TabStripView — a region's strip must be the same view the compact strip uses"))
    return violations


# --------------------------------------------------------------------------
# ios-curated-view-parity W7 — the `code` surface
# --------------------------------------------------------------------------

#: `PerriView.swift` truncates its own raw diff at 4000 characters/60 lines
#: (D8) — a different, deferred surface, excluded by name from the
#: no-truncation check below rather than fixed here.
CODE_SURFACE_TRUNCATION_EXCLUDED_FILES = ("PerriView.swift",)


def _code_surface_entry(files):
    match = next(((p, s) for p, s in files if os.path.basename(p) == "CodeSurfaceView.swift"), None)
    return match if match else ("iOS/Nostromo/Views/Panes/CodeSurfaceView.swift", "")


def check_code_surface_no_truncation(files):
    """`CodeSurfaceView.swift` truncates nothing: no `prefix(`, no numeric
    row cap on its `ForEach`, and no `lineLimit(` in the row that renders a
    line's text.

    D8: unlike `PerriView.swift`'s raw diff (truncated at 4000 characters
    and 60 lines — a different, deferred surface, excluded here by name, not
    fixed), a large file relies on `LazyVStack`'s own laziness rather than a
    cap. The `lineLimit(` check is scoped to the file's `codeRow` function
    rather than the whole file, because the header legitimately applies
    `lineLimit(1)` to the path label (D6) — that is a one-line header, not
    the content column this criterion is about.
    """
    path, source = _code_surface_entry(files)
    if os.path.basename(path) in CODE_SURFACE_TRUNCATION_EXCLUDED_FILES:
        return []
    stripped = _strip_line_comments(source)
    violations = []

    if re.search(r"\.prefix\(", stripped):
        violations.append((path, "CodeSurfaceView.swift calls .prefix( — no truncation of any kind is permitted (D8)"))

    if re.search(r"ForEach\(\s*0\s*\.\.<\s*\d+", stripped):
        violations.append((path, "CodeSurfaceView.swift's row ForEach is bounded by a numeric literal — rows must come from the document, not a cap"))

    for span in _spans_after(stripped, r"func\s+codeRow\("):
        if "lineLimit(" in span:
            violations.append((path, "codeRow(...) applies lineLimit( to the content column"))

    return violations


def check_code_surface_no_horizontal_panning(files):
    """`CodeSurfaceView.swift` never scrolls horizontally.

    A long line wraps (D3); a phone user two-finger-panning a code view is
    worse than a wrapped line, so there is no `ScrollView(.horizontal` and no
    `axes: .horizontal` anywhere in this file.
    """
    path, source = _code_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    if re.search(r"ScrollView\(\s*\.horizontal", stripped):
        violations.append((path, "CodeSurfaceView.swift contains ScrollView(.horizontal"))
    if re.search(r"axes\s*:\s*\.horizontal", stripped):
        violations.append((path, "CodeSurfaceView.swift sets axes: .horizontal"))
    return violations


def check_code_surface_gutter_top_aligned_wrapping_column(files):
    """`CodeSurfaceView.swift` renders each row as an `HStack(alignment:
    .top` with no `lineLimit` on the line text (D3).

    This is the mechanism, not just a style choice: a top-aligned gutter
    cell beside a freely-wrapping text column is what puts a wrapped line's
    number beside its first visual line and leaves the rest of the gutter
    blank, structurally, with no fragment-counting arithmetic (contrast
    macOS's `LineNumberRulerView.drawHashMarksAndLabels`).
    """
    path, source = _code_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    if not re.search(r"HStack\(\s*alignment:\s*\.top", stripped):
        violations.append((path, "CodeSurfaceView.swift has no HStack(alignment: .top — the gutter/wrap mechanism (D3)"))
    for span in _spans_after(stripped, r"func\s+codeRow\("):
        if "lineLimit(" in span:
            violations.append((path, "codeRow(...) applies lineLimit( — a wrapped line must stay fully readable"))
    return violations


def check_code_surface_scroll_only_via_decision(files):
    """Every `scrollTo(` call in `CodeSurfaceView.swift` sits inside a `case
    .scrollTo` arm — never called unconditionally.

    Ported from macOS's `CodeContentViewTests.
    testCodeContentViewConsultsScrollDecisionAndOnlyScrollsFromTheScrollToBranch`,
    broadened to accept either of the two decision types this surface
    legitimately consults: `ScrollDecision` (an anchor arriving) and
    `ScrollRestore` (a saved position being restored after a width-class
    rebuild — a case macOS has no analogue of, since it has only one
    presentation). Both share the identical `.scrollTo(target:)` case and
    the identical discipline: a scroll is a decision, never a bare call.
    """
    path, source = _code_surface_entry(files)
    stripped = _strip_line_comments(source)
    lines = stripped.splitlines()
    violations = []
    for i, line in enumerate(lines):
        if not re.search(r"\bscrollTo\(", line):
            continue
        if re.search(r"case\s+(let\s+)?\.scrollTo", line):
            continue  # this line is the case pattern itself, not a call
        window = lines[max(0, i - 5):i + 1]
        if not any(re.search(r"case\s+(let\s+)?\.scrollTo", w) for w in window):
            violations.append((path, "scrollTo( call not gated by a `case .scrollTo` pattern: %s" % line.strip()))
    return violations


def check_code_surface_no_rebuild_on_address_change(files):
    """No `.id(` expression in `CodeSurfaceView.swift` references `address`,
    `anchor`, or `emphasis` (D5).

    The surface's SwiftUI identity must not include the address — an
    address-only push (a re-anchor/re-mark) must never force a rebuild of
    the document, the row views, or their scroll position. Ported from
    macOS's `CodeContentViewTests.
    testCodeContentViewNeverTearsDownItsScrollOrTextViewOnUpdate` (the same
    property, checked there by asserting `scrollView.documentView` is
    assigned exactly once, in `init`).
    """
    path, source = _code_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    # `\w*` after each root, case-insensitive: a careless `.id(anchorResolution)`
    # or `.id(emphasisResolution)` is exactly as much a rebuild trigger as a
    # bare `.id(address)`, and must not slip past a check anchored only to
    # the exact identifier.
    banned = re.compile(r"\b(address|anchor|emphasis)\w*", re.IGNORECASE)
    for call in _balanced_call_args(stripped, r"\.id\("):
        if banned.search(call):
            violations.append((path, ".id(...) expression references address/anchor/emphasis: %s" % call))
    return violations


def check_code_surface_renders_every_resolution_case(files):
    """Every `AnchorResolution` and `EmphasisResolution` case name is
    referenced somewhere in `CodeSurfaceView.swift`.

    Paired with the L1 exhaustive-case switches in `AnchorResolutionTests`:
    an added case fails to compile in `CodeDocument.resolve` (no `default:`)
    AND is invisible here until this file is updated, so both ends of "an
    added case cannot be silently ignored" are covered.
    """
    path, source = _code_surface_entry(files)
    stripped = _strip_line_comments(source)
    required = (".notRequested", ".resolved", ".unresolved", ".none", ".rows", ".matchedNothing")
    violations = []
    for case_name in required:
        if case_name not in stripped:
            violations.append((path, "case %s is never referenced in CodeSurfaceView.swift" % case_name))
    return violations


def check_code_surface_no_syntax_highlighting(files):
    """`CodeSurfaceView.swift` builds no `AttributedString` and references no
    highlighter dependency.

    D8: macOS does not highlight either, and the wire type reserves room for
    it. Not here, on either client.
    """
    path, source = _code_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    if "AttributedString(" in stripped:
        violations.append((path, "CodeSurfaceView.swift constructs an AttributedString — no syntax highlighting (D8)"))
    if re.search(r"\bsyntect\b", stripped, re.IGNORECASE):
        violations.append((path, "CodeSurfaceView.swift references a highlighter dependency — no syntax highlighting (D8)"))
    return violations


# --------------------------------------------------------------------------
# ios-curated-view-parity W8 — the `pr_diff` surface
# --------------------------------------------------------------------------

#: The three new W8 view files, in the order the plan introduces them:
#: the width-arranging container, the file list, and the anchored file
#: content. `WIDTH_CLASS_ALLOWLIST` above names only the first of these —
#: the other two take identical parameters at both widths.
DIFF_SURFACE_FILES = ("DiffSurfaceView.swift", "DiffFileListView.swift", "DiffFileContentView.swift")


def _diff_surface_entry(files, name):
    """Look up one of `DIFF_SURFACE_FILES` by name, the same shape
    `_code_surface_entry` uses for `CodeSurfaceView.swift` — a sensible
    default path is returned when the file doesn't exist yet, so a check
    against a not-yet-created file fails loudly (its default empty source
    trips the check) rather than passing vacuously.
    """
    match = next(((p, s) for p, s in files if os.path.basename(p) == name), None)
    return match if match else ("iOS/Nostromo/Views/Panes/%s" % name, "")


def check_diff_surface_no_truncation(files):
    """None of `DiffSurfaceView.swift`/`DiffFileListView.swift`/
    `DiffFileContentView.swift` truncates: no `.prefix(`, no numeric row cap
    on a `ForEach`, and — scoped only within `DiffFileContentView.swift`'s
    `func row(` span — no `lineLimit(`.

    D6: "the diff is not truncated to a fixed line or character budget",
    the same criterion W7 established for `file`
    (`check_code_surface_no_truncation`), now covering `pr_diff`'s three
    files; `PerriView.swift`'s doubly-clipped raw diff
    (`CODE_SURFACE_TRUNCATION_EXCLUDED_FILES`) stays the one deferred,
    excluded-by-name exception (D6, D8). `DiffFileListView.swift`
    legitimately truncates its own path label with `lineLimit(1)` (D7: "the
    path, truncated from the leading end so the filename survives") — that
    is a one-line label, not the hunk content this criterion is about, so
    the `lineLimit(` ban is scoped to `DiffFileContentView.swift`'s
    row-building function (`func row(`) rather than applied file-wide, the
    same scoping `check_code_surface_no_truncation` applies to `codeRow`.
    """
    violations = []
    for name in DIFF_SURFACE_FILES:
        path, source = _diff_surface_entry(files, name)
        stripped = _strip_line_comments(source)

        if re.search(r"\.prefix\(", stripped):
            violations.append((path, "%s calls .prefix( — no truncation of any kind is permitted (D6)" % name))

        if re.search(r"ForEach\(\s*0\s*\.\.<\s*\d+", stripped):
            violations.append((
                path,
                "%s's row ForEach is bounded by a numeric literal — rows must come from the document, not a cap" % name
            ))

        if name == "DiffFileContentView.swift":
            for span in _spans_after(stripped, r"func\s+row\("):
                if "lineLimit(" in span:
                    violations.append((path, "row(...) applies lineLimit( to hunk content"))

    return violations


def check_diff_surface_no_horizontal_panning(files):
    """None of the three `pr_diff` surface files scrolls horizontally.

    Hunk lines wrap, same as `file` (W7's
    `check_code_surface_no_horizontal_panning`, generalized here to iterate
    all three files): no `ScrollView(.horizontal` and no `axes: .horizontal`
    anywhere in `DiffSurfaceView.swift`/`DiffFileListView.swift`/
    `DiffFileContentView.swift`.
    """
    violations = []
    for name in DIFF_SURFACE_FILES:
        path, source = _diff_surface_entry(files, name)
        stripped = _strip_line_comments(source)
        if re.search(r"ScrollView\(\s*\.horizontal", stripped):
            violations.append((path, "%s contains ScrollView(.horizontal" % name))
        if re.search(r"axes\s*:\s*\.horizontal", stripped):
            violations.append((path, "%s sets axes: .horizontal" % name))
    return violations


def check_diff_content_uses_shared_code_row(files):
    """`DiffFileContentView.swift` renders its rows through `CodeRowView(` —
    the view W8 extracts from `CodeSurfaceView.swift` — rather than
    reimplementing the gutter/wrapping mechanism a second time.

    This is the check that keeps `file` and `pr_diff` from drifting: the
    gutter, wrapping, and marking rules are one view instantiated twice, not
    two views that merely look alike today and diverge tomorrow.
    """
    path, source = _diff_surface_entry(files, "DiffFileContentView.swift")
    stripped = _strip_line_comments(source)
    violations = []
    if "CodeRowView(" not in stripped:
        violations.append((
            path,
            "DiffFileContentView.swift does not reference CodeRowView( — rows must go through the shared row view, not a second implementation"
        ))
    return violations


def check_diff_scroll_only_via_decision(files):
    """Every `scrollTo(` call in `DiffFileContentView.swift` sits inside a
    `case .scrollTo` arm — never called unconditionally.

    Mirrors `check_code_surface_scroll_only_via_decision`'s line-window logic
    exactly, pointed at `DiffFileContentView.swift` instead of
    `CodeSurfaceView.swift`: a scroll is a decision (`ScrollDecision` for an
    arriving anchor, `ScrollRestore` for a saved position being restored),
    never a bare call.
    """
    path, source = _diff_surface_entry(files, "DiffFileContentView.swift")
    stripped = _strip_line_comments(source)
    lines = stripped.splitlines()
    violations = []
    for i, line in enumerate(lines):
        if not re.search(r"\bscrollTo\(", line):
            continue
        if re.search(r"case\s+(let\s+)?\.scrollTo", line):
            continue  # this line is the case pattern itself, not a call
        window = lines[max(0, i - 5):i + 1]
        if not any(re.search(r"case\s+(let\s+)?\.scrollTo", w) for w in window):
            violations.append((path, "scrollTo( call not gated by a `case .scrollTo` pattern: %s" % line.strip()))
    return violations


def check_diff_no_line_resolution_reimplemented(files):
    """No file under `iOS/Nostromo` compares `newN`/`oldN` with a comparison
    operator.

    Memo B10 as a policy, scanning every file in `files` (the whole
    `iOS/Nostromo` tree, not just the three W8 files) rather than one named
    file: line-resolution arithmetic belongs only to
    `DiffDocument`/`DiffAddressing` (NostromoKit), never reimplemented in a
    view — the exact defect class an independent implementation of "which
    number does the gutter show" would reintroduce. A plain nil-coalescing
    read like `row.newN ?? row.oldN` (the gutter's own new-or-old display
    precedence, D5) is not comparison arithmetic and must not trip this —
    only `==`/`!=`/`<=`/`>=`/`<`/`>` immediately adjacent to one of the two
    identifiers, in either operand position, case-sensitive on the
    identifiers themselves.
    """
    pattern = re.compile(
        r"\b(newN|oldN)\b\s*(==|!=|<=|>=|<|>)|(==|!=|<=|>=|<|>)\s*\b(newN|oldN)\b"
    )
    violations = []
    for path, source in files:
        stripped = _strip_line_comments(source)
        if pattern.search(stripped):
            violations.append((
                path,
                "newN/oldN compared with a comparison operator — line resolution belongs to DiffDocument/DiffAddressing, not the view"
            ))
    return violations


def check_diff_selected_file_not_view_state(files):
    """None of the three `pr_diff` surface files declares `@State` holding
    the selected file locally.

    D2: the selected file is not view state — it lives in
    `FocusRegionState` (the `selectedFile`/`setSelectedFile` slot), the same
    reasoning W5's `check_no_frontmost_tab_state_in_view` applies to the
    frontmost tab, so a width-class rebuild (which destroys the view
    hierarchy) does not drop which file was open.
    """
    pattern = re.compile(r"@State[^\n]*\b(selectedFile|currentFile)\b", re.IGNORECASE)
    violations = []
    for name in DIFF_SURFACE_FILES:
        path, source = _diff_surface_entry(files, name)
        stripped = _strip_line_comments(source)
        if pattern.search(stripped):
            violations.append((
                path,
                "%s declares @State holding the selected file locally — it must come from FocusRegionState" % name
            ))
    return violations


def check_diff_renders_every_resolution_case(files):
    """Every `AnchorResolution` and `EmphasisResolution` case name is
    referenced somewhere in `DiffSurfaceView.swift`.

    Mirrors `check_code_surface_renders_every_resolution_case`, pointed at
    the diff surface's container: paired with the L1 exhaustive-case
    switches in `DiffAddressingTests`, an added case fails to compile in
    `DiffDocument.resolve` (no `default:`) AND is invisible here until this
    file is updated, so both ends of "an added case cannot be silently
    ignored" are covered.
    """
    path, source = _diff_surface_entry(files, "DiffSurfaceView.swift")
    stripped = _strip_line_comments(source)
    required = (".notRequested", ".resolved", ".unresolved", ".none", ".rows", ".matchedNothing")
    violations = []
    for case_name in required:
        if case_name not in stripped:
            violations.append((path, "case %s is never referenced in DiffSurfaceView.swift" % case_name))
    return violations


def check_diff_toolarge_notice_not_one_row_among_many(files):
    """`DiffSurfaceView.swift` contains the substring `tooLarge`.

    D4: a gated diff has no rows, and a view that renders an empty file list
    is indistinguishable from a PR that changes nothing — so the surface
    must branch on `tooLarge` before rendering a list at all. This is an
    honest heuristic, in the same spirit as this file's other
    existence-only checks (e.g. `check_ticker_survives_the_rewrite`): it
    only proves the branch exists, not that it is structured correctly (that
    the notice truly replaces the list rather than merely decorating it) —
    that half is a manual-verification item, not something a text scan can
    prove.
    """
    path, source = _diff_surface_entry(files, "DiffSurfaceView.swift")
    violations = []
    if "tooLarge" not in source:
        violations.append((
            path,
            "DiffSurfaceView.swift never references tooLarge — a gated diff must be rendered as its own notice, not an empty file list"
        ))
    return violations


# --------------------------------------------------------------------------
# ios-curated-view-parity W9 — the `pr_conversation`/`ticket` prose surface
# --------------------------------------------------------------------------
#
# `ProseSurfaceView.swift` is the one iOS-side file for this wedge — the
# platform-neutral row model and the two payload adapters
# (`ConversationPlan`/`TicketPlan`) live in `Shared/NostromoKit/Sources/
# NostromoKit/Prose/`, out of this suite's remit (see `_ios_swift_files`'s
# own docstring: Shared/ has its own L1 coverage — `ProsePlanTests`,
# `ConversationPlanTests`, `TicketPlanTests`, `ProseAddressingTests`). Every
# check below is therefore scoped to the one view file this suite can see,
# in the same existence-only spirit as `check_diff_toolarge_notice_not_one_row_among_many`
# where a check can only prove a branch exists, not that Shared-side data
# actually reaches it — that link is what L1 proves instead.

def _prose_surface_entry(files):
    match = next(((p, s) for p, s in files if os.path.basename(p) == "ProseSurfaceView.swift"), None)
    return match if match else ("iOS/Nostromo/Views/Panes/ProseSurfaceView.swift", "")


def check_prose_surface_reads_no_width_class(files):
    """`ProseSurfaceView.swift` never mentions `WidthClass` or
    `horizontalSizeClass`.

    D7: prose is the same prose at both widths. `pr_diff`
    (`DiffSurfaceView.swift`) remains the only renderer on
    `WIDTH_CLASS_ALLOWLIST` (memo B9) — this check is a dedicated,
    wedge-specific pin on top of the generic
    `check_width_class_referenced_only_by_the_allowlist`, which would also
    catch this, so a regression here is reported by name rather than only
    by the generic allowlist check.
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    if re.search(r"\bWidthClass\b|\bnostromoWidthClass\b", stripped):
        violations.append((path, "ProseSurfaceView.swift references WidthClass — prose is identical at both widths"))
    if "horizontalSizeClass" in stripped:
        violations.append((path, "ProseSurfaceView.swift references horizontalSizeClass — prose is identical at both widths"))
    return violations


def check_prose_surface_no_truncation(files):
    """`ProseSurfaceView.swift` truncates nothing: no `.prefix(`, no numeric
    row cap on its row `ForEach`, and no `lineLimit(` inside the function
    that renders a code block.

    D6: a long paragraph or fenced code block wraps and stays fully
    readable, relying on `LazyVStack`'s own laziness rather than a cap — the
    same rule `check_code_surface_no_truncation`/`check_diff_surface_no_truncation`
    enforce for `file`/`pr_diff`. The `lineLimit(` check is scoped to
    `codeBlockView(...)` rather than the whole file because the document
    header legitimately applies `lineLimit(1)` to its one-line url — the
    same carve-out those two checks make for their own path labels.
    `PerriView.swift` is excluded by construction: this check only ever
    looks at `ProseSurfaceView.swift`.
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []

    if re.search(r"\.prefix\(", stripped):
        violations.append((path, "ProseSurfaceView.swift calls .prefix( — no truncation of any kind is permitted"))

    if re.search(r"ForEach\(\s*0\s*\.\.<\s*\d+", stripped):
        violations.append((path, "ProseSurfaceView.swift's row ForEach is bounded by a numeric literal — rows must come from the plan, not a cap"))

    for span in _spans_after(stripped, r"func\s+codeBlockView\("):
        if "lineLimit(" in span:
            violations.append((path, "codeBlockView(...) applies lineLimit( to code block content"))

    return violations


def check_prose_surface_no_horizontal_panning(files):
    """`ProseSurfaceView.swift` never scrolls horizontally.

    Code blocks wrap instead (D6), the same rule `file`/`pr_diff` follow: no
    `ScrollView(.horizontal` and no `axes: .horizontal` anywhere in this
    file.
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    if re.search(r"ScrollView\(\s*\.horizontal", stripped):
        violations.append((path, "ProseSurfaceView.swift contains ScrollView(.horizontal"))
    if re.search(r"axes\s*:\s*\.horizontal", stripped):
        violations.append((path, "ProseSurfaceView.swift sets axes: .horizontal"))
    return violations


def check_prose_surface_scroll_only_via_decision(files):
    """Every `scrollTo(` call in `ProseSurfaceView.swift` sits inside a
    `case .scrollTo` arm — never called unconditionally.

    Mirrors `check_code_surface_scroll_only_via_decision`/
    `check_diff_scroll_only_via_decision`: this surface consults both
    `ScrollDecision` (a resolved anchor arriving) and `ScrollRestore` (a
    saved position being restored after a width-class rebuild), and both
    share the identical `.scrollTo(target:)` case and the identical
    discipline — a scroll is a decision, never a bare call.
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    lines = stripped.splitlines()
    violations = []
    for i, line in enumerate(lines):
        if not re.search(r"\bscrollTo\(", line):
            continue
        if re.search(r"case\s+(let\s+)?\.scrollTo", line):
            continue  # this line is the case pattern itself, not a call
        window = lines[max(0, i - 5):i + 1]
        if not any(re.search(r"case\s+(let\s+)?\.scrollTo", w) for w in window):
            violations.append((path, "scrollTo( call not gated by a `case .scrollTo` pattern: %s" % line.strip()))
    return violations


def check_prose_surface_thread_metadata_rendered(files):
    """`ProseSurfaceView.swift` references a thread's `resolved`, `path` and
    `line` fields.

    The anti-`MarkdownBlockDocument` policy: macOS decodes
    `ConversationThreadModel.kind`/`path`/`line`/`diffHunk`/`resolved` and
    reads none of them (`MarkdownBlockDocument.swift:29-58`) — an inline
    review comment renders identically to a general PR comment there. This
    check exists so that regression can't happen quietly here too.
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    for field in ("resolved", "path", "line"):
        if field not in stripped:
            violations.append((path, "ProseSurfaceView.swift never references thread.%s — thread metadata would be discarded, the macOS defect this wedge exists to not repeat" % field))
    return violations


def check_conversation_error_notice_is_rendered(files):
    """`ProseSurfaceView.swift` renders the `conversationError` notice case.

    D3, the PRD's forbidden state in its purest form: a partial conversation
    must never be presented as a complete one. `ConversationPlan` (Shared/
    NostromoKit — out of this suite's remit) emits a
    `.notice(.conversationIncomplete(reason:))` row exactly when the
    daemon's `conversation_error` was set, covered at L1 by
    `ConversationPlanTests`'s "renders when set" / "renders nothing when
    absent" pair; this is the client-side half — an existence-only check,
    in the same spirit as `check_diff_toolarge_notice_not_one_row_among_many`,
    that the view actually renders that case rather than silently dropping
    it.
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    if "conversationIncomplete" not in stripped:
        violations.append((path, "ProseSurfaceView.swift never renders .conversationIncomplete — conversationError would be silently dropped, exactly like macOS"))
    return violations


def check_prose_surface_renders_every_resolution_case(files):
    """Every `AnchorResolution` and `EmphasisResolution` case name is
    referenced somewhere in `ProseSurfaceView.swift`.

    Mirrors `check_code_surface_renders_every_resolution_case`/
    `check_diff_renders_every_resolution_case`: paired with the L1
    exhaustive-case switches in `ProseAddressingTests`, an added case fails
    to compile in `ConversationPlan.resolve`/`TicketPlan.resolve` (no
    `default:`) AND is invisible here until this file is updated, so both
    ends of "an added case cannot be silently ignored" are covered.
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    required = (".notRequested", ".resolved", ".unresolved", ".none", ".rows", ".matchedNothing")
    violations = []
    for case_name in required:
        if case_name not in stripped:
            violations.append((path, "case %s is never referenced in ProseSurfaceView.swift" % case_name))
    return violations


def check_no_client_side_markdown_parsing(files):
    """No `.swift` file under `iOS/` parses markdown itself: no
    `AttributedString(markdown:`, and no manual backtick or `#`-prefix
    scanning.

    The parent PRD's B5: the daemon parses markdown with `pulldown-cmark`
    and sends structured `MdBlock`/`MdSpan` trees; the client renders them
    dumbly. A second parser on the client — even a small one, reached for
    to "just handle this one case" — is exactly the disagreeing-renderers
    problem this PRD family exists to end. Scoped to the whole `iOS/` tree,
    not just the prose surface: this is a standing prohibition, not a
    property of one file.
    """
    violations = []
    backtick_scan = re.compile(r'hasPrefix\(\s*"`"|hasSuffix\(\s*"`"|contains\(\s*"```"')
    heading_scan = re.compile(r'hasPrefix\(\s*"#"')
    for path, source in files:
        stripped = _strip_line_comments(source)
        if "AttributedString(markdown:" in stripped:
            violations.append((path, "%s constructs AttributedString(markdown:) — the daemon parses markdown, not the client" % os.path.basename(path)))
        if backtick_scan.search(stripped):
            violations.append((path, "%s manually scans for backticks — markdown parsing belongs to the daemon" % os.path.basename(path)))
        if heading_scan.search(stripped):
            violations.append((path, "%s manually scans for a '#' heading prefix — markdown parsing belongs to the daemon" % os.path.basename(path)))
    return violations


def check_lang_not_discarded_in_prose_surface(files):
    """`ProseSurfaceView.swift` never discards a code block's `lang`.

    D6: `lang` is retained even though syntax highlighting is out of scope
    on both clients — the assertion macOS's `_ = lang`
    (`MarkdownBlockDocument.swift:233`) fails. Bans both the exact shape
    macOS uses (an explicit discard statement) and the client-side
    equivalent (a `.codeBlock` case pattern that never binds `lang` at all,
    which would discard it just as completely at the pattern match).
    """
    path, source = _prose_surface_entry(files)
    stripped = _strip_line_comments(source)
    violations = []
    if re.search(r"_\s*=\s*lang\b", stripped):
        violations.append((path, "ProseSurfaceView.swift discards lang via `_ = lang` — the exact macOS defect this wedge (D6) must not repeat"))
    if re.search(r"\.codeBlock\(\s*_\s*,", stripped):
        violations.append((path, "ProseSurfaceView.swift's .codeBlock case pattern never binds lang — it is discarded at the match"))
    return violations


CHECKS = (
    check_no_default_in_panecontentwire_switch,
    check_every_toRowModel_call_passes_marked,
    check_payload_text_only_inside_codedocument_construction,
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
    check_no_pane_id_visible_via_capitalized,
    check_no_second_bottom_tab_bar,
    check_no_root_tab_hijack,
    check_no_frontmost_tab_state_in_view,
    check_no_local_placement_or_ratio_persistence,
    check_unread_glyph_uses_opacity_not_conditional_insertion,
    check_ticker_survives_the_rewrite,
    check_nothing_branches_on_the_device,
    check_horizontal_size_class_read_in_exactly_one_file,
    check_width_class_referenced_only_by_the_allowlist,
    check_no_region_resize_affordance,
    check_no_sheet_presented_from_inside_a_region,
    check_region_container_computes_no_layout_fraction,
    check_no_scroll_restore_key_in_view_state,
    check_region_container_reuses_the_shared_tab_strip,
    check_code_surface_no_truncation,
    check_code_surface_no_horizontal_panning,
    check_code_surface_gutter_top_aligned_wrapping_column,
    check_code_surface_scroll_only_via_decision,
    check_code_surface_no_rebuild_on_address_change,
    check_code_surface_renders_every_resolution_case,
    check_code_surface_no_syntax_highlighting,
    check_diff_surface_no_truncation,
    check_diff_surface_no_horizontal_panning,
    check_diff_content_uses_shared_code_row,
    check_diff_scroll_only_via_decision,
    check_diff_no_line_resolution_reimplemented,
    check_diff_selected_file_not_view_state,
    check_diff_renders_every_resolution_case,
    check_diff_toolarge_notice_not_one_row_among_many,
    check_prose_surface_reads_no_width_class,
    check_prose_surface_no_truncation,
    check_prose_surface_no_horizontal_panning,
    check_prose_surface_scroll_only_via_decision,
    check_prose_surface_thread_metadata_rendered,
    check_conversation_error_notice_is_rendered,
    check_prose_surface_renders_every_resolution_case,
    check_no_client_side_markdown_parsing,
    check_lang_not_discarded_in_prose_surface,
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


class PayloadTextOnlyInsideCodeDocumentConstructionTests(unittest.TestCase):
    def test_bites_on_a_direct_render_of_the_raw_text(self):
        source = "ScrollView { textView(payload.text) }"
        violations = check_payload_text_only_inside_codedocument_construction([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_absent(self):
        source = "ScrollView { textView(text) }"
        self.assertEqual(check_payload_text_only_inside_codedocument_construction([("Synthetic.swift", source)]), [])

    def test_passes_when_inside_a_codedocument_construction(self):
        source = "let document = CodeDocument(path: p, revision: r, firstLine: 1, text: payload.text)"
        self.assertEqual(check_payload_text_only_inside_codedocument_construction([("Synthetic.swift", source)]), [])

    def test_ignores_a_comment_naming_the_deleted_dump(self):
        source = "// W2 deleted the raw payload.text dump; W7 replaced it with CodeSurfaceView."
        self.assertEqual(check_payload_text_only_inside_codedocument_construction([("Synthetic.swift", source)]), [])


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


class NoPaneIdVisibleViaCapitalizedTests(unittest.TestCase):
    def test_bites_on_capitalized_called_directly_on_paneid(self):
        source = ".tabItem { Label(paneId.capitalized, systemImage: \"rectangle.split.2x1\") }"
        violations = check_no_pane_id_visible_via_capitalized([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_capitalized_called_on_selectedtab(self):
        source = ".navigationTitle(selectedTab == \"repl\" ? displayName : selectedTab.capitalized)"
        violations = check_no_pane_id_visible_via_capitalized([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_text_interpolating_a_bare_paneid(self):
        source = 'Text("\\(paneId)")'
        violations = check_no_pane_id_visible_via_capitalized([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_label_interpolating_paneid_capitalized(self):
        # This source also happens to trip the `.capitalized`-on-paneId rule
        # (both are real, independent violations of the same policy) — assert
        # at least one violation, and that the interpolation-specific message
        # is among them, rather than pin an exact count coupled to overlap
        # between the two heuristics.
        source = 'Label("\\(paneId.capitalized)", systemImage: "doc")'
        violations = check_no_pane_id_visible_via_capitalized([("Synthetic.swift", source)])
        self.assertTrue(len(violations) >= 1)
        self.assertTrue(any("interpolates a bare paneId" in msg for _, msg in violations))

    def test_passes_when_the_label_comes_from_tab_plan_metadata(self):
        source = '.tabItem { Label(entry.label, systemImage: "rectangle.split.2x1") }'
        self.assertEqual(check_no_pane_id_visible_via_capitalized([("Synthetic.swift", source)]), [])

    def test_ignores_unrelated_capitalized_calls(self):
        source = 'Text(displayName.capitalized)'
        self.assertEqual(check_no_pane_id_visible_via_capitalized([("Synthetic.swift", source)]), [])


class NoSecondBottomTabBarTests(unittest.TestCase):
    def test_bites_on_tabview_under_views(self):
        source = "TabView(selection: $selectedTab) { EmptyView() }"
        violations = check_no_second_bottom_tab_bar([("iOS/Nostromo/Views/DynamicFocusView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_tabitem_under_views(self):
        source = '.tabItem { Label("Repl", systemImage: "terminal") }'
        violations = check_no_second_bottom_tab_bar([("iOS/Nostromo/Views/Panes/TabStripView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_ignores_tabview_in_nostromoapp(self):
        source = "TabView(selection: $selection) { EmptyView() }"
        violations = check_no_second_bottom_tab_bar([("iOS/Nostromo/NostromoApp.swift", source)])
        self.assertEqual(violations, [])

    def test_ignores_files_outside_views(self):
        source = "TabView(selection: $selectedTab) { EmptyView() }"
        violations = check_no_second_bottom_tab_bar([("iOS/Nostromo/SomeHelper.swift", source)])
        self.assertEqual(violations, [])

    def test_passes_on_a_clean_views_file(self):
        source = "struct DynamicFocusView: View { var body: some View { EmptyView() } }"
        self.assertEqual(
            check_no_second_bottom_tab_bar([("iOS/Nostromo/Views/DynamicFocusView.swift", source)]), []
        )


class NoRootTabHijackTests(unittest.TestCase):
    def test_bites_on_navigation_path_append(self):
        source = "navigationPath.append(PaneRoute.detail)"
        violations = check_no_root_tab_hijack([("iOS/Nostromo/Views/DynamicFocusView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_navigation_path_removelast(self):
        source = "navigationPath.removeLast()"
        violations = check_no_root_tab_hijack([("iOS/Nostromo/Views/DynamicFocusView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_self_selection_assignment(self):
        source = "self.selection = .queue"
        violations = check_no_root_tab_hijack([("iOS/Nostromo/Views/DynamicFocusView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_ignores_files_outside_views(self):
        source = "self.selection = .queue"
        violations = check_no_root_tab_hijack([("iOS/Nostromo/NostromoApp.swift", source)])
        self.assertEqual(violations, [])

    def test_passes_on_clean_source(self):
        source = "store.selectPane(tag: tag, regionPath: region, paneId: entry.paneId)"
        self.assertEqual(
            check_no_root_tab_hijack([("iOS/Nostromo/Views/DynamicFocusView.swift", source)]), []
        )


class NoFrontmostTabStateInViewTests(unittest.TestCase):
    def test_bites_on_selectedtab_state(self):
        source = '@State private var selectedTab: String = "repl"'
        violations = check_no_frontmost_tab_state_in_view([("iOS/Nostromo/Views/DynamicFocusView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_activetab_state(self):
        source = "@State var activeTabId: String = \"repl\""
        violations = check_no_frontmost_tab_state_in_view([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_frontmost_state(self):
        source = "@State private var frontmostPaneId: String? = nil"
        violations = check_no_frontmost_tab_state_in_view([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_frontmost_comes_from_the_store(self):
        source = "let frontmost = store.focusRegionStates[tag]?.frontmostPane(for: region, available: ids, fallback: \"repl\")"
        self.assertEqual(check_no_frontmost_tab_state_in_view([("Synthetic.swift", source)]), [])

    def test_ignores_unrelated_state(self):
        source = "@State private var showActivitySheet = false"
        self.assertEqual(check_no_frontmost_tab_state_in_view([("Synthetic.swift", source)]), [])


class NoLocalPlacementOrRatioPersistenceTests(unittest.TestCase):
    def test_bites_on_userdefaults_ratio_key(self):
        source = 'UserDefaults.standard.set(0.5, forKey: "splitRatio.root.0")'
        violations = check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_appstorage_dynlayout_key(self):
        source = '@AppStorage("dynlayout.tabOrder") private var savedOrder = ""'
        violations = check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_evict_identifier(self):
        source = "func evictOldestPane() { }"
        violations = check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_tabcap_identifier(self):
        source = "let tabCap = 5"
        violations = check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_placement_identifier(self):
        source = "func resolvePlacement(for pane: String) -> Int { 0 }"
        violations = check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_typeorder_identifier(self):
        source = "let typeOrder: [String] = []"
        violations = check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_unrelated_userdefaults_usage(self):
        source = 'UserDefaults.standard.set(host, forKey: "daemonHost")'
        self.assertEqual(check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)]), [])

    def test_passes_on_clean_source(self):
        source = "let entries = TabPlan.build(tree: tree, content: content)"
        self.assertEqual(check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)]), [])

    def test_ignores_swiftuis_own_toolbaritem_placement_keyword_argument(self):
        # SwiftUI's standard ToolbarItem(placement:)/.toolbar(placement:) is
        # unrelated to macOS's curated-placement-engine vocabulary this check
        # exists to ban — must not false-positive on ordinary toolbar layout.
        source = 'ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }'
        self.assertEqual(check_no_local_placement_or_ratio_persistence([("Synthetic.swift", source)]), [])


class UnreadGlyphUsesOpacityNotConditionalInsertionTests(unittest.TestCase):
    def test_bites_when_the_file_does_not_exist(self):
        violations = check_unread_glyph_uses_opacity_not_conditional_insertion([("SomeOtherFile.swift", "irrelevant")])
        self.assertTrue(len(violations) > 0)

    def test_bites_when_opacity_is_missing(self):
        source = "Circle().fill(.blue).frame(width: 6, height: 6)"
        violations = check_unread_glyph_uses_opacity_not_conditional_insertion([("TabStripView.swift", source)])
        self.assertTrue(any("opacity" in msg for _, msg in violations))

    def test_bites_on_if_unread_conditional_insertion(self):
        source = "VStack { if unread { Circle().opacity(1) } }"
        violations = check_unread_glyph_uses_opacity_not_conditional_insertion([("TabStripView.swift", source)])
        self.assertTrue(any("if unread" in msg or "if isUnread" in msg for _, msg in violations))

    def test_bites_on_if_isunread_conditional_insertion(self):
        source = "VStack { if isUnread { Circle().opacity(1) } }"
        violations = check_unread_glyph_uses_opacity_not_conditional_insertion([("TabStripView.swift", source)])
        self.assertTrue(any("if unread" in msg or "if isUnread" in msg for _, msg in violations))

    def test_passes_on_a_fixed_glyph_with_toggled_opacity(self):
        source = "Circle().fill(.blue).frame(width: 6, height: 6).opacity(entry.unread ? 1 : 0)"
        self.assertEqual(
            check_unread_glyph_uses_opacity_not_conditional_insertion([("TabStripView.swift", source)]), []
        )


class TickerSurvivesTheRewriteTests(unittest.TestCase):
    def test_bites_when_the_file_does_not_reference_activitytickerbar(self):
        source = "struct DynamicFocusView: View { var body: some View { EmptyView() } }"
        violations = check_ticker_survives_the_rewrite([("DynamicFocusView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_when_the_file_is_missing_entirely(self):
        violations = check_ticker_survives_the_rewrite([("SomeOtherFile.swift", "irrelevant")])
        self.assertEqual(len(violations), 1)

    def test_passes_when_activitytickerbar_is_still_referenced(self):
        source = "private var activityTicker: some View { ActivityTickerBar(text: t, onTap: {}) }"
        self.assertEqual(check_ticker_survives_the_rewrite([("DynamicFocusView.swift", source)]), [])


# --------------------------------------------------------------------------
# W6 bites-tests — one class per check, proving each can actually fail.
# --------------------------------------------------------------------------

class NothingBranchesOnTheDeviceTests(unittest.TestCase):
    def test_bites_on_UIDevice(self):
        source = "let idiom = UIDevice.current"
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)
        self.assertIn("UIDevice", violations[0][1])

    def test_bites_on_userInterfaceIdiom(self):
        source = "let idiom = someType.userInterfaceIdiom"
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)
        self.assertIn("userInterfaceIdiom", violations[0][1])

    def test_bites_on_UIScreen(self):
        source = "let bounds = UIScreen.main.bounds"
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)
        self.assertIn("UIScreen", violations[0][1])

    def test_bites_on_UIInterfaceOrientationMask(self):
        source = "let mask: UIInterfaceOrientationMask = .portrait"
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)
        self.assertIn("UIInterfaceOrientationMask", violations[0][1])

    def test_bites_on_a_bare_orientation_identifier(self):
        source = "let orientation = currentValue"
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)
        self.assertIn("orientation", violations[0][1])

    def test_bites_on_willTransition_to(self):
        source = "coordinator.willTransition(to: newSize) { _ in }"
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)
        self.assertIn("willTransition(to", violations[0][1])

    def test_bites_on_willTransition_to_the_UIKit_override_declaration_form(self):
        # The banned pattern widened from the call form (`willTransition(to:`)
        # to `willTransition(\s*to\b` specifically so it also catches the
        # UIKit override DECLARATION — `func willTransition(to newCollection:
        # UITraitCollection, ...)` — which is how a real view controller
        # would hook a size-class transition. That declaration form is the
        # one that actually matters: it's the mechanism this policy exists
        # to forbid, and the narrower call-only pattern would have missed it
        # entirely (a view controller can declare the override without ever
        # writing a matching call in the same file).
        source = (
            "func willTransition(to newCollection: UITraitCollection, "
            "with coordinator: UIViewControllerTransitionCoordinator) {}"
        )
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)
        self.assertIn("willTransition(to", violations[0][1])

    def test_ignores_a_banned_token_that_appears_only_in_a_line_comment(self):
        # A doc-comment explaining why UIDevice is forbidden must not itself
        # be a violation — the same _strip_line_comments carve-out the rest
        # of this suite relies on.
        source = "// UIDevice, UIScreen, and orientation are never read here — see the width-class PRD."
        violations = check_nothing_branches_on_the_device([("Synthetic.swift", source)])
        self.assertEqual(violations, [])

    def test_passes_on_clean_source(self):
        source = "let width = horizontalSizeClass == .compact ? WidthClass.compact : .regular"
        self.assertEqual(check_nothing_branches_on_the_device([("Synthetic.swift", source)]), [])


class HorizontalSizeClassReadInExactlyOneFileTests(unittest.TestCase):
    def test_bites_when_a_second_file_declares_the_environment_read(self):
        files = [
            ("DynamicFocusView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
            ("SomeOtherView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
        ]
        violations = check_horizontal_size_class_read_in_exactly_one_file(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("SomeOtherView.swift", violations[0][1])

    def test_bites_when_DynamicFocusView_stops_reading_the_size_class(self):
        # Nothing would select the presentation at all — the "missing
        # wiring is itself a violation" shape this suite already uses.
        files = [("DynamicFocusView.swift", "struct DynamicFocusView: View { var body: some View { EmptyView() } } ")]
        violations = check_horizontal_size_class_read_in_exactly_one_file(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("no longer reads", violations[0][1])

    def test_bites_when_a_non_allowlisted_file_merely_mentions_horizontalSizeClass(self):
        files = [
            ("DynamicFocusView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
            ("SomeHelper.swift", "let compact = horizontalSizeClass == .compact"),
        ]
        violations = check_horizontal_size_class_read_in_exactly_one_file(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("SomeHelper.swift", violations[0][1])
        self.assertIn("outside the WidthClass allowlist", violations[0][1])

    def test_ignores_a_preview_only_environment_set_inside_an_allowlisted_file(self):
        # #Preview blocks in RegionContainerView.swift SET the environment
        # value to look at the regular arrangement during development —
        # that is a different act from reading it and is explicitly
        # permitted for allowlisted files.
        files = [
            ("DynamicFocusView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
            ("RegionContainerView.swift", "#Preview { RegionContainerView().environment(\\.horizontalSizeClass, .regular) }"),
        ]
        self.assertEqual(check_horizontal_size_class_read_in_exactly_one_file(files), [])

    def test_bites_when_a_non_allowlisted_file_sets_the_environment_value(self):
        # The SET carve-out (`.environment(\.horizontalSizeClass, ...)`) is
        # permitted ONLY inside WIDTH_CLASS_ALLOWLIST, per the docstring.
        # Previously the carve-out was stripped unconditionally regardless of
        # which file it appeared in, so a SET in a non-allowlisted file
        # passed silently — a second file publishing a size-class override is
        # a second branch by another name, exactly what D1 forbids.
        files = [
            ("DynamicFocusView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
            ("SomeOtherView.swift", "#Preview { SomeOtherView().environment(\\.horizontalSizeClass, .regular) }"),
        ]
        violations = check_horizontal_size_class_read_in_exactly_one_file(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("SomeOtherView.swift", violations[0][1])
        self.assertIn("outside the WidthClass allowlist", violations[0][1])

    def test_passes_on_the_correct_single_reader_shape(self):
        files = [
            ("DynamicFocusView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
            ("RegionContainerView.swift", "struct RegionContainerView: View { let widthClass: WidthClass }"),
        ]
        self.assertEqual(check_horizontal_size_class_read_in_exactly_one_file(files), [])


class WidthClassReferencedOnlyByTheAllowlistTests(unittest.TestCase):
    def test_bites_when_a_non_allowlisted_file_names_WidthClass(self):
        files = [("SomeOtherView.swift", "let w: WidthClass = .compact")]
        violations = check_width_class_referenced_only_by_the_allowlist(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_a_non_allowlisted_file_names_nostromoWidthClass(self):
        files = [("SomeOtherView.swift", ".environment(\\.nostromoWidthClass, widthClass)")]
        violations = check_width_class_referenced_only_by_the_allowlist(files)
        self.assertEqual(len(violations), 1)

    def test_passes_for_allowlisted_files(self):
        files = [
            ("DynamicFocusView.swift", "let w: WidthClass = .compact"),
            ("RegionContainerView.swift", ".environment(\\.nostromoWidthClass, widthClass)"),
        ]
        self.assertEqual(check_width_class_referenced_only_by_the_allowlist(files), [])

    def test_ignores_a_mention_in_a_line_comment(self):
        files = [("SomeOtherView.swift", "// WidthClass is deliberately not read here")]
        self.assertEqual(check_width_class_referenced_only_by_the_allowlist(files), [])

    def test_bites_when_code_surface_view_names_width_class(self):
        # ios-curated-view-parity W7: a file view is the same file view at
        # both widths — W8's diff surface is the sole intended WidthClass
        # consumer, not this one.
        files = [("CodeSurfaceView.swift", "let w: WidthClass = .compact")]
        violations = check_width_class_referenced_only_by_the_allowlist(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_code_surface_view_reads_horizontal_size_class(self):
        files = [
            ("DynamicFocusView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
            ("CodeSurfaceView.swift", "@Environment(\\.horizontalSizeClass) private var widthClass"),
        ]
        violations = check_horizontal_size_class_read_in_exactly_one_file(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_diff_file_list_view_names_width_class(self):
        # ios-curated-view-parity W8: DiffSurfaceView.swift is the sole
        # intended WidthClass consumer for pr_diff — its two leaf views take
        # identical parameters at both widths and must not branch on it.
        files = [("DiffFileListView.swift", "let w: WidthClass = .compact")]
        violations = check_width_class_referenced_only_by_the_allowlist(files)
        self.assertEqual(len(violations), 1)

    def test_bites_when_diff_file_content_view_names_width_class(self):
        files = [("DiffFileContentView.swift", ".environment(\\.nostromoWidthClass, widthClass)")]
        violations = check_width_class_referenced_only_by_the_allowlist(files)
        self.assertEqual(len(violations), 1)

    def test_passes_when_diff_surface_view_names_width_class(self):
        files = [("DiffSurfaceView.swift", "let w: WidthClass = .compact")]
        self.assertEqual(check_width_class_referenced_only_by_the_allowlist(files), [])


class NoRegionResizeAffordanceTests(unittest.TestCase):
    def test_bites_on_draggesture(self):
        files = [("RegionContainerView.swift", "@State var drag = DragGesture().onChanged { _ in }")]
        violations = check_no_region_resize_affordance(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("gesture", violations[0][1])

    def test_bites_on_dot_gesture(self):
        files = [("RegionContainerView.swift", "Divider().gesture(TapGesture())")]
        violations = check_no_region_resize_affordance(files)
        self.assertEqual(len(violations), 1)

    def test_bites_on_dot_simultaneousGesture(self):
        files = [("RegionContainerView.swift", "Divider().simultaneousGesture(TapGesture())")]
        violations = check_no_region_resize_affordance(files)
        self.assertEqual(len(violations), 1)

    def test_bites_on_a_userdefaults_key_matching_ratio(self):
        files = [("Synthetic.swift", 'UserDefaults.standard.set(0.5, forKey: "regionRatio")')]
        violations = check_no_region_resize_affordance(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("persisted layout key", violations[0][1])

    def test_bites_on_an_appstorage_key_matching_dynlayout(self):
        files = [("Synthetic.swift", '@AppStorage("dynlayout.tabOrder") private var savedOrder = ""')]
        violations = check_no_region_resize_affordance(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("persisted layout key", violations[0][1])

    def test_bites_on_a_userdefaults_key_matching_split(self):
        files = [("Synthetic.swift", 'UserDefaults.standard.set(pos, forKey: "splitPosition")')]
        violations = check_no_region_resize_affordance(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("persisted layout key", violations[0][1])

    def test_passes_on_unrelated_userdefaults_usage(self):
        files = [("Synthetic.swift", 'UserDefaults.standard.set(host, forKey: "daemonHost")')]
        self.assertEqual(check_no_region_resize_affordance(files), [])

    def test_passes_on_a_clean_region_container(self):
        files = [("RegionContainerView.swift", "struct RegionContainerView: View { var body: some View { EmptyView() } }")]
        self.assertEqual(check_no_region_resize_affordance(files), [])


class NoSheetPresentedFromInsideARegionTests(unittest.TestCase):
    def test_bites_when_RegionContainerView_presents_a_sheet(self):
        files = [
            ("RegionContainerView.swift", ".sheet(isPresented: $x) { Foo() }"),
            ("TabStripView.swift", "struct TabStripView: View {}"),
            ("PaneSurfaceView.swift", "struct PaneSurfaceView: View {}"),
        ]
        violations = check_no_sheet_presented_from_inside_a_region(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("RegionContainerView.swift", violations[0][0])

    def test_bites_when_TabStripView_presents_a_sheet(self):
        files = [
            ("RegionContainerView.swift", "struct RegionContainerView: View {}"),
            ("TabStripView.swift", ".sheet(isPresented: $x) { Foo() }"),
            ("PaneSurfaceView.swift", "struct PaneSurfaceView: View {}"),
        ]
        violations = check_no_sheet_presented_from_inside_a_region(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("TabStripView.swift", violations[0][0])

    def test_bites_when_PaneSurfaceView_presents_a_sheet(self):
        files = [
            ("RegionContainerView.swift", "struct RegionContainerView: View {}"),
            ("TabStripView.swift", "struct TabStripView: View {}"),
            ("PaneSurfaceView.swift", ".sheet(isPresented: $x) { Foo() }"),
        ]
        violations = check_no_sheet_presented_from_inside_a_region(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("PaneSurfaceView.swift", violations[0][0])

    def test_passes_when_none_of_the_three_present_a_sheet(self):
        files = [
            ("RegionContainerView.swift", "struct RegionContainerView: View {}"),
            ("TabStripView.swift", "struct TabStripView: View {}"),
            ("PaneSurfaceView.swift", "struct PaneSurfaceView: View {}"),
        ]
        self.assertEqual(check_no_sheet_presented_from_inside_a_region(files), [])


class RegionContainerComputesNoLayoutFractionTests(unittest.TestCase):
    def test_bites_on_a_layout_fraction_in_a_frame_expression(self):
        files = [("RegionContainerView.swift", "let allocation = shares[i]\nFoo().frame(width: geometry.size.width * 0.6)")]
        violations = check_region_container_computes_no_layout_fraction(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("layout fraction literal", violations[0][1])

    def test_bites_when_the_file_never_references_shares(self):
        files = [("RegionContainerView.swift", "struct RegionContainerView: View { var body: some View { EmptyView() } }")]
        violations = check_region_container_computes_no_layout_fraction(files)
        self.assertEqual(len(violations), 1)
        self.assertIn("never references the plan's `shares`", violations[0][1])

    def test_ignores_opacity_on_a_non_sizing_line(self):
        files = [("RegionContainerView.swift", "let allocation = shares[i]\nCircle().opacity(0.25)")]
        self.assertEqual(check_region_container_computes_no_layout_fraction(files), [])

    def test_ignores_an_integer_literal_on_a_frame_line(self):
        # A 1-point hairline thickness, not a proportion of the container.
        files = [("RegionContainerView.swift", "let allocation = shares[i]\nDivider().frame(height: 1)")]
        self.assertEqual(check_region_container_computes_no_layout_fraction(files), [])

    def test_ignores_a_literal_greater_than_or_equal_to_one_on_a_frame_line(self):
        files = [("RegionContainerView.swift", "let allocation = shares[i]\nDivider().frame(width: 1.5)")]
        self.assertEqual(check_region_container_computes_no_layout_fraction(files), [])

    # Not covered, by the check's own docstring: a fraction laundered
    # through a named constant (e.g. `.frame(width: geometry.size.width *
    # regionSplitFraction)`) reads as an identifier, not a `0.\d+` literal,
    # and this heuristic will not catch it. No test asserts otherwise.

    def test_passes_on_a_clean_region_container(self):
        files = [("RegionContainerView.swift", "let width = totalWidth * shares[i] / totalShares")]
        self.assertEqual(check_region_container_computes_no_layout_fraction(files), [])


class NoScrollRestoreKeyInViewStateTests(unittest.TestCase):
    def test_bites_on_scrollKey_state(self):
        source = "@State private var scrollKey: String = \"\""
        violations = check_no_scroll_restore_key_in_view_state([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_savedScrollPosition_state(self):
        source = "@State private var savedScrollPosition: String? = nil"
        violations = check_no_scroll_restore_key_in_view_state([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_restoreKey_state(self):
        source = "@State private var restoreKey: String = \"\""
        violations = check_no_scroll_restore_key_in_view_state([("Synthetic.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_view_local_visible_row_indices(self):
        # "What is on screen right now" is transient view state, not
        # durable state anyone is trying to preserve across a width-class
        # rebuild — banning this would be wrong.
        source = "@State private var visibleRowIndices: Set<Int> = []"
        self.assertEqual(check_no_scroll_restore_key_in_view_state([("Synthetic.swift", source)]), [])

    def test_passes_on_view_local_visible_turn_indices(self):
        source = "@State private var visibleTurnIndices: Set<Int> = []"
        self.assertEqual(check_no_scroll_restore_key_in_view_state([("Synthetic.swift", source)]), [])


class RegionContainerReusesTheSharedTabStripTests(unittest.TestCase):
    def test_bites_when_RegionContainerView_does_not_instantiate_TabStripView(self):
        source = "struct RegionContainerView: View { var body: some View { EmptyView() } }"
        violations = check_region_container_reuses_the_shared_tab_strip([("RegionContainerView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_when_the_file_is_missing_entirely(self):
        violations = check_region_container_reuses_the_shared_tab_strip([("SomeOtherFile.swift", "irrelevant")])
        self.assertEqual(len(violations), 1)

    def test_passes_when_TabStripView_is_instantiated(self):
        source = "struct RegionContainerView: View { var body: some View { TabStripView(tag: tag, region: region) } }"
        self.assertEqual(check_region_container_reuses_the_shared_tab_strip([("RegionContainerView.swift", source)]), [])


# --------------------------------------------------------------------------
# ios-curated-view-parity W7 — the `code` surface
# --------------------------------------------------------------------------

class CodeSurfaceNoTruncationTests(unittest.TestCase):
    def test_bites_on_prefix(self):
        source = "Text(document.lines[row].prefix(200))"
        violations = check_code_surface_no_truncation([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_a_numeric_row_cap(self):
        source = "ForEach(0..<600, id: \\.self) { row in codeRow(row) }"
        violations = check_code_surface_no_truncation([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_lineLimit_inside_codeRow(self):
        source = "func codeRow(_ row: Int) -> some View { Text(document.lines[row]).lineLimit(1) }"
        violations = check_code_surface_no_truncation([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_ignores_lineLimit_outside_codeRow(self):
        # The header's path label legitimately truncates to one line (D6) —
        # this check is scoped to the content column, not the whole file.
        source = "var header: some View { Text(document.path).lineLimit(1) }\nfunc codeRow(_ row: Int) -> some View { Text(document.lines[row]) }"
        self.assertEqual(check_code_surface_no_truncation([("CodeSurfaceView.swift", source)]), [])

    def test_ignores_perriview_by_path(self):
        source = "Text(pr.diff.prefix(4000)).lineLimit(60)"
        self.assertEqual(check_code_surface_no_truncation([("PerriView.swift", source)]), [])

    def test_passes_on_clean_source(self):
        source = "ForEach(0..<document.lineCount, id: \\.self) { row in codeRow(row) }\nfunc codeRow(_ row: Int) -> some View { Text(document.lines[row]) }"
        self.assertEqual(check_code_surface_no_truncation([("CodeSurfaceView.swift", source)]), [])


class CodeSurfaceNoHorizontalPanningTests(unittest.TestCase):
    def test_bites_on_scrollview_horizontal(self):
        source = "ScrollView(.horizontal) { content }"
        violations = check_code_surface_no_horizontal_panning([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_axes_horizontal(self):
        source = "ScrollView(axes: .horizontal) { content }"
        violations = check_code_surface_no_horizontal_panning([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_clean_source(self):
        source = "ScrollView { content }"
        self.assertEqual(check_code_surface_no_horizontal_panning([("CodeSurfaceView.swift", source)]), [])


class CodeSurfaceGutterTopAlignedWrappingColumnTests(unittest.TestCase):
    def test_bites_when_no_top_aligned_hstack_exists(self):
        source = "func codeRow(_ row: Int) -> some View { HStack { Text(\"x\") } }"
        violations = check_code_surface_gutter_top_aligned_wrapping_column([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_lineLimit_inside_codeRow(self):
        source = "HStack(alignment: .top) {}\nfunc codeRow(_ row: Int) -> some View { Text(document.lines[row]).lineLimit(1) }"
        violations = check_code_surface_gutter_top_aligned_wrapping_column([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_clean_source(self):
        source = "func codeRow(_ row: Int) -> some View { HStack(alignment: .top, spacing: 8) { Text(document.lines[row]) } }"
        self.assertEqual(check_code_surface_gutter_top_aligned_wrapping_column([("CodeSurfaceView.swift", source)]), [])


class CodeSurfaceScrollOnlyViaDecisionTests(unittest.TestCase):
    def test_bites_on_an_unconditional_scrollTo(self):
        source = "func jumpToTop(proxy: ScrollViewProxy) { proxy.scrollTo(0) }"
        violations = check_code_surface_scroll_only_via_decision([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_gated_by_scrolldecision(self):
        source = "switch ScrollDecision.decide(anchor: a, visibleRange: r) {\ncase .none: break\ncase .scrollTo(let row):\nproxy.scrollTo(row, anchor: .center)\n}"
        self.assertEqual(check_code_surface_scroll_only_via_decision([("CodeSurfaceView.swift", source)]), [])

    def test_passes_when_gated_by_scrollrestore(self):
        source = "switch restoreScroll(range) {\ncase .scrollTo(let target):\nproxy.scrollTo(target, anchor: .top)\ncase .none: break\n}"
        self.assertEqual(check_code_surface_scroll_only_via_decision([("CodeSurfaceView.swift", source)]), [])


class CodeSurfaceNoRebuildOnAddressChangeTests(unittest.TestCase):
    def test_bites_on_id_referencing_address(self):
        source = "SomeView().id(address)"
        violations = check_code_surface_no_rebuild_on_address_change([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_id_referencing_anchor(self):
        source = "SomeView().id(anchorResolution)"
        violations = check_code_surface_no_rebuild_on_address_change([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_id_referencing_emphasis(self):
        source = "SomeView().id(emphasisResolution)"
        violations = check_code_surface_no_rebuild_on_address_change([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_id_references_only_row(self):
        source = "codeRow(row).id(row)"
        self.assertEqual(check_code_surface_no_rebuild_on_address_change([("CodeSurfaceView.swift", source)]), [])


class CodeSurfaceRendersEveryResolutionCaseTests(unittest.TestCase):
    def test_bites_when_a_case_is_missing(self):
        source = ".resolved(let row): return row\n.unresolved(let reason): notice(reason)"
        violations = check_code_surface_renders_every_resolution_case([("CodeSurfaceView.swift", source)])
        self.assertTrue(len(violations) > 0)

    def test_passes_when_every_case_is_present(self):
        source = ".notRequested .resolved .unresolved .none .rows .matchedNothing"
        self.assertEqual(check_code_surface_renders_every_resolution_case([("CodeSurfaceView.swift", source)]), [])


class CodeSurfaceNoSyntaxHighlightingTests(unittest.TestCase):
    def test_bites_on_attributedstring_construction(self):
        source = "let s = AttributedString(line, language: lang)"
        violations = check_code_surface_no_syntax_highlighting([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_syntect_reference(self):
        source = "let highlighted = Syntect.highlight(line)"
        violations = check_code_surface_no_syntax_highlighting([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_clean_source(self):
        source = "Text(document.lines[row])"
        self.assertEqual(check_code_surface_no_syntax_highlighting([("CodeSurfaceView.swift", source)]), [])


# --------------------------------------------------------------------------
# ios-curated-view-parity W8 — the `pr_diff` surface
# --------------------------------------------------------------------------

class DiffSurfaceNoTruncationTests(unittest.TestCase):
    def test_bites_on_prefix_in_diff_file_content_view(self):
        source = "Text(document.rows[i].text.prefix(200))"
        violations = check_diff_surface_no_truncation([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_prefix_in_diff_file_list_view(self):
        source = "Text(file.path.prefix(80))"
        violations = check_diff_surface_no_truncation([("DiffFileListView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_prefix_in_diff_surface_view(self):
        source = "Text(document.rows.prefix(50).map(\\.text).joined())"
        violations = check_diff_surface_no_truncation([("DiffSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_a_numeric_row_cap(self):
        source = "ForEach(0..<600, id: \\.self) { i in row(i) }"
        violations = check_diff_surface_no_truncation([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_lineLimit_inside_row_in_diff_file_content_view(self):
        source = "func row(_ index: Int) -> some View { CodeRowView(text: document.rows[index].text).lineLimit(1) }"
        violations = check_diff_surface_no_truncation([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_ignores_lineLimit_1_on_diff_file_list_views_truncated_path_label(self):
        # DiffFileListView.swift legitimately truncates its own path label to
        # one line (D7: "truncated from the leading end so the filename
        # survives") — this check is scoped to DiffFileContentView's row(...)
        # function, not applied file-wide.
        source = "Text(file.path).lineLimit(1)"
        self.assertEqual(check_diff_surface_no_truncation([("DiffFileListView.swift", source)]), [])

    def test_ignores_lineLimit_outside_row_in_diff_file_content_view(self):
        source = (
            "var header: some View { Text(document.path).lineLimit(1) }\n"
            "func row(_ index: Int) -> some View { CodeRowView(text: document.rows[index].text) }"
        )
        self.assertEqual(check_diff_surface_no_truncation([("DiffFileContentView.swift", source)]), [])

    def test_passes_on_clean_source(self):
        files = [
            ("DiffSurfaceView.swift", "struct DiffSurfaceView: View { var body: some View { EmptyView() } }"),
            ("DiffFileListView.swift", "ForEach(document.files, id: \\.path) { file in Text(file.path).lineLimit(1) }"),
            (
                "DiffFileContentView.swift",
                "ForEach(0..<document.rowCount, id: \\.self) { i in row(i) }\n"
                "func row(_ index: Int) -> some View { CodeRowView(text: document.rows[index].text) }"
            ),
        ]
        self.assertEqual(check_diff_surface_no_truncation(files), [])


class DiffSurfaceNoHorizontalPanningTests(unittest.TestCase):
    def test_bites_on_scrollview_horizontal_in_diff_file_content_view(self):
        source = "ScrollView(.horizontal) { content }"
        violations = check_diff_surface_no_horizontal_panning([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_axes_horizontal_in_diff_surface_view(self):
        source = "ScrollView(axes: .horizontal) { content }"
        violations = check_diff_surface_no_horizontal_panning([("DiffSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_clean_source(self):
        files = [
            ("DiffSurfaceView.swift", "HStack { DiffFileListView(document: d); DiffFileContentView(document: d) }"),
            ("DiffFileListView.swift", "ScrollView { content }"),
            ("DiffFileContentView.swift", "ScrollView { content }"),
        ]
        self.assertEqual(check_diff_surface_no_horizontal_panning(files), [])


class DiffContentUsesSharedCodeRowTests(unittest.TestCase):
    def test_bites_when_diff_file_content_view_does_not_reference_coderowview(self):
        source = "func row(_ index: Int) -> some View { Text(document.rows[index].text) }"
        violations = check_diff_content_uses_shared_code_row([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_when_the_file_is_missing_entirely(self):
        violations = check_diff_content_uses_shared_code_row([("SomeOtherFile.swift", "irrelevant")])
        self.assertEqual(len(violations), 1)

    def test_passes_when_coderowview_is_referenced(self):
        source = "func row(_ index: Int) -> some View { CodeRowView(text: document.rows[index].text, kind: document.rows[index].kind) }"
        self.assertEqual(check_diff_content_uses_shared_code_row([("DiffFileContentView.swift", source)]), [])


class DiffScrollOnlyViaDecisionTests(unittest.TestCase):
    def test_bites_on_an_unconditional_scrollTo(self):
        source = "func jumpToTop(proxy: ScrollViewProxy) { proxy.scrollTo(0) }"
        violations = check_diff_scroll_only_via_decision([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_gated_by_scrolldecision(self):
        source = (
            "switch ScrollDecision.decide(anchor: a, visibleRange: r) {\n"
            "case .none: break\n"
            "case .scrollTo(let row):\n"
            "proxy.scrollTo(row, anchor: .center)\n"
            "}"
        )
        self.assertEqual(check_diff_scroll_only_via_decision([("DiffFileContentView.swift", source)]), [])

    def test_passes_when_gated_by_scrollrestore(self):
        source = (
            "switch restoreScroll(range) {\n"
            "case .scrollTo(let target):\n"
            "proxy.scrollTo(target, anchor: .top)\n"
            "case .none: break\n"
            "}"
        )
        self.assertEqual(check_diff_scroll_only_via_decision([("DiffFileContentView.swift", source)]), [])


class DiffNoLineResolutionReimplementedTests(unittest.TestCase):
    def test_bites_on_newN_compared_with_equality(self):
        source = "if row.newN == line { scrollTarget = row }"
        violations = check_diff_no_line_resolution_reimplemented([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_oldN_compared_with_the_operator_on_the_left(self):
        # The operator-first alternative matches a bare identifier directly
        # after the operator (whitespace only in between) — the shape a
        # local extracted from `row.oldN` takes, as opposed to `row.oldN`
        # itself, which the identifier-first alternative already covers.
        source = "let oldN = row.oldN\nif line <= oldN { markEmphasis(row) }"
        violations = check_diff_no_line_resolution_reimplemented([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_scans_every_file_not_just_the_diff_surface_files(self):
        # Memo B10's point: resolution must not be reimplemented ANYWHERE
        # under iOS/, not merely kept out of the three new files.
        source = "if row.newN == line { }"
        violations = check_diff_no_line_resolution_reimplemented([("CodeSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_does_not_bite_on_a_nil_coalescing_read(self):
        # The gutter's own new-or-old display precedence (D5) is a plain
        # read, not comparison arithmetic, and must not trip this check.
        source = 'Text("\\(row.newN ?? row.oldN ?? 0)")'
        self.assertEqual(check_diff_no_line_resolution_reimplemented([("DiffFileContentView.swift", source)]), [])

    def test_passes_on_clean_source(self):
        source = "let gutterNumber = row.newN ?? row.oldN"
        self.assertEqual(check_diff_no_line_resolution_reimplemented([("DiffFileContentView.swift", source)]), [])


class DiffSelectedFileNotViewStateTests(unittest.TestCase):
    def test_bites_on_selectedfile_state_in_diff_surface_view(self):
        source = "@State private var selectedFile: String?"
        violations = check_diff_selected_file_not_view_state([("DiffSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_currentfile_state_in_diff_file_content_view(self):
        source = '@State var currentFile: String = ""'
        violations = check_diff_selected_file_not_view_state([("DiffFileContentView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_unrelated_state(self):
        source = "@State private var navPath: [String] = []"
        self.assertEqual(check_diff_selected_file_not_view_state([("DiffSurfaceView.swift", source)]), [])


class DiffRendersEveryResolutionCaseTests(unittest.TestCase):
    def test_bites_when_a_case_is_missing(self):
        source = ".resolved(let row): open(row)\n.unresolved(let reason): notice(reason)"
        violations = check_diff_renders_every_resolution_case([("DiffSurfaceView.swift", source)])
        self.assertTrue(len(violations) > 0)

    def test_passes_when_every_case_is_present(self):
        source = ".notRequested .resolved .unresolved .none .rows .matchedNothing"
        self.assertEqual(check_diff_renders_every_resolution_case([("DiffSurfaceView.swift", source)]), [])


class DiffTooLargeNoticeNotOneRowAmongManyTests(unittest.TestCase):
    def test_bites_when_toolarge_is_never_referenced(self):
        source = "struct DiffSurfaceView: View { var body: some View { DiffFileListView(document: document) } }"
        violations = check_diff_toolarge_notice_not_one_row_among_many([("DiffSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_when_the_file_is_missing_entirely(self):
        violations = check_diff_toolarge_notice_not_one_row_among_many([("SomeOtherFile.swift", "irrelevant")])
        self.assertEqual(len(violations), 1)

    def test_passes_when_toolarge_is_referenced(self):
        source = "if document.tooLarge { TooLargeNotice(changedFiles: document.changedFiles) } else { DiffFileListView(document: document) }"
        self.assertEqual(check_diff_toolarge_notice_not_one_row_among_many([("DiffSurfaceView.swift", source)]), [])


# --------------------------------------------------------------------------
# ios-curated-view-parity W9 bites-tests
# --------------------------------------------------------------------------

class ProseSurfaceReadsNoWidthClassTests(unittest.TestCase):
    def test_bites_on_WidthClass_reference(self):
        source = "let width: WidthClass = .compact"
        violations = check_prose_surface_reads_no_width_class([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_horizontalSizeClass_reference(self):
        source = "@Environment(\\.horizontalSizeClass) private var sizeClass"
        violations = check_prose_surface_reads_no_width_class([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_clean_source(self):
        source = "struct ProseSurfaceView: View { let rows: [ProseRow] }"
        self.assertEqual(check_prose_surface_reads_no_width_class([("ProseSurfaceView.swift", source)]), [])


class ProseSurfaceNoTruncationTests(unittest.TestCase):
    def test_bites_on_prefix(self):
        source = "Text(text.prefix(200))"
        violations = check_prose_surface_no_truncation([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_numeric_row_cap(self):
        source = "ForEach(0..<50) { i in rowView(rows[i]) }"
        violations = check_prose_surface_no_truncation([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_lineLimit_inside_codeBlockView(self):
        source = "func codeBlockView(lang: String?, text: String) -> some View { Text(text).lineLimit(4) }"
        violations = check_prose_surface_no_truncation([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_ignores_lineLimit_outside_codeBlockView(self):
        # The document header's url legitimately truncates to one line.
        source = (
            "func documentHeaderView(_ header: ProseHeader) -> some View { Link(url, destination: u).lineLimit(1) }\n"
            "func codeBlockView(lang: String?, text: String) -> some View { Text(text) }"
        )
        self.assertEqual(check_prose_surface_no_truncation([("ProseSurfaceView.swift", source)]), [])

    def test_passes_on_clean_source(self):
        source = "ForEach(rows) { row in rowView(row) }"
        self.assertEqual(check_prose_surface_no_truncation([("ProseSurfaceView.swift", source)]), [])


class ProseSurfaceNoHorizontalPanningTests(unittest.TestCase):
    def test_bites_on_horizontal_scrollview(self):
        source = "ScrollView(.horizontal) { content }"
        violations = check_prose_surface_no_horizontal_panning([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_horizontal_axes(self):
        source = "ScrollView(axes: .horizontal) { content }"
        violations = check_prose_surface_no_horizontal_panning([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_clean_source(self):
        source = "ScrollView { content }"
        self.assertEqual(check_prose_surface_no_horizontal_panning([("ProseSurfaceView.swift", source)]), [])


class ProseSurfaceScrollOnlyViaDecisionTests(unittest.TestCase):
    def test_bites_on_unconditional_scrollTo(self):
        source = "proxy.scrollTo(target, anchor: .top)"
        violations = check_prose_surface_scroll_only_via_decision([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_gated_by_case_scrollTo(self):
        source = "switch decision {\ncase .scrollTo(let target):\n    proxy.scrollTo(target, anchor: .top)\ncase .none:\n    break\n}"
        self.assertEqual(check_prose_surface_scroll_only_via_decision([("ProseSurfaceView.swift", source)]), [])


class ProseSurfaceThreadMetadataRenderedTests(unittest.TestCase):
    def test_bites_when_resolved_is_never_referenced(self):
        source = "Text(thread.path ?? \"\")\nText(\"\\(thread.line ?? 0)\")"
        violations = check_prose_surface_thread_metadata_rendered([("ProseSurfaceView.swift", source)])
        self.assertTrue(any("resolved" in msg for _, msg in violations))

    def test_bites_when_path_and_line_are_never_referenced(self):
        source = "Text(thread.resolved ? \"Resolved\" : \"\")"
        violations = check_prose_surface_thread_metadata_rendered([("ProseSurfaceView.swift", source)])
        self.assertTrue(any("path" in msg for _, msg in violations))
        self.assertTrue(any("line" in msg for _, msg in violations))

    def test_passes_when_all_three_are_referenced(self):
        source = "thread.resolved\nthread.path\nthread.line"
        self.assertEqual(check_prose_surface_thread_metadata_rendered([("ProseSurfaceView.swift", source)]), [])


class ConversationErrorNoticeIsRenderedTests(unittest.TestCase):
    def test_bites_when_never_referenced(self):
        source = "struct ProseSurfaceView: View { var body: some View { EmptyView() } }"
        violations = check_conversation_error_notice_is_rendered([("ProseSurfaceView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_when_referenced(self):
        source = "case .notice(.conversationIncomplete(let reason)): NoticeBanner(text: reason)"
        self.assertEqual(check_conversation_error_notice_is_rendered([("ProseSurfaceView.swift", source)]), [])


class ProseSurfaceRendersEveryResolutionCaseTests(unittest.TestCase):
    def test_bites_when_a_case_is_missing(self):
        source = ".resolved(let target): scroll(target)\n.unresolved(let reason): notice(reason)"
        violations = check_prose_surface_renders_every_resolution_case([("ProseSurfaceView.swift", source)])
        self.assertTrue(len(violations) > 0)

    def test_passes_when_every_case_is_present(self):
        source = ".notRequested .resolved .unresolved .none .rows .matchedNothing"
        self.assertEqual(check_prose_surface_renders_every_resolution_case([("ProseSurfaceView.swift", source)]), [])


class NoClientSideMarkdownParsingTests(unittest.TestCase):
    def test_bites_on_attributedstring_markdown_initializer(self):
        source = 'let s = try? AttributedString(markdown: text)'
        violations = check_no_client_side_markdown_parsing([("SomeView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_manual_backtick_scanning(self):
        source = 'if line.hasPrefix("`") { }'
        violations = check_no_client_side_markdown_parsing([("SomeView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_bites_on_manual_heading_prefix_scanning(self):
        source = 'if line.hasPrefix("#") { }'
        violations = check_no_client_side_markdown_parsing([("SomeView.swift", source)])
        self.assertEqual(len(violations), 1)

    def test_passes_on_clean_source(self):
        source = "Text(attributedText(for: row.spans))"
        self.assertEqual(check_no_client_side_markdown_parsing([("ProseSurfaceView.swift", source)]), [])


class LangNotDiscardedInProseSurfaceTests(unittest.TestCase):
    def test_bites_on_the_macos_shaped_discard(self):
        source = "case .codeBlock(let lang, let text):\n    _ = lang\n    renderPlain(text)"
        violations = check_lang_not_discarded_in_prose_surface([("ProseSurfaceView.swift", source)])
        self.assertTrue(len(violations) > 0)

    def test_bites_when_the_case_pattern_never_binds_lang(self):
        source = "case .codeBlock(_, let text): renderPlain(text)"
        violations = check_lang_not_discarded_in_prose_surface([("ProseSurfaceView.swift", source)])
        self.assertTrue(len(violations) > 0)

    def test_passes_when_lang_is_bound_and_threaded_through(self):
        source = "case .codeBlock(let lang, let text): codeBlockView(lang: lang, text: text)"
        self.assertEqual(check_lang_not_discarded_in_prose_surface([("ProseSurfaceView.swift", source)]), [])


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

    def test_payload_text_is_referenced_only_inside_codedocument_construction(self):
        violations = check_payload_text_only_inside_codedocument_construction(self.files)
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

    def test_no_pane_id_visible_via_capitalized(self):
        # Expected to FAIL against today's tree, pre-W5: DynamicFocusView.swift
        # derives tab labels/titles from `paneId.capitalized`/`selectedTab.capitalized`
        # — exactly the defect this wedge exists to fix. This assertion is
        # written to be true once W5 lands; until then it documents the gap.
        violations = check_no_pane_id_visible_via_capitalized(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_second_bottom_tab_bar(self):
        # Expected to FAIL against today's tree, pre-W5: DynamicFocusView.swift
        # nests its own per-focus TabView/.tabItem inside the app's root tab bar.
        violations = check_no_second_bottom_tab_bar(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_root_tab_hijack(self):
        violations = check_no_root_tab_hijack(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_frontmost_tab_state_in_view(self):
        # Expected to FAIL against today's tree, pre-W5:
        # DynamicFocusView.swift declares `@State private var selectedTab`.
        violations = check_no_frontmost_tab_state_in_view(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_local_placement_or_ratio_persistence(self):
        violations = check_no_local_placement_or_ratio_persistence(self.files)
        self.assertEqual(violations, [], violations)

    def test_unread_glyph_uses_opacity_not_conditional_insertion(self):
        # Expected to FAIL against today's tree, pre-W5: TabStripView.swift
        # doesn't exist yet.
        violations = check_unread_glyph_uses_opacity_not_conditional_insertion(self.files)
        self.assertEqual(violations, [], violations)

    def test_ticker_survives_the_rewrite(self):
        violations = check_ticker_survives_the_rewrite(self.files)
        self.assertEqual(violations, [], violations)

    def test_nothing_branches_on_the_device(self):
        violations = check_nothing_branches_on_the_device(self.files)
        self.assertEqual(violations, [], violations)

    def test_horizontal_size_class_read_in_exactly_one_file(self):
        violations = check_horizontal_size_class_read_in_exactly_one_file(self.files)
        self.assertEqual(violations, [], violations)

    def test_width_class_referenced_only_by_the_allowlist(self):
        violations = check_width_class_referenced_only_by_the_allowlist(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_region_resize_affordance(self):
        violations = check_no_region_resize_affordance(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_sheet_presented_from_inside_a_region(self):
        violations = check_no_sheet_presented_from_inside_a_region(self.files)
        self.assertEqual(violations, [], violations)

    def test_region_container_computes_no_layout_fraction(self):
        violations = check_region_container_computes_no_layout_fraction(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_scroll_restore_key_in_view_state(self):
        violations = check_no_scroll_restore_key_in_view_state(self.files)
        self.assertEqual(violations, [], violations)

    def test_region_container_reuses_the_shared_tab_strip(self):
        violations = check_region_container_reuses_the_shared_tab_strip(self.files)
        self.assertEqual(violations, [], violations)

    def test_code_surface_no_truncation(self):
        violations = check_code_surface_no_truncation(self.files)
        self.assertEqual(violations, [], violations)

    def test_code_surface_no_horizontal_panning(self):
        violations = check_code_surface_no_horizontal_panning(self.files)
        self.assertEqual(violations, [], violations)

    def test_code_surface_gutter_top_aligned_wrapping_column(self):
        violations = check_code_surface_gutter_top_aligned_wrapping_column(self.files)
        self.assertEqual(violations, [], violations)

    def test_code_surface_scroll_only_via_decision(self):
        violations = check_code_surface_scroll_only_via_decision(self.files)
        self.assertEqual(violations, [], violations)

    def test_code_surface_no_rebuild_on_address_change(self):
        violations = check_code_surface_no_rebuild_on_address_change(self.files)
        self.assertEqual(violations, [], violations)

    def test_code_surface_renders_every_resolution_case(self):
        violations = check_code_surface_renders_every_resolution_case(self.files)
        self.assertEqual(violations, [], violations)

    def test_code_surface_no_syntax_highlighting(self):
        violations = check_code_surface_no_syntax_highlighting(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_surface_no_truncation(self):
        # Expected to FAIL until W8 lands: DiffSurfaceView.swift,
        # DiffFileListView.swift, and DiffFileContentView.swift don't exist
        # yet.
        violations = check_diff_surface_no_truncation(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_surface_no_horizontal_panning(self):
        violations = check_diff_surface_no_horizontal_panning(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_content_uses_shared_code_row(self):
        violations = check_diff_content_uses_shared_code_row(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_scroll_only_via_decision(self):
        violations = check_diff_scroll_only_via_decision(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_no_line_resolution_reimplemented(self):
        violations = check_diff_no_line_resolution_reimplemented(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_selected_file_not_view_state(self):
        violations = check_diff_selected_file_not_view_state(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_renders_every_resolution_case(self):
        violations = check_diff_renders_every_resolution_case(self.files)
        self.assertEqual(violations, [], violations)

    def test_diff_toolarge_notice_not_one_row_among_many(self):
        violations = check_diff_toolarge_notice_not_one_row_among_many(self.files)
        self.assertEqual(violations, [], violations)

    def test_prose_surface_reads_no_width_class(self):
        violations = check_prose_surface_reads_no_width_class(self.files)
        self.assertEqual(violations, [], violations)

    def test_prose_surface_no_truncation(self):
        violations = check_prose_surface_no_truncation(self.files)
        self.assertEqual(violations, [], violations)

    def test_prose_surface_no_horizontal_panning(self):
        violations = check_prose_surface_no_horizontal_panning(self.files)
        self.assertEqual(violations, [], violations)

    def test_prose_surface_scroll_only_via_decision(self):
        violations = check_prose_surface_scroll_only_via_decision(self.files)
        self.assertEqual(violations, [], violations)

    def test_prose_surface_thread_metadata_rendered(self):
        violations = check_prose_surface_thread_metadata_rendered(self.files)
        self.assertEqual(violations, [], violations)

    def test_conversation_error_notice_is_rendered(self):
        violations = check_conversation_error_notice_is_rendered(self.files)
        self.assertEqual(violations, [], violations)

    def test_prose_surface_renders_every_resolution_case(self):
        violations = check_prose_surface_renders_every_resolution_case(self.files)
        self.assertEqual(violations, [], violations)

    def test_no_client_side_markdown_parsing(self):
        violations = check_no_client_side_markdown_parsing(self.files)
        self.assertEqual(violations, [], violations)

    def test_lang_not_discarded_in_prose_surface(self):
        violations = check_lang_not_discarded_in_prose_surface(self.files)
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
