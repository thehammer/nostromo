// NostromoKit — TrackerPresentationTests.swift
//
// The tracker pane's view model (T1, design contract §9; PRD 12, 15, 21): the rows built from the
// 60-item golden board (`tests/fixtures/tracker/board-60.md`), the four filters, relative times
// and Copy as Markdown. Pure: `now` and the time zone are always passed in, nothing reads the
// clock, the pasteboard or UserDefaults.
//
// The golden frame is read relative to `#filePath` (the same files `TrackerWireTests` and the Rust
// round-trip test use). To vary the board, `TrackerFixtures.edited` decodes the golden JSON,
// edits the node dictionaries and decodes the result again, so every test exercises the real
// wire decoder. `TrackerFixtures` is shared with `TrackerDiffTests` and `TrackerDeferralTests`.

import XCTest
@testable import NostromoKit

// MARK: - Shared fixtures

enum TrackerFixtures {

    typealias Obj = [String: Any]

    /// 2025-10-15 17:06:40 UTC: four minutes after the golden board's newest item, so the board
    /// reads "updated 4 m ago" and its items read from "4 m" to "2 h".
    static let now = Date(timeIntervalSince1970: 1_760_548_000)

    static let utc = TimeZone(identifier: "UTC")!

    struct EditError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Loading

    /// `<repo>/tests/fixtures/tracker/<name>`: the test files are five directories deep.
    static func fixtureData(_ name: String, file: StaticString = #filePath) throws -> Data {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/tracker/\(name)")
        return try Data(contentsOf: url)
    }

    static func fixtureText(_ name: String, file: StaticString = #filePath) throws -> String {
        String(decoding: try fixtureData(name, file: file), as: UTF8.self)
    }

