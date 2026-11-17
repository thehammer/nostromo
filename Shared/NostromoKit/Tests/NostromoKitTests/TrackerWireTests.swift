// NostromoKit — TrackerWireTests.swift
//
// The agent tracker's frames (T0b). The golden frames are the SAME files the Rust
// round-trip test (`tests/tracker_wire_golden.rs`) reproduces byte for byte, read
// through a path relative to this file, so the daemon and the Kit can't drift
// apart. The 60-item board they are built from is `tests/fixtures/tracker/board-60.md`.

import XCTest
@testable import NostromoKit

final class TrackerWireTests: XCTestCase {

    // MARK: - Fixtures

    /// `<repo>/tests/fixtures/tracker/<name>`: this file is five directories deep.
    private func fixture(_ name: String, file: StaticString = #filePath) throws -> Data {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/tracker/\(name)")
        return try Data(contentsOf: url)
    }

    private func board(from data: Data) throws -> TrackerBoardFrameWire {
        guard case .trackerBoard(let frame) = ServerMsg.decode(from: data) else {
            XCTFail("not a tracker_board frame")
            throw CocoaError(.coderReadCorrupt)
        }
        return frame
    }

    private func items(_ view: TrackerBoardViewWire) -> [TrackerItemWire] {
        view.nodes.compactMap { if case .item(let item) = $0 { return item } else { return nil } }
    }

    // MARK: - Golden frames

