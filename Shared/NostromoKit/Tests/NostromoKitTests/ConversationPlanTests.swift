import XCTest
@testable import NostromoKit

// L1 coverage for `ConversationPlan(payload:)` (ios-curated-view-parity W9,
// D2/D3) — thread grouping, inline/resolved badging, and the
// `conversationError` notice. These assertions port the spirit of
// `MarkdownBlockDocumentTests` (macOS/NostromoTests) from character-range
// arithmetic to row-index/row-kind sequence assertions.

final class ConversationPlanTests: XCTestCase {

    // MARK: - Fixture builders

    private func comment(
        id: String,
        author: String = "alice",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        text: String = "comment body"
    ) -> ConversationCommentModel {
        ConversationCommentModel(id: id, author: author, createdAt: createdAt, body: [.paragraph([.text(text)])])
    }

    private func thread(
        id: String,
        kind: ConversationThreadKind = .issue,
        path: String? = nil,
        line: Int? = nil,
        diffHunk: String? = nil,
        resolved: Bool = false,
        comments: [ConversationCommentModel]
    ) -> ConversationThreadModel {
        ConversationThreadModel(id: id, kind: kind, path: path, line: line, diffHunk: diffHunk, resolved: resolved, comments: comments)
    }

    private func payload(
        title: String = "A great PR",
        author: String = "octocat",
        url: String = "https://github.com/acme/web/pull/1",
        body: [MdBlock] = [],
        threads: [ConversationThreadModel] = [],
        conversationError: String? = nil
    ) -> PrConversationPayload {
        PrConversationPayload(
            repo: "acme/web", number: 1, title: title, author: author, url: url,
            body: body, threads: threads, conversationError: conversationError
        )
    }

    // MARK: - Title, author, description, threads

    func testPlanRendersTheDocumentHeaderWithTitleAuthorAndUrl() {
        let plan = ConversationPlan(payload: payload(title: "Fix the flaky test", author: "octocat", url: "https://github.com/acme/web/pull/9"))
        guard case .documentHeader(let header) = plan.rows[0].kind else {
            return XCTFail("expected rows[0] to be .documentHeader")
        }
        XCTAssertEqual(header.title, "Fix the flaky test")
        XCTAssertEqual(header.author, "octocat")
        XCTAssertEqual(header.url, "https://github.com/acme/web/pull/9")
        XCTAssertNil(header.key, "a PR conversation header has no ticket key")
    }

    func testPlanRendersTheDescriptionBody() {
        let plan = ConversationPlan(payload: payload(body: [
            .heading(level: 2, spans: [.text("Summary")]),
            .paragraph([.text("This PR fixes the flaky test.")]),
        ]))
        XCTAssertTrue(plan.rows.contains { $0.kind == .heading(level: 2) && $0.spans == [.text("Summary")] })
        XCTAssertTrue(plan.rows.contains { $0.kind == .paragraph && $0.spans == [.text("This PR fixes the flaky test.")] })
    }

    // MARK: - Threads are groups: no interleaving

    func testThreadsRenderAsGroupsInThreadOrderThenCommentOrderWithNoInterleaving() {
        let t1c1 = comment(id: "t1-c1", text: "one")
        let t1c2 = comment(id: "t1-c2", text: "two")
        let t2c1 = comment(id: "t2-c1", text: "three")
        let t2c2 = comment(id: "t2-c2", text: "four")
        let thread1 = thread(id: "thread-1", comments: [t1c1, t1c2])
        let thread2 = thread(id: "thread-2", kind: .review, comments: [t2c1, t2c2])

        let plan = ConversationPlan(payload: payload(threads: [thread1, thread2]))

        // rows[0] is the document header; walk the rest and assert the exact
        // kind sequence, so a thread's comments can never bleed into another
        // thread's group.
        let kinds = Array(plan.rows.dropFirst().map(\.kind))
        // 2 threadHeaders + 4 commentHeaders + 4 one-paragraph comment bodies.
        XCTAssertEqual(kinds.count, 10)
        var i = kinds.startIndex
        func expectThreadHeader() {
            guard case .threadHeader = kinds[i] else { return XCTFail("expected threadHeader at \(i), got \(kinds[i])") }
            i += 1
        }
        func expectCommentHeader() {
            guard case .commentHeader = kinds[i] else { return XCTFail("expected commentHeader at \(i), got \(kinds[i])") }
            i += 1
        }
        func expectParagraph() {
            XCTAssertEqual(kinds[i], .paragraph, "expected paragraph body at \(i)")
            i += 1
        }
        expectThreadHeader()   // thread-1
        expectCommentHeader(); expectParagraph() // t1-c1
        expectCommentHeader(); expectParagraph() // t1-c2
        expectThreadHeader()   // thread-2
        expectCommentHeader(); expectParagraph() // t2-c1
        expectCommentHeader(); expectParagraph() // t2-c2
    }

