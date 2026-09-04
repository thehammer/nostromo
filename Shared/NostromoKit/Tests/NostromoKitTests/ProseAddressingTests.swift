import XCTest
@testable import NostromoKit

// L1 coverage for `ConversationPlan.resolve`/`TicketPlan.resolve` and the
// shared `ProseAddressing` helpers (ios-curated-view-parity W9, D4/D5) — the
// honesty suite, and the substance of this wedge (memo B12): every anchor
// or emphasis this surface cannot use resolves to `.unresolved`/
// `.matchedNothing` with an operator-facing reason, never to silence.
// Same discipline `AnchorResolutionTests` established for `CodeDocument`.

final class ProseAddressingTests: XCTestCase {

    // MARK: - Conversation fixture

    private func conversationComment(
        id: String,
        author: String = "alice",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        text: String = "comment body"
    ) -> ConversationCommentModel {
        ConversationCommentModel(id: id, author: author, createdAt: createdAt, body: [.paragraph([.text(text)])])
    }

    private func conversationThread(
        id: String,
        kind: ConversationThreadKind = .issue,
        comments: [ConversationCommentModel]
    ) -> ConversationThreadModel {
        ConversationThreadModel(id: id, kind: kind, path: nil, line: nil, diffHunk: nil, resolved: false, comments: comments)
    }

    /// rows: [0] documentHeader, [1] paragraph(description), [2] threadHeader(t1),
    /// [3] commentHeader(c1), [4] paragraph(c1 body: "first comment marker alpha"),
    /// [5] commentHeader(c2), [6] paragraph(c2 body: "second comment marker beta").
    private func makeConversationPlan() -> ConversationPlan {
        let c1 = conversationComment(id: "c1", text: "first comment marker alpha")
        let c2 = conversationComment(id: "c2", text: "second comment marker beta")
        let t1 = conversationThread(id: "t1", comments: [c1, c2])
        let payload = PrConversationPayload(
            repo: "acme/web", number: 1, title: "t", author: "a", url: "",
            body: [.paragraph([.text("PR description text")])],
            threads: [t1], conversationError: nil
        )
        return ConversationPlan(payload: payload)
    }

    // MARK: - Ticket fixture

    private func ticketSection(
        name: String,
        heading: [MdSpan]? = nil,
        blocks: [MdBlock] = [.paragraph([.text("default section body")])]
    ) -> TicketSectionModel {
        TicketSectionModel(name: name, heading: heading, blocks: blocks)
    }

    private func ticketComment(
        index: Int,
        author: String = "alice",
        blocks: [MdBlock] = [.paragraph([.text("default comment body")])]
    ) -> TicketCommentModel {
        TicketCommentModel(index: index, author: author, createdAt: Date(timeIntervalSince1970: 0), blocks: blocks)
    }

    /// rows: [0] documentHeader, [1] sectionHeader(description), [2] paragraph,
    /// [3] sectionHeader(acceptance_criteria), [4] paragraph, [5] commentHeader(1),
    /// [6] paragraph, [7] commentHeader(2), [8] paragraph, [9] commentHeader(3),
    /// [10] paragraph, [11] commentHeader(4), [12] paragraph.
    private func makeTicketPlan() -> TicketPlan {
        let payload = TicketPayload(
            provider: "jira", key: "PROJ-1", summary: "s", status: "open",
            assignee: nil, url: "",
            sections: [
                ticketSection(name: "description"),
                ticketSection(name: "acceptance_criteria"),
            ],
            comments: [
                ticketComment(index: 1, author: "carol"),
                ticketComment(index: 2, author: "dave"),
                ticketComment(index: 3, author: "erin"),
                ticketComment(index: 4, author: "frank"),
            ]
        )
        return TicketPlan(payload: payload)
    }

    // MARK: - No anchor -> .notRequested on both surfaces

