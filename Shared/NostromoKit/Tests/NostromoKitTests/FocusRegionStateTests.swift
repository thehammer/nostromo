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

    // MARK: - W8: the selected-file slot (pr_diff's per-pane "which file is open")
    //
    // Keyed the same way scrollKeys already is (per-pane, not per-region), and
    // additionally scoped by an identity string the caller passes at both
    // write and read time — `"\(repo)#\(number)"`-shaped. A changed PR means
    // a changed identity, so the old file silently stops resolving rather
    // than needing an explicit clear when the pane's content changes to a
    // different PR.

    func testSelectedFileRoundTrips() {
        var state = FocusRegionState()
        state.setSelectedFile("src/a.rs", identity: "acme/web#1", for: "diff-pane")
        XCTAssertEqual(state.selectedFile(for: "diff-pane", identity: "acme/web#1"), "src/a.rs")
    }

    func testSelectedFileForAPaneNeverSetIsNil() {
        let state = FocusRegionState()
        XCTAssertNil(state.selectedFile(for: "never-set", identity: "acme/web#1"))
    }

    func testSelectedFileReadWithADifferentIdentityThanItWasWrittenWithIsNil() {
        var state = FocusRegionState()
        state.setSelectedFile("src/a.rs", identity: "acme/web#1", for: "diff-pane")
        XCTAssertNil(
            state.selectedFile(for: "diff-pane", identity: "acme/web#2"),
            "a changed PR means a changed identity — the old file must silently stop resolving, not keep answering for a different PR"
        )
    }

    func testSettingSelectedFileForOnePaneDoesNotAffectAnother() {
        var state = FocusRegionState()
        state.setSelectedFile("src/a.rs", identity: "acme/web#1", for: "pane-a")
        state.setSelectedFile("src/b.rs", identity: "acme/web#1", for: "pane-b")
        XCTAssertEqual(state.selectedFile(for: "pane-a", identity: "acme/web#1"), "src/a.rs")
        XCTAssertEqual(state.selectedFile(for: "pane-b", identity: "acme/web#1"), "src/b.rs")
    }

    func testSelectedFileSurvivesASplitTopologyChangeUntouched() {
        var state = FocusRegionState()
        state.setSelectedFile("src/a.rs", identity: "acme/web#1", for: "diff-pane")

        state.apply(
            change: .splitTopology, regionPath: region,
            treeActivePaneId: nil, focusedPane: nil, available: ["repl", "diff-pane"]
        )

        XCTAssertEqual(
            state.selectedFile(for: "diff-pane", identity: "acme/web#1"), "src/a.rs",
            "the selected file must survive a .splitTopology rebuild the same way scroll keys and unread marks do"
        )
    }

    func testPruneDropsTheSelectedFileForAPaneNoLongerLive() {
        var state = FocusRegionState()
        state.setSelectedFile("src/a.rs", identity: "acme/web#1", for: "diff-pane")

        state.prune(livePaths: [], livePanes: [])

        XCTAssertNil(state.selectedFile(for: "diff-pane", identity: "acme/web#1"))
    }

    func testPruneKeepsTheSelectedFileForAPaneStillLive() {
        var state = FocusRegionState()
        state.setSelectedFile("src/a.rs", identity: "acme/web#1", for: "diff-pane")

        state.prune(livePaths: [], livePanes: ["diff-pane"])

        XCTAssertEqual(state.selectedFile(for: "diff-pane", identity: "acme/web#1"), "src/a.rs")
    }

    // MARK: - W8: per-file scroll-restore key
    //
    // One open diff pane can show different files at different times, and a
    // single Int scroll slot keyed only by paneId can't tell one file's saved
    // row from another's — this trio is semantically identical to the bare
    // paneId scroll-key trio above, just additionally keyed by `file`.

    func testPerFileScrollKeyRoundTrips() {
        var state = FocusRegionState()
        state.setScrollKey(42, for: "diff-pane", file: "a.rs")
        XCTAssertEqual(state.scrollKey(for: "diff-pane", file: "a.rs"), 42)
    }

    func testPerFileScrollKeyForAnUnsetFileIsNil() {
        let state = FocusRegionState()
        XCTAssertNil(state.scrollKey(for: "diff-pane", file: "never-set.rs"))
    }

    func testTwoFilesUnderTheSamePaneDoNotCollide() {
        var state = FocusRegionState()
        state.setScrollKey(10, for: "diff-pane", file: "a.rs")
        state.setScrollKey(20, for: "diff-pane", file: "b.rs")
        XCTAssertEqual(state.scrollKey(for: "diff-pane", file: "a.rs"), 10)
        XCTAssertEqual(state.scrollKey(for: "diff-pane", file: "b.rs"), 20)
    }

    func testPerFileScrollRestoreMirrorsTheBarePaneIdRule() {
        var state = FocusRegionState()
        state.setScrollKey(50, for: "diff-pane", file: "a.rs")
        XCTAssertEqual(
            state.scrollRestore(for: "diff-pane", file: "a.rs", visibleRange: 0...10), .scrollTo(target: 50),
            "a key outside the visible range must scroll to it"
        )
        XCTAssertEqual(
            state.scrollRestore(for: "diff-pane", file: "a.rs", visibleRange: 40...60), .none,
            "a key already inside the visible range must not move the viewport"
        )
    }

    func testPruneDropsAPanesEntirePerFileScrollMapWhenThatPaneIsNoLongerLive() {
        var state = FocusRegionState()
        state.setScrollKey(10, for: "diff-pane", file: "a.rs")
        state.setScrollKey(20, for: "diff-pane", file: "b.rs")

        state.prune(livePaths: [], livePanes: [])

        XCTAssertNil(state.scrollKey(for: "diff-pane", file: "a.rs"))
        XCTAssertNil(state.scrollKey(for: "diff-pane", file: "b.rs"))
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

    // MARK: - W6: surviving a width-class change
    //
    // D5's losslessness requirement: rotating an iPad or dragging a
    // multitasking divider changes `layoutPlan`'s output live, with no
    // relaunch, and must not disturb frontmost tabs, unread marks, or scroll
    // positions. `FocusRegionState` survives this "for free" only because
    // region paths are a pure function of the tree, not of which
    // presentation is on screen (`LayoutPlanTests`'s path-stability suite
    // proves that half). What's proven here is the other half: that reading
    // and writing through those paths actually round-trips a real
    // operator action across a width-class change.
    //
    // A `tabs` node sitting directly at the tree's root is the one shape
    // where compact's single region (always `FocusRegionState.compactRegion`
    // — see W5) and regular width's own region path for that SAME node are
    // the literal same string, both derived from the actual tree via
    // `layoutPlan` rather than assumed. For any other shape, regular width
    // fans the tree out into several regions ("root.0", "root.1", …) that
    // compact's one strip conflates, so there is no single region to
    // compare state against across the two presentations.

    private func rootTabsTree() -> PaneTree {
        tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
    }

    private func regularTabbedPath(for tree: PaneTree) -> String {
        guard case .regions(let node) = layoutPlan(tree: tree, width: .regular, content: [:]),
              case .tabbed(let path, _) = node else {
            XCTFail("expected a top-level .tabbed region")
            return ""
        }
        return path
    }

    func testARootLevelTabsNodesOwnRegionPathEqualsCompactsSingleRegion() {
        // Sanity check underpinning every test below: without this
        // coincidence, comparing state "across a width-class change" for
        // this tree shape would be meaningless.
        XCTAssertEqual(regularTabbedPath(for: rootTabsTree()), FocusRegionState.compactRegion)
    }

    func testFrontmostPaneMadeFrontmostUnderCompactIsStillFrontmostOncePlannedRegular() {
        let tree = rootTabsTree()
        let regularPath = regularTabbedPath(for: tree)

        var state = FocusRegionState()
        // Operator taps "b" while the compact strip is on screen.
        state.select(paneId: "b", regionPath: FocusRegionState.compactRegion, contentVersion: 1)

        XCTAssertEqual(
            state.frontmostPane(for: regularPath, available: ["a", "b"], fallback: "a"), "b",
            "a pane made frontmost under compact's region path must still be frontmost once the same tree is planned at regular width"
        )
    }

    func testFrontmostPaneMadeFrontmostUnderRegularIsStillFrontmostOncePlannedCompact() {
        let tree = rootTabsTree()
        let regularPath = regularTabbedPath(for: tree)

        var state = FocusRegionState()
        // Operator taps "b" while the regular-width region is on screen.
        state.select(paneId: "b", regionPath: regularPath, contentVersion: 1)

        XCTAssertEqual(
            state.frontmostPane(for: FocusRegionState.compactRegion, available: ["a", "b"], fallback: "a"), "b",
            "a pane made frontmost under the regular-width region path must still be frontmost once the same tree is replanned compact"
        )
    }

    func testUnreadStateRecordedUnderCompactIsStillUnreadOncePlannedRegular() {
        let tree = rootTabsTree()
        let regularPath = regularTabbedPath(for: tree)

        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: FocusRegionState.compactRegion, contentVersion: 1)
        state.noteContentVersion(paneId: "b", regionPath: FocusRegionState.compactRegion, contentVersion: 2)

        XCTAssertTrue(
            state.isUnread(paneId: "b", regionPath: regularPath, contentVersion: 2),
            "an unread mark recorded while compact must still read unread once the same tree is planned regular"
        )
    }

    func testUnreadStateRecordedUnderRegularIsStillUnreadOncePlannedCompact() {
        let tree = rootTabsTree()
        let regularPath = regularTabbedPath(for: tree)

        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: regularPath, contentVersion: 1)
        state.noteContentVersion(paneId: "b", regionPath: regularPath, contentVersion: 2)

        XCTAssertTrue(
            state.isUnread(paneId: "b", regionPath: FocusRegionState.compactRegion, contentVersion: 2),
            "an unread mark recorded while regular must still read unread once the same tree is replanned compact"
        )
    }

    func testAScrollRestoreKeyWrittenForAPaneIsReadableAfterAWidthClassChange() {
        let tree = rootTabsTree()
        // Scroll-restore keys are pane-id-only, not region-scoped (see
        // `FocusRegionState`'s `scrollKeys` doc comment), so planning either
        // width must have no bearing on it at all. Plan both, to prove this
        // isn't merely an untouched dictionary that was never exercised.
        _ = layoutPlan(tree: tree, width: .compact, content: [:])
        _ = layoutPlan(tree: tree, width: .regular, content: [:])

        var state = FocusRegionState()
        state.setScrollKey(12, for: "b")

        XCTAssertEqual(
            state.scrollKey(for: "b"), 12,
            "a scroll-restore key written for a pane must survive a width-class change"
        )
    }

    // MARK: - W6: scrollRestore mirrors ScrollDecision's already-visible-means-don't-move rule

    func testScrollRestoreWithNoSavedKeyDoesNothing() {
        let state = FocusRegionState()
        XCTAssertEqual(
            state.scrollRestore(for: "a", visibleRange: 0...10), .none,
            "nothing has ever been saved for this pane — there is nothing to restore"
        )
    }

    func testScrollRestoreForAKeyAlreadyWithinTheVisibleRangeDoesNothing() {
        var state = FocusRegionState()
        state.setScrollKey(5, for: "a")
        XCTAssertEqual(
            state.scrollRestore(for: "a", visibleRange: 0...10), .none,
            "a transition that happened not to move anything must not produce a visible jump"
        )
    }

    func testScrollRestoreForAKeyOutsideTheVisibleRangeScrollsToIt() {
        var state = FocusRegionState()
        state.setScrollKey(50, for: "a")
        XCTAssertEqual(state.scrollRestore(for: "a", visibleRange: 0...10), .scrollTo(target: 50))
    }

    func testScrollRestoreWithNoVisibleRangeYetAlwaysScrollsAFirstPaint() {
        var state = FocusRegionState()
        state.setScrollKey(5, for: "a")
        XCTAssertEqual(
            state.scrollRestore(for: "a", visibleRange: nil), .scrollTo(target: 5),
            "a first paint (no visible range measured yet) must always honor the saved key"
        )
    }

    // MARK: - W6: prune drops state for anything the new tree no longer contains

    func testPruneDiscardsFrontmostReadAndScrollStateForARegionAndPaneNoLongerLive() {
        var state = FocusRegionState()
        // Region "root.0" hosted "a" (frontmost) and "b" (unread, with a scroll key).
        state.select(paneId: "a", regionPath: "root.0", contentVersion: 1)
        state.noteContentVersion(paneId: "b", regionPath: "root.0", contentVersion: 2)
        state.setScrollKey(5, for: "b")
        // Region "root.1" hosted "x" (frontmost), with its own scroll key.
        state.select(paneId: "x", regionPath: "root.1", contentVersion: 1)
        state.setScrollKey(9, for: "x")

        XCTAssertTrue(state.isUnread(paneId: "b", regionPath: "root.0", contentVersion: 2), "sanity check")
        XCTAssertEqual(state.scrollKey(for: "b"), 5, "sanity check")

        // A rebuild drops region "root.0" (and its panes) from the tree entirely.
        state.prune(livePaths: ["root.1"], livePanes: ["x"])

        XCTAssertEqual(
            state.frontmostPane(for: "root.0", available: ["q"], fallback: "q"), "q",
            "a region path no longer in the tree must not remember a stale frontmost pane"
        )
        XCTAssertFalse(
            state.isUnread(paneId: "b", regionPath: "root.0", contentVersion: 2),
            "an unread mark for a pane no longer in the tree must not resurrect"
        )
        XCTAssertNil(
            state.scrollKey(for: "b"),
            "a scroll key for a pane no longer in the tree must be discarded"
        )

        // The surviving region/pane are untouched.
        XCTAssertEqual(state.frontmostPane(for: "root.1", available: ["x"], fallback: "x"), "x")
        XCTAssertEqual(state.scrollKey(for: "x"), 9)
    }

    func testPruneDropsAPaneNoLongerLiveEvenWhenItsRegionPathSurvives() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: "root.0", contentVersion: 1)
        state.noteContentVersion(paneId: "b", regionPath: "root.0", contentVersion: 2)
        state.setScrollKey(3, for: "b")

        // "root.0" is still in the tree, but "b" itself was removed from it
        // (e.g. a tab closed) while "a" remains.
        state.prune(livePaths: ["root.0"], livePanes: ["a"])

        XCTAssertFalse(
            state.isUnread(paneId: "b", regionPath: "root.0", contentVersion: 2),
            "a pane dropped from the tree must not remain marked unread under a surviving region"
        )
        XCTAssertNil(state.scrollKey(for: "b"))
        XCTAssertEqual(
            state.frontmostPane(for: "root.0", available: ["a"], fallback: "a"), "a",
            "the surviving pane's frontmost record must be untouched"
        )
    }

    func testPruneKeepsStateForARegionAndPaneBothStillLive() {
        var state = FocusRegionState()
        state.select(paneId: "a", regionPath: "root.0", contentVersion: 1)
        state.noteContentVersion(paneId: "b", regionPath: "root.0", contentVersion: 2)
        state.setScrollKey(3, for: "b")

        state.prune(livePaths: ["root.0"], livePanes: ["a", "b"])

        XCTAssertTrue(
            state.isUnread(paneId: "b", regionPath: "root.0", contentVersion: 2),
            "state for a surviving region and pane must not be discarded"
        )
        XCTAssertEqual(state.scrollKey(for: "b"), 3)
        XCTAssertEqual(state.frontmostPane(for: "root.0", available: ["a", "b"], fallback: "a"), "a")
    }
}
