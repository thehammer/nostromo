import XCTest
@testable import NostromoKit

// Contract: `MarkdownFences.segments(of:)` splits transcript text into prose and fenced code,
// byte-exactly, so the Mac renderer can draw code as code and nothing else as code.
//
// Every case is a small literal. Two invariants run over all of them: the segments reproduce the
// (line-ending normalised) input exactly, and `containsFence` agrees with `segments(of:)`.

final class MarkdownFencesTests: XCTestCase {

    // MARK: Helpers

    private typealias Segment = MarkdownFences.Segment
    private typealias CodeBlock = MarkdownFences.CodeBlock

    private func codeBlocks(_ text: String) -> [CodeBlock] {
        MarkdownFences.segments(of: text).compactMap {
            if case .code(let block) = $0 { return block }
            return nil
        }
    }

    private func singleBlock(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> CodeBlock {
        let blocks = codeBlocks(text)
        XCTAssertEqual(blocks.count, 1, "expected exactly one code block in \(text.debugDescription)", file: file, line: line)
        return try XCTUnwrap(blocks.first, file: file, line: line)
    }

    private func text(of segment: Segment) -> String {
        switch segment {
        case .prose(let s): return s
        case .code(let block): return block.source
        }
    }

    /// Every input the per-case tests use, for the invariants at the bottom.
    private let corpus: [(name: String, text: String)] = [
        ("backtick fence", "before\n```\nx = 1\n```\nafter"),
        ("tilde fence", "before\n~~~\nx = 1\n~~~\nafter"),
        ("info php", "```php\n$a = 1;\n```"),
        ("info with attributes", "```python title=x\nprint(1)\n```"),
        ("bare fence", "```\nplain\n```"),
        ("four-backtick fence containing three-backtick line", "````\n```\ninner\n```\n````"),
        ("tilde fence containing backticks", "~~~\n```\nnot a closer\n```\n~~~"),
        ("closer shorter than the opener", "````\nline\n```\nstill code\n````"),
        ("closer with trailing spaces", "```\ncode\n```   \nafter"),
        ("fence indented three spaces", "   ```\n   a\n     b\n   ```"),
        ("fence indented six spaces", "      ```\n      a\n        b\n      ```"),
        ("content indented less than the fence", "      ```\nx\n  y\n      z\n      ```"),
        ("no blank line before or after", "text\n```\ncode\n```\nmore text"),
        ("unterminated", "intro\n```sh\nline one\nline two"),
        ("inline triple backticks mid-prose", "use ```x``` inline in prose"),
        ("empty block", "```\n```"),
        ("CRLF input", "before\r\n```php\r\n$a = 1;\r\n$b = 2;\r\n```\r\nafter\r\n"),
        ("no fence at all", "# Title\n\n- one\n- two\n\nplain `code` and **bold**"),
        ("two blocks back to back", "```\na\n```\n```\nb\n```"),
        ("empty input", ""),
    ]

    // MARK: Fence characters and info strings

    func testABacktickFenceIsACodeBlockWithItsContentAndNeitherFenceLine() throws {
        let block = try singleBlock("before\n```\nx = 1\ny = 2\n```\nafter")
        XCTAssertEqual(block.code, "x = 1\ny = 2")
        XCTAssertTrue(block.isClosed)
        XCTAssertEqual(block.source, "```\nx = 1\ny = 2\n```")
    }

    func testATildeFenceIsACodeBlockToo() throws {
        let block = try singleBlock("before\n~~~\nx = 1\n~~~\nafter")
        XCTAssertEqual(block.code, "x = 1")
        XCTAssertTrue(block.isClosed)
    }

    func testTheFirstWordOfTheInfoStringIsTheLanguage() throws {
        let block = try singleBlock("```php\n$a = 1;\n```")
        XCTAssertEqual(block.info, "php")
        XCTAssertEqual(block.language, "php")
    }

    func testTheWholeInfoStringIsKeptAndOnlyItsFirstWordIsTheLanguage() throws {
        let block = try singleBlock("```python title=x\nprint(1)\n```")
        XCTAssertEqual(block.info, "python title=x")
        XCTAssertEqual(block.language, "python")
    }

    func testABareFenceHasNoInfoAndNoLanguage() throws {
        let block = try singleBlock("```\nplain\n```")
        XCTAssertEqual(block.info, "")
        XCTAssertNil(block.language)
    }

    // MARK: What closes a block and what is only content

    func testALongerFenceContainsAShorterOneAsContent() throws {
        let block = try singleBlock("````\n```\ninner\n```\n````")
        XCTAssertEqual(block.code, "```\ninner\n```")
        XCTAssertTrue(block.isClosed)
    }

    func testATildeFenceContainsBacktickFencesAsContent() throws {
        let block = try singleBlock("~~~\n```\nnot a closer\n```\n~~~")
        XCTAssertEqual(block.code, "```\nnot a closer\n```")
        XCTAssertTrue(block.isClosed)
    }

    func testACloserShorterThanTheOpenerIsContent() throws {
        let block = try singleBlock("````\nline\n```\nstill code\n````\nafter")
        XCTAssertEqual(block.code, "line\n```\nstill code")
        XCTAssertTrue(block.isClosed)
    }

    func testACloserWithTrailingSpacesStillCloses() {
        let segments = MarkdownFences.segments(of: "```\ncode\n```   \nafter")
        XCTAssertEqual(segments.count, 2)
        guard segments.count == 2, case .code(let block) = segments[0] else { return XCTFail("expected code then prose: \(segments)") }
        XCTAssertEqual(block.code, "code")
        XCTAssertTrue(block.isClosed)
        XCTAssertEqual(segments[1], .prose("after"))
    }

    // MARK: Indentation

    func testAFenceIndentedThreeSpacesRemovesThatIndentFromItsContent() throws {
        let block = try singleBlock("   ```\n   a\n     b\n   ```")
        XCTAssertEqual(block.code, "a\n  b")
        XCTAssertTrue(block.isClosed)
    }

    func testAFenceIndentedSixSpacesRemovesThatIndentFromItsContent() throws {
        let block = try singleBlock("      ```\n      a\n        b\n      ```")
        XCTAssertEqual(block.code, "a\n  b", "a fence nested in a list item is still a fence, and its content is de-indented")
        XCTAssertTrue(block.isClosed)
    }

    func testContentIndentedLessThanTheFenceLosesNoCharactersThatAreNotIndentation() throws {
        // Column-0 content under a six-space fence is untouched; partly indented content loses only
        // the spaces it has; indentation beyond the fence's is kept.
        let block = try singleBlock("      ```\nx\n  y\n      z\n        w\n      ```")
        XCTAssertEqual(block.code, "x\ny\nz\n  w")
    }

    func testTheSourceKeepsTheOriginalIndentationAndFenceLines() throws {
        let input = "   ```\n   a\n   ```"
        XCTAssertEqual(try singleBlock(input).source, input)
    }

    // MARK: Boundaries

    func testNoBlankLineIsNeededBeforeOrAfterAFence() {
        let segments = MarkdownFences.segments(of: "text\n```\ncode\n```\nmore text")
        XCTAssertEqual(segments.count, 3)
        guard segments.count == 3 else { return }
        XCTAssertEqual(segments[0], .prose("text"))
        if case .code(let block) = segments[1] { XCTAssertEqual(block.code, "code") } else { XCTFail("middle segment is not code") }
        XCTAssertEqual(segments[2], .prose("more text"))
    }

    func testAnUnterminatedFenceRunsToTheEndOfTheText() throws {
        let block = try singleBlock("intro\n```sh\nline one\nline two")
        XCTAssertFalse(block.isClosed)
        XCTAssertEqual(block.info, "sh")
        XCTAssertEqual(block.code, "line one\nline two")
    }

    func testAnUnterminatedFenceWithNoContentYetIsAnEmptyOpenBlock() throws {
        let block = try singleBlock("intro\n```")
        XCTAssertFalse(block.isClosed)
        XCTAssertEqual(block.code, "")
    }

    func testTripleBackticksInTheMiddleOfAProseLineAreNotAFence() {
        let input = "use ```x``` inline in prose"
        XCTAssertTrue(codeBlocks(input).isEmpty)
        XCTAssertEqual(MarkdownFences.segments(of: input), [.prose(input)])
    }

    func testTripleBackticksWithTextAfterThemOnTheSameLineAreNotAnOpener() {
        // A backtick fence's info string may not contain a backtick.
        XCTAssertTrue(codeBlocks("```x``` and more\nnext line").isEmpty)
    }

    func testAnEmptyBlockHasEmptyCode() throws {
        let block = try singleBlock("```\n```")
        XCTAssertEqual(block.code, "")
        XCTAssertTrue(block.isClosed)
    }

    func testTwoBlocksBackToBackAreTwoBlocks() {
        let blocks = codeBlocks("```\na\n```\n```\nb\n```")
        XCTAssertEqual(blocks.map(\.code), ["a", "b"])
    }

    func testCRLFLineEndingsAreNormalisedAndNeverReachTheCode() throws {
        let block = try singleBlock("before\r\n```php\r\n$a = 1;\r\n$b = 2;\r\n```\r\nafter\r\n")
        XCTAssertEqual(block.code, "$a = 1;\n$b = 2;")
        XCTAssertEqual(block.language, "php")
        XCTAssertTrue(block.isClosed)
        XCTAssertFalse(block.source.contains("\r"))
    }

    // MARK: Invariants over every case

    func testTheSegmentsReproduceTheNormalisedInputExactlyForEveryCase() {
        for (name, input) in corpus {
            let rebuilt = MarkdownFences.segments(of: input).map(text(of:)).joined(separator: "\n")
            XCTAssertEqual(rebuilt, input.replacingOccurrences(of: "\r\n", with: "\n"), "\(name): segments do not reproduce the input")
        }
    }

    func testContainsFenceAgreesWithTheSegmentsForEveryCase() {
        for (name, input) in corpus {
            let hasCode = !codeBlocks(input).isEmpty
            XCTAssertEqual(MarkdownFences.containsFence(input), hasCode, "\(name): containsFence disagrees with segments(of:)")
        }
    }

    func testTextWithoutAFenceIsASingleProseSegment() {
        let input = "# Title\n\n- one\n- two\n\nplain `code` and **bold**"
        XCTAssertEqual(MarkdownFences.segments(of: input), [.prose(input)])
        XCTAssertFalse(MarkdownFences.containsFence(input))
    }

    // MARK: The reported message

    private let sqlLine = #"SELECT REPLACE(job_class,'App\\Modules\\Referrals\\Jobs\\','') job, status, outcome_quality, LEFT(COALESCE(error_message,'-'),60) err, COALESCE(completed_at,updated_at) at FROM pipeline_job_runs WHERE referral_id = 14464 ORDER BY id DESC LIMIT 20"#

    private let phpLines = [
        #"$referral = \App\Modules\Referrals\Models\Referral::findOrFail(14464);"#,
        #"$result = app(\App\Modules\Referrals\Services\ReprocessReferralPipelineService::class)->reprocess($referral);"#,
        #"$result->documentCount;"#,
    ]

    func testTheReportedMessageIsProseThenThreeCodeBlocksSeparatedByProse() throws {
        let segments = MarkdownFences.segments(of: MarkdownFenceFixtures.reportedMessage)
        XCTAssertEqual(segments.count, 7, "expected prose, code, prose, code, prose, code, prose")
        guard segments.count == 7 else { return }

        let shape = segments.map { segment -> String in
            switch segment {
            case .prose: return "prose"
            case .code(let block): return "code(\(block.info))"
            }
        }
        XCTAssertEqual(shape, ["prose", "code()", "prose", "code(php)", "prose", "code(sql)", "prose"])

        guard case .code(let bare) = segments[1], case .code(let php) = segments[3], case .code(let sql) = segments[5] else {
            return XCTFail("code segments are not where the shape says: \(shape)")
        }
        for block in [bare, php, sql] { XCTAssertTrue(block.isClosed) }

        XCTAssertNil(bare.language)
        XCTAssertEqual(php.language, "php")
        XCTAssertEqual(sql.language, "sql")
        XCTAssertTrue(bare.code.hasPrefix("aws ecs execute-command --profile production-developers"))
        XCTAssertTrue(bare.code.hasSuffix(#"--command "php artisan tinker""#))
        XCTAssertFalse(bare.code.contains("\n"), "the staged command is a single line")
    }

    func testTheReportedMessagesSQLBlockIsTheOneLineByteForByte() throws {
        let blocks = codeBlocks(MarkdownFenceFixtures.reportedMessage)
        let sql = try XCTUnwrap(blocks.first { $0.language == "sql" })
        XCTAssertEqual(sql.code, sqlLine)
        XCTAssertTrue(sql.code.contains(#"'App\\Modules\\Referrals\\Jobs\\'"#), "the doubled backslashes survive untouched")
        XCTAssertEqual(sql.code.filter { $0 == "_" }.count, sqlLine.filter { $0 == "_" }.count)
    }

    func testTheReportedMessagesPHPBlockIsItsThreeLinesExactly() throws {
        let blocks = codeBlocks(MarkdownFenceFixtures.reportedMessage)
        let php = try XCTUnwrap(blocks.first { $0.language == "php" })
        XCTAssertEqual(php.code, phpLines.joined(separator: "\n"))
    }

    func testTheReportedMessagesProseKeepsItsInlineMarkupForTheRendererToHandle() {
        let prose = MarkdownFences.segments(of: MarkdownFenceFixtures.reportedMessage).compactMap { segment -> String? in
            if case .prose(let s) = segment { return s }
            return nil
        }
        XCTAssertTrue(prose.first?.hasPrefix("Both alerts are resolved: `PORTAL_DEV-1Q0` and `PORTAL_DEV-1Q1`.") ?? false)
        XCTAssertTrue(prose.contains { $0.contains("**Staged command**") })
        XCTAssertTrue(prose.last?.hasSuffix("Tell me when you've run it and I'll check the result.") ?? false)
        XCTAssertFalse(prose.contains { $0.contains("```") }, "no fence line leaks into prose")
    }

    func testTheReportedMessageReconstructsExactlyAndContainsAFence() {
        let input = MarkdownFenceFixtures.reportedMessage
        XCTAssertTrue(MarkdownFences.containsFence(input))
        XCTAssertEqual(MarkdownFences.segments(of: input).map(text(of:)).joined(separator: "\n"), input)
    }
}
