import XCTest
import AppKit

// `TicketBlockDocument`, `TicketPayload`, `TicketSectionModel`,
// `TicketCommentModel`, `MdBlock`, `MdSpan` are compiled into this target
// directly (logic test — no host app, no `@testable import`), the same idiom
// as `MarkdownBlockDocumentTests`/`CodeDocumentTests`/`DiffDocumentTests`.

/// Behavioural coverage for `TicketBlockDocument` — the ticket-payload-to-
/// attributed-string renderer and the per-section/per-comment range
/// arithmetic `Anchor.section(name:)` addressing depends on (W4 —
/// curated-agent-views).
final class TicketBlockDocumentTests: XCTestCase {

    // MARK: - Fixture builders

    private func makeSection(
        name: String,
        heading: [MdSpan]? = nil,
        blocks: [MdBlock] = [.paragraph([.text("default section body")])]
    ) -> TicketSectionModel {
        TicketSectionModel(name: name, heading: heading, blocks: blocks)
    }

    private func makeComment(
        index: Int,
        author: String = "alice",
        createdAt: Date = Date(timeIntervalSince1970: 0),
        blocks: [MdBlock] = [.paragraph([.text("default comment body")])]
    ) -> TicketCommentModel {
        TicketCommentModel(index: index, author: author, createdAt: createdAt, blocks: blocks)
    }

    private func makePayload(
        provider: String = "jira",
        key: String = "PROJ-123",
        summary: String = "Fix the login bug",
        status: String = "In Progress",
        assignee: String? = "Alice Smith",
        url: String = "https://example.atlassian.net/browse/PROJ-123",
        sections: [TicketSectionModel]? = nil,
        comments: [TicketCommentModel]? = nil
    ) -> TicketPayload {
        TicketPayload(
            provider: provider,
            key: key,
            summary: summary,
            status: status,
            assignee: assignee,
            url: url,
            sections: sections ?? [makeSection(name: "description")],
            comments: comments ?? [makeComment(index: 1)]
        )
    }

    // MARK: 1. Header renders key, summary, status, assignee, url

    func testHeaderRendersTicketKeySummaryStatusAssigneeAndURL() {
        let payload = makePayload(
            key: "PROJ-999",
            summary: "A very particular summary line",
            status: "In Review",
            assignee: "Bob Jones",
            url: "https://example.atlassian.net/browse/PROJ-999"
        )
        let doc = TicketBlockDocument(payload: payload)
        let rendered = doc.attributedString.string

        XCTAssertTrue(rendered.contains("PROJ-999"), "the ticket key must appear in the rendered header")
        XCTAssertTrue(rendered.contains("A very particular summary line"), "the summary must appear in the rendered header")
        XCTAssertTrue(rendered.contains("In Review"), "the status must appear in the rendered header")
        XCTAssertTrue(rendered.contains("Bob Jones"), "the assignee must appear in the rendered header")
        XCTAssertTrue(rendered.contains("https://example.atlassian.net/browse/PROJ-999"), "the url must appear in the rendered header")
    }

    // MARK: 2. A nil assignee is omitted cleanly from the metadata line

    func testNilAssigneeOmitsAssigneeSegmentWithoutAStrayJoinArtifact() {
        let payload = makePayload(
            status: "Open",
            assignee: nil,
            url: "https://example.atlassian.net/browse/PROJ-123"
        )
        let doc = TicketBlockDocument(payload: payload)
        let lines = doc.attributedString.string.components(separatedBy: "\n")

        // line 0 is "<key>  <summary>"; line 1 is the metadata line.
        XCTAssertEqual(
            lines[1], "Open  ·  https://example.atlassian.net/browse/PROJ-123",
            "with no assignee, the metadata line must join only status and url — no stray separator left behind"
        )
        XCTAssertFalse(
            doc.attributedString.string.contains("·  ·"),
            "omitting a nil assignee must not leave a doubled-up separator artifact"
        )
    }

