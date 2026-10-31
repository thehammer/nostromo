import XCTest
import AppKit
import Combine
import NostromoKit

// MF4 fix-up, the tests that outlive the red phase (PlanFixupRedTests holds the first red ones):
//
//   - PlanDisplayLimitsTests    a plan has a cost ceiling: rows, characters, characters and lines per row;
//                               past it the plan stops and says so, the whole file one click away.
//   - PlanViewFixupTests        link hosts, the header's file name, an empty plan, a file that is not
//                               markdown, accessibility of the blocks and the buttons.
//   - PlanChecklistFollowTests  the Overview's checklist follows its file (injected loader, watcher only
//                               while the Overview shows, no read per progress tick, same rows for same items).
//
// Real files in temp directories, the real loader and a real (invisible) window; only the outside world
// (open, reveal, copy) is recorded. Waits are conditions pumped on the main run loop: the timeouts are
// failure bounds, never durations a test depends on. The 1 MiB cases are slow by nature (a read and a
// parse of a megabyte), which is why their wait bound is generous; their assertions are COUNTS.

// MARK: - Shared rig for the plan view

/// What the outside world was asked to do.
fileprivate final class FixupRecorder {
    var openedPlans: [String] = []
    var openedURLs: [URL] = []
    var revealed: [URL] = []
    var copied: [String] = []

    var actions: PlanViewActions {
        PlanViewActions(openPlan: { [weak self] in self?.openedPlans.append($0) },
                        openURL: { [weak self] in self?.openedURLs.append($0) },
                        reveal: { [weak self] in self?.revealed.append($0) },
                        copy: { [weak self] in self?.copied.append($0) })
    }
}

fileprivate struct FixupRig {
    let view: PlanDocumentView
    let container: NSView
    let window: NSWindow
    let path: String
    let recorder: FixupRecorder
    let loader: PlanFileLoader
}

/// A plan view, `width` x `height`, filling a container of exactly that size inside an invisible window.
fileprivate func makeFixupRig(_ test: XCTestCase, path: String, width: CGFloat = 700, height: CGFloat = 600,
                              loader: PlanFileLoader = PlanFileLoader()) -> FixupRig {
    let window = MDFixedWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 800),
                               styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.alphaValue = 0
    window.orderFront(nil)
    test.addTeardownBlock { window.orderOut(nil); window.contentView = nil }

    let recorder = FixupRecorder()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    window.contentView?.addSubview(container)
    let view = PlanDocumentView(frame: container.bounds, loader: loader, actions: recorder.actions)
    container.addSubview(view)
    return FixupRig(view: view, container: container, window: window, path: path, recorder: recorder, loader: loader)
}

// MARK: - 6. Display limits

final class PlanDisplayLimitsTests: XCTestCase {

    private static let mebibyte = 1_048_576
    private typealias Limits = PlanDisplayLimits

    // MARK: Rig

    private struct Opened {
        let rig: FixupRig
        /// The longest single stretch the main thread was busy while the plan was read, parsed and applied.
        let longestStall: TimeInterval
    }

    /// Write `text` as `plan.md`, show it, and wait for `.document`. Parsing is off the main thread (and as
    /// slow as a megabyte of markdown is); what must stay short is each stretch the MAIN thread is busy.
    private func open(_ text: String, width: CGFloat = 700, height: CGFloat = 600,
                      file: StaticString = #filePath, line: UInt = #line) throws -> Opened {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("plan.md")
        try Data(text.utf8).write(to: url)
        XCTAssertLessThanOrEqual(text.utf8.count, Self.mebibyte, "the fixture itself must be loadable", file: file, line: line)
        return try show(url, width: width, height: height, file: file, line: line)
    }

    private func show(_ url: URL, width: CGFloat = 700, height: CGFloat = 600,
                      file: StaticString = #filePath, line: UInt = #line) throws -> Opened {
        let rig = makeFixupRig(self, path: url.path, width: width, height: height)
        rig.view.show(planPath: rig.path)
        rig.view.setActive(true)

        var longest: TimeInterval = 0
        let end = Date().addingTimeInterval(180)   // a failure bound
        while rig.view.state != .document, Date() < end {
            let began = Date()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            longest = max(longest, Date().timeIntervalSince(began))
        }
        XCTAssertEqual(rig.view.state, .document, "the plan never reached .document", file: file, line: line)
        rig.view.layoutSubtreeIfNeeded()
        return Opened(rig: rig, longestStall: longest)
    }

    private func scroll(_ view: PlanDocumentView, toY y: CGFloat) {
        let clip = view.documentScrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        view.documentScrollView.reflectScrolledClipView(clip)
        view.layoutSubtreeIfNeeded()
    }

    private func scrollToTheBottom(_ view: PlanDocumentView) {
        let flow = view.documentContentView
        scroll(view, toY: max(0, flow.frame.height - view.documentScrollView.contentView.bounds.height))
    }

    private func noticeRows(_ view: PlanDocumentView) -> [NSView] {
        view.documentContentView.subviews.filter { NSStringFromClass(type(of: $0)).contains("PlanNoticeRow") }
    }

    private func codeText(_ view: PlanDocumentView) throws -> String {
        try XCTUnwrap(view.codeScrollViews.first?.documentView as? NSTextView, "the code block is shown").string
    }

    private func tableText(_ view: PlanDocumentView) throws -> String {
        try XCTUnwrap(view.tableScrollViews.first?.documentView as? NSTextView, "the table is shown").string
    }

    private func lineCount(_ text: String) -> Int { text.components(separatedBy: "\n").count }

