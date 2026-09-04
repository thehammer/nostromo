import XCTest
@testable import NostromoKit

// L1 coverage for `ProsePlan.appendRows`/`plainText` — the `MdBlock`/`MdSpan`
// -> `[ProseRow]` mapping shared by `ConversationPlan` and `TicketPlan`
// (ios-curated-view-parity W9, D1). This is the foundation everything else
// in this wedge sits on: `ConversationPlanTests`/`TicketPlanTests` assume
// this mapping is correct and test only the structure they add around it.

final class ProsePlanTests: XCTestCase {

    private func plan(for blocks: [MdBlock]) -> [ProseRow] {
        var rows: [ProseRow] = []
        var nextId = 0
        ProsePlan.appendRows(for: blocks, indent: 0, rows: &rows, nextId: &nextId)
        return rows
    }

    // MARK: - Every MdBlock kind produces its expected row kind

    func testParagraphProducesAParagraphRowCarryingItsSpans() {
        let spans: [MdSpan] = [.text("hello world")]
        let rows = plan(for: [.paragraph(spans)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .paragraph)
        XCTAssertEqual(rows[0].spans, spans)
    }

    func testHeadingProducesAHeadingRowAtEveryLevelOneThroughSix() {
        for level in 1...6 {
            let spans: [MdSpan] = [.text("h\(level)")]
            let rows = plan(for: [.heading(level: level, spans: spans)])
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].kind, .heading(level: level), "level \(level) did not round-trip")
            XCTAssertEqual(rows[0].spans, spans)
        }
    }

    func testCodeBlockWithALanguageRoundTripsLangOnTheRow() {
        let code = "fn foo() {\n    let x = 1;\n}"
        let rows = plan(for: [.codeBlock(lang: "rust", text: code)])
        XCTAssertEqual(rows.count, 1)
        // This is the assertion macOS's `_ = lang` (`MarkdownBlockDocument.swift:233`)
        // fails: the fence's language token must survive onto the row, even
        // though nothing renders it as syntax highlighting (D6).
        XCTAssertEqual(rows[0].kind, .codeBlock(lang: "rust", text: code))
        guard case .codeBlock(let lang, let text) = rows[0].kind else {
            return XCTFail("expected .codeBlock")
        }
        XCTAssertEqual(lang, "rust")
        XCTAssertEqual(text, code)
    }

    func testCodeBlockWithNoLanguageCarriesNilLang() {
        let rows = plan(for: [.codeBlock(lang: nil, text: "plain")])
        XCTAssertEqual(rows.count, 1)
        guard case .codeBlock(let lang, let text) = rows[0].kind else {
            return XCTFail("expected .codeBlock")
        }
        XCTAssertNil(lang)
        XCTAssertEqual(text, "plain")
    }

    func testOrderedListHonoursStartAndProducesNumberedMarkers() {
        let rows = plan(for: [.list(ordered: true, start: 5, items: [
            [.paragraph([.text("first")])],
            [.paragraph([.text("second")])],
        ])])
        // listItem, paragraph, listItem, paragraph
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[0].kind, .listItem(ordered: true, marker: "5."))
        XCTAssertEqual(rows[2].kind, .listItem(ordered: true, marker: "6."))
    }

    func testOrderedListWithNoStartDefaultsMarkersToOne() {
        let rows = plan(for: [.list(ordered: true, start: nil, items: [
            [.paragraph([.text("first")])],
            [.paragraph([.text("second")])],
        ])])
        XCTAssertEqual(rows[0].kind, .listItem(ordered: true, marker: "1."))
        XCTAssertEqual(rows[2].kind, .listItem(ordered: true, marker: "2."))
    }

    func testUnorderedListProducesBulletMarkers() {
        let rows = plan(for: [.list(ordered: false, start: nil, items: [
            [.paragraph([.text("only item")])],
        ])])
        XCTAssertEqual(rows[0].kind, .listItem(ordered: false, marker: "\u{2022}"))
    }

    func testQuoteProducesAQuoteRow() {
        let rows = plan(for: [.quote([.paragraph([.text("quoted")])])])
        XCTAssertEqual(rows[0].kind, .quote)
    }

    func testTableProducesPipeRowsWithHeaderFlaggedAndBodyRowsNot() {
        let header: [[MdSpan]] = [[.text("Name")], [.text("Age")]]
        let body: [[MdSpan]] = [[.text("Alice")], [.text("30")]]
        let rows = plan(for: [.table(header: header, rows: [body])])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].kind, .tableRow(cells: header, isHeader: true))
        XCTAssertEqual(rows[1].kind, .tableRow(cells: body, isHeader: false))
    }

    func testTableWithNoHeaderProducesOnlyBodyRows() {
        let body: [[MdSpan]] = [[.text("a")], [.text("b")]]
        let rows = plan(for: [.table(header: [], rows: [body])])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .tableRow(cells: body, isHeader: false))
    }

    func testRuleProducesARuleRow() {
        let rows = plan(for: [.rule])
        XCTAssertEqual(rows[0].kind, .rule)
    }

    // MARK: - Nested lists and nested quotes produce increasing indent

    func testNestedListsProduceStrictlyIncreasingIndentAndReturnToTheOuterLevelAfterward() {
        let nested: [MdBlock] = [
            .list(ordered: false, start: nil, items: [
                [
                    .paragraph([.text("level1 para")]),
                    .list(ordered: false, start: nil, items: [
                        [
                            .paragraph([.text("level2 para")]),
                            .list(ordered: false, start: nil, items: [
                                [.paragraph([.text("level3 para")])],
                            ]),
                        ],
                    ]),
                ],
            ]),
            .paragraph([.text("back to level0")]),
        ]
        let rows = plan(for: nested)

        // listItem(0), para(1), listItem(1), para(2), listItem(2), para(3), para(0)
        XCTAssertEqual(rows.map(\.indent), [0, 1, 1, 2, 2, 3, 0])
        XCTAssertFalse(rows.isEmpty, "nesting must not crash or flatten to nothing")
        XCTAssertEqual(rows.last?.kind, .paragraph)
        XCTAssertEqual(rows.last?.spans, [.text("back to level0")])
    }

    func testNestedQuotesProduceStrictlyIncreasingIndentAndReturnToTheOuterLevelAfterward() {
        let nested: [MdBlock] = [
            .quote([
                .paragraph([.text("q1 para")]),
                .quote([
                    .paragraph([.text("q2 para")]),
                    .quote([
                        .paragraph([.text("q3 para")]),
                    ]),
                ]),
            ]),
            .paragraph([.text("after quotes")]),
        ]
        let rows = plan(for: nested)

        // quote(0), para(1), quote(1), para(2), quote(2), para(3), para(0)
        XCTAssertEqual(rows.map(\.indent), [0, 1, 1, 2, 2, 3, 0])
        XCTAssertEqual(rows.last?.kind, .paragraph)
        XCTAssertEqual(rows.last?.spans, [.text("after quotes")])
    }

    // MARK: - Every MdSpan kind survives onto a row's spans

    func testEverySpanKindSurvivesOntoTheRowsSpansExactly() {
        let spans: [MdSpan] = [
            .text("plain"),
            .code("let x = 1"),
            .emph([.text("emphasised")]),
            .strong([.text("strong")]),
            .strike([.text("struck")]),
            .link(spans: [.text("visible link text")], url: "https://example.com/docs"),
            .image(alt: "an alt description", url: "https://example.com/shot.png"),
        ]
        let rows = plan(for: [.paragraph(spans)])
        XCTAssertEqual(rows.count, 1)
        // MdSpan is Equatable, so this asserts every span kind AND the link's
        // spans/url and the image's alt/url all round-trip verbatim.
        XCTAssertEqual(rows[0].spans, spans)
    }

    // MARK: - Row ids are unique and strictly ascending across a whole plan

    func testRowIdsAreUniqueAndStrictlyAscendingAcrossAMultiBlockPlan() {
        let blocks: [MdBlock] = [
            .heading(level: 1, spans: [.text("Title")]),
            .paragraph([.text("intro")]),
            .codeBlock(lang: "swift", text: "let x = 1"),
            .list(ordered: true, start: 1, items: [
                [.paragraph([.text("one")])],
                [.paragraph([.text("two")])],
            ]),
            .quote([.paragraph([.text("quoted")])]),
            .table(header: [[.text("H")]], rows: [[[.text("v")]]]),
            .rule,
        ]
        let rows = plan(for: blocks)
        let ids = rows.map(\.id)
        XCTAssertEqual(ids, Array(0..<rows.count), "ids must be unique and strictly ascending, with no gaps")
    }

    // MARK: - The plain-text projection is a stable, pure function of the rows

    func testPlainTextProjectionIsStableAcrossTwoIdenticalBuilds() {
        let blocks: [MdBlock] = [
            .heading(level: 2, spans: [.text("Heading")]),
            .paragraph([.text("Some prose with "), .strong([.text("emphasis")])]),
            .codeBlock(lang: "rust", text: "fn f() {}"),
            .list(ordered: false, start: nil, items: [[.paragraph([.text("item")])]]),
        ]
        let rows1 = plan(for: blocks)
        let rows2 = plan(for: blocks)
        XCTAssertEqual(ProsePlan.plainText(for: rows1), ProsePlan.plainText(for: rows2))
    }

    // MARK: - An unrecognized block kind (decoded as `.paragraph([])`) still produces a row

    func testAnEmptyParagraphBlockStillProducesOneRowRatherThanBeingDropped() {
        // `MdBlock.init(from:)` (`PaneLayout.swift`) degrades an unrecognized
        // wire block kind to `.paragraph([])` before ProsePlan ever sees it —
        // so the criterion "a future block kind degrades visibly" reduces to
        // this: a `.paragraph([])` block must still produce a row, not be
        // silently skipped.
        let rows = plan(for: [.paragraph([])])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .paragraph)
        XCTAssertEqual(rows[0].spans, [])
    }
}
