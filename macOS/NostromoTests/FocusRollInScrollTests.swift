import XCTest
import AppKit
import NostromoKit

// FV3 (reader-protected roll-in): what the operator sees when a newer message rolls the latest one
// into the activity row above it.
//
// The rig is TF3's `ScrollRig` (`ToolFoldScrollTests.swift`): a real scroll view, virtualizer,
// follow-tail controller, viewport coordinator, real `ChatTurnView`s and the real `RollInHolds`
// that `ReplView` owns. The animation seam records instead of playing, so nothing here needs a
// timer. Every claim about stillness is stated as what an operator sees: the screen y of a
// concrete thing (found by the text it shows, because a roll-in rebuilds the views after the
// message) before and after, "moves at most 1 pt".
//
// The rules under test (PRD "Rolling behaviour and scroll safety", contract §2.5):
//   - a pane that is not following the tail holds only a message that is on screen;
//   - a text selection inside a message holds it, following or not;
//   - a held message completes its roll-in when it leaves the viewport, when the selection
//     clears, or on Jump to latest;
//   - only an on-screen roll-in in a following pane animates, for at most 0.15 s, and not with
//     Reduce Motion;
//   - holds are this pane's own: they are never persisted or broadcast.
//
// No wall clock, no real pasteboard / UserDefaults / ~/.nostromo.
//
// A real mouse drag cannot be simulated in a logic test (no window server). What the pane reads
// as "the reader is selecting here" is the first responder's text view holding a non-empty
// selection (a drag in progress also counts, through the left button, which the pane asks
// AppKit and a test cannot press). That selection is the observable state these tests build.

private typealias F = FoldFixtures
private typealias X = FocusFixtures

// MARK: - Fixtures

/// One message of `blocks` plain text blocks (no call between them, so one message): tall, so a
/// viewport can sit inside it. The blocks read `<tag>-0`, `<tag>-1`, ...
private func tallMessage(_ tag: String, blocks: Int = 6) -> [TurnBlock] {
    (0 ..< blocks).map { TurnBlock.text("\(tag)-\($0) \(F.prose) \(F.prose) \(F.prose)") }
}

/// Like `tallMessage`, with markdown, so each block renders as a card holding a real `NSTextView`
/// (the plain blocks are labels).
private func tallMarkdownMessage(_ tag: String, blocks: Int = 6) -> [TurnBlock] {
    (0 ..< blocks).map { TurnBlock.text("\(tag)-\($0) **bold \($0)** \(F.prose) \(F.prose) \(F.prose)") }
}

/// A concrete thing the reader is looking at, named by the text it shows (a roll-in rebuilds the
/// views after the message, so a view's identity or index cannot name it) and where it was.
private struct ReaderPosition {
    let turnID: UUID
    let needle: String
    /// Screen y (below the top of the viewport) when it was taken.
    let y: CGFloat
}

/// What a test needs of a text selection it made.
private struct HeldSelection {
    let textView: NSTextView
    let block: TextBlockView
    let range: NSRange
    let text: String
}

final class FocusRollInScrollTests: XCTestCase {

    // MARK: - Helpers: reading the pane

    private func textBlock(containing text: String, in view: ChatTurnView?) -> TextBlockView? {
        view?.subviews.compactMap { $0 as? TextBlockView }.first { X.contains(text, in: $0) }
    }

    private func held(_ rig: ScrollRig, turn id: UUID) -> Set<Int> {
        rig.store.state(for: id).heldOrdinals
    }

    private func ghosts(in view: ChatTurnView?) -> [RollInGhostView] {
        view?.subviews.compactMap { $0 as? RollInGhostView } ?? []
    }

    private func rowSummary(_ view: ChatTurnView?) -> String? {
        view?.activityRowViews.first?.row.summaryField.stringValue
    }

    /// Whether any part of message `ordinal` (or the leading groups, -1) of the turn is in the
    /// viewport; nil when it has no views of its own (it is folded).
    private func isOnScreen(_ rig: ScrollRig, turn id: UUID, ordinal: Int) -> Bool? {
        guard let view = rig.materialized[id], let rect = view.rollInRect(ordinal: ordinal) else { return nil }
        return RollInPolicy.isVisible(view.convert(rect, to: rig.doc), in: rig.clip.bounds)
    }

    private func screenY(_ rig: ScrollRig, of needle: String, inTurn id: UUID) -> CGFloat? {
        guard let view = rig.materialized[id],
              let item = view.subviews.first(where: { X.contains(needle, in: $0) }) else { return nil }
        return rig.screenY(of: item)
    }

