import XCTest
// PaneTree, SplitDirection, LayoutChange and LayoutChangeClassifier are
// compiled into this target directly (logic test — no host app, no window).
// No module imports needed.

// MARK: - LayoutChangeClassifierTests

/// Behavioural tests for `LayoutChangeClassifier` (W1 — curated-agent-views).
///
/// This classifier is what the ratio-preservation and scroll-restore
/// acceptance criteria actually rest on: `DynamicFocusView` only clears saved
/// split ratios (`clearSavedRatios`) on the `.splitTopology` path, so every
/// case here that must NOT produce `.splitTopology` is asserting, in effect,
/// "opening/closing/switching a tab must not wipe the operator's dragged
/// splits." The two live defects named in the wedge plan — a direction/ratio
/// -only change being swallowed as content-only, and tabs membership/active
/// changes never having existed as a concept at all — are covered here too.
final class LayoutChangeClassifierTests: XCTestCase {

    // MARK: - Fixtures

    private func leaf(_ id: String) -> PaneTree { .leaf(paneId: id) }

    private func split(
        _ direction: SplitDirection = .horizontal,
        _ children: [PaneTree],
        _ ratios: [Double]
    ) -> PaneTree {
        .split(direction: direction, children: children, ratios: ratios)
    }

    private func tabs(_ children: [PaneTree], _ labels: [String], active: Int) -> PaneTree {
        .tabs(children: children, labels: labels, active: active)
    }

    // MARK: - .identical