    /// The golden `tracker_board` frame as a JSON object.
    static func goldenFrame(file: StaticString = #filePath) throws -> Obj {
        let data = try fixtureData("frame-tracker-board.json", file: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? Obj else {
            throw EditError(description: "golden frame is not a JSON object")
        }
        return object
    }

    /// Decodes a frame (as JSON) the way the app does and returns its board.
    static func board(fromFrame frame: Obj) throws -> TrackerBoardViewWire {
        let data = try JSONSerialization.data(withJSONObject: frame)
        guard case .trackerBoard(let decoded) = ServerMsg.decode(from: data), let view = decoded.board else {
            throw EditError(description: "frame did not decode to a tracker_board with a board")
        }
        return view
    }

    static func golden(file: StaticString = #filePath) throws -> TrackerBoardViewWire {
        try board(fromFrame: try goldenFrame(file: file))
    }

    /// The golden board after `body` has edited its JSON.
    static func edited(file: StaticString = #filePath,
                       _ body: (inout Edit) throws -> Void) throws -> TrackerBoardViewWire {
        var frame = try goldenFrame(file: file)
        var edit = Edit(board: frame["board"] as? Obj ?? [:])
        try body(&edit)
        frame["board"] = edit.board
        return try board(fromFrame: frame)
    }

    static func iso(_ epoch: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    static func paragraph(_ text: String) -> Obj {
        let spans: [Obj] = [["kind": "text", "text": text]]
        return ["kind": "paragraph", "spans": spans]
    }

    // MARK: Editing the board's JSON

    struct Edit {
        var board: Obj

        var nodes: [Obj] {
            get { board["nodes"] as? [Obj] ?? [] }
            set { board["nodes"] = newValue }
        }

        private func isItem(_ node: Obj, _ id: String) -> Bool {
            (node["type"] as? String) == "item" && (node["id"] as? String) == id
        }

        private func isSection(_ node: Obj, _ id: String) -> Bool {
            (node["type"] as? String) == "section" && (node["id"] as? String) == id
        }

        func itemIndex(_ id: String) throws -> Int {
            guard let index = nodes.firstIndex(where: { isItem($0, id) }) else {
                throw EditError(description: "no item \(id) in the golden board")
            }
            return index
        }

        mutating func updateItem(_ id: String, _ change: (inout Obj) -> Void) throws {
            var all = nodes
            let index = try itemIndex(id)
            change(&all[index])
            nodes = all
        }

        mutating func setStatus(_ id: String, _ status: String) throws {
            try updateItem(id) { $0["status"] = status }
        }

        mutating func setText(_ id: String, _ text: String) throws {
            let spans: [Obj] = [["kind": "text", "text": text]]
            try updateItem(id) { $0["text_spans"] = spans }
        }

        mutating func setOwner(_ id: String, _ owner: String) throws {
            try updateItem(id) { $0["owner"] = owner }
        }

        mutating func setUpdatedAt(_ id: String, epoch: TimeInterval) throws {
            let stamp = TrackerFixtures.iso(epoch)
            try updateItem(id) { $0["updated_at"] = stamp }
        }

        mutating func setNoteBlocks(_ id: String, _ blocks: [Obj]) throws {
            try updateItem(id) { $0["note_blocks"] = blocks }
        }

        /// One paragraph per entry, so `paragraphs.count` is the note's line count.
        mutating func setNote(_ id: String, paragraphs: [String]) throws {
            try setNoteBlocks(id, paragraphs.map { TrackerFixtures.paragraph($0) })
        }

        mutating func removeItem(_ id: String) throws {
            var all = nodes
            all.remove(at: try itemIndex(id))
            nodes = all
        }

        /// Moves the item to the top of `section` (directly under its heading) and re-files it there.
        mutating func moveItem(_ id: String, toSection section: String) throws {
            var all = nodes
            var node = all.remove(at: try itemIndex(id))
            node["section"] = section
            guard let heading = all.firstIndex(where: { isSection($0, section) }) else {
                throw EditError(description: "no section \(section) in the golden board")
            }
            all.insert(node, at: heading + 1)
            nodes = all
        }

        /// Reorders within the item's own section: the item now follows `other`.
        mutating func moveItem(_ id: String, after other: String) throws {
            var all = nodes
            let node = all.remove(at: try itemIndex(id))
            guard let target = all.firstIndex(where: { isItem($0, other) }) else {
                throw EditError(description: "no item \(other) in the golden board")
            }
            all.insert(node, at: target + 1)
            nodes = all
        }

        /// Reorders within the item's own section: the item now precedes `other`.
        mutating func moveItem(_ id: String, before other: String) throws {
            var all = nodes
            let node = all.remove(at: try itemIndex(id))
            guard let target = all.firstIndex(where: { isItem($0, other) }) else {
                throw EditError(description: "no item \(other) in the golden board")
            }
            all.insert(node, at: target)
            nodes = all
        }

        /// A new item directly under the heading of `section`.
        mutating func insertItem(id: String, section: String, status: String = "todo",
                                 text: String = "A new item", updatedAt: TimeInterval = 1_760_547_800) throws {
            let spans: [Obj] = [["kind": "text", "text": text]]
            let noBlocks: [Obj] = []
            let item: Obj = [
                "type": "item",
                "id": id,
                "section": section,
                "text_spans": spans,
                "status": status,
                "updated_at": TrackerFixtures.iso(updatedAt),
                "note_blocks": noBlocks,
                "links": noBlocks,
                "kind": "item",
                "ran": false,
                "source": "- [ ] \(text)\n",
            ]
            var all = nodes
            guard let heading = all.firstIndex(where: { isSection($0, section) }) else {
                throw EditError(description: "no section \(section) in the golden board")
            }
            all.insert(item, at: heading + 1)
            nodes = all
        }

        mutating func setBanner(_ banner: Obj?) {
            if let banner {
                board["banner"] = banner
            } else {
                board.removeValue(forKey: "banner")
            }
        }

        mutating func setCommittable(remote: String?) {
            var committable: Obj = [:]
            if let remote { committable["remote"] = remote }
            board["committable"] = committable
        }

        mutating func setHiddenByUser(_ hidden: Bool) {
            board["hidden_by_user"] = hidden
        }

        mutating func setBoardUpdatedAt(epoch: TimeInterval) {
            board["updated_at"] = TrackerFixtures.iso(epoch)
        }

        /// Replaces the Log with these lines (oldest first).
        mutating func setLog(_ texts: [String]) {
            var entries: [Obj] = []
            for (index, text) in texts.enumerated() {
                entries.append(["time": "09:\(String(format: "%02d", index))", "text": text])
            }
            board["log"] = entries
        }
    }

    // MARK: Presenting and reading rows

    static func present(_ board: TrackerBoardViewWire,
                        now: Date = TrackerFixtures.now,
                        filter: TrackerFilter = .all,
                        folds: TrackerFoldState = TrackerFoldState()) -> TrackerPresentation {
        TrackerPresenter.present(board: board, now: now, filter: filter, folds: folds, timeZone: utc)
    }

    enum RowKind: Equatable {
        case section, item, doneGroup, prose, log, stub
    }

    static func kind(of row: TrackerRow) -> RowKind {
        switch row.content {
        case .section: return .section
        case .item: return .item
        case .doneGroup: return .doneGroup
        case .prose: return .prose
        case .log: return .log
        case .stub: return .stub
        }
    }

    static func keys(_ rows: [TrackerRow]) -> [String] {
        rows.map { $0.key }
    }

    static func rows(_ rows: [TrackerRow], ofKind wanted: RowKind) -> [TrackerRow] {
        rows.filter { kind(of: $0) == wanted }
    }

    static func sections(_ rows: [TrackerRow]) -> [TrackerSectionRow] {
        rows.compactMap { row -> TrackerSectionRow? in
            if case .section(let section) = row.content { return section }
            return nil
        }
    }

    static func doneGroups(_ rows: [TrackerRow]) -> [TrackerDoneGroupRow] {
        rows.compactMap { row -> TrackerDoneGroupRow? in
            if case .doneGroup(let group) = row.content { return group }
            return nil
        }
    }

    /// The item rows (not stubs), top to bottom.
    static func items(_ rows: [TrackerRow]) -> [TrackerItemRow] {
        rows.compactMap { row -> TrackerItemRow? in
            if case .item(let item) = row.content { return item }
            return nil
        }
    }

    /// Item rows plus the done items folded into a Done group.
    static func allItems(_ presentation: TrackerPresentation) -> [TrackerItemRow] {
        items(presentation.rows) + Array(presentation.foldedItems.values)
    }

    /// An item's row, whether it is a visible row or folded into a Done group.
    static func itemRow(_ id: String, in presentation: TrackerPresentation) -> TrackerItemRow? {
        for row in presentation.rows {
            if case .item(let item) = row.content, item.id == id { return item }
        }
        return presentation.foldedItems[id]
    }

    static func rowIndex(_ key: String, in rows: [TrackerRow]) -> Int? {
        rows.firstIndex(where: { $0.key == key })
    }

    static func wireItems(_ board: TrackerBoardViewWire) -> [TrackerItemWire] {
        board.nodes.compactMap { node -> TrackerItemWire? in
            if case .item(let item) = node { return item }
            return nil
        }
    }
}

private typealias TFx = TrackerFixtures

// MARK: - Presentation

final class TrackerPresentationTests: XCTestCase {

    private let needsYouIds = [
        "docum-1740", "backf-1777", "rotat-1814", "audit-1851", "check-1888",
        "verif-1925", "retry-1962", "revie-1999", "draft-2036", "close-2073",
    ]

    private let doneIdsBySection: [String: [String]] = [
        "done": ["repro-2110", "triag-2147", "docum-2184", "backf-2221", "rotat-2258", "audit-2295",
                 "check-2332", "verif-2369", "retry-2406", "revie-2443", "draft-2480", "close-2517"],
        "findings": ["triag-2591", "backf-2665", "audit-2739", "verif-2813", "revie-2887"],
    ]

    // MARK: Sections

    func testSixSectionsInFileOrderWithTheirItemCountsDoneIncluded() throws {
        let p = TFx.present(try TFx.golden())
        let described = TFx.sections(p.rows).map { "\($0.id)|\($0.title)|\($0.count)" }
        XCTAssertEqual(described, [
            "now|Now|10", "next|Next|10", "waiting-on-you|Waiting on you|10",
            "done|Done|12", "findings|Findings|10", "loose-ends|Loose ends|8",
        ])
        XCTAssertEqual(TFx.keys(TFx.rows(p.rows, ofKind: .section)), [
            "section:now", "section:next", "section:waiting-on-you",
            "section:done", "section:findings", "section:loose-ends",
        ])
    }

    // MARK: Item rows

    func testEveryNonDoneItemHasAnItemRowInFileOrderAndDoneItemsDoNot() throws {
        let board = try TFx.golden()
        let p = TFx.present(board)
        let expected = TFx.wireItems(board).filter { $0.status != .done }.map { "item:\($0.id)" }
        XCTAssertEqual(expected.count, 43)
        XCTAssertEqual(TFx.keys(TFx.rows(p.rows, ofKind: .item)), expected)
    }

    func testItemRowsSitUnderTheirOwnSectionHeading() throws {
        let p = TFx.present(try TFx.golden())
        var current = ""
        for row in p.rows {
            switch row.content {
            case .section(let section): current = section.id
            case .item(let item): XCTAssertEqual(item.sectionId, current, item.id)
            default: break
            }
        }
    }

    func testStatusMarkMatchesTheStatusForEveryItem() throws {
        let p = TFx.present(try TFx.golden())
        let expected: [TrackerStatusWire: String] = [
            .todo: "○", .inProgress: "◐", .blocked: "⊘", .needsYou: "●", .done: "✓",
        ]
        let all = TFx.allItems(p)
        XCTAssertEqual(all.count, 60)
        for item in all {
            XCTAssertEqual(item.mark, expected[item.status], "\(item.id) is \(item.status)")
        }
    }

    func testNamedItemsShowTheirStatusMarkTextAndOwner() throws {
        let p = TFx.present(try TFx.golden())
        let table: [(id: String, status: TrackerStatusWire, mark: String, owner: String?, text: String)] = [
            ("revie-1111", .todo, "○", nil, "Review queue job 8812"),
            ("verif-1037", .inProgress, "◐", "cody", "Verify webhook retries"),
            ("repro-1222", .blocked, "⊘", nil, "Reproduce staging deploy"),
            ("retry-1074", .blocked, "⊘", "me", "Retry retry backoff"),
            ("docum-1740", .needsYou, "●", "me", "Document referral 4411 duplicate"),
            ("repro-2110", .done, "✓", nil, "Reproduce user avatar sync"),
            ("triag-2147", .done, "✓", "cody", "Triage slow query 77"),
        ]
        for row in table {
            let item = try XCTUnwrap(TFx.itemRow(row.id, in: p), row.id)
            XCTAssertEqual(item.status, row.status, row.id)
            XCTAssertEqual(item.mark, row.mark, row.id)
            XCTAssertEqual(item.owner, row.owner, row.id)
            XCTAssertEqual(item.text, row.text, row.id)
        }
    }

    func testRelativeTimeOnItemRowsComesFromTheInjectedNow() throws {
        let p = TFx.present(try TFx.golden())
        // now = 1_760_548_000; the epochs are the ones in board-60.md's markers.
        let table: [(id: String, updated: TimeInterval, relative: String)] = [
            ("audit-3183", 1_760_547_729, "4 m"),
            ("rotat-3146", 1_760_547_598, "6 m"),
            ("docum-1740", 1_760_542_620, "1 h"),
            ("repro-2110", 1_760_543_930, "1 h"),
            ("verif-1037", 1_760_540_131, "2 h"),
            ("check-1000", 1_760_540_000, "2 h"),
        ]
        for row in table {
            let item = try XCTUnwrap(TFx.itemRow(row.id, in: p), row.id)
            XCTAssertEqual(item.updatedAt, Date(timeIntervalSince1970: row.updated), row.id)
            XCTAssertEqual(item.relativeTime, row.relative, row.id)
        }
    }

    func testRelativeTimeOnItemRowsFollowsTheNowAndTimeZoneTheCallerPasses() throws {
        let board = try TFx.golden()
        let threeDaysLater = Date(timeIntervalSince1970: 1_760_548_000 + 3 * 86_400)
        // check-1000 was updated 2025-10-15 14:53:20 UTC.
        let inUTC = TrackerPresenter.present(board: board, now: threeDaysLater, timeZone: TFx.utc)
        XCTAssertEqual(TFx.itemRow("check-1000", in: inUTC)?.relativeTime, "Oct 15")
        let kiritimati = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))   // UTC+14: already Oct 16
        let inKiritimati = TrackerPresenter.present(board: board, now: threeDaysLater, timeZone: kiritimati)
        XCTAssertEqual(TFx.itemRow("check-1000", in: inKiritimati)?.relativeTime, "Oct 16")
    }

