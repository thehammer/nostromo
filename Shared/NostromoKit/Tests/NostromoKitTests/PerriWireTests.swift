// NostromoKit — PerriWireTests.swift
//
// Wire JSON assertions for Perri types.
// Verifies:
//   - ClientPerriAction encoding matches the Rust daemon protocol.
//   - ServerMsg.perriState decoding with populated and nil current.
//   - CiState unknown-string fallback.
//   - Field name snake_case → camelCase mapping.

import XCTest
@testable import NostromoKit

final class PerriWireTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - ClientPerriAction encoding

    func testPerriActionLoadPrEncoding() throws {
        let msg = ClientPerriAction(action: "load_pr", prNumber: 42, repo: "acme/web")
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"]      as? String, "perri_action")
        XCTAssertEqual(dict["action"]    as? String, "load_pr")
        XCTAssertEqual(dict["pr_number"] as? Int,    42)
        XCTAssertEqual(dict["repo"]      as? String, "acme/web")
    }

    func testPerriActionClearEncoding() throws {
        let msg  = ClientPerriAction(action: "clear", prNumber: nil, repo: nil)
        let dict = try encode(msg)
        // Wire must carry type and action.
        XCTAssertEqual(dict["type"]   as? String, "perri_action")
        XCTAssertEqual(dict["action"] as? String, "clear")
        // Swift's synthesised Encodable uses encodeIfPresent for optionals, so
        // nil values are omitted from the JSON — which is fine because Rust's serde
        // deserialises a missing Option<T> key the same as null (both become None).
        XCTAssertNil(dict["pr_number"] as? Int)
        XCTAssertNil(dict["repo"]      as? String)
    }

    func testPerriActionLoadPrHasExactlyFourKeys() throws {
        let msg = ClientPerriAction(action: "load_pr", prNumber: 1, repo: "org/repo")
        let dict = try encode(msg)
        XCTAssertEqual(dict.keys.count, 4, "Expected type, action, pr_number, repo")
    }

    // MARK: - ServerMsg.perriState decoding — populated queue + current

    func testPerriStateDecodesPopulatedQueue() throws {
        let json = """
        {
            "type": "perri_state",
            "queue": [
                {
                    "repo": "acme/web",
                    "number": 42,
                    "title": "feat: add auth",
                    "author": "alice",
                    "bucket": "requested",
                    "new_activity": true,
                    "url": "https://github.com/acme/web/pull/42",
                    "ci_state": "success",
                    "head_sha": "abc123"
                }
            ],
            "current": {
                "pr_number": 42,
                "repo": "acme/web",
                "title": "feat: add auth",
                "author": "alice",
                "url": "https://github.com/acme/web/pull/42",
                "diff": "--- a\\n+++ b",
                "stale": false,
                "ci_checks": [
                    {"name": "test", "state": "success"}
                ],
                "additions": 10,
                "deletions": 5,
                "changed_files": 2,
                "head_sha": "abc123",
                "diff_too_large": false
            }
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .perriState(let queue, let current) = msg else {
            XCTFail("Expected .perriState, got \(msg)")
            return
        }

        // Queue item assertions
        XCTAssertEqual(queue.count, 1)
        let item = queue[0]
        XCTAssertEqual(item.repo,        "acme/web")
        XCTAssertEqual(item.number,      42)
        XCTAssertEqual(item.title,       "feat: add auth")
        XCTAssertEqual(item.author,      "alice")
        XCTAssertEqual(item.bucket,      "requested")
        XCTAssertTrue(item.newActivity)
        XCTAssertEqual(item.ciState,     .success)
        XCTAssertEqual(item.headSha,     "abc123")

        // Current PR assertions
        let pr = try XCTUnwrap(current)
        XCTAssertEqual(pr.prNumber,     42)
        XCTAssertEqual(pr.repo,         "acme/web")
        XCTAssertEqual(pr.title,        "feat: add auth")
        XCTAssertEqual(pr.author,       "alice")
        XCTAssertEqual(pr.additions,    10)
        XCTAssertEqual(pr.deletions,    5)
        XCTAssertEqual(pr.changedFiles, 2)
        XCTAssertEqual(pr.headSha,      "abc123")
        XCTAssertFalse(pr.diffTooLarge)

        // CI check inside current
        XCTAssertEqual(pr.ciChecks.count, 1)
        XCTAssertEqual(pr.ciChecks[0].name,  "test")
        XCTAssertEqual(pr.ciChecks[0].state, .success)
    }

    // MARK: - ServerMsg.perriState decoding — null current

    func testPerriStateWithNullCurrentDecodesAsNil() throws {
        let json = """
        {
            "type": "perri_state",
            "queue": [],
            "current": null
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .perriState(let queue, let current) = msg else {
            XCTFail("Expected .perriState, got \(msg)")
            return
        }
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(current)
    }

    // MARK: - CiState unknown-string fallback

    func testCiStateDecodesUnknownStringAsUnknown() throws {
        let json = """
        {
            "repo": "r",
            "number": 1,
            "title": "t",
            "author": "a",
            "bucket": "requested",
            "new_activity": false,
            "url": "https://example.com",
            "ci_state": "totally_new_state_unknown_to_client"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(PrQueueItem.self, from: json)
        XCTAssertEqual(item.ciState, .unknown, "Unknown ci_state strings should decode to .unknown")
    }

    func testCiStateDecodesAllKnownVariants() throws {
        let cases: [(String, CiState)] = [
            ("unknown", .unknown),
            ("pending", .pending),
            ("success", .success),
            ("failure", .failure),
        ]
        for (raw, expected) in cases {
            let data = "\"\(raw)\"".data(using: .utf8)!
            let decoded = try JSONDecoder().decode(CiState.self, from: data)
            XCTAssertEqual(decoded, expected, "CiState \(raw) should decode to .\(expected)")
        }
    }

    // MARK: - is_bot field + dependabot bucket

    func testIsBotDecodesFromPayload() throws {
        let json = """
        {
            "repo": "Carefeed/admin-portal",
            "number": 100,
            "title": "chore: bump serde",
            "author": "dependabot[bot]",
            "bucket": "dependabot",
            "new_activity": false,
            "url": "https://github.com/Carefeed/admin-portal/pull/100",
            "ci_state": "success",
            "head_sha": "bot-sha",
            "is_bot": true
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(PrQueueItem.self, from: json)
        XCTAssertTrue(item.isBot,              "is_bot:true should decode to isBot == true")
        XCTAssertEqual(item.bucket, "dependabot")
        XCTAssertEqual(item.author, "dependabot[bot]")
    }

    func testIsBotDefaultsFalseWhenAbsent() throws {
        let json = """
        {
            "repo": "acme/web",
            "number": 1,
            "title": "t",
            "author": "alice",
            "bucket": "requested",
            "new_activity": false,
            "url": "https://example.com"
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(PrQueueItem.self, from: json)
        XCTAssertFalse(item.isBot, "is_bot should default to false when absent from payload")
    }

    func testPerriStateDependabotBucketRoundtrips() throws {
        // A perri_state message with a dependabot bucket item should decode cleanly.
        let json = """
        {
            "type": "perri_state",
            "queue": [
                {
                    "repo": "Carefeed/admin-portal",
                    "number": 99,
                    "title": "chore: bump tokio",
                    "author": "dependabot[bot]",
                    "bucket": "dependabot",
                    "new_activity": false,
                    "url": "https://github.com/Carefeed/admin-portal/pull/99",
                    "ci_state": "success",
                    "head_sha": "dep-sha",
                    "is_bot": true
                }
            ],
            "current": null
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .perriState(let queue, let current) = msg else {
            XCTFail("Expected .perriState, got \(msg)")
            return
        }
        XCTAssertNil(current)
        XCTAssertEqual(queue.count, 1)
        let item = queue[0]
        XCTAssertEqual(item.bucket, "dependabot")
        XCTAssertTrue(item.isBot)
        XCTAssertEqual(item.headSha, "dep-sha")
    }

    // MARK: - PrSnapshot defaults for missing Rust `#[serde(default)]` fields

    func testPrSnapshotDefaultsMissingCountFields() throws {
        let json = """
        {
            "pr_number": null,
            "repo": "r", "title": "t", "author": "a",
            "url": "u", "diff": "", "stale": false
        }
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(PrSnapshot.self, from: json)
        XCTAssertEqual(snap.additions,    0)
        XCTAssertEqual(snap.deletions,    0)
        XCTAssertEqual(snap.changedFiles, 0)
        XCTAssertFalse(snap.diffTooLarge)
        XCTAssertTrue(snap.ciChecks.isEmpty)
        XCTAssertEqual(snap.headSha, "")
    }
}
