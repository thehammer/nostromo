import XCTest
import AppKit
import NostromoKit

// T6: link chips and live (bound) items in the tracker pane (PRD criteria 52 and 55, Mac half).
//
// A chip click asks the daemon to open PR, ticket and file links (`tracker_open_link`) and the
// workspace opener to open URL links; nothing else happens, and the transcript never moves. A bound
// item whose source went silent shows a quiet "as of 10:42" in a line whose height was reserved from
// the start, so the footnote appearing or going never shifts a row (≤ 1 pt tracker drift, gate).
//
// Both openers are injected into the pane: no daemon, no browser. No wall clock, no pasteboard.

/// What the pane asked its injected openers to do.
final class TrackerGateLinkRecorder {
    struct DaemonOpen: Equatable {
        let tag: String
        let item: String
        let index: Int
    }

    var daemonOpens: [DaemonOpen] = []
    var urlOpens: [URL] = []
}

/// The link and stale-footnote events of the gate: a bound item with four chips goes badly stale and
/// recovers, and each kind of chip is clicked.
enum TrackerLinkGateScript {
    /// Which item the script bound.
    final class Pick {
        var id: String?
    }

    static let links: [[String: Any]] = [
        ["text": "PR #253", "url": "https://github.com/acme/web/pull/253", "kind": "pr"],
        ["text": "CORE-2841", "kind": "jira"],
        ["text": "index.md:42", "kind": "file"],
        ["text": "run 9912", "url": "https://ci.example.com/runs/9912", "kind": "run"],
    ]

    static func bound(stale: Bool) -> [String: Any] {
        var bound: [String: Any] = ["source": "pr.ci", "badly_stale": stale]
        bound["as_of"] = "2025-10-15T16:42:00Z"
        return bound
    }

    private static func event(_ name: String,
                              _ body: @escaping (inout TrackerGateBoard, TrackerGateHarness) throws -> Void) -> TrackerGateEvent {
        TrackerGateEvent(kind: .note, name: name, action: .edit(body), observe: nil)
    }

    private static func click(_ pick: Pick, chip index: Int, expecting: @escaping (TrackerGateLinkRecorder) -> Int) -> TrackerGateEvent {
        event("click chip \(index)") { _, harness in
            guard let id = pick.id,
                  let row = harness.pane.rowViews[TrackerRow.itemKey(id)],
                  row.linkChips.indices.contains(index) else {
                throw TrackerGateError("the bound item has no chip \(index)")
            }
            let before = expecting(harness.links)
            let window = try XCTUnwrap(harness.pane.window)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            row.linkChips[index].mouseDown(with: down)
            guard expecting(harness.links) == before + 1 else {
                throw TrackerGateError("chip \(index) did not ask its opener to open anything")
            }
        }
    }

    static func events() -> [TrackerGateEvent] {
        let pick = Pick()
        func stale(_ on: Bool) -> (inout TrackerGateBoard, TrackerGateHarness) throws -> Void {
            { board, _ in
                guard let id = pick.id else { throw TrackerGateError("no bound item picked") }
                try board.editItem(id) { $0["bound"] = TrackerLinkGateScript.bound(stale: on) }
            }
        }
        return [
            event("bind an item to a source and give it chips") { board, harness in
                let item = try harness.requireItem(.inside) { $0.links.isEmpty && $0.bound == nil && !$0.isDone }
                pick.id = item.id
                try board.editItem(item.id) {
                    $0["links"] = TrackerLinkGateScript.links
                    $0["bound"] = TrackerLinkGateScript.bound(stale: false)
                }
            },
            event("the source goes badly stale", stale(true)),
            event("the source recovers", stale(false)),
            event("the source goes badly stale again", stale(true)),
            click(pick, chip: 0) { $0.daemonOpens.count },
            click(pick, chip: 1) { $0.daemonOpens.count },
            click(pick, chip: 2) { $0.daemonOpens.count },
            click(pick, chip: 3) { $0.urlOpens.count },
            event("the source recovers for good", stale(false)),
        ]
    }
}

final class TrackerLinkTests: XCTestCase {

    private func makeHarness(_ start: TrackerGateHarness.Start,
                             size: NSSize = NSSize(width: 380, height: 420)) throws -> TrackerGateHarness {
        let window = makeRigWindow(self, size: size)
        let harness = try TrackerGateHarness(self)
        let content = window.contentView!
        harness.pane.frame = content.bounds
        harness.pane.autoresizingMask = [.width, .height]
        content.addSubview(harness.pane)
        harness.layout()
        try harness.push()
        harness.layout()
        try harness.start(start)
        return harness
    }

    /// Binds the first suitable item inside the viewport and returns its id.
    private func bindItem(_ harness: TrackerGateHarness, stale: Bool = false) throws -> String {
        let item = try harness.requireItem(.inside) { $0.links.isEmpty && $0.bound == nil && !$0.isDone }
        try harness.mutate { board in
            try board.editItem(item.id) {
                $0["links"] = TrackerLinkGateScript.links
                $0["bound"] = TrackerLinkGateScript.bound(stale: stale)
            }
        }
        return item.id
    }

