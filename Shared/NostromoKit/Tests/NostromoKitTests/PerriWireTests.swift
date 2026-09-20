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

    func testPerriActionApproveEncoding() throws {
        let msg = ClientPerriAction(action: "approve", prNumber: 7, repo: "acme/web")
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"]      as? String, "perri_action")
        XCTAssertEqual(dict["action"]    as? String, "approve")
        XCTAssertEqual(dict["pr_number"] as? Int,    7)
        XCTAssertEqual(dict["repo"]      as? String, "acme/web")
        XCTAssertEqual(dict.keys.count,  4, "Expected exactly type, action, pr_number, repo")
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

    // MARK: - PrSnapshot body/threads/conversation_error (W3 — curated-agent-views)

    /// The cache-compatibility guarantee: a `pr-cache/*.json` file written by
    /// a binary built before this wedge has none of `body`/`threads`/
    /// `conversation_error` on the wire at all. It must still decode, with
    /// those three fields defaulting rather than the whole snapshot failing.
    func testPrSnapshotDecodesWithBodyThreadsAndConversationErrorMissingEntirely() throws {
        let json = """
        {
            "pr_number": 42,
            "repo": "acme/web", "title": "feat: auth", "author": "alice",
            "url": "https://github.com/acme/web/pull/42", "diff": "", "stale": false
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder.nostromo.decode(PrSnapshot.self, from: json)

        XCTAssertEqual(snap.body, "", "body must default to an empty string when absent from an older cache file")
        XCTAssertEqual(snap.threads, [], "threads must default to empty when absent from an older cache file")
        XCTAssertNil(snap.conversationError, "conversation_error must default to nil when absent from an older cache file")
    }

    func testPrSnapshotDecodesBodyAndThreadsWhenPresent() throws {
        let json = """
        {
            "pr_number": 42,
            "repo": "acme/web", "title": "feat: auth", "author": "alice",
            "url": "https://github.com/acme/web/pull/42", "diff": "", "stale": false,
            "body": "This PR adds auth.\\n\\n```rust\\nfn login() {}\\n```",
            "threads": [
                {
                    "id": "thread-1",
                    "kind": "inline",
                    "path": "src/auth.rs",
                    "line": 12,
                    "diff_hunk": "@@ -1,2 +1,2 @@",
                    "resolved": true,
                    "comments": [
                        {
                            "id": "comment-1",
                            "author": "bob",
                            "created_at": "2026-05-30T09:30:56.510874Z",
                            "body": "Looks good, one nit."
                        }
                    ]
                }
            ],
            "conversation_error": null
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder.nostromo.decode(PrSnapshot.self, from: json)

        XCTAssertEqual(snap.body, "This PR adds auth.\n\n```rust\nfn login() {}\n```")
        XCTAssertNil(snap.conversationError)
        XCTAssertEqual(snap.threads.count, 1)

        let thread = snap.threads[0]
        XCTAssertEqual(thread.id, "thread-1")
        XCTAssertEqual(thread.kind, .inline)
        XCTAssertEqual(thread.path, "src/auth.rs")
        XCTAssertEqual(thread.line, 12)
        XCTAssertEqual(thread.diffHunk, "@@ -1,2 +1,2 @@")
        XCTAssertTrue(thread.resolved)
        XCTAssertEqual(thread.comments.count, 1)

        let comment = thread.comments[0]
        XCTAssertEqual(comment.id, "comment-1")
        XCTAssertEqual(comment.author, "bob")
        XCTAssertEqual(comment.body, "Looks good, one nit.")

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(fmt.date(from: "2026-05-30T09:30:56.510874Z"))
        XCTAssertEqual(comment.createdAt, expected)
    }

    func testPrSnapshotSetsConversationErrorAlongsideWhateverThreadsWereRetrieved() throws {
        // A conversation fetch failure alongside a successful PR fetch must
        // preserve whatever threads were retrieved before the failure, not
        // blank them out.
        let json = """
        {
            "pr_number": 42,
            "repo": "acme/web", "title": "feat: auth", "author": "alice",
            "url": "https://github.com/acme/web/pull/42", "diff": "", "stale": false,
            "threads": [
                { "id": "thread-1", "kind": "issue", "resolved": false, "comments": [] }
            ],
            "conversation_error": "GitHub API rate limited"
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder.nostromo.decode(PrSnapshot.self, from: json)

        XCTAssertEqual(snap.conversationError, "GitHub API rate limited")
        XCTAssertEqual(snap.threads.count, 1, "partial threads retrieved before the failure must be preserved, not discarded")
    }

    func testEveryPrThreadKindDecodesToTheRightCase() throws {
        func decodeKind(_ raw: String) throws -> PrThreadKind {
            let json = """
            { "id": "t1", "kind": "\(raw)", "resolved": false, "comments": [] }
            """.data(using: .utf8)!
            return try JSONDecoder().decode(PrThread.self, from: json).kind
        }

        XCTAssertEqual(try decodeKind("issue"), .issue)
        XCTAssertEqual(try decodeKind("review"), .review)
        XCTAssertEqual(try decodeKind("inline"), .inline)
    }

    /// `PrThread`/`PrComment` round-trip through `Codable` (they're the raw-
    /// markdown counterparts of `ConversationThreadModel`/
    /// `ConversationCommentModel`, and travel on `PrSnapshot` rather than
    /// `PaneContentWire`).
    func testPrThreadAndPrCommentRoundTripThroughCodable() throws {
        let original = PrThread(
            id: "thread-1",
            kind: .review,
            path: "src/auth.rs",
            line: 7,
            diffHunk: "@@ -1,1 +1,1 @@",
            resolved: false,
            comments: [
                PrComment(id: "c1", author: "alice", createdAt: Date(timeIntervalSince1970: 1_700_000_000), body: "raw **markdown** body"),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrThread.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - PrQueueItem.bucketScopedId (SwiftUI row identity, never a domain identity)
    //
    // Same defect as `PrListItemModel.bucketScopedId` (see PaneContentWireTests),
    // second file: `PrQueueItem.id` is `"\(repo)#\(number)"` and deliberately
    // excludes `bucket`, so when a PR moves between review buckets its `id`
    // (and therefore its default SwiftUI `Identifiable` row identity) doesn't
    // change — SwiftUI can then recycle the old row under the new section
    // header, rendering the previous bucket's badge. `bucketScopedId` is a
    // second, view-identity-only property that folds `bucket` in so a bucket
    // move always looks like a new row to `ForEach(items, id: \.bucketScopedId)`.
    // It must never replace `id` itself, since `id` is relied on elsewhere as
    // a cross-cutting domain identity (e.g. `rowModel(for:)` in PerriView).

    private func makeQueueItem(
        repo:        String  = "acme/web",
        number:      Int     = 42,
        title:       String  = "feat: auth",
        author:      String  = "alice",
        bucket:      String  = "requested",
        newActivity: Bool    = true,
        url:         String  = "https://github.com/acme/web/pull/42",
        ciState:     CiState = .success,
        headSha:     String  = "abc123",
        isBot:       Bool    = false
    ) -> PrQueueItem {
        PrQueueItem(
            repo: repo, number: number, title: title, author: author,
            bucket: bucket, newActivity: newActivity, url: url,
            ciState: ciState, headSha: headSha, isBot: isBot
        )
    }

    func testBucketScopedIdDiffersWhenOnlyBucketDiffers() {
        let requested   = makeQueueItem(bucket: "requested")
        let needsReview = makeQueueItem(bucket: "needs_review")

        XCTAssertNotEqual(
            requested.bucketScopedId, needsReview.bucketScopedId,
            "a PR moving from one bucket to another must be treated as a distinct SwiftUI row identity, " +
            "or a moved row can be recycled and render the stale bucket's badge"
        )
    }

    func testIdIsUnaffectedByBucketEvenWhenBucketScopedIdDiffers() {
        let requested   = makeQueueItem(bucket: "requested")
        let needsReview = makeQueueItem(bucket: "needs_review")

        XCTAssertEqual(
            requested.id, needsReview.id,
            "id must stay \"\\(repo)#\\(number)\" and never fold in bucket — id is a cross-cutting domain " +
            "identity used elsewhere (e.g. PerriView.rowModel(for:)); only bucketScopedId may vary with bucket"
        )
    }

    func testBucketScopedIdIsDeterministicForTheSameInputs() {
        let first  = makeQueueItem(repo: "acme/web", number: 42, bucket: "requested")
        let second = makeQueueItem(repo: "acme/web", number: 42, bucket: "requested")

        XCTAssertEqual(
            first.bucketScopedId, second.bucketScopedId,
            "bucketScopedId must be a pure function of its inputs — the same repo/number/bucket must " +
            "always produce the same row identity"
        )
    }

    func testBucketScopedIdDistinguishesDifferentPrsInTheSameBucket() {
        let prOne = makeQueueItem(repo: "acme/web", number: 42, bucket: "requested")
        let prTwo = makeQueueItem(repo: "acme/other", number: 7, bucket: "requested")

        XCTAssertNotEqual(
            prOne.bucketScopedId, prTwo.bucketScopedId,
            "two distinct PRs in the same bucket must never collapse onto the same row identity — that " +
            "would drop one of them from the rendered list entirely, which is worse than the stale-badge bug"
        )
    }
}