    func testNoAnchorIsNotRequestedNotUnresolvedNotResolvedOnConversation() {
        let resolution = makeConversationPlan().resolve(anchor: nil)
        XCTAssertEqual(resolution, .notRequested)
        XCTAssertNotEqual(resolution, .unresolved(reason: ""))
        XCTAssertNotEqual(resolution, .resolved(target: 0))
    }

    func testNoAnchorIsNotRequestedNotUnresolvedNotResolvedOnTicket() {
        let resolution = makeTicketPlan().resolve(anchor: nil)
        XCTAssertEqual(resolution, .notRequested)
        XCTAssertNotEqual(resolution, .unresolved(reason: ""))
        XCTAssertNotEqual(resolution, .resolved(target: 0))
    }

    // MARK: - Conversation: Anchor.comment(id:)

    func testConversationCommentAnchorPresentResolvesToThatCommentsHeaderRowCrossCheckedAgainstCommentRowIndex() {
        let plan = makeConversationPlan()
        let resolution = plan.resolve(anchor: .comment(id: "c2"))
        XCTAssertEqual(resolution, .resolved(target: plan.commentRowIndex["c2"]!))
    }

    func testConversationCommentAnchorAbsentIsUnresolvedNamingTheIdAndTheCommentCount() {
        let plan = makeConversationPlan()
        guard case .unresolved(let reason) = plan.resolve(anchor: .comment(id: "does-not-exist")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("does-not-exist"), "reason must name the requested id: \(reason)")
        XCTAssertTrue(reason.contains("2"), "reason must name the actual comment count: \(reason)")
    }

    // MARK: - Conversation: anchor kinds this surface cannot use

    func testConversationLineAnchorIsUnresolvedNamingTheKind() {
        // This is exactly the case macOS's `ConversationContentView.applyAddress`
        // silently drops — it only ever handles `.comment`, everything else
        // is a no-op with no operator-visible signal.
        guard case .unresolved(let reason) = makeConversationPlan().resolve(anchor: .line(path: nil, line: 5)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("line"))
    }

    func testConversationSectionAnchorIsUnresolvedNamingTheKind() {
        // Same silent-drop case macOS repeats: a conversation view has no
        // named sections at all.
        guard case .unresolved(let reason) = makeConversationPlan().resolve(anchor: .section(name: "Intro")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("section"))
    }

    func testConversationQueueRowAnchorIsUnresolvedNamingTheKind() {
        guard case .unresolved(let reason) = makeConversationPlan().resolve(anchor: .queueRow(repo: "acme/web", number: 1)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("queue"))
    }

    // MARK: - Ticket: Anchor.section(name:) matching a canonical name

    func testTicketSectionAnchorMatchingCanonicalNameResolvesToThatSectionsRow() {
        let plan = makeTicketPlan()
        let resolution = plan.resolve(anchor: .section(name: "acceptance_criteria"))
        XCTAssertEqual(resolution, .resolved(target: plan.sectionOrCommentRowIndex["acceptance_criteria"]!))
    }

    // MARK: - Ticket: near-variant section names resolve to the same row (parent PRD's near-variant matching requirement)

    func testTicketSectionAnchorCaseVariantResolvesToTheSameRowAsTheCanonicalName() {
        let plan = makeTicketPlan()
        let canonical = plan.resolve(anchor: .section(name: "acceptance_criteria"))
        let variant = plan.resolve(anchor: .section(name: "Acceptance Criteria"))
        XCTAssertEqual(canonical, variant)
    }

    func testTicketSectionAnchorTrailingColonVariantResolvesToTheSameRowAsTheCanonicalName() {
        let plan = makeTicketPlan()
        let canonical = plan.resolve(anchor: .section(name: "acceptance_criteria"))
        let variant = plan.resolve(anchor: .section(name: "acceptance_criteria:"))
        XCTAssertEqual(canonical, variant)
    }

