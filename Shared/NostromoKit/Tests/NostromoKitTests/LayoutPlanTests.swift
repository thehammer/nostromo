// NostromoKit — LayoutPlanTests.swift
//
// Behavioural tests for `layoutPlan`, `LayoutPlan`, `RegionNode`, and
// `LayoutRegions` (W6 — ios-curated-view-parity): the pure function that
// decides, from nothing but a `PaneTree` and a `WidthClass`, whether iOS
// renders one flattened strip (compact, W5's `TabPlan`) or the daemon's real
// simultaneously-visible regions (regular). This function is this wedge's
// only real defence — there is no simulator, no device in CI, and no way to
// watch an iPad rendering itself wrong from here — so every criterion that
// CAN be reduced to "given this tree and this width, this plan comes out"
// lives in this file rather than being hoped for at the view layer. See
// docs/ios-verification.md for the honest list of what this suite CANNOT
// prove (observed on-screen proportions, the live rotation/multitasking
// transition, per-region unread legibility) — those are verified by hand.
//
// import Foundation only — pure value types and pure functions, exercised by
// `make kit-test` with no simulator and no device.
import Foundation
import XCTest
@testable import NostromoKit

final class LayoutPlanTests: XCTestCase {

    // MARK: - Fixtures (matching TabPlanTests' house style)

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

