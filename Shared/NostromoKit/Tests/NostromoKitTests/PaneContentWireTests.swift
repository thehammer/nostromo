// NostromoKit — PaneContentWireTests.swift
//
// Wire JSON assertions for the PaneContentWire pr_list kind.
// Verifies:
//   - pr_list decodes all fields correctly (snake_case → camelCase).
//   - Optional pr_list item fields default to safe values when absent.
//   - Unknown future kinds do NOT throw (forward-compatibility contract).
//   - PrListItemModel.toRowModel() maps fields to the expected row model shape.
//   - Existing text and json_snapshot kinds still decode without regression.
//   - PrListItemModel/PaneContentWire Equatable conformance, including the
//     deliberately-conservative "always changed" rule for .jsonSnapshot/.unknown.
//   - PaneFreshness decodes as_of/stale/badly_stale, and the pane_content
//     ServerMsg decodes whether or not a "freshness" key is present on the wire.

import XCTest
@testable import NostromoKit

final class PaneContentWireTests: XCTestCase {

    private let decoder = JSONDecoder()

    private func decode(_ jsonString: String) throws -> PaneContentWire {
        let data = Data(jsonString.utf8)
        return try decoder.decode(PaneContentWire.self, from: data)
    }

    // MARK: - pr_list decodes correctly

    func testPrListDecodesCorrectly() throws {
        let json = """
        {
            "kind": "pr_list",
            "items": [
                {
                    "repo": "acme/web",
                    "number": 42,
                    "title": "feat: auth",
                    "author": "alice",
                    "bucket": "requested",
                    "ci_state": "success",
                    "new_activity": true,
                    "url": "https://github.com/acme/web/pull/42",
                    "head_sha": "abc123"
                }
            ]
        }
        """

        let wire = try decode(json)

        guard case .prList(let items) = wire else {
            XCTFail("Expected .prList, got \(wire)")
            return
        }

        XCTAssertEqual(items.count, 1)

        let item = items[0]
        XCTAssertEqual(item.repo,        "acme/web")
        XCTAssertEqual(item.number,      42)
        XCTAssertEqual(item.title,       "feat: auth")
        XCTAssertEqual(item.author,      "alice")
        XCTAssertEqual(item.bucket,      "requested")
        XCTAssertEqual(item.ciState,     .success)
        XCTAssertTrue(item.newActivity)
        XCTAssertEqual(item.url,         "https://github.com/acme/web/pull/42")
        XCTAssertEqual(item.headSha,     "abc123")
    }

    // MARK: - Optional fields default correctly when absent

    func testPrListItemOptionalFieldsDefaultCorrectly() throws {
        let json = """
        {
            "kind": "pr_list",
            "items": [
                {
                    "repo": "acme/web",
                    "number": 1,
                    "title": "fix: bug",
                    "author": "bob",
                    "bucket": "needs_review",
                    "ci_state": "unknown"
                }
            ]
        }
        """

        let wire = try decode(json)

        guard case .prList(let items) = wire else {
            XCTFail("Expected .prList, got \(wire)")
            return
        }

        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertFalse(item.newActivity, "new_activity should default to false when absent")
        XCTAssertEqual(item.url,     "", "url should default to empty string when absent")
        XCTAssertEqual(item.headSha, "", "head_sha should default to empty string when absent")
    }

    // MARK: - Unknown future kinds do not throw

    func testUnknownKindDecodesWithoutThrowing() throws {
        let json = """
        {
            "kind": "future_type_not_yet_known",
            "some_field": "some_value"
        }
        """

        var wire: PaneContentWire?
        XCTAssertNoThrow(
            wire = try decode(json),
            "PaneContentWire should silently accept unknown kind values for forward compatibility"
        )

        if let wire {
            guard case .unknown = wire else {
                XCTFail("Expected .unknown for unrecognised kind, got \(wire)")
                return
            }
        }
    }

    // MARK: - PrListItemModel.toRowModel()

