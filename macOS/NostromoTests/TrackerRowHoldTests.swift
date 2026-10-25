import XCTest
import AppKit
import NostromoKit

// The tracker pane's "more" / "less" toggle and the rows it holds back (fix/tracker-row-hold-and-less).
//
// Live observation this file pins down: the agent moved an item from "Waiting on you" to "Done today" and
// set it done, and the pane kept showing it under "Waiting on you"; the reader had expanded its multi-line
// note, and "less" did nothing. Two promises follow:
//
//  1. "more" and "less" always show: whatever text is selected in the item's row, and whatever the board
//     did to the item meanwhile, the row's note ends up expanded or collapsed as clicked.
//  2. A held change goes away once the reader is done with it: a row that had been held for a text
//     selection leaves its old section when the selection clears (not only when it scrolls out of view).
//
// A real `TrackerPaneView` in an offscreen window is fed small boards through a real `TrackerStore`. The
// disclosure is clicked the way the reader does it (the row's own button). What is asserted is what the
// row shows (its text, its prose view, the "more" / "less" label, its note state) and where the item is
// listed, never how the pane gets there. The clock, the pasteboard and the highlight scheduler are the
// rig's own; no timers, no sleeping beyond the short `rigSettle` pumps the other tracker tests use.
//
// Releases that need the pane's idle timer, click or pointer rules live in `TrackerRowHoldReleaseTests`.

// MARK: - A small board for the scenarios

/// "Waiting on you" (the item under test, with a five-line note, and a bystander), "Next", "Done today"
/// (one finished item already), and a "Later" section of filler so the board is taller than the pane.
struct TrackerHoldBoard {
    typealias Obj = [String: Any]

    static let waiting = "waiting-on-you"
    static let next = "next"
    static let doneToday = "done-today"

    /// The item the scenarios move, expand and select in.
    static let target = "wait-target"
    static let targetText = "Vendor reply on referral 4411"
    static let bystander = "wait-other"
    static let bystanderText = "Approve the staging deploy"
    static let finished = "done-old"

    /// A five-line note: the first line shows when collapsed, the last only when expanded.
    static let noteLines = [
        "NOTE-ONE the vendor replied on Tuesday",
        "NOTE-TWO they want the export re-run",
        "NOTE-THREE the file has to be signed",
        "NOTE-FOUR then sent back to them",
        "NOTE-FIVE and only then does the ticket close",
    ]
    static let firstNoteMarker = "NOTE-ONE"
    static let lastNoteMarker = "NOTE-FIVE"

    let tag: String
    private(set) var nodes: [Obj] = []
    private(set) var version = 1

    init(tag: String) {
        self.tag = tag
        nodes.append(Self.sectionNode(Self.waiting, "Waiting on you"))
        nodes.append(Self.itemNode(Self.target, section: Self.waiting, text: Self.targetText,
                                   status: "needs-you", note: Self.noteLines))
        nodes.append(Self.itemNode(Self.bystander, section: Self.waiting, text: Self.bystanderText, status: "needs-you"))
        nodes.append(Self.sectionNode(Self.next, "Next"))
        nodes.append(Self.itemNode("next-a", section: Self.next, text: "Rotate the avatar sync key", status: "todo"))
        nodes.append(Self.itemNode("next-b", section: Self.next, text: "Audit the slow query", status: "todo"))
        nodes.append(Self.sectionNode(Self.doneToday, "Done today"))
        nodes.append(Self.itemNode(Self.finished, section: Self.doneToday, text: "Closed the webhook retries", status: "done"))
        nodes.append(Self.sectionNode("later", "Later"))
        for n in 1...24 {
            let id = String(format: "fill-%02d", n)
            nodes.append(Self.itemNode(id, section: "later", text: "Filler item \(n)", status: "todo",
                                       note: ["Filler note \(n)"]))
        }
    }

    /// The board as the daemon's `tracker_board` frame.
    var frame: Obj {
        let none: [Obj] = []
        let board: Obj = [
            "title": "Hold test board", "path": "/repo/.claude/wip/hold/index.md", "version": version,
            "updated_at": TrackerPaneFx.iso(1_760_547_800), "nodes": nodes, "log": none, "hidden_by_user": false,
        ]
        return ["type": "tracker_board", "tag": tag, "board": board]
    }