    func testItemsWithoutATimeShowNoRelativeTime() throws {
        let board = try TFx.edited { edit in
            var all = edit.nodes
            let index = try edit.itemIndex("revie-1111")
            all[index].removeValue(forKey: "updated_at")
            edit.nodes = all
        }
        let item = try XCTUnwrap(TFx.itemRow("revie-1111", in: TFx.present(board)))
        XCTAssertNil(item.updatedAt)
        XCTAssertEqual(item.relativeTime, "")
    }

    // MARK: Done groups

    func testDoneItemsFoldIntoACollapsedDoneGroupAtTheEndOfEachSectionThatHasThem() throws {
        let p = TFx.present(try TFx.golden())
        XCTAssertEqual(TFx.keys(TFx.rows(p.rows, ofKind: .doneGroup)), ["done:done", "done:findings"])
        let groups = TFx.doneGroups(p.rows)
        XCTAssertEqual(groups.map { $0.sectionId }, ["done", "findings"])
        XCTAssertEqual(groups.map { $0.count }, [12, 5])
        XCTAssertEqual(groups.map { $0.expanded }, [false, false])
        XCTAssertEqual(groups.map { $0.title }, ["Done (12)", "Done (5)"])

        // A group closes its section: the next row is the next section's heading.
        XCTAssertEqual(try XCTUnwrap(TFx.rowIndex("done:done", in: p.rows)) + 1,
                       TFx.rowIndex("section:findings", in: p.rows))
        XCTAssertEqual(try XCTUnwrap(TFx.rowIndex("done:findings", in: p.rows)) + 1,
                       TFx.rowIndex("section:loose-ends", in: p.rows))
    }

