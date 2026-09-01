// NostromoKit — FocusRegionStateTests.swift
//
// Behavioural tests for `FocusRegionState` (W5 — ios-curated-view-parity):
// D4's layout-change transition table (which classifications may move the
// frontmost pane, and the operator's own `focusedPane` always winning when
// present), D7's per-pane unread tracking, and the small `PaneTree`
// extension `resolvedActivePaneId` the transition table is fed from.
//
// The single most important case here is `.contentOnly` never moving the
// frontmost pane even when the tree's own active pointer disagrees with it —
// "don't fight the operator" — since a content-only push is by far the most
// frequent broadcast and the one most likely to regress this if the
// transition table is ever simplified carelessly.
import XCTest
@testable import NostromoKit

final class FocusRegionStateTests: XCTestCase {

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

    /// The region path this wedge actually uses everywhere (W6 adds real
    /// per-region paths later) — see `FocusRegionState.compactRegion`.
    private let region = FocusRegionState.compactRegion

    // MARK: - D4 transition table: .contentOnly never moves the frontmost pane

    func testContentOnlyNeverMovesTheFrontmostPaneEvenWhenTreeActivePaneIdDisagrees() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: region, contentVersion: 1)

        state.apply(
            change: .contentOnly, regionPath: region,
            treeActivePaneId: "b", focusedPane: nil, available: ["repl", "a", "b"]
        )

        XCTAssertEqual(
            state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "a",
            "a content-only push must never fight the operator's own selection"
        )
    }

    func testIdenticalChangesNothing() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: region, contentVersion: 1)

        state.apply(
            change: .identical, regionPath: region,
            treeActivePaneId: "b", focusedPane: nil, available: ["repl", "a", "b"]
        )

        XCTAssertEqual(state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "a")
    }

    // MARK: - D4 transition table: these DO honor treeActivePaneId

    func testActiveTabOnlyHonorsTreeActivePaneIdWhenPresentAndAvailable() {
        var state = FocusRegionState()
        state.apply(
            change: .activeTabOnly(paths: ["root.1"]), regionPath: region,
            treeActivePaneId: "b", focusedPane: nil, available: ["repl", "a", "b"]
        )
        XCTAssertEqual(state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "b")
    }

    func testTabMembershipHonorsTreeActivePaneIdWhenPresentAndAvailable() {
        var state = FocusRegionState()
        state.apply(
            change: .tabMembership(paths: ["root.1"]), regionPath: region,
            treeActivePaneId: "b", focusedPane: nil, available: ["repl", "a", "b"]
        )
        XCTAssertEqual(state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "b")
    }

    func testSplitTopologyHonorsTreeActivePaneIdWhenPresentAndAvailable() {
        var state = FocusRegionState()
        state.apply(
            change: .splitTopology, regionPath: region,
            treeActivePaneId: "b", focusedPane: nil, available: ["repl", "a", "b"]
        )
        XCTAssertEqual(state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "b")
    }

    // MARK: - `focusedPane` always wins over `treeActivePaneId`, regardless of classification

    func testFocusedPaneWinsOverTreeActivePaneIdRegardlessOfClassification() {
        var state = FocusRegionState()
        state.apply(
            change: .activeTabOnly(paths: ["root.1"]), regionPath: region,
            treeActivePaneId: "b", focusedPane: "a", available: ["repl", "a", "b"]
        )
        XCTAssertEqual(
            state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "a",
            "focusedPane must win over treeActivePaneId when both are set and differ"
        )
    }

    func testFocusedPaneAbsentFromAvailableIsIgnoredFallingThroughToTreeActivePaneId() {
        var state = FocusRegionState()
        state.apply(
            change: .activeTabOnly(paths: ["root.1"]), regionPath: region,
            treeActivePaneId: "b", focusedPane: "ghost-pane-not-available", available: ["repl", "a", "b"]
        )
        XCTAssertEqual(
            state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "b",
            "a focusedPane naming a pane absent from available must be ignored, not crash or win anyway"
        )
    }

    // MARK: - Frontmost pane disappearing falls back to repl

    func testFrontmostPaneDisappearingFallsBackToReplWhenReplIsAvailable() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: region, contentVersion: 1)

        // "a" is no longer in `available` — e.g. removed by reset_panes.
        let frontmost = state.frontmostPane(for: region, available: ["repl", "b"], fallback: "repl")
        XCTAssertEqual(frontmost, "repl", "today's preserved behavior: fall back to repl when it's available")
    }

    func testFrontmostPaneNeverRecordedFallsBackToFallbackWhenAvailable() {
        let state = FocusRegionState()
        let frontmost = state.frontmostPane(for: region, available: ["repl", "a"], fallback: "repl")
        XCTAssertEqual(frontmost, "repl", "nothing recorded yet — falls back to the given fallback")
    }

    func testFrontmostPaneFallsBackToFirstAvailableWhenNeitherRecordedNorFallbackIsAvailable() {
        let state = FocusRegionState()
        let frontmost = state.frontmostPane(for: region, available: ["x", "y"], fallback: "repl")
        XCTAssertEqual(frontmost, "x", "falls back to the first available pane when the fallback itself isn't available")
    }

    // MARK: - D7 unread tracking

    func testANoteContentVersionBumpForANonFrontmostPaneMarksItUnread() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: region, contentVersion: 1)

        state.noteContentVersion(paneId: "b", regionPath: region, contentVersion: 2)

        XCTAssertTrue(state.isUnread(paneId: "b", regionPath: region, contentVersion: 2))
    }

    func testSelectingAnUnreadPaneClearsItsMarkAndMakesItFrontmost() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: region, contentVersion: 1)
        state.noteContentVersion(paneId: "b", regionPath: region, contentVersion: 2)
        XCTAssertTrue(state.isUnread(paneId: "b", regionPath: region, contentVersion: 2), "sanity check")

        state.select(paneId: "b", regionPath: region, contentVersion: 2)

        XCTAssertFalse(state.isUnread(paneId: "b", regionPath: region, contentVersion: 2))
        XCTAssertEqual(state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "b")
    }

    func testNoteContentVersionForTheFrontmostPaneNeverMarksItUnread() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: region, contentVersion: 1)

        state.noteContentVersion(paneId: "a", regionPath: region, contentVersion: 5)

        XCTAssertFalse(
            state.isUnread(paneId: "a", regionPath: region, contentVersion: 5),
            "a push to the visible/frontmost pane must never be marked unread"
        )
    }

    // MARK: - Two region paths are independent

    func testTwoDifferentRegionPathsAreIndependentForBothFrontmostAndUnread() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: "root", contentVersion: 1)
        state.select(paneId: "x", regionPath: "root.1", contentVersion: 1)

        state.noteContentVersion(paneId: "b", regionPath: "root", contentVersion: 2)

        XCTAssertTrue(state.isUnread(paneId: "b", regionPath: "root", contentVersion: 2))
        XCTAssertFalse(
            state.isUnread(paneId: "b", regionPath: "root.1", contentVersion: 2),
            "an unread mark recorded under one region path must not leak into another"
        )
        XCTAssertEqual(state.frontmostPane(for: "root", available: ["repl", "a", "b"], fallback: "repl"), "a")
        XCTAssertEqual(state.frontmostPane(for: "root.1", available: ["repl", "x"], fallback: "repl"), "x")
    }

    // MARK: - resolvedActivePaneId

    func testResolvedActivePaneIdForASingleTabsNodeRecursingThroughANestedSplit() {
        let tree = split(.horizontal, [
            leaf("repl"),
            tabs([
                leaf("a"),
                split(.vertical, [leaf("b1"), leaf("b2")], [0.5, 0.5])
            ], ["A", "B"], active: 1)
        ], [0.5, 0.5])

        // active: 1 selects the nested split; a plain split has no "active"
        // concept of its own, so its first child breaks the tie.
        XCTAssertEqual(tree.resolvedActivePaneId, "b1")
    }

    func testResolvedActivePaneIdForASingleTabsNodeWithALeafActiveChild() {
        let tree = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
        XCTAssertEqual(tree.resolvedActivePaneId, "a")
    }

    func testResolvedActivePaneIdIsNilWhenNoTabsNodeExistsAnywhere() {
        let tree = split(.horizontal, [leaf("repl"), leaf("a")], [0.5, 0.5])
        XCTAssertNil(tree.resolvedActivePaneId)
    }

    func testResolvedActivePaneIdIsNilWhenTwoTabsNodesDisagree() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            tabs([leaf("c"), leaf("d")], ["C", "D"], active: 1)
        ], [0.5, 0.5])
        XCTAssertNil(
            tree.resolvedActivePaneId,
            "two simultaneously-visible tabs regions with disagreeing resolutions must not be guessed at"
        )
    }

    // MARK: - Scroll key round-tripping

    func testScrollKeyRoundTrips() {
        var state = FocusRegionState()
        state.setScrollKey(42, for: "a")
        XCTAssertEqual(state.scrollKey(for: "a"), 42)
    }

    func testScrollKeyForAnUnsetPaneIsNil() {
        let state = FocusRegionState()
        XCTAssertNil(state.scrollKey(for: "never-set"))
    }

    func testSettingScrollKeyForOnePaneDoesNotAffectAnother() {
        var state = FocusRegionState()
        state.setScrollKey(1, for: "a")
        state.setScrollKey(2, for: "b")
        XCTAssertEqual(state.scrollKey(for: "a"), 1)
        XCTAssertEqual(state.scrollKey(for: "b"), 2)
    }

    // MARK: - Scroll keys and unread marks for persisting panes survive a rebuild

    func testScrollKeysAndUnreadMarksForPersistingPanesSurviveASplitTopologyChangeUntouched() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: region, contentVersion: 1)
        state.setScrollKey(7, for: "b")
        state.noteContentVersion(paneId: "b", regionPath: region, contentVersion: 2)
        XCTAssertTrue(state.isUnread(paneId: "b", regionPath: region, contentVersion: 2), "sanity check")

        // A rebuild with no tree-resolved active pane and no operator focus —
        // only .splitTopology's own possible frontmost move is in play, and
        // here there's nothing to move it to.
        state.apply(
            change: .splitTopology, regionPath: region,
            treeActivePaneId: nil, focusedPane: nil, available: ["repl", "a", "b"]
        )

        XCTAssertEqual(state.scrollKey(for: "b"), 7, "a persisting pane's scroll key must survive a rebuild")
        XCTAssertTrue(
            state.isUnread(paneId: "b", regionPath: region, contentVersion: 2),
            "a persisting pane's unread mark must survive a rebuild"
        )
        XCTAssertEqual(
            state.frontmostPane(for: region, available: ["repl", "a", "b"], fallback: "repl"), "a",
            "frontmost is untouched when there's nothing for .splitTopology to move it to"
        )
    }
}
