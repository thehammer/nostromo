import XCTest
// PaneTree, SplitDirection, and PaneRenderPlan are compiled into this target
// directly (logic test — no host app, no window). No module imports needed.

// MARK: - PaneRenderPlanTests

/// Behavioural tests for `PaneRenderPlan` (fix/detail-region-content-not-rendering).
///
/// `DynamicFocusView` builds three separate pieces of bookkeeping while it
/// walks a `PaneTree` — `leafViews` (every leaf's content view, including
/// tab-hosted ones), the split-node path set an incremental repair keys off
/// of, and the `TabRegionView` metadata a tabs update targets — and the bug
/// this branch fixes is that those three can silently fall out of step with
/// the tree the daemon actually sent. `PaneRenderPlan` is the single pure
/// description of "what should exist, and at what path" that both the
/// renderer and (eventually) a reconciliation step can compare their live
/// state against. These tests pin its path scheme and traversal order so a
/// future refactor of `DynamicFocusView` can't drift from it unnoticed.
final class PaneRenderPlanTests: XCTestCase {

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

    // MARK: 1. Plain leaf tree

    func testAPlainLeafTreeProducesASingleRootLeafAndNothingElse() {
        let plan = PaneRenderPlan.build(from: leaf("repl"))
        XCTAssertEqual(plan.leafPaths, ["root": "repl"])
        XCTAssertEqual(plan.splitPaths, [])
        XCTAssertEqual(plan.tabsNodes, [])
        XCTAssertEqual(plan.paneIds, ["repl"])
    }

    // MARK: 2. Nested split

    func testATwoChildSplitProducesOneSplitPathAndTwoIndexedLeafPaths() {
        let tree = split(.vertical, [leaf("queue"), leaf("repl")], [0.6, 0.4])
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.splitPaths, ["root"])
        XCTAssertEqual(plan.leafPaths, ["root.0": "queue", "root.1": "repl"])
        XCTAssertEqual(plan.tabsNodes, [])
    }

    // MARK: 3. Tabs node

    func testATabsNodeProducesATabsNodeEntryAndDotTabIndexedLeafPaths() {
        let tree = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 1)
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.tabsNodes, [
            PaneRenderPlan.TabsNode(path: "root", paneIds: ["a", "b"], labels: ["A", "B"], activePaneId: "b"),
        ])
        XCTAssertEqual(plan.leafPaths, ["root.tab0": "a", "root.tab1": "b"])
        XCTAssertEqual(plan.splitPaths, [])
        XCTAssertEqual(plan.paneIds, ["a", "b"])
    }

    // MARK: 4. The live perri tree this bug occurs in

    func testThePerriTreeWithANestedSplitAndATabsNodeIsPlannedExactly() {
        // Transcribed literally from the daemon-panes.json snapshot captured
        // during the bug investigation: a vertical outer split, a horizontal
        // split in its first slot, and a `detail` tabs region (Conversation /
        // Diff) nested inside that inner split's second slot.
        let tree = split(.vertical, [
            split(.horizontal, [
                leaf("queue"),
                tabs([leaf("detail.0"), leaf("detail.1")], ["Conversation", "Diff"], active: 1),
            ], [0.5, 0.5]),
            leaf("repl"),
        ], [0.6, 0.4])

        let plan = PaneRenderPlan.build(from: tree)

        XCTAssertEqual(plan.tabsNodes, [
            PaneRenderPlan.TabsNode(
                path: "root.0.1",
                paneIds: ["detail.0", "detail.1"],
                labels: ["Conversation", "Diff"],
                activePaneId: "detail.1"
            ),
        ])
        XCTAssertEqual(plan.splitPaths, ["root", "root.0"], "split paths must be depth-first: outer split before the nested one")
        XCTAssertEqual(plan.leafPaths, [
            "root.0.0": "queue",
            "root.0.1.tab0": "detail.0",
            "root.0.1.tab1": "detail.1",
            "root.1": "repl",
        ])
    }

    // MARK: 5. Out-of-bounds active index falls back to the first tab

    func testATabsNodeWithAnOutOfBoundsActiveIndexResolvesToTheFirstChild() {
        // Must agree with the two other call sites making this same fallback
        // decision: DynamicFocusView.buildTabs (`tabs.first?.paneId ?? ""`)
        // and TabRegionView.init (`tabs.first?.paneId ?? activePaneId`).
        let tree = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 5)
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.tabsNodes.first?.activePaneId, "a")
    }

    func testATabsNodeWithANegativeActiveIndexAlsoResolvesToTheFirstChild() {
        let tree = tabs([leaf("a"), leaf("b")], ["A", "B"], active: -1)
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.tabsNodes.first?.activePaneId, "a")
    }

    // MARK: 6. Duplicate pane ids must not collapse in leafPaths

    func testTwoLeavesSharingThePaneIdAreBothPresentInLeafPathsKeyedByPath() {
        let tree = split(.horizontal, [leaf("dup"), leaf("dup")], [0.5, 0.5])
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.leafPaths.count, 2, """
            leafPaths is keyed by path, not by pane id — a [paneId: path] dict would have silently collapsed \
            these two occurrences of "dup" into one entry, hiding one of the two rendered leaves from any \
            reconciliation step built on top of this plan.
            """)
        XCTAssertEqual(plan.leafPaths, ["root.0": "dup", "root.1": "dup"])
        XCTAssertEqual(plan.paneIds, ["dup"], "the Set collapses duplicates by design — only leafPaths must not")
    }

    // MARK: - Edge cases

    func testASplitWithNoChildrenStillContributesItsOwnSplitPathButNoLeaves() {
        let tree = split(.horizontal, [], [])
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.splitPaths, ["root"])
        XCTAssertEqual(plan.leafPaths, [:])
        XCTAssertEqual(plan.tabsNodes, [])
    }

    func testATabsNodeWithNoChildrenProducesAnEmptyTabsNodeEntry() {
        let tree = tabs([], [], active: 0)
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.tabsNodes, [
            PaneRenderPlan.TabsNode(path: "root", paneIds: [], labels: [], activePaneId: ""),
        ])
        XCTAssertEqual(plan.leafPaths, [:])
    }

    func testTwoSiblingTabsNodesAreReportedInLeftToRightOrder() {
        let tree = split(.horizontal, [
            tabs([leaf("a")], ["A"], active: 0),
            tabs([leaf("b")], ["B"], active: 0),
        ], [0.5, 0.5])
        let plan = PaneRenderPlan.build(from: tree)
        XCTAssertEqual(plan.tabsNodes.map(\.path), ["root.0", "root.1"], """
            tabsNodes must be reported in the same left-to-right, depth-first order as splitPaths — a \
            reconciliation step iterating both needs a stable, predictable order.
            """)
    }
}