    // MARK: 3. A section with no heading gets a display heading derived from its canonical name

    func testSectionWithNoHeadingRendersADisplayHeadingDerivedFromItsCanonicalName() {
        let payload = makePayload(sections: [
            makeSection(name: "description", heading: nil, blocks: [.paragraph([.text("unique description marker")])]),
        ])
        let doc = TicketBlockDocument(payload: payload)

        XCTAssertTrue(
            doc.attributedString.string.contains("Description"),
            "a section named 'description' with no heading of its own must render a title-cased display heading"
        )
    }

    func testSectionNamedAcceptanceCriteriaWithNoHeadingRendersAsAcceptanceCriteriaTitleCased() {
        let payload = makePayload(sections: [
            makeSection(name: "acceptance_criteria", heading: nil, blocks: [.paragraph([.text("unique AC marker")])]),
        ])
        let doc = TicketBlockDocument(payload: payload)

        XCTAssertTrue(
            doc.attributedString.string.contains("Acceptance Criteria"),
            "displayName must title-case each underscore-separated word: 'acceptance_criteria' -> 'Acceptance Criteria'"
        )
    }

    // MARK: 4. A section WITH a heading renders that heading's own spans, not a derived display name

    func testSectionWithHeadingRendersItsOwnHeadingSpansNotADerivedDisplayNameAndSectionsRenderInOrder() {
        let unheaded = makeSection(name: "description", heading: nil, blocks: [.paragraph([.text("alpha marker body")])])
        let headed = makeSection(
            name: "acceptance_criteria",
            heading: [.text("Custom AC Heading Text")],
            blocks: [.paragraph([.text("beta marker body")])]
        )
        let payload = makePayload(sections: [unheaded, headed])
        let doc = TicketBlockDocument(payload: payload)
        let rendered = doc.attributedString.string as NSString

        let descriptionRange = rendered.range(of: "Description")
        let customHeadingRange = rendered.range(of: "Custom AC Heading Text")
        XCTAssertNotEqual(descriptionRange.location, NSNotFound, "the unheaded section's derived display heading must render")
        XCTAssertNotEqual(customHeadingRange.location, NSNotFound, "the headed section's own heading spans must render")
        XCTAssertLessThan(
            descriptionRange.location, customHeadingRange.location,
            "sections must render in payload order: the unheaded 'description' section before the headed 'acceptance_criteria' section"
        )

        XCTAssertFalse(
            rendered.contains("Acceptance Criteria"),
            "a section with its own heading must render that heading's spans, not the derived display name for its canonical name"
        )
    }

    // MARK: 5. ranges bracket each section's/comment's own content without bleeding into another's

