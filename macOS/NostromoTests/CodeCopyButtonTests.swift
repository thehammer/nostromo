import XCTest
import AppKit
import NostromoKit

// Contract: each fenced code block (``` or ~~~) in a MarkdownCardView carries a small copy button at
// its top-right. Clicking it puts exactly the block's raw code on the pasteboard (string type only)
// and briefly shows a checkmark. The button never changes the card's measured height, never steals
// focus or text selection, and only exists (a bounded number of them) for blocks near the viewport.
//
// Hermetic: every click goes to a private named pasteboard; the general pasteboard is only observed
// (its change count must not move). Windows are offscreen and never ordered front.

final class CodeCopyButtonTests: XCTestCase {

    private var pb: NSPasteboard!
    private var generalChangeCount = 0
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        pb = NSPasteboard(name: NSPasteboard.Name("CodeCopyButtonTests-\(UUID().uuidString)"))
        generalChangeCount = NSPasteboard.general.changeCount
    }

    override func tearDown() {
        XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount,
                       "a test touched the general pasteboard")
        pb.releaseGlobally()
        pb = nil
        for w in windows { w.contentView = nil; w.close() }
        windows = []
        super.tearDown()
    }

    // MARK: Helpers

    private let base13 = NSFont.systemFont(ofSize: 13)

    private func makeWindow(width: CGFloat = 400, height: CGFloat = 600) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        windows.append(w)
        return w
    }

    /// A card attached to an offscreen window, laid out at `width`.
    private func attachedCard(_ markdown: String, width: CGFloat = 400) -> (MarkdownCardView, NSWindow) {
        let card = MarkdownCardView(markdown: markdown, pasteboard: pb)
        card.presetWidth = width
        let window = makeWindow(width: width)
        let height = MarkdownCardView.measuredHeight(markdown: markdown, width: width)
        card.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView!.addSubview(card)
        card.layoutSubtreeIfNeeded()
        return (card, window)
    }

    private func buttons(_ card: MarkdownCardView) -> [CodeCopyButton] {
        card.codeCopyButtons.sorted { $0.frame.minY > $1.frame.minY } // top to bottom
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private let twoBlocks = "Intro prose.\n\n```swift\nlet a = 1\n```\n\nMiddle prose.\n\n~~~\nsecond block\n~~~\n\nOutro."

    // MARK: CB-1 presence

    func testBacktickAndTildeBlocksEachGetOneButton() {
        let (card, _) = attachedCard(twoBlocks)
        XCTAssertEqual(card.codeCopyButtons.count, 2)
    }

    func testProseOnlyAndInlineCodeOnlyMarkdownGetNoButton() {
        let (prose, _) = attachedCard("Just **prose** here.\n\n- a list\n- of things")
        XCTAssertEqual(prose.codeCopyButtons.count, 0)
        let (inline, _) = attachedCard("Use `let x = 1` and ```not a block``` inline.")
        XCTAssertEqual(inline.codeCopyButtons.count, 0)
    }

    func testEmptyFencedBlockGetsNoButton() {
        let (card, _) = attachedCard("Before\n\n```\n```\n\nAfter")
        XCTAssertEqual(card.codeCopyButtons.count, 0)
    }

    func testDetachedCardHasNoButtons() {
        let card = MarkdownCardView(markdown: twoBlocks, pasteboard: pb)
        card.presetWidth = 400
        card.frame = NSRect(x: 0, y: 0, width: 400, height: MarkdownCardView.measuredHeight(markdown: twoBlocks, width: 400))
        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.codeCopyButtons.count, 0)
    }

    // MARK: CB-2 copy content

    func testClickCopiesExactRawCodeWithIndentationAndTrailingSpaces() {
        let code = "func f() {\n    return 1   \n}\n\n  tail  "
        let (card, _) = attachedCard("Look:\n\n```swift\n\(code)\n```\n\nDone")
        let list = buttons(card)
        XCTAssertEqual(list.count, 1)
        list[0].copyCode()
        XCTAssertEqual(pb.string(forType: .string), code)
    }

    func testPerformClickCopies() {
        let (card, _) = attachedCard("```\nhello\n```")
        let button = try! XCTUnwrap(buttons(card).first)
        button.performClick(nil)
        XCTAssertEqual(pb.string(forType: .string), "hello")
    }

    func testEachBlockCopiesItsOwnTextAndOnlyStringTypeIsDeclared() {
        let (card, _) = attachedCard(twoBlocks)
        let list = buttons(card)
        XCTAssertEqual(list.count, 2)
        list[0].copyCode()
        XCTAssertEqual(pb.string(forType: .string), "let a = 1")
        XCTAssertEqual(pb.types, [.string])
        list[1].copyCode()
        XCTAssertEqual(pb.string(forType: .string), "second block")
        XCTAssertEqual(pb.types, [.string])
    }

    func testCopyReplacesPriorPasteboardContents() {
        pb.clearContents()
        pb.setString("<b>old</b>", forType: .html)
        let (card, _) = attachedCard("```\nnew\n```")
        buttons(card)[0].copyCode()
        XCTAssertEqual(pb.types, [.string])
        XCTAssertEqual(pb.string(forType: .string), "new")
    }

    func testRenderBlocksRangesSelectTheCodeInOrder() {
        let md = "Prose before.\n\n```swift\nlet a = 1\n  let b = 2\n```\n\nBetween.\n\n```\n```\n\n~~~\nsecond\n~~~\n\nAfter."
        let rendered = MarkdownRenderer.renderBlocks(md, baseFont: base13)
        XCTAssertEqual(rendered.codeBlocks.map(\.code), ["let a = 1\n  let b = 2", "second"])
        let ns = rendered.text.string as NSString
        var lastEnd = 0
        for block in rendered.codeBlocks {
            XCTAssertLessThanOrEqual(NSMaxRange(block.range), ns.length)
            XCTAssertEqual(ns.substring(with: block.range), block.code)
            XCTAssertGreaterThanOrEqual(block.range.location, lastEnd)
            lastEnd = NSMaxRange(block.range)
        }
    }

    func testRenderStringEqualsRenderBlocksText() {
        let a = MarkdownRenderer.render(twoBlocks, baseFont: base13)
        let b = MarkdownRenderer.renderBlocks(twoBlocks, baseFont: base13).text
        XCTAssertEqual(a.string, b.string)
        XCTAssertTrue(a.isEqual(to: b))
    }

    // MARK: CB-3 no layout impact

    func testButtonsDoNotChangeMeasuredOrIntrinsicHeight() {
        let detached = MarkdownCardView(markdown: twoBlocks, pasteboard: pb)
        detached.presetWidth = 400
        let detachedIntrinsic = detached.intrinsicContentSize.height
        let measured = MarkdownCardView.measuredHeight(markdown: twoBlocks, width: 400)

        let (attached, _) = attachedCard(twoBlocks)
        XCTAssertEqual(attached.codeCopyButtons.count, 2)
        XCTAssertEqual(attached.intrinsicContentSize.height, detachedIntrinsic, accuracy: 0.5)
        XCTAssertEqual(MarkdownCardView.measuredHeight(markdown: twoBlocks, width: 400), measured, accuracy: 0.001)
    }

    // MARK: CB-4 geometry, resize, selection, boundedness

    private func assertTopRight(_ card: MarkdownCardView, _ button: CodeCopyButton,
                                file: StaticString = #filePath, line: UInt = #line) {
        let bounds = card.bounds
        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(button.frame), "button outside card: \(button.frame) vs \(bounds)", file: file, line: line)
        XCTAssertLessThanOrEqual(button.frame.maxX, bounds.width - 12 + 4, file: file, line: line)
        XCTAssertGreaterThanOrEqual(button.frame.maxX, bounds.width / 2, file: file, line: line)
    }

    func testFirstButtonSitsAtTopRightOfTheText() {
        let (card, _) = attachedCard("```\nonly block\n```")
        let button = buttons(card)[0]
        assertTopRight(card, button)
        XCTAssertLessThanOrEqual(button.frame.maxY, card.bounds.maxY - 12 + 2)
        XCTAssertGreaterThanOrEqual(button.frame.maxY, card.bounds.maxY - 12 - 30)
    }

    func testStackedBlocksGetDistinctButtonsInBlockOrder() {
        let (card, _) = attachedCard("```\nfirst\n```\n\n```\nsecond\n```")
        let list = buttons(card) // top to bottom
        XCTAssertEqual(list.count, 2)
        XCTAssertNotEqual(list[0].frame.minY, list[1].frame.minY)
        XCTAssertEqual(list.map(\.code), ["first", "second"])
        list.forEach { assertTopRight(card, $0) }
    }

    func testButtonsSurviveResizeAndStayTopRight() {
        let (card, _) = attachedCard(twoBlocks)
        card.presetWidth = 300
        card.frame = NSRect(x: 0, y: 0, width: 300, height: MarkdownCardView.measuredHeight(markdown: twoBlocks, width: 300))
        card.layoutSubtreeIfNeeded()
        let list = buttons(card)
        XCTAssertEqual(list.count, 2)
        list.forEach { assertTopRight(card, $0) }
    }

    func testButtonNeverTakesFocusAndTextAreaIsNotHitByIt() {
        let (card, window) = attachedCard("```\nline one\nline two\nline three\n```")
        let button = buttons(card)[0]
        XCTAssertTrue(button.refusesFirstResponder)
        XCTAssertFalse(button.acceptsFirstResponder)
        XCTAssertFalse(window.makeFirstResponder(button) && window.firstResponder === button)
        XCTAssertFalse(window.firstResponder === button)

        // A point in the block's text, well left of the button, must hit the text, not a button.
        let point = NSPoint(x: 24, y: button.frame.midY)
        let superPoint = card.convert(point, to: card.superview)
        let hit = card.hitTest(superPoint)
        XCTAssertFalse(hit is CodeCopyButton)
    }

    private func scrollFixture(blockCount: Int) -> (NSScrollView, NSClipView, MarkdownCardView, [String]) {
        let codes = (0..<blockCount).map { "line \($0)" }
        let md = codes.map { "```\n\($0)\n```" }.joined(separator: "\n\n")
        let card = MarkdownCardView(markdown: md, pasteboard: pb)
        card.presetWidth = 400
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        let height = MarkdownCardView.measuredHeight(markdown: md, width: 400)
        card.frame = NSRect(x: 0, y: 0, width: 400, height: height)
        let window = makeWindow(width: 400, height: 300)
        window.contentView!.addSubview(scroll)
        scroll.documentView = card
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        return (scroll, scroll.contentView, card, codes)
    }

    private func scroll(_ scroll: NSScrollView, _ clip: NSClipView, toFraction f: CGFloat, card: MarkdownCardView) {
        let maxY = max(0, card.frame.height - clip.bounds.height)
        // Non-flipped document: y = 0 is the bottom; fraction 0 is the top of the content.
        let y = clip.documentView?.isFlipped == true ? maxY * f : maxY * (1 - f)
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        card.layoutSubtreeIfNeeded()
    }

    func testButtonCountStaysBoundedForAHugeMessageAndFollowsScrolling() {
        let (sv, clip, card, codes) = scrollFixture(blockCount: 200)
        XCTAssertGreaterThan(card.frame.height, 2000)
        XCTAssertGreaterThan(card.codeCopyButtons.count, 0)
        XCTAssertLessThanOrEqual(card.codeCopyButtons.count, 30)
        XCTAssertTrue(card.codeCopyButtons.map(\.code).contains(codes[0]))

        scroll(sv, clip, toFraction: 0.5, card: card)
        XCTAssertGreaterThan(card.codeCopyButtons.count, 0)
        XCTAssertLessThanOrEqual(card.codeCopyButtons.count, 30)
        XCTAssertFalse(card.codeCopyButtons.map(\.code).contains(codes[0]))

        scroll(sv, clip, toFraction: 1.0, card: card)
        XCTAssertLessThanOrEqual(card.codeCopyButtons.count, 30)
        XCTAssertTrue(card.codeCopyButtons.map(\.code).contains(codes[199]),
                      "the last block must have a button once scrolled to the bottom")
    }

    // MARK: CB-5 accessibility, feedback, hover

    func testAccessibilityLabelRoleAndPress() throws {
        let (card, _) = attachedCard("```\nax code\n```")
        let button = try XCTUnwrap(buttons(card).first)
        XCTAssertEqual(button.accessibilityLabel(), "Copy code")
        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertFalse(button.isBordered)
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(pb.string(forType: .string), "ax code")
    }

    func testCopyShowsCheckmarkAndCopiedThenResets() throws {
        let (card, _) = attachedCard("```\nfeedback\n```")
        let button = try XCTUnwrap(buttons(card).first)
        XCTAssertEqual(button.feedbackDuration, 1.2, accuracy: 0.0001)
        XCTAssertEqual(button.toolTip, "Copy code")
        XCTAssertFalse(button.isShowingCopied)
        XCTAssertEqual(button.symbolName, "doc.on.doc")
        let restingImage = button.image

        button.feedbackDuration = 0.05
        button.copyCode()
        XCTAssertTrue(button.isShowingCopied)
        XCTAssertEqual(button.toolTip, "Copied")
        XCTAssertEqual(button.symbolName, "checkmark")
        XCTAssertNotNil(button.image)
        XCTAssertFalse(button.image === restingImage && restingImage != nil, "icon should change to a checkmark")

        let reset = expectation(description: "feedback resets")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { t in
            if !button.isShowingCopied { t.invalidate(); reset.fulfill() }
        }
        wait(for: [reset], timeout: 2)
        timer.invalidate()
        XCTAssertEqual(button.toolTip, "Copy code")
        XCTAssertFalse(button.isShowingCopied)
    }

    func testSecondCopyWithinTheWindowRestartsTheFeedbackTimer() throws {
        let (card, _) = attachedCard("```\nagain\n```")
        let button = try XCTUnwrap(buttons(card).first)
        button.feedbackDuration = 0.4
        button.copyCode()
        let wait1 = expectation(description: "0.25s elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wait1.fulfill() }
        wait(for: [wait1], timeout: 2)
        button.copyCode() // restart: original timer would fire at 0.4s
        let wait2 = expectation(description: "0.25s more elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { wait2.fulfill() }
        wait(for: [wait2], timeout: 2)
        XCTAssertTrue(button.isShowingCopied, "second copy must restart the timer, not let the first one reset it")
        let reset = expectation(description: "eventually resets")
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
            if !button.isShowingCopied { t.invalidate(); reset.fulfill() }
        }
        wait(for: [reset], timeout: 2)
        timer.invalidate()
    }

    func testHoverRaisesAlphaAndLeavingRestsIt() throws {
        let (card, _) = attachedCard("```\nhover\n```")
        let button = try XCTUnwrap(buttons(card).first)
        XCTAssertEqual(button.alphaValue, 0.5, accuracy: 0.001)
        button.setHovered(true)
        XCTAssertEqual(button.alphaValue, 1.0, accuracy: 0.001)
        button.setHovered(false)
        XCTAssertEqual(button.alphaValue, 0.5, accuracy: 0.001)
    }

    // MARK: CB-6 transcript wiring

    func testTextBlockViewWithoutFenceHasNoCopyButton() {
        let block = TextBlockView(text: "Some **prose** with `inline code` and a [link](x).")
        let window = makeWindow()
        block.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView!.addSubview(block)
        block.presetLayoutWidth(400)
        block.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(of: block).compactMap { $0 as? CodeCopyButton }.isEmpty)
    }

    func testTextBlockViewWithFenceHasExactlyOneCopyButton() {
        let block = TextBlockView(text: "Run this:\n\n```sh\necho hi\n```\n\nThen relax.")
        let window = makeWindow()
        block.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView!.addSubview(block)
        block.presetLayoutWidth(400)
        block.layoutSubtreeIfNeeded()
        // Do not click: this card uses the general pasteboard.
        XCTAssertEqual(descendants(of: block).compactMap { $0 as? CodeCopyButton }.count, 1)
    }

    // Approval card: skipped. `ApprovalCardView` needs an ApprovalStore, wire request and gesture
    // permit to construct, so there is no cheap hermetic init; it also renders no markdown cards.
}
