import XCTest
import NostromoKit

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

    private final class Outcome: @unchecked Sendable {
        var document: PlanDocument?
        var seconds: TimeInterval = 0
    }

    /// `PlanMarkdown.parse(text)` on a 512 KiB-stack thread. Nil (and a failure) if it never finishes.
    private func parseOnSmallStack(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (doc: PlanDocument, seconds: TimeInterval)? {
        let outcome = Outcome()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let start = Date()
            outcome.document = PlanMarkdown.parse(text)
            outcome.seconds = Date().timeIntervalSince(start)
            finished.signal()
        }
        thread.stackSize = 512 * 1024
        thread.qualityOfService = .utility
        thread.start()

        guard finished.wait(timeout: .now() + giveUp) == .success, let doc = outcome.document else {
            XCTFail("the parse did not finish within \(Int(giveUp)) s", file: file, line: line)
            return nil
        }
        return (doc, outcome.seconds)
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
}