    func testByteIdenticalTreesClassifyAsIdentical() {
        let tree = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: tree, new: tree), .identical)
    }

    func testEqualButSeparatelyConstructedTreesClassifyAsIdentical() {
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .identical)
    }

    // MARK: - .contentOnly / .identical (nothing structural, the common case)

    func testSameShapeAndIdsClassifiesAsIdentical() {
        // The tree itself never carries content, so this is what actually
        // fires on the vast majority of `PaneContent` broadcasts: the tree in
        // the republished `FocusLayoutModel` is unchanged. Two separately
        // built trees with identical shape/ids/ratios are `==`, so this is
        // `.identical`, not `.contentOnly` — see `LayoutChangeClassifier`'s
        // doc comment on `.contentOnly` for why the latter is a defensive
        // bucket rather than one this comparison can actually produce today.
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .identical)
    }

    // MARK: - .splitTopology (the two previously-swallowed defects)

    func testDirectionOnlyChangeIsClassifiedAsSplitTopologyNotSwallowed() {
        // Same pane ids, same order, same ratios — only direction differs.
        // The old `paneIds`-array comparison would have missed this entirely.
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.vertical, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology)
    }

    func testRatiosOnlyChangeIsClassifiedAsSplitTopologyNotSwallowed() {
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.3, 0.7])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology)
    }

    func testChildCountChangeIsSplitTopology() {
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), leaf("jobs"), leaf("log")], [0.34, 0.33, 0.33])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology)
    }

    func testLeafSwappedForADifferentPaneAtTheSamePositionIsSplitTopology() {
        // Same split shape, same ratios — but a different pane occupies the
        // second slot. Not a tabs concern, so it must still force a rebuild.
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), leaf("notes")], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology)
    }

    func testALeafBecomingASplitAtAFixedPositionIsSplitTopology() {
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), split(.vertical, [leaf("jobs"), leaf("log")], [0.5, 0.5])], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology)
    }

    // MARK: - W3 — a detail region (a tabs node) appearing/disappearing at a fixed
    // position is .splitTopology, never repairable in place. This pins an invariant the W3
    // investigation *used* but did not itself break — the empirically confirmed root cause of
    // "correct gutter, blank body" was an unclipped ruler fill in CodeContentView.swift, not a
    // tree divergence — so both tests below are expected to pass immediately against `main`.
    // They exist so a future change to this classifier can't silently start treating "the detail
    // region just appeared" as a repairable content-only change, which is the one thing that
    // would make a freshly materialized tabs region arrive with no chrome around it.

    func testADetailRegionAppearingWhereALeafUsedToBeIsSplitTopology() {
        let old = split(.horizontal, [leaf("queue"), leaf("repl")], [0.5, 0.5])
        let new = split(
            .horizontal,
            [leaf("queue"), tabs([leaf("detail.0")], ["Conversation"], active: 0)],
            [0.5, 0.5]
        )
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology, """
            a detail region materializing where a bare leaf used to be is a structural change — \
            DynamicFocusView must rebuild that slot from scratch (and, per the ratio-preservation \
            invariant this classifier exists for, may clear saved ratios) rather than attempt an \
            in-place repair that could leave a tabs node partially wired.
            """)
    }

    func testADetailRegionDisappearingBackToALeafIsSplitTopology() {
        let old = split(
            .horizontal,
            [leaf("queue"), tabs([leaf("detail.0")], ["Conversation"], active: 0)],
            [0.5, 0.5]
        )
        let new = split(.horizontal, [leaf("queue"), leaf("repl")], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology, """
            the symmetrical removal — a detail region's last tab closing and the region \
            collapsing back to a bare leaf (see PaneTree/tree.rs's remove_tabs_region on the \
            daemon side) — must be classified the same as its appearance: a full rebuild, not a \
            repair.
            """)
    }

    // MARK: - .activeTabOnly (no teardown)

    func testActiveTabChangeAloneIsClassifiedAsActiveTabOnly() {
        let old = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 1)], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .activeTabOnly(paths: ["root.1"]))
    }

    func testActiveTabChangeDoesNotClearSavedRatiosPathIsDistinctFromSplitTopology() {
        // Sanity: an active-only change must never be reported as
        // .splitTopology — that's the one case that clears saved ratios, and
        // switching tabs must never do that.
        let old = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
        let new = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 1)
        XCTAssertNotEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology)
    }

    // MARK: - .tabMembership (opening/closing/reordering/relabeling a tab)

    // W3 note: "a tabs node gaining a child while the split shape is unchanged is
    // .tabMembership, never .splitTopology" is already covered exactly by
    // testOpeningANewTabIsClassifiedAsTabMembershipNotSplitTopology immediately below (and its
    // sibling testClosingATabIsClassifiedAsTabMembership for the removal direction) — not
    // duplicated here.

    func testOpeningANewTabIsClassifiedAsTabMembershipNotSplitTopology() {
        let old = split(.horizontal, [leaf("repl"), tabs([leaf("ticket")], ["Ticket"], active: 0)], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .tabMembership(paths: ["root.1"]))
    }

    func testClosingATabIsClassifiedAsTabMembership() {
        let old = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), tabs([leaf("ticket")], ["Ticket"], active: 0)], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .tabMembership(paths: ["root.1"]))
    }

    func testRelabelingATabWithNoMembershipChangeIsClassifiedAsTabMembership() {
        let old = tabs([leaf("ticket")], ["Ticket"], active: 0)
        let new = tabs([leaf("ticket")], ["Ticket (updated)"], active: 0)
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .tabMembership(paths: ["root"]))
    }

    func testReorderingTabsIsClassifiedAsTabMembership() {
        let old = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
        let new = tabs([leaf("b"), leaf("a")], ["B", "A"], active: 0)
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .tabMembership(paths: ["root"]))
    }

    func testTabMembershipChangeDoesNotClearSavedRatiosPathIsDistinctFromSplitTopology() {
        let old = split(.horizontal, [leaf("repl"), tabs([leaf("ticket")], ["Ticket"], active: 0)], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)], [0.5, 0.5])
        XCTAssertNotEqual(
            LayoutChangeClassifier.classify(old: old, new: new), .splitTopology,
            "opening a tab must never be classified in the one bucket that clears the operator's dragged ratios"
        )
    }

    // MARK: - focused_pane is out of scope for this classifier

    // `focused_pane` lives on `FocusLayoutModel`, not on `PaneTree` itself —
    // this classifier only ever sees trees, so there is nothing to test here;
    // that behaviour belongs to whatever reads `model.focusedPane` directly.

    // MARK: - Split topology recursion

    func testSplitTopologyChangeNestedInsideATabsRegionIsDetected() {
        // A tab child that is itself a malformed/changed split must still be
        // caught — the split signature walk recurses into tab children.
        let old = tabs(
            [split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5])],
            ["Nested"],
            active: 0
        )
        let new = tabs(
            [split(.vertical, [leaf("a"), leaf("b")], [0.5, 0.5])],
            ["Nested"],
            active: 0
        )
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .splitTopology)
    }

    func testDeeplyNestedActiveTabChangeReportsItsOwnPath() {
        let old = split(
            .horizontal,
            [leaf("repl"),
             split(.vertical, [tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0), leaf("footer")], [0.7, 0.3])],
            [0.5, 0.5]
        )
        let new = split(
            .horizontal,
            [leaf("repl"),
             split(.vertical, [tabs([leaf("a"), leaf("b")], ["A", "B"], active: 1), leaf("footer")], [0.7, 0.3])],
            [0.5, 0.5]
        )
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .activeTabOnly(paths: ["root.1.0"]))
    }

    // MARK: - Path-scheme agreement with PaneRenderPlan

    // LayoutChangeClassifier.swift:52-57 asserts, in a comment, that this
    // classifier's dotted path scheme agrees with the other implementations
    // that independently walk the same tree with the same convention:
    // DynamicFocusView.buildView and PaneRenderPlan.build. These tests turn
    // that comment into an executable invariant for the PaneRenderPlan half
    // — every path this classifier reports inside an
    // .activeTabOnly/.tabMembership case must resolve to an actual tabs node
    // at that same path in PaneRenderPlan.build(from: new).tabsNodes. If the
    // two implementations ever drift apart, DynamicFocusView.applyActiveTabOnly/
    // applyTabMembership would be handed a path that either doesn't exist in
    // the plan or points at the wrong node — the exact "bookkeeping disagrees
    // with what's on screen" failure mode this branch fixes.

    func testActiveTabOnlyPathsAgreeWithPaneRenderPlansTabsNodePaths() {
        let old = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 1)], [0.5, 0.5])

        guard case .activeTabOnly(let paths) = LayoutChangeClassifier.classify(old: old, new: new) else {
            XCTFail("expected .activeTabOnly")
            return
        }
        let planPaths = Set(PaneRenderPlan.build(from: new).tabsNodes.map(\.path))
        for path in paths {
            XCTAssertTrue(planPaths.contains(path), """
                classifier reported \(path) as .activeTabOnly, but PaneRenderPlan has no tabs node at that path — \
                the two path schemes have drifted apart
                """)
        }
    }

    func testTabMembershipPathsAgreeWithPaneRenderPlansTabsNodePaths() {
        let old = split(.horizontal, [leaf("repl"), tabs([leaf("ticket")], ["Ticket"], active: 0)], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)], [0.5, 0.5])

        guard case .tabMembership(let paths) = LayoutChangeClassifier.classify(old: old, new: new) else {
            XCTFail("expected .tabMembership")
            return
        }
        let planPaths = Set(PaneRenderPlan.build(from: new).tabsNodes.map(\.path))
        for path in paths {
            XCTAssertTrue(planPaths.contains(path), """
                classifier reported \(path) as .tabMembership, but PaneRenderPlan has no tabs node at that path — \
                the two path schemes have drifted apart
                """)
        }
    }

    func testDeeplyNestedActiveTabOnlyPathAgreesWithPaneRenderPlan() {
        let old = split(
            .horizontal,
            [leaf("repl"),
             split(.vertical, [tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0), leaf("footer")], [0.7, 0.3])],
            [0.5, 0.5]
        )
        let new = split(
            .horizontal,
            [leaf("repl"),
             split(.vertical, [tabs([leaf("a"), leaf("b")], ["A", "B"], active: 1), leaf("footer")], [0.7, 0.3])],
            [0.5, 0.5]
        )

        guard case .activeTabOnly(let paths) = LayoutChangeClassifier.classify(old: old, new: new) else {
            XCTFail("expected .activeTabOnly")
            return
        }
        let planPaths = Set(PaneRenderPlan.build(from: new).tabsNodes.map(\.path))
        for path in paths {
            XCTAssertTrue(planPaths.contains(path), """
                classifier reported \(path) as .activeTabOnly, but PaneRenderPlan has no tabs node at that path — \
                the two path schemes have drifted apart
                """)
        }
    }
}