    // MARK: Editing (what the agent does to the file)

    private func index(ofItem id: String) throws -> Int {
        guard let i = nodes.firstIndex(where: { ($0["type"] as? String) == "item" && ($0["id"] as? String) == id }) else {
            throw TrackerFixtureError(description: "the hold board has no item \(id)")
        }
        return i
    }

    /// The agent moves `id` to the top of `section`, and optionally changes its status.
    mutating func moveItem(_ id: String, toSection section: String, status: String? = nil) throws {
        var all = nodes
        var node = all.remove(at: try index(ofItem: id))
        node["section"] = section
        if let status { node["status"] = status }
        guard let heading = all.firstIndex(where: { ($0["type"] as? String) == "section" && ($0["id"] as? String) == section }) else {
            throw TrackerFixtureError(description: "the hold board has no section \(section)")
        }
        all.insert(node, at: heading + 1)
        nodes = all
        version += 1
    }

    mutating func setText(_ id: String, _ text: String) throws {
        var all = nodes
        let i = try index(ofItem: id)
        let spans: [Obj] = [["kind": "text", "text": text]]
        all[i]["text_spans"] = spans
        nodes = all
        version += 1
    }

    // MARK: Nodes

    private static func sectionNode(_ id: String, _ title: String) -> Obj {
        ["type": "section", "id": id, "title": title, "source": "## \(title)\n"]
    }

    private static func itemNode(_ id: String, section: String, text: String, status: String, note: [String] = []) -> Obj {
        let spans: [Obj] = [["kind": "text", "text": text]]
        let blocks: [Obj] = note.map { ["kind": "paragraph", "spans": [["kind": "text", "text": $0]]] }
        let none: [Obj] = []
        return ["type": "item", "id": id, "section": section, "text_spans": spans, "status": status,
                "updated_at": TrackerPaneFx.iso(1_760_547_800), "note_blocks": blocks, "links": none,
                "kind": "item", "ran": false, "source": "- [ ] \(text)\n"]
    }
}

extension TrackerPaneRig {
    /// Deliver the board as a `tracker_board` frame, decoded the way the app decodes it.
    func push(_ board: TrackerHoldBoard, file: StaticString = #filePath, line: UInt = #line) {
        do {
            store.ingest(try TrackerPaneFx.message(board.frame))
        } catch {
            XCTFail("could not decode the hold board: \(error)", file: file, line: line)
        }
        settle()
    }
}

// MARK: - Reading the pane

/// What the hold tests read from a pane. Everything here is what a reader sees or `tracker show` reports.
enum TrackerHoldFx {
    /// Where a text selection is made in the item's row.
    enum Selecting {
        /// The item's own text.
        case itemText
        /// The note: its first line when collapsed, the whole note (prose) when expanded.
        case noteText
    }

    static let targetKey = TrackerRow.itemKey(TrackerHoldBoard.target)

    /// Every displayed row that shows item `id` (an item row or a stub), with the section heading it
    /// sits under on screen (which is not always the item's own section: a held row keeps its place).
    static func placements(of id: String, in pane: TrackerPaneView) -> [(key: String, section: String)] {
        var current = ""
        var out: [(key: String, section: String)] = []
        for row in pane.displayedRows {
            if case .section(let section) = row.content { current = section.id }
            if row.item?.id == id { out.append((row.key, current)) }
        }
        return out
    }

    static func isListed(_ id: String, under section: String, in pane: TrackerPaneView) -> Bool {
        placements(of: id, in: pane).contains { $0.section == section }
    }

    static func doneGroup(_ section: String, in pane: TrackerPaneView) -> TrackerDoneGroupRow? {
        for row in pane.displayedRows {
            if case .doneGroup(let group) = row.content, group.sectionId == section { return group }
        }
        return nil
    }

    /// The row view currently showing item `id` as an item (not as a "moved to" stub): its live copy
    /// while a stub holds the old place, else its own row.
    static func itemRow(_ id: String, in pane: TrackerPaneView) -> TrackerRowView? {
        for key in [TrackerDeferral.movingPrefix + id, TrackerRow.itemKey(id)] {
            if let view = pane.rowViews[key], case .item = view.row.content { return view }
        }
        return nil
    }