    func testFoldedItemsAreTheDoneItemsAndNotRows() throws {
        let p = TFx.present(try TFx.golden())
        let expected = Set(doneIdsBySection.values.flatMap { $0 })
        XCTAssertEqual(expected.count, 17)
        XCTAssertEqual(Set(p.foldedItems.keys), expected)
        for (id, item) in p.foldedItems {
            XCTAssertEqual(item.id, id)
            XCTAssertEqual(item.status, .done, id)
            XCTAssertNil(TFx.rowIndex("item:\(id)", in: p.rows), "\(id) is folded, not a row")
        }
    }

    func testExpandingADoneGroupShowsItsItemsRightAfterTheGroupRow() throws {
        let folds = TrackerFoldState(expandedDoneGroups: ["findings"])
        let p = TFx.present(try TFx.golden(), folds: folds)
        let groupIndex = try XCTUnwrap(TFx.rowIndex("done:findings", in: p.rows))
        let after = p.rows[(groupIndex + 1)..<(groupIndex + 6)]
        XCTAssertEqual(TFx.keys(Array(after)), (doneIdsBySection["findings"] ?? []).map { "item:\($0)" })
        XCTAssertEqual(p.rows[groupIndex + 6].key, "section:loose-ends")
        XCTAssertEqual(TFx.doneGroups(p.rows).map { $0.expanded }, [false, true])
        XCTAssertEqual(Set(p.foldedItems.keys), Set(doneIdsBySection["done"] ?? []),
                       "only the group that stayed collapsed still folds its items")
        // Expanding a group does not change the section's count.
        XCTAssertEqual(TFx.sections(p.rows).first(where: { $0.id == "findings" })?.count, 10)
    }

    func testAllDoneSectionShowsOnlyItsHeadingAndGroupUnderAll() throws {
        let p = TFx.present(try TFx.golden())
        let start = try XCTUnwrap(TFx.rowIndex("section:done", in: p.rows))
        let end = try XCTUnwrap(TFx.rowIndex("section:findings", in: p.rows))
        XCTAssertEqual(TFx.keys(Array(p.rows[start..<end])), ["section:done", "done:done"])
    }

    // MARK: Waiting on you strip

    func testStripListsExactlyTheTenNeedsYouItemsInFileOrderAndTheyStayInTheirSection() throws {
        let p = TFx.present(try TFx.golden())
        XCTAssertEqual(p.strip.entries.map { $0.key }, needsYouIds.map { "item:\($0)" })
        XCTAssertEqual(p.strip.count, 10)
        XCTAssertEqual(p.strip.title, "Waiting on you (10)")
        XCTAssertEqual(p.strip.entries.first?.text, "Document referral 4411 duplicate")
        XCTAssertEqual(p.strip.entries.first?.detail, "Waiting on you")

        let start = try XCTUnwrap(TFx.rowIndex("section:waiting-on-you", in: p.rows))
        let end = try XCTUnwrap(TFx.rowIndex("section:done", in: p.rows))
        XCTAssertEqual(TFx.keys(Array(p.rows[(start + 1)..<end])), needsYouIds.map { "item:\($0)" })
    }

    func testAnItemTurnedNeedsYouJoinsTheStripInFileOrderAndKeepsItsRow() throws {
        let board = try TFx.edited { try $0.setStatus("revie-1111", "needs-you") }
        let p = TFx.present(board)
        XCTAssertEqual(p.strip.count, 11)
        XCTAssertEqual(p.strip.entries.first?.key, "item:revie-1111", "Now comes before Waiting on you in the file")
        XCTAssertEqual(p.strip.entries.first?.detail, "Now")
        XCTAssertNotNil(TFx.rowIndex("item:revie-1111", in: p.rows))
    }

    func testStripCombinesEverySourceAndIsEmptyWithoutAny() throws {
        struct DecisionSource: TrackerWaitingSource {
            func waitingEntries(board: TrackerBoardViewWire) -> [TrackerWaitingEntry] {
                [TrackerWaitingEntry(key: "decision:1", text: "Approve the deploy", detail: "Perri")]
            }
        }
        let board = try TFx.golden()
        let both = TrackerPresenter.present(board: board, now: TFx.now,
                                            sources: [TrackerNeedsYouSource(), DecisionSource()], timeZone: TFx.utc)
        XCTAssertEqual(both.strip.count, 11)
        XCTAssertEqual(both.strip.entries.last?.key, "decision:1")
        XCTAssertEqual(both.strip.title, "Waiting on you (11)")

        let none = TrackerPresenter.present(board: board, now: TFx.now, sources: [], timeZone: TFx.utc)
        XCTAssertEqual(none.strip.count, 0)
        XCTAssertEqual(none.strip.title, "Waiting on you (0)")
    }

    // MARK: Prose

    func testProseRowsKeepTheirKeysAndPlaces() throws {
        let board = try TFx.golden()
        let p = TFx.present(board)
        let keys = ["prose:6b9cd2405a57a890-0", "prose:b7a086995f3f3e13-0", "prose:893d578a815a55ee-0"]
        XCTAssertEqual(TFx.keys(TFx.rows(p.rows, ofKind: .prose)), keys)

        XCTAssertEqual(p.rows.first?.key, keys[0], "the intro sits above the first section")
        let waiting = try XCTUnwrap(TFx.rowIndex("section:waiting-on-you", in: p.rows))
        XCTAssertEqual(p.rows[waiting - 1].key, keys[1], "the note closes the Next section")
        let loose = try XCTUnwrap(TFx.rowIndex("section:loose-ends", in: p.rows))
        XCTAssertEqual(p.rows[loose + 1].key, keys[2], "the loose-ends intro follows its heading")

        // The row carries the node's blocks.
        guard case .prose(let intro) = p.rows[0].content else { return XCTFail("first row is prose") }
        let wireBlocks = board.nodes.compactMap { node -> [MdBlock]? in
            if case .prose(let key, let blocks, _) = node, key == "6b9cd2405a57a890-0" { return blocks }
            return nil
        }.first
        XCTAssertEqual(intro.blocks, wireBlocks)
        XCTAssertFalse(intro.blocks.isEmpty)
    }

    // MARK: Log

