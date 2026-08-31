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
    check_no_pane_id_visible_via_capitalized,
    check_no_second_bottom_tab_bar,
    check_no_root_tab_hijack,
    check_no_frontmost_tab_state_in_view,
    check_no_local_placement_or_ratio_persistence,
    check_unread_glyph_uses_opacity_not_conditional_insertion,
    check_ticker_survives_the_rewrite,
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