    func testTicketSectionAnchorSpacesForUnderscoresVariantResolvesToTheSameRowAsTheCanonicalName() {
        let plan = makeTicketPlan()
        let canonical = plan.resolve(anchor: .section(name: "acceptance_criteria"))
        let variant = plan.resolve(anchor: .section(name: "acceptance criteria"))
        XCTAssertEqual(canonical, variant)
    }

    // MARK: - Ticket: an unmatched section is unresolved AND falls back to the description

    func testTicketUnmatchedSectionAnchorIsUnresolvedNamingTheRequestedNameAndDescriptionFallbackRowEqualsTheDescriptionSectionsHeaderRow() {
        // A fallback target without the stated reason is macOS's bug (a
        // silent fallback); a stated reason without a fallback target is a
        // blank view. This wedge requires both, so both halves are asserted
        // in this one test.
        let plan = makeTicketPlan()
        guard case .unresolved(let reason) = plan.resolve(anchor: .section(name: "not_a_real_section")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("not_a_real_section"), "reason must name the requested section: \(reason)")
        XCTAssertEqual(plan.descriptionFallbackRow, plan.sectionOrCommentRowIndex["description"]!)
    }

    func testDescriptionFallbackRowWhenNoDescriptionSectionExistsEqualsTheFirstSectionsRow() {
        let payload = TicketPayload(
            provider: "jira", key: "PROJ-1", summary: "s", status: "open",
            assignee: nil, url: "",
            sections: [ticketSection(name: "acceptance_criteria")],
            comments: []
        )
        let plan = TicketPlan(payload: payload)
        XCTAssertNil(plan.sectionOrCommentRowIndex["description"])
        XCTAssertEqual(plan.descriptionFallbackRow, plan.sectionOrCommentRowIndex["acceptance_criteria"]!)
    }

    func testDescriptionFallbackRowWhenZeroSectionsExistEqualsTheDocumentHeaderRowZero() {
        let payload = TicketPayload(
            provider: "jira", key: "PROJ-1", summary: "s", status: "open",
            assignee: nil, url: "", sections: [], comments: []
        )
        let plan = TicketPlan(payload: payload)
        XCTAssertEqual(plan.descriptionFallbackRow, 0)
    }

    // MARK: - Ticket comment addressing via the shared "comment:<index>" convention

    func testTicketCommentAddressValidResolvesToThatCommentsHeaderRow() {
        let plan = makeTicketPlan()
        let resolution = plan.resolve(anchor: .section(name: "comment:2"))
        XCTAssertEqual(resolution, .resolved(target: plan.sectionOrCommentRowIndex["comment:2"]!))
    }

    func testTicketCommentAddressOutOfRangeIsUnresolvedNamingBothTheRequestedAndActualCounts() {
        let plan = makeTicketPlan() // has 4 comments
        guard case .unresolved(let reason) = plan.resolve(anchor: .section(name: "comment:7")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("7"), "reason must name the requested index: \(reason)")
        XCTAssertTrue(reason.contains("4"), "reason must name the actual comment count: \(reason)")
    }

    func testTicketCommentAddressMalformedIsUnresolvedNamingTheMalformedToken() {
        let plan = makeTicketPlan()
        guard case .unresolved(let reason) = plan.resolve(anchor: .section(name: "comment:abc")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("abc"), "reason must name the malformed token: \(reason)")
    }

    // MARK: - Ticket: anchor kinds this surface cannot use at all

    func testTicketLineAnchorIsUnresolvedNamingTheKind() {
        guard case .unresolved(let reason) = makeTicketPlan().resolve(anchor: .line(path: nil, line: 5)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("line"))
    }

    func testTicketCommentAnchorIsUnresolvedNamingTheKind() {
        // A ticket's comments are addressed by index via "comment:<n>"
        // (Anchor.section(name:)), never by id (Anchor.comment(id:)).
        guard case .unresolved(let reason) = makeTicketPlan().resolve(anchor: .comment(id: "x")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("comment"))
    }

