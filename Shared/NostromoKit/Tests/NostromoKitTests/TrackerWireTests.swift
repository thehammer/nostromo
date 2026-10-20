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
}
