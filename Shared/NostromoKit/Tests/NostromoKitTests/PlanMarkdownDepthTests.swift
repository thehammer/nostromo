import XCTest
@testable import NostromoKit

/// A plan's text is untrusted (SR2). Hostile nesting must neither crash the parser nor leave a model
/// that is deep enough to crash whatever draws it, and the plan's own words must stay readable.
///
/// The app parses on a small-stack utility queue, so every parse here runs on a thread with a 512 KiB
/// stack. The model is bounded when no block (quote or list item) sits more than 33 containers deep;
/// the parser flattens anything deeper into its parent (its own limit is 32, the test allows one more).
final class PlanMarkdownDepthTests: XCTestCase {

    /// The deepest container nesting the model may have (`PlanMarkdown.maxDepth` is 32).
    private let depthLimit = 33
    /// A parse that takes longer than this has failed: the real one is well under a second.
    private let wellInside: TimeInterval = 10
    /// The most a parse is waited for before the test gives up on it.
    private let giveUp: TimeInterval = 30

    // MARK: Running a parse the way the app does

    private final class Outcome<Value>: @unchecked Sendable {
        var value: Value?
        var seconds: TimeInterval = 0
    }

    /// `body()` on a 512 KiB-stack thread. Nil (and a failure) if it never finishes.
    private func onSmallStack<Value>(_ body: @escaping () -> Value,
                                     file: StaticString = #filePath, line: UInt = #line) -> (value: Value, seconds: TimeInterval)? {
        let outcome = Outcome<Value>()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let start = Date()
            outcome.value = body()
            outcome.seconds = Date().timeIntervalSince(start)
            finished.signal()
        }
        thread.stackSize = 512 * 1024
        thread.qualityOfService = .utility
        thread.start()