    func testTicketQueueRowAnchorIsUnresolvedNamingTheKind() {
        guard case .unresolved(let reason) = makeTicketPlan().resolve(anchor: .queueRow(repo: "acme/web", number: 1)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("queue"))
    }

    // MARK: - Emphasis: absent is .none, not .matchedNothing

    func testEmptyEmphasisArrayIsNoneOnConversation() {
        XCTAssertEqual(makeConversationPlan().resolve(emphasis: []), .none)
    }

    func testEmptyEmphasisArrayIsNoneOnTicket() {
        XCTAssertEqual(makeTicketPlan().resolve(emphasis: []), .none)
    }

    // MARK: - Emphasis: resolving/failing on each surface's own addressing

    func testConversationCommentEmphasisResolvingProducesRowsContainingTheExpectedRow() {
        let plan = makeConversationPlan()
        let resolution = plan.resolve(emphasis: [.comment(id: "c1")])
        XCTAssertEqual(resolution, .rows([plan.commentRowIndex["c1"]!]))
    }

    func testConversationCommentEmphasisAbsentIsMatchedNothingNamingTheId() {
        guard case .matchedNothing(let reason) = makeConversationPlan().resolve(emphasis: [.comment(id: "ghost")]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertTrue(reason.contains("ghost"))
    }

    func testTicketSectionEmphasisResolvingProducesRowsContainingTheExpectedRow() {
        let plan = makeTicketPlan()
        let resolution = plan.resolve(emphasis: [.section(name: "acceptance_criteria")])
        XCTAssertEqual(resolution, .rows([plan.sectionOrCommentRowIndex["acceptance_criteria"]!]))
    }

    func testTicketSectionEmphasisAbsentIsMatchedNothingNamingTheName() {
        guard case .matchedNothing(let reason) = makeTicketPlan().resolve(emphasis: [.section(name: "ghost_section")]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertTrue(reason.contains("ghost_section"))
    }

    // MARK: - Emphasis.textRange

    func testTextRangeInsideTheDocumentResolvesToRowsContainingTheExpectedRow() {
        let plan = makeConversationPlan()
        let full = ProsePlan.plainText(for: plan.rows) as NSString
        let marker = "first comment marker alpha"
        let markerRange = full.range(of: marker)
        XCTAssertNotEqual(markerRange.location, NSNotFound, "fixture setup: marker must be present in the projection")

        let resolution = plan.resolve(emphasis: [.textRange(start: markerRange.location, end: markerRange.location + markerRange.length)])
        // Row 4 is c1's paragraph body, whose plain text IS exactly the marker.
        guard case .rows(let rows) = resolution else {
            return XCTFail("expected .rows, got \(resolution)")
        }
        XCTAssertTrue(rows.contains(4), "expected the marker's own row (c1's body) among the resolved rows, got \(rows)")
    }

    func testTextRangeMatchReturnsTheContainingRowAndTheWithinRowRangeForTheSameInputs() {
        let plan = makeConversationPlan()
        let full = ProsePlan.plainText(for: plan.rows) as NSString
        let marker = "first comment marker alpha"
        let markerRange = full.range(of: marker)
        XCTAssertNotEqual(markerRange.location, NSNotFound)

        let start = markerRange.location
        let end = markerRange.location + markerRange.length
        guard let match = ProseAddressing.textRangeMatch(start: start, end: end, in: plan.rows) else {
            return XCTFail("expected a match")
        }
        XCTAssertEqual(match.row, 4, "the marker sits entirely within row 4 (c1's body paragraph)")
        // The marker IS the entirety of row 4's own plain text, so the
        // within-row range must span from 0 to the marker's own length.
        XCTAssertEqual(match.range, 0..<markerRange.length)
    }

    func testTextRangeEntirelyOutsideTheDocumentIsMatchedNothingAndTextRangeMatchReturnsNil() {
        let plan = makeConversationPlan()
        let full = ProsePlan.plainText(for: plan.rows)
        let farStart = full.utf16.count + 1000
        let farEnd = farStart + 10

        guard case .matchedNothing = plan.resolve(emphasis: [.textRange(start: farStart, end: farEnd)]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertNil(ProseAddressing.textRangeMatch(start: farStart, end: farEnd, in: plan.rows))
    }

    func testInvertedOrEmptyTextRangeIsMatchedNothingAndTextRangeMatchReturnsNil() {
        let plan = makeConversationPlan()

        guard case .matchedNothing = plan.resolve(emphasis: [.textRange(start: 10, end: 3)]) else {
            return XCTFail("expected .matchedNothing for an inverted range")
        }
        XCTAssertNil(ProseAddressing.textRangeMatch(start: 10, end: 3, in: plan.rows))

        guard case .matchedNothing = plan.resolve(emphasis: [.textRange(start: 5, end: 5)]) else {
            return XCTFail("expected .matchedNothing for an empty (start == end) range")
        }
        XCTAssertNil(ProseAddressing.textRangeMatch(start: 5, end: 5, in: plan.rows))
    }

    // MARK: - Multiple emphasis entries union without duplicating rows

    func testMultipleEmphasisEntriesUnionRowsWithoutDuplicatingRows() {
        let plan = makeConversationPlan()
        let resolution = plan.resolve(emphasis: [.comment(id: "c1"), .comment(id: "c2")])
        guard case .rows(let rows) = resolution else {
            return XCTFail("expected .rows, got \(resolution)")
        }
        XCTAssertEqual(rows.count, Set(rows).count, "no row may appear twice even when it satisfies more than one entry")
        XCTAssertEqual(Set(rows), Set([plan.commentRowIndex["c1"]!, plan.commentRowIndex["c2"]!]))
    }

    func testTwoEmphasisEntriesResolvingToTheSameRowProduceNoDuplicate() {
        let plan = makeConversationPlan()
        let resolution = plan.resolve(emphasis: [.comment(id: "c1"), .comment(id: "c1")])
        XCTAssertEqual(resolution, .rows([plan.commentRowIndex["c1"]!]))
    }

    // MARK: - Re-emphasis replaces, it does not clear-then-leak (D5)

    func testReEmphasisIsAPureFunctionTheSecondResolutionReflectsOnlyTheSecondSet() {
        // `resolve(emphasis:)` reads only its argument and `self` — there is
        // no mutable emphasis state anywhere on `ConversationPlan`/
        // `TicketPlan` for a prior call to leak through. This test pins that
        // as an observable property: calling `resolve` with a first set and
        // then a second set is indistinguishable from calling it with only
        // the second set, which is what makes the macOS
        // `TicketContentView.clearEmphasis`-wipes-everything defect (which
        // depends on there BEING a document-wide mutable state to wipe)
        // structurally impossible here, not merely avoided by care.
        let plan = makeConversationPlan()
        let firstSet: [Emphasis] = [.comment(id: "c1")]
        let secondSet: [Emphasis] = [.comment(id: "c2")]

        _ = plan.resolve(emphasis: firstSet) // the "first push" — establishes nothing that outlives this call
        let secondResult = plan.resolve(emphasis: secondSet)
        let secondResultCalledFresh = plan.resolve(emphasis: secondSet)

        XCTAssertEqual(secondResult, secondResultCalledFresh, "resolving the second set must be identical whether or not the first set was ever resolved")
        guard case .rows(let rows) = secondResult else {
            return XCTFail("expected .rows, got \(secondResult)")
        }
        XCTAssertFalse(rows.contains(plan.commentRowIndex["c1"]!), "the second resolution must carry no memory of the first call's rows")
        XCTAssertEqual(rows, [plan.commentRowIndex["c2"]!])
    }
}