    /// The first top-level item that still shows below the top of the viewport.
    private func topReading(_ rig: ScrollRig) -> ReaderPosition? {
        for turn in rig.turns {
            guard let view = rig.materialized[turn.id] else { continue }
            for item in view.subviews where rig.doc.convert(item.bounds, from: item).maxY > rig.clip.bounds.minY + 1 {
                let longest = X.texts(in: item)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 6 }
                    .max { $0.count < $1.count }
                guard let text = longest else { continue }
                let needle = String(text.prefix(40))
                guard let y = screenY(rig, of: needle, inTurn: turn.id) else { continue }
                return ReaderPosition(turnID: turn.id, needle: needle, y: y)
            }
        }
        return nil
    }

    private func assertReadingStill(_ rig: ScrollRig, _ reading: ReaderPosition, _ context: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let y = screenY(rig, of: reading.needle, inTurn: reading.turnID) else {
            return XCTFail("the first visible line (\"\(reading.needle)\") is no longer on screen: \(context)",
                           file: file, line: line)
        }
        XCTAssertLessThanOrEqual(abs(y - reading.y), 1,
                                 "the first visible line (\"\(reading.needle)\") moved by \(abs(y - reading.y)) pt: \(context)",
                                 file: file, line: line)
    }

    // MARK: - Helpers: the operator and the stream

    /// The operator scrolls 60 pt above the true bottom: not following, the end of the turn on screen.
    private func readFromJustAboveTheBottom(_ rig: ScrollRig) {
        rig.userScroll(to: rig.doc.frame.height - rig.viewportHeight - 60)
        rig.settle()
    }

    /// The viewport top that shows the end of the turn before `id` and only its first points: the
    /// turn is still built (inside the pane's overscan) but every message of it is below the viewport.
    private func yJustAbove(_ rig: ScrollRig, turn id: UUID) -> CGFloat {
        let index = rig.turns.firstIndex { $0.id == id } ?? 0
        return max(0, rig.virtualizer.offset(of: index) + 10 - rig.viewportHeight)
    }

    /// The operator moves the viewport, but the pane's roll-in holds have not looked yet. Lets a
    /// test read what the operator sees at `y`, and that nothing completed, before `react`.
    private func scrollQuietly(_ rig: ScrollRig, to y: CGFloat) {
        let onScroll = rig.followTail.onScroll
        rig.followTail.onScroll = nil
        rig.userScroll(to: y)
        rig.followTail.onScroll = onScroll
        rig.settle()
    }

    /// The holds look at where the viewport is now (what the scroll event does).
    private func react(_ rig: ScrollRig) {
        rig.rollInHolds.scrolled()
        rig.settle()
    }

    /// A newer message arrives: some calls, then the message `tag` (a roll-in, since a call
    /// separates it from the message before). `tallBlocks`: as a message that tall.
    private func arrive(_ rig: ScrollRig, _ tag: String, tallBlocks: Int? = nil, toTurnAt index: Int? = nil) {
        let message = tallBlocks.map { tallMessage(tag, blocks: $0) } ?? [focusMessage(tag)]
        rig.append(F.run(1, prefix: "call-\(tag)-") + message, toTurnAt: index)
    }

    // MARK: - Helpers: scenes

    /// A live turn whose latest message (ordinal 1, `HELD-0` ... `HELD-5`) is on screen in a pane
    /// scrolled 60 pt above the true bottom: the operator is reading, not following.
    private func holdingScene() -> (rig: ScrollRig, live: ChatTurn) {
        let live = F.turn([focusMessage("Earlier")] + F.run(2, prefix: "a") + tallMessage("HELD") + F.run(2, prefix: "b"),
                          complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        readFromJustAboveTheBottom(rig)
        return (rig, live)
    }

    /// Select `word` in the card that shows it: the card's text view takes focus and the word is
    /// the selection.
    private func select(_ word: String, in rig: ScrollRig, turn id: UUID) throws -> HeldSelection {
        let view = try XCTUnwrap(rig.materialized[id], "the turn is built")
        let textView = try XCTUnwrap(X.all(NSTextView.self, in: view).first { $0.string.contains(word) },
                                     "a card shows \(word) in a text view")
        let block = try XCTUnwrap(textBlock(containing: word, in: view))
        let range = (textView.string as NSString).range(of: word)
        XCTAssertNotEqual(range.location, NSNotFound, "\(word) is in the card's text")
        XCTAssertTrue(rig.window.makeFirstResponder(textView), "the card's text view takes focus")
        textView.setSelectedRange(range)
        XCTAssertEqual(textView.selectedRange, range, "precondition: the text is selected")
        return HeldSelection(textView: textView, block: block, range: range, text: word)
    }

    private func clearSelection(_ selection: HeldSelection) {
        selection.textView.setSelectedRange(NSRange(location: 0, length: 0))   // posts didChangeSelection
    }

    private func selectedText(_ selection: HeldSelection) -> String {
        let text = selection.textView.string as NSString
        let range = selection.textView.selectedRange
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return "" }
        return text.substring(with: range)
    }

    /// A live turn whose latest message (ordinal 1) is markdown (`SEL-0` ... `SEL-5`), with `word` of
    /// it selected. Following the tail, or scrolled up until the message is below the viewport.
    private func selectionScene(following: Bool, word: String = "SEL-5") throws
        -> (rig: ScrollRig, live: ChatTurn, selection: HeldSelection) {
        let live = F.turn([focusMessage("Earlier")] + F.run(2, prefix: "a") + tallMarkdownMessage("SEL"),
                          complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned, "precondition: the pane follows the tail")
        let selection = try select(word, in: rig, turn: live.id)
        // Taking focus may bring the text into view; this is the pane of a reader at the tail.
        rig.followTail.scrollToBottom()
        rig.settle()
        XCTAssertTrue(rig.followTail.isPinned, "precondition: the pane follows the tail")
        XCTAssertEqual(selection.textView.selectedRange, selection.range, "precondition: the selection survived")
        if !following {
            rig.userScroll(to: yJustAbove(rig, turn: live.id))
            rig.settle()
            XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator scrolled up")
            XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 1), false, "precondition: the message is off screen")
        }
        XCTAssertTrue(rig.window.firstResponder === selection.textView, "precondition: the selection holds focus")
        return (rig, live, selection)
    }

    // MARK: - 1. Visible, not following

    func testAVisibleMessageStaysWhereItIsWhenANewOneArrivesInAPaneThatIsNotFollowing() throws {
        let (rig, live) = holdingScene()
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading")
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 1), true, "precondition: the outgoing message is on screen")
        let view = try XCTUnwrap(rig.materialized[live.id])
        let blocks = (0 ..< 6).compactMap { textBlock(containing: "HELD-\($0)", in: view) }
        XCTAssertEqual(blocks.count, 6, "precondition: the message is six top-level text blocks")
        let reading = try XCTUnwrap(topReading(rig))
        let before = blocks.map { rig.screenY(of: $0) }

        arrive(rig, "NEXT-MSG")

        XCTAssertEqual(rig.holds, [1], "the message that was on screen (ordinal 1) is held")
        XCTAssertEqual(held(rig, turn: live.id), [1])
        let now = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertTrue(now === view)
        for (index, block) in blocks.enumerated() {
            XCTAssertTrue(textBlock(containing: "HELD-\(index)", in: now) === block,
                          "block \(index) of the held message is still a top-level text block, the same view")
            XCTAssertEqual(rig.screenY(of: block), before[index], accuracy: 1, "block \(index) of the held message moved")
        }
        let latest = try XCTUnwrap(textBlock(containing: "NEXT-MSG", in: now), "the new message appears")
        XCTAssertGreaterThan(rig.screenY(of: latest), rig.screenY(of: blocks[5]), "the new message is below the held one")
        assertReadingStill(rig, reading, "after a roll-in was held")
        XCTAssertFalse(rig.followTail.isPinned)
        XCTAssertTrue(rig.animator.requests.isEmpty, "a held roll-in plays nothing")
    }

    // MARK: - 2. Scrolling it out of view

    func testScrollingTheHeldMessageOutOfViewCompletesItsRollInWithoutMovingTheReader() throws {
        let (rig, live) = holdingScene()
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: the roll-in was held")

        scrollQuietly(rig, to: yJustAbove(rig, turn: live.id))

        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 1), false, "precondition: the held message is off screen")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: nothing has looked at the hold yet")
        let reading = try XCTUnwrap(topReading(rig))

        react(rig)

        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "the roll-in completed")
        XCTAssertFalse(rig.store.hasHolds)
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertTrue(view.heldOrdinals.isEmpty)
        XCTAssertNil(textBlock(containing: "HELD-0", in: view), "no top-level block still shows the message")
        XCTAssertFalse(X.contains("HELD-0", in: view), "the message is folded into the collapsed row")
        XCTAssertEqual(rowSummary(view)?.hasPrefix("2 messages"), true, rowSummary(view) ?? "no row")
        XCTAssertNotNil(textBlock(containing: "NEXT-MSG", in: view))
        assertReadingStill(rig, reading, "after the held roll-in completed off screen")
        XCTAssertTrue(rig.animator.requests.isEmpty, "a roll-in that completes off screen is never animated")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testScrollingTheHeldMessageOutOfViewThroughThePanesOwnScrollPathCompletesItsRollIn() throws {
        let (rig, live) = holdingScene()
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: the roll-in was held")

        rig.userScroll(to: yJustAbove(rig, turn: live.id))   // the scroll event itself is what completes it
        rig.settle()

        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "the scroll event released the hold")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertNil(textBlock(containing: "HELD-0", in: view))
        XCTAssertNotNil(textBlock(containing: "NEXT-MSG", in: view))
    }

    func testAHeldMessageStaysHeldWhenTheReaderScrollsButStillSeesPartOfIt() throws {
        let (rig, live) = holdingScene()
        arrive(rig, "NEXT-MSG")
        let view = try XCTUnwrap(rig.materialized[live.id])
        let blocks = (0 ..< 6).compactMap { textBlock(containing: "HELD-\($0)", in: view) }
        XCTAssertEqual(blocks.count, 6, "precondition")

        // The viewport moves up by less than it takes to push the message out of it.
        rig.userScroll(to: rig.clip.bounds.minY - 20)
        rig.settle()

        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 1), true, "precondition: still partly on screen")
        XCTAssertEqual(held(rig, turn: live.id), [1], "the message is still held")
        for (index, block) in blocks.enumerated() {
            XCTAssertTrue(textBlock(containing: "HELD-\(index)", in: rig.materialized[live.id]) === block,
                          "block \(index) of the held message is still the same top-level view")
        }
    }

    // MARK: - 3. Jump to latest

    func testJumpToLatestCompletesTheRollInAndLandsAtTheTrueBottom() throws {
        let (rig, live) = holdingScene()
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: the roll-in was held")
        rig.flips = []

        rig.followTail.pinToBottomAndScroll(cause: .jumpToLatest)   // what the overlay's button does
        rig.settle()

        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertEqual(rig.flips.map(\.cause), [.jumpToLatest])
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the pane is at the true bottom")
        XCTAssertTrue(held(rig, turn: live.id).isEmpty)
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertNil(textBlock(containing: "HELD-0", in: view), "no top-level block shows the old message")
        XCTAssertNotNil(textBlock(containing: "NEXT-MSG", in: view))
        XCTAssertEqual(rowSummary(view)?.hasPrefix("2 messages"), true, rowSummary(view) ?? "no row")
    }

    // MARK: - 4. A selection holds the message

    func testASelectionHoldsAMessageThatIsOffScreenAndClearingItCompletesTheRollInWithoutMovingTheReader() throws {
        let (rig, live, selection) = try selectionScene(following: false)

        arrive(rig, "NEXT-MSG")

        XCTAssertEqual(rig.holds, [1], "the selected message is held even though it is off screen")
        XCTAssertEqual(held(rig, turn: live.id), [1])
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertTrue(textBlock(containing: selection.text, in: view) === selection.block,
                      "the selected message is still a top-level block, the same view")
        XCTAssertEqual(selection.textView.selectedRange, selection.range, "the selection survived the roll-in")
        XCTAssertEqual(selectedText(selection), selection.text, "the selection still reads as the text that was selected")
        XCTAssertTrue(rig.window.firstResponder === selection.textView, "the selection keeps focus")
        XCTAssertNotNil(textBlock(containing: "NEXT-MSG", in: view))
        let reading = try XCTUnwrap(topReading(rig))

        clearSelection(selection)

        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "clearing the selection completes the roll-in")
        XCTAssertNil(textBlock(containing: selection.text, in: view), "the message is folded")
        XCTAssertFalse(X.contains("SEL-", in: view))
        XCTAssertEqual(rowSummary(view)?.hasPrefix("2 messages"), true, rowSummary(view) ?? "no row")
        assertReadingStill(rig, reading, "after the selection cleared and the roll-in completed")
        XCTAssertTrue(rig.animator.requests.isEmpty, "an off-screen completion is never animated")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testASelectionInThePaneCannotBeHeldAgainstJumpToLatest() throws {
        let (rig, live, selection) = try selectionScene(following: false)
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition")

        rig.followTail.pinToBottomAndScroll(cause: .jumpToLatest)
        rig.settle()

        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "jumping to latest completes every roll-in")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
        XCTAssertNil(textBlock(containing: selection.text, in: rig.materialized[live.id]))
    }

    // MARK: - 5. A selection in a pane that follows the tail

    func testASelectionInTheLatestMessageOfAFollowingPaneSurvivesARollInAndThePaneStaysAtTheBottom() throws {
        let (rig, live, selection) = try followingSelection()

        arrive(rig, "NEXT-MSG")

        XCTAssertEqual(rig.holds, [1], "the selected message is held although the pane follows the tail")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertTrue(textBlock(containing: selection.text, in: view) === selection.block, "the same view")
        XCTAssertEqual(selection.textView.selectedRange, selection.range, "the selection survived")
        XCTAssertEqual(selectedText(selection), selection.text, "the selected text is still copyable")
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the pane is still at the true bottom")
        XCTAssertTrue(rig.animator.requests.isEmpty, "a held roll-in plays nothing")
    }

    func testClearingTheSelectionInAFollowingPaneCompletesTheRollInWithOneShortCollapse() throws {
        let (rig, live, selection) = try followingSelection()
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: the roll-in was held")

        clearSelection(selection)

        XCTAssertTrue(held(rig, turn: live.id).isEmpty)
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertNil(textBlock(containing: selection.text, in: view), "the message is folded")
        XCTAssertEqual(rig.animator.requests.count, 1, "it is on screen in a following pane: one collapse")
        let duration = try XCTUnwrap(rig.animator.requests.first).duration
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThanOrEqual(duration, 0.15)
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the pane is at the true bottom")
    }

    func testASelectionInAPlainParagraphOfTheLatestMessageHoldsItToo() throws {
        // Plain prose is a label, not a card: its selection lives in the label's field editor.
        let live = F.turn([focusMessage("Earlier")] + F.run(2, prefix: "a") + tallMessage("PLAIN"), complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        let view = try XCTUnwrap(rig.materialized[live.id])
        let block = try XCTUnwrap(textBlock(containing: "PLAIN-5", in: view))
        let label = try XCTUnwrap(X.all(CopyMenuTextField.self, in: view).first { $0.stringValue.contains("PLAIN-5") },
                                  "the paragraph is a label")
        label.selectText(nil)
        let editor = try XCTUnwrap(rigEditor(of: label), "the label is being edited")
        XCTAssertGreaterThan(editor.selectedRange.length, 0, "precondition: the paragraph is selected")
        rig.followTail.scrollToBottom()
        rig.settle()
        XCTAssertTrue(rig.followTail.isPinned, "precondition: the pane follows the tail")
        let range = editor.selectedRange

        arrive(rig, "NEXT-MSG")

        XCTAssertEqual(rig.holds, [1], "a selection in a label holds the message, following the tail or not")
        XCTAssertTrue(textBlock(containing: "PLAIN-5", in: rig.materialized[live.id]) === block, "the same view")
        XCTAssertEqual(editor.selectedRange, range, "the selection survived the roll-in")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)

        editor.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "clearing the selection completes the roll-in")
        XCTAssertNil(textBlock(containing: "PLAIN-5", in: rig.materialized[live.id]))
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
    }

    private func followingSelection(word: String = "SEL-5") throws -> (rig: ScrollRig, live: ChatTurn, selection: HeldSelection) {
        let scene = try selectionScene(following: true, word: word)
        XCTAssertLessThanOrEqual(scene.rig.gapBelowViewport, 0.5, "precondition: at the true bottom")
        return scene
    }

    // MARK: - 6. A roll-in while the reader is selecting

    func testAMessageBeingSelectedInTheMiddleIsKeptWhileTheNextMessageStreamsInBlockByBlock() throws {
        // A drag cannot be performed here; a non-empty selection held by the first responder is
        // the state the pane reads (see the header). Selecting in the middle block of a six-block
        // message, then streaming the next message in a block at a time, is the shape of it.
        let (rig, live, selection) = try followingSelection(word: "SEL-2")
        let view = try XCTUnwrap(rig.materialized[live.id])
        let blocks = (0 ..< 6).compactMap { textBlock(containing: "SEL-\($0)", in: view) }
        XCTAssertEqual(blocks.count, 6, "precondition")

        func assertKept(_ step: String) {
            for (index, block) in blocks.enumerated() {
                XCTAssertTrue(textBlock(containing: "SEL-\(index)", in: rig.materialized[live.id]) === block,
                              "block \(index) of the message being selected was replaced: \(step)")
            }
            XCTAssertEqual(selection.textView.selectedRange, selection.range, "the selection was lost: \(step)")
            XCTAssertTrue(rig.window.firstResponder === selection.textView, "the selection lost focus: \(step)")
            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the pane left the true bottom: \(step)")
        }

        rig.append(F.run(1, prefix: "drag-call-"))
        assertKept("after the calls")
        rig.append([focusMessage("DRAG-NEXT first block")])
        assertKept("after the new message arrived")
        XCTAssertEqual(held(rig, turn: live.id), [1], "the message being selected is held")
        rig.append([.text("DRAG-NEXT second block")])
        assertKept("after the new message grew")
        XCTAssertEqual(held(rig, turn: live.id), [1])
    }

    // MARK: - 7. Off-screen roll-ins

    func testARollInOfAMessageAboveTheViewportInAPaneThatIsNotFollowingHappensAtOnceAndNothingMoves() throws {
        // The message, then thirty notes (never folded) the operator is reading below it.
        let live = F.turn([focusMessage("Earlier")] + F.run(2, prefix: "a") + [focusMessage("OFFSCREEN-MSG")]
                          + noteBlocks(30, tag: "after"), complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        let view = try XCTUnwrap(rig.materialized[live.id])
        let note = try XCTUnwrap(view.subviews.first { X.contains("after note 1.", in: $0) }, "precondition: the notes are built")
        rig.userScroll(to: rig.doc.convert(note.bounds, from: note).minY - 10)
        rig.settle()
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading the notes")
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 1), false, "precondition: the message is above the viewport")
        let reading = try XCTUnwrap(topReading(rig))
        XCTAssertEqual(reading.turnID, live.id, "precondition: the reader is in the live turn")

        arrive(rig, "NEXT-MSG")

        XCTAssertTrue(rig.holds.isEmpty, "nothing on screen to protect: no hold is recorded")
        XCTAssertTrue(held(rig, turn: live.id).isEmpty)
        XCTAssertTrue(rig.animator.requests.isEmpty, "an off-screen roll-in is never animated")
        let now = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertFalse(X.contains("OFFSCREEN-MSG", in: now), "the message rolled into the row at once")
        XCTAssertEqual(rowSummary(now)?.hasPrefix("2 messages"), true, rowSummary(now) ?? "no row")
        assertReadingStill(rig, reading, "after a roll-in above the viewport")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testARollInOfAMessageBelowTheViewportInAPaneThatIsNotFollowingHappensAtOnceAndNothingMoves() throws {
        let (rig, live) = holdingScene()
        scrollQuietly(rig, to: yJustAbove(rig, turn: live.id))
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 1), false, "precondition: the message is below the viewport")
        let reading = try XCTUnwrap(topReading(rig))

        arrive(rig, "NEXT-MSG")

        XCTAssertTrue(rig.holds.isEmpty)
        XCTAssertTrue(rig.animator.requests.isEmpty)
        XCTAssertFalse(X.contains("HELD-0", in: try XCTUnwrap(rig.materialized[live.id])))
        assertReadingStill(rig, reading, "after a roll-in below the viewport")
    }

    // MARK: - 8. Following through ten roll-ins

    func testAFollowingPaneStaysAtTheTrueBottomThroughTenRollInsAndEachCollapsesOnceForNoMoreThan150Milliseconds() throws {
        let live = F.turn([focusMessage("Starting")], complete: false, user: "go")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)

        for n in 0 ..< 10 {
            rig.append(F.run(2, prefix: "r\(n)_"))
            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "after the calls of step \(n)")
            rig.append([focusMessage("Message \(n)")])

            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "after roll-in \(n) the viewport ends at the true bottom")
            XCTAssertTrue(rig.followTail.isPinned, "after roll-in \(n)")
            // The turn opened with a message, so every roll-in has an outgoing message ("Starting",
            // then "Message 0" ...), and it is on screen at the tail: roll-in n is the (n+1)th collapse.
            XCTAssertEqual(rig.animator.requests.count, n + 1, "roll-in \(n) requests exactly one collapse")
        }

        for request in rig.animator.requests {
            XCTAssertGreaterThan(request.duration, 0)
            XCTAssertLessThanOrEqual(request.duration, 0.15)
        }
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(rowSummary(view)?.hasPrefix("10 messages"), true, rowSummary(view) ?? "no row")
        XCTAssertTrue(rig.holds.isEmpty, "a following pane with nothing selected never holds")
        XCTAssertTrue(rig.flips.filter { !$0.pinned }.isEmpty, "following never stopped")
        XCTAssertTrue(ghosts(in: view).isEmpty, "every collapse finished")
    }

    func testWithReduceMotionEveryRollInInAFollowingPaneIsInstant() throws {
        let live = F.turn([focusMessage("Starting")], complete: false, user: "go")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.reduceMotion = true
        rig.start()

        for n in 0 ..< 10 {
            rig.append(F.run(2, prefix: "r\(n)_"))
            rig.append([focusMessage("Message \(n)")])
            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "after roll-in \(n)")
        }

        XCTAssertTrue(rig.animator.requests.isEmpty, "Reduce Motion: nothing is animated")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(rowSummary(view)?.hasPrefix("10 messages"), true, rowSummary(view) ?? "no row")
        XCTAssertTrue(ghosts(in: view).isEmpty)
    }

    // MARK: - 10. Several holds

    func testASelectedMessageStaysWhileLaterMessagesRollInAsSoonAsTheyAreOffScreenAndClearingItFoldsTheRest() throws {
        let (rig, live, selection) = try selectionScene(following: false)
        let view = try XCTUnwrap(rig.materialized[live.id])
        let heldBlocks = (0 ..< 6).compactMap { textBlock(containing: "SEL-\($0)", in: view) }
        XCTAssertEqual(heldBlocks.count, 6, "precondition")

        arrive(rig, "M2-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "M1 is held by its selection")
        arrive(rig, "M3-MSG")   // M2 is the outgoing message, below the viewport: it rolls in at once

        XCTAssertEqual(rig.holds, [1], "only M1 was ever held")
        XCTAssertEqual(held(rig, turn: live.id), [1])
        let now = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertNil(textBlock(containing: "M2-MSG", in: now), "M2 is not a top-level message")
        XCTAssertFalse(X.contains("M2-MSG", in: now), "M2 is folded into the collapsed row that follows M1")
        for (index, block) in heldBlocks.enumerated() {
            XCTAssertTrue(textBlock(containing: "SEL-\(index)", in: now) === block, "M1 block \(index) is still the same view")
        }
        XCTAssertEqual(selection.textView.selectedRange, selection.range, "the selection survived both roll-ins")
        XCTAssertNotNil(textBlock(containing: "M3-MSG", in: now))
        let reading = try XCTUnwrap(topReading(rig))

        clearSelection(selection)

        XCTAssertFalse(rig.store.hasHolds, "M1 completed its roll-in once its selection cleared")
        XCTAssertEqual(X.kinds(now), ["ActivityRowView", "TextBlockView"], "both older messages are folded; M3 is the latest")
        XCTAssertEqual(rowSummary(now)?.hasPrefix("3 messages"), true, rowSummary(now) ?? "no row")
        XCTAssertNil(textBlock(containing: "SEL-0", in: now))
        assertReadingStill(rig, reading, "after M1 completed its roll-in")
    }

    func testAMessageHeldByBeingOnScreenRollsInWhenScrolledAwayWhileAnOlderSelectedOneStays() throws {
        let (rig, live, selection) = try selectionScene(following: false)
        arrive(rig, "M2-MSG", tallBlocks: 3)
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: M1 is held by its selection")
        // The operator reads back down to M2, then the next message arrives while M2 is on screen.
        readFromJustAboveTheBottom(rig)
        XCTAssertFalse(rig.followTail.isPinned)
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 2), true, "precondition: M2 is on screen")
        arrive(rig, "M3-MSG", tallBlocks: 3)
        XCTAssertEqual(held(rig, turn: live.id), [1, 2], "M2 is held by being on screen, M1 by its selection")

        scrollQuietly(rig, to: yJustAbove(rig, turn: live.id))
        XCTAssertEqual(held(rig, turn: live.id), [1, 2], "precondition: nothing has looked yet")
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 2), false, "precondition: M2 is off screen")
        let reading = try XCTUnwrap(topReading(rig))
        react(rig)

        XCTAssertEqual(held(rig, turn: live.id), [1], "M2 completed its roll-in, M1 stays held by its selection")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertNil(textBlock(containing: "M2-MSG", in: view))
        XCTAssertTrue(textBlock(containing: selection.text, in: view) === selection.block, "M1 is still the same top-level view")
        XCTAssertEqual(selection.textView.selectedRange, selection.range)
        assertReadingStill(rig, reading, "after M2 completed its roll-in")

        let afterM2 = try XCTUnwrap(topReading(rig))
        clearSelection(selection)

        XCTAssertFalse(rig.store.hasHolds)
        XCTAssertNil(textBlock(containing: selection.text, in: view), "M1 is folded")
        XCTAssertEqual(X.kinds(view), ["ActivityRowView", "TextBlockView", "TextBlockView", "TextBlockView"],
                       "one row, and the three blocks of M3, the latest message")
        assertReadingStill(rig, afterM2, "after M1 completed its roll-in")
    }

    // MARK: - 11. Two windows, one session (contract F4)

    func testTwoWindowsOnOneSessionFoldTheSameRowUnderOneKeyAndPresentTheSameStructureOnceTheHoldIsReleased() throws {
        let live = F.turn([focusMessage("Earlier")] + F.run(2, prefix: "a") + tallMessage("HELD") + F.run(2, prefix: "b"),
                          complete: false, user: "live")
        let turns = (0 ..< 4).map(longTurn) + [live]
        let rigA = ScrollRig(self, turns: turns)
        let rigB = ScrollRig(self, turns: turns)
        rigA.start()
        rigB.start()
        readFromJustAboveTheBottom(rigA)   // window A: the operator reads the message
        XCTAssertFalse(rigA.followTail.isPinned)
        XCTAssertTrue(rigB.followTail.isPinned, "window B follows the tail")

        arrive(rigA, "NEXT-MSG")
        arrive(rigB, "NEXT-MSG")

        XCTAssertEqual(rigA.holds, [1], "window A holds what its reader is looking at")
        XCTAssertTrue(rigB.holds.isEmpty, "window B follows: nothing to hold")
        let viewA = try XCTUnwrap(rigA.materialized[live.id])
        let viewB = try XCTUnwrap(rigB.materialized[live.id])
        XCTAssertNotNil(textBlock(containing: "HELD-0", in: viewA), "A still shows the message")
        XCTAssertNil(textBlock(containing: "HELD-0", in: viewB), "B folded it")
        let rowA = try XCTUnwrap(viewA.activityRowViews.first, "A shows the row above the held message")
        let rowB = try XCTUnwrap(viewB.activityRowViews.first)
        XCTAssertEqual(rowA.segment.key, rowB.segment.key, "the row has one key in both windows, hold or not")
        let key = rowB.segment.key

        // The operator opens the row in B.
        rigB.toggleActivityRow(turn: live.id, key: key)
        XCTAssertTrue(rowB.isExpanded)
        let reading = try XCTUnwrap(topReading(rigA))

        // What the pane does for a change made in another window (no fold-store subscription yet:
        // the change is applied through the same entry point a subscription will use).
        rigA.coordinator.applyFoldChange(turnIds: [live.id]) {
            rigA.store.setActivity(turn: live.id, key: key, true)
            rigA.materialized[live.id]?.applyFolds(FoldResolver(state: rigA.store.state(for: live.id), expandedByDefault: false))
        }

        assertReadingStill(rigA, reading, "after window B opened the row")
        let stillA = try XCTUnwrap(rigA.materialized[live.id])
        XCTAssertNotNil(textBlock(containing: "HELD-0", in: stillA), "A still shows the held message as a message")
        XCTAssertEqual(held(rigA, turn: live.id), [1], "the other window's change did not release A's hold")

        // A's hold completes (Jump to latest): the two windows now present the same turn.
        rigA.followTail.pinToBottomAndScroll(cause: .jumpToLatest)
        rigA.settle()

        XCTAssertTrue(held(rigA, turn: live.id).isEmpty)
        let finalA = try XCTUnwrap(rigA.materialized[live.id])
        let finalB = try XCTUnwrap(rigB.materialized[live.id])
        XCTAssertEqual(X.kinds(finalA), X.kinds(finalB))
        XCTAssertEqual(finalA.activityRowViews.map { $0.row.summaryField.stringValue },
                       finalB.activityRowViews.map { $0.row.summaryField.stringValue })
        XCTAssertEqual(finalA.activityRowViews.map(\.isExpanded), finalB.activityRowViews.map(\.isExpanded))
        XCTAssertEqual(finalA.activityRowViews.map(\.isExpanded), [true], "the row is open in both")
        XCTAssertEqual(finalA.activityRowViews.first?.laneMemberViews.map(X.typeName),
                       finalB.activityRowViews.first?.laneMemberViews.map(X.typeName), "the same lane")
        XCTAssertEqual(finalA.activityRowViews.map { $0.segment.key }, finalB.activityRowViews.map { $0.segment.key })
    }

    // MARK: - 13. Queued user messages

    func testAQueuedUserMessageNeitherReleasesNorAddsAHoldAndTheNextRollInStillFollowsThePolicy() throws {
        let (rig, live) = holdingScene()
        arrive(rig, "NEXT-1", tallBlocks: 3)
        XCTAssertEqual(rig.holds, [1], "precondition")
        let view = try XCTUnwrap(rig.materialized[live.id])
        let held1 = try XCTUnwrap(textBlock(containing: "HELD-0", in: view))
        let reading = try XCTUnwrap(topReading(rig))

        // The operator typed a message while the agent was running: a new turn after this one.
        rig.appendTurn(F.turn([], complete: false, user: "queued while running"))

        XCTAssertEqual(rig.holds, [1], "a new turn is not a roll-in: no new hold")
        XCTAssertEqual(held(rig, turn: live.id), [1], "and it released nothing")
        XCTAssertTrue(textBlock(containing: "HELD-0", in: rig.materialized[live.id]) === held1)
        assertReadingStill(rig, reading, "after a message was queued")
        XCTAssertFalse(rig.followTail.isPinned)

        // The agent keeps going; the reader is now looking at the latest message of the running turn.
        readFromJustAboveTheBottom(rig)
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 2), true, "precondition: the latest message is on screen")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: the older hold is still on screen")
        let index = try XCTUnwrap(rig.turns.firstIndex { $0.id == live.id })
        arrive(rig, "NEXT-2", toTurnAt: index)

        XCTAssertEqual(rig.holds, [1, 2], "the roll-in of an on-screen message in a pane that is not following is held, queued turn or not")
        XCTAssertEqual(held(rig, turn: live.id), [1, 2])
    }

    func testAQueuedUserMessageDoesNotBlockARollInInAFollowingPane() throws {
        let live = F.turn([focusMessage("Starting")] + F.run(2, prefix: "a"), complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        rig.appendTurn(F.turn([], complete: false, user: "queued while running"))
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "precondition")

        let index = try XCTUnwrap(rig.turns.firstIndex { $0.id == live.id })
        arrive(rig, "NEXT-MSG", toTurnAt: index)

        XCTAssertTrue(rig.holds.isEmpty)
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertFalse(X.contains("Starting", in: view), "the roll-in went through")
        XCTAssertEqual(rowSummary(view)?.hasPrefix("1 message"), true, rowSummary(view) ?? "no row")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
        XCTAssertTrue(rig.followTail.isPinned)
    }

    // MARK: - 14. The first roll-in has no outgoing message

    private func leadingGroupScene() -> (rig: ScrollRig, live: ChatTurn, key: String) {
        let live = F.turn(F.run(6, prefix: "lead"), complete: false, user: "live")
        let key = F.groups(of: live).first?.key ?? "g:lead0"
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.store.setGroup(turn: live.id, key: key, true)   // the operator opened it
        rig.start()
        return (rig, live, key)
    }

    func testTheGroupsBeforeTheFirstMessageStayOpenAsAGroupWhileTheReaderIsLookingAtThemAndFoldWhenScrolledAway() throws {
        let (rig, live, key) = leadingGroupScene()
        readFromJustAboveTheBottom(rig)
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading")
        let view = try XCTUnwrap(rig.materialized[live.id])
        let group = try XCTUnwrap(view.groupView(forKey: key), "precondition: the group is a top-level view")
        XCTAssertTrue(group.isExpanded, "precondition: the operator opened it")
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: FocusPlanner.leadingGroups), true, "precondition: it is on screen")
        let reading = try XCTUnwrap(topReading(rig))

        arrive(rig, "FIRST-MSG")

        XCTAssertEqual(rig.holds, [FocusPlanner.leadingGroups], "the groups before the first message are held")
        XCTAssertEqual(held(rig, turn: live.id), [FocusPlanner.leadingGroups])
        XCTAssertEqual(X.kinds(view), ["ToolGroupView", "TextBlockView"], "the group stays a group, the message follows it")
        XCTAssertTrue(view.groupView(forKey: key) === group, "the same group view")
        XCTAssertTrue(group.isExpanded, "still open")
        XCTAssertTrue(view.activityRowViews.isEmpty, "nothing folded")
        assertReadingStill(rig, reading, "after the first roll-in was held")

        scrollQuietly(rig, to: yJustAbove(rig, turn: live.id))
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: FocusPlanner.leadingGroups), false, "precondition: it is off screen")
        let away = try XCTUnwrap(topReading(rig))
        react(rig)

        XCTAssertTrue(held(rig, turn: live.id).isEmpty)
        XCTAssertEqual(X.kinds(view), ["ActivityRowView", "TextBlockView"], "the group folded into the row")
        XCTAssertEqual(view.activityRowViews.first?.row.summaryField.stringValue.contains("7 commands"), true,
                       rowSummary(view) ?? "no row")
        assertReadingStill(rig, away, "after the leading group completed its roll-in")
    }

    func testTheGroupsBeforeTheFirstMessageFoldAtOnceInAFollowingPane() throws {
        let (rig, live, _) = leadingGroupScene()
        XCTAssertTrue(rig.followTail.isPinned)

        arrive(rig, "FIRST-MSG")

        XCTAssertTrue(rig.holds.isEmpty, "a following pane holds nothing")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(X.kinds(view), ["ActivityRowView", "TextBlockView"])
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
        XCTAssertTrue(rig.followTail.isPinned)
    }

    // MARK: - 15. Keys survive a release

    func testARowOpenedWhileItsFirstMessageWasHeldStaysOpenAsTheWholeSegmentWhenTheMessageIsReleased() throws {
        // First message (ordinal 0) is held as it rolls in; the next one rolls in off screen, so
        // the rest of the segment is a continuation row keyed by its own first member.
        let live = F.turn(tallMessage("FIRST") + F.run(2, prefix: "a"), complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        readFromJustAboveTheBottom(rig)
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 0), true, "precondition: the first message is on screen")
        arrive(rig, "SECOND", tallBlocks: 3)
        XCTAssertEqual(rig.holds, [0], "precondition: the first message is held")

        // Read down to the end of the first message: the second is below the viewport.
        let view = try XCTUnwrap(rig.materialized[live.id])
        let first = try XCTUnwrap(view.rollInRect(ordinal: 0).map { view.convert($0, to: rig.doc) })
        rig.userScroll(to: first.maxY - 20 - rig.viewportHeight)
        rig.settle()
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 0), true, "precondition: still on screen")
        XCTAssertEqual(isOnScreen(rig, turn: live.id, ordinal: 1), false, "precondition: the second message is below the viewport")
        XCTAssertFalse(rig.followTail.isPinned)
        arrive(rig, "THIRD")
        XCTAssertEqual(rig.holds, [0], "the second message rolled in at once (off screen)")
        XCTAssertEqual(held(rig, turn: live.id), [0])

        let segmentKey = try XCTUnwrap(FocusFixtures.segments(of: rig.turns[rig.turns.count - 1]).first).key
        let continuation = try XCTUnwrap(view.activityRowViews.first, "the rest of the segment is a row of its own")
        XCTAssertNotEqual(continuation.segment.key, segmentKey, "precondition: the continuation has its own key")
        XCTAssertEqual(view.activityRowViews.count, 1)

        // The operator opens the continuation row.
        rig.toggleActivityRow(turn: live.id, key: continuation.segment.key)
        XCTAssertTrue(continuation.isExpanded)
        XCTAssertEqual(rig.activityToggles, ["\(continuation.segment.key)=true"])

        // The first message leaves the viewport: it rolls in and the segment is whole again.
        rig.userScroll(to: yJustAbove(rig, turn: live.id))
        rig.settle()

        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "the hold completed")
        let now = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(now.activityRowViews.map { $0.segment.key }, [segmentKey], "one row, under the segment's key")
        XCTAssertEqual(now.activityRowViews.map(\.isExpanded), [true], "the whole row stays open")
        XCTAssertEqual(rig.store.state(for: live.id).activityStates[segmentKey], true,
                       "the open state moved to the key the whole segment has")
        XCTAssertTrue(X.contains("FIRST-0", in: try XCTUnwrap(now.activityRowViews.first)), "the first message is in the open lane")
    }

    func testAToggleOnTheRowAboveAHeldMessageAppliesToTheWholeSegmentAfterTheRelease() throws {
        let (rig, live) = holdingScene()
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition")
        let segmentKey = try XCTUnwrap(FocusFixtures.segments(of: rig.turns[rig.turns.count - 1]).first).key
        let view = try XCTUnwrap(rig.materialized[live.id])
        let prefix = try XCTUnwrap(view.activityRowViews.first, "the row above the held message")
        XCTAssertEqual(prefix.segment.key, segmentKey, "the part before the held message keeps the segment's key")

        rig.toggleActivityRow(turn: live.id, key: segmentKey)
        XCTAssertTrue(prefix.isExpanded)

        rig.followTail.pinToBottomAndScroll(cause: .jumpToLatest)
        rig.settle()

        XCTAssertTrue(held(rig, turn: live.id).isEmpty)
        let now = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(now.activityRowViews.map { $0.segment.key }, [segmentKey])
        XCTAssertEqual(now.activityRowViews.map(\.isExpanded), [true], "the toggle applies to the whole segment")
        XCTAssertEqual(rig.store.state(for: live.id).activityStates[segmentKey], true)
        XCTAssertTrue(X.contains("HELD-0", in: try XCTUnwrap(now.activityRowViews.first)), "the released message is in the open lane")
    }

    // MARK: - 16. The bound

    func testATurnNeverHoldsMoreThanSixteenMessagesAndTheOldestAreReleasedFirst() throws {
        let live = F.turn([focusMessage("MSG-0")], complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        let view = try XCTUnwrap(rig.materialized[live.id])
        view.decideRollIn = { _ in .hold }   // hold every roll-in, so the bound is what limits them
        var dropped: [Int] = []
        let forget = view.onHoldDropped
        view.onHoldDropped = { ordinal in
            dropped.append(ordinal)
            forget?(ordinal)
        }

        for n in 1 ... 20 {
            rig.append([.note("Model changed \(n)."), focusMessage("MSG-\(n)")])
            let heldNow = held(rig, turn: live.id)
            XCTAssertLessThanOrEqual(heldNow.count, RollInPolicy.maxHeldPerTurn, "after message \(n)")
            XCTAssertEqual(heldNow, view.heldOrdinals, "the pane's record matches the view after message \(n)")
        }

        XCTAssertEqual(rig.holds, Array(0 ..< 20), "every roll-in was held when it happened")
        XCTAssertEqual(dropped, [0, 1, 2, 3], "the oldest holds were the ones released, oldest first")
        XCTAssertEqual(held(rig, turn: live.id), Set(4 ..< 20))
        for n in 0 ..< 4 {
            XCTAssertNil(textBlock(containing: "MSG-\(n) ", in: view), "message \(n) rolled in when it was released")
        }
        for n in 4 ..< 20 {
            XCTAssertNotNil(textBlock(containing: "MSG-\(n) ", in: view), "message \(n) is still held")
        }
    }

    // MARK: - 17. Cost

    private func scrollCost(turnCount: Int, holding: Bool) throws -> (events: Int, evaluations: Int) {
        let live = F.turn([focusMessage("Earlier")] + F.run(2, prefix: "a") + tallMessage("HELD") + F.run(2, prefix: "b"),
                          complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< turnCount).map(longTurn) + [live])
        rig.start()
        readFromJustAboveTheBottom(rig)
        if holding {
            arrive(rig, "NEXT-MSG")
            XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: one message is held")
        }
        var events = 0
        let wired = rig.followTail.onScroll
        rig.followTail.onScroll = {
            events += 1
            wired?()
        }
        let top = rig.clip.bounds.minY
        let before = rig.rollInHolds.evaluations

        for step in 0 ..< 12 {
            rig.userScroll(to: step % 2 == 0 ? top - 8 : top)   // the held message stays on screen
        }

        XCTAssertGreaterThan(events, 0, "the scrolls reached the pane's scroll hook")
        if holding { XCTAssertEqual(held(rig, turn: live.id), [1], "the message was held throughout") }
        return (events, rig.rollInHolds.evaluations - before)
    }

    func testScrollingAPaneThatHoldsNothingDoesNoHoldWork() throws {
        for turnCount in [4, 40] {
            let cost = try scrollCost(turnCount: turnCount, holding: false)
            XCTAssertEqual(cost.evaluations, 0, "\(turnCount) turns: \(cost.events) scroll events examined \(cost.evaluations) messages")
        }
    }

    func testScrollingAPaneWithOneHeldMessageExaminesOneMessagePerScrollWhateverTheNumberOfTurns() throws {
        for turnCount in [4, 40] {
            let cost = try scrollCost(turnCount: turnCount, holding: true)
            XCTAssertEqual(cost.evaluations, cost.events,
                           "\(turnCount) turns: \(cost.events) scroll events examined \(cost.evaluations) messages, one held")
        }
    }

    // MARK: - 18. Animation of a release, Reduce Motion, the ghost

    func testReleasingAHoldInAFollowingPaneWithReduceMotionOnIsInstant() throws {
        let (rig, live, selection) = try followingSelection()
        rig.reduceMotion = true
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition")

        clearSelection(selection)

        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "the roll-in completed")
        XCTAssertTrue(rig.animator.requests.isEmpty, "Reduce Motion: nothing is animated")
        XCTAssertNil(textBlock(containing: selection.text, in: rig.materialized[live.id]))
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
    }

    func testTheCollapseIsPlayedOnAGhostWhileTheGeometryIsAlreadyFinalAndTheGhostNeverTakesAClick() throws {
        let (rig, live, selection) = try followingSelection()
        arrive(rig, "NEXT-MSG")
        rig.animator.completesAtOnce = false
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition")

        clearSelection(selection)   // releases the hold in a following pane: on screen, so it collapses

        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(rig.animator.requests.count, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(rig.animator.requests.first).duration, 0.15)
        let ghost = try XCTUnwrap(ghosts(in: view).first, "the departing message plays on a ghost over the turn")
        XCTAssertTrue(rig.animator.requests.first?.ghost === ghost)
        XCTAssertEqual(ghosts(in: view).count, 1)
        XCTAssertTrue(X.contains(selection.text, in: ghost), "the ghost shows the departing message")
        XCTAssertTrue(held(rig, turn: live.id).isEmpty, "the roll-in itself is done")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the geometry is already final while the ghost plays")
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertNil(textBlock(containing: selection.text, in: view), "no top-level block shows it any more")

        let center = NSPoint(x: ghost.frame.midX, y: ghost.frame.midY)
        XCTAssertNil(ghost.hitTest(center), "a ghost never takes a hit")
        let hit = view.hitTest(view.convert(center, to: view.superview))
        XCTAssertFalse(hit.map { $0.isDescendant(of: ghost) } ?? false, "a click over the ghost reaches nothing in it")

        rig.animator.finishAll()

        XCTAssertTrue(ghosts(in: view).isEmpty, "the ghost is gone once the collapse finished")
        XCTAssertFalse(X.contains(selection.text, in: view), "and so is the message")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
    }

    func testAnOnScreenRollInInAFollowingPanePlaysOnAGhostWhileTheGeometryIsAlreadyFinal() throws {
        let live = F.turn([focusMessage("OLD-MSG")] + F.run(1, prefix: "a"), complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.animator.completesAtOnce = false
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)

        arrive(rig, "NEW-MSG")

        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(rig.animator.requests.count, 1)
        XCTAssertEqual(ghosts(in: view).count, 1, "the outgoing message plays on a ghost")
        XCTAssertTrue(X.contains("OLD-MSG", in: view), "it is still drawn, on the ghost")
        XCTAssertNil(textBlock(containing: "OLD-MSG", in: view), "but it is not a block of the turn")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the pane is already at its final bottom")
        XCTAssertNotNil(textBlock(containing: "NEW-MSG", in: view))

        rig.animator.finishAll()

        XCTAssertTrue(ghosts(in: view).isEmpty)
        XCTAssertFalse(X.contains("OLD-MSG", in: view))
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
    }

    func testARollInGhostNeverTakesAHitWhateverItCovers() {
        let ghost = RollInGhostView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 80, height: 30))
        ghost.addSubview(button)

        XCTAssertNil(ghost.hitTest(NSPoint(x: 20, y: 20)), "over a button inside it")
        XCTAssertNil(ghost.hitTest(NSPoint(x: 150, y: 80)), "over nothing")
        XCTAssertNil(ghost.hitTest(NSPoint(x: 500, y: 500)), "outside it")
    }

    // MARK: - 19. An evicted turn

    func testAHoldWhoseTurnWasEvictedIsDroppedOnTheNextScroll() throws {
        let (rig, live) = holdingScene()
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(held(rig, turn: live.id), [1], "precondition: the roll-in was held")

        // The operator is far away; no hold looks until the turn's view is gone.
        scrollQuietly(rig, to: 0)
        XCTAssertNil(rig.materialized[live.id], "precondition: the turn's view was evicted")
        XCTAssertTrue(rig.store.hasHolds, "precondition: the hold is still recorded")

        rig.userScroll(to: 20)
        rig.settle()

        XCTAssertFalse(rig.store.hasHolds, "a turn with no view has nothing on screen and nothing selected: its hold is dropped")
        XCTAssertTrue(held(rig, turn: live.id).isEmpty)

        // Back at the tail, the rebuilt turn shows the message folded.
        rig.followTail.pinToBottomAndScroll(cause: .jumpToLatest)
        rig.settle()
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertNil(textBlock(containing: "HELD-0", in: view), "the dropped hold does not come back")
        XCTAssertNotNil(textBlock(containing: "NEXT-MSG", in: view))
        XCTAssertEqual(rig.holds, [1], "and nothing was held again")
    }

    // MARK: - 20. Nothing about holds is persisted or broadcast

    func testTheFoldStoreThatIsPersistedAndSharedKnowsNothingOfRollInHolds() throws {
        let source = URL(fileURLWithPath: #filePath)   // …/macOS/NostromoTests/FocusRollInScrollTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent("Nostromo/Data/TranscriptFoldStore.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.isEmpty, "the fold store source was found")

        for term in ["RollInPolicy", "RollInHolds", "heldMessages", "heldOrdinals", "heldTurns", "RollInDecision"] {
            XCTAssertFalse(text.contains(term),
                           "TranscriptFoldStore mentions \(term): holds are per pane and transient, never persisted or broadcast")
        }
    }
}