    func testLogRowIsNewestFirstAndCollapsedToFiveLines() throws {
        let p = TFx.present(try TFx.golden())
        XCTAssertEqual(p.rows.last?.key, "log")
        guard case .log(let log) = try XCTUnwrap(p.rows.last).content else { return XCTFail("last row is the log") }
        XCTAssertEqual(log.title, "Log")
        XCTAssertEqual(log.total, 12)
        XCTAssertFalse(log.expanded)
        XCTAssertTrue(log.isCollapsible)
        let expected = (8...12).reversed().map { "Claudia: logged event \(String(format: "%02d", $0))" }
        XCTAssertEqual(log.lines.map { $0.text }, expected)
        XCTAssertEqual(log.lines.first?.time, "09:12")
    }

    func testLogRowShowsEveryLineNewestFirstWhenExpanded() throws {
        let p = TFx.present(try TFx.golden(), folds: TrackerFoldState(logExpanded: true))
        guard case .log(let log) = try XCTUnwrap(p.rows.last).content else { return XCTFail("last row is the log") }
        XCTAssertTrue(log.expanded)
        XCTAssertEqual(log.lines.count, 12)
        XCTAssertEqual(log.lines.first?.text, "Claudia: logged event 12")
        XCTAssertEqual(log.lines.last?.text, "Claudia: logged event 01")
    }

    func testLogOnlyCollapsesWhenItHasMoreThanFiveLines() throws {
        let table: [(total: Int, shown: Int, collapsible: Bool)] = [
            (1, 1, false), (5, 5, false), (6, 5, true), (12, 5, true),
        ]
        for row in table {
            let texts = (1...row.total).map { "line \($0)" }
            let board = try TFx.edited { $0.setLog(texts) }
            let p = TFx.present(board)
            guard case .log(let log) = try XCTUnwrap(p.rows.last).content else { return XCTFail("last row is the log") }
            XCTAssertEqual(log.lines.count, row.shown, "\(row.total) lines")
            XCTAssertEqual(log.total, row.total)
            XCTAssertEqual(log.isCollapsible, row.collapsible, "\(row.total) lines")
            XCTAssertEqual(log.lines.first?.text, "line \(row.total)", "newest first")
        }
    }

    // MARK: Notes

    func testNoteCollapsesOnlyWhenLongerThanTwoLines() throws {
        let cases: [(name: String, blocks: [TFx.Obj], collapsible: Bool)] = [
            ("one paragraph", [TFx.paragraph("a")], false),
            ("two paragraphs", [TFx.paragraph("a"), TFx.paragraph("b")], false),
            ("three paragraphs", [TFx.paragraph("a"), TFx.paragraph("b"), TFx.paragraph("c")], true),
            ("one paragraph of three lines", [TFx.paragraph("a\nb\nc")], true),
            ("a code block of three lines", [["kind": "code_block", "text": "a\nb\nc\n"]], true),
            ("a code block of two lines", [["kind": "code_block", "text": "a\nb\n"]], false),
        ]
        for c in cases {
            let board = try TFx.edited { try $0.setNoteBlocks("verif-1037", c.blocks) }
            let item = try XCTUnwrap(TFx.itemRow("verif-1037", in: TFx.present(board)), c.name)
            XCTAssertEqual(item.noteIsCollapsible, c.collapsible, c.name)
            XCTAssertEqual(item.noteExpanded, !c.collapsible, "\(c.name): a long note starts collapsed, a short one is shown whole")
        }
    }

    func testALongNoteExpandsOnlyForTheItemsTheUserExpanded() throws {
        let board = try TFx.edited { edit in
            try edit.setNote("verif-1037", paragraphs: ["first", "second", "third"])
            try edit.setNote("retry-1518", paragraphs: ["first", "second", "third"])
        }
        let folds = TrackerFoldState(expandedNotes: ["verif-1037"])
        let p = TFx.present(board, folds: folds)
        let opened = try XCTUnwrap(TFx.itemRow("verif-1037", in: p))
        let closed = try XCTUnwrap(TFx.itemRow("retry-1518", in: p))
        XCTAssertTrue(opened.noteIsCollapsible)
        XCTAssertTrue(opened.noteExpanded)
        XCTAssertTrue(closed.noteIsCollapsible)
        XCTAssertFalse(closed.noteExpanded)
    }

    func testExpandingAShortNoteChangesNothing() throws {
        let board = try TFx.golden()
        let plain = TFx.present(board)
        let expanded = TFx.present(board, folds: TrackerFoldState(expandedNotes: ["check-1000"]))
        XCTAssertEqual(plain.rows, expanded.rows)
    }

    func testNoteFirstLineIsThePlainTextOfTheNotesFirstLine() throws {
        let p = TFx.present(try TFx.golden())
        XCTAssertEqual(TFx.itemRow("check-1000", in: p)?.noteFirstLine, "Seen on host 14, see the log for detail")
        XCTAssertNil(TFx.itemRow("verif-1037", in: p)?.noteFirstLine, "no note, no first line")
    }

    func testABlockedItemExposesTheFirstLineOfItsNoteEvenWhenTheNoteIsCollapsed() throws {
        let board = try TFx.edited {
            try $0.setNote("repro-1222", paragraphs: ["Waiting on the vendor", "second line", "third line"])
        }
        let item = try XCTUnwrap(TFx.itemRow("repro-1222", in: TFx.present(board)))
        XCTAssertEqual(item.status, .blocked)
        XCTAssertEqual(item.noteFirstLine, "Waiting on the vendor")
        XCTAssertTrue(item.noteIsCollapsible)
        XCTAssertFalse(item.noteExpanded)
    }

    func testLinkTextsAreCarriedAsPlainText() throws {
        let p = TFx.present(try TFx.golden())
        XCTAssertEqual(TFx.itemRow("check-1000", in: p)?.linkTexts, ["PR #253"])
        XCTAssertEqual(TFx.itemRow("close-1185", in: p)?.linkTexts, ["CORE-2841", "Sentry PORTAL-1F2"])
        XCTAssertEqual(TFx.itemRow("verif-1037", in: p)?.linkTexts, [])
    }

    // MARK: Environment badges