    func testCommentOrderIsThreadOrderThenCommentOrderWithinThread() {
        let t1c1 = comment(id: "t1-c1")
        let t1c2 = comment(id: "t1-c2")
        let t2c1 = comment(id: "t2-c1")
        let thread1 = thread(id: "thread-1", comments: [t1c1, t1c2])
        let thread2 = thread(id: "thread-2", kind: .review, comments: [t2c1])

        let plan = ConversationPlan(payload: payload(threads: [thread1, thread2]))
        XCTAssertEqual(plan.commentOrder, ["t1-c1", "t1-c2", "t2-c1"])
    }

    // MARK: - An inline thread's header carries path/line; a general thread's does not

    func testInlineThreadHeaderCarriesPathAndLineAndAGeneralIssueThreadDoesNot() {
        // This is the exact criterion `MarkdownBlockDocument` fails: it
        // decodes `path`/`line` on `ConversationThreadModel` and renders
        // neither, so an inline review comment looks identical to a general
        // PR comment (`MarkdownBlockDocument.swift:29-58`). Here the two
        // `ThreadHeader` values must differ, distinguishable from the row alone.
        let issueThread = thread(id: "issue-1", kind: .issue, comments: [comment(id: "c1")])
        let inlineThread = thread(id: "inline-1", kind: .inline, path: "src/session_manager.rs", line: 412, comments: [comment(id: "c2")])

        let plan = ConversationPlan(payload: payload(threads: [issueThread, inlineThread]))

        let headers = plan.rows.compactMap { row -> ThreadHeader? in
            guard case .threadHeader(let h) = row.kind else { return nil }
            return h
        }
        XCTAssertEqual(headers.count, 2)
        let issueHeader = headers[0]
        let inlineHeader = headers[1]

        XCTAssertNil(issueHeader.path)
        XCTAssertNil(issueHeader.line)
        XCTAssertEqual(inlineHeader.path, "src/session_manager.rs")
        XCTAssertEqual(inlineHeader.line, 412)
        XCTAssertNotEqual(issueHeader, inlineHeader)
    }

    func testReviewThreadKindIsDistinguishableFromInlineAndIssue() {
        let plan = ConversationPlan(payload: payload(threads: [
            thread(id: "r1", kind: .review, comments: [comment(id: "c1")]),
        ]))
        guard case .threadHeader(let header) = plan.rows[1].kind else {
            return XCTFail("expected a threadHeader row")
        }
        XCTAssertEqual(header.kind, .review)
        XCTAssertNotEqual(header.kind, .inline)
        XCTAssertNotEqual(header.kind, .issue)
    }

    // MARK: - Resolved state

    func testResolvedThreadHeaderCarriesResolvedTrueAndUnresolvedCarriesFalse() {
        let resolvedThread = thread(id: "t1", resolved: true, comments: [comment(id: "c1")])
        let unresolvedThread = thread(id: "t2", resolved: false, comments: [comment(id: "c2")])

        let plan = ConversationPlan(payload: payload(threads: [resolvedThread, unresolvedThread]))
        let headers = plan.rows.compactMap { row -> ThreadHeader? in
            guard case .threadHeader(let h) = row.kind else { return nil }
            return h
        }
        XCTAssertEqual(headers.count, 2)
        XCTAssertTrue(headers[0].resolved)
        XCTAssertFalse(headers[1].resolved)
    }

    // MARK: - conversationError notice: present vs. absent

    func testConversationErrorSetProducesExactlyOneNoticeRowBeforeTheFirstThreadHeaderCarryingTheErrorTextVerbatim() {
        let plan = ConversationPlan(payload: payload(
            threads: [thread(id: "t1", comments: [comment(id: "c1")])],
            conversationError: "fetching the conversation timed out after 30s"
        ))

        let noticeIndices = plan.rows.indices.filter { row in
            if case .notice = plan.rows[row].kind { return true }
            return false
        }
        XCTAssertEqual(noticeIndices.count, 1, "exactly one notice row must be produced")

        guard case .notice(.conversationIncomplete(let reason)) = plan.rows[noticeIndices[0]].kind else {
            return XCTFail("expected .notice(.conversationIncomplete)")
        }
        XCTAssertEqual(reason, "fetching the conversation timed out after 30s")

        let firstThreadHeaderIndex = plan.rows.firstIndex { row in
            if case .threadHeader = row.kind { return true }
            return false
        }
        XCTAssertNotNil(firstThreadHeaderIndex)
        XCTAssertLessThan(noticeIndices[0], firstThreadHeaderIndex!, "the notice must sit before the first thread — where the missing threads would have been")
    }

    func testConversationErrorAbsentProducesNoNoticeRowAtAll() {
        // Asserted separately from the "renders when set" test above: a
        // permanent warning on every healthy PR would be exactly as
        // dishonest as no warning on an incomplete one.
        let plan = ConversationPlan(payload: payload(
            threads: [thread(id: "t1", comments: [comment(id: "c1")])],
            conversationError: nil
        ))
        let hasNotice = plan.rows.contains { row in
            if case .notice = row.kind { return true }
            return false
        }
        XCTAssertFalse(hasNotice, "conversationError absent must produce no notice row at all")
    }