// MARK: - 12. The composer keeps first responder

final class FocusRollInComposerTests: XCTestCase {

    private func tallMessage(_ tag: String, blocks: Int = 6) -> [TurnBlock] {
        (0 ..< blocks).map { TurnBlock.text("\(tag)-\($0) \(F.prose) \(F.prose) \(F.prose)") }
    }

    private func makeRig(following: Bool) -> (rig: SafetyRig, live: ChatTurn) {
        let live = F.turn([focusMessage("Earlier")] + F.run(2, prefix: "a") + tallMessage("HELD") + F.run(2, prefix: "b"),
                          complete: false, user: "live")
        let rig = SafetyRig(self, turns: (0 ..< 4).map { SafetyFixtures.tallTurn($0) } + [live])
        rig.start()
        if !following {
            rig.userScroll(to: rig.doc.frame.height - rig.viewportHeight - 60)
            rig.settle()
        }
        rig.focusComposer()
        return (rig, live)
    }

    private func arrive(_ rig: SafetyRig, _ tag: String) {
        rig.append(F.run(1, prefix: "call-\(tag)-") + [focusMessage(tag)])
    }

    private struct Composer {
        let responder: NSResponder?
        let text: String
        let selection: NSRange
    }

    private func composer(_ rig: SafetyRig) -> Composer {
        Composer(responder: rig.window.firstResponder, text: rig.textView.string, selection: rig.textView.selectedRange())
    }