    /// Everything the pane's rows show, top to bottom.
    static func shownText(_ pane: TrackerPaneView) -> String {
        pane.displayedRows.compactMap { pane.rowViews[$0.key]?.visibleText }.joined(separator: "\n")
    }

    /// The row's "more" / "less" button, if it has one.
    static func disclosure(in row: TrackerRowView) -> NSButton? {
        rigAllSubviews(of: row).compactMap { $0 as? NSButton }
            .first { ["more", "less"].contains($0.attributedTitle.string) }
    }

    static func textView(_ target: Selecting, in row: TrackerRowView) -> TrackerTextView? {
        switch target {
        case .itemText:
            return row.textViews.first { $0.string.contains(TrackerHoldBoard.targetText) }
        case .noteText:
            if let prose = row.proseView {
                return prose.textViews.first { $0.string.contains(TrackerHoldBoard.firstNoteMarker) } ?? prose.textViews.first
            }
            return row.textViews.first { $0.string.contains(TrackerHoldBoard.firstNoteMarker) }
        }
    }

    static func items(inSection id: String, of report: [String: Any]) -> [[String: Any]] {
        let sections = report["sections"] as? [[String: Any]] ?? []
        return sections.first { ($0["id"] as? String) == id }?["items"] as? [[String: Any]] ?? []
    }
}

// MARK: - The tests

final class TrackerRowHoldTests: XCTestCase {

    private typealias Hold = TrackerHoldBoard
    private typealias Fx = TrackerHoldFx

    private func makeScene() -> (rig: TrackerPaneRig, board: TrackerHoldBoard) {
        let tag = TrackerPaneFx.uniqueTag()
        let rig = TrackerPaneFx.makeRig(self, tag: tag, size: NSSize(width: 360, height: 320))
        let board = TrackerHoldBoard(tag: tag)
        rig.push(board)
        return (rig, board)
    }

    // MARK: Doing what the reader and the agent do

    /// Click the row's disclosure the way the reader does; it must currently read `title`.
    private func click(_ title: String, onRow key: String, _ rig: TrackerPaneRig,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard let row = rig.pane.rowViews[key] else {
            return XCTFail("no row \(key) to click \"\(title)\" on; rows: \(rig.pane.displayedRows.map(\.key))", file: file, line: line)
        }
        guard let button = Fx.disclosure(in: row), button.attributedTitle.string == title else {
            let offered = Fx.disclosure(in: row)?.attributedTitle.string ?? "no disclosure at all"
            return XCTFail("row \(key) offers \"\(offered)\", not \"\(title)\"", file: file, line: line)
        }
        button.performClick(nil)
        rigSettle(0.02)
        rig.settle()
    }

    private func expandTheNote(_ rig: TrackerPaneRig, file: StaticString = #filePath, line: UInt = #line) {
        click("more", onRow: Fx.targetKey, rig, file: file, line: line)
        assertExpanded(rig, "after more", file: file, line: line)
    }

    /// The agent moves the item to Done today and sets it done.
    private func moveToDoneToday(_ rig: TrackerPaneRig, _ board: inout TrackerHoldBoard,
                                 file: StaticString = #filePath, line: UInt = #line) {
        do {
            try board.moveItem(Hold.target, toSection: Hold.doneToday, status: "done")
        } catch {
            return XCTFail("\(error)", file: file, line: line)
        }
        rig.push(board, file: file, line: line)
    }

    @discardableResult
    private func select(_ target: TrackerHoldFx.Selecting, _ rig: TrackerPaneRig,
                        file: StaticString = #filePath, line: UInt = #line) throws -> TrackerTextView {
        let row = try XCTUnwrap(Fx.itemRow(Hold.target, in: rig.pane), "the item has a row to select in", file: file, line: line)
        let textView = try XCTUnwrap(Fx.textView(target, in: row), "the row has the \(target) to select in", file: file, line: line)
        XCTAssertTrue(rig.window.makeFirstResponder(textView), file: file, line: line)
        textView.setSelectedRange(NSRange(location: 0, length: 6))
        rigSettle(0.02)
        XCTAssertNotNil(Fx.itemRow(Hold.target, in: rig.pane)?.selectedTextView, "setup: text is selected in the row",
                        file: file, line: line)
        return textView
    }

