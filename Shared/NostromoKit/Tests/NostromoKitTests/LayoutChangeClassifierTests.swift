// NostromoKit — LayoutChangeClassifierTests.swift
//
// Behavioural tests for `LayoutChangeClassifier` (W5 — ios-curated-view-parity).
//
// A direct port of macOS/NostromoTests/LayoutChangeClassifierTests.swift onto
// NostromoKit's own `PaneTree`/`SplitDirection` (identical shape, decoded
// from the same wire protocol) — `import NostromoKit`/`@testable import
// NostromoKit` replaces the host-less logic-bundle compilation macOS uses,
// but the classifier's contract (same cases, same `classify(old:new:)`
// signature) is unchanged, so the behavioural cases port verbatim.
//
// This classifier is what `FocusRegionState.apply` (D4) keys its
// "don't fight the operator" transition table on: `.contentOnly`/`.identical`
// must never move the frontmost pane, while `.activeTabOnly`/
// `.tabMembership`/`.splitTopology` may. Every case below that must NOT
// produce `.splitTopology` also protects that distinction one level up.
//
// Deliberately NOT ported: macOS's `DynamicFocusViewClearRatiosWiringTests`.
// Those assert wiring for `clearSavedRatios`, a locally-persisted split-ratio
// concept iOS does not have and never will (see the W5 plan's explicit ban
// on local ratio/placement persistence) — there is nothing here for that
// fitness function to guard.
import XCTest
@testable import NostromoKit

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
        // Two separately-built trees with identical shape/ids/ratios are `==`,
        // so this is `.identical`, not `.contentOnly` — see `LayoutChange`'s
        // doc comment on `.contentOnly` for why the latter is a defensive
        // bucket rather than one this comparison can actually produce today.
        let old = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), leaf("jobs")], [0.5, 0.5])
        XCTAssertEqual(LayoutChangeClassifier.classify(old: old, new: new), .identical)
    }

    // MARK: - .splitTopology

    func testDirectionOnlyChangeIsClassifiedAsSplitTopologyNotSwallowed() {
        // Same pane ids, same order, same ratios — only direction differs.
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

    func testActiveTabChangeIsNeverClassifiedAsSplitTopology() {
        // Sanity: an active-only change must never be reported as
        // .splitTopology — that's the one case that would clear any
        // operator-dragged split state a platform keeps, and switching tabs
        // must never trigger it.
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

    func testTabMembershipChangeIsNeverClassifiedAsSplitTopology() {
        let old = split(.horizontal, [leaf("repl"), tabs([leaf("ticket")], ["Ticket"], active: 0)], [0.5, 0.5])
        let new = split(.horizontal, [leaf("repl"), tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)], [0.5, 0.5])
        XCTAssertNotEqual(
            LayoutChangeClassifier.classify(old: old, new: new), .splitTopology,
            "opening a tab must never be classified in the structural-rebuild bucket"
        )
    }

    // MARK: - focused_pane is out of scope for this classifier

    // `focused_pane` lives on `FocusLayoutModel`, not on `PaneTree` itself —
    // this classifier only ever sees trees, so there is nothing to test here;
    // that behaviour belongs to `FocusRegionState.apply` (see
    // FocusRegionStateTests.swift).

    // MARK: - Split topology recursion

    func testSplitTopologyChangeNestedInsideATabsRegionIsDetected() {
        // A tab child that is itself a changed split must still be caught —
        // the split signature walk recurses into tab children.
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