    func testEnvironmentBadgesMarkProductionLikeEnvironmentsAsHazards() throws {
        let p = TFx.present(try TFx.golden())
        let table: [(id: String, badge: String?, hazard: Bool)] = [
            ("close-1629", "PROD", true),
            ("verif-1481", "CANADA", true),
            ("check-1888", "DEMO", true),
            ("rotat-2702", "ENV?", true),
            ("audit-2295", "STAGING", false),
            ("close-1185", "LOCAL", false),
            ("check-1000", nil, false),
        ]
        for row in table {
            let item = try XCTUnwrap(TFx.itemRow(row.id, in: p), row.id)
            XCTAssertEqual(item.envBadge, row.badge, row.id)
            XCTAssertEqual(item.isHazard, row.hazard, row.id)
        }
    }

    // MARK: Header and banner

    func testHeaderCarriesTitlePathAndUpdatedTime() throws {
        let p = TFx.present(try TFx.golden())
        XCTAssertEqual(p.header.title, "Synthetic release triage")
        XCTAssertEqual(p.header.path, "/repo/.claude/wip/sentry-triage/index.md")
        XCTAssertEqual(p.header.updatedText, "updated 4 m ago")
        XCTAssertNil(p.header.committableText, "the golden board is not committable")
        XCTAssertNil(p.banner)
        XCTAssertFalse(p.hiddenByUser)
    }

    func testHeaderUpdatedTextFollowsTheBoardsTimeAndTheInjectedNow() throws {
        let board = try TFx.golden()
        let later = Date(timeIntervalSince1970: 1_760_547_729 + 3 * 86_400)
        XCTAssertEqual(TFx.present(board, now: later).header.updatedText, "updated Oct 15")
        let untimed = try TFx.edited { $0.board.removeValue(forKey: "updated_at") }
        XCTAssertEqual(TFx.present(untimed).header.updatedText, "")
    }

    func testCommittableBoardShowsWhereItCanBeCommitted() throws {
        let board = try TFx.edited { $0.setCommittable(remote: "github.com/example/repo") }
        XCTAssertEqual(TFx.present(board).header.committableText,
                       "This file can be committed to github.com/example/repo")
    }

    func testCommittableBoardWithoutARemoteStillSaysItCanBeCommitted() throws {
        let board = try TFx.edited { $0.setCommittable(remote: nil) }
        let text = try XCTUnwrap(TFx.present(board).header.committableText)
        XCTAssertTrue(text.hasPrefix("This file can be committed"), text)
    }

    func testHiddenByUserIsCarriedThrough() throws {
        let board = try TFx.edited { $0.setHiddenByUser(true) }
        XCTAssertTrue(TFx.present(board).hiddenByUser)
    }

    func testUnreadableBannerNamesTheLine() throws {
        let board = try TFx.edited {
            $0.setBanner(["type": "unreadable", "line": 12, "reason": "duplicate_id"])
        }
        let banner = try XCTUnwrap(TFx.present(board).banner)
        XCTAssertEqual(banner.kind, .unreadable)
        XCTAssertTrue(banner.text.contains("line 12"), banner.text)
    }

    func testUnreadableBannerWithALastGoodTimeStillShowsTheLine() throws {
        let board = try TFx.edited {
            $0.setBanner(["type": "unreadable", "line": 42, "reason": "garbled marker",
                          "last_good_at": TrackerFixtures.iso(1_760_547_740)])
        }
        let banner = try XCTUnwrap(TFx.present(board).banner)
        XCTAssertEqual(banner.kind, .unreadable)
        XCTAssertTrue(banner.text.contains("line 42"), banner.text)
    }

    func testMissingBannerSaysTheFileIsGone() throws {
        let banners: [TFx.Obj] = [
            ["type": "missing"],
            ["type": "missing", "last_seen": TrackerFixtures.iso(1_760_547_740)],
        ]
        for banner in banners {
            let board = try TFx.edited { $0.setBanner(banner) }
            let row = try XCTUnwrap(TFx.present(board).banner)
            XCTAssertEqual(row.kind, .missing)
            XCTAssertFalse(row.text.isEmpty)
        }
    }

    func testAnUnknownBannerTypeShowsNoBanner() throws {
        let board = try TFx.edited { $0.setBanner(["type": "hologram"]) }
        XCTAssertNil(TFx.present(board).banner)
    }

    func testBannerLeavesTheRowsUntouched() throws {
        let clean = TFx.present(try TFx.golden())
        let board = try TFx.edited { $0.setBanner(["type": "missing"]) }
        XCTAssertEqual(TFx.present(board).rows, clean.rows)
    }

    // MARK: Filters

    func testAllFilterShowsEverythingTheBoardHolds() throws {
        let p = TFx.present(try TFx.golden(), filter: .all)
        XCTAssertEqual(p.filter, .all)
        XCTAssertEqual(TFx.rows(p.rows, ofKind: .section).count, 6)
        XCTAssertEqual(TFx.rows(p.rows, ofKind: .prose).count, 3)
        XCTAssertEqual(TFx.rows(p.rows, ofKind: .doneGroup).count, 2)
        XCTAssertEqual(TFx.rows(p.rows, ofKind: .log).count, 1)
    }

    func testOpenFilterShowsNoDoneItemsNoDoneGroupNoProseAndNoLog() throws {
        let p = TFx.present(try TFx.golden(), filter: .open)
        XCTAssertEqual(p.filter, .open)
        let described = TFx.sections(p.rows).map { "\($0.id)|\($0.count)" }
        XCTAssertEqual(described, ["now|10", "next|10", "waiting-on-you|10", "findings|5", "loose-ends|8"],
                       "counts follow the filter and the all-done section disappears")
        let items = TFx.items(p.rows)
        XCTAssertEqual(items.count, 43)
        XCTAssertTrue(items.allSatisfy { !$0.isDone })
        for kind in [TFx.RowKind.doneGroup, .prose, .log] {
            XCTAssertTrue(TFx.rows(p.rows, ofKind: kind).isEmpty, "\(kind)")
        }
    }