    /// The notice is the last row, says what happened, and its Copy path button copies the plan's path.
    private func assertTheNotice(_ opened: Opened, file: StaticString = #filePath, line: UInt = #line) {
        let view = opened.rig.view
        XCTAssertTrue(view.isTruncatedForDisplay, "the view says it cut the plan", file: file, line: line)
        scrollToTheBottom(view)
        let notices = noticeRows(view)
        guard notices.count == 1, let notice = notices.first else {
            return XCTFail("expected exactly one 'plan truncated for display' row at the bottom, found \(notices.count)", file: file, line: line)
        }
        let others = view.documentContentView.subviews.filter { $0 !== notice }
        XCTAssertTrue(others.allSatisfy { $0.frame.maxY <= notice.frame.minY + 0.5 }, "the notice is the LAST row", file: file, line: line)
        XCTAssertEqual(notice.frame.maxY, view.documentContentView.frame.height - 24, accuracy: 1, "and nothing follows it", file: file, line: line)

        let fields = MD.allSubviews(notice).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue.hasPrefix("Plan truncated for display") }, "it says so: \(fields.map(\.stringValue))", file: file, line: line)

        let copy = MD.allSubviews(notice).compactMap { $0 as? NSButton }.first { $0.title == "Copy path" }
        guard let copy else { return XCTFail("the notice has no Copy path button", file: file, line: line) }
        XCTAssertFalse(copy.isHiddenOrHasHiddenAncestor, file: file, line: line)
        _ = copy.sendAction(copy.action, to: copy.target)
        XCTAssertEqual(opened.rig.recorder.copied, [opened.rig.path], "Copy path copies the plan's path", file: file, line: line)
        XCTAssertTrue(opened.rig.recorder.openedPlans.isEmpty && opened.rig.recorder.revealed.isEmpty, file: file, line: line)
    }

    /// The longest stretch the main thread may be busy at a time. The measured worst case is 1.9 s (a
    /// megabyte of short paragraphs, on a developer Mac); a plan whose rows are not bounded takes tens of
    /// seconds, so this catches a real regression with room for a slow CI runner. The row and character
    /// counts below are the primary guard: they do not depend on the machine.
    private static let stallBound: TimeInterval = 6

    /// The counts every truncated plan keeps, whatever it was made of.
    private func assertBounded(_ opened: Opened, file: StaticString = #filePath, line: UInt = #line) {
        let view = opened.rig.view
        XCTAssertLessThanOrEqual(view.rowCount, Limits.maxRows + 1, "rows: at most the limit and the notice", file: file, line: line)
        XCTAssertLessThanOrEqual(view.displayedCharacterCount, Limits.maxCharacters, "characters over all rows", file: file, line: line)
        XCTAssertLessThan(opened.longestStall, Self.stallBound, "the main thread was busy for \(opened.longestStall) s at a stretch", file: file, line: line)
    }

    /// A layout at another width completes and leaves the document as wide as the view.
    private func assertRelayoutAtAnotherWidth(_ opened: Opened, file: StaticString = #filePath, line: UInt = #line) {
        let rig = opened.rig
        let began = Date()
        let size = NSSize(width: 300, height: 500)
        rig.container.setFrameSize(size)
        rig.view.setFrameSize(size)
        rig.view.needsLayout = true
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(Date().timeIntervalSince(began), 15, "a re-layout at another width took too long", file: file, line: line)
        XCTAssertLessThanOrEqual(rig.view.documentContentView.frame.width, size.width + 1, "the document follows the width", file: file, line: line)
        XCTAssertEqual(rig.view.state, .document, file: file, line: line)
    }

    // MARK: Text of 1 MiB

    private func paragraphsOf(count: Int, text: (Int) -> String) -> String {
        (0 ..< count).map(text).joined(separator: "\n\n") + "\n"
    }

    /// 1,048,576 bytes of one-character paragraphs.
    private var megabyteOfShortParagraphs: String { String(repeating: "p\n\n", count: 349_525) + "p" }

    /// Roughly 1 MiB of lines of about 60 bytes in one fenced block.
    private func megabyteFencedBlock(line: String, fence: String = "```") -> String {
        let n = (Self.mebibyte - 2 * (fence.utf8.count + 1) - 8) / line.utf8.count
        return fence + "\n" + String(repeating: line, count: n) + fence + "\n"
    }

    // MARK: (a) many rows

    func testAMegabyteOfShortParagraphsIsCutToTheRowLimitWithANoticeAtTheEnd() throws {
        let opened = try open(megabyteOfShortParagraphs)
        let view = opened.rig.view

        XCTAssertEqual(view.state, .document)
        assertBounded(opened)
        XCTAssertGreaterThan(view.rowCount, 1_000, "it is cut, not dropped: the plan is still a long document")
        XCTAssertEqual(view.rowCount, Limits.maxRows + 1, "the rows up to the limit, then the notice")
        XCTAssertEqual(view.headings.count, 0)
        XCTAssertEqual(view.outlineButton.menu?.items.count, 1, "the outline has only its own title: no heading is shown")
        assertTheNotice(opened)
        assertRelayoutAtAnotherWidth(opened)
    }

    func testAMegabyteOfHeadingsListsOnlyTheShownOnesInTheOutlineAndWindowsTheirViews() throws {
        let opened = try open(String(repeating: "# h\n\n", count: 209_715))
        let view = opened.rig.view
        assertBounded(opened)

        XCTAssertEqual(view.headings.count, Limits.maxRows, "a heading is a row: the shown ones are the rows")
        let entries = Array(try XCTUnwrap(view.outlineButton.menu).items.dropFirst())
        XCTAssertLessThanOrEqual(entries.count, Limits.maxRows, "no outline entry for a heading that has no row")
        XCTAssertEqual(entries.count, view.headings.count, "the outline lists what is shown, nothing else")
        XCTAssertLessThanOrEqual(view.headingViews.count, 300, "thousands of headings are windowed like any row, not all built")
        XCTAssertLessThan(view.documentContentView.subviews.count, 400)
        assertTheNotice(opened)
        assertRelayoutAtAnotherWidth(opened)
    }

    func testTheOutlineOfATruncatedPlanListsEveryShownHeadingAndNoOthers() throws {
        // 3,000 sections: only the first part is shown, and every outline entry must be one of those
        let sections = (0 ..< 3_000).map { "## Section \($0)\n\nbody \($0)\n" }.joined(separator: "\n")
        let opened = try open(sections)
        let view = opened.rig.view
        XCTAssertTrue(view.isTruncatedForDisplay)

        let shown = view.headings.map(\.title)
        XCTAssertFalse(shown.isEmpty)
        XCTAssertLessThan(shown.count, 3_000)
        let titles = try XCTUnwrap(view.outlineButton.menu).items.dropFirst().map { $0.title.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(titles, shown, "the outline is exactly the headings that have rows, in order")
        XCTAssertFalse(titles.contains("Section 2999"))
    }

    // MARK: (b) one huge row

    func testAMegabyteFencedBlockOfManyLinesIsOneCodeRowCutToItsLimits() throws {
        let line = "let value = compute(42) // filler text to make the line a bit long\n"
        let opened = try open(megabyteFencedBlock(line: line))
        let view = opened.rig.view
        assertBounded(opened)
        XCTAssertGreaterThan(opened.rig.view.rowCount, 0)

        view.buildAllRows()
        XCTAssertEqual(view.rowCount, 2, "one code row and the notice")
        XCTAssertEqual(view.codeScrollViews.count, 1)
        let code = try codeText(view)
        XCTAssertLessThanOrEqual(lineCount(code), Limits.maxLinesPerScrollRow, "lines of one code block")
        XCTAssertLessThanOrEqual(code.utf16.count, Limits.maxCharactersPerRow + 1, "characters of one row, and the ellipsis")
        XCTAssertGreaterThan(code.utf16.count, 1_000, "and the start of the block is still there")
        XCTAssertTrue(code.hasPrefix("let value = compute(42)"))
        assertTheNotice(opened)
        assertRelayoutAtAnotherWidth(opened)
    }

    func testACodeBlockOfShortLinesIsCutAtTheLineLimit() throws {
        let opened = try open(megabyteFencedBlock(line: "x\n"))
        let view = opened.rig.view
        assertBounded(opened)

        view.buildAllRows()
        let code = try codeText(view)
        XCTAssertEqual(lineCount(code), Limits.maxLinesPerScrollRow, "the first \(Limits.maxLinesPerScrollRow) lines, no more")
        XCTAssertLessThan(code.utf16.count, Limits.maxCharactersPerRow, "it is the line limit that cut it here, not the character limit")
        assertTheNotice(opened)
    }

    func testACodeBlockOfOneMegabyteLineIsCutToTheCharacterLimit() throws {
        let opened = try open("```\n" + String(repeating: "x", count: Self.mebibyte - 10) + "\n```\n")
        let view = opened.rig.view
        assertBounded(opened)

        view.buildAllRows()
        XCTAssertEqual(view.rowCount, 2)
        let code = try codeText(view)
        XCTAssertLessThanOrEqual(code.utf16.count, Limits.maxCharactersPerRow + 1)
        XCTAssertTrue(code.hasPrefix("xxxx"))
        assertTheNotice(opened)
        assertRelayoutAtAnotherWidth(opened)
    }

    func testAMegabyteTableIsCutToItsRowLimit() throws {
        let body = String(repeating: "| 1 | 2 |\n", count: (Self.mebibyte - 20) / 10)
        let opened = try open("| a | b |\n|---|---|\n" + body)
        let view = opened.rig.view
        assertBounded(opened)

        view.buildAllRows()
        XCTAssertEqual(view.rowCount, 2, "one table row and the notice")
        XCTAssertEqual(view.tableScrollViews.count, 1)
        let table = try tableText(view)
        XCTAssertLessThanOrEqual(lineCount(table), Limits.maxLinesPerScrollRow + 1, "the header and at most \(Limits.maxLinesPerScrollRow) rows")
        XCTAssertGreaterThan(lineCount(table), 100, "and the start of the table is still there")
        XCTAssertTrue(table.hasPrefix("a\tb"), "the header first: \(table.prefix(20).debugDescription)")
        assertTheNotice(opened)
        assertRelayoutAtAnotherWidth(opened)
    }

    func testAMegabyteSingleParagraphIsCutToTheCharacterLimit() throws {
        let opened = try open(String(repeating: "word ", count: 209_715))
        let view = opened.rig.view
        assertBounded(opened)

        view.buildAllRows()
        XCTAssertEqual(view.rowCount, 2, "one paragraph and the notice")
        let text = try XCTUnwrap(view.textViews.first).string
        XCTAssertLessThanOrEqual(text.utf16.count, Limits.maxCharactersPerRow + 1)
        XCTAssertGreaterThan(text.utf16.count, Limits.maxCharactersPerRow / 2, "most of the allowance is used")
        XCTAssertTrue(text.hasPrefix("word word"))
        assertTheNotice(opened)
        assertRelayoutAtAnotherWidth(opened)
    }

    func testAnyKindOfRowIsCutToTheRowLimit() throws {
        let long = String(repeating: "x", count: 62_000)   // each over a row's limit, all four inside the parser's
        let opened = try open("# \(long)\n\n- list \(long)\n\n- [ ] task \(long)\n\n> quote \(long)\n")
        let view = opened.rig.view
        assertBounded(opened)
        view.buildAllRows()

        let strings = view.textViews.map(\.string)
        XCTAssertGreaterThanOrEqual(strings.count, 4, "a heading, a list item, a task item, a quote")
        for string in strings {
            XCTAssertLessThanOrEqual(string.utf16.count, Limits.maxCharactersPerRow + 1, "a \(string.prefix(8)) row is longer than a row may be")
        }
        XCTAssertTrue(view.headings.allSatisfy { $0.title.utf16.count <= Limits.maxCharactersPerRow + 1 })
        assertTheNotice(opened)
    }

    // SUSPECTED GAP in the first cut (PlanSpecBuilder.limited only bounds the BODY rows of a table; the
    // header's cells go through `tableText` as they are): one giant header cell is one giant row.
    func testAGiantTableHeaderCellIsCutToTheRowLimitToo() throws {
        let opened = try open("| " + String(repeating: "x", count: 200_000) + " | b |\n|---|---|\n| 1 | 2 |\n")
        let view = opened.rig.view
        view.buildAllRows()
        let table = try tableText(view)
        XCTAssertLessThanOrEqual(table.utf16.count, Limits.maxCharactersPerRow + 1, "one row of the document may not be longer than a row may be")
        XCTAssertTrue(view.isTruncatedForDisplay)
    }

    // MARK: Total characters

    // SUSPECTED OFF-BY-ONE in the first cut (PlanSpecBuilder.fit cuts to the room left and then appends the
    // ellipsis, so the last row can take the total to maxCharacters + 1; its doc comment says "at most").
    func testThePlanAsAWholeNeverShowsMoreThanTheCharacterLimit() throws {
        let paragraph = String(repeating: "x", count: 30_000)
        let opened = try open(paragraphsOf(count: 34) { _ in paragraph })
        let view = opened.rig.view
        XCTAssertTrue(view.isTruncatedForDisplay)
        XCTAssertLessThanOrEqual(view.displayedCharacterCount, Limits.maxCharacters, "characters over all rows")

        view.buildAllRows()
        let shown = view.textViews.reduce(0) { $0 + $1.string.utf16.count }
        XCTAssertLessThanOrEqual(shown, Limits.maxCharacters, "and what the text views hold agrees")
        XCTAssertGreaterThan(shown, 150_000, "most of the allowance is used before it stops")
        assertTheNotice(opened)
    }

    // MARK: Exactly at the limits

    func testAPlanOfExactlyTheRowLimitIsShownWholeAndOneRowMoreIsCut() throws {
        let whole = try open(paragraphsOf(count: Limits.maxRows) { "para \($0)" })
        XCTAssertFalse(whole.rig.view.isTruncatedForDisplay, "\(Limits.maxRows) rows fit")
        XCTAssertEqual(whole.rig.view.rowCount, Limits.maxRows)
        scrollToTheBottom(whole.rig.view)
        XCTAssertTrue(noticeRows(whole.rig.view).isEmpty, "and there is no notice")
        XCTAssertTrue(whole.rig.view.shownPlainText.contains("para \(Limits.maxRows - 1)"), "the last paragraph is shown")

        let cut = try open(paragraphsOf(count: Limits.maxRows + 1) { "para \($0)" })
        XCTAssertTrue(cut.rig.view.isTruncatedForDisplay, "one more does not")
        XCTAssertEqual(cut.rig.view.rowCount, Limits.maxRows + 1, "the rows up to the limit, then the notice")
        assertTheNotice(cut)
        XCTAssertTrue(cut.rig.view.shownPlainText.contains("para \(Limits.maxRows - 1)"))
        XCTAssertFalse(cut.rig.view.shownPlainText.contains("para \(Limits.maxRows)"), "the paragraph past the limit is not shown")
    }

    func testAParagraphOfExactlyTheRowCharacterLimitIsShownWholeAndOneMoreCharacterIsCut() throws {
        let whole = try open(String(repeating: "x", count: Limits.maxCharactersPerRow))
        whole.rig.view.buildAllRows()
        XCTAssertFalse(whole.rig.view.isTruncatedForDisplay)
        XCTAssertEqual(try XCTUnwrap(whole.rig.view.textViews.first).string.utf16.count, Limits.maxCharactersPerRow)
        XCTAssertEqual(whole.rig.view.displayedCharacterCount, Limits.maxCharactersPerRow)

        let cut = try open(String(repeating: "x", count: Limits.maxCharactersPerRow + 1))
        cut.rig.view.buildAllRows()
        XCTAssertTrue(cut.rig.view.isTruncatedForDisplay)
        let text = try XCTUnwrap(cut.rig.view.textViews.first).string
        XCTAssertEqual(text.utf16.count, Limits.maxCharactersPerRow, "the limit, the ellipsis included")
        XCTAssertTrue(text.hasSuffix("…"), "the ellipsis shows it was cut")
    }

    func testTheParserIsHandedNoMoreThanItsByteLimitCutAtALineBreakWithoutSplittingACharacter() {
        let small = "# Title\n\nbody é日本\n"
        XCTAssertEqual(Limits.parsedPrefix(of: small).text, small)
        XCTAssertFalse(Limits.parsedPrefix(of: small).wasCut)

        let exact = String(repeating: "x", count: Limits.maxParsedBytes)
        XCTAssertFalse(Limits.parsedPrefix(of: exact).wasCut, "exactly the limit is not cut")

        // Three-byte characters, so the limit falls inside one; a line break every 100 characters.
        let line = String(repeating: "日", count: 99) + "\n"
        let big = String(repeating: line, count: 2_000)
        let cut = Limits.parsedPrefix(of: big)
        XCTAssertTrue(cut.wasCut)
        XCTAssertLessThanOrEqual(cut.text.utf8.count, Limits.maxParsedBytes)
        XCTAssertGreaterThan(cut.text.utf8.count, Limits.maxParsedBytes - line.utf8.count - 1, "as much as fits")
        XCTAssertTrue(cut.text.hasPrefix(line) && big.hasPrefix(cut.text), "a prefix of the file")
        XCTAssertFalse(cut.text.hasSuffix("\n"), "cut before the last line break")
        XCTAssertFalse(cut.text.contains("\u{FFFD}"), "no character was split")

        // The only line break is near the start: cutting there would keep almost nothing, so it is cut mid-line.
        let longFirstLine = "```\n" + String(repeating: "x", count: 400_000)
        let mid = Limits.parsedPrefix(of: longFirstLine)
        XCTAssertTrue(mid.wasCut)
        XCTAssertGreaterThan(mid.text.utf8.count, Limits.maxParsedBytes - 10, "the long line is kept up to the limit")

        // No line break at all: still cut, still valid text.
        let noBreaks = String(repeating: "日", count: 200_000)
        let flat = Limits.parsedPrefix(of: noBreaks)
        XCTAssertTrue(flat.wasCut)
        XCTAssertLessThanOrEqual(flat.text.utf8.count, Limits.maxParsedBytes)
        XCTAssertFalse(flat.text.contains("\u{FFFD}"))
    }

    func testACodeBlockOfExactlyTheLineLimitIsShownWholeAndOneLineMoreIsCut() throws {
        func plan(lines: Int) -> String { "```\n" + (0 ..< lines).map { "l\($0)" }.joined(separator: "\n") + "\n```\n" }

        let whole = try open(plan(lines: Limits.maxLinesPerScrollRow))
        whole.rig.view.buildAllRows()
        XCTAssertFalse(whole.rig.view.isTruncatedForDisplay, "\(Limits.maxLinesPerScrollRow) lines fit")
        XCTAssertEqual(lineCount(try codeText(whole.rig.view)), Limits.maxLinesPerScrollRow)

        let cut = try open(plan(lines: Limits.maxLinesPerScrollRow + 1))
        cut.rig.view.buildAllRows()
        XCTAssertTrue(cut.rig.view.isTruncatedForDisplay, "one more does not")
        XCTAssertEqual(lineCount(try codeText(cut.rig.view)), Limits.maxLinesPerScrollRow)
    }

    // MARK: (d) a plan under the limits is untouched

    func testPlansUnderTheLimitsAreNotTruncated() throws {
        for name in ["plan-2000-lines.md", "plan-full.md", "plan-task-nested.md", "plan-hostile.md"] {
            let dir = try PlanTestSupport.tempDirectory(self)
            let url = try PlanTestSupport.copyFixture(name, into: dir, as: name)
            let opened = try show(url)
            let view = opened.rig.view

            XCTAssertFalse(view.isTruncatedForDisplay, name)
            XCTAssertGreaterThan(view.displayedCharacterCount, 0, name)
            XCTAssertLessThanOrEqual(view.rowCount, Limits.maxRows, name)
            scrollToTheBottom(view)
            XCTAssertTrue(noticeRows(view).isEmpty, "\(name) has no notice")
            view.buildAllRows()
            XCTAssertTrue(noticeRows(view).isEmpty, "\(name) has no notice")
        }
        let bigDir = try PlanTestSupport.tempDirectory(self)
        let big = try show(try PlanTestSupport.copyFixture("plan-2000-lines.md", into: bigDir))
        XCTAssertGreaterThan(big.rig.view.rowCount, 1_000, "the existing behaviour: every row of a long plan is a row")
        XCTAssertEqual(big.rig.view.headings.count, 80)
        XCTAssertEqual(big.rig.view.headingViews.count, 80, "and every heading has a view")
        XCTAssertEqual(big.rig.view.criteriaText, "✓ 107/320 criteria")
    }

    // MARK: (e) scrolling a truncated plan

    func testScrollingATruncatedPlanBuildsOnlyTheRowsNearTheViewport() throws {
        let opened = try open(megabyteOfShortParagraphs)
        let view = opened.rig.view
        let flow = view.documentContentView
        let clip = view.documentScrollView.contentView
        let room = flow.frame.height - clip.bounds.height
        XCTAssertGreaterThan(room, 10_000, "a tall document")

        for fraction: CGFloat in [0, 0.25, 0.5, 0.75, 1, 0.4, 0] {
            scroll(view, toY: room * fraction)
            XCTAssertLessThan(flow.subviews.count, 300, "rows with views at \(fraction) of the way down")
            XCTAssertGreaterThan(flow.subviews.count, 0)
            let visible = view.documentScrollView.documentVisibleRect
            XCTAssertTrue(view.textViews.contains { flow.convert($0.bounds, from: $0).intersects(visible) },
                          "something is drawn where the reader is, at \(fraction)")
            XCTAssertEqual(view.rowCount, Limits.maxRows + 1, "scrolling does not change the rows")
        }

        // and a slow scroll, a screen at a time, never builds the whole document
        var y: CGFloat = 0
        while y < room {
            scroll(view, toY: y)
            XCTAssertLessThan(flow.subviews.count, 500, "rows with views at \(y)")
            y += clip.bounds.height
        }
        XCTAssertEqual(view.state, .document)
    }
}

