import XCTest
@testable import NostromoKit

// L1 coverage for `TicketPlan(payload:)` (ios-curated-view-parity W9, D4) —
// header fields, section/comment ordering, the display-name rule ported
// from `TicketBlockDocument.displayName(_:)`
// (`macOS/Nostromo/UI/TicketBlockDocument.swift:111-116`), and the
// `"comment:<index>"` addressing convention's row lookup.

final class TicketPlanTests: XCTestCase {

    // MARK: - Fixture builders

    private func section(
        name: String,
        heading: [MdSpan]? = nil,
        blocks: [MdBlock] = [.paragraph([.text("default section body")])]
    ) -> TicketSectionModel {
        TicketSectionModel(name: name, heading: heading, blocks: blocks)
    }

    private func comment(
        index: Int,
        author: String = "alice",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        blocks: [MdBlock] = [.paragraph([.text("default comment body")])]
    ) -> TicketCommentModel {
        TicketCommentModel(index: index, author: author, createdAt: createdAt, blocks: blocks)
    }

    private func payload(
        key: String = "PROJ-123",
        summary: String = "Fix the login bug",
        status: String = "In Progress",
        assignee: String? = "Alice Smith",
        url: String = "https://example.atlassian.net/browse/PROJ-123",
        sections: [TicketSectionModel] = [],
        comments: [TicketCommentModel] = []
    ) -> TicketPayload {
        TicketPayload(
            provider: "jira", key: key, summary: summary, status: status,
            assignee: assignee, url: url, sections: sections, comments: comments
        )
    }

    // MARK: - Header renders key/summary/status/assignee/url

    func testHeaderRendersKeySummaryStatusAssigneeAndUrlIndividually() {
        let plan = TicketPlan(payload: payload(
            key: "PROJ-999", summary: "A very particular summary line",
            status: "In Review", assignee: "Bob Jones",
            url: "https://example.atlassian.net/browse/PROJ-999"
        ))
        guard case .documentHeader(let header) = plan.rows[0].kind else {
            return XCTFail("expected rows[0] to be .documentHeader")
        }
        XCTAssertEqual(header.key, "PROJ-999")
        XCTAssertEqual(header.title, "A very particular summary line")
        XCTAssertEqual(header.status, "In Review")
        XCTAssertEqual(header.assignee, "Bob Jones")
        XCTAssertEqual(header.url, "https://example.atlassian.net/browse/PROJ-999")
    }

    // MARK: - A nil assignee produces a clean nil, not a join artifact

    func testNilAssigneeProducesACleanNilProseHeaderAssignee() {
        // `ProseHeader` has a dedicated `assignee: String?` field and no
        // string-joining anywhere in this design — there is no join point at
        // which a stray separator could appear. This sidesteps, by
        // construction, the exact bug class macOS's
        // `TicketBlockDocumentTests.testNilAssigneeOmitsAssigneeSegmentWithoutAStrayJoinArtifact`
        // guards against with a runtime string-content assertion.
        let plan = TicketPlan(payload: payload(assignee: nil))
        guard case .documentHeader(let header) = plan.rows[0].kind else {
            return XCTFail("expected rows[0] to be .documentHeader")
        }
        XCTAssertNil(header.assignee)
    }

    // MARK: - Sections render in payload order

    func testSectionsRenderInPayloadOrder() {
        let plan = TicketPlan(payload: payload(sections: [
            section(name: "description"),
            section(name: "acceptance_criteria"),
            section(name: "notes"),
        ]))
        let descriptionRow = plan.sectionOrCommentRowIndex["description"]!
        let acRow = plan.sectionOrCommentRowIndex["acceptance_criteria"]!
        let notesRow = plan.sectionOrCommentRowIndex["notes"]!
        XCTAssertLessThan(descriptionRow, acRow)
        XCTAssertLessThan(acRow, notesRow)
    }

    // MARK: - A section with no heading gets a title-cased display name

    func testSectionWithNoHeadingProducesASectionHeaderRowWithATitleCasedDisplayName() {
        // Cites `TicketBlockDocument.displayName(_:)`
        // (`macOS/Nostromo/UI/TicketBlockDocument.swift:111-116`) as the exact
        // mapping this must match.
        let plan = TicketPlan(payload: payload(sections: [section(name: "description", heading: nil)]))
        let rowIndex = plan.sectionOrCommentRowIndex["description"]!
        XCTAssertEqual(plan.rows[rowIndex].kind, .sectionHeader(name: "description", display: "Description"))
    }