    /// The reader clicks away, or drags, until nothing is selected any more.
    private func clearTheSelection(_ rig: TrackerPaneRig) {
        for view in rig.pane.rowViews.values {
            for textView in view.allTextViews where textView.hasSelection {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
        rigSettle(0.02)
        rig.settle()
    }

    /// Scroll the held row fully out of the viewport and back to the top.
    private func scrollAwayAndBack(_ rig: TrackerPaneRig, file: StaticString = #filePath, line: UInt = #line) throws {
        let pane = rig.pane
        let frame = try XCTUnwrap(pane.rowViews[Fx.targetKey], "the held row is on screen", file: file, line: line).frame
        let room = pane.documentView.frame.height - pane.clipView.bounds.height
        XCTAssertGreaterThan(room, frame.maxY + 3, "setup: the board scrolls far enough to hide the row", file: file, line: line)
        rig.scroll(to: frame.maxY + 3)
        rig.scroll(to: 0)
    }

    // MARK: What the pane shows

    private func assertHeldInPlace(_ rig: TrackerPaneRig, _ kind: TrackerHold.Kind,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rig.pane.deferral.held.contains { $0.key == Fx.targetKey && $0.kind == kind },
                      "setup: the row is held as \(kind): \(rig.pane.deferral.held.map { "\($0.key) \($0.kind)" })",
                      file: file, line: line)
        XCTAssertTrue(Fx.isListed(Hold.target, under: Hold.waiting, in: rig.pane),
                      "setup: the row is still under Waiting on you where the reader sees it: \(Fx.placements(of: Hold.target, in: rig.pane))",
                      file: file, line: line)
    }

    private func assertExpanded(_ rig: TrackerPaneRig, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let row = Fx.itemRow(Hold.target, in: rig.pane) else {
            return XCTFail("\(message): the item has no row; rows: \(rig.pane.displayedRows.map(\.key))", file: file, line: line)
        }
        XCTAssertEqual(row.row.item?.noteExpanded, true, "\(message): the row's note is expanded", file: file, line: line)
        XCTAssertNotNil(row.proseView, "\(message): the whole note is laid out", file: file, line: line)
        XCTAssertTrue(row.visibleText.contains(Hold.lastNoteMarker),
                      "\(message): the note's last line is shown: \(row.visibleText)", file: file, line: line)
        XCTAssertEqual(Fx.disclosure(in: row)?.attributedTitle.string, "less", "\(message): the disclosure offers less",
                       file: file, line: line)
    }

    /// The note is collapsed to its first line wherever the item is shown. With `rowMustShow` the item
    /// has to have a row; otherwise the pane may already have folded it away (a collapse that releases
    /// what was held), and then nothing may show the note's last line anywhere.
    private func assertCollapsed(_ rig: TrackerPaneRig, _ message: String, rowMustShow: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let pane = rig.pane
        XCTAssertFalse(Fx.shownText(pane).contains(Hold.lastNoteMarker),
                       "\(message): the note is still shown in full (the toggle did nothing): \(Fx.shownText(pane))",
                       file: file, line: line)
        guard let row = Fx.itemRow(Hold.target, in: pane) else {
            if rowMustShow { XCTFail("\(message): the item has no row; rows: \(pane.displayedRows.map(\.key))", file: file, line: line) }
            return
        }
        XCTAssertEqual(row.row.item?.noteExpanded, false, "\(message): the row's note is collapsed", file: file, line: line)
        XCTAssertEqual(row.row.item?.noteIsCollapsible, true, "\(message): the note still collapses", file: file, line: line)
        XCTAssertNil(row.proseView, "\(message): no prose is laid out for a collapsed note", file: file, line: line)
        XCTAssertTrue(row.visibleText.contains(Hold.firstNoteMarker), "\(message): the first line shows: \(row.visibleText)",
                      file: file, line: line)
        XCTAssertEqual(Fx.disclosure(in: row)?.attributedTitle.string, "more", "\(message): the disclosure offers more",
                       file: file, line: line)
    }

    /// The item is gone from "Waiting on you" (no row, no stub) and sits in Done today's group, in the
    /// pane and in what `tracker show` reports.
    private func assertLeftWaitingOnYou(_ rig: TrackerPaneRig, _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let pane = rig.pane
        XCTAssertFalse(Fx.isListed(Hold.target, under: Hold.waiting, in: pane),
                       "\(message): still shown under Waiting on you: \(Fx.placements(of: Hold.target, in: pane))",
                       file: file, line: line)
        XCTAssertNil(pane.rowViews[Fx.targetKey], "\(message): no row or stub is left in the old place", file: file, line: line)
        let group = Fx.doneGroup(Hold.doneToday, in: pane)
        XCTAssertEqual(group?.itemIds.contains(Hold.target), true, "\(message): Done today's group holds it: \(String(describing: group))",
                       file: file, line: line)
        XCTAssertEqual(group?.count, 2, "\(message): Done today counts it", file: file, line: line)
        XCTAssertTrue(pane.deferral.held.isEmpty, "\(message): nothing is still held: \(pane.deferral.held.map(\.key))", file: file, line: line)

        let report = pane.showReport()
        XCTAssertFalse(Fx.items(inSection: Hold.waiting, of: report).contains { ($0["id"] as? String) == Hold.target },
                       "\(message): tracker show still lists it under Waiting on you", file: file, line: line)
        let folded = Fx.items(inSection: Hold.doneToday, of: report).first { ($0["id"] as? String) == Hold.target }
        XCTAssertEqual(folded?["folded"] as? Bool, true, "\(message): tracker show lists it folded under Done today", file: file, line: line)
        XCTAssertEqual(folded?["status"] as? String, "done", file: file, line: line)
    }

    // MARK: - TB-1: a moved, finished item leaves "Waiting on you"

    func testAnItemExpandedBeforeItMovesToDoneTodayLeavesWaitingOnYouOnceItsRowScrollsOutOfView() throws {
        let scene = makeScene()
        let rig = scene.rig
        var board = scene.board
        expandTheNote(rig)

        moveToDoneToday(rig, &board)

        assertHeldInPlace(rig, .doneInPlace)
        XCTAssertEqual(rig.pane.rowViews[Fx.targetKey]?.isStrikethrough, true, "the finished item shows struck through where it was")
        try scrollAwayAndBack(rig)
        assertLeftWaitingOnYou(rig, "after the row scrolled out of view")
    }

    func testAnItemExpandedAfterItsMoveToDoneTodayArrivedStillLeavesWaitingOnYouOnceItsRowScrollsOutOfView() throws {
        let scene = makeScene()
        let rig = scene.rig
        var board = scene.board
        moveToDoneToday(rig, &board)
        assertHeldInPlace(rig, .doneInPlace)

        click("more", onRow: Fx.targetKey, rig)

        assertExpanded(rig, "the held row after more")
        assertHeldInPlace(rig, .doneInPlace)
        try scrollAwayAndBack(rig)
        assertLeftWaitingOnYou(rig, "after the row scrolled out of view")
    }

    func testAnItemMovedToDoneTodayWhileItsNoteWasSelectedLeavesWaitingOnYouWhenTheSelectionClears() throws {
        let scene = makeScene()
        let rig = scene.rig
        var board = scene.board
        expandTheNote(rig)
        try select(.noteText, rig)

        moveToDoneToday(rig, &board)

        // While the reader is selecting, nothing changes under them.
        assertHeldInPlace(rig, .selection)
        let held = try XCTUnwrap(rig.pane.rowViews[Fx.targetKey])
        XCTAssertTrue(held.visibleText.contains(Hold.lastNoteMarker), "the selected row keeps its content: \(held.visibleText)")
        XCTAssertNotNil(held.selectedTextView, "the selection is untouched")

        clearTheSelection(rig)

        assertLeftWaitingOnYou(rig, "after the selection cleared (the reader never scrolled)")
    }

    func testAnItemSelectedAfterItsMoveToDoneTodayArrivedLeavesWaitingOnYouWhenTheSelectionClears() throws {
        let scene = makeScene()
        let rig = scene.rig
        var board = scene.board
        expandTheNote(rig)
        moveToDoneToday(rig, &board)
        assertHeldInPlace(rig, .doneInPlace)
        try select(.itemText, rig)

        clearTheSelection(rig)

        assertLeftWaitingOnYou(rig, "after the selection cleared (the reader never scrolled)")
    }

    // MARK: - TB-2: "less" (and "more") show, whatever state the row is in

    func testLessCollapsesAndMoreExpandsTheNoteWhenNothingIsPending() {
        let rig = makeScene().rig
        assertCollapsed(rig, "setup", rowMustShow: true)

        click("more", onRow: Fx.targetKey, rig)
        assertExpanded(rig, "after more")

        click("less", onRow: Fx.targetKey, rig)
        assertCollapsed(rig, "after less", rowMustShow: true)
        XCTAssertTrue(rig.pane.deferral.held.isEmpty, "nothing was ever held")
    }

    func testLessCollapsesTheNoteWhileTheNotesTextIsSelected() throws {
        let rig = makeScene().rig
        expandTheNote(rig)
        try select(.noteText, rig)

        click("less", onRow: Fx.targetKey, rig)

        assertCollapsed(rig, "less with the note's text selected", rowMustShow: true)
    }

    func testLessCollapsesTheNoteWhileTheItemsTextIsSelected() throws {
        let rig = makeScene().rig
        expandTheNote(rig)
        try select(.itemText, rig)

        click("less", onRow: Fx.targetKey, rig)

        assertCollapsed(rig, "less with the item's text selected", rowMustShow: true)
    }

    func testMoreExpandsTheNoteWhileTheItemsTextIsSelected() throws {
        let rig = makeScene().rig
        try select(.itemText, rig)

        click("more", onRow: Fx.targetKey, rig)

        assertExpanded(rig, "more with the item's text selected")
    }

    func testMoreExpandsTheNoteWhileTheCollapsedNotesFirstLineIsSelected() throws {
        let rig = makeScene().rig
        try select(.noteText, rig)

        click("more", onRow: Fx.targetKey, rig)

        assertExpanded(rig, "more with the note's first line selected")
    }

    func testLessCollapsesTheNoteOfARowHeldForASelectionAfterTheBoardMovedTheItemToDoneToday() throws {
        let scene = makeScene()
        let rig = scene.rig
        var board = scene.board
        expandTheNote(rig)
        try select(.noteText, rig)
        moveToDoneToday(rig, &board)
        assertHeldInPlace(rig, .selection)
        XCTAssertTrue(Fx.shownText(rig.pane).contains(Hold.lastNoteMarker), "setup: the selected row still shows the whole note")

        click("less", onRow: Fx.targetKey, rig)

        assertCollapsed(rig, "less on a row held for a selection", rowMustShow: false)
    }

    func testLessCollapsesTheNoteOfAFinishedItemHeldInPlaceWithNoSelection() {
        let scene = makeScene()
        let rig = scene.rig
        var board = scene.board
        expandTheNote(rig)
        moveToDoneToday(rig, &board)
        assertHeldInPlace(rig, .doneInPlace)
        XCTAssertTrue(Fx.shownText(rig.pane).contains(Hold.lastNoteMarker), "setup: the held row shows the whole note")

        click("less", onRow: Fx.targetKey, rig)

        assertCollapsed(rig, "less on a finished item held in place", rowMustShow: false)
    }

    func testLessCollapsesTheNoteOfAnItemMovedToAnotherSectionWhileItsMovedToStubIsStillShown() throws {
        let scene = makeScene()
        let rig = scene.rig
        var board = scene.board
        expandTheNote(rig)
        try board.moveItem(Hold.target, toSection: Hold.next, status: "todo")
        rig.push(board)
        let stub = try XCTUnwrap(rig.pane.rowViews[Fx.targetKey], "a stub keeps the old place")
        XCTAssertTrue(stub.visibleText.contains("moved to Next"), "setup: the stub reads: \(stub.visibleText)")
        let liveKey = TrackerDeferral.movingPrefix + Hold.target
        XCTAssertNotNil(rig.pane.rowViews[liveKey], "setup: the live copy is already in Next")
        assertExpanded(rig, "the live copy keeps the expanded note")

        click("less", onRow: liveKey, rig)

        assertCollapsed(rig, "less on the live copy while the stub is shown", rowMustShow: true)
        XCTAssertTrue(Fx.isListed(Hold.target, under: Hold.next, in: rig.pane), "the item is listed under Next")
    }
}