    private func chips(_ harness: TrackerGateHarness, _ id: String) throws -> [TrackerLinkChip] {
        try XCTUnwrap(harness.pane.rowViews[TrackerRow.itemKey(id)], "the row of \(id) is shown").linkChips
    }

    private func click(_ chip: TrackerLinkChip, in harness: TrackerGateHarness) throws {
        let window = try XCTUnwrap(harness.pane.window)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        chip.mouseDown(with: down)
    }

    // MARK: - Chips

    func testAnItemsLinksShowAsChipsWithTheirTexts() throws {
        let harness = try makeHarness(.mid)
        let id = try bindItem(harness)
        XCTAssertEqual(try chips(harness, id).map { $0.link.text }, ["PR #253", "CORE-2841", "index.md:42", "run 9912"])
        let row = try XCTUnwrap(harness.pane.rowViews[TrackerRow.itemKey(id)])
        XCTAssertTrue(row.visibleText.contains("PR #253 · CORE-2841 · index.md:42 · run 9912"), row.visibleText)
    }

    func testPrTicketAndFileChipsAskTheDaemonAndTheUrlChipOpensTheBrowser() throws {
        let harness = try makeHarness(.mid)
        let id = try bindItem(harness)
        let all = try chips(harness, id)
        for chip in all { try click(chip, in: harness) }
        XCTAssertEqual(harness.links.daemonOpens, [
            .init(tag: TrackerGateHarness.tag, item: id, index: 0),
            .init(tag: TrackerGateHarness.tag, item: id, index: 1),
            .init(tag: TrackerGateHarness.tag, item: id, index: 2),
        ], "PR, ticket and file chips go to the daemon with the link's index")
        XCTAssertEqual(harness.links.urlOpens, [URL(string: "https://ci.example.com/runs/9912")!],
                       "a run chip with a URL goes to the workspace opener")
    }

    func testAReferenceWithNoUrlIsPlainTextThatOpensNothing() throws {
        let harness = try makeHarness(.mid)
        let item = try harness.requireItem(.inside) { $0.links.isEmpty && !$0.isDone }
        try harness.mutate { board in
            try board.editItem(item.id) { $0["links"] = [["text": "Sentry PORTAL-1F2", "kind": "sentry"]] }
        }
        let chip = try XCTUnwrap(try chips(harness, item.id).first)
        XCTAssertEqual(chip.action, .inert)
        try click(chip, in: harness)
        XCTAssertTrue(harness.links.daemonOpens.isEmpty)
        XCTAssertTrue(harness.links.urlOpens.isEmpty)
    }

    func testClickingAChipLeavesThePaneWhereItWasAndTakesNoFocus() throws {
        let harness = try makeHarness(.mid)
        let id = try bindItem(harness)
        let before = harness.pane.anchorSnapshot(windowIndex: 0)
        for chip in try chips(harness, id) { try click(chip, in: harness) }
        harness.layout()
        let after = harness.pane.anchorSnapshot(windowIndex: 0)
        XCTAssertEqual(after.firstVisible?.rowKey, before.firstVisible?.rowKey)
        XCTAssertEqual(after.scrollY, before.scrollY, accuracy: 1)
        XCTAssertFalse(harness.paneOwnsFirstResponder())
    }

    // MARK: - Stale footnote

    func testAStaleSourceShowsAnAsOfFootnoteAndRecoveryClearsItWithoutChangingTheRowHeight() throws {
        let harness = try makeHarness(.mid)
        let id = try bindItem(harness)
        let key = TrackerRow.itemKey(id)
        let rowHeight = try XCTUnwrap(harness.pane.rowViews[key]).frame.height
        XCTAssertNil(try XCTUnwrap(harness.pane.rowViews[key]).staleFootnote)

        try harness.mutate { board in
            try board.editItem(id) { $0["bound"] = TrackerLinkGateScript.bound(stale: true) }
        }
        let stale = try XCTUnwrap(harness.pane.rowViews[key])
        XCTAssertEqual(stale.staleFootnote?.stringValue, "as of 16:42")
        XCTAssertEqual(stale.frame.height, rowHeight, accuracy: 1, "the footnote's line was reserved")

        try harness.mutate { board in
            try board.editItem(id) { $0["bound"] = TrackerLinkGateScript.bound(stale: false) }
        }
        let fresh = try XCTUnwrap(harness.pane.rowViews[key])
        XCTAssertNil(fresh.staleFootnote)
        XCTAssertEqual(fresh.frame.height, rowHeight, accuracy: 1)
    }

    // MARK: - Gate

    func testLinkAndStaleEventsNeverMoveTheReadingPositionWhenScrolledMidBoard() throws {
        let harness = try makeHarness(.mid)
        for (i, event) in TrackerLinkGateScript.events().enumerated() {
            harness.assertNoMove("mid-board link #\(i + 1) \(event.name)", event)
        }
        XCTAssertEqual(harness.links.daemonOpens.count, 3)
        XCTAssertEqual(harness.links.urlOpens.count, 1)
    }

    func testLinkAndStaleEventsNeverMoveTheReadingPositionAtTheTop() throws {
        let harness = try makeHarness(.top)
        for (i, event) in TrackerLinkGateScript.events().enumerated() {
            harness.assertNoMove("top link #\(i + 1) \(event.name)", event)
        }
    }
}