    func testWaitingFilterShowsOnlyNeedsYouItemsAndOnlyTheirSections() throws {
        let p = TFx.present(try TFx.golden(), filter: .waiting)
        XCTAssertEqual(p.filter, .waiting)
        XCTAssertEqual(TFx.sections(p.rows).map { "\($0.id)|\($0.count)" }, ["waiting-on-you|10"])
        XCTAssertEqual(TFx.items(p.rows).map { $0.id }, needsYouIds)
        XCTAssertTrue(TFx.items(p.rows).allSatisfy { $0.isNeedsYou })
        for kind in [TFx.RowKind.doneGroup, .prose, .log] {
            XCTAssertTrue(TFx.rows(p.rows, ofKind: kind).isEmpty, "\(kind)")
        }
    }

    func testWaitingFilterIncludesEverySectionThatHasANeedsYouItem() throws {
        let board = try TFx.edited { try $0.setStatus("revie-1111", "needs-you") }
        let p = TFx.present(board, filter: .waiting)
        XCTAssertEqual(TFx.sections(p.rows).map { "\($0.id)|\($0.count)" }, ["now|1", "waiting-on-you|10"])
        XCTAssertEqual(TFx.items(p.rows).first?.id, "revie-1111")
    }

    func testDoneFilterShowsDoneItemsDirectlyWithoutADoneGroup() throws {
        let p = TFx.present(try TFx.golden(), filter: .done)
        XCTAssertEqual(p.filter, .done)
        XCTAssertEqual(TFx.sections(p.rows).map { "\($0.id)|\($0.count)" }, ["done|12", "findings|5"])
        let ids = TFx.items(p.rows).map { $0.id }
        XCTAssertEqual(ids, (doneIdsBySection["done"] ?? []) + (doneIdsBySection["findings"] ?? []))
        XCTAssertTrue(TFx.items(p.rows).allSatisfy { $0.isDone })
        for kind in [TFx.RowKind.doneGroup, .prose, .log] {
            XCTAssertTrue(TFx.rows(p.rows, ofKind: kind).isEmpty, "\(kind)")
        }
    }

    func testSectionWithNothingToShowIsDroppedUnderEveryNarrowingFilter() throws {
        let board = try TFx.golden()
        for filter in [TrackerFilter.open, .waiting, .done] {
            for section in TFx.sections(TFx.present(board, filter: filter).rows) {
                XCTAssertGreaterThan(section.count, 0, "\(filter): \(section.id)")
            }
        }
    }

    func testFilterIsViewOnlyAndReAllRestoresTheOriginalRows() throws {
        let board = try TFx.golden()
        let pristine = try TFx.golden()
        let original = TFx.present(board, filter: .all)
        for filter in TrackerFilter.allCases { _ = TFx.present(board, filter: filter) }
        XCTAssertEqual(board, pristine, "presenting never changes the board")
        XCTAssertEqual(TFx.present(board, filter: .all), original)
    }

    func testFilterLabels() {
        XCTAssertEqual(TrackerFilter.allCases, [.all, .open, .waiting, .done])
        XCTAssertEqual(TrackerFilter.allCases.map { $0.label }, ["All", "Open", "Waiting on you", "Done"])
    }

    // MARK: Row keys

    func testRowKeysAreUniqueUnderEveryFilterAndFoldState() throws {
        let board = try TFx.golden()
        let allExpanded = TrackerFoldState(expandedNotes: ["check-1000"], expandedDoneGroups: ["done", "findings"],
                                           logExpanded: true)
        for filter in TrackerFilter.allCases {
            for folds in [TrackerFoldState(), allExpanded] {
                let keys = TFx.keys(TFx.present(board, filter: filter, folds: folds).rows)
                XCTAssertEqual(keys.count, Set(keys).count, "\(filter)")
            }
        }
    }

    func testRowKeyVocabulary() throws {
        let p = TFx.present(try TFx.golden())
        for row in p.rows {
            switch row.content {
            case .section(let section): XCTAssertEqual(row.key, "section:\(section.id)")
            case .item(let item): XCTAssertEqual(row.key, "item:\(item.id)")
            case .doneGroup(let group): XCTAssertEqual(row.key, "done:\(group.sectionId)")
            case .prose(let prose): XCTAssertEqual(row.key, "prose:\(prose.key)")
            case .log: XCTAssertEqual(row.key, "log")
            case .stub: XCTFail("a presentation never holds stubs")
            }
        }
    }

    func testAnEmptyBoardPresentsNoRows() throws {
        let board = try TFx.edited { edit in
            edit.nodes = []
            edit.board["log"] = [TFx.Obj]()
        }
        let p = TFx.present(board)
        XCTAssertTrue(p.rows.isEmpty)
        XCTAssertEqual(p.strip.count, 0)
        XCTAssertTrue(p.foldedItems.isEmpty)
    }
}

// MARK: - Relative time