    func testConversationErrorSetTogetherWithThreadsStillRendersBothTheNoticeAndAllTheThreadRows() {
        let plan = ConversationPlan(payload: payload(
            threads: [thread(id: "t1", comments: [comment(id: "c1", text: "partial thread survives")])],
            conversationError: "partial fetch"
        ))

        let hasNotice = plan.rows.contains { row in
            if case .notice(.conversationIncomplete(let reason)) = row.kind { return reason == "partial fetch" }
            return false
        }
        XCTAssertTrue(hasNotice, "the notice must appear")

        let hasThreadHeader = plan.rows.contains { row in
            if case .threadHeader(let h) = row.kind { return h.threadId == "t1" }
            return false
        }
        XCTAssertTrue(hasThreadHeader, "the partial thread's rows must still appear after the notice")

        let hasCommentBody = plan.rows.contains { $0.spans == [.text("partial thread survives")] }
        XCTAssertTrue(hasCommentBody, "the thread's own comment content must still render — the notice states incompleteness, it does not replace the content")
    }

    // MARK: - A thread with zero comments produces only its header row

    func testThreadWithZeroCommentsProducesOnlyItsHeaderRowAndNoOrphanRows() {
        let emptyThread = thread(id: "empty-thread", comments: [])
        let nextThread = thread(id: "next-thread", comments: [comment(id: "c1")])
        let plan = ConversationPlan(payload: payload(threads: [emptyThread, nextThread]))

        guard let emptyHeaderIndex = plan.rows.firstIndex(where: {
            if case .threadHeader(let h) = $0.kind { return h.threadId == "empty-thread" }
            return false
        }) else {
            return XCTFail("expected empty-thread's header row to exist")
        }

        // The very next row must be the NEXT thread's header (or the end of
        // rows) — never a stray comment/body row attributable to the empty
        // thread.
        let nextRowIndex = emptyHeaderIndex + 1
        XCTAssertLessThan(nextRowIndex, plan.rows.count, "there must be a following thread")
        guard case .threadHeader(let nextHeader) = plan.rows[nextRowIndex].kind else {
            return XCTFail("expected the row right after the empty thread's header to be the next thread's header, got \(plan.rows[nextRowIndex].kind)")
        }
        XCTAssertEqual(nextHeader.threadId, "next-thread")
    }

    // MARK: - diffHunk round-trips and produces no additional row

    func testDiffHunkRoundTripsOnThreadHeaderAndProducesNoExtraRow() {
        let withHunk = thread(id: "t1", diffHunk: "@@ -1,3 +1,4 @@\n+added line", comments: [comment(id: "c1")])
        let withoutHunk = thread(id: "t2", diffHunk: nil, comments: [comment(id: "c2")])

        let planWithHunk = ConversationPlan(payload: payload(threads: [withHunk]))
        let planWithoutHunk = ConversationPlan(payload: payload(threads: [withoutHunk]))

        XCTAssertEqual(
            planWithHunk.rows.count, planWithoutHunk.rows.count,
            "a set diffHunk must add no rows of its own — same row count as an otherwise-identical body-only thread"
        )

        guard case .threadHeader(let header) = planWithHunk.rows[1].kind else {
            return XCTFail("expected a threadHeader row")
        }
        XCTAssertEqual(header.diffHunk, "@@ -1,3 +1,4 @@\n+added line")
    }

    // MARK: - No threads, only a description

    func testConversationWithNoThreadsAndOnlyADescriptionRendersOnlyTheDescription() {
        let plan = ConversationPlan(payload: payload(
            body: [.paragraph([.text("just a description, no threads")])],
            threads: []
        ))
        let hasThreadHeader = plan.rows.contains { if case .threadHeader = $0.kind { return true }; return false }
        XCTAssertFalse(hasThreadHeader)
        XCTAssertTrue(plan.rows.contains { $0.spans == [.text("just a description, no threads")] })
    }

    // MARK: - commentRowIndex points at a commentHeader row

    func testCommentRowIndexForARealCommentIdPointsAtACommentHeaderRow() {
        let plan = ConversationPlan(payload: payload(threads: [
            thread(id: "t1", comments: [comment(id: "c1", author: "carol")]),
        ]))
        guard let rowIndex = plan.commentRowIndex["c1"] else {
            return XCTFail("expected commentRowIndex to contain \"c1\"")
        }
        guard case .commentHeader(let author, _) = plan.rows[rowIndex].kind else {
            return XCTFail("commentRowIndex[\"c1\"] must point at a .commentHeader row, got \(plan.rows[rowIndex].kind)")
        }
        XCTAssertEqual(author, "carol")
    }
}
