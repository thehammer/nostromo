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
    private func quotesThenSpans(levels: Int, spans: Int? = nil) -> String {
        let total = 256 * 1024
        return String(repeating: ">", count: levels) + " " + String(repeating: "*a* ", count: spans ?? (total - levels - 1) / 4)
    }

    /// The whole 256 KiB file. The emphasis spans alone cost Foundation a few seconds on a CI runner (they
    /// are the part no bound on nesting can remove), so the bound is that plus room; the unbounded parse of
    /// this file takes about a minute there (23 s on a developer Mac) and the harness gives up on it at 30 s.
    func testDeepQuotesFollowedByManyEmphasisSpansAreParsedInBoundedTime() throws {
        let levels = 10_000
        let text = quotesThenSpans(levels: levels)
        XCTAssertLessThanOrEqual(text.utf8.count, 256 * 1024)
        let run = try XCTUnwrap(parseOnSmallStack(text))
        XCTAssertLessThan(run.seconds, 15, "\(levels) levels took \(run.seconds) s")
        let deepest = nesting(of: run.doc.blocks)
        XCTAssertLessThanOrEqual(deepest, depthLimit, "\(levels) levels: the model nests \(deepest) deep")
        XCTAssertTrue(leafTexts(run.doc.blocks).contains { $0.hasPrefix("a a a") }, "\(levels) levels: the spans' text is still there")
    }

    // [work-count] The same shapes, counted in operations so a slow machine cannot flake it.
    func testDeepQuotesAndIndentsFollowedByManySpansStayWithinAWorkBudget() throws {
        // Each run's block path is walked: with the markers unbounded that is levels x runs; bounded it is
        // the depth limit x runs. Each `*a* ` is about two runs, so 3,000 spans are about 6,000 runs. Bounded,
        // a path is at most ~70 components, so about 420,000 in all. Unbounded: 2,500 quotes = 15 million,
        // 5,000 bullets (2 components each) = 60 million, 3,000 nested list levels about 36 million. So every
        // case is at least 5x over the budget and the bounded figure at least 7x under it: the guard still
        // trips on the old code, and the test costs a few seconds, not twelve.
        let budget = 3_000_000
        let indented = (0 ..< 3_000).map { String(repeating: " ", count: 2 * $0) + "- item" }.joined(separator: "\n")
            + "\n" + String(repeating: " ", count: 6_000) + String(repeating: "*a* ", count: 3_000)
        let bullets = String(repeating: "- ", count: 5_000) + String(repeating: "*a* ", count: 3_000)
        let numbered = String(repeating: "1. ", count: 5_000) + String(repeating: "*a* ", count: 3_000)
        let mixed = String(repeating: "> - ", count: 2_500) + String(repeating: "*a* ", count: 3_000)
        for (name, text) in [("5,000 bullets", bullets), ("5,000 numbered items", numbered), ("2,500 quote-bullet pairs", mixed),
                             ("2,500 quotes", quotesThenSpans(levels: 2_500, spans: 3_000)),
                             ("10,000 quotes", quotesThenSpans(levels: 10_000, spans: 3_000)),
                             ("3,000 nested list levels", indented)] {
            let run = try XCTUnwrap(onSmallStack({ PlanMarkdown.parseCounting(text) }))
            XCTAssertLessThan(run.value.pathComponents, budget, "\(name): \(run.value.pathComponents) path components walked")
            XCTAssertLessThanOrEqual(nesting(of: run.value.document.blocks), depthLimit, name)
            XCTAssertTrue(leafTexts(run.value.document.blocks).contains { $0.contains("a a a") || $0 == "item" }, "\(name): the text is kept")
        }
    }

    func testTheSourceIsBoundedBeforeItIsParsedAndOnlyItsLinePrefixChanges() {
        let bound = PlanMarkdown.boundingNesting
        let maxQuotes = PlanMarkdown.maxMarkersPerLine

        let manyQuotes = bound(String(repeating: ">", count: 5_000) + " hello\n> next")
        XCTAssertEqual(manyQuotes, String(repeating: ">", count: maxQuotes) + "hello\n> next",
                       "markers past the cap are dropped with their white space, the text and the next line stay")
        let spaced = bound(String(repeating: "> ", count: 5_000) + "hello")
        XCTAssertEqual(spaced, String(repeating: "> ", count: maxQuotes) + "hello")

        let bullets = bound(String(repeating: "- ", count: 5_000) + "item\n- next")
        XCTAssertEqual(bullets, String(repeating: "- ", count: maxQuotes) + "item\n- next", "bullets count toward the same cap")
        let numbered = bound(String(repeating: "12. ", count: 5_000) + "item")
        XCTAssertEqual(numbered, String(repeating: "12. ", count: maxQuotes) + "item")
        let mixed = bound(String(repeating: "> 1) * ", count: 5_000) + "item")
        XCTAssertEqual(mixed, String(repeating: "> 1) * ", count: 10) + "> 1) " + "item",
                       "quotes, ordered and bullet markers share one cap of \(maxQuotes): ten groups of three and two more")

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

    // MARK: Fenced code is left as written (the source bound only flattens what the parser would nest)

    /// A line of 200 spaces and an x: past `maxIndentColumns`, so the bound cuts it anywhere it applies.
    private var wideLine: String { String(repeating: " ", count: 200) + "x" }
    /// `wideLine` as the bound leaves an ordinary line.
    private var boundedWideLine: String { String(repeating: " ", count: PlanMarkdown.maxIndentColumns) + "x" }
    /// 5,000 quote markers and a word: past `maxMarkersPerLine`.
    private var manyQuotes: String { String(repeating: ">", count: 5_000) + " hello" }
    /// `manyQuotes` as the bound leaves an ordinary line.
    private var boundedQuotes: String { String(repeating: ">", count: PlanMarkdown.maxMarkersPerLine) + "hello" }

    /// `XCTAssertEqual` for the long texts here: a failure names the first line that differs instead of
    /// printing both texts in full.
    private func assertSameText(_ actual: String, _ expected: String, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard actual != expected else { return }
        let got = actual.components(separatedBy: "\n")
        let want = expected.components(separatedBy: "\n")
        let shared = min(got.count, want.count)
        let first = (0 ..< shared).first(where: { got[$0] != want[$0] }) ?? shared
        func describe(_ lines: [String]) -> String {
            first < lines.count ? "\(lines[first].utf8.count) bytes" : "no such line"
        }
        XCTFail("\(what): line \(first + 1) differs (\(describe(got)), where \(describe(want)) were expected)", file: file, line: line)
    }

    func testFencedCodeKeepsItsIndentationPastTheColumnCap() {
        let wide = wideLine
        let tabs = String(repeating: "\t", count: 40) + "x"
        let fences: [(String, String)] = [
            ("backticks", "```\n\(wide)\n```\n"),
            ("tildes", "~~~\n\(wide)\n~~~\n"),
            ("an info string", "```swift\n\(wide)\n```\n"),
            ("a tilde fence whose info string has a backtick", "~~~ a`b\n\(wide)\n~~~\n"),
            ("a four-backtick fence holding a three-backtick line", "````\n```\n\(wide)\n````\n"),
            ("a tilde fence holding backticks", "~~~\n```\n\(wide)\n~~~\n"),
            ("a backtick fence holding tildes", "```\n~~~\n\(wide)\n```\n"),
            ("tabs that add up to more than the cap", "```\n\(tabs)\n```\n"),
            ("text before it", "# Plan\n\nSome words.\n\n```\n\(wide)\n```\n"),
        ]
        for (name, text) in fences {
            assertSameText(PlanMarkdown.boundingNesting(text), text, name)
        }
    }

    func testQuoteAndBulletMarkersInsideAFenceAreLeftAloneAndTheSameLinesAfterItAreBounded() {
        let quotes = manyQuotes
        let bullets = String(repeating: "- ", count: 5_000) + "item"
        let after = "\(quotes)\n\(bullets)\n"
        let boundedAfter = "\(boundedQuotes)\n\(String(repeating: "- ", count: PlanMarkdown.maxMarkersPerLine))item\n"
        for fence in ["```", "~~~"] {
            let inside = "\(fence)\n\(quotes)\n\(bullets)\n\(fence)\n"
            assertSameText(PlanMarkdown.boundingNesting(inside + after), inside + boundedAfter,
                           "\(fence): the fenced lines stay whole, the same lines after it are bounded")
        }
    }

    func testOnlyAProperClosingLineEndsAFence() {
        let wide = wideLine
        // Each of these closes the fence: the wide line after it is an ordinary line again.
        for closer in ["```", "````", "```   ", "```\t", "   ```", " ```  "] {
            let text = "```\n\(wide)\n\(closer)\n\(wide)\n"
            let expected = "```\n\(wide)\n\(closer)\n\(boundedWideLine)\n"
            assertSameText(PlanMarkdown.boundingNesting(text), expected, "closed by \(closer.debugDescription)")
        }
        // None of these does: they are lines of the code, and the fence is still open after them.
        for notCloser in ["    ```", "``", "``` x", "~~~", "\t```"] {
            let text = "```\n\(wide)\n\(notCloser)\n\(wide)\n"
            assertSameText(PlanMarkdown.boundingNesting(text), text, "not closed by \(notCloser.debugDescription)")
        }
        // A longer fence is closed only by one at least as long, of the same character.
        let longer = "~~~~\n~~~\n\(wide)\n~~~~~\n\(wide)\n"
        assertSameText(PlanMarkdown.boundingNesting(longer), "~~~~\n~~~\n\(wide)\n~~~~~\n\(boundedWideLine)\n",
                       "a four-tilde fence is closed by five")
    }

    func testTextBetweenTwoFencesIsBoundedAndBothFencesAreKept() {
        let fence = "```\n\(wideLine)\n\(manyQuotes)\n```\n"
        let text = "\(fence)\(wideLine)\n\(manyQuotes)\n\(fence)"
        let expected = "\(fence)\(boundedWideLine)\n\(boundedQuotes)\n\(fence)"
        assertSameText(PlanMarkdown.boundingNesting(text), expected, "each fence is its own; what lies between is bounded")
    }

    func testAnUnclosedFenceRunsToTheEndOfTheText() {
        let tail = "\(wideLine)\n\(manyQuotes)\n\(String(repeating: "- ", count: 5_000))item"
        for opener in ["```", "~~~", "````swift"] {
            let text = "# Plan\n\n\(opener)\n\(tail)"
            assertSameText(PlanMarkdown.boundingNesting(text), text, "everything after an unclosed \(opener) is left as written")
        }
    }

    /// [guard] Each case is one where the parser's idea of the structure can differ from a fence tracker's,
    /// so the line after it, 5,000 quote markers, must still be cut to `maxMarkersPerLine`. These are how
    /// the old code behaved, too: they stay green, and fail if the tracker believes a fence the parser
    /// would not see (the bound is the only thing between such a line and a cost the parser cannot cancel).
    func testAFenceTheParserMightNotSeeIsNotTrustedAndTheLineAfterItStaysBounded() {
        let cases: [(String, String)] = [
            ("a fence inside a list item", "- x\n  ```\n"),
            ("a fence on a bullet's own line", "- ```\n"),
            ("a fence on an ordered item's own line", "1. ```\n"),
            ("a fence inside a quote", "> ```\nfoo\n"),
            ("a backtick fence with a backtick in its info string", "```a`b\n"),
            ("a fence indented one space", " ```\n"),
            ("a fence indented two spaces", "  ```\n"),
            ("a fence indented three spaces", "   ```\n"),
            ("a tilde fence indented", "  ~~~\n"),
            ("two backticks", "``\n"),
            ("a fence after an HTML comment opens", "<!--\n```\n-->\n"),
            ("a fence after an HTML tag", "<div>\n```\n</div>\n"),
            ("a fence after an HTML tag indented three spaces", "   <div>\n```\n</div>\n"),
            ("a fence that opens after an HTML line and a blank one", "<b>hi</b>\n\n```\n"),
            // The parser has a top-level fence open after the indented opener and the fence line at the
            // start of the next line CLOSES it; a tracker that took that line for an opener would copy
            // everything after it as code while the parser reads it as markdown.
            ("an indented fence closed by a fence line at the start of a line", " ```\n```\n"),
            ("the same with tildes and two spaces", "  ~~~\n~~~\n"),
            ("an indented fence, its closer and another opener", "   ```\n```\n```\n"),
            ("an indented fence and a fence line of the other character", " ```\n~~~\n"),
        ]
        for (name, prefix) in cases {
            assertSameText(PlanMarkdown.boundingNesting("\(prefix)\(manyQuotes)\n"), "\(prefix)\(boundedQuotes)\n", name)
        }
    }

    /// A fence at the start of a line is honoured until something makes the bound and the parser possibly
    /// disagree about fences; from there on every line is bounded, whatever follows.
    func testFenceRecognitionStopsForGoodAtTheFirstLineThatCouldMakeTheParserDisagree() {
        let fenced = "```\n\(wideLine)\n```\n"
        for (name, doubt) in [("an indented fence", " ```\n"), ("an HTML line", "<b>hi</b>\n")] {
            let text = "\(fenced)\(doubt)```\n\(wideLine)\n\(manyQuotes)\n~~~\n\(wideLine)\n"
            let expected = "\(fenced)\(doubt)```\n\(boundedWideLine)\n\(boundedQuotes)\n~~~\n\(boundedWideLine)\n"
            assertSameText(PlanMarkdown.boundingNesting(text), expected,
                           "the fence before \(name) is kept whole, everything after it is bounded")
        }
    }

    func testACodeBlockKeepsTheWhiteSpaceOfItsLinesInTheParsedModel() throws {
        let indent = String(repeating: " ", count: 200)
        let run = try XCTUnwrap(parseOnSmallStack("```\n\(indent)x\n```\n"))
        assertBounded(run)
        var code: [String] = []
        for block in run.doc.blocks {
            if case .codeBlock(_, let text) = block.kind { code.append(text) }
        }
        XCTAssertEqual(code.count, 1, "the fence is one code block")
        XCTAssertTrue(code.first?.hasPrefix(indent + "x") == true,
                      "the 200 spaces survive: \(code.first?.prefix(140).debugDescription ?? "no code block")")
    }

    /// [guard] A GFM table row followed, with no blank line, by a fence line at column 0: the tracker takes
    /// the line for a fence opener, so the parser must too (a fence interrupts a table), or the wide line
    /// would be copied whole as "code" while the parser reads it as table text.
    func testAFenceLineRightAfterATableRowIsACodeBlockForTheParserAndTheTracker() throws {
        let indent = String(repeating: " ", count: 200)
        let text = "| a | b |\n|---|---|\n| 1 | 2 |\n```\n\(indent)x\n```\n"

        assertSameText(PlanMarkdown.boundingNesting(text), text, "the tracker keeps the fenced line whole")
        let run = try XCTUnwrap(parseOnSmallStack(text))
        var code: [String] = []
        var tables = 0
        for block in run.doc.blocks {
            switch block.kind {
            case .codeBlock(_, let body): code.append(body)
            case .table: tables += 1
            default: break
            }
        }
        XCTAssertEqual(tables, 1, "the table is one block")
        XCTAssertEqual(code.count, 1, "the fence after it is one code block")
        XCTAssertTrue(code.first?.hasPrefix(indent + "x") == true,
                      "the parser keeps the 200 spaces: \(code.first?.prefix(140).debugDescription ?? "no code block")")
    }
}