// MARK: - Nits of the plan view

final class PlanViewFixupTests: XCTestCase {

    // MARK: Rig

    private func write(_ text: String, named name: String = "plan.md") throws -> URL {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func openRig(for url: URL, loader: PlanFileLoader = PlanFileLoader(), active: Bool = true) -> FixupRig {
        let rig = makeFixupRig(self, path: url.path, loader: loader)
        rig.view.show(planPath: url.path)
        if active { rig.view.setActive(true) }
        return rig
    }

    private func waitForState(_ rig: FixupRig, _ state: PlanDocumentView.State,
                              file: StaticString = #filePath, line: UInt = #line) {
        let ok = PlanTestSupport.pumpUntil(timeout: 30) { rig.view.state == state }
        XCTAssertTrue(ok, "the view never reached \(state); it is \(rig.view.state)", file: file, line: line)
        rig.view.layoutSubtreeIfNeeded()
    }

    private func click(_ button: NSButton) { _ = button.sendAction(button.action, to: button.target) }

    // MARK: 1. A file: link names a file on THIS machine

    private func action(_ target: String) -> PlanLinkAction {
        PlanLinkPolicy.action(for: target, planDirectory: URL(fileURLWithPath: "/tmp/plan-dir", isDirectory: true))
    }

    func testAFileLinkForAnotherHostIsInertAndOneForThisMachineIsRevealed() {
        for foreign in ["file://otherhost/etc/passwd", "file://evil.example.com/x", "FILE://EVIL.example.com/x", "file://attacker/share/plan.md",
                        "file://localhost@evil.example.com/x"] {
            XCTAssertEqual(action(foreign), .none, "\(foreign) names a file on another host")
        }
        for local in ["file://localhost/tmp/x.md", "file:///tmp/x.md", "FILE://LOCALHOST/tmp/x", "file://LocalHost/tmp/x", "File:///tmp/x"] {
            guard case .reveal(let url) = action(local) else { XCTFail("\(local) is on this machine and is revealed"); continue }
            XCTAssertTrue(url.isFileURL, local)
            XCTAssertTrue(url.path.hasPrefix("/tmp/x") || url.path.hasPrefix("/private/tmp/x"), "\(local) -> \(url.path)")
        }
    }

    func testClickingAFileLinkForAnotherHostRevealsNothingAndOpensNothing() throws {
        let rig = makeFixupRig(self, path: "/tmp/plans/plan.md")
        let recorder = rig.recorder
        rig.view.show(planPath: rig.path)   // not active: nothing is read

        rig.view.handleLink(URL(string: "file://otherhost/etc/passwd")!)
        rig.view.handleLink("file://evil.example.com/x")
        rig.view.handleLink(URL(string: "FILE://EVIL.example.com/y")!)
        XCTAssertTrue(recorder.revealed.isEmpty, "a file on another host is not revealed")
        XCTAssertTrue(recorder.openedURLs.isEmpty)
        XCTAssertTrue(recorder.openedPlans.isEmpty)

        rig.view.handleLink(URL(string: "file://localhost/tmp/x.md")!)
        rig.view.handleLink(URL(string: "FILE://LOCALHOST/tmp/y.md")!)
        XCTAssertEqual(recorder.revealed.map(\.lastPathComponent), ["x.md", "y.md"], "a file on this machine is revealed")
        XCTAssertTrue(recorder.openedURLs.isEmpty, "and never opened")
    }

    // MARK: 2. The header's file name

    func testTheHeaderShowsAFileNameWithoutBidiZeroWidthOrFillerCharacters() throws {
        // The name is read as a whole, so it gets the document rules: a soft hyphen and a joiner between
        // two ASCII letters go too (the row rules keep them).
        let hostile = "a\u{202E}b\u{200B}c\u{3164}d\u{2066}e\u{00AD}f\u{200D}g.md"
        let url = try write("# Title\n", named: hostile)
        let rig = openRig(for: url)
        waitForState(rig, .document)

        XCTAssertEqual(rig.view.fileNameText, "abcdefg.md")
        for scalar in rig.view.fileNameText.unicodeScalars {
            XCTAssertFalse([0x202E, 0x200B, 0x3164, 0x2066, 0x00AD, 0x200D].contains(scalar.value), "U+\(String(scalar.value, radix: 16, uppercase: true)) is in the header")
        }
    }

    func testTheHeaderNameIsSanitisedInTheMessageStatesToo() throws {
        let dir = try PlanTestSupport.tempDirectory(self)
        let url = dir.appendingPathComponent("gone\u{202E}x\u{200B}.md")
        let rig = openRig(for: url)
        waitForState(rig, .unreadable(.notFound))

        XCTAssertEqual(rig.view.fileNameText, "gonex.md")
    }

    // MARK: 3. An empty plan

    private func assertEmptyPlan(_ rig: FixupRig, file: StaticString = #filePath, line: UInt = #line) {
        let view = rig.view
        XCTAssertEqual(view.state, .emptyPlan, file: file, line: line)
        XCTAssertTrue(view.shownMessage?.hasPrefix("Empty plan") == true, "message: \(String(describing: view.shownMessage))", file: file, line: line)
        XCTAssertNil(view.unreadableMessage, "an empty plan is not an unreadable one", file: file, line: line)
        XCTAssertFalse(view.messageCopyPathButton.isHiddenOrHasHiddenAncestor, "Copy path is offered", file: file, line: line)
        XCTAssertTrue(view.messageOpenPlanButton.isHiddenOrHasHiddenAncestor, "there is nothing to open", file: file, line: line)
        XCTAssertTrue(view.messageRevealButtonView.isHiddenOrHasHiddenAncestor, "or to show", file: file, line: line)
        XCTAssertTrue(view.documentScrollView.isHidden, "no document is shown", file: file, line: line)
        XCTAssertEqual(view.fileNameText, (rig.path as NSString).lastPathComponent, "the header still names the file", file: file, line: line)
        for button in [view.openButton, view.finderButton, view.copyPathButton] {
            XCTAssertTrue(button.isHiddenOrHasHiddenAncestor, "the header's \(button.title) button is gone", file: file, line: line)
        }
        XCTAssertNil(view.criteriaText, file: file, line: line)
        XCTAssertEqual(view.rowCount, 0, file: file, line: line)
        XCTAssertFalse(view.isTruncatedForDisplay, file: file, line: line)

        let before = rig.recorder.copied.count
        click(view.messageCopyPathButton)
        XCTAssertEqual(Array(rig.recorder.copied.dropFirst(before)), [rig.path], "Copy path copies the path", file: file, line: line)
        XCTAssertTrue(rig.recorder.openedPlans.isEmpty && rig.recorder.revealed.isEmpty && rig.recorder.openedURLs.isEmpty, file: file, line: line)
    }

    func testAPlanWithNoBytesWhiteSpaceOnlyOrOnlyInvisibleScalarsIsAnEmptyPlan() throws {
        let texts: [(String, String)] = [
            ("no bytes", ""),
            ("white space", "  \n\t\n"),
            ("blank lines", "\n\n\n\n"),
            ("zero-width space and a filler", "\u{200B}\u{3164}"),
            ("invisibles around white space", "\u{FEFF}\n \u{200B}\n\u{2800}\n"),
            ("a joiner, a selector and a soft hyphen", "\u{200D}\u{FE0F}\u{00AD}"),
        ]
        for (name, text) in texts {
            let rig = openRig(for: try write(text))
            waitForState(rig, .emptyPlan)
            assertEmptyPlan(rig)
            XCTAssertTrue(rig.view.isWatchingFile, "\(name): an empty file is still watched, so it shows when it fills")
        }
    }

    func testAnEmptyPlanBecomesADocumentWhenTheFileGetsContent() throws {
        let scheduler = ManualPlanReloadScheduler()
        let url = try write("")
        let rig = openRig(for: url, loader: PlanFileLoader(scheduler: scheduler))
        waitForState(rig, .emptyPlan)
        assertEmptyPlan(rig)

        try PlanTestSupport.writeInPlace("# Now there is something\n\n- [ ] one\n- [x] two\n", to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { rig.loader.hasPendingReload }, "the edit was never noticed")
        scheduler.fire()

        waitForState(rig, .document)
        XCTAssertNil(rig.view.shownMessage, "the message is gone")
        XCTAssertFalse(rig.view.documentScrollView.isHidden)
        XCTAssertEqual(rig.view.criteriaText, "✓ 1/2 criteria")
        XCTAssertEqual(rig.view.headings.map(\.title), ["Now there is something"])
        for button in [rig.view.openButton, rig.view.finderButton, rig.view.copyPathButton] {
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, "the header's \(button.title) button is back")
        }
        XCTAssertTrue(rig.view.messageCopyPathButton.isHiddenOrHasHiddenAncestor)
    }