    func testGoldenBoardFrameDecodesTheWholeBoard() throws {
        let frame = try board(from: try fixture("frame-tracker-board.json"))
        let view = try XCTUnwrap(frame.board)
        XCTAssertFalse(frame.tag.isEmpty)
        XCTAssertFalse(view.title.isEmpty)
        XCTAssertFalse(view.path.isEmpty)
        XCTAssertEqual(items(view).count, 60, "board-60.md has 60 items")
        XCTAssertFalse(view.nodes.contains(.unknown), "every node kind in the golden is known")
        XCTAssertNil(view.banner)
        XCTAssertFalse(view.hiddenByUser)
        for item in items(view) {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.source.isEmpty, "\(item.id) carries its markdown source")
        }
    }

    func testJoiningEveryNodeSourceReproducesTheFile() throws {
        let view = try XCTUnwrap(try board(from: try fixture("frame-tracker-board.json")).board)
        let joined = view.nodes.map { node -> String in
            switch node {
            case .title(_, let source), .section(_, _, let source), .logHeading(_, let source),
                 .prose(_, _, let source), .logLine(_, _, let source):
                return source
            case .item(let item):
                return item.source
            case .unknown:
                return ""
            }
        }.joined()
        let file = String(decoding: try fixture("board-60.md"), as: UTF8.self)
        XCTAssertEqual(joined, file)
    }

    func testGoldenSummaryMatchesTheBoard() throws {
        let board = try XCTUnwrap(try board(from: try fixture("frame-tracker-board.json")).board)
        guard case .trackerSummary(let summary) = ServerMsg.decode(from: try fixture("frame-tracker-summary.json")) else {
            return XCTFail("not a tracker_summary frame")
        }
        XCTAssertTrue(summary.hasTracker)
        let counts = summary.counts
        let byStatus = Dictionary(grouping: items(board), by: \.status).mapValues(\.count)
        XCTAssertEqual(counts.todo, byStatus[.todo] ?? 0)
        XCTAssertEqual(counts.inProgress, byStatus[.inProgress] ?? 0)
        XCTAssertEqual(counts.blocked, byStatus[.blocked] ?? 0)
        XCTAssertEqual(counts.needsYou, byStatus[.needsYou] ?? 0)
        XCTAssertEqual(counts.done, byStatus[.done] ?? 0)
        XCTAssertEqual(counts.todo + counts.inProgress + counts.blocked + counts.needsYou + counts.done, 60)
    }

    // MARK: - Leniency

    func testUnknownNodeKindDecodesToUnknownNotAThrow() throws {
        let json = """
        {"type":"tracker_board","tag":"t","board":{"title":"B","path":"/p.md","version":3,"hidden_by_user":false,
         "log":[],"nodes":[
           {"type":"title","text":"B","source":"# B\\n"},
           {"type":"hologram","source":"???","extra":{"a":1}},
           {"type":"section","id":"now","title":"Now","source":"## Now\\n"}]}}
        """
        let view = try XCTUnwrap(try board(from: Data(json.utf8)).board)
        XCTAssertEqual(view.nodes.count, 3)
        XCTAssertEqual(view.nodes[1], .unknown)
        XCTAssertEqual(view.nodes[2], .section(id: "now", title: "Now", source: "## Now\n"))
    }

    func testUnknownStatusKindEnvAndLinkKindDecodeToUnknown() throws {
        let json = """
        {"type":"tracker_board","tag":"t","board":{"title":"B","path":"/p.md","version":1,"hidden_by_user":false,"log":[],
         "nodes":[{"type":"item","id":"a","section":"now","text_spans":[],"status":"parked","note_blocks":[],
                   "links":[{"text":"x","kind":"carrier-pigeon"}],"kind":"teleport","env":"mars","ran":false,"source":"- [ ] a\\n"}]}}
        """
        let view = try XCTUnwrap(try board(from: Data(json.utf8)).board)
        let item = try XCTUnwrap(items(view).first)
        XCTAssertEqual(item.status, .unknown("parked"))
        XCTAssertEqual(item.kind, .unknown("teleport"))
        XCTAssertEqual(item.env, .unknown("mars"))
        XCTAssertEqual(item.links.first?.kind, .unknown("carrier-pigeon"))
    }

    func testBoardNullMeansNoTrackerAndBannersDecode() throws {
        let none = #"{"type":"tracker_board","tag":"t","board":null}"#
        XCTAssertNil(try board(from: Data(none.utf8)).board)

        let unreadable = """
        {"type":"tracker_board","tag":"t","board":{"title":"B","path":"/p.md","version":1,"hidden_by_user":true,"log":[],"nodes":[],
         "banner":{"type":"unreadable","line":12,"reason":"duplicate_id"},"committable":{"remote":"github.com/o/r"}}}
        """
        let view = try XCTUnwrap(try board(from: Data(unreadable.utf8)).board)
        XCTAssertEqual(view.banner, .unreadable(line: 12, reason: "duplicate_id", lastGoodAt: nil))
        XCTAssertEqual(view.committable?.remote, "github.com/o/r")
        XCTAssertTrue(view.hiddenByUser)

        let missing = """
        {"type":"tracker_board","tag":"t","board":{"title":"B","path":"/p.md","version":1,"hidden_by_user":false,"log":[],"nodes":[],
         "banner":{"type":"missing"}}}
        """
        XCTAssertEqual(try XCTUnwrap(try board(from: Data(missing.utf8)).board).banner, .missing(lastSeen: nil))
    }

    // MARK: - Two-way (T3a)

    func testGoldenBoardFrameCarriesEachItemsRawTextAndNote() throws {
        let view = try XCTUnwrap(try board(from: try fixture("frame-tracker-board.json")).board)
        for item in items(view) {
            XCTAssertFalse(item.text.isEmpty, "\(item.id) carries its raw text")
            XCTAssertTrue(item.conflicts.isEmpty)
            XCTAssertNil(item.sensitive)
        }
        XCTAssertTrue(items(view).contains { $0.note != nil }, "an item with a note carries it raw")
        XCTAssertTrue(view.removedConflicts.isEmpty)
    }

    func testConflictsGoldenDecodesConflictsSensitiveAndRemovedConflicts() throws {
        let view = try XCTUnwrap(try board(from: try fixture("frame-tracker-board-conflicts.json")).board)
        let byId = Dictionary(uniqueKeysWithValues: items(view).map { ($0.id, $0) })
        let conflict = try XCTUnwrap(byId["check-1000"]?.conflicts.first)
        XCTAssertEqual(conflict.field, "status")
        XCTAssertEqual(conflict.losing, "in-progress")
        XCTAssertEqual(conflict.losingBy, "agent claudia")
        XCTAssertEqual(conflict.winningBy, "pane (you)")
        XCTAssertEqual(conflict.index, 0)
        XCTAssertNotNil(conflict.at)
        XCTAssertEqual(byId["verif-1037"]?.sensitive?.classes, ["ssn"])
        let removed = try XCTUnwrap(view.removedConflicts.first)
        XCTAssertEqual(removed.itemId, "gone-1")
        XCTAssertEqual(removed.title, "A removed task")
        XCTAssertTrue(removed.source.hasPrefix("- [ ] A removed task"))
        XCTAssertEqual(items(view).count, 60, "the rest of the board is the golden board")
    }

    func testABoardFromAnOlderDaemonWithoutTheNewFieldsStillDecodes() throws {
        let json = """
        {"type":"tracker_board","tag":"t","board":{"title":"B","path":"/p.md","version":3,"hidden_by_user":false,"log":[],
         "nodes":[{"type":"item","id":"a","section":"now","text_spans":[],"status":"todo","note_blocks":[],
                   "links":[],"kind":"item","ran":false,"source":"- [ ] a\\n"}]}}
        """
        let view = try XCTUnwrap(try board(from: Data(json.utf8)).board)
        let item = try XCTUnwrap(items(view).first)
        XCTAssertEqual(item.text, "")
        XCTAssertNil(item.note)
        XCTAssertTrue(item.conflicts.isEmpty)
        XCTAssertNil(item.sensitive)
        XCTAssertTrue(view.removedConflicts.isEmpty)
    }

    func testTheTrackerEditRequestEncodesToTheFixedJSON() throws {
        let request = TrackerEditRequestWire(
            tag: "t", requestId: "r1", baseVersion: 7, operatorNonce: "n",
            ops: [
                .status(id: "a", status: "done"),
                .edit(id: "a", title: "T", text: nil, body: ""),
                .add(section: "now", title: "x", body: nil, before: "a", after: nil),
                .restore(source: "- [ ] x\n", section: "now", before: nil, after: "a"),
                .clearBadge(id: "a"),
                .resolveConflict(id: "a", field: "status", keep: .losing, index: 1),
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(request), as: UTF8.self)
        XCTAssertEqual(json, """
        {"base_version":7,"operator_nonce":"n","ops":[\
        {"id":"a","op":"status","status":"done"},\
        {"body":"","id":"a","op":"edit","title":"T"},\
        {"before":"a","op":"add","section":"now","title":"x"},\
        {"after":"a","op":"restore","section":"now","source":"- [ ] x\\n"},\
        {"id":"a","op":"clear_badge"},\
        {"field":"status","id":"a","index":1,"keep":"losing","op":"resolve_conflict"}],\
        "request_id":"r1","tag":"t","type":"tracker_edit"}
        """)
    }

    func testAPaneOpRoundTripsAndAnUnknownOpIsRefused() throws {
        let ops: [TrackerPaneOpWire] = [
            .status(id: "a", status: "todo"), .edit(id: "a", title: nil, text: "t", body: nil),
            .move(id: "a", section: "next", before: nil, after: "b"), .remove(id: "a"),
            .resolveConflict(id: "a", field: "removed", keep: .current, index: nil),
        ]
        let data = try JSONEncoder().encode(ops)
        XCTAssertEqual(try JSONDecoder().decode([TrackerPaneOpWire].self, from: data), ops)
        XCTAssertThrowsError(try JSONDecoder().decode(TrackerPaneOpWire.self, from: Data(#"{"op":"teleport"}"#.utf8)))
    }

    func testTheEditResultDecodesOkAndErrorAndTheFeatureNameIsFixed() throws {
        XCTAssertEqual(trackerEditFeature, "tracker_edit_v1")
        let ok = #"{"type":"tracker_edit_result","tag":"t","request_id":"r1","ok":true,"version":9,"created":["x-1","x-2"]}"#
        guard case .trackerEditResult(let result) = ServerMsg.decode(from: Data(ok.utf8)) else {
            return XCTFail("not a tracker_edit_result frame")
        }
        XCTAssertEqual(result.requestId, "r1")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.version, 9)
        XCTAssertEqual(result.created, ["x-1", "x-2"])
        XCTAssertNil(result.error)

        let refused = #"{"type":"tracker_edit_result","tag":"t","request_id":"r2","ok":false,"error":{"code":"invalid_args","reason":"title is empty","index":2},"version":0}"#
        guard case .trackerEditResult(let bad) = ServerMsg.decode(from: Data(refused.utf8)) else {
            return XCTFail("not a tracker_edit_result frame")
        }
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, TrackerEditErrorWire(code: "invalid_args", reason: "title is empty", index: 2))
        XCTAssertTrue(bad.created.isEmpty)
    }
}