// MARK: - DynamicFocusViewClearRatiosWiringTests

/// A fitness function, not a behavioural test — the same spirit as
/// `ImageDecodePolicyTests` and `TurnInteractionWiringTests`. `DynamicFocusView`
/// is deliberately not on `NostromoTests`' dual Sources/TestSources list (see
/// `LayoutChangeClassifier.swift`'s doc comment for why it's the extracted
/// classifier, not the view, that gets that treatment) — it needs a real
/// window to mean anything, so `renderLayout`/`clearSavedRatios` can only be
/// exercised end-to-end by hand (`make mac-run`), not by this logic-test bundle.
///
/// What CAN be checked here, cheaply and durably, is that the source text
/// still wires `clearRatios` the way the ratio-preservation acceptance
/// criteria require: `clearSavedRatios(for:` has exactly one call site, gated
/// behind `if clearRatios`, and `clearRatios: true` is only ever passed from
/// two places: the `.splitTopology` branch of `handleLayoutUpdate` (a
/// genuine agent-authored structural change) and, as of
/// fix-collapsed-split-ratio-persistence D5, `performLayoutReset` — the
/// operator-facing "Reset Layout" escape hatch, which deliberately reuses
/// this exact same clear-and-rebuild path rather than duplicating it. The
/// initial `setup()` render, and every other branch, must still not.
final class DynamicFocusViewClearRatiosWiringTests: XCTestCase {

