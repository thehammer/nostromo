// NostromoKit — PaneContentWireTests.swift
//
// Wire JSON assertions for the PaneContentWire pr_list kind.
// Verifies:
//   - pr_list decodes all fields correctly (snake_case → camelCase).
//   - Optional pr_list item fields default to safe values when absent.
//   - Unknown future kinds do NOT throw (forward-compatibility contract).
//   - PrListItemModel.toRowModel() maps fields to the expected row model shape.
//   - Existing text and json_snapshot kinds still decode without regression.

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
}
