import XCTest
import NostromoKit

// `PaneContentWire`, `PaneTree`, `SplitDirection`, `FocusLayoutModel` are
// macOS-local types declared in Models.swift and compiled into this test
// target directly (logic test — no host app, same as PerriModelTests /
// MotherBrokerClientTests). They intentionally shadow NostromoKit's
// identically-named types within this module — see the header comment on
// Shared/NostromoKit/Sources/NostromoKit/Wire/PaneLayout.swift.
//
// `PrListItemModel` is NOT shadowed locally, so it resolves to
// `NostromoKit.PrListItemModel` here — hence the explicit `import NostromoKit`
// and the fully-qualified `NostromoKit.CiState` below (the macOS module also
// declares its own, unrelated, local `CiState` enum for `PRQueueItem`, so an
// unqualified `CiState` here would resolve to the WRONG type and fail to
// compile against `PrListItemModel.ciState`).
//
// Per-field equality coverage for `PrListItemModel` itself lives in
// Shared/NostromoKit/Tests/NostromoKitTests/PaneContentWireTests.swift, since
// that's the only module where the type is actually declared. This file only
// covers the macOS-local `PaneContentWire`'s own Equatable contract.

// MARK: - PaneContentWireEqualityTests

/// Equality-contract tests for the macOS-local `PaneContentWire` (Models.swift).
/// Mirrors the equivalent NostromoKit suite in `PaneContentWireTests.swift` —
/// the two `PaneContentWire` types are separate, deliberately-duplicated
/// copies; this file exercises only the macOS one.
final class PaneContentWireEqualityTests: XCTestCase {

    private func makeItem(
        title: String = "feat: auth"
    ) -> PrListItemModel {
        PrListItemModel(
            repo: "acme/web",
            number: 42,
            title: title,
            author: "alice",
            bucket: "requested",
            ciState: NostromoKit.CiState.success,
            newActivity: true,
            url: "https://github.com/acme/web/pull/42",
            headSha: "abc123"
        )
    }

    // MARK: - .text

    func testTextCasesWithSameStringAreEqual() {
        XCTAssertEqual(PaneContentWire.text("hello"), PaneContentWire.text("hello"))
    }

    func testTextCasesWithDifferentStringsAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.text("goodbye"))
    }

    // MARK: - .loading

    func testLoadingCasesAreAlwaysEqual() {
        XCTAssertEqual(PaneContentWire.loading, PaneContentWire.loading)
    }

    // MARK: - .error

    func testErrorCasesWithSameMessageAreEqual() {
        XCTAssertEqual(PaneContentWire.error("boom"), PaneContentWire.error("boom"))
    }

    func testErrorCasesWithDifferentMessagesAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.error("kaboom"))
    }

    // MARK: - .prList

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

    // MARK: - .jsonSnapshot
    //
    // Formerly "(conservative 'always changed')": `.jsonSnapshot` carried an
    // uncomparable `Any` and hard-coded `==` to `false` for every pair — a
    // deliberate "report changed rather than risk a false unchanged" choice.
    // That trade-off only made sense while equality was actually impossible
    // to compute. Now that the payload is a real Equatable `JSONValue`, the
    // conservative choice just costs a spurious re-render of every pane in
    // every window on every daemon push, so it's reversed below.

    func testJsonSnapshotCasesWithIdenticalPayloadsAreEqual() {
        let payload = JSONValue.object(["x": .int(1)])
        let lhs = PaneContentWire.jsonSnapshot(payload)
        let rhs = PaneContentWire.jsonSnapshot(payload)
        XCTAssertEqual(
            lhs, rhs,
            "identical .jsonSnapshot payloads must compare equal now that the payload is a real " +
            "Equatable JSONValue rather than uncomparable Any — comparing unequal here forces a " +
            "spurious re-render of every pane in every window on every daemon push."
        )
    }

    func testJsonSnapshotPayloadsDifferingByALeafValueAreNotEqual() {
        let a = PaneContentWire.jsonSnapshot(.object(["x": .object(["y": .int(1)])]))
        let b = PaneContentWire.jsonSnapshot(.object(["x": .object(["y": .int(2)])]))
        XCTAssertNotEqual(a, b, "a changed leaf value nested inside .jsonSnapshot must be caught")
    }

    func testJsonSnapshotPayloadsDifferingByAMissingKeyAreNotEqual() {
        let a = PaneContentWire.jsonSnapshot(.object(["x": .int(1), "y": .int(2)]))
        let b = PaneContentWire.jsonSnapshot(.object(["x": .int(1)]))
        XCTAssertNotEqual(a, b, "a key missing from one .jsonSnapshot payload must be caught")
    }

    func testJsonSnapshotPayloadsDifferingByAnExtraKeyAreNotEqual() {
        let a = PaneContentWire.jsonSnapshot(.object(["x": .int(1)]))
        let b = PaneContentWire.jsonSnapshot(.object(["x": .int(1), "y": .int(2)]))
        XCTAssertNotEqual(a, b, "a key present in only one .jsonSnapshot payload must be caught")
    }

    func testJsonSnapshotPayloadsWithAReorderedArrayAreNotEqual() {
        // Arrays are ordered (unlike object keys) — reordering IS a content change.
        let a = PaneContentWire.jsonSnapshot(.array([.int(1), .int(2)]))
        let b = PaneContentWire.jsonSnapshot(.array([.int(2), .int(1)]))
        XCTAssertNotEqual(a, b, "a reordered array nested inside .jsonSnapshot must be caught")
    }

    // MARK: - .unknown
    //
    // Same inversion, same reasoning, as `.jsonSnapshot` above.

    func testUnknownCasesWithIdenticalPayloadsAreEqual() {
        let payload = JSONValue.object(["future_field": .string("value")])
        let lhs = PaneContentWire.unknown(payload)
        let rhs = PaneContentWire.unknown(payload)
        XCTAssertEqual(
            lhs, rhs,
            "identical .unknown payloads must compare equal now that the payload is a real " +
            "Equatable JSONValue rather than uncomparable Any — comparing unequal here forces a " +
            "spurious re-render of every pane in every window on every daemon push."
        )
    }

    func testUnknownPayloadsDifferingByALeafValueAreNotEqual() {
        let a = PaneContentWire.unknown(.object(["x": .object(["y": .int(1)])]))
        let b = PaneContentWire.unknown(.object(["x": .object(["y": .int(2)])]))
        XCTAssertNotEqual(a, b, "a changed leaf value nested inside .unknown must be caught")
    }

    func testUnknownPayloadsDifferingByAMissingKeyAreNotEqual() {
        let a = PaneContentWire.unknown(.object(["x": .int(1), "y": .int(2)]))
        let b = PaneContentWire.unknown(.object(["x": .int(1)]))
        XCTAssertNotEqual(a, b, "a key missing from one .unknown payload must be caught")
    }

    func testUnknownPayloadsDifferingByAnExtraKeyAreNotEqual() {
        let a = PaneContentWire.unknown(.object(["x": .int(1)]))
        let b = PaneContentWire.unknown(.object(["x": .int(1), "y": .int(2)]))
        XCTAssertNotEqual(a, b, "a key present in only one .unknown payload must be caught")
    }

    func testUnknownPayloadsWithAReorderedArrayAreNotEqual() {
        let a = PaneContentWire.unknown(.array([.int(1), .int(2)]))
        let b = PaneContentWire.unknown(.array([.int(2), .int(1)]))
        XCTAssertNotEqual(a, b, "a reordered array nested inside .unknown must be caught")
    }

    // MARK: - .jsonSnapshot decoding (JSONValue — the real object-payload bug)

    /// The single most important test in this file. `AnyDecodable` (the type
    /// `JSONValue` replaces) had no keyed-container branch at all, so any JSON
    /// *object* payload fell through every `try?` in its `init(from:)` and
    /// silently decoded to `""` — a real rendering bug, not just an equality
    /// defect. This proves a nested object decodes to its actual structure.
    func testJsonSnapshotDecodesAJSONObjectRatherThanCollapsingToAnEmptyValue() throws {
        let json = """
        {"kind":"json_snapshot","value":{"a":1,"b":{"c":[1,2,3]}}}
        """
        let wire = try decode(json)
        guard case .jsonSnapshot(let value) = wire else {
            XCTFail("Expected .jsonSnapshot, got \(wire)")
            return
        }
        let expected = JSONValue.object([
            "a": .int(1),
            "b": .object(["c": .array([.int(1), .int(2), .int(3)])]),
        ])
        XCTAssertEqual(value, expected, """
            AnyDecodable/JSONValue has no keyed-container branch — JSON objects must not \
            collapse to an empty value.
            """)
    }

    func testJsonSnapshotDecodesAnArrayOfObjects() throws {
        let json = """
        {"kind":"json_snapshot","value":[{"id":1},{"id":2}]}
        """
        let wire = try decode(json)
        guard case .jsonSnapshot(let value) = wire else {
            XCTFail("Expected .jsonSnapshot, got \(wire)")
            return
        }
        XCTAssertEqual(value, .array([.object(["id": .int(1)]), .object(["id": .int(2)])]))
    }

    func testJsonSnapshotDecodesEveryScalarType() throws {
        let json = """
        {"kind":"json_snapshot","value":{"s":"hello","i":42,"d":3.5,"b":true}}
        """
        let wire = try decode(json)
        guard case .jsonSnapshot(let value) = wire else {
            XCTFail("Expected .jsonSnapshot, got \(wire)")
            return
        }
        XCTAssertEqual(value, .object([
            "s": .string("hello"),
            "i": .int(42),
            "d": .double(3.5),
            "b": .bool(true),
        ]))
    }

    func testJsonSnapshotDecodesJSONNullAsDotNullNotAsAString() throws {
        let json = """
        {"kind":"json_snapshot","value":{"x":null}}
        """
        let wire = try decode(json)
        guard case .jsonSnapshot(let value) = wire else {
            XCTFail("Expected .jsonSnapshot, got \(wire)")
            return
        }
        XCTAssertEqual(value, .object(["x": .null]),
                       "JSON null must decode to .null, not to an empty string or a dropped key")
    }

    /// Sibling of `testAPrConversationShapedPayloadWithAnUnrecognisedKindStringDecodesToUnknown`:
    /// a `json_snapshot`-shaped frame with a garbled/unrecognised `kind` must still
    /// decode to `.unknown` holding a real `JSONValue` for the whole frame, not throw.
    func testAJsonSnapshotShapedPayloadWithAnUnrecognisedKindStringDecodesToUnknownHoldingARealValue() throws {
        let json = """
        {"kind":"json_snapshot_v2","value":{"a":1}}
        """
        let wire = try decode(json)
        guard case .unknown(let value) = wire else {
            XCTFail("Expected .unknown for an unrecognised kind string, got \(wire)")
            return
        }
        XCTAssertEqual(
            value,
            .object(["kind": .string("json_snapshot_v2"), "value": .object(["a": .int(1)])]),
            "an unrecognised kind must still decode the whole frame into a real JSONValue " +
            "rather than throwing or collapsing to an empty value"
        )
    }

    // MARK: - .code (W2 — curated-agent-views)

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

    // MARK: - .diff (W2 — curated-agent-views)

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

    // MARK: - .prConversation (W3 — curated-agent-views)

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

    // MARK: - .prConversation decoding (W3 — curated-agent-views)

    private let decoder = JSONDecoder()

    private func decode(_ jsonString: String) throws -> PaneContentWire {
        try decoder.decode(PaneContentWire.self, from: Data(jsonString.utf8))
    }

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

    /// Sibling of `testAFutureContentKindNotYetKnownDecodesToUnknownJustLikeAnyOtherUnrecognisedKind`
    /// in the NostromoKit test suite: proves that a `pr_conversation`-shaped
    /// payload with a mangled/unrecognised `kind` string still degrades to
    /// `.unknown` rather than throwing.
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

    func testAPayloadMissingTheKindKeyEntirelyThrowsRatherThanDecodingToPrConversation() {
        let json = """
        {
            "repo": "acme/web",
            "number": 42,
            "title": "feat: add auth",
            "author": "alice",
            "url": "https://github.com/acme/web/pull/42",
            "body": [],
            "threads": []
        }
        """

        XCTAssertThrowsError(try decode(json), "a frame with no kind discriminator at all must not silently decode as any known case")
    }

    // MARK: - .ticket (W4 — curated-agent-views)

    private func makeTicketSection(
        name: String = "description",
        heading: [MdSpan]? = nil,
        blocks: [MdBlock]? = nil
    ) -> TicketSectionModel {
        TicketSectionModel(name: name, heading: heading, blocks: blocks ?? [.paragraph([.text("section body")])])
    }

    private func makeTicketComment(
        index: Int = 1,
        author: String = "alice",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        blocks: [MdBlock]? = nil
    ) -> TicketCommentModel {
        TicketCommentModel(index: index, author: author, createdAt: createdAt, blocks: blocks ?? [.paragraph([.text("comment body")])])
    }

    private func makeTicketPayload(
        provider: String = "jira",
        key: String = "PROJ-42",
        summary: String = "Fix the login bug",
        status: String = "In Progress",
        assignee: String? = "alice",
        url: String = "https://example.atlassian.net/browse/PROJ-42",
        sections: [TicketSectionModel]? = nil,
        comments: [TicketCommentModel]? = nil
    ) -> TicketPayload {
        TicketPayload(
            provider: provider, key: key, summary: summary, status: status, assignee: assignee, url: url,
            sections: sections ?? [makeTicketSection()], comments: comments ?? [makeTicketComment()]
        )
    }

    func testTicketCasesWithIdenticalPayloadsAreEqual() {
        XCTAssertEqual(
            PaneContentWire.ticket(makeTicketPayload()),
            PaneContentWire.ticket(makeTicketPayload())
        )
    }

    func testTicketCasesDifferingByKeyAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.ticket(makeTicketPayload()),
            PaneContentWire.ticket(makeTicketPayload(key: "PROJ-43"))
        )
    }

    func testTicketCasesDifferingBySummaryAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.ticket(makeTicketPayload()),
            PaneContentWire.ticket(makeTicketPayload(summary: "A different summary entirely"))
        )
    }

    /// Proves nested `TicketSectionModel`/`TicketCommentModel` equality reaches
    /// down through `.ticket`'s payload — not just the top-level string fields.
    func testTicketCasesWithStructurallyDifferentSectionsOrCommentsAreNotEqual() {
        let differentSectionHeading = makeTicketPayload(sections: [
            makeTicketSection(name: "acceptance_criteria", heading: [.text("Acceptance Criteria")]),
        ])
        XCTAssertNotEqual(
            PaneContentWire.ticket(makeTicketPayload()),
            PaneContentWire.ticket(differentSectionHeading),
            "a different section heading nested inside an otherwise-identical payload must be caught"
        )

        let differentCommentAuthor = makeTicketPayload(comments: [makeTicketComment(author: "bob")])
        XCTAssertNotEqual(
            PaneContentWire.ticket(makeTicketPayload()),
            PaneContentWire.ticket(differentCommentAuthor),
            "a different comment author nested inside an otherwise-identical payload must be caught"
        )
    }

    // MARK: - .ticket decoding (W4 — curated-agent-views)

    func testTicketDecodesEveryFieldFromWireFormatJSON() throws {
        let json = """
        {
            "kind": "ticket",
            "provider": "jira",
            "key": "PROJ-42",
            "summary": "Fix the login bug",
            "status": "In Progress",
            "assignee": "alice",
            "url": "https://example.atlassian.net/browse/PROJ-42",
            "sections": [
                {
                    "name": "description",
                    "blocks": [
                        { "kind": "paragraph", "spans": [{ "kind": "text", "text": "This is the description." }] }
                    ]
                },
                {
                    "name": "acceptance_criteria",
                    "heading": [{ "kind": "text", "text": "Acceptance Criteria" }],
                    "blocks": [
                        {
                            "kind": "list", "ordered": false,
                            "items": [[{ "kind": "paragraph", "spans": [{ "kind": "text", "text": "Criterion one" }] }]]
                        }
                    ]
                }
            ],
            "comments": [
                {
                    "index": 1,
                    "author": "bob",
                    "created_at": "2026-05-30T09:30:56.510874Z",
                    "blocks": [{ "kind": "paragraph", "spans": [{ "kind": "text", "text": "Looks fine." }] }]
                }
            ]
        }
        """

        let wire = try decode(json)

        guard case .ticket(let payload) = wire else {
            XCTFail("Expected .ticket, got \(wire)")
            return
        }

        XCTAssertEqual(payload.provider, "jira")
        XCTAssertEqual(payload.key, "PROJ-42")
        XCTAssertEqual(payload.summary, "Fix the login bug")
        XCTAssertEqual(payload.status, "In Progress")
        XCTAssertEqual(payload.assignee, "alice")
        XCTAssertEqual(payload.url, "https://example.atlassian.net/browse/PROJ-42")

        XCTAssertEqual(payload.sections.count, 2)
        XCTAssertEqual(payload.sections[0].name, "description")
        XCTAssertNil(payload.sections[0].heading)
        XCTAssertEqual(payload.sections[0].blocks, [.paragraph([.text("This is the description.")])])

        XCTAssertEqual(payload.sections[1].name, "acceptance_criteria")
        XCTAssertEqual(payload.sections[1].heading, [.text("Acceptance Criteria")])
        XCTAssertEqual(
            payload.sections[1].blocks,
            [.list(ordered: false, start: nil, items: [[.paragraph([.text("Criterion one")])]])]
        )

        XCTAssertEqual(payload.comments.count, 1)
        XCTAssertEqual(payload.comments[0].index, 1)
        XCTAssertEqual(payload.comments[0].author, "bob")
        XCTAssertEqual(payload.comments[0].blocks, [.paragraph([.text("Looks fine.")])])

        // Equal to the value constructed directly, not just field-by-field.
        let expected = TicketPayload(
            provider: "jira", key: "PROJ-42", summary: "Fix the login bug", status: "In Progress",
            assignee: "alice", url: "https://example.atlassian.net/browse/PROJ-42",
            sections: [
                TicketSectionModel(
                    name: "description", heading: nil,
                    blocks: [.paragraph([.text("This is the description.")])]
                ),
                TicketSectionModel(
                    name: "acceptance_criteria", heading: [.text("Acceptance Criteria")],
                    blocks: [.list(ordered: false, start: nil, items: [[.paragraph([.text("Criterion one")])]])]
                ),
            ],
            comments: [
                TicketCommentModel(
                    index: 1, author: "bob", createdAt: payload.comments[0].createdAt,
                    blocks: [.paragraph([.text("Looks fine.")])]
                ),
            ]
        )
        XCTAssertEqual(wire, PaneContentWire.ticket(expected))
    }

    // MARK: - Cross-case inequality

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

    func testPrConversationCaseNeverEqualsCodeDiffTextOrLoading() {
        let conversation = PaneContentWire.prConversation(makeConversationPayload())
        XCTAssertNotEqual(conversation, PaneContentWire.code(makeCodePayload()))
        XCTAssertNotEqual(conversation, PaneContentWire.diff(makeDiffPayload()))
        XCTAssertNotEqual(conversation, PaneContentWire.text("PR description"))
        XCTAssertNotEqual(conversation, PaneContentWire.loading)
    }

    func testTicketCaseNeverEqualsCodeOrPrConversationOrLoading() {
        let ticket = PaneContentWire.ticket(makeTicketPayload())
        XCTAssertNotEqual(ticket, PaneContentWire.code(makeCodePayload()))
        XCTAssertNotEqual(ticket, PaneContentWire.prConversation(makeConversationPayload()))
        XCTAssertNotEqual(ticket, PaneContentWire.text("Fix the login bug"))
        XCTAssertNotEqual(ticket, PaneContentWire.loading)
    }
}