    private static func dynamicFocusViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/LayoutChangeClassifierTests.swift
            .deletingLastPathComponent()                     // …/macOS/NostromoTests
            .deletingLastPathComponent()                     // …/macOS
            .appendingPathComponent("Nostromo/UI/Views/DynamicFocusView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testClearSavedRatiosHasExactlyOneCallSiteGatedByClearRatios() throws {
        let source = try Self.dynamicFocusViewSource()
        guard let callRange = source.range(of: "clearSavedRatios(for:") else {
            XCTFail("clearSavedRatios(for: call site not found — did it move or rename?")
            return
        }
        let remaining = source[callRange.upperBound...].components(separatedBy: "clearSavedRatios(for:").count - 1
        XCTAssertEqual(
            remaining, 0,
            "clearSavedRatios must have exactly one call site — the ratio-preservation criteria assume a single choke point"
        )

        // The call must be gated behind `if clearRatios {` — found by scanning
        // backwards from the call site for the nearest enclosing `if`, which
        // tolerates any comments/blank lines between the guard and the call.
        let before = source[..<callRange.lowerBound]
        guard let guardRange = before.range(of: "if clearRatios {", options: .backwards) else {
            XCTFail("no enclosing `if clearRatios {` found before the clearSavedRatios call")
            return
        }
        // And there must be no intervening closing brace between the guard
        // and the call — i.e. the call is still inside that `if`'s body, not
        // merely somewhere earlier in the same function.
        let between = source[guardRange.upperBound..<callRange.lowerBound]
        XCTAssertFalse(
            between.contains("}"),
            "clearSavedRatios must run unconditionally-within, not after, the `if clearRatios` guard: \(between)"
        )
    }