    func testRangesExactlyBracketEachSectionsAndCommentsOwnContentWithoutOverlapping() throws {
        let section1 = makeSection(name: "description", heading: nil, blocks: [.paragraph([.text("section one unique marker alpha")])])
        let section2 = makeSection(
            name: "acceptance_criteria",
            heading: [.text("AC Heading")],
            blocks: [.paragraph([.text("section two unique marker beta")])]
        )
        let comment1 = makeComment(index: 1, author: "carol", blocks: [.paragraph([.text("comment one unique marker gamma")])])
        let comment2 = makeComment(index: 2, author: "dave", blocks: [.paragraph([.text("comment two unique marker delta")])])
        let payload = makePayload(sections: [section1, section2], comments: [comment1, comment2])
        let doc = TicketBlockDocument(payload: payload)

        let rangeSection1 = try XCTUnwrap(doc.ranges["description"])
        let rangeSection2 = try XCTUnwrap(doc.ranges["acceptance_criteria"])
        let rangeComment1 = try XCTUnwrap(doc.ranges["comment:1"])
        let rangeComment2 = try XCTUnwrap(doc.ranges["comment:2"])

        // Ordering: section1 < section2 < comment1 < comment2, none overlapping.
        XCTAssertLessThanOrEqual(rangeSection1.location + rangeSection1.length, rangeSection2.location)
        XCTAssertLessThanOrEqual(rangeSection2.location + rangeSection2.length, rangeComment1.location)
        XCTAssertLessThanOrEqual(rangeComment1.location + rangeComment1.length, rangeComment2.location)

        let full = doc.attributedString.string as NSString
        let textSection1 = full.substring(with: rangeSection1)
        let textSection2 = full.substring(with: rangeSection2)
        let textComment1 = full.substring(with: rangeComment1)
        let textComment2 = full.substring(with: rangeComment2)

        XCTAssertTrue(textSection1.contains("section one unique marker alpha"))
        XCTAssertFalse(textSection1.contains("section two unique marker beta"))
        XCTAssertFalse(textSection1.contains("comment one unique marker gamma"))

        XCTAssertTrue(textSection2.contains("section two unique marker beta"))
        XCTAssertFalse(textSection2.contains("section one unique marker alpha"))
        XCTAssertFalse(textSection2.contains("comment one unique marker gamma"))

        XCTAssertTrue(textComment1.contains("comment one unique marker gamma"))
        XCTAssertTrue(textComment1.contains("carol"))
        XCTAssertFalse(textComment1.contains("comment two unique marker delta"))

        XCTAssertTrue(textComment2.contains("comment two unique marker delta"))
        XCTAssertTrue(textComment2.contains("dave"))
        XCTAssertFalse(textComment2.contains("comment one unique marker gamma"))

        XCTAssertLessThan(
            rangeSection1.length, full.length,
            "a section's range must not just span the entire document"
        )
    }

    // MARK: 6. Zero sections and zero comments still produce a valid document

    func testZeroSectionsAndZeroCommentsStillProducesAValidDocumentContainingJustTheHeader() {
        let payload = makePayload(key: "PROJ-1", summary: "Only a header", sections: [], comments: [])
        let doc = TicketBlockDocument(payload: payload)

        XCTAssertTrue(doc.attributedString.string.contains("PROJ-1"))
        XCTAssertTrue(doc.attributedString.string.contains("Only a header"))
        XCTAssertEqual(doc.ranges, [:], "with no sections and no comments, the ranges table must be empty")
    }

    // MARK: 7. Equatable

    func testTwoDocumentsBuiltFromEqualPayloadsAreEqual() {
        let doc1 = TicketBlockDocument(payload: makePayload())
        let doc2 = TicketBlockDocument(payload: makePayload())
        XCTAssertEqual(doc1, doc2)
    }

    func testTwoDocumentsDifferingByOneCommentsAuthorAreNotEqual() {
        let doc1 = TicketBlockDocument(payload: makePayload(comments: [makeComment(index: 1, author: "alice")]))
        let doc2 = TicketBlockDocument(payload: makePayload(comments: [makeComment(index: 1, author: "bob")]))
        XCTAssertNotEqual(doc1, doc2)
    }

    // MARK: 8. A comment's header line contains its index, author, and a formatted date

    func testCommentHeaderLineContainsItsIndexAuthorAndAFormattedDate() {
        let payload = makePayload(comments: [
            makeComment(index: 3, author: "eve", createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        let doc = TicketBlockDocument(payload: payload)
        let rendered = doc.attributedString.string

        XCTAssertTrue(rendered.contains("Comment #3"), "the comment header must contain its index")
        XCTAssertTrue(rendered.contains("eve"), "the comment header must contain its author")

        // Don't over-assert the exact date format — just that *some* non-empty
        // date-like text follows the author, distinct from a placeholder.
        let range = (rendered as NSString).range(of: "eve")
        XCTAssertNotEqual(range.location, NSNotFound)
        let afterAuthor = (rendered as NSString).substring(from: range.location + range.length)
        let firstLine = afterAuthor.components(separatedBy: "\n").first ?? ""
        XCTAssertFalse(
            firstLine.trimmingCharacters(in: .whitespaces).isEmpty,
            "a formatted date must follow the author on the comment header line"
        )
    }
}