    func testADocumentThatBecomesEmptyShowsTheEmptyPlanAndNothingOfTheOldDocument() throws {
        let scheduler = ManualPlanReloadScheduler()
        let url = try write("# Title\n\nbody text\n\n- [x] done\n")
        let rig = openRig(for: url, loader: PlanFileLoader(scheduler: scheduler))
        waitForState(rig, .document)
        XCTAssertEqual(rig.view.criteriaText, "✓ 1/1 criteria")

        try PlanTestSupport.writeAtomically("\n  \n", to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { rig.loader.hasPendingReload }, "the replacement was never noticed")
        scheduler.fire()

        waitForState(rig, .emptyPlan)
        assertEmptyPlan(rig)
        XCTAssertTrue(rig.view.headings.isEmpty)
        XCTAssertEqual(rig.view.outlineButton.menu?.items.count ?? 1, 1, "the outline has only its own title")

        // and back again
        try PlanTestSupport.writeAtomically("# Back\n", to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { rig.loader.hasPendingReload }, "the second replacement was never noticed")
        scheduler.fire()
        waitForState(rig, .document)
        XCTAssertEqual(rig.view.headings.map(\.title), ["Back"])
    }

    func testAnEmptyPlanReadAgainOnComingBackIsStillEmptyAndFillsWhenTheFileDoes() throws {
        let url = try write("")
        let rig = openRig(for: url)
        waitForState(rig, .emptyPlan)

        rig.view.setActive(false)
        try PlanTestSupport.writeInPlace("# Filled while away\n", to: url)
        rig.view.setActive(true)

        waitForState(rig, .document)
        XCTAssertEqual(rig.view.headings.map(\.title), ["Filled while away"])
    }

