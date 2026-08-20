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
/// behind `if clearRatios`, and only the `.splitTopology` branch of
/// `handleLayoutUpdate` ever passes `clearRatios: true` — the initial
/// `setup()` render, and every other branch, must not.
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

    func testOnlyTheSplitTopologyCaseOfHandleLayoutUpdatePassesClearRatiosTrue() throws {
        let source = try Self.dynamicFocusViewSource()
        guard let trueRange = source.range(of: "clearRatios: true") else {
            XCTFail("no clearRatios: true call site found")
            return
        }
        let remaining = source[trueRange.upperBound...].components(separatedBy: "clearRatios: true").count - 1
        XCTAssertEqual(
            remaining, 0,
            "exactly one call site must pass clearRatios: true — every other structural path must preserve ratios"
        )

        // The nearest enclosing `case` label — found by scanning backwards,
        // so it's immune to any unrelated `case` elsewhere in the file —
        // must be `.splitTopology`.
        let before = source[..<trueRange.lowerBound]
        guard let lastCaseRange = before.range(of: "\n        case ", options: .backwards) else {
            XCTFail("no enclosing `case` label found before the clearRatios: true call")
            return
        }
        let caseLine = before[lastCaseRange.upperBound...].prefix { $0 != "\n" }
        XCTAssertTrue(
            caseLine.contains(".splitTopology"),
            "clearRatios: true must be called from within case .splitTopology specifically, found case line: \(caseLine)"
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
