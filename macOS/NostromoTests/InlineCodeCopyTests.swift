import XCTest
import AppKit
import NostromoKit

// Contract: an inline code span (`like this`) in a MarkdownCardView shows a small copy button while the
// pointer is over it. Clicking puts exactly the span's text (no backticks) on the pasteboard. Empty,
// whitespace-only, oversize (> 400 chars) and in-link spans are not copyable. Fenced blocks are not
// inline spans. The button never changes the card's height, never takes focus, stays inside the card,
// and repeated hovering never leaks subviews or tracking areas.
//
// Hermetic: private named pasteboard, offscreen windows; the general pasteboard is only observed.

final class InlineCodeCopyTests: XCTestCase {

    private var pb: NSPasteboard!
    private var generalChangeCount = 0
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: NSPasteboard.Name("InlineCodeCopyTests-\(UUID().uuidString)"))
        generalChangeCount = NSPasteboard.general.changeCount
    }

    override func tearDown() {
        XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount, "a test touched the general pasteboard")
        pb.releaseGlobally()
        pb = nil
        for w in windows { w.contentView = nil; w.close() }
        windows = []
        super.tearDown()
    }

    // MARK: Helpers

    private let base13 = NSFont.systemFont(ofSize: 13)

    private func spans(_ md: String) -> [MarkdownRenderer.InlineCodeSpan] {
        MarkdownRenderer.renderBlocks(md, baseFont: base13).inlineCodeSpans
    }

    private func attachedCard(_ markdown: String, width: CGFloat = 400) -> MarkdownCardView {
        let card = MarkdownCardView(markdown: markdown, pasteboard: pb)
        card.presetWidth = width
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                         styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        windows.append(w)
        card.frame = NSRect(x: 0, y: 0, width: width,
                            height: MarkdownCardView.measuredHeight(markdown: markdown, width: width))
        w.contentView!.addSubview(card)
        card.layoutSubtreeIfNeeded()
        return card
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func copyButtonCount(_ card: MarkdownCardView) -> Int {
        descendants(of: card).filter { $0 is CodeCopyButton }.count
    }

    /// Every grid point in the card at which hovering shows the button for `text`. The card is reset
    /// (hover nil) before each probe, so results don't depend on sticky hover.
    private func hitPoints(_ card: MarkdownCardView, for text: String, step: CGFloat = 2) -> [NSPoint] {
        var hits: [NSPoint] = []
        var y = card.bounds.maxY - 1
        while y > 0 {
            var x: CGFloat = 1
            while x < card.bounds.width {
                card.updateInlineHover(at: nil)
                card.updateInlineHover(at: NSPoint(x: x, y: y))
                if let b = card.inlineCopyButton, b.code == text { hits.append(NSPoint(x: x, y: y)) }
                x += step
            }
            y -= step
        }
        card.updateInlineHover(at: nil)
        return hits
    }

    private func hoverPoint(_ card: MarkdownCardView, on text: String,
                            file: StaticString = #filePath, line: UInt = #line) throws -> NSPoint {
        let hits = hitPoints(card, for: text)
        guard !hits.isEmpty else {
            XCTFail("no point in the card hovers span \"\(text)\"", file: file, line: line)
            throw XCTSkip("span not hoverable")
        }
        // The middle hit, so it is well inside the span rather than on its edge.
        return hits[hits.count / 2]
    }

    private func assertOnlyStringTypes(file: StaticString = #filePath, line: UInt = #line) {
        let ok: Set<NSPasteboard.PasteboardType> = [.string, NSPasteboard.PasteboardType("NSStringPboardType")]
        XCTAssertTrue(Set(pb.types ?? []).isSubset(of: ok), "pasteboard types: \(pb.types ?? [])", file: file, line: line)
    }

    // MARK: Renderer

    func testSpansRecordedWithExactTextAndRanges() {
        let md = "Run `make x` then `git status -sb` and finish."
        let rendered = MarkdownRenderer.renderBlocks(md, baseFont: base13)
        XCTAssertEqual(rendered.inlineCodeSpans.map(\.text), ["make x", "git status -sb"])
        let ns = rendered.text.string as NSString
        var lastEnd = 0
        for s in rendered.inlineCodeSpans {
            XCTAssertLessThanOrEqual(NSMaxRange(s.range), ns.length)
            XCTAssertEqual(ns.substring(with: s.range), s.text)
            XCTAssertFalse(s.text.contains("`"))
            XCTAssertGreaterThanOrEqual(s.range.location, lastEnd)
            lastEnd = NSMaxRange(s.range)
        }
    }

    func testProseWithoutInlineCodeHasNoSpans() {
        XCTAssertTrue(spans("Just **prose** and a [link](http://u).").isEmpty)
    }

    func testLongSpanThatWouldWrapIsOneSpan() {
        let long = (0..<30).map { "word\($0)" }.joined(separator: " ")
        let result = spans("Before `\(long)` after")
        XCTAssertEqual(result.map(\.text), [long])
    }

    func testEmptyAndWhitespaceOnlySpansAreNotRecorded() {
        XCTAssertTrue(spans("a `` b").isEmpty)
        XCTAssertTrue(spans("a ` ` b").isEmpty)
        XCTAssertTrue(spans("a `    ` b").isEmpty)
    }

    func testLengthLimitIs400Characters() {
        let ok = String(repeating: "a", count: 400)
        let tooLong = String(repeating: "a", count: 401)
        XCTAssertEqual(spans("x `\(ok)` y").map(\.text), [ok])
        XCTAssertTrue(spans("x `\(tooLong)` y").isEmpty)
    }

    func testSpanInsideLinkTextIsNotRecorded() {
        XCTAssertTrue(spans("see [`x`](http://u) now").isEmpty)
    }

    func testSpanOutsideALinkOnTheSameLineIsStillRecorded() {
        XCTAssertEqual(spans("[go](http://u) then `run it`").map(\.text), ["run it"])
    }

    func testBoldWrappedCodeStillRecordsItsText() {
        XCTAssertEqual(spans("Use **`make x`** now").map(\.text), ["make x"])
    }

    func testAdjacentSpansStayDistinct() {
        let result = spans("`a``b`")
        XCTAssertEqual(result.map(\.text), ["a", "b"])
        if result.count == 2 { XCTAssertLessThanOrEqual(NSMaxRange(result[0].range), result[1].range.location) }
    }

    func testFencedBlocksAreNotInlineSpans() {
        XCTAssertTrue(spans("```\nlet a = 1\n```").isEmpty)
        XCTAssertTrue(spans("~~~\nuse `x` here\n~~~").isEmpty)
        XCTAssertTrue(spans("```sh\necho `date`\n```").isEmpty)
        XCTAssertEqual(spans("```\nblock\n```\n\nand `inline`").map(\.text), ["inline"])
    }

    // MARK: View: show / hide

    func testHoveringASpanShowsExactlyOneLabelledButton() throws {
        let card = attachedCard("Run `make x` now, then relax.")
        XCTAssertNil(card.inlineCopyButton)
        let before = copyButtonCount(card)
        let p = try hoverPoint(card, on: "make x")
        card.updateInlineHover(at: p)
        let button = try XCTUnwrap(card.inlineCopyButton)
        XCTAssertEqual(button.accessibilityLabel(), "Copy code")
        XCTAssertEqual(copyButtonCount(card), before + 1)
        XCTAssertTrue(button.isDescendant(of: card))
        // Hovering again within the same span does not add another.
        card.updateInlineHover(at: p)
        XCTAssertEqual(copyButtonCount(card), before + 1)
    }

    func testHoverOverPlainProseShowsNoButton() {
        let card = attachedCard("Plain words only here `code` end.")
        let hits = hitPoints(card, for: "code")
        // A point at the far bottom-right corner is not on the span.
        card.updateInlineHover(at: NSPoint(x: card.bounds.maxX - 1, y: 1))
        XCTAssertNil(card.inlineCopyButton)
        XCTAssertFalse(hits.isEmpty)
    }

    func testLeavingTheCardHidesAndRemovesTheButton() throws {
        let card = attachedCard("Run `make x` now.")
        let before = copyButtonCount(card)
        card.updateInlineHover(at: try hoverPoint(card, on: "make x"))
        XCTAssertNotNil(card.inlineCopyButton)
        card.updateInlineHover(at: nil)
        XCTAssertNil(card.inlineCopyButton)
        XCTAssertEqual(copyButtonCount(card), before)
    }

    func testMovingBetweenSpansShowsTheSecondSpansText() throws {
        let card = attachedCard("Run `alpha` then `beta` ok.")
        let before = copyButtonCount(card)
        let p1 = try hoverPoint(card, on: "alpha")
        let p2 = try hoverPoint(card, on: "beta")
        card.updateInlineHover(at: nil)
        card.updateInlineHover(at: p1)
        XCTAssertEqual(card.inlineCopyButton?.code, "alpha")
        card.updateInlineHover(at: p2)
        XCTAssertEqual(card.inlineCopyButton?.code, "beta")
        XCTAssertEqual(copyButtonCount(card), before + 1)
        card.inlineCopyButton?.copyCode()
        XCTAssertEqual(pb.string(forType: .string), "beta")
    }

    func testHoveringAnUncopyableSpanShowsNoButton() {
        let card = attachedCard("Link [`x`](http://u) and blank `   ` here.")
        var y = card.bounds.maxY - 1
        while y > 0 {
            var x: CGFloat = 1
            while x < card.bounds.width {
                card.updateInlineHover(at: NSPoint(x: x, y: y))
                XCTAssertNil(card.inlineCopyButton, "button appeared at \(x),\(y)")
                if card.inlineCopyButton != nil { return }
                x += 6
            }
            y -= 4
        }
    }

    // MARK: View: copy

    func testClickCopiesExactSpanTextWithoutBackticks() throws {
        let card = attachedCard("Run `git commit -m \"fix  it\"` now.")
        card.updateInlineHover(at: try hoverPoint(card, on: "git commit -m \"fix  it\""))
        let button = try XCTUnwrap(card.inlineCopyButton)
        button.performClick(nil)
        XCTAssertEqual(pb.string(forType: .string), "git commit -m \"fix  it\"")
        assertOnlyStringTypes()
    }

    func testCopyCodeAndAccessibilityPressCopySpanText() throws {
        let card = attachedCard("Use `swift test` please.")
        card.updateInlineHover(at: try hoverPoint(card, on: "swift test"))
        let button = try XCTUnwrap(card.inlineCopyButton)
        button.copyCode()
        XCTAssertEqual(pb.string(forType: .string), "swift test")
        pb.clearContents()
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(pb.string(forType: .string), "swift test")
    }

    // MARK: View: focus

    func testButtonIsAControlThatDoesNotPullFocusToTheComposer() throws {
        let card = attachedCard("Use `swift test` please.")
        card.updateInlineHover(at: try hoverPoint(card, on: "swift test"))
        let button = try XCTUnwrap(card.inlineCopyButton)
        XCTAssertTrue(button is NSControl)
        XCTAssertFalse(ReplView.shouldFocusComposer(hit: button, firstResponder: nil, composer: NSTextView()))
        XCTAssertFalse(button.acceptsFirstResponder)
    }

    // MARK: View: layout

    func testHoverDoesNotChangeIntrinsicOrMeasuredHeight() throws {
        let md = "Run `make x` now, and also `swift test` later on in this longer sentence of prose."
        let card = attachedCard(md)
        let intrinsic = card.intrinsicContentSize.height
        let measured = MarkdownCardView.measuredHeight(markdown: md, width: 400)
        card.updateInlineHover(at: try hoverPoint(card, on: "make x"))
        XCTAssertNotNil(card.inlineCopyButton)
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.intrinsicContentSize.height, intrinsic, accuracy: 0.001)
        XCTAssertEqual(MarkdownCardView.measuredHeight(markdown: md, width: 400), measured, accuracy: 0.001)
    }

    func testButtonStaysInsideCardEvenWhenSpanEndsAtTheRightEdge() throws {
        // Narrow widths and unbreakable spans push span ends against the card's right edge.
        let text = String(repeating: "x", count: 22)
        for width in stride(from: 160 as CGFloat, through: 260, by: 10) {
            let card = attachedCard("`\(text)`", width: width)
            let p = try hoverPoint(card, on: text)
            card.updateInlineHover(at: p)
            let button = try XCTUnwrap(card.inlineCopyButton)
            XCTAssertTrue(card.bounds.insetBy(dx: -0.5, dy: -0.5).contains(button.frame),
                          "width \(width): button \(button.frame) outside \(card.bounds)")
        }
        let wide = attachedCard("Edge case here `\(text)`", width: 300)
        wide.updateInlineHover(at: try hoverPoint(wide, on: text))
        let b = try XCTUnwrap(wide.inlineCopyButton)
        XCTAssertTrue(wide.bounds.insetBy(dx: -0.5, dy: -0.5).contains(b.frame))
    }

    func testWrappedSpansButtonSitsAtItsLastLine() throws {
        let long = (0..<14).map { "word\($0)" }.joined(separator: " ")
        let card = attachedCard("Start `\(long)` end", width: 260)
        let hits = hitPoints(card, for: long, step: 3)
        XCTAssertFalse(hits.isEmpty)
        let ys = hits.map(\.y)
        let top = ys.max()!, bottom = ys.min()!
        XCTAssertGreaterThan(top - bottom, 10, "span should wrap over at least two lines")
        card.updateInlineHover(at: hits[hits.count / 2])
        let button = try XCTUnwrap(card.inlineCopyButton)
        let lastLineY = card.isFlipped ? top : bottom
        let firstLineY = card.isFlipped ? bottom : top
        XCTAssertLessThan(abs(button.frame.midY - lastLineY), abs(button.frame.midY - firstLineY),
                          "button \(button.frame) should be nearer the last line (\(lastLineY)) than the first (\(firstLineY))")
    }

    // MARK: View: churn

    func testRepeatedHoverAndTrackingUpdatesDoNotLeak() throws {
        let card = attachedCard("Run `make x` then `swift test` ok.")
        let p = try hoverPoint(card, on: "make x")
        card.updateInlineHover(at: nil)
        card.updateTrackingAreas()
        let trackingCount = card.trackingAreas.count
        let subviewCount = card.subviews.count
        let buttonCount = copyButtonCount(card)

        for _ in 0..<200 {
            card.updateInlineHover(at: p)
            XCTAssertNotNil(card.inlineCopyButton)
            card.updateInlineHover(at: nil)
            XCTAssertNil(card.inlineCopyButton)
        }
        for _ in 0..<50 { card.updateTrackingAreas() }

        XCTAssertEqual(card.trackingAreas.count, trackingCount)
        XCTAssertEqual(card.subviews.count, subviewCount)
        XCTAssertEqual(copyButtonCount(card), buttonCount)
    }
}