    func testToRowModelMapsFieldsCorrectly() {
        let model = PrListItemModel(
            repo:        "acme/web",
            number:      42,
            title:       "feat: auth",
            author:      "alice",
            bucket:      "requested",
            ciState:     .success,
            newActivity: true,
            url:         "https://github.com/acme/web/pull/42",
            headSha:     "abc123"
        )

        let rowModel = model.toRowModel()

        XCTAssertEqual(rowModel.id,          "acme/web#42")
        XCTAssertEqual(rowModel.number,      42)
        XCTAssertEqual(rowModel.title,       "feat: auth")
        XCTAssertEqual(rowModel.repo,        "acme/web")
        XCTAssertEqual(rowModel.author,      "alice")
        XCTAssertEqual(rowModel.bucket,      "requested")
        XCTAssertEqual(rowModel.ciState,     .success)
        XCTAssertTrue(rowModel.newActivity)
    }

    // MARK: - Existing kinds still decode (regression)

    func testTextKindStillDecodes() throws {
        let json = """
        {"kind": "text", "text": "hello"}
        """

        let wire = try decode(json)

        guard case .text(let value) = wire else {
            XCTFail("Expected .text, got \(wire)")
            return
        }
        XCTAssertEqual(value, "hello")
    }

    func testJsonSnapshotKindStillDecodes() throws {
        let json = """
        {"kind": "json_snapshot", "value": {"x": 1}}
        """

        var wire: PaneContentWire?
        XCTAssertNoThrow(wire = try decode(json))

        if let wire {
            guard case .jsonSnapshot = wire else {
                XCTFail("Expected .jsonSnapshot, got \(wire)")
                return
            }
        }
    }

    // MARK: - PrListItemModel.Equatable

    private func makeItem(
        repo:        String  = "acme/web",
        number:      Int     = 42,
        title:       String  = "feat: auth",
        author:      String  = "alice",
        bucket:      String  = "requested",
        ciState:     CiState = .success,
        newActivity: Bool    = true,
        url:         String  = "https://github.com/acme/web/pull/42",
        headSha:     String  = "abc123"
    ) -> PrListItemModel {
        PrListItemModel(
            repo: repo, number: number, title: title, author: author,
            bucket: bucket, ciState: ciState, newActivity: newActivity,
            url: url, headSha: headSha
        )
    }

    func testPrListItemModelsWithIdenticalFieldsAreEqual() {
        XCTAssertEqual(makeItem(), makeItem())
    }

    func testPrListItemModelsDifferingByRepoAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(repo: "acme/other"))
    }

    func testPrListItemModelsDifferingByNumberAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(number: 43))
    }

    func testPrListItemModelsDifferingByTitleAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(title: "fix: bug"))
    }

    func testPrListItemModelsDifferingByAuthorAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(author: "bob"))
    }

    func testPrListItemModelsDifferingByBucketAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(bucket: "needs_review"))
    }

    func testPrListItemModelsDifferingByCiStateAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(ciState: .failure))
    }

    func testPrListItemModelsDifferingByNewActivityAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(newActivity: false))
    }

    func testPrListItemModelsDifferingByUrlAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(url: "https://github.com/acme/web/pull/99"))
    }

    func testPrListItemModelsDifferingByHeadShaAreNotEqual() {
        XCTAssertNotEqual(makeItem(), makeItem(headSha: "def456"))
    }

    // MARK: - PaneContentWire.Equatable — .text / .loading / .error

    func testTextCasesWithSameStringAreEqual() {
        XCTAssertEqual(PaneContentWire.text("hello"), PaneContentWire.text("hello"))
    }

    func testTextCasesWithDifferentStringsAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.text("goodbye"))
    }

    func testLoadingCasesAreAlwaysEqual() {
        XCTAssertEqual(PaneContentWire.loading, PaneContentWire.loading)
    }

    func testErrorCasesWithSameMessageAreEqual() {
        XCTAssertEqual(PaneContentWire.error("boom"), PaneContentWire.error("boom"))
    }

    func testErrorCasesWithDifferentMessagesAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.error("kaboom"))
    }

    // MARK: - PaneContentWire.Equatable — .prList

    func testPrListCasesWithIdenticalItemArraysAreEqual() {
        let lhs = PaneContentWire.prList([makeItem()])
        let rhs = PaneContentWire.prList([makeItem()])
        XCTAssertEqual(lhs, rhs)
    }

    func testPrListCasesWithADifferingItemAreNotEqual() {
        let lhs = PaneContentWire.prList([makeItem()])
        let rhs = PaneContentWire.prList([makeItem(title: "fix: something else")])
        XCTAssertNotEqual(lhs, rhs)
    }

    func testPrListCasesWithDifferentCountsAreNotEqual() {
        let lhs = PaneContentWire.prList([makeItem()])
        let rhs = PaneContentWire.prList([makeItem(), makeItem(number: 43)])
        XCTAssertNotEqual(lhs, rhs)
    }

    // MARK: - PaneContentWire.Equatable — .jsonSnapshot / .unknown (conservative "always changed")

    func testJsonSnapshotCasesWithIdenticalPayloadsAreNeverEqual() throws {
        let json = """
        {"kind": "json_snapshot", "value": {"x": 1}}
        """
        let lhs = try decode(json)
        let rhs = try decode(json)
        XCTAssertNotEqual(
            lhs, rhs,
            ".jsonSnapshot must compare unequal to any other value, even with an identical payload — " +
            "this is a deliberate conservative choice (report 'changed' rather than risk a false 'unchanged')"
        )
    }

    func testUnknownCasesWithIdenticalPayloadsAreNeverEqual() throws {
        let json = """
        {"kind": "future_type_not_yet_known", "some_field": "some_value"}
        """
        let lhs = try decode(json)
        let rhs = try decode(json)
        XCTAssertNotEqual(
            lhs, rhs,
            ".unknown must compare unequal to any other value, even with an identical payload — " +
            "this is a deliberate conservative choice (report 'changed' rather than risk a false 'unchanged')"
        )
    }

    // MARK: - PaneContentWire.Equatable — cross-case

    func testDifferentCasesAreNeverEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.loading)
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.text("boom"))
        XCTAssertNotEqual(PaneContentWire.prList([makeItem()]), PaneContentWire.loading)
    }

    // MARK: - PaneFreshness decoding

    func testPaneFreshnessDecodesAsOfAsDateAndSurvivesBoolLiterals() throws {
        let json = """
        {
            "as_of": "2026-05-30T09:30:56.510874Z",
            "stale": true,
            "badly_stale": false
        }
        """.data(using: .utf8)!

        let freshness = try JSONDecoder.nostromo.decode(PaneFreshness.self, from: json)

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(fmt.date(from: "2026-05-30T09:30:56.510874Z"))

        XCTAssertEqual(freshness.asOf, expected)
        XCTAssertTrue(freshness.stale)
        XCTAssertFalse(freshness.badlyStale)
    }

    func testPaneFreshnessDecodesWithoutAsOfKey() throws {
        let json = """
        {
            "stale": false,
            "badly_stale": true
        }
        """.data(using: .utf8)!

        let freshness = try JSONDecoder.nostromo.decode(PaneFreshness.self, from: json)
        XCTAssertNil(freshness.asOf)
        XCTAssertFalse(freshness.stale)
        XCTAssertTrue(freshness.badlyStale)
    }

    // MARK: - ServerMsg pane_content decoding of freshness

    func testServerMsgPaneContentDecodesFreshnessWhenPresent() throws {
        let json = """
        {
            "type": "pane_content",
            "tag": "focus1",
            "pane_id": "pane1",
            "content": {"kind": "text", "text": "hello"},
            "freshness": {
                "as_of": "2026-05-30T09:30:56.510874Z",
                "stale": false,
                "badly_stale": false
            }
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .paneContent(_, _, _, let freshness, _) = msg else {
            XCTFail("Expected .paneContent, got \(msg)")
            return
        }

        let f = try XCTUnwrap(freshness, "freshness should decode when the key is present on the wire")

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(fmt.date(from: "2026-05-30T09:30:56.510874Z"))

        XCTAssertEqual(f.asOf, expected)
        XCTAssertFalse(f.stale)
        XCTAssertFalse(f.badlyStale)
    }

    func testServerMsgPaneContentDecodesSuccessfullyWithoutFreshnessKey() throws {
        // Old-daemon compatibility: a pane_content frame with no "freshness"
        // key at all must still decode successfully, with freshness == nil.
        let json = """
        {
            "type": "pane_content",
            "tag": "focus1",
            "pane_id": "pane1",
            "content": {"kind": "text", "text": "hello"}
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .paneContent(let tag, let paneId, let content, let freshness, let address) = msg else {
            XCTFail("Expected .paneContent, got \(msg)")
            return
        }

        XCTAssertEqual(tag, "focus1")
        XCTAssertEqual(paneId, "pane1")
        guard case .text(let value) = content else {
            XCTFail("Expected .text content, got \(content)")
            return
        }
        XCTAssertEqual(value, "hello")
        XCTAssertNil(freshness, "freshness must be nil when the key is absent, not a decode failure")
        XCTAssertNil(address, "address must be nil when the key is absent, not a decode failure")
    }

    // MARK: - PaneAddress / Anchor / Emphasis decoding (W1 — curated-agent-views)

    func testServerMsgPaneContentDecodesAddressWhenPresent() throws {
        let json = """
        {
            "type": "pane_content",
            "tag": "ticket",
            "pane_id": "ticket",
            "content": {"kind": "text", "text": "CORE-1234"},
            "address": {
                "anchor": {"kind": "line", "path": "src/main.rs", "line": 42},
                "emphasis": [{"kind": "text_range", "start": 0, "end": 4}],
                "reason": "opened from the queue"
            }
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .paneContent(_, _, _, _, let address) = msg else {
            XCTFail("Expected .paneContent, got \(msg)")
            return
        }
        let a = try XCTUnwrap(address)
        XCTAssertEqual(a.anchor, .line(path: "src/main.rs", line: 42))
        XCTAssertEqual(a.emphasis, [.textRange(start: 0, end: 4)])
        XCTAssertEqual(a.reason, "opened from the queue")
    }

    func testServerMsgPaneContentDecodesSuccessfullyWithoutAddressKey() throws {
        let json = """
        {
            "type": "pane_content",
            "tag": "focus1",
            "pane_id": "pane1",
            "content": {"kind": "text", "text": "hello"}
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .paneContent(_, _, _, _, let address) = msg else {
            XCTFail("Expected .paneContent, got \(msg)")
            return
        }
        XCTAssertNil(address, "address must be nil when the key is absent, not a decode failure")
    }

    func testEveryAnchorVariantDecodes() throws {
        func decodeAnchor(_ json: String) throws -> Anchor {
            try JSONDecoder().decode(Anchor.self, from: Data(json.utf8))
        }
        XCTAssertEqual(
            try decodeAnchor(#"{"kind": "line", "line": 7}"#),
            .line(path: nil, line: 7)
        )
        XCTAssertEqual(
            try decodeAnchor(#"{"kind": "comment", "id": "c-1"}"#),
            .comment(id: "c-1")
        )
        XCTAssertEqual(
            try decodeAnchor(#"{"kind": "section", "name": "Overview"}"#),
            .section(name: "Overview")
        )
        XCTAssertEqual(
            try decodeAnchor(#"{"kind": "queue_row", "repo": "acme/web", "number": 42}"#),
            .queueRow(repo: "acme/web", number: 42)
        )
    }

    func testEveryEmphasisVariantDecodes() throws {
        func decodeEmphasis(_ json: String) throws -> Emphasis {
            try JSONDecoder().decode(Emphasis.self, from: Data(json.utf8))
        }
        XCTAssertEqual(
            try decodeEmphasis(#"{"kind": "line_range", "start": 1, "end": 2}"#),
            .lineRange(path: nil, start: 1, end: 2)
        )
        XCTAssertEqual(
            try decodeEmphasis(#"{"kind": "comment", "id": "c-2"}"#),
            .comment(id: "c-2")
        )
        XCTAssertEqual(
            try decodeEmphasis(#"{"kind": "section", "name": "Risks"}"#),
            .section(name: "Risks")
        )
        XCTAssertEqual(
            try decodeEmphasis(#"{"kind": "text_range", "start": 0, "end": 12}"#),
            .textRange(start: 0, end: 12)
        )
        XCTAssertEqual(
            try decodeEmphasis(#"{"kind": "queue_row", "repo": "acme/web", "number": 7}"#),
            .queueRow(repo: "acme/web", number: 7)
        )
    }

    func testPaneAddressWithNoKeysDecodesToAllDefaults() throws {
        let addr = try JSONDecoder().decode(PaneAddress.self, from: Data("{}".utf8))
        XCTAssertNil(addr.anchor)
        XCTAssertEqual(addr.emphasis, [])
        XCTAssertNil(addr.reason)
    }
}