    private func assertUntouched(_ rig: SafetyRig, _ before: Composer, _ context: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(rig.window.firstResponder === rig.textView,
                      "the composer lost first responder to \(String(describing: rig.window.firstResponder)): \(context)",
                      file: file, line: line)
        XCTAssertTrue(rig.window.firstResponder === before.responder, "first responder changed: \(context)", file: file, line: line)
        XCTAssertEqual(rig.textView.string, before.text, "composer text changed: \(context)", file: file, line: line)
        XCTAssertEqual(rig.textView.selectedRange(), before.selection, "composer selection changed: \(context)", file: file, line: line)
    }

    func testAFollowingPanesRollInsAndTheirCollapsesNeverTouchTheComposer() throws {
        let (rig, live) = makeRig(following: true)
        let before = composer(rig)
        XCTAssertTrue(rig.followTail.isPinned)

        for n in 0 ..< 3 {
            arrive(rig, "Message \(n)")
            assertUntouched(rig, before, "roll-in \(n)")
            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "roll-in \(n)")
        }
        XCTAssertEqual(rig.animator.requests.count, 3, "precondition: each on-screen roll-in collapsed")

        rig.animator.completesAtOnce = false
        arrive(rig, "Message 3")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(view.subviews.compactMap { $0 as? RollInGhostView }.count, 1, "precondition: a collapse is playing")
        assertUntouched(rig, before, "while a collapse is playing")