final class TrackerRelativeTimeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_760_548_000)   // 2025-10-15 17:06:40 UTC
    private let utc = TimeZone(identifier: "UTC")!

    func testShortFormByAge() {
        let table: [(age: TimeInterval, expected: String)] = [
            (-3_600, "now"), (-1, "now"), (0, "now"), (59, "now"), (59.9, "now"),
            (60, "1 m"), (119, "1 m"), (120, "2 m"), (59 * 60, "59 m"), (3_599, "59 m"), (3_599.9, "59 m"),
            (3_600, "1 h"), (7_199, "1 h"), (7_200, "2 h"), (23 * 3_600, "23 h"), (86_399, "23 h"),
            (86_400, "Oct 14"), (2 * 86_400, "Oct 13"), (30 * 86_400, "Sep 15"), (400 * 86_400, "Sep 10"),
        ]
        for row in table {
            let date = now.addingTimeInterval(-row.age)
            XCTAssertEqual(TrackerRelativeTime.short(date, now: now, timeZone: utc), row.expected,
                           "\(row.age) s ago")
        }
    }

    func testShortFormWithoutADateIsEmpty() {
        XCTAssertEqual(TrackerRelativeTime.short(nil, now: now, timeZone: utc), "")
    }

    func testDayFormIsSpelledInTheCallersTimeZone() throws {
        // 2025-10-15 00:30 UTC, two days before `later`.
        let date = Date(timeIntervalSince1970: 1_760_488_200)
        let later = date.addingTimeInterval(2 * 86_400)
        let table: [(zone: String, expected: String)] = [
            ("UTC", "Oct 15"),
            ("Pacific/Pago_Pago", "Oct 14"),     // UTC-11: still the 14th, 13:30
            ("Pacific/Kiritimati", "Oct 15"),    // UTC+14: 14:30 on the 15th
        ]
        for row in table {
            let zone = try XCTUnwrap(TimeZone(identifier: row.zone))
            XCTAssertEqual(TrackerRelativeTime.short(date, now: later, timeZone: zone), row.expected, row.zone)
        }
    }

    func testHeaderForm() {
        let table: [(age: TimeInterval, expected: String)] = [
            (-5, "updated just now"), (0, "updated just now"), (59, "updated just now"),
            (60, "updated 1 m ago"), (120, "updated 2 m ago"), (59 * 60, "updated 59 m ago"),
            (3_600, "updated 1 h ago"), (3 * 3_600, "updated 3 h ago"), (86_399, "updated 23 h ago"),
            (86_400, "updated Oct 14"), (3 * 86_400, "updated Oct 12"),
        ]
        for row in table {
            let date = now.addingTimeInterval(-row.age)
            XCTAssertEqual(TrackerRelativeTime.header(date, now: now, timeZone: utc), row.expected,
                           "\(row.age) s ago")
        }
    }

    func testHeaderFormWithoutADateIsEmpty() {
        XCTAssertEqual(TrackerRelativeTime.header(nil, now: now, timeZone: utc), "")
    }

    func testStatusMarks() {
        XCTAssertEqual(TrackerStatusMark.mark(for: .todo), "○")
        XCTAssertEqual(TrackerStatusMark.mark(for: .inProgress), "◐")
        XCTAssertEqual(TrackerStatusMark.mark(for: .blocked), "⊘")
        XCTAssertEqual(TrackerStatusMark.mark(for: .needsYou), "●")
        XCTAssertEqual(TrackerStatusMark.mark(for: .done), "✓")
    }
}

// MARK: - Copy as Markdown

final class TrackerMarkdownTests: XCTestCase {

    /// The file text from the first occurrence of `start` up to (not including) `end`.
    private func slice(_ file: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(file.range(of: start), "\(start) is in board-60.md").lowerBound
        let upper = try XCTUnwrap(file.range(of: end), "\(end) is in board-60.md").lowerBound
        return String(file[lower..<upper])
    }

    /// An item's task line plus the indented lines under it.
    private func itemLines(_ id: String, in file: String) throws -> String {
        let lines = file.components(separatedBy: "\n")
        let first = try XCTUnwrap(lines.firstIndex(where: { $0.contains("<!-- #\(id) ") }), id)
        var taken = [lines[first]]
        for line in lines[(first + 1)...] {
            guard line.hasPrefix("  ") else { break }
            taken.append(line)
        }
        return taken.joined(separator: "\n") + "\n"
    }

    func testWholeBoardIsTheFilesBytes() throws {
        let board = try TFx.golden()
        let file = try TFx.fixtureText("board-60.md")
        XCTAssertEqual(TrackerMarkdown.board(board), file)
        XCTAssertEqual(Array(TrackerMarkdown.board(board).utf8), Array(try TFx.fixtureData("board-60.md")))
    }

    func testSectionIsItsHeadingAndEverythingUnderItUpToTheNextSection() throws {
        let board = try TFx.golden()
        let file = try TFx.fixtureText("board-60.md")
        let table: [(id: String, start: String, end: String)] = [
            ("now", "## Now\n", "## Next\n"),
            ("next", "## Next\n", "## Waiting on you\n"),
            ("waiting-on-you", "## Waiting on you\n", "## Done\n"),
            ("done", "## Done\n", "## Findings\n"),
            ("findings", "## Findings\n", "## Loose ends\n"),
            ("loose-ends", "## Loose ends\n", "## Log\n"),
        ]
        for row in table {
            let expected = try slice(file, from: row.start, to: row.end)
            XCTAssertEqual(TrackerMarkdown.section(row.id, in: board), expected, row.id)
        }
    }

    func testSectionCopyIncludesItsProseButNotTheNextSection() throws {
        let board = try TFx.golden()
        let next = try XCTUnwrap(TrackerMarkdown.section("next", in: board))
        XCTAssertTrue(next.hasPrefix("## Next\n"))
        XCTAssertTrue(next.contains("Note to self: everything under Next is unprioritised."))
        XCTAssertFalse(next.contains("## Waiting on you"))
    }

    func testItemIsItsTaskLineNoteAndLinksLines() throws {
        let board = try TFx.golden()
        let file = try TFx.fixtureText("board-60.md")
        for id in ["check-1000", "verif-1037", "retry-1074", "verif-1481", "audit-2295", "docum-1740"] {
            XCTAssertEqual(TrackerMarkdown.item(id, in: board), try itemLines(id, in: file), id)
        }
        XCTAssertEqual(
            TrackerMarkdown.item("check-1000", in: board),
            "- [ ] Check referral 4411 duplicate — in progress · 14:53 <!-- #check-1000 1760540000 -->\n"
            + "  Seen on host 14, see the log for detail\n"
            + "  Links: [PR #253](https://github.com/example/repo/pull/253)\n")
    }

    func testEveryItemsCopyIsAPartOfTheFile() throws {
        let board = try TFx.golden()
        let file = try TFx.fixtureText("board-60.md")
        for item in TFx.wireItems(board) {
            let copy = try XCTUnwrap(TrackerMarkdown.item(item.id, in: board), item.id)
            XCTAssertTrue(file.contains(copy), item.id)
            XCTAssertTrue(copy.contains("#\(item.id) "), item.id)
        }
    }

    func testUnknownIdsCopyNothing() throws {
        let board = try TFx.golden()
        XCTAssertNil(TrackerMarkdown.section("no-such-section", in: board))
        XCTAssertNil(TrackerMarkdown.item("no-such-item", in: board))
        XCTAssertNil(TrackerMarkdown.section("check-1000", in: board), "an item id is not a section id")
        XCTAssertNil(TrackerMarkdown.item("now", in: board), "a section id is not an item id")
    }
}