    /// Every occurrence, in file order, of the literal `needle` in `source`.
    private static func allRanges(of needle: String, in source: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = source.startIndex
        while let range = source.range(of: needle, range: searchStart..<source.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    /// Exactly two call sites may ever pass `clearRatios: true`:
    /// - the `.splitTopology` branch of `handleLayoutUpdate` — a genuine
    ///   agent-authored structural change, PR #122's original invariant;
    /// - `performLayoutReset` — fix-collapsed-split-ratio-persistence D5's
    ///   "Reset Layout" operator escape hatch, which deliberately reuses
    ///   this exact clear-and-rebuild path (via `reconcile`) rather than
    ///   duplicating `clearSavedRatios`/rebuild logic. `reconcile` and
    ///   `clearSavedRatios` are themselves untouched by D5 — this is a new
    ///   *caller*, not a new code path — so this test's job is only to keep
    ///   that caller enumerated and closed to any third, unintended one.
    ///
    /// Every other structural path must still preserve ratios.
    func testOnlyTheSplitTopologyCaseAndPerformLayoutResetPassClearRatiosTrue() throws {
        let source = try Self.dynamicFocusViewSource()
        let trueRanges = Self.allRanges(of: "clearRatios: true", in: source)

        XCTAssertEqual(trueRanges.count, 2, """
            Exactly two call sites may pass clearRatios: true — the `.splitTopology` case of \
            handleLayoutUpdate and performLayoutReset (D5's Reset Layout entry point). Every other structural \
            path must preserve ratios. Found \(trueRanges.count):
            \(trueRanges.map { String(source[$0]) }.joined(separator: "\n"))
            """)
        guard trueRanges.count == 2 else { return }

        // The first must be inside case .splitTopology of the switch in
        // handleLayoutUpdate — found by scanning backwards for the nearest
        // enclosing `case` label, so it's immune to any unrelated `case`
        // elsewhere in the file.
        let firstBefore = source[..<trueRanges[0].lowerBound]
        guard let lastCaseRange = firstBefore.range(of: "\n        case ", options: .backwards) else {
            XCTFail("no enclosing `case` label found before the first clearRatios: true call")
            return
        }
        let caseLine = firstBefore[lastCaseRange.upperBound...].prefix { $0 != "\n" }
        XCTAssertTrue(
            caseLine.contains(".splitTopology"),
            "the first clearRatios: true must be called from within case .splitTopology specifically, found case line: \(caseLine)"
        )

        // The second must be inside a function named performLayoutReset —
        // found by scanning backwards for the nearest enclosing `func`, the
        // same "scope since the last `func` keyword" approximation
        // DynamicFocusViewWiringTests uses elsewhere.
        let secondBefore = source[..<trueRanges[1].lowerBound]
        guard let precedingFunc = secondBefore.range(of: "func ", options: .backwards) else {
            XCTFail("no enclosing func found before the second clearRatios: true call")
            return
        }
        let funcLine = source[source.lineRange(for: precedingFunc)]
        XCTAssertTrue(
            funcLine.contains("performLayoutReset"),
            "the second clearRatios: true must be called from within performLayoutReset — D5's Reset Layout entry point — found: \(funcLine)"
        )
    }

    func testSetupsInitialRenderDoesNotClearRatios() throws {
        let source = try Self.dynamicFocusViewSource()
        guard let setupRange = source.range(of: "private func setup() {") else {
            XCTFail("setup() not found — did DynamicFocusView change shape?")
            return
        }
        let afterSetup = source[setupRange.upperBound...]
        let nextFuncRange = afterSetup.range(of: "\n    private func handleLayoutUpdate")
        let setupBody = nextFuncRange.map { afterSetup[..<$0.lowerBound] } ?? afterSetup
        XCTAssertTrue(
            setupBody.contains("clearRatios: false"),
            "the initial render in setup() must pass clearRatios: false — a relaunch must be able to restore saved ratios"
        )
    }
}
