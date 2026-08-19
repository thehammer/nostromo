import XCTest
import AppKit

// `MarkdownBlockDocument`, `MdBlock`, `MdSpan`, `ConversationThreadModel`,
// `ConversationCommentModel`, `ConversationThreadKind` are compiled into this
// target directly (logic test — no host app, no `@testable import`), the
// same idiom as `CodeDocumentTests`/`DiffDocumentTests`.

/// Behavioural coverage for `MarkdownBlockDocument` — the block-model-to-
/// attributed-string renderer and the per-comment range arithmetic comment
/// anchoring depends on (W3 — curated-agent-views).
///
/// This is where the PRD's fenced-code-fidelity acceptance criterion actually
/// lives on the Swift side: "a PR description or comment containing a fenced
/// code block renders it as a code block, not as literal backticks and
/// unindented prose, with indentation preserved."
final class MarkdownBlockDocumentTests: XCTestCase {

    // MARK: - Fixture builders

    private func makeComment(
        id: String,
        author: String,
        createdAt: Date,
        text: String
    ) -> ConversationCommentModel {
        ConversationCommentModel(id: id, author: author, createdAt: createdAt, body: [.paragraph([.text(text)])])
    }

    private func makeThread(
        id: String,
        kind: ConversationThreadKind = .issue,
        comments: [ConversationCommentModel]
    ) -> ConversationThreadModel {
        ConversationThreadModel(
            id: id, kind: kind, path: nil, line: nil, diffHunk: nil, resolved: false, comments: comments
        )
    }

    // MARK: 1. Fenced code renders monospaced with indentation intact

    func testCodeBlockRendersMonospacedTextWithOriginalIndentationIntact() {
        let code = "fn foo() {\n    let x = 1;\n}"
        let doc = MarkdownBlockDocument(title: "", body: [.codeBlock(lang: "rust", text: code)], threads: [])

        let full = doc.attributedString.string as NSString
        let range = full.range(of: code)
        XCTAssertNotEqual(
            range.location, NSNotFound,
            "the code block's exact text, including its indented inner line, must appear verbatim in the rendered document"
        )
        XCTAssertEqual(
            full.substring(with: range), code,
            "the rendered code block substring must match the original text byte-for-byte, indentation included"
        )
    }

    func testCodeBlockWithoutALanguageStillPreservesIndentation() {
        let code = "line one\n  line two indented\n    line three more indented"
        let doc = MarkdownBlockDocument(title: "", body: [.codeBlock(lang: nil, text: code)], threads: [])

        let full = doc.attributedString.string as NSString
        let range = full.range(of: code)
        XCTAssertNotEqual(range.location, NSNotFound)
        XCTAssertEqual(full.substring(with: range), code)
    }

    // MARK: 2. Fenced code carries a distinct attribute from surrounding prose

    func testCodeBlockRunCarriesADistinctBackgroundColorFromSurroundingProse() {
        let code = "let distinguishable_code_marker = 1;"
        let doc = MarkdownBlockDocument(
            title: "",
            body: [
                .paragraph([.text("Some prose before the code.")]),
                .codeBlock(lang: nil, text: code),
                .paragraph([.text("Some prose after the code.")]),
            ],
            threads: []
        )

        let full = doc.attributedString.string as NSString
        let codeRange = full.range(of: code)
        let proseRange = full.range(of: "Some prose before the code.")
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        XCTAssertNotEqual(proseRange.location, NSNotFound)

        let codeBg = doc.attributedString.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
        let proseBg = doc.attributedString.attribute(.backgroundColor, at: proseRange.location, effectiveRange: nil) as? NSColor

        XCTAssertNotNil(
            codeBg,
            "a fenced code block's rendered run must carry a background-color attribute distinguishing it from prose"
        )
        XCTAssertNil(
            proseBg,
            "plain paragraph text must not carry a background-color attribute — otherwise it isn't distinguishable from a code block"
        )
    }

    // MARK: 3. A comment's range exactly brackets its own rendered content

