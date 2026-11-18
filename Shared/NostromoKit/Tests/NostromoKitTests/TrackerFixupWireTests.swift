import XCTest
@testable import NostromoKit

// T3b fix-ups, Kit half: the pane's `restore_text` op is the daemon's (shared fixture with the Rust test),
// the daemon's `stale` marker and `epoch` decode tolerantly, titles are counted the way the daemon counts
// them (Unicode scalars), and the conflict mark reads who set what.
//
// What the tests are meant to catch:
//  - Encode `restoreText` as `edit` with `text` (cut at 500 by the daemon): the fixture round trip fails.
//  - Count characters (graphemes) for the title limit: the combining-accent cases fail.
//  - Drop `epoch` or `stale` from the decoder: the decode cases fail.
final class TrackerFixupWireTests: XCTestCase {

    private func fixtureData() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/tracker/pane-ops.json")
        return try Data(contentsOf: url)
    }

    func testThePaneOpsFixtureDecodesAndEncodesBackToTheSameJSON() throws {
        let data = try fixtureData()
        let ops = try JSONDecoder().decode([TrackerPaneOpWire].self, from: data)
        XCTAssertTrue(ops.contains { if case .restoreText = $0 { return true } else { return false } })
        // The structure ops share the fixture with the daemon's test: add, move (each kind of place), remove, restore.
        XCTAssertTrue(ops.contains { if case .add = $0 { return true } else { return false } })
        XCTAssertTrue(ops.contains { if case .move(_, _, let before, _) = $0 { return before != nil } else { return false } })
        XCTAssertTrue(ops.contains { if case .move(_, _, _, let after) = $0 { return after != nil } else { return false } })
        XCTAssertTrue(ops.contains { if case .move(_, _, nil, nil) = $0 { return true } else { return false } })
        XCTAssertTrue(ops.contains { if case .remove = $0 { return true } else { return false } })
        XCTAssertTrue(ops.contains { if case .restore = $0 { return true } else { return false } })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let again = try JSONSerialization.jsonObject(with: try encoder.encode(ops)) as? NSArray
        let wire = try JSONSerialization.jsonObject(with: data) as? NSArray
        XCTAssertEqual(again, wire)
    }

    func testRestoreTextCarriesTheWholeTextWithoutACut() throws {
        let long = String(repeating: "x", count: 628)
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(TrackerPaneOpWire.restoreText(id: "a-1", text: long))) as? [String: Any]
        XCTAssertEqual(json?["op"] as? String, "restore_text")
        XCTAssertEqual((json?["text"] as? String)?.count, 628)
    }

    func testTheDaemonsStaleMarkerAndEpochDecodeAndTheirAbsenceIsFine() throws {
        let stale = try JSONDecoder().decode(TrackerEditErrorWire.self,
                                             from: Data(#"{"code":"invalid_args","reason":"x","stale":true}"#.utf8))
        XCTAssertTrue(stale.stale)
        let plain = try JSONDecoder().decode(TrackerEditErrorWire.self, from: Data(#"{"code":"invalid_args"}"#.utf8))
        XCTAssertFalse(plain.stale)
        let request = TrackerEditRequestWire(tag: "t", requestId: "r", baseVersion: 3, operatorNonce: nil, ops: [])
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        XCTAssertNil(object?["base_epoch"], "no epoch is sent unless the board had one")
        let withEpoch = TrackerEditRequestWire(tag: "t", requestId: "r", baseVersion: 3, baseEpoch: "e1", operatorNonce: nil, ops: [])
        let sent = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(withEpoch)) as? [String: Any]
        XCTAssertEqual(sent?["base_epoch"] as? String, "e1")
    }

    func testATitleIsCountedInScalarsLikeTheDaemon() {
        let decomposed = String(repeating: "e\u{301}", count: 80)   // 80 characters, 160 scalars
        XCTAssertEqual(decomposed.count, 80)
        XCTAssertFalse(TrackerTitle.fitsTitle(decomposed))
        XCTAssertTrue(TrackerTitle.fitsTitle(String(repeating: "é", count: 80)))
        let fitted = TrackerTitle.fitScalars(decomposed)
        XCTAssertLessThanOrEqual(fitted.title.unicodeScalars.count, TrackerTitle.maxChars)
        XCTAssertNotNil(fitted.overflow)
        XCTAssertEqual((fitted.title + (fitted.overflow ?? "")).unicodeScalars.count, 160, "nothing lost, never cut inside a character")
    }

    func testARestructuredTitleAlwaysFitsInScalars() {
        let typed = String(repeating: "e\u{301}", count: 80)
        let result = TrackerTitle.restructure(text: "Old", note: nil, newTitle: typed)
        XCTAssertLessThanOrEqual(result.title.unicodeScalars.count, TrackerTitle.maxChars)
        XCTAssertFalse(result.body.isEmpty)
    }
}