    // MARK: 4. A file that is not markdown cannot be opened from the plan view at all

    func testNothingInTheViewOpensAPlanThatIsNotMarkdown() throws {
        let url = try write("not markdown\n", named: "notes.txt")
        let rig = openRig(for: url)
        waitForState(rig, .unreadable(.notMarkdown))
        let view = rig.view

        XCTAssertTrue(view.messageOpenPlanButton.isHiddenOrHasHiddenAncestor, "no Open in the message")
        XCTAssertFalse(view.messageRevealButtonView.isHiddenOrHasHiddenAncestor, "Show in Finder instead")
        for button in [view.openButton, view.finderButton, view.copyPathButton] {
            XCTAssertTrue(button.isHiddenOrHasHiddenAncestor, "the header has no \(button.title) button for it")
        }
        // Every control a person can reach, pressed: not one of them hands the file to be opened.
        let visible = MD.allSubviews(view).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertGreaterThanOrEqual(visible.count, 2, "Copy path and Show in Finder at least")
        visible.forEach(click)
        XCTAssertTrue(rig.recorder.openedPlans.isEmpty, "a file that is not markdown is never opened")
        XCTAssertTrue(rig.recorder.openedURLs.isEmpty)
        XCTAssertEqual(rig.recorder.revealed, [URL(fileURLWithPath: url.path)])
        XCTAssertEqual(rig.recorder.copied, [url.path])
    }