    func testCommentRangeExactlyBracketsThatCommentsOwnRenderedContentAndDoesNotOverlapAnother() throws {
        let c1 = makeComment(id: "c1", author: "alice", createdAt: Date(timeIntervalSince1970: 0), text: "first comment unique marker alpha")
        let c2 = makeComment(id: "c2", author: "bob", createdAt: Date(timeIntervalSince1970: 100), text: "second comment unique marker beta")
        let thread = makeThread(id: "t1", comments: [c1, c2])
        let doc = MarkdownBlockDocument(title: "", body: [], threads: [thread])

        let range1 = try XCTUnwrap(doc.range(ofComment: "c1"))
        let range2 = try XCTUnwrap(doc.range(ofComment: "c2"))

        XCTAssertLessThanOrEqual(
            range1.location + range1.length, range2.location,
            "comment 1's range must end at or before comment 2's range begins — the two must not overlap"
        )

        let full = doc.attributedString.string as NSString
        let text1 = full.substring(with: range1)
        let text2 = full.substring(with: range2)

        XCTAssertTrue(text1.contains("alice"))
        XCTAssertTrue(text1.contains("first comment unique marker alpha"))
        XCTAssertFalse(text1.contains("second comment unique marker beta"), "comment 1's range must not bleed into comment 2's content")

        XCTAssertTrue(text2.contains("bob"))
        XCTAssertTrue(text2.contains("second comment unique marker beta"))
        XCTAssertFalse(text2.contains("first comment unique marker alpha"), "comment 2's range must not include comment 1's content")
    }

    // MARK: 4. range(ofComment:) is nil for an id not present

    func testRangeOfCommentReturnsNilForAnIdNotInTheDocument() {
        let c1 = makeComment(id: "c1", author: "alice", createdAt: Date(), text: "the only comment")
        let thread = makeThread(id: "t1", comments: [c1])
        let doc = MarkdownBlockDocument(title: "", body: [], threads: [thread])

        XCTAssertNil(doc.range(ofComment: "does-not-exist"))
    }

    // MARK: 5. Comments render in thread order, then comment order within thread

    func testCommentsRenderInThreadOrderThenCommentOrderWithinThread() {
        let t1c1 = makeComment(id: "t1-c1", author: "a", createdAt: Date(timeIntervalSince1970: 0), text: "one")
        let t1c2 = makeComment(id: "t1-c2", author: "b", createdAt: Date(timeIntervalSince1970: 1), text: "two")
        let t2c1 = makeComment(id: "t2-c1", author: "c", createdAt: Date(timeIntervalSince1970: 2), text: "three")
        let thread1 = makeThread(id: "thread-1", comments: [t1c1, t1c2])
        let thread2 = makeThread(id: "thread-2", kind: .review, comments: [t2c1])

        let doc = MarkdownBlockDocument(title: "", body: [], threads: [thread1, thread2])

        XCTAssertEqual(doc.commentOrder, ["t1-c1", "t1-c2", "t2-c1"])
    }

    // MARK: 6. Nested markdown renders without crashing

    func testNestedMarkdownRendersWithoutCrashingAndProducesNonEmptyText() {
        let nested: [MdBlock] = [
            .paragraph([.strong([.text("bold intro")])]),
            .list(ordered: false, start: nil, items: [
                [.paragraph([.text("item one")])],
                [
                    .paragraph([.text("item two")]),
                    .list(ordered: true, start: 1, items: [[.paragraph([.text("nested sub-item")])]]),
                ],
            ]),
            .quote([.paragraph([.text("quoted paragraph")])]),
        ]

        let doc = MarkdownBlockDocument(title: "", body: nested, threads: [])
        let rendered = doc.attributedString.string

        XCTAssertFalse(rendered.isEmpty)
        XCTAssertTrue(rendered.contains("bold intro"))
        XCTAssertTrue(rendered.contains("item one"))
        XCTAssertTrue(rendered.contains("nested sub-item"))
        XCTAssertTrue(rendered.contains("quoted paragraph"))
    }

    // MARK: 7. A link span renders its visible text, not the raw URL