    func testSectionNamedAcceptanceCriteriaWithNoHeadingRendersTitleCasedAcceptanceCriteria() {
        let plan = TicketPlan(payload: payload(sections: [section(name: "acceptance_criteria", heading: nil)]))
        let rowIndex = plan.sectionOrCommentRowIndex["acceptance_criteria"]!
        XCTAssertEqual(plan.rows[rowIndex].kind, .sectionHeader(name: "acceptance_criteria", display: "Acceptance Criteria"))
    }

    // MARK: - A section WITH a heading renders that heading's own spans, not a derived display name

    func testSectionWithHeadingRendersAHeadingRowCarryingItsOwnSpansNotASectionHeaderRow() {
        let headingSpans: [MdSpan] = [.text("Custom AC Heading Text")]
        let plan = TicketPlan(payload: payload(sections: [
            section(name: "acceptance_criteria", heading: headingSpans),
        ]))
        let rowIndex = plan.sectionOrCommentRowIndex["acceptance_criteria"]!
        XCTAssertEqual(plan.rows[rowIndex].kind, .heading(level: 2))
        XCTAssertEqual(plan.rows[rowIndex].spans, headingSpans)

        // The derived display name ("Acceptance Criteria") must not appear
        // anywhere for this section — a section with its own heading is
        // never ALSO given the canonical derived name.
        let hasDerivedSectionHeader = plan.rows.contains {
            if case .sectionHeader(let name, let display) = $0.kind {
                return name == "acceptance_criteria" || display == "Acceptance Criteria"
            }
            return false
        }
        XCTAssertFalse(hasDerivedSectionHeader)
    }

    // MARK: - Comments render in order, each with a commentHeader row indexed correctly

    func testCommentsRenderInOrderWithCommentHeaderRowsCarryingAuthorAndDate() {
        let createdAt1 = Date(timeIntervalSince1970: 1_700_000_000)
        let createdAt2 = Date(timeIntervalSince1970: 1_700_000_100)
        let plan = TicketPlan(payload: payload(comments: [
            comment(index: 1, author: "carol", createdAt: createdAt1),
            comment(index: 2, author: "dave", createdAt: createdAt2),
        ]))

        let row1 = plan.sectionOrCommentRowIndex["comment:1"]!
        let row2 = plan.sectionOrCommentRowIndex["comment:2"]!
        XCTAssertLessThan(row1, row2)

        guard case .commentHeader(let author1, let date1) = plan.rows[row1].kind else {
            return XCTFail("expected commentHeader")
        }
        XCTAssertEqual(author1, "carol")
        XCTAssertEqual(date1, createdAt1)

        guard case .commentHeader(let author2, let date2) = plan.rows[row2].kind else {
            return XCTFail("expected commentHeader")
        }
        XCTAssertEqual(author2, "dave")
        XCTAssertEqual(date2, createdAt2)
    }

    // MARK: - Zero sections and zero comments

    func testZeroSectionsAndZeroCommentsProducesOnlyTheHeaderRow() {
        let plan = TicketPlan(payload: payload(key: "PROJ-1", summary: "Only a header", sections: [], comments: []))
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertTrue(plan.sectionOrCommentRowIndex.isEmpty)
        guard case .documentHeader(let header) = plan.rows[0].kind else {
            return XCTFail("expected the only row to be .documentHeader")
        }
        XCTAssertEqual(header.key, "PROJ-1")
        XCTAssertEqual(header.title, "Only a header")
    }

    // MARK: - `TicketPlan.displayName(_:)` unit-level mapping

    func testDisplayNameTitleCasesEachUnderscoreSeparatedWord() {
        XCTAssertEqual(TicketPlan.displayName("description"), "Description")
        XCTAssertEqual(TicketPlan.displayName("acceptance_criteria"), "Acceptance Criteria")
        XCTAssertEqual(TicketPlan.displayName("steps_to_reproduce"), "Steps To Reproduce")
    }
}
