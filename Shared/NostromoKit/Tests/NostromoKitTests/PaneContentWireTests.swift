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
//   - code/diff (W2 — curated-agent-views): full field decode including
//     nested DiffFileModel/DiffHunkModel/DiffLineModel, renamed-file old_path,
//     omitted number, and the too_large/empty-files large-diff state; a
//     pre-W2 client sibling proving code/diff fall through to .unknown for a
//     kind string it doesn't recognise; and Equatable coverage for both.
//   - pr_conversation (W3 — curated-agent-views): full field decode including
//     nested MdBlock/MdSpan body content and a full ConversationThread/
//     ConversationComment, conversation_error null/absent/present, every
//     ConversationThreadKind raw value, a pr_conversation-shaped payload with
//     an unrecognised kind string falling through to .unknown; and Equatable
//     coverage including nested-content differences.

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

    /// Sibling of `testUnknownKindDecodesWithoutThrowing`: proves that this is
    /// exactly the path a pre-W2/W3 client takes for a `code`/`diff`/
    /// `pr_conversation` frame it doesn't yet know about — i.e. a future kind
    /// is not special-cased, it falls through the same default arm as any
    /// other unrecognised kind. Uses a plausible future kind name rather than
    /// "code"/"diff"/"pr_conversation" themselves, since this client DOES know
    /// those three.
    func testAFutureContentKindNotYetKnownDecodesToUnknownJustLikeAnyOtherUnrecognisedKind() throws {
        let json = """
        {
            "kind": "some_future_kind_this_client_has_never_heard_of",
            "some_field": "some_value"
        }
        """

        let wire = try decode(json)

        guard case .unknown = wire else {
            XCTFail("Expected .unknown for a not-yet-known future kind, got \(wire)")
            return
        }
    }

    /// Sibling of the above, specific to `pr_conversation` (W3 —
    /// curated-agent-views): an *unrecognised variant* of a kind this client
    /// otherwise knows (e.g. a hypothetical future `pr_conversation_v2`, or
    /// the frame simply mangled) must still degrade to `.unknown` rather than
    /// throwing — the same forward-compatibility contract as any other kind.
    func testAPrConversationShapedPayloadWithAnUnrecognisedKindStringDecodesToUnknown() throws {
        let json = """
        {
            "kind": "pr_conversation_v2",
            "repo": "acme/web",
            "number": 42,
            "title": "feat: add auth",
            "author": "alice",
            "url": "https://github.com/acme/web/pull/42",
            "body": [],
            "threads": []
        }
        """

        let wire = try decode(json)

        guard case .unknown = wire else {
            XCTFail("Expected .unknown for an unrecognised kind string, got \(wire)")
            return
        }
    }

    // MARK: - code decodes correctly (W2 — curated-agent-views)

    func testCodeDecodesCorrectly() throws {
        let json = """
        {
            "kind": "code",
            "path": "src/ipc/session_manager.rs",
            "revision": "a1b2c3d",
            "first_line": 1,
            "text": "use std::..."
        }
        """

        let wire = try decode(json)

        guard case .code(let payload) = wire else {
            XCTFail("Expected .code, got \(wire)")
            return
        }

        XCTAssertEqual(payload.path,      "src/ipc/session_manager.rs")
        XCTAssertEqual(payload.revision,  "a1b2c3d")
        XCTAssertEqual(payload.firstLine, 1, "first_line must map to firstLine")
        XCTAssertEqual(payload.text,      "use std::...")
    }

    // MARK: - diff decodes correctly (W2 — curated-agent-views)

    func testDiffDecodesCorrectlyWithTwoFilesIncludingARenameAndAllLineKinds() throws {
        let json = """
        {
            "kind": "diff",
            "repo": "acme/web",
            "number": 42,
            "files": [
                {
                    "path": "src/main.rs",
                    "old_path": null,
                    "status": "modified",
                    "additions": 3,
                    "deletions": 1,
                    "hunks": [
                        {
                            "header": "@@ -10,3 +10,5 @@ fn main() {",
                            "old_start": 10,
                            "new_start": 10,
                            "lines": [
                                { "kind": "context", "old_n": 10, "new_n": 10, "text": "let x = 1;" },
                                { "kind": "removed", "old_n": 11, "text": "let y = 2;" },
                                { "kind": "added",   "new_n": 11, "text": "let y = 3;" },
                                { "kind": "meta", "text": "\\\\ No newline at end of file" }
                            ]
                        }
                    ]
                },
                {
                    "path": "src/new_name.rs",
                    "old_path": "src/old_name.rs",
                    "status": "renamed",
                    "additions": 0,
                    "deletions": 0,
                    "hunks": [
                        {
                            "header": "@@ -1,2 +1,2 @@",
                            "old_start": 1,
                            "new_start": 1,
                            "lines": [
                                { "kind": "context", "old_n": 1, "new_n": 1, "text": "unchanged" }
                            ]
                        },
                        {
                            "header": "@@ -20,1 +20,1 @@",
                            "old_start": 20,
                            "new_start": 20,
                            "lines": [
                                { "kind": "context", "old_n": 20, "new_n": 20, "text": "also unchanged" }
                            ]
                        }
                    ]
                }
            ],
            "too_large": false,
            "changed_files": 2
        }
        """

        let wire = try decode(json)

        guard case .diff(let payload) = wire else {
            XCTFail("Expected .diff, got \(wire)")
            return
        }

        XCTAssertEqual(payload.repo,         "acme/web")
        XCTAssertEqual(payload.number,       42)
        XCTAssertFalse(payload.tooLarge)
        XCTAssertEqual(payload.changedFiles, 2)
        XCTAssertEqual(payload.files.count,  2)

        let modifiedFile = payload.files[0]
        XCTAssertEqual(modifiedFile.path,      "src/main.rs")
        XCTAssertNil(modifiedFile.oldPath)
        XCTAssertEqual(modifiedFile.status,    .modified)
        XCTAssertEqual(modifiedFile.additions, 3)
        XCTAssertEqual(modifiedFile.deletions, 1)
        XCTAssertEqual(modifiedFile.hunks.count, 1)

        let hunk = modifiedFile.hunks[0]
        XCTAssertEqual(hunk.header,   "@@ -10,3 +10,5 @@ fn main() {")
        XCTAssertEqual(hunk.oldStart, 10)
        XCTAssertEqual(hunk.newStart, 10)
        XCTAssertEqual(hunk.lines.count, 4)

        XCTAssertEqual(hunk.lines[0].kind, .context)
        XCTAssertEqual(hunk.lines[0].oldN, 10)
        XCTAssertEqual(hunk.lines[0].newN, 10)
        XCTAssertEqual(hunk.lines[0].text, "let x = 1;")

        XCTAssertEqual(hunk.lines[1].kind, .removed)
        XCTAssertEqual(hunk.lines[1].oldN, 11)
        XCTAssertNil(hunk.lines[1].newN, "a removed line has no new-side line number")
        XCTAssertEqual(hunk.lines[1].text, "let y = 2;")

        XCTAssertEqual(hunk.lines[2].kind, .added)
        XCTAssertNil(hunk.lines[2].oldN, "an added line has no old-side line number")
        XCTAssertEqual(hunk.lines[2].newN, 11)
        XCTAssertEqual(hunk.lines[2].text, "let y = 3;")

        XCTAssertEqual(hunk.lines[3].kind, .meta)
        XCTAssertNil(hunk.lines[3].oldN)
        XCTAssertNil(hunk.lines[3].newN)
        XCTAssertEqual(hunk.lines[3].text, "\\ No newline at end of file")

        let renamedFile = payload.files[1]
        XCTAssertEqual(renamedFile.path,    "src/new_name.rs")
        XCTAssertEqual(renamedFile.oldPath, "src/old_name.rs")
        XCTAssertEqual(renamedFile.status,  .renamed)
        XCTAssertEqual(renamedFile.hunks.count, 2, "a renamed file can still carry multiple hunks")
        XCTAssertEqual(renamedFile.hunks[0].header, "@@ -1,2 +1,2 @@")
        XCTAssertEqual(renamedFile.hunks[1].header, "@@ -20,1 +20,1 @@")
    }

    func testDiffWithOmittedNumberDecodesWithNilNumber() throws {
        // The daemon omits `number` via skip_serializing_if when there's no
        // PR context to attach it to.
        let json = """
        {
            "kind": "diff",
            "repo": "acme/web",
            "files": [],
            "too_large": false,
            "changed_files": 0
        }
        """

        let wire = try decode(json)

        guard case .diff(let payload) = wire else {
            XCTFail("Expected .diff, got \(wire)")
            return
        }

        XCTAssertNil(payload.number, "number must be nil, not 0 or a decode failure, when omitted from the wire")
    }

    func testDiffWithTooLargeTrueAndEmptyFilesRetainsChangedFilesCount() throws {
        let json = """
        {
            "kind": "diff",
            "repo": "acme/web",
            "number": 7,
            "files": [],
            "too_large": true,
            "changed_files": 250
        }
        """

        let wire = try decode(json)

        guard case .diff(let payload) = wire else {
            XCTFail("Expected .diff, got \(wire)")
            return
        }

        XCTAssertTrue(payload.tooLarge)
        XCTAssertEqual(payload.files, [], "files must be empty when too_large, not a stale/partial list")
        XCTAssertEqual(
            payload.changedFiles, 250,
            "changed_files must survive the wire even when the diff itself is too large to send"
        )
    }

    // MARK: - pr_conversation decodes correctly (W3 — curated-agent-views)

    func testPrConversationDecodesEveryFieldFromWireFormatJSON() throws {
        let json = """
        {
            "kind": "pr_conversation",
            "repo": "acme/web",
            "number": 42,
            "title": "feat: add auth",
            "author": "alice",
            "url": "https://github.com/acme/web/pull/42",
            "body": [
                { "kind": "paragraph", "spans": [{ "kind": "text", "text": "This PR adds auth." }] },
                { "kind": "code_block", "lang": "rust", "text": "fn login() {\\n    todo!()\\n}" }
            ],
            "threads": [
                {
                    "id": "thread-1",
                    "kind": "review",
                    "path": "src/auth.rs",
                    "line": 12,
                    "diff_hunk": "@@ -1,2 +1,2 @@",
                    "resolved": false,
                    "comments": [
                        {
                            "id": "comment-1",
                            "author": "bob",
                            "created_at": "2026-05-30T09:30:56.510874Z",
                            "body": [{ "kind": "paragraph", "spans": [{ "kind": "text", "text": "Looks good." }] }]
                        }
                    ]
                }
            ],
            "conversation_error": null
        }
        """

        let wire = try decode(json)

        guard case .prConversation(let payload) = wire else {
            XCTFail("Expected .prConversation, got \(wire)")
            return
        }

        XCTAssertEqual(payload.repo, "acme/web")
        XCTAssertEqual(payload.number, 42)
        XCTAssertEqual(payload.title, "feat: add auth")
        XCTAssertEqual(payload.author, "alice")
        XCTAssertEqual(payload.url, "https://github.com/acme/web/pull/42")
        XCTAssertEqual(payload.body.count, 2)
        XCTAssertEqual(payload.body[0], .paragraph([.text("This PR adds auth.")]))
        XCTAssertEqual(payload.body[1], .codeBlock(lang: "rust", text: "fn login() {\n    todo!()\n}"))

        XCTAssertEqual(payload.threads.count, 1)
        let thread = payload.threads[0]
        XCTAssertEqual(thread.id, "thread-1")
        XCTAssertEqual(thread.kind, .review)
        XCTAssertEqual(thread.path, "src/auth.rs")
        XCTAssertEqual(thread.line, 12)
        XCTAssertEqual(thread.diffHunk, "@@ -1,2 +1,2 @@")
        XCTAssertFalse(thread.resolved)
        XCTAssertEqual(thread.comments.count, 1)

        let comment = thread.comments[0]
        XCTAssertEqual(comment.id, "comment-1")
        XCTAssertEqual(comment.author, "bob")
        XCTAssertEqual(comment.body, [.paragraph([.text("Looks good.")])])

        XCTAssertNil(payload.conversationError, "conversation_error: null must decode to nil")
    }

    func testPrConversationDecodesWithConversationErrorAbsentEntirely() throws {
        let json = """
        {
            "kind": "pr_conversation",
            "repo": "acme/web",
            "number": 42,
            "title": "feat: add auth",
            "author": "alice",
            "url": "https://github.com/acme/web/pull/42",
            "body": [],
            "threads": []
        }
        """

        let wire = try decode(json)

        guard case .prConversation(let payload) = wire else {
            XCTFail("Expected .prConversation, got \(wire)")
            return
        }

        XCTAssertNil(payload.conversationError, "conversation_error must default to nil when the key is absent entirely")
        XCTAssertEqual(payload.body, [])
        XCTAssertEqual(payload.threads, [])
    }

    func testPrConversationDecodesWithAConversationErrorPresent() throws {
        let json = """
        {
            "kind": "pr_conversation",
            "repo": "acme/web",
            "number": 42,
            "title": "feat: add auth",
            "author": "alice",
            "url": "https://github.com/acme/web/pull/42",
            "body": [],
            "threads": [],
            "conversation_error": "GitHub API rate limited"
        }
        """

        let wire = try decode(json)

        guard case .prConversation(let payload) = wire else {
            XCTFail("Expected .prConversation, got \(wire)")
            return
        }

        XCTAssertEqual(payload.conversationError, "GitHub API rate limited")
    }

    func testEveryConversationThreadKindDecodesToTheRightCase() throws {
        func decodeKind(_ raw: String) throws -> ConversationThreadKind {
            let json = """
            {
                "kind": "pr_conversation", "repo": "r", "number": 1, "title": "t", "author": "a",
                "url": "u", "body": [], "threads": [
                    { "id": "t1", "kind": "\(raw)", "resolved": false, "comments": [] }
                ]
            }
            """
            guard case .prConversation(let payload) = try decode(json) else {
                XCTFail("Expected .prConversation")
                return .issue
            }
            return payload.threads[0].kind
        }

        XCTAssertEqual(try decodeKind("issue"), .issue)
        XCTAssertEqual(try decodeKind("review"), .review)
        XCTAssertEqual(try decodeKind("inline"), .inline)
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
        XCTAssertFalse(rowModel.marked, "a row nothing points at is unmarked")
    }

    // MARK: - Queue-row marking (W5 — curated-agent-views)

    private func prItem(repo: String = "acme/web", number: Int = 42) -> PrListItemModel {
        PrListItemModel(
            repo:        repo,
            number:      number,
            title:       "feat: auth",
            author:      "alice",
            bucket:      "requested",
            ciState:     .success,
            newActivity: false,
            url:         "",
            headSha:     ""
        )
    }

    func testRowIsMarkedWhenTheAddressAnchorsThatQueueRow() {
        let address = PaneAddress(
            anchor:   .queueRow(repo: "acme/web", number: 42),
            emphasis: [],
            reason:   nil
        )
        XCTAssertTrue(prItem().toRowModel(marked: address.marks(repo: "acme/web", number: 42)).marked)
    }

    func testRowIsMarkedWhenTheAddressEmphasisesThatQueueRow() {
        let address = PaneAddress(
            anchor:   nil,
            emphasis: [.queueRow(repo: "acme/web", number: 42)],
            reason:   "this one next"
        )
        XCTAssertTrue(prItem().toRowModel(marked: address.marks(repo: "acme/web", number: 42)).marked)
    }

    func testOnlyTheAddressedRowIsMarked() {
        let address = PaneAddress(
            anchor:   .queueRow(repo: "acme/web", number: 42),
            emphasis: [],
            reason:   nil
        )
        XCTAssertTrue(prItem(number: 42).toRowModel(marked: address.marks(repo: "acme/web", number: 42)).marked)
        XCTAssertFalse(prItem(number: 43).toRowModel(marked: address.marks(repo: "acme/web", number: 43)).marked)
        XCTAssertFalse(prItem(repo: "acme/api").toRowModel(marked: address.marks(repo: "acme/api", number: 42)).marked)
    }

    func testARowIsUnmarkedByAnAddressThatPointsAtSomethingElse() {
        // A `reason`-only address, and an address carrying a non-queue anchor,
        // must both leave every row alone rather than marking the first one.
        let reasonOnly = PaneAddress(anchor: nil, emphasis: [], reason: "why")
        XCTAssertFalse(prItem().toRowModel(marked: reasonOnly.marks(repo: "acme/web", number: 42)).marked)

        let lineAnchor = PaneAddress(
            anchor:   .line(path: "a.rs", line: 412),
            emphasis: [.lineRange(path: nil, start: 1, end: 2)],
            reason:   nil
        )
        XCTAssertFalse(prItem().toRowModel(marked: lineAnchor.marks(repo: "acme/web", number: 42)).marked)
    }

    func testAnAbsentAddressLeavesEveryRowUnmarked() {
        let absent: PaneAddress? = nil
        XCTAssertFalse(
            prItem().toRowModel(
                marked: absent?.marks(repo: "acme/web", number: 42) ?? false
            ).marked
        )
        XCTAssertFalse(prItem().toRowModel().marked)
    }

    /// D6 (ios-curated-view-parity W2): marking is visual only. An address
    /// pointing at row A must mark row A's model and leave row B's model
    /// unmarked, and — the part a bare `marked == true/false` assertion
    /// doesn't cover — must not perturb any *other* field of either row.
    /// `PerriPRRowModel.marked`'s own doc comment states the invariant this
    /// pins: marking never touches selection, current-PR state, or what a
    /// swipe-to-approve acts on. Comparing the whole model against what
    /// `toRowModel(marked: false)` would have produced, field by field via
    /// `==`, is what catches a future change that starts threading `marked`
    /// into some other field's computation.
    func testMarkingOneRowLeavesEveryOtherFieldOfBothRowModelsUnchanged() {
        let address = PaneAddress(
            anchor:   .queueRow(repo: "acme/web", number: 42),
            emphasis: [],
            reason:   nil
        )
        let rowA = prItem(number: 42)
        let rowB = prItem(number: 43)

        let markedA   = rowA.toRowModel(marked: address.marks(repo: "acme/web", number: 42))
        let unmarkedA = rowA.toRowModel(marked: false)
        XCTAssertTrue(markedA.marked)
        XCTAssertEqual(markedA.id, unmarkedA.id)
        XCTAssertEqual(markedA.number, unmarkedA.number)
        XCTAssertEqual(markedA.title, unmarkedA.title)
        XCTAssertEqual(markedA.repo, unmarkedA.repo)
        XCTAssertEqual(markedA.author, unmarkedA.author)
        XCTAssertEqual(markedA.bucket, unmarkedA.bucket)
        XCTAssertEqual(markedA.ciState, unmarkedA.ciState)
        XCTAssertEqual(markedA.newActivity, unmarkedA.newActivity)

        let rowBModel = rowB.toRowModel(marked: address.marks(repo: "acme/web", number: 43))
        XCTAssertEqual(rowBModel, rowB.toRowModel(marked: false), "row B is untouched by an address that points at row A")
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

    // MARK: - PrListItemModel.bucketScopedId (SwiftUI row identity, never a domain identity)
    //
    // Regression coverage for the stale-badge bug: `id` is `"\(repo)#\(number)"`
    // and deliberately excludes `bucket`, so when a PR moves between buckets
    // its `id` (and therefore its default SwiftUI `Identifiable` row identity)
    // doesn't change — SwiftUI can then recycle the old row under the new
    // section header, rendering the previous bucket's badge. `bucketScopedId`
    // is a second, view-identity-only property that folds `bucket` in so a
    // bucket move always looks like a new row to `ForEach(items, id:
    // \.bucketScopedId)`. It must never replace `id` itself, since `id` is
    // documented as matching `PrQueueItem.id` and is relied on elsewhere as a
    // cross-cutting domain identity.

    func testBucketScopedIdDiffersWhenOnlyBucketDiffers() {
        let requested   = makeItem(bucket: "requested")
        let needsReview = makeItem(bucket: "needs_review")

        XCTAssertNotEqual(
            requested.bucketScopedId, needsReview.bucketScopedId,
            "a PR moving from one bucket to another must be treated as a distinct SwiftUI row identity, " +
            "or a moved row can be recycled and render the stale bucket's badge"
        )
    }

    func testIdIsUnaffectedByBucketEvenWhenBucketScopedIdDiffers() {
        let requested   = makeItem(bucket: "requested")
        let needsReview = makeItem(bucket: "needs_review")

        XCTAssertEqual(
            requested.id, needsReview.id,
            "id must stay \"\\(repo)#\\(number)\" and never fold in bucket — id is a cross-cutting domain " +
            "identity documented as matching PrQueueItem.id; only bucketScopedId may vary with bucket"
        )
    }

    func testBucketScopedIdIsDeterministicForTheSameInputs() {
        let first  = makeItem(repo: "acme/web", number: 42, bucket: "requested")
        let second = makeItem(repo: "acme/web", number: 42, bucket: "requested")

        XCTAssertEqual(
            first.bucketScopedId, second.bucketScopedId,
            "bucketScopedId must be a pure function of its inputs — the same repo/number/bucket must " +
            "always produce the same row identity"
        )
    }

    func testBucketScopedIdDistinguishesDifferentPrsInTheSameBucket() {
        let prOne = makeItem(repo: "acme/web", number: 42, bucket: "requested")
        let prTwo = makeItem(repo: "acme/other", number: 7, bucket: "requested")

        XCTAssertNotEqual(
            prOne.bucketScopedId, prTwo.bucketScopedId,
            "two distinct PRs in the same bucket must never collapse onto the same row identity — that " +
            "would drop one of them from the rendered list entirely, which is worse than the stale-badge bug"
        )
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

    // MARK: - PaneContentWire.Equatable — .code (W2 — curated-agent-views)

    private func makeCodePayload(
        path:      String = "src/main.rs",
        revision:  String = "a1b2c3d",
        firstLine: Int    = 1,
        text:      String = "let x = 1;"
    ) -> CodePayload {
        CodePayload(path: path, revision: revision, firstLine: firstLine, text: text)
    }

    func testCodeCasesWithIdenticalPayloadsAreEqual() {
        XCTAssertEqual(PaneContentWire.code(makeCodePayload()), PaneContentWire.code(makeCodePayload()))
    }

    func testCodeCasesDifferingByPathAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(path: "src/other.rs"))
        )
    }

    func testCodeCasesDifferingByRevisionAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(revision: "working"))
        )
    }

    func testCodeCasesDifferingByFirstLineAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(firstLine: 42))
        )
    }

    func testCodeCasesDifferingByTextAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(text: "let x = 2;"))
        )
    }

    // MARK: - PaneContentWire.Equatable — .diff (W2 — curated-agent-views)

    private func makeDiffLine(
        kind: DiffLineModel.Kind = .context,
        oldN: Int? = 10,
        newN: Int? = 10,
        text: String = "let x = 1;"
    ) -> DiffLineModel {
        DiffLineModel(kind: kind, oldN: oldN, newN: newN, text: text)
    }

    private func makeDiffHunk(
        header:   String = "@@ -10,3 +10,5 @@ fn main() {",
        oldStart: Int = 10,
        newStart: Int = 10,
        lines:    [DiffLineModel]? = nil
    ) -> DiffHunkModel {
        DiffHunkModel(header: header, oldStart: oldStart, newStart: newStart, lines: lines ?? [makeDiffLine()])
    }

    private func makeDiffFile(
        path:      String = "src/main.rs",
        oldPath:   String? = nil,
        status:    DiffFileModel.Status = .modified,
        additions: Int = 3,
        deletions: Int = 1,
        hunks:     [DiffHunkModel]? = nil
    ) -> DiffFileModel {
        DiffFileModel(
            path: path, oldPath: oldPath, status: status,
            additions: additions, deletions: deletions, hunks: hunks ?? [makeDiffHunk()]
        )
    }

    private func makeDiffPayload(
        repo:         String = "acme/web",
        number:       Int?   = 42,
        files:        [DiffFileModel]? = nil,
        tooLarge:     Bool = false,
        changedFiles: Int  = 1
    ) -> DiffPayload {
        DiffPayload(
            repo: repo, number: number, files: files ?? [makeDiffFile()],
            tooLarge: tooLarge, changedFiles: changedFiles
        )
    }

    func testDiffCasesWithIdenticalPayloadsAreEqual() {
        XCTAssertEqual(PaneContentWire.diff(makeDiffPayload()), PaneContentWire.diff(makeDiffPayload()))
    }

    func testDiffCasesDifferingByRepoAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(repo: "acme/other"))
        )
    }

    func testDiffCasesDifferingByNumberAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(number: 43))
        )
    }

    func testDiffCasesDifferingByFilesAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile(path: "src/other.rs")]))
        )
    }

    func testDiffCasesDifferingByTooLargeAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(tooLarge: true))
        )
    }

    func testDiffCasesDifferingByChangedFilesAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(changedFiles: 5))
        )
    }

    /// Proves nested `DiffFileModel`/`DiffHunkModel`/`DiffLineModel` equality
    /// actually reaches down through `.diff`'s payload — not just the
    /// top-level `DiffPayload` fields.
    func testDiffCasesWithStructurallyDifferentFilesAreNotEqual() {
        // A different hunk (header changes) inside an otherwise-identical file.
        let differentHunk = makeDiffFile(hunks: [makeDiffHunk(header: "@@ -1,1 +1,1 @@ fn other() {")])
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile()])),
            PaneContentWire.diff(makeDiffPayload(files: [differentHunk])),
            "a different hunk header nested inside an identical file must be caught"
        )

        // A different line kind inside an otherwise-identical hunk.
        let differentLineKind = makeDiffFile(hunks: [makeDiffHunk(lines: [makeDiffLine(kind: .added)])])
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile()])),
            PaneContentWire.diff(makeDiffPayload(files: [differentLineKind])),
            "a different line kind nested inside an identical hunk must be caught"
        )

        // A different oldPath (rename provenance) on an otherwise-identical file.
        let differentOldPath = makeDiffFile(oldPath: "src/renamed_from.rs", status: .renamed)
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile(status: .renamed)])),
            PaneContentWire.diff(makeDiffPayload(files: [differentOldPath])),
            "a different oldPath nested inside an identical file must be caught"
        )
    }

    // MARK: - PaneContentWire.Equatable — .prConversation (W3 — curated-agent-views)

    private func makeConversationComment(
        id: String = "c1",
        author: String = "alice",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        body: [MdBlock]? = nil
    ) -> ConversationCommentModel {
        ConversationCommentModel(
            id: id, author: author, createdAt: createdAt,
            body: body ?? [.paragraph([.text("looks good")])]
        )
    }

    private func makeConversationThread(
        id: String = "t1",
        kind: ConversationThreadKind = .issue,
        path: String? = nil,
        line: Int? = nil,
        diffHunk: String? = nil,
        resolved: Bool = false,
        comments: [ConversationCommentModel]? = nil
    ) -> ConversationThreadModel {
        ConversationThreadModel(
            id: id, kind: kind, path: path, line: line, diffHunk: diffHunk,
            resolved: resolved, comments: comments ?? [makeConversationComment()]
        )
    }

    private func makeConversationPayload(
        repo: String = "acme/web",
        number: Int? = 42,
        title: String = "feat: auth",
        author: String = "alice",
        url: String = "https://github.com/acme/web/pull/42",
        body: [MdBlock]? = nil,
        threads: [ConversationThreadModel]? = nil,
        conversationError: String? = nil
    ) -> PrConversationPayload {
        PrConversationPayload(
            repo: repo, number: number, title: title, author: author, url: url,
            body: body ?? [.paragraph([.text("PR description")])],
            threads: threads ?? [makeConversationThread()],
            conversationError: conversationError
        )
    }

    func testPrConversationCasesWithIdenticalPayloadsAreEqual() {
        XCTAssertEqual(
            PaneContentWire.prConversation(makeConversationPayload()),
            PaneContentWire.prConversation(makeConversationPayload())
        )
    }

    func testPrConversationCasesDifferingByRepoAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.prConversation(makeConversationPayload()),
            PaneContentWire.prConversation(makeConversationPayload(repo: "acme/other"))
        )
    }

    func testPrConversationCasesDifferingByConversationErrorAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.prConversation(makeConversationPayload()),
            PaneContentWire.prConversation(makeConversationPayload(conversationError: "fetch failed"))
        )
    }

    /// Proves the hand-written `PaneContentWire ==` actually dispatches to
    /// `PrConversationPayload`'s own `Equatable` for this case rather than
    /// falling through to a `default: return false` arm that would make every
    /// `.prConversation` pair compare unequal regardless of content.
    func testPrConversationCasesReachPayloadEquatableRatherThanFallingThroughToDefault() {
        let a = PaneContentWire.prConversation(makeConversationPayload())
        let b = PaneContentWire.prConversation(makeConversationPayload())
        XCTAssertEqual(a, b, "identical .prConversation payloads must compare equal, not fall through to a conservative default")

        let differentThread = makeConversationThread(comments: [makeConversationComment(body: [.paragraph([.text("different")])])])
        let c = PaneContentWire.prConversation(makeConversationPayload(threads: [differentThread]))
        XCTAssertNotEqual(a, c, "a nested comment-body difference must be caught, not masked by a coarse default")
    }

    /// Proves nested `MdBlock`/comment/thread equality reaches down through
    /// `.prConversation`'s payload — not just the top-level string fields.
    func testPrConversationCasesWithStructurallyDifferentBodyOrThreadsAreNotEqual() {
        let differentBody = makeConversationPayload(body: [.codeBlock(lang: "rust", text: "fn main() {}")])
        XCTAssertNotEqual(
            PaneContentWire.prConversation(makeConversationPayload()),
            PaneContentWire.prConversation(differentBody),
            "a different rendered body block must be caught"
        )

        let differentThreadKind = makeConversationPayload(threads: [makeConversationThread(kind: .review)])
        XCTAssertNotEqual(
            PaneContentWire.prConversation(makeConversationPayload()),
            PaneContentWire.prConversation(differentThreadKind),
            "a different thread kind nested inside an otherwise-identical payload must be caught"
        )

        let differentCommentAuthor = makeConversationPayload(
            threads: [makeConversationThread(comments: [makeConversationComment(author: "bob")])]
        )
        XCTAssertNotEqual(
            PaneContentWire.prConversation(makeConversationPayload()),
            PaneContentWire.prConversation(differentCommentAuthor),
            "a different comment author nested two levels deep must be caught"
        )
    }

    func testPrConversationCaseNeverEqualsCodeDiffTextOrLoading() {
        let conversation = PaneContentWire.prConversation(makeConversationPayload())
        XCTAssertNotEqual(conversation, PaneContentWire.code(makeCodePayload()))
        XCTAssertNotEqual(conversation, PaneContentWire.diff(makeDiffPayload()))
        XCTAssertNotEqual(conversation, PaneContentWire.text("PR description"))
        XCTAssertNotEqual(conversation, PaneContentWire.loading)
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

    func testCodeCaseNeverEqualsDiffTextOrLoading() {
        let code = PaneContentWire.code(makeCodePayload())
        XCTAssertNotEqual(code, PaneContentWire.diff(makeDiffPayload()))
        XCTAssertNotEqual(code, PaneContentWire.text("let x = 1;"))
        XCTAssertNotEqual(code, PaneContentWire.loading)
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
