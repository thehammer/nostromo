// NostromoKit — TabPlanTests.swift
//
// Behavioural tests for `TabPlan` (W5 — ios-curated-view-parity): flattening
// a `PaneTree` into the ordered strip entries `DynamicFocusView`'s rewrite
// renders as a single tab strip, and the pure label-fallback rule that
// replaces today's `paneId.capitalized` (the whole point of this wedge —
// see `check_no_pane_id_visible_via_capitalized` in
// tests/ios_policy/test_ios_view_policy.py for the same requirement enforced
// from the outside, over real view source).
import XCTest
@testable import NostromoKit

final class TabPlanTests: XCTestCase {

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

    // MARK: - Ordering: repl first, tabs runs contiguous, nothing dropped/duplicated

    func testSingleReplLeafProducesOneEntry() {
        let entries = TabPlan.build(tree: leaf("repl"), content: [:])
        XCTAssertEqual(entries.map(\.paneId), ["repl"])
    }

    func testReplLeafIsAlwaysFirstRegardlessOfItsPositionInTheTree() {
        // repl is the *second* child here — the strip must still put it first.
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            leaf("repl")
        ], [0.5, 0.5])
        let entries = TabPlan.build(tree: tree, content: [:])
        XCTAssertEqual(entries.first?.paneId, "repl")
    }

    func testTwoTabsNodesProduceContiguousRunsInTreeOrderNotInterleaved() {
        let tree = split(.horizontal, [
            leaf("repl"),
            split(.vertical, [
                tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
                tabs([leaf("c"), leaf("d")], ["C", "D"], active: 0)
            ], [0.5, 0.5])
        ], [0.3, 0.7])
        let entries = TabPlan.build(tree: tree, content: [:])
        XCTAssertEqual(entries.map(\.paneId), ["repl", "a", "b", "c", "d"])
    }

    func testNoLeafDroppedOrDuplicatedForANestedTabsSplitTabsShape() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            split(.vertical, [
                leaf("repl"),
                tabs([leaf("c"), leaf("d")], ["C", "D"], active: 0)
            ], [0.5, 0.5])
        ], [0.4, 0.6])
        let entries = TabPlan.build(tree: tree, content: [:])
        XCTAssertEqual(Set(entries.map(\.paneId)), Set(tree.paneIds), "every leaf must appear, none invented")
        XCTAssertEqual(entries.count, tree.paneIds.count, "no leaf may appear more than once")
    }

    // MARK: - Labels: positional from `labels`, with fallback

    func testLabelsAreUsedPositionallyWhenPresent() {
        let tree = tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)
        let entries = TabPlan.build(tree: tree, content: [:])
        XCTAssertEqual(entries.first(where: { $0.paneId == "ticket" })?.label, "Ticket")
        XCTAssertEqual(entries.first(where: { $0.paneId == "activity" })?.label, "Activity")
    }

    func testLabelsShorterThanChildrenFallsBackForMissingEntriesWithoutCrashing() {
        // Only one label for two children — the second must fall back to its
        // content-kind label rather than crash on an out-of-range index.
        let tree = tabs([leaf("ticket"), leaf("thediff")], ["Ticket"], active: 0)
        let content: [String: PaneContentWire] = [
            "thediff": .diff(DiffPayload(repo: "acme/web", number: 7, files: []))
        ]
        let entries = TabPlan.build(tree: tree, content: content)
        XCTAssertEqual(entries.first(where: { $0.paneId == "ticket" })?.label, "Ticket")
        XCTAssertEqual(entries.first(where: { $0.paneId == "thediff" })?.label, "Diff")
    }

    func testLabelsLongerThanChildrenIgnoresExtrasWithoutCrashing() {
        let tree = tabs([leaf("ticket")], ["Ticket", "Extra1", "Extra2"], active: 0)
        let entries = TabPlan.build(tree: tree, content: [:])
        let matching = entries.filter { $0.paneId == "ticket" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.label, "Ticket")
        XCTAssertEqual(entries.count, 1, "exactly children.count entries for this tabs node — extras never read")
    }

    func testASplitChildLeafNeverInsideTabsAlwaysGetsAContentKindFallbackLabel() {
        // A leaf that's a split child has nothing that could supply a data
        // label — Split carries no labels array — so it must always fall back.
        let tree = split(.horizontal, [leaf("repl"), leaf("thecode")], [0.5, 0.5])
        let content: [String: PaneContentWire] = [
            "thecode": .code(CodePayload(path: "main.swift", revision: "working", firstLine: 1, text: ""))
        ]
        let entries = TabPlan.build(tree: tree, content: content)
        XCTAssertEqual(entries.first(where: { $0.paneId == "thecode" })?.label, "File")
    }

    // MARK: - fallbackLabel: pure content-kind rule, never the pane id

    func testFallbackLabelForReplIsRepl() {
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "repl", content: nil), "Repl")
    }

    func testFallbackLabelIsDrivenByContentKindNotPaneId() {
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .prList([])), "Queue")
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .diff(DiffPayload(repo: "r", number: nil, files: []))), "Diff")
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .code(CodePayload(path: "p", revision: "working", firstLine: 1, text: ""))), "File")
        XCTAssertEqual(
            TabPlan.fallbackLabel(paneId: "x", content: .prConversation(
                PrConversationPayload(repo: "r", number: nil, title: "", author: "", url: "", body: [], threads: [], conversationError: nil)
            )),
            "Conversation"
        )
        XCTAssertEqual(
            TabPlan.fallbackLabel(paneId: "x", content: .ticket(
                TicketPayload(provider: "jira", key: "K-1", summary: "", status: "", assignee: nil, url: "", sections: [], comments: [])
            )),
            "Ticket"
        )
    }

    func testFallbackLabelIsViewForEveryOtherContentKindOrMissingContent() {
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .text("hi")), "View")
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .loading), "View")
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .error("boom")), "View")
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .jsonSnapshot(["k": "v"])), "View")
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: .unknown("???")), "View")
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "x", content: nil), "View")
    }

    // MARK: - A pane with no entry in `content` yet still gets a valid label

    func testAPaneWithNoContentEntryYetStillGetsAValidFallbackLabel() {
        let tree = tabs([leaf("ticket"), leaf("notyetloaded")], ["Ticket"], active: 0)
        let entries = TabPlan.build(tree: tree, content: [:])
        XCTAssertEqual(entries.first(where: { $0.paneId == "notyetloaded" })?.label, "View")
    }

    // MARK: - Region paths — literal strings must match
    // macOS/Nostromo/UI/LayoutChangeClassifier.swift:95-133's path convention
    // ("root", "root.0", "root.tab0", ...), the source of truth this ported
    // scheme must not silently drift from.

    func testRegionPathForALeafDirectlyUnderRootIsRoot() {
        let entries = TabPlan.build(tree: leaf("repl"), content: [:])
        XCTAssertEqual(entries.first?.regionPath, "root")
    }

    func testRegionPathForTheFirstChildOfARootSplitIsRootDotZero() {
        let tree = split(.horizontal, [leaf("repl"), leaf("thecode")], [0.5, 0.5])
        let entries = TabPlan.build(tree: tree, content: [:])
        XCTAssertEqual(entries.first(where: { $0.paneId == "repl" })?.regionPath, "root.0")
        XCTAssertEqual(entries.first(where: { $0.paneId == "thecode" })?.regionPath, "root.1")
    }

    func testRegionPathForTheFirstChildOfARootTabsNodeIsRootDotTabZero() {
        let tree = tabs([leaf("ticket"), leaf("activity")], ["Ticket", "Activity"], active: 0)
        let entries = TabPlan.build(tree: tree, content: [:])
        XCTAssertEqual(entries.first(where: { $0.paneId == "ticket" })?.regionPath, "root.tab0")
        XCTAssertEqual(entries.first(where: { $0.paneId == "activity" })?.regionPath, "root.tab1")
    }

    // MARK: - tabIndex matches final array position

    func testTabIndexMatchesEachEntrysFinalPositionInTheReturnedArray() {
        let tree = split(.horizontal, [
            tabs([leaf("a"), leaf("b")], ["A", "B"], active: 0),
            leaf("repl")
        ], [0.5, 0.5])
        let entries = TabPlan.build(tree: tree, content: [:])
        for (i, entry) in entries.enumerated() {
            XCTAssertEqual(entry.tabIndex, i, "tabIndex must equal the entry's own position in the array")
        }
    }

    // MARK: - No entry's label is ever the pane id or its capitalized form
    // (except "repl", which coincidentally is — the rule is content-driven,
    // not id-driven; this proves it over a table of realistic, non-repl ids
    // with varied/missing content, so the fallback path is what's exercised).

    func testNoNonReplLabelEverEqualsItsPaneIdOrCapitalizedPaneId() {
        struct Case { let id: String; let content: PaneContentWire? }
        let cases: [Case] = [
            Case(id: "detail-1", content: .diff(DiffPayload(repo: "r", number: 1, files: []))),
            // Deliberately NOT "queue": PaneTree.fallbackLabel's .prList case
            // produces "Queue", which coincidentally equals "queue".capitalized
            // — the same class of accident the "repl" exemption above
            // documents, just for a pane id this table isn't exempting. Using
            // a differently-named id with the same .prList content is the
            // more faithful proof that the label is content-driven, not
            // id-driven: the fallback is still "Queue" here, but it no longer
            // coincidentally matches this pane's own id.
            Case(id: "worklist", content: .prList([])),
            Case(id: "pane_3", content: nil),
        ]
        for c in cases {
            // A single-child tabs node with no label supplied forces the
            // fallback path for every case, regardless of content.
            let tree = tabs([leaf(c.id)], [], active: 0)
            var content: [String: PaneContentWire] = [:]
            if let payload = c.content { content[c.id] = payload }
            let entries = TabPlan.build(tree: tree, content: content)
            let label = entries.first?.label
            XCTAssertNotEqual(label, c.id, "label for \(c.id) must never equal the raw pane id")
            XCTAssertNotEqual(label, c.id.capitalized, "label for \(c.id) must never equal paneId.capitalized")
        }
    }

    func testReplIsTheOnlyExemptionFromTheAntiCapitalizationRuleByCoincidenceNotDesign() {
        // "Repl" happens to equal "repl".capitalized — documented as a
        // coincidence of English capitalization, not evidence the rule is
        // secretly `paneId.capitalized`: fallbackLabel keys off paneId=="repl"
        // as a dedicated case, not off any generic capitalization scheme (see
        // the other cases in testFallbackLabelIsDrivenByContentKindNotPaneId,
        // none of which capitalize their pane id at all).
        XCTAssertEqual(TabPlan.fallbackLabel(paneId: "repl", content: nil), "Repl")
        XCTAssertEqual("repl".capitalized, "Repl")
    }
}