        guard finished.wait(timeout: .now() + giveUp) == .success, let value = outcome.value else {
            XCTFail("the parse did not finish within \(Int(giveUp)) s", file: file, line: line)
            return nil
        }
        return (value, outcome.seconds)
    }

    /// `PlanMarkdown.parse(text)` on a 512 KiB-stack thread. Nil (and a failure) if it never finishes.
    private func parseOnSmallStack(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (doc: PlanDocument, seconds: TimeInterval)? {
        guard let run = onSmallStack({ PlanMarkdown.parse(text) }, file: file, line: line) else { return nil }
        return (run.value, run.seconds)
    }

    // MARK: Reading the model (it is bounded, so recursing over it is safe)

    private func spansText(_ spans: [PlanSpan]) -> String { spans.plainText }

    /// How many containers (quotes, lists) are stacked inside each other at the deepest point.
    private func nesting(of blocks: [PlanBlock]) -> Int {
        blocks.map { nesting(of: $0) }.max() ?? 0
    }

    private func nesting(of block: PlanBlock) -> Int {
        switch block.kind {
        case .quote(let inner):
            return 1 + nesting(of: inner)
        case .list(_, _, let items):
            return 1 + (items.map { nesting(of: $0.blocks) }.max() ?? 0)
        default:
            return 0
        }
    }

    /// The text of every leaf block (heading, paragraph, code block, table cell), in document order.
    private func leafTexts(_ blocks: [PlanBlock]) -> [String] {
        var out: [String] = []
        func visit(_ block: PlanBlock) {
            switch block.kind {
            case .heading(_, let spans), .paragraph(let spans):
                out.append(spansText(spans))
            case .codeBlock(_, let text):
                out.append(text)
            case .table(let header, let rows):
                out.append(contentsOf: header.map(spansText))
                for row in rows { out.append(contentsOf: row.map(spansText)) }
            case .quote(let inner):
                inner.forEach(visit)
            case .list(_, _, let items):
                for item in items { item.blocks.forEach(visit) }
            case .rule:
                break
            }
        }
        blocks.forEach(visit)
        return out
    }

    private func assertBounded(_ run: (doc: PlanDocument, seconds: TimeInterval),
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(run.seconds, wellInside, "the parse took \(run.seconds) s", file: file, line: line)
        let deepest = nesting(of: run.doc.blocks)
        XCTAssertLessThanOrEqual(deepest, depthLimit, "the model nests \(deepest) containers deep", file: file, line: line)
    }

    // MARK: Quotes

    func testAMebibyteOfQuoteMarkersParsesToABoundedModel() throws {
        let run = try XCTUnwrap(parseOnSmallStack(String(repeating: ">", count: 1_048_576)))
        assertBounded(run)
    }

    func testAMillionQuoteMarkersBeforeAWordKeepTheWordAndABoundedModel() throws {
        let run = try XCTUnwrap(parseOnSmallStack(String(repeating: ">", count: 1_000_000) + " hello"))
        assertBounded(run)
        XCTAssertTrue(leafTexts(run.doc.blocks).contains("hello"), "the plan's text is still there")
    }

    func testFourHundredThousandSpacedQuoteMarkersBeforeAWordKeepTheWordAndABoundedModel() throws {
        let run = try XCTUnwrap(parseOnSmallStack(String(repeating: "> ", count: 400_000) + "hello"))
        assertBounded(run)
        XCTAssertTrue(leafTexts(run.doc.blocks).contains("hello"), "the plan's text is still there")
    }

    // MARK: Lists

    func testAMebibyteOfNestedListItemsKeepsEveryItemAndABoundedModel() throws {
        var text = ""
        var count = 0
        while text.utf8.count < 1_048_576 - 4_096 {
            text += String(repeating: " ", count: 2 * count) + "- item \(count)\n"
            count += 1
        }
        XCTAssertGreaterThan(count, 500, "the fixture is a deeply nested list")

        let run = try XCTUnwrap(parseOnSmallStack(text))
        assertBounded(run)
        let leaves = leafTexts(run.doc.blocks)
        XCTAssertTrue(leaves.contains("item 0"), "the first item is still there")
        XCTAssertTrue(leaves.contains("item \(count - 1)"), "the deepest item is still there")
    }

    // MARK: Containers inside containers, deep

    func testQuotesCodeBlocksAndTablesInsideDeepListsKeepTheirTextAndABoundedModel() throws {
        let levels = 600
        let withBlocks: Set<Int> = [0, 99, 199, 299, 399, 499, levels - 1]
        var lines: [String] = []
        for i in 0..<levels {
            let indent = String(repeating: " ", count: 2 * i)
            lines.append(indent + "- item \(i)")
            guard withBlocks.contains(i) else { continue }
            let inner = String(repeating: " ", count: 2 * (i + 1))
            lines += [
                "",
                inner + "> quote \(i)",
                "",
                inner + "```",
                inner + "code \(i)",
                inner + "```",
                "",
                inner + "| head | other |",
                inner + "| --- | --- |",
                inner + "| cell \(i) | value |",
                "",
            ]
        }

        let run = try XCTUnwrap(parseOnSmallStack(lines.joined(separator: "\n") + "\n"))
        assertBounded(run)
        let leaves = leafTexts(run.doc.blocks)
        XCTAssertTrue(leaves.contains("item 0"))
        XCTAssertTrue(leaves.contains("item \(levels - 1)"), "the deepest item is still there")
        for i in withBlocks.sorted() {
            XCTAssertTrue(leaves.contains("quote \(i)"), "the quote at level \(i) kept its text")
            XCTAssertTrue(leaves.contains("code \(i)"), "the code block at level \(i) kept its text")
            XCTAssertTrue(leaves.contains("cell \(i)"), "the table at level \(i) kept its cell")
        }
    }

    // MARK: Deep quotes and deep indentation followed by many spans (cost, not stack)

    /// A hostile plan's biggest shape: `levels` quote markers, then short emphasis spans to fill 256 KiB.
    /// Foundation takes time that grows with depth times the number of inline runs, cannot be cancelled,
    /// and the app does it again at every file-watch reload (7 s at 2,500 levels, 23 s at 10,000).
    private func quotesThenSpans(levels: Int) -> String {
        let total = 256 * 1024
        return String(repeating: ">", count: levels) + " " + String(repeating: "*a* ", count: (total - levels) / 4)
    }

    func testDeepQuotesFollowedByManyEmphasisSpansAreParsedInBoundedTime() throws {
        for levels in [2_500, 10_000] {
            let text = quotesThenSpans(levels: levels)
            XCTAssertLessThanOrEqual(text.utf8.count, 256 * 1024)
            let run = try XCTUnwrap(parseOnSmallStack(text))
            XCTAssertLessThan(run.seconds, wellInside, "\(levels) levels took \(run.seconds) s")
            let deepest = nesting(of: run.doc.blocks)
            XCTAssertLessThanOrEqual(deepest, depthLimit, "\(levels) levels: the model nests \(deepest) deep")
            XCTAssertTrue(leafTexts(run.doc.blocks).contains { $0.hasPrefix("a a a") }, "\(levels) levels: the spans' text is still there")
        }
    }

    // [work-count] The same shapes, counted in operations so a slow machine cannot flake it.
    func testDeepQuotesAndIndentsFollowedByManySpansStayWithinAWorkBudget() throws {
        // Each run's block path is walked: with the markers unbounded that is levels x runs (hundreds of
        // millions); bounded it is the depth limit x runs, a few million.
        let budget = 20_000_000
        let indented = (0 ..< 3_000).map { String(repeating: " ", count: 2 * $0) + "- item" }.joined(separator: "\n")
            + "\n" + String(repeating: " ", count: 6_000) + String(repeating: "*a* ", count: 40_000)
        for (name, text) in [("2,500 quotes", quotesThenSpans(levels: 2_500)),
                             ("10,000 quotes", quotesThenSpans(levels: 10_000)),
                             ("3,000 nested list levels", indented)] {
            let run = try XCTUnwrap(onSmallStack({ PlanMarkdown.parseCounting(text) }))
            XCTAssertLessThan(run.value.pathComponents, budget, "\(name): \(run.value.pathComponents) path components walked")
            XCTAssertLessThanOrEqual(nesting(of: run.value.document.blocks), depthLimit, name)
            XCTAssertTrue(leafTexts(run.value.document.blocks).contains { $0.contains("a a a") || $0 == "item" }, "\(name): the text is kept")
        }
    }

    func testTheSourceIsBoundedBeforeItIsParsedAndOnlyItsLinePrefixChanges() {
        let bound = PlanMarkdown.boundingNesting
        let maxQuotes = PlanMarkdown.maxQuoteMarkersPerLine

        let manyQuotes = bound(String(repeating: ">", count: 5_000) + " hello\n> next")
        XCTAssertEqual(manyQuotes, String(repeating: ">", count: maxQuotes) + "hello\n> next",
                       "markers past the cap are dropped with their white space, the text and the next line stay")
        let spaced = bound(String(repeating: "> ", count: 5_000) + "hello")
        XCTAssertEqual(spaced, String(repeating: "> ", count: maxQuotes) + "hello")

        let indent = bound(String(repeating: " ", count: 5_000) + "- deep")
        XCTAssertEqual(indent, String(repeating: " ", count: PlanMarkdown.maxIndentColumns) + "- deep")

        for untouched in ["# Title\n\n> one\n> > two\n\n- a\n  - b\n    - c\n\n    code\n",
                          "text with > inside and      spaces\n",
                          "```\n\(String(repeating: " ", count: 100))indented\n```\n",
                          "a\tb\n\t> quoted\n"] {
            XCTAssertEqual(bound(untouched), untouched, "ordinary text is not changed")
        }
        XCTAssertEqual(bound("x" + String(repeating: ">", count: 100)), "x" + String(repeating: ">", count: 100),
                       "only the line's own prefix counts: a > after text is text")
    }
}