    func testLinkSpanRendersVisibleTextNotTheRawURLAndCarriesTheLinkAttribute() {
        let url = "https://example.com/docs/some-very-long-path"
        let doc = MarkdownBlockDocument(
            title: "",
            body: [.paragraph([.link(spans: [.text("Nostromo docs")], url: url)])],
            threads: []
        )

        let rendered = doc.attributedString.string
        XCTAssertTrue(rendered.contains("Nostromo docs"), "the link's visible text must render")
        XCTAssertFalse(rendered.contains(url), "the raw URL must not be dumped inline alongside the visible text")

        let full = doc.attributedString.string as NSString
        let range = full.range(of: "Nostromo docs")
        XCTAssertNotEqual(range.location, NSNotFound)
        let linkAttr = doc.attributedString.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(linkAttr, URL(string: url))
    }

    // MARK: 8. An image span renders a readable alt-text placeholder

    func testImageSpanRendersReadableAltTextPlaceholder() {
        let doc = MarkdownBlockDocument(
            title: "",
            body: [.paragraph([.image(alt: "screenshot of the failing test", url: "https://example.com/shot.png")])],
            threads: []
        )

        XCTAssertTrue(doc.attributedString.string.contains("screenshot of the failing test"))
    }

    func testImageSpanWithNoAltTextStillRendersANonBlankPlaceholder() {
        let doc = MarkdownBlockDocument(
            title: "",
            body: [.paragraph([.image(alt: "", url: "https://example.com/shot.png")])],
            threads: []
        )

        let rendered = doc.attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(rendered.isEmpty, "an image with no alt text must still render a visible placeholder, not blank")
    }

    // MARK: 9. An empty body with no threads still produces a valid document

    func testEmptyBodyWithNoThreadsProducesAValidDocumentWithNoCrash() {
        let doc = MarkdownBlockDocument(title: "", body: [], threads: [])

        XCTAssertEqual(doc.attributedString.length, 0)
        XCTAssertEqual(doc.commentRanges, [:])
        XCTAssertEqual(doc.commentOrder, [])
    }

    func testTitleOnlyDocumentWithEmptyBodyAndNoThreadsRendersTheTitleWithNoComments() {
        let doc = MarkdownBlockDocument(title: "My Great PR", body: [], threads: [])

        XCTAssertTrue(doc.attributedString.string.contains("My Great PR"))
        XCTAssertEqual(doc.commentRanges, [:])
        XCTAssertEqual(doc.commentOrder, [])
    }

    // MARK: 10. Equatable

    func testTwoDocumentsBuiltFromIdenticalInputsAreEqual() {
        let comment = makeComment(id: "c1", author: "alice", createdAt: Date(timeIntervalSince1970: 0), text: "same text")
        let thread = makeThread(id: "t1", comments: [comment])
        let body: [MdBlock] = [.paragraph([.text("body text")]), .codeBlock(lang: "swift", text: "let x = 1")]

        let doc1 = MarkdownBlockDocument(title: "Title", body: body, threads: [thread])
        let doc2 = MarkdownBlockDocument(title: "Title", body: body, threads: [thread])

        XCTAssertEqual(doc1, doc2)
    }

    func testTwoDocumentsDifferingByTitleAreNotEqual() {
        let doc1 = MarkdownBlockDocument(title: "Title A", body: [], threads: [])
        let doc2 = MarkdownBlockDocument(title: "Title B", body: [], threads: [])

        XCTAssertNotEqual(doc1, doc2)
    }

    func testTwoDocumentsDifferingByCommentContentAreNotEqual() {
        let commentA = makeComment(id: "c1", author: "alice", createdAt: Date(timeIntervalSince1970: 0), text: "version A")
        let commentB = makeComment(id: "c1", author: "alice", createdAt: Date(timeIntervalSince1970: 0), text: "version B")

        let doc1 = MarkdownBlockDocument(title: "", body: [], threads: [makeThread(id: "t1", comments: [commentA])])
        let doc2 = MarkdownBlockDocument(title: "", body: [], threads: [makeThread(id: "t1", comments: [commentB])])

        XCTAssertNotEqual(doc1, doc2)
    }
}