    /// A tree decoded via `PaneLayout.swift:77-90`'s unrecognised-`kind`
    /// fallback: a future node type this client doesn't know about yet,
    /// carrying one real leaf child. The decoder degrades to that child
    /// rather than throwing or fabricating a duplicate repl — see the
    /// comment at the fallback site. Once decoded it is an ordinary
    /// `PaneTree`, so this fixture is really proving `layoutPlan` doesn't
    /// need to know anything about that fallback at all.
    private func unknownKindFallbackLeaf() -> PaneTree {
        let json = Data(#"{"kind":"future_thing","children":[{"kind":"leaf","pane_id":"mystery"}]}"#.utf8)
        return try! JSONDecoder().decode(PaneTree.self, from: json)
    }

    // MARK: - Fixtures: ~15 tree shapes for totality / path-stability tables

    private struct TreeCase {
        let name: String
        let tree: PaneTree
    }

    private var treeShapeCases: [TreeCase] {
        [
            TreeCase(name: "single leaf", tree: leaf("repl")),
            TreeCase(name: "two-way split", tree:
                split(.horizontal, [leaf("repl"), leaf("a")], [0.5, 0.5])
            ),
            TreeCase(name: "three-way split", tree:
                split(.horizontal, [leaf("repl"), leaf("a"), leaf("b")], [0.34, 0.33, 0.33])
            ),
            TreeCase(name: "nested splits three deep", tree:
                split(.horizontal, [
                    leaf("repl"),
                    split(.vertical, [
                        leaf("a"),
                        split(.horizontal, [leaf("b"), leaf("c")], [0.5, 0.5])
                    ], [0.4, 0.6])
                ], [0.3, 0.7])
            ),
            TreeCase(name: "tabs at root", tree:
                tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
            ),
            TreeCase(name: "tabs inside split", tree:
                split(.horizontal, [
                    leaf("repl"),
                    tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
                ], [0.5, 0.5])
            ),
            TreeCase(name: "split inside tabs", tree:
                tabs([
                    leaf("repl"),
                    split(.vertical, [leaf("a"), leaf("b")], [0.5, 0.5])
                ], ["Repl", "Split"], active: 0)
            ),
            TreeCase(name: "tabs inside tabs", tree:
                tabs([
                    leaf("repl"),
                    tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
                ], ["Repl", "Nested"], active: 0)
            ),
            TreeCase(name: "split with one child", tree:
                split(.horizontal, [leaf("solo")], [1.0])
            ),
            TreeCase(name: "tabs node with active out of range", tree:
                tabs([leaf("a"), leaf("b")], ["A", "B"], active: 99)
            ),
            TreeCase(name: "tabs node with fewer labels than children", tree:
                tabs([leaf("a"), leaf("b"), leaf("c")], ["OnlyOne"], active: 0)
            ),
            TreeCase(name: "decoded via the unknown-kind fallback", tree:
                unknownKindFallbackLeaf()
            ),
            TreeCase(name: "deep five-level mix", tree:
                split(.horizontal, [
                    leaf("l1"),
                    tabs([
                        split(.vertical, [
                            leaf("l2"),
                            tabs([
                                leaf("l3"),
                                split(.horizontal, [leaf("l4"), leaf("l5")], [0.5, 0.5])
                            ], ["T3", "T4"], active: 0)
                        ], [0.4, 0.6])
                    ], ["OnlyTab"], active: 0)
                ], [0.3, 0.7])
            ),
            TreeCase(name: "repl leaf buried deep", tree:
                split(.horizontal, [
                    tabs([
                        split(.vertical, [leaf("x"), leaf("repl")], [0.5, 0.5])
                    ], ["Nested"], active: 0),
                    leaf("y")
                ], [0.5, 0.5])
            ),
            TreeCase(name: "tabs node with an empty children array", tree:
                split(.horizontal, [
                    tabs([], [], active: 0),
                    leaf("only")
                ], [0.5, 0.5])
            ),
        ]
    }

    // MARK: - Walking a RegionNode (test-side helpers only — layoutPlan itself is what's under test)

    /// Every leaf pane id reachable under `node`, in walk order, WITHOUT
    /// deduplicating — used to catch a genuine duplicate as well as a drop,
    /// which a `Set`-only comparison would mask.
    private func collectLeafPaneIds(from node: RegionNode) -> [String] {
        switch node {
        case .bare(_, let paneId):
            return [paneId]
        case .split(_, let children, _):
            return children.flatMap { collectLeafPaneIds(from: $0) }
        case .tabbed(_, let tabs):
            return tabs.flatMap { collectLeafPaneIds(from: $0.content) }
        }
    }

    /// Every leaf's OWN region path, keyed by pane id — the same notion
    /// `TabPlanEntry.regionPath` names for the compact plan: a `.bare`
    /// node's own path, or (recursing into a tab's content) whatever that
    /// content resolves to. Used only for the path-stability comparison
    /// below; assumes no duplicate pane ids (proven separately by the
    /// totality tests).
    private func collectLeafPaths(from node: RegionNode) -> [String: String] {
        switch node {
        case .bare(let path, let paneId):
            return [paneId: path]
        case .split(_, let children, _):
            return children.reduce(into: [:]) { acc, child in
                acc.merge(collectLeafPaths(from: child)) { a, _ in a }
            }
        case .tabbed(_, let tabs):
            return tabs.reduce(into: [:]) { acc, tab in
                acc.merge(collectLeafPaths(from: tab.content)) { a, _ in a }
            }
        }
    }

    // MARK: - Compact: identical to W5's TabPlan, unchanged

    func testCompactPresentationIsByteIdenticalToTabPlanBuildForATableOfTreeShapes() {
        let content: [String: PaneContentWire] = [
            "thecode": .code(CodePayload(path: "main.swift", revision: "working", firstLine: 1, text: ""))
        ]
        for c in treeShapeCases {
            guard case .singleRegion(let entries) = layoutPlan(tree: c.tree, width: .compact, content: content) else {
                XCTFail("\(c.name): compact width must always produce .singleRegion")
                continue
            }
            XCTAssertEqual(
                entries, TabPlan.build(tree: c.tree, content: content),
                "\(c.name): the compact plan must be exactly what W5's TabPlan.build produces on its own — a future edit must not fork this path"
            )
        }
    }

    func testASplitStillFlattensAtCompactWidthWithEveryLeafReachable() {
        let tree = split(.horizontal, [
            leaf("a"),
            split(.vertical, [leaf("b"), leaf("c")], [0.5, 0.5])
        ], [0.4, 0.6])
        guard case .singleRegion(let entries) = layoutPlan(tree: tree, width: .compact, content: [:]) else {
            return XCTFail("expected .singleRegion")
        }
        XCTAssertFalse(tree.paneIds.isEmpty, "sanity — the tree actually has leaves to lose")
        XCTAssertEqual(
            Set(entries.map(\.paneId)), Set(tree.paneIds),
            "every leaf under a split must remain reachable once flattened, not dropped"
        )
    }

    func testContentParameterDefaultsToEmptyDictionaryForACallerWithNoPushedContentYet() {
        XCTAssertEqual(
            layoutPlan(tree: leaf("repl"), width: .compact),
            .singleRegion(TabPlan.build(tree: leaf("repl"), content: [:]))
        )
    }

    // MARK: - Regular: a single bare leaf, no chrome

    func testASingleReplLeafAtRegularWidthIsABareRegionWithNoChrome() {
        XCTAssertEqual(
            layoutPlan(tree: leaf("repl"), width: .regular, content: [:]),
            .regions(.bare(path: "root", paneId: "repl"))
        )
    }

    // MARK: - Regular: a two-way split, direction and shares preserved

    func testHorizontalSplitProducesTwoBareRegionsWithTheDaemonsShares() {
        let tree = split(.horizontal, [leaf("a"), leaf("b")], [0.6, 0.4])
        XCTAssertEqual(
            layoutPlan(tree: tree, width: .regular, content: [:]),
            .regions(.split(
                direction: .horizontal,
                children: [.bare(path: "root.0", paneId: "a"), .bare(path: "root.1", paneId: "b")],
                shares: [0.6, 0.4]
            ))
        )
    }

    func testHorizontalSplitDirectionIsPreservedMeaningAVerticalDividerLeftPipeRight() {
        // PaneLayout.swift:14-20: `.horizontal` means a vertical divider
        // (left | right). Getting this backwards produces a layout that
        // looks deliberate and is wrong — assert on the field directly and
        // say so in the name.
        let tree = split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5])
        guard case .regions(.split(let direction, _, _)) = layoutPlan(tree: tree, width: .regular, content: [:]) else {
            return XCTFail("expected a top-level .split region")
        }
        XCTAssertEqual(direction, .horizontal)
    }

    func testVerticalSplitDirectionIsPreservedMeaningAHorizontalDividerTopOverBottom() {
        let tree = split(.vertical, [leaf("a"), leaf("b")], [0.5, 0.5])
        guard case .regions(.split(let direction, _, _)) = layoutPlan(tree: tree, width: .regular, content: [:]) else {
            return XCTFail("expected a top-level .split region")
        }
        XCTAssertEqual(direction, .vertical)
    }

    // MARK: - Regular: nested splits produce regions within regions, not a flattened row

    func testNestedSplitProducesARegionWithinARegionRatherThanAFlattenedRow() {
        let tree = split(.vertical, [
            split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5]),
            leaf("c")
        ], [0.4, 0.6])

        guard case .regions(let node) = layoutPlan(tree: tree, width: .regular, content: [:]) else {
            return XCTFail("expected .regions")
        }
        guard case .split(let direction, let children, let shares) = node else {
            return XCTFail("expected a top-level .split")
        }
        XCTAssertEqual(direction, .vertical)
        XCTAssertEqual(children.count, 2, "a two-child split must produce exactly two regions, not a flattened three-way row")
        assertSharesAreValid(shares)

        guard case .split(let innerDirection, let innerChildren, let innerShares) = children[0] else {
            return XCTFail("child 0 must itself be a .split region — a nested split, not three leaves flattened into one row")
        }
        XCTAssertEqual(innerDirection, .horizontal)
        assertSharesAreValid(innerShares)
        XCTAssertEqual(innerChildren, [.bare(path: "root.0.0", paneId: "a"), .bare(path: "root.0.1", paneId: "b")])
        XCTAssertEqual(children[1], .bare(path: "root.1", paneId: "c"))
    }

    // MARK: - Regular: two tabbed regions, distinct paths, no shared pane

    func testTwoTabsNodesUnderASplitProduceDistinctTabbedRegionsSharingNoPane() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            tabs([leaf("c"), leaf("d")], ["C", "D"], active: 0)
        ], [0.5, 0.5])

        guard case .regions(.split(_, let children, _)) = layoutPlan(tree: tree, width: .regular, content: [:]) else {
            return XCTFail("expected a top-level .split")
        }
        XCTAssertEqual(children.count, 2)
        guard case .tabbed(let path0, let tabs0) = children[0], case .tabbed(let path1, let tabs1) = children[1] else {
            return XCTFail("both children must be .tabbed regions")
        }

        XCTAssertEqual(path0, "root.0")
        XCTAssertEqual(path1, "root.1")
        XCTAssertNotEqual(path0, path1, "two simultaneously-visible tabbed regions must have distinct paths")

        XCTAssertEqual(tabs0.map(\.entry.paneId), ["a", "b"])
        XCTAssertEqual(tabs1.map(\.entry.paneId), ["c", "d"])

        let allPaneIds = tabs0.map(\.entry.paneId) + tabs1.map(\.entry.paneId)
        XCTAssertEqual(Set(allPaneIds).count, allPaneIds.count, "no pane may appear in both regions' tab lists")
    }

    func testRegionPathsAreBuiltFromRegionPathsOwnConventionNotAParallelScheme() {
        let tree = split(.horizontal, [leaf("a"), tabs([leaf("b")], ["B"], active: 0)], [0.5, 0.5])
        guard case .regions(.split(_, let children, _)) = layoutPlan(tree: tree, width: .regular, content: [:]) else {
            return XCTFail("expected a top-level .split")
        }
        guard case .bare(let pathA, _) = children[0] else { return XCTFail("child 0 must be .bare") }
        guard case .tabbed(let pathTabs, let tabs) = children[1] else { return XCTFail("child 1 must be .tabbed") }

        XCTAssertEqual(pathA, RegionPath.splitChild(RegionPath.root, 0))
        XCTAssertEqual(pathTabs, RegionPath.splitChild(RegionPath.root, 1))
        XCTAssertEqual(tabs[0].entry.regionPath, RegionPath.tabChild(pathTabs, 0))
    }

    // MARK: - Regular: a tabs node whose child is a split — a region within a tab

    func testATabsNodeWhoseChildIsASplitProducesASplitRegionWithinTheTab() {
        let tree = tabs([
            split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5])
        ], ["Split View"], active: 0)

        guard case .regions(.tabbed(let path, let tabs)) = layoutPlan(tree: tree, width: .regular, content: [:]) else {
            return XCTFail("expected a top-level .tabbed region")
        }
        XCTAssertEqual(path, "root")
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs[0].entry.label, "Split View")
        XCTAssertEqual(tabs[0].entry.regionPath, "root.tab0")

        guard case .split(let direction, let children, let shares) = tabs[0].content else {
            return XCTFail("a tab whose underlying node is a split must expose a .split region as its content — a region within a tab")
        }
        XCTAssertEqual(direction, .horizontal)
        assertSharesAreValid(shares)
        XCTAssertEqual(children, [.bare(path: "root.tab0.0", paneId: "a"), .bare(path: "root.tab0.1", paneId: "b")])
        // NOTE: `tabs[0].entry.paneId` (the "representative pane id" for a
        // tab whose content is NOT a bare leaf) is deliberately not
        // asserted here — the spec calls it "representative" but does not
        // pin down what it should be when the tab's content is itself a
        // split. See the final report for this gap.
    }

    // MARK: - Regular-width tab labels use the same fallback rule as compact

    func testRegularWidthTabLabelsMatchWhatTabPlanWouldAssignForTheSameNode() {
        let content: [String: PaneContentWire] = [
            "thediff": .diff(DiffPayload(repo: "acme/web", number: 7, files: []))
        ]
        let tree = tabs([leaf("ticket"), leaf("thediff")], ["Ticket"], active: 0)

        let compactEntries = TabPlan.build(tree: tree, content: content)
        guard case .regions(.tabbed(_, let tabs)) = layoutPlan(tree: tree, width: .regular, content: content) else {
            return XCTFail("expected a top-level .tabbed region")
        }

        XCTAssertFalse(compactEntries.isEmpty, "sanity — the tree actually has tabs to label")
        for compact in compactEntries {
            guard let regularTab = tabs.first(where: { $0.entry.paneId == compact.paneId }) else {
                XCTFail("no regular-width tab found for pane \(compact.paneId)")
                continue
            }
            XCTAssertEqual(
                regularTab.entry.label, compact.label,
                "a node's label must not differ between presentations — every renderer and addressing behaviour is identical at both widths"
            )
        }
    }

    // MARK: - Path stability across width classes (the most load-bearing assertion in this wedge)
    //
    // FocusRegionState is keyed by region path. If a leaf's own path differed
    // between the compact and regular plans, a frontmost/unread/scroll
    // record written under one presentation would silently fail to resolve
    // under the other the instant the operator rotates the device or drags
    // a multitasking divider — exactly the "losslessness" criterion this
    // wedge exists to satisfy.

    func testALeafsOwnRegionPathIsIdenticalWhetherThePlanWasBuiltCompactOrRegular() {
        for c in treeShapeCases {
            guard case .singleRegion(let compactEntries) = layoutPlan(tree: c.tree, width: .compact, content: [:]) else {
                XCTFail("\(c.name): expected .singleRegion at compact width")
                continue
            }
            let compactPaths = Dictionary(uniqueKeysWithValues: compactEntries.map { ($0.paneId, $0.regionPath) })
            XCTAssertFalse(compactPaths.isEmpty, "\(c.name): sanity — the tree actually has leaves")

            guard case .regions(let node) = layoutPlan(tree: c.tree, width: .regular, content: [:]) else {
                XCTFail("\(c.name): expected .regions at regular width")
                continue
            }
            let regularPaths = collectLeafPaths(from: node)

            for (paneId, compactPath) in compactPaths {
                XCTAssertEqual(
                    regularPaths[paneId], compactPath,
                    "\(c.name): pane \(paneId)'s own region path must be identical at both widths — this is what lets region state resolve across a width-class transition"
                )
            }
        }
    }

    // MARK: - Totality: no leaf dropped, none duplicated, at either width
    //
    // Uses the public `.regions` accessor (not a private re-walk of
    // RegionNode) so this test also proves `.regions` itself is total — the
    // same accessor `LayoutRegions` and any future per-region UI code would
    // rely on.

    func testEveryLeafAppearsExactlyOnceAcrossRegionsAtBothWidthsForATableOfTreeShapes() {
        for c in treeShapeCases {
            let expected = Set(c.tree.paneIds)
            XCTAssertFalse(expected.isEmpty, "\(c.name): sanity — the tree must actually have leaves to lose")

            let compactPlan = layoutPlan(tree: c.tree, width: .compact, content: [:])
            let compactIds = compactPlan.regions.flatMap(\.paneIds)
            XCTAssertEqual(compactIds.count, c.tree.paneIds.count, "\(c.name) (compact): no leaf may appear more than once")
            XCTAssertEqual(Set(compactIds), expected, "\(c.name) (compact): every leaf must appear, none invented")

            let regularPlan = layoutPlan(tree: c.tree, width: .regular, content: [:])
            let regularIds = regularPlan.regions.flatMap(\.paneIds)
            XCTAssertEqual(regularIds.count, c.tree.paneIds.count, "\(c.name) (regular): no leaf may appear more than once")
            XCTAssertEqual(Set(regularIds), expected, "\(c.name) (regular): every leaf must appear, none invented")

            // Also verify directly over RegionNode shape (not just via
            // `.regions`) for the regular case, so a bug isolated to
            // `.regions` itself doesn't mask a bug (or hide correctness) in
            // the plan shape underneath it, or vice versa.
            guard case .regions(let node) = regularPlan else { continue }
            let regularViaWalk = collectLeafPaneIds(from: node)
            XCTAssertEqual(regularViaWalk.count, c.tree.paneIds.count, "\(c.name) (regular, walked): no leaf may appear more than once")
            XCTAssertEqual(Set(regularViaWalk), expected, "\(c.name) (regular, walked): every leaf must appear, none invented")
        }
    }

    // MARK: - LayoutPlan.regions

    func testSingleRegionsRegionsPropertyIsOneMembershipAtRootCoveringEveryEntry() {
        let tree = split(.horizontal, [leaf("repl"), tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)], [0.5, 0.5])
        let plan = layoutPlan(tree: tree, width: .compact, content: [:])
        guard case .singleRegion(let entries) = plan else { return XCTFail("expected .singleRegion") }

        XCTAssertEqual(
            plan.regions,
            [RegionMembership(path: RegionPath.root, paneIds: entries.map(\.paneId))],
            "the compact presentation has exactly one region — the whole strip — hosting every pane in the tree"
        )
    }

    func testRegularRegionsPropertyListsEachTabbedRegionWithThePanesItDirectlyHosts() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            tabs([leaf("c"), leaf("d")], ["C", "D"], active: 0)
        ], [0.5, 0.5])
        let plan = layoutPlan(tree: tree, width: .regular, content: [:])

        XCTAssertEqual(
            plan.regions,
            [
                RegionMembership(path: "root.0", paneIds: ["a", "b"]),
                RegionMembership(path: "root.1", paneIds: ["c", "d"]),
            ],
            "a split of two tabbed regions must report both as separate hosting regions, walked left to right"
        )
    }

    func testRegularRegionsPropertyForBareLeavesReportsOneRegionPerLeafAtItsOwnPath() {
        let tree = split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5])
        let plan = layoutPlan(tree: tree, width: .regular, content: [:])
        XCTAssertEqual(
            plan.regions,
            [
                RegionMembership(path: "root.0", paneIds: ["a"]),
                RegionMembership(path: "root.1", paneIds: ["b"]),
            ]
        )
    }

    func testRegularRegionsPropertyGivesANestedTabsInATabItsOwnSeparateMembershipRatherThanMergingIntoTheOuterRegion() {
        // This (and the split-in-a-tab test below) is inferred from
        // `LayoutRegions.hostingPaths`'s documented rule — "its tabs
        // parent's path" (the IMMEDIATE parent, not any outer ancestor) —
        // rather than from an explicit worked example for `.regions`
        // itself. Flagged in the final report as the area most worth
        // double-checking against the real implementation.
        let tree = tabs([
            leaf("repl"),
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
        ], ["Repl", "Nested"], active: 0)
        let plan = layoutPlan(tree: tree, width: .regular, content: [:])

        XCTAssertEqual(
            plan.regions,
            [
                RegionMembership(path: "root", paneIds: ["repl"]),
                RegionMembership(path: "root.tab1", paneIds: ["a", "b"]),
            ],
            "a tabs node nested inside a tab is its own addressable region (D4: its own strip, its own frontmost tab) and must be reported separately, not folded into the outer region's membership"
        )
    }

    func testRegularRegionsPropertyGivesEachSplitChildInsideATabItsOwnBareMembership() {
        let tree = tabs([
            leaf("repl"),
            split(.vertical, [leaf("a"), leaf("b")], [0.5, 0.5])
        ], ["Repl", "Split"], active: 0)
        let plan = layoutPlan(tree: tree, width: .regular, content: [:])

        XCTAssertEqual(
            plan.regions,
            [
                RegionMembership(path: "root", paneIds: ["repl"]),
                RegionMembership(path: "root.tab1.0", paneIds: ["a"]),
                RegionMembership(path: "root.tab1.1", paneIds: ["b"]),
            ]
        )
    }

    // MARK: - LayoutRegions.hostingPaths / allPaths

    func testHostingPathsForALeafOnlyTreeIsJustRoot() {
        XCTAssertEqual(LayoutRegions.hostingPaths(of: "repl", in: leaf("repl")), ["root"])
    }

    func testHostingPathsForALeafDirectlyUnderASplitIsRootAndItsOwnSplitPath() {
        let tree = split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5])
        XCTAssertEqual(LayoutRegions.hostingPaths(of: "a", in: tree), ["root", "root.0"])
        XCTAssertEqual(LayoutRegions.hostingPaths(of: "b", in: tree), ["root", "root.1"])
    }

    func testHostingPathsForALeafInsideATabsNodeIsRootAndTheTabsNodesOwnPath() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            tabs([leaf("c"), leaf("d")], ["C", "D"], active: 0)
        ], [0.5, 0.5])
        XCTAssertEqual(LayoutRegions.hostingPaths(of: "a", in: tree), ["root", "root.0"])
        XCTAssertEqual(LayoutRegions.hostingPaths(of: "c", in: tree), ["root", "root.1"])
    }

    func testHostingPathsForALeafInsideANestedTabsInATabIsTheImmediateTabsParentNotTheOutermostOne() {
        let tree = tabs([
            leaf("repl"),
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
        ], ["Repl", "Nested"], active: 0)
        XCTAssertEqual(
            LayoutRegions.hostingPaths(of: "a", in: tree), ["root", "root.tab1"],
            "the hosting region for a pane behind a nested tabs-in-a-tab is its immediate tabs parent, not the outermost tabs node"
        )
    }

    func testHostingPathsForAPaneAbsentFromTheTreeIsEmpty() {
        let tree = split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5])
        XCTAssertEqual(LayoutRegions.hostingPaths(of: "ghost", in: tree), [])
    }

    func testHostingPathsIsDeduplicatedWhenCompactAndRegularAgreeOnTheSamePath() {
        // A root-level tabs node: compact's single region and the regular
        // tabbed region are the SAME path ("root") — must be reported once,
        // not twice.
        let tree = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
        XCTAssertEqual(LayoutRegions.hostingPaths(of: "a", in: tree), ["root"])
    }

    func testAllPathsCoversEveryRegionInEitherPresentation() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            tabs([leaf("c"), leaf("d")], ["C", "D"], active: 0)
        ], [0.5, 0.5])
        XCTAssertEqual(LayoutRegions.allPaths(in: tree), ["root", "root.0", "root.1"])
    }

    func testAllPathsForALeafOnlyTreeIsJustRoot() {
        XCTAssertEqual(LayoutRegions.allPaths(in: leaf("repl")), ["root"])
    }

    // MARK: - LayoutRegions.activePane

    func testActivePaneResolvesEachSiblingTabsRegionIndependentlyWhereWholeTreeResolutionIsAmbiguous() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            tabs([leaf("c"), leaf("d")], ["C", "D"], active: 1)
        ], [0.5, 0.5])

        // The whole-tree resolution is genuinely ambiguous — two tabs nodes
        // disagree (one resolves "a", the other "d") with no focused_pane to
        // pick between them, so W5's whole-tree rule correctly declines.
        XCTAssertNil(
            tree.resolvedActivePaneId,
            "sanity check: two disagreeing tabs nodes must make the whole-tree resolution nil"
        )

        // But at regular width the two nodes are two SEPARATE regions, and
        // each one's own `active` is unambiguous on its own.
        XCTAssertEqual(LayoutRegions.activePane(forRegion: "root.0", in: tree), "a")
        XCTAssertEqual(LayoutRegions.activePane(forRegion: "root.1", in: tree), "d")
    }

    func testActivePaneIsNilForARegionPathNamingABareLeaf() {
        let tree = split(.horizontal, [leaf("a"), leaf("b")], [0.5, 0.5])
        XCTAssertNil(
            LayoutRegions.activePane(forRegion: "root.0", in: tree),
            "a .bare leaf has no \"active\" concept — there is no tabs node at that path"
        )
    }

    func testActivePaneIsNilForAPathNotPresentInTheTreeAtAll() {
        let tree = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0)
        XCTAssertNil(LayoutRegions.activePane(forRegion: "root.tab7", in: tree))
    }

    func testActivePaneWithAnOutOfRangeActiveIndexFallsBackToIndexZeroRatherThanNilOrTrapping() {
        let tree = tabs([leaf("a"), leaf("b")], ["A", "B"], active: 5)
        XCTAssertEqual(
            LayoutRegions.activePane(forRegion: "root", in: tree), "a",
            "an out-of-range active index must degrade to the first tab rather than returning nil or trapping"
        )
    }

    func testActivePaneOfATabsNodeWhoseActiveChildIsANestedSplitResolvesToItsFirstLeaf() {
        let tree = tabs([
            split(.horizontal, [leaf("x"), leaf("y")], [0.5, 0.5])
        ], ["Split View"], active: 0)
        XCTAssertEqual(LayoutRegions.activePane(forRegion: "root", in: tree), "x")
    }

    func testActivePaneForATabsNodeWithNoChildrenReturnsNilRatherThanTrapping() {
        let tree = tabs([], [], active: 0)
        XCTAssertNil(LayoutRegions.activePane(forRegion: "root", in: tree))
    }

    // MARK: - Ratio normalisation: helpers

    private func regularSplitShares(
        childCount: Int, ratios: [Double],
        file: StaticString = #filePath, line: UInt = #line
    ) -> [Double] {
        let children = (0..<childCount).map { leaf("leaf\($0)") }
        let tree = split(.horizontal, children, ratios)
        guard case .regions(.split(_, _, let shares)) = layoutPlan(tree: tree, width: .regular, content: [:]) else {
            XCTFail("expected a top-level .split region", file: file, line: line)
            return []
        }
        return shares
    }

    private func assertSharesEqual(
        _ actual: [Double], _ expected: [Double], accuracy: Double = 1e-9,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "share count must equal child count", file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: accuracy, file: file, line: line)
        }
    }

    private func assertSharesAreValid(_ shares: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(shares.isEmpty, "sanity — a split with children must produce a share for each", file: file, line: line)
        XCTAssertEqual(
            shares.reduce(0, +), 1, accuracy: 1e-9,
            "shares must sum to 1 — the view divides screen space by these numbers; any other total blanks or overlaps a region",
            file: file, line: line
        )
        for s in shares {
            XCTAssertGreaterThan(s, 0, "every share must be strictly positive — a non-positive share is a region with no width to render", file: file, line: line)
        }
    }

    // MARK: - Ratio normalisation: worked examples from the documented rule

    func testEqualRatiosStayEqual() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [0.5, 0.5]), [0.5, 0.5])
    }

    func testEqualNonNormalizedRatiosAreNormalizedToEqualShares() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [1, 1]), [0.5, 0.5])
    }

    func testProportionalRatiosAreNormalizedPreservingProportion() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [3, 1]), [0.75, 0.25])
    }

    func testAnAlreadyValidUnevenSplitIsNotPerturbedByTheFloor() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [0.6, 0.4]), [0.6, 0.4])
    }

    func testFewerRatiosThanChildrenSplitsTheRemainderEquallyAmongTheMissingOnes() {
        assertSharesEqual(regularSplitShares(childCount: 3, ratios: [0.6]), [0.6, 0.2, 0.2])
    }

    func testMoreRatiosThanChildrenIgnoresTheExtrasBeforeNormalizing() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [0.5, 0.3, 0.2]), [0.625, 0.375])
    }

    func testAnEmptyRatiosArrayProducesEqualShares() {
        assertSharesEqual(regularSplitShares(childCount: 3, ratios: []), [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    func testAZeroShareIsRaisedToTheFloorAndTheDeficitComesFromTheRest() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [0, 1]), [0.05, 0.95])
    }

    func testANegativeShareIsSanitizedToZeroThenRaisedToTheFloor() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [-1, 2]), [0.05, 0.95])
    }

    func testANaNShareIsSanitizedToZeroThenRaisedToTheFloor() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [Double.nan, 1]), [0.05, 0.95])
    }

    func testAPositiveInfiniteShareIsSanitizedToZeroThenRaisedToTheFloor() {
        // Not one of the worked examples, but the documented rule names
        // "non-finite (NaN/±inf)" explicitly — testing only NaN would leave
        // the ±inf half of that rule unproven.
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [Double.infinity, 1]), [0.05, 0.95])
    }

    func testANegativeInfiniteShareIsSanitizedToZeroThenRaisedToTheFloor() {
        assertSharesEqual(regularSplitShares(childCount: 2, ratios: [-Double.infinity, 1]), [0.05, 0.95])
    }

    func testAllZeroRatiosProduceEqualShares() {
        assertSharesEqual(regularSplitShares(childCount: 3, ratios: [0, 0, 0]), [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    // MARK: - Ratio normalisation: the invariant every view depends on

    func testEveryPlansSharesSumToOneAndAreStrictlyPositiveForATableOfWellFormedAndAdversarialRatios() {
        struct Case { let name: String; let childCount: Int; let ratios: [Double] }
        let cases: [Case] = [
            Case(name: "well-formed 2-way", childCount: 2, ratios: [0.5, 0.5]),
            Case(name: "well-formed 3-way", childCount: 3, ratios: [0.2, 0.3, 0.5]),
            Case(name: "unnormalized", childCount: 2, ratios: [1, 1]),
            Case(name: "empty", childCount: 4, ratios: []),
            Case(name: "short", childCount: 4, ratios: [0.9]),
            Case(name: "long", childCount: 2, ratios: [0.1, 0.2, 0.3, 0.4]),
            Case(name: "all zero", childCount: 3, ratios: [0, 0, 0]),
            Case(name: "one negative", childCount: 3, ratios: [-5, 1, 1]),
            Case(name: "one NaN", childCount: 3, ratios: [.nan, 1, 1]),
            Case(name: "one infinite", childCount: 3, ratios: [.infinity, 1, 1]),
            Case(name: "extreme skew", childCount: 2, ratios: [0.0001, 999]),
            Case(name: "single child", childCount: 1, ratios: [1]),
            Case(name: "single child malformed", childCount: 1, ratios: [-1]),
            Case(name: "many children, all malformed", childCount: 5, ratios: [0, -1, .nan, .infinity, -.infinity]),
        ]
        for c in cases {
            let shares = regularSplitShares(childCount: c.childCount, ratios: c.ratios)
            XCTAssertEqual(shares.count, c.childCount, "\(c.name): one share per child")
            assertSharesAreValid(shares)
        }
    }
}