        rig.animator.finishAll()
        assertUntouched(rig, before, "after the collapse finished")
    }

    func testAHeldRollInInAPaneThatIsNotFollowingMovesNothingAndNeverTouchesTheComposer() throws {
        let (rig, live) = makeRig(following: false)

        rig.assertNoMove("a roll-in held while the reader looks at the message", following: false) {
            arrive(rig, "NEXT-MSG")
        }

        XCTAssertEqual(rig.store.state(for: live.id).heldOrdinals, [1], "precondition: the roll-in was held")
    }

    func testReleasingAHoldByScrollingNeverTouchesTheComposer() throws {
        let (rig, live) = makeRig(following: false)
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(rig.store.state(for: live.id).heldOrdinals, [1], "precondition")
        let before = composer(rig)

        rig.userScroll(to: max(0, rig.virtualizer.offset(of: rig.turns.count - 1) + 10 - rig.viewportHeight))
        rig.settle()

        XCTAssertFalse(rig.store.hasHolds, "precondition: the hold was released by the scroll")
        assertUntouched(rig, before, "after the release by scrolling")
    }

    func testReleasingAHoldWithJumpToLatestNeverTouchesTheComposer() throws {
        let (rig, live) = makeRig(following: false)
        arrive(rig, "NEXT-MSG")
        XCTAssertEqual(rig.store.state(for: live.id).heldOrdinals, [1], "precondition")
        let before = composer(rig)

        rig.followTail.pinToBottomAndScroll(cause: .jumpToLatest)
        rig.settle()

        XCTAssertFalse(rig.store.hasHolds, "precondition: the hold was released by the jump")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
        assertUntouched(rig, before, "after Jump to latest")
    }
}