    func testAPlanThatIsTooLargeKeepsOpenAndHasNoShowInFinder() throws {
        let url = try write("")
        try Data(repeating: UInt8(ascii: "a"), count: PlanFileRules.maxBytes + 1).write(to: url)
        let rig = openRig(for: url)
        waitForState(rig, .unreadable(.tooLarge))

        XCTAssertFalse(rig.view.messageOpenPlanButton.isHiddenOrHasHiddenAncestor, "Open stays")
        XCTAssertTrue(rig.view.messageRevealButtonView.isHiddenOrHasHiddenAncestor)
        click(rig.view.messageOpenPlanButton)
        XCTAssertEqual(rig.recorder.openedPlans, [url.path])
    }

    // MARK: 5. Accessibility

    private func scrollRow(of scrollView: NSScrollView) -> NSView? {
        var view = scrollView.superview
        while let current = view {
            if NSStringFromClass(type(of: current)).contains("PlanScrollRow") { return current }
            view = current.superview
        }
        return nil
    }

    func testCodeBlocksAndTablesAreGroupsAScreenReaderCanNameAndTheirTextStaysInside() throws {
        let plan = """
        ```swift
        let x = 1
        ```

        ```
        plain
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let rig = openRig(for: try write(plan))
        waitForState(rig, .document)
        rig.view.buildAllRows()

        let codeRows = rig.view.codeScrollViews.compactMap(scrollRow)
        let tableRows = rig.view.tableScrollViews.compactMap(scrollRow)
        XCTAssertEqual(codeRows.count, 2)
        XCTAssertEqual(tableRows.count, 1)

        XCTAssertEqual(codeRows.map { $0.accessibilityLabel() }, ["Code block, swift", "Code block"])
        XCTAssertEqual(tableRows.map { $0.accessibilityLabel() }, ["Table"])
        for row in codeRows + tableRows {
            XCTAssertTrue(row.isAccessibilityElement(), "the row is the element a screen reader lands on")
            XCTAssertEqual(row.accessibilityRole(), .group)
        }
        for scrollView in rig.view.codeScrollViews + rig.view.tableScrollViews {
            XCTAssertTrue(scrollView.documentView is NSTextView, "the text view is still inside it")
        }
    }

    func testTheHeaderAndMessageButtonsAreNamedForWhatTheyDo() throws {
        let rig = openRig(for: try write("# T\n"))
        waitForState(rig, .document)
        let view = rig.view

        XCTAssertEqual(view.openButton.accessibilityLabel(), "Open plan in its default app")
        XCTAssertEqual(view.finderButton.accessibilityLabel(), "Show plan in Finder")
        XCTAssertEqual(view.copyPathButton.accessibilityLabel(), "Copy path")
        XCTAssertEqual(view.messageCopyPathButton.accessibilityLabel(), "Copy plan path")
        XCTAssertEqual(view.messageOpenPlanButton.accessibilityLabel(), "Open plan in its default app")
        XCTAssertEqual(view.messageRevealButtonView.accessibilityLabel(), "Show plan in Finder")
    }

    // MARK: Hostile text in a document, in context (document text is stricter than a row)

    func testNoJoinerOrSelectorSitsNextToAnASCIIScalarAnywhereOnScreen() throws {
        let v = "\u{200D}\u{200C}\u{FE0F}\u{FE0E}\u{00AD}\u{180E}\u{FE00}\u{E0100}"
        let plan = """
        # head\(v)ing

        para\(v)graph a\u{200D}b ok \u{1F469}\u{200D}\u{1F469} \u{2764}\u{FE0F}

        - [ ] task\(v)item
        - [x] done\u{200C}item

        | h\(v)1 | h2 |
        |---|---|
        | ce\(v)ll | c2 |

        ```
        co\(v)de a\u{200D}b
        ```
        """
        let rig = openRig(for: try write(plan))
        waitForState(rig, .document)
        rig.view.buildAllRows()

        let scalars = Array(rig.view.shownPlainText.unicodeScalars)
        XCTAssertGreaterThan(scalars.count, 20)
        for (i, s) in scalars.enumerated() {
            let value = s.value
            XCTAssertFalse(value == 0x00AD || value == 0x180E || (0xFE00 ... 0xFE0D).contains(value) || (0xE0100 ... 0xE01EF).contains(value),
                           "U+\(String(value, radix: 16, uppercase: true)) is on screen")
            guard [0x200C, 0x200D, 0xFE0E, 0xFE0F].contains(value) else { continue }
            let before = i > 0 ? scalars[i - 1] : nil
            let after = i + 1 < scalars.count ? scalars[i + 1] : nil
            let name = "U+\(String(value, radix: 16, uppercase: true))"
            if value == 0x200C || value == 0x200D {
                // a joiner joins two things that are not ASCII
                XCTAssertTrue(before.map { $0.value > 0x7F } == true && after.map { $0.value > 0x7F } == true,
                              "\(name) sits next to ASCII (or at an edge) at \(i)")
            } else {
                // a selector belongs to the emoji before it (what follows it is free)
                XCTAssertTrue(before.map { $0.value > 0x7F } == true, "\(name) follows ASCII (or nothing) at \(i)")
            }
        }
        XCTAssertTrue(rig.view.shownPlainText.contains("heading"))
        XCTAssertTrue(rig.view.shownPlainText.contains("paragraph ab ok"))
        XCTAssertTrue(rig.view.shownPlainText.contains("\u{1F469}\u{200D}\u{1F469}"), "an emoji sequence still draws")
    }
}

// MARK: - 8. The Overview checklist follows its file

final class PlanChecklistFollowTests: XCTestCase {

    // MARK: Helpers

    private final class ReadCounter {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// The checklist's loader, its scheduler and the reads it did, as the detail made them.
    private final class Made {
        let scheduler = ManualPlanReloadScheduler()
        let reads = ReadCounter()
        private(set) var loader: PlanFileLoader?
        private(set) var loaders: [PlanFileLoader] = []

        func make() -> PlanFileLoader {
            let reads = self.reads
            let loader = PlanFileLoader(reader: { reads.bump(); return PlanFileRules.read(path: $0) }, scheduler: scheduler)
            self.loader = loader
            loaders.append(loader)
            return loader
        }
    }

    private func makeDetail(inWindow: Bool = false) throws -> (detail: MotherJobDetail, dir: URL, made: Made, window: NSWindow?) {
        let dir = try PlanTestSupport.tempDirectory(self)
        let frame = NSRect(x: 0, y: 0, width: 800, height: 900)
        let detail = MotherJobDetail(host: MDStubHost(), logDirectory: dir, frame: frame)
        let made = Made()
        detail.makeChecklistFileLoader = { made.make() }
        var window: NSWindow?
        if inWindow {
            let w = MDFixedWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.alphaValue = 0
            w.contentView?.addSubview(detail)
            w.orderFront(nil)
            addTeardownBlock { w.orderOut(nil); w.contentView = nil }
            window = w
        }
        addTeardownBlock { detail.select(nil) }
        return (detail, dir, made, window)
    }

    /// With a progress, a job that has crew data (so a tick really changes the job); without, a bare one.
    private func job(plan: String, progress: Int? = nil) -> MotherJob {
        MDFixtures.job(id: "j-plan", long: [], state: "awaiting", planPath: plan, progressPct: progress, bare: progress == nil)
    }

    private func checklistRows(_ detail: MotherJobDetail) -> [NSView]? {
        guard let list = MD.allSubviews(detail).first(where: { NSStringFromClass(type(of: $0)).contains("PlanChecklistView") }),
              let stack = list.subviews.compactMap({ $0 as? NSStackView }).first
        else { return nil }
        return stack.arrangedSubviews
    }

    private func labels(_ detail: MotherJobDetail) -> [String] {
        (checklistRows(detail) ?? []).compactMap { row in
            MD.allSubviews(row).compactMap { $0 as? NSTextField }.map(\.stringValue).first { $0 != "○" && $0 != "✓" }
        }
    }

    private func waitForRows(_ count: Int, _ detail: MotherJobDetail, _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let ok = PlanTestSupport.pumpUntil(timeout: 20) { self.checklistRows(detail)?.count == count }
        XCTAssertTrue(ok, "\(what): expected \(count) rows, saw \(String(describing: checklistRows(detail)?.count))", file: file, line: line)
    }

    private func writePlan(_ items: [String], to url: URL, atomically: Bool = false) throws {
        let text = items.map { "- [ ] \($0)\n" }.joined()
        if atomically { try PlanTestSupport.writeAtomically(text, to: url) } else { try PlanTestSupport.writeInPlace(text, to: url) }
    }

    /// The main queue and the background queue have each had a turn, three times over: whatever a reload
    /// parsed and applied has landed. (A pass here proves nothing by itself; it only makes a "nothing changed"
    /// check one that a late change could not slip past.)
    private func settle() {
        for _ in 0 ..< 3 {
            var done = false
            DispatchQueue.global(qos: .utility).async { DispatchQueue.main.async { done = true } }
            XCTAssertTrue(PlanTestSupport.pumpUntil { done })
        }
    }

    private func sameViews(_ a: [NSView], _ b: [NSView]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0 === $1 }
    }

    // MARK: The injected loader

    func testTheChecklistIsFedByItsOwnLoaderAndAnEditShowsOnlyWhenThatLoadersDebounceFires() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["first", "second"], to: url)
        detail.select(job(plan: url.path))
        waitForRows(2, detail, "the plan's two items")
        let loader = try XCTUnwrap(made.loader, "the detail asked for a checklist loader")
        XCTAssertTrue(loader.isWatching)

        try writePlan(["first", "second", "third"], to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload }, "the edit was never noticed")
        settle()
        XCTAssertEqual(checklistRows(detail)?.count, 2, "nothing reloads before the debounce fires")

        made.scheduler.fire()
        waitForRows(3, detail, "after the debounce fired")
        XCTAssertEqual(labels(detail), ["first", "second", "third"])
        XCTAssertEqual(made.loaders.count, 1, "one loader for the checklist")
    }

    func testAnAtomicReplacementIsFollowedAndTheWatcherMovesToTheNewFile() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["one"], to: url)
        detail.select(job(plan: url.path))
        waitForRows(1, detail, "one item")
        let loader = try XCTUnwrap(made.loader)

        try writePlan(["one", "two"], to: url, atomically: true)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload })
        made.scheduler.fire()
        waitForRows(2, detail, "after the replacement")

        try writePlan(["one", "two", "three"], to: url)   // an in-place edit of the NEW file
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload }, "the new file is the one watched")
        made.scheduler.fire()
        waitForRows(3, detail, "after the edit of the new file")
    }

    // MARK: Only while the Overview shows

    func testTheChecklistWatcherStopsWhenThePlanIsShownAndComesBackWithTheOverview() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["first", "second"], to: url)
        detail.select(job(plan: url.path))
        waitForRows(2, detail, "the plan's two items")
        let loader = try XCTUnwrap(made.loader)
        let rows = try XCTUnwrap(checklistRows(detail))
        XCTAssertTrue(loader.isWatching)

        detail.selectSegment(.plan)
        XCTAssertFalse(loader.isWatching, "the Plan is on show: its own view reads the file, the checklist does not")
        XCTAssertFalse(loader.hasPendingReload)

        detail.selectSegment(.overview)
        XCTAssertTrue(loader.isWatching, "the Overview re-arms the checklist's watcher")
        settle()
        XCTAssertTrue(sameViews(try XCTUnwrap(checklistRows(detail)), rows), "the file did not change: the same rows")
    }

    func testTheChecklistAgreesWithTheFileAfterAnEditMadeWhileAnotherSegmentShowed() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["first", "second"], to: url)
        detail.select(job(plan: url.path))
        waitForRows(2, detail, "the plan's two items")
        _ = made

        detail.selectSegment(.log)
        try writePlan(["first", "second", "third", "fourth"], to: url)
        settle()
        XCTAssertEqual(checklistRows(detail)?.count, 2, "nobody is watching while the Log shows")

        detail.selectSegment(.overview)
        waitForRows(4, detail, "back on the Overview")
        XCTAssertEqual(labels(detail), ["first", "second", "third", "fourth"])
    }

    func testNoSegmentButTheOverviewHoldsAChecklistWatcher() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["first"], to: url)
        detail.select(job(plan: url.path))
        waitForRows(1, detail, "one item")
        let loader = try XCTUnwrap(made.loader)

        detail.selectSegment(.log)
        XCTAssertFalse(loader.isWatching, "the Log is on show")
        XCTAssertFalse(detail.planView?.isWatchingFile ?? false)

        detail.selectSegment(.plan)
        XCTAssertFalse(loader.isWatching)
        XCTAssertTrue(detail.planView?.isWatchingFile ?? false, "the Plan's own view watches")

        detail.selectSegment(.log)
        XCTAssertFalse(loader.isWatching)
        XCTAssertFalse(detail.planView?.isWatchingFile ?? false)

        detail.selectSegment(.overview)
        XCTAssertTrue(loader.isWatching)
        XCTAssertFalse(detail.planView?.isWatchingFile ?? false)
    }

    func testAPlanPathThatChangesWhileTheOverviewIsNotOnShowIsReadWhenItIs() throws {
        let (detail, dir, made, _) = try makeDetail()
        let a = dir.appendingPathComponent("a.md")
        let b = dir.appendingPathComponent("b.md")
        try writePlan(["first", "second"], to: a)
        try writePlan(["only"], to: b)
        detail.select(job(plan: a.path))
        waitForRows(2, detail, "plan a")
        let loader = try XCTUnwrap(made.loader)

        detail.selectSegment(.log)
        settle()
        let reads = made.reads.count
        let generation = loader.generation

        detail.update(job(plan: b.path))          // the path changes while the Log shows
        settle()
        XCTAssertEqual(loader.generation, generation, "nothing was loaded for a segment that is not on show")
        XCTAssertEqual(made.reads.count, reads, "and nothing was read")
        XCTAssertFalse(loader.isWatching)

        detail.selectSegment(.overview)
        waitForRows(1, detail, "plan b, once the Overview is back")
        XCTAssertEqual(labels(detail), ["only"])
        XCTAssertEqual(made.reads.count, reads + 1, "read once, when it came on show")
        XCTAssertEqual(loader.path, b.path)
        XCTAssertTrue(loader.isWatching)
    }

    func testTheChecklistWatcherStopsWhenTheDetailLeavesItsWindowAndStartsWhenItComesBack() throws {
        let (detail, dir, made, window) = try makeDetail(inWindow: true)
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["first", "second"], to: url)
        detail.select(job(plan: url.path))
        waitForRows(2, detail, "the plan's two items")
        let loader = try XCTUnwrap(made.loader)
        let contentView = try XCTUnwrap(window?.contentView)
        XCTAssertNotNil(detail.window)
        XCTAssertTrue(loader.isWatching)

        detail.removeFromSuperview()
        XCTAssertNil(detail.window)
        XCTAssertFalse(loader.isWatching, "a detail that is not on screen holds no watcher")
        XCTAssertFalse(loader.hasPendingReload)

        contentView.addSubview(detail)
        XCTAssertTrue(loader.isWatching, "back on screen, it watches again")
        waitForRows(2, detail, "the rows after coming back")
    }

    // MARK: No read per tick

    func testManyProgressTicksForTheSamePlanPathReadTheFileNoMoreOften() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["first", "second"], to: url)
        detail.select(job(plan: url.path, progress: 1))
        waitForRows(2, detail, "the plan's two items")
        let loader = try XCTUnwrap(made.loader)
        let rows = try XCTUnwrap(checklistRows(detail))
        settle()
        let reads = made.reads.count
        let generation = loader.generation
        XCTAssertGreaterThanOrEqual(reads, 1)

        for pct in 2 ... 60 { detail.update(job(plan: url.path, progress: pct)) }

        XCTAssertEqual(loader.generation, generation, "not one load or reload was started by an update tick")
        settle()
        XCTAssertEqual(made.reads.count, reads, "the file was not read again")
        XCTAssertTrue(sameViews(try XCTUnwrap(checklistRows(detail)), rows), "the same rows")
        XCTAssertTrue(loader.isWatching, "and it is still watched")
    }

    func testANewPlanPathIsReadOnceAndTheOldOneIsDropped() throws {
        let (detail, dir, made, _) = try makeDetail()
        let a = dir.appendingPathComponent("a.md")
        let b = dir.appendingPathComponent("b.md")
        try writePlan(["first", "second"], to: a)
        try writePlan(["only"], to: b)
        detail.select(job(plan: a.path, progress: 1))
        waitForRows(2, detail, "plan a")
        settle()
        let reads = made.reads.count

        detail.update(job(plan: b.path, progress: 2))
        waitForRows(1, detail, "plan b")
        settle()

        XCTAssertEqual(made.reads.count, reads + 1, "the new path is read once")
        XCTAssertEqual(labels(detail), ["only"])
        XCTAssertEqual(made.loaders.count, 1, "by the same loader")
        XCTAssertEqual(made.loader?.path, b.path)

        detail.update(job(plan: b.path, progress: 3))
        settle()
        XCTAssertEqual(made.reads.count, reads + 1, "and not again")
    }

    // MARK: Same items, same rows

    func testAReloadThatChangesNoItemKeepsTheSameRowViews() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try PlanTestSupport.writeInPlace("- [ ] first\n- [x] second\n", to: url)
        detail.select(job(plan: url.path))
        waitForRows(2, detail, "the plan's two items")
        let loader = try XCTUnwrap(made.loader)
        let rows = try XCTUnwrap(checklistRows(detail))

        // The file changes (a heading, prose around the tasks) but its tasks do not.
        var delivered = 0
        let viewsHandler = loader.onResult
        loader.onResult = { result in delivered += 1; viewsHandler?(result) }
        try PlanTestSupport.writeInPlace("# A title\n\nSome prose.\n\n- [ ] first\n- [x] second\n\nMore prose.\n", to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload }, "the edit was never noticed")
        made.scheduler.fire()
        XCTAssertTrue(PlanTestSupport.pumpUntil { delivered == 1 }, "the reload never delivered")
        settle()

        XCTAssertTrue(sameViews(try XCTUnwrap(checklistRows(detail)), rows), "the same items: the same row views, not rebuilt ones")
        XCTAssertEqual(labels(detail), ["first", "second"])

        // and a change of an item does rebuild
        try PlanTestSupport.writeInPlace("# A title\n\n- [ ] first\n- [x] second\n- [ ] third\n", to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload })
        made.scheduler.fire()
        waitForRows(3, detail, "after a real change")
    }

    func testTickingAnItemInTheFileChangesItsRowButTheRowCountStays() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try PlanTestSupport.writeInPlace("- [ ] first\n- [ ] second\n", to: url)
        detail.select(job(plan: url.path))
        waitForRows(2, detail, "the plan's two items")
        let rows = try XCTUnwrap(checklistRows(detail))
        let loader = try XCTUnwrap(made.loader)

        try PlanTestSupport.writeInPlace("- [x] first\n- [ ] second\n", to: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload })
        made.scheduler.fire()

        let rebuilt = PlanTestSupport.pumpUntil { self.checklistRows(detail).map { !self.sameViews($0, rows) } ?? false }
        XCTAssertTrue(rebuilt, "a ticked item is a change: its row is redrawn")
        XCTAssertEqual(checklistRows(detail)?.count, 2)
    }

    // MARK: A file that goes away and comes back

    func testAChecklistWhoseFileIsDeletedEmptiesAndComesBackWhenTheFileDoes() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("a.md")
        try writePlan(["first", "second"], to: url)
        detail.select(job(plan: url.path))
        waitForRows(2, detail, "the plan's two items")
        let loader = try XCTUnwrap(made.loader)

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingReload }, "the deletion was never noticed")
        made.scheduler.fire()
        waitForRows(0, detail, "after the file was deleted")
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingRetry }, "a file that is not there is looked for again")

        try writePlan(["back"], to: url)
        let end = Date().addingTimeInterval(20)
        while checklistRows(detail)?.count != 1, Date() < end {
            made.scheduler.fire()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(labels(detail), ["back"], "the file came back and the checklist found it")
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.isWatching }, "and watches it again")
    }

    func testAPlanThatDoesNotExistYetFillsTheChecklistWhenItAppears() throws {
        let (detail, dir, made, _) = try makeDetail()
        let url = dir.appendingPathComponent("later.md")
        detail.select(job(plan: url.path))
        let loader = try XCTUnwrap(made.loader)
        XCTAssertTrue(PlanTestSupport.pumpUntil { loader.hasPendingRetry }, "the missing plan is looked for again")
        XCTAssertEqual(checklistRows(detail)?.count ?? 0, 0)

        try writePlan(["arrived"], to: url)
        let end = Date().addingTimeInterval(20)
        while checklistRows(detail)?.count != 1, Date() < end {
            made.scheduler.fire()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(labels(detail), ["arrived"])
    }
}
