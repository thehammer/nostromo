// NostromoKit — PerriStateTagTests.swift
//
// Wire decoding for the new leading `tag: String` on `ServerMsg.perriState`
// (W8 — per-focus-pr-indicator): `perri_state` frames now carry a top-level
// `"tag"` string identifying which focus's PR-under-review this broadcast
// describes. `queue` stays fleet-wide/global — it does NOT get a per-tag
// semantic — only `current` is per-focus.
//
// Deliberately a NEW file rather than an edit to the existing
// `PerriWireTests.swift` in this directory: that file's several
// `guard case .perriState(let queue, let current) = msg` call sites are
// being mechanically updated to the new 3-tuple shape as a separate change,
// and this file must not collide with that edit.

import XCTest
@testable import NostromoKit

final class PerriStateTagTests: XCTestCase {

    // MARK: - tag decodes, queue empty, current nil

    func testPerriStateDecodesTagWithEmptyQueueAndNilCurrent() throws {
        let json = """
        {
            "type": "perri_state",
            "tag": "focus-a",
            "queue": [],
            "current": null
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .perriState(let tag, let queue, let current) = msg else {
            XCTFail("Expected .perriState, got \(msg)")
            return
        }
        XCTAssertEqual(tag, "focus-a")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(current)
    }

    // MARK: - tag decodes alongside a populated queue AND a populated current
    //         — the "queue stays global, only current is per-tag" invariant

    func testPerriStateDecodesTagWithPopulatedQueueAndCurrent() throws {
        let json = """
        {
            "type": "perri_state",
            "tag": "focus-b",
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
        guard case .perriState(let tag, let queue, let current) = msg else {
            XCTFail("Expected .perriState, got \(msg)")
            return
        }

        XCTAssertEqual(tag, "focus-b")

        XCTAssertEqual(queue.count, 1, "queue must still decode exactly as before — it stays fleet-wide, not per-tag")
        XCTAssertEqual(queue[0].repo, "acme/web")
        XCTAssertEqual(queue[0].number, 42)

        let pr = try XCTUnwrap(current)
        XCTAssertEqual(pr.repo, "acme/web")
        XCTAssertEqual(pr.prNumber, 42)
    }
}
