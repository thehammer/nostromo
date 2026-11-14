import XCTest
import AppKit
import NostromoKit

// A local slash command's answer (`/context`, `/model haiku`) is drawn where the user's message would be:
// ONE muted line, `/<command> <args> · <first output line>` (or `no output`), with a chevron when the output
// has more than one non-blank line, and never a bubble. Click, Space, Return or a VoiceOver press opens the
// rest below it. stderr output says `error` in amber. Opened or closed survives the turn view being rebuilt
// (the choice is kept in the pane's `FoldResolver`), and the turn's height is arithmetic, so the estimator
// agrees with the view.
//
// LocalCommandRecordView, ChatTurnView, TurnHeightEstimator, FoldResolver and Theme are compiled into this
// target directly. Reuses `MotherNoticeFixtures` (WakeMarkerTests.swift) and `OriginFixtures` (TurnOriginTests.swift).

private final class FlippedHost: NSView {
    override var isFlipped: Bool { true }
}

final class LocalCommandRecordTests: MouseQueueTestCase {

    private let windows = WindowBag()

    override func tearDown() {
        windows.tearDown()
        super.tearDown()
    }

    // MARK: Helpers

    private let manyLines = (1...5).map { "line \($0)" }.joined(separator: "\n")

    private func record(command: String = "context", args: String = "", output: String, stream: String = "stdout",
                        expanded: Bool = false, board: NSPasteboard = .general) -> LocalCommandRecordView {
        LocalCommandRecordView(command: command, args: args, output: output, stream: stream,
                               startExpanded: expanded, pasteboard: board)
    }

    /// The record in a window, at `width`, the way the transcript holds it (a flipped parent, no relayout).
    private func hosted(_ view: LocalCommandRecordView, width: CGFloat = 600) -> NSWindow {
        let window = windows.make(width: width, height: 400)
        let host = FlippedHost(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        window.contentView = host
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.arithmeticHeight(atWidth: width))
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func click(in window: NSWindow, atY y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 400 - y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func turn(output: String, command: String = "context", args: String = "", stream: String = "stdout") -> ChatTurn {
        OriginFixtures.turn(userInput: args.isEmpty ? "/\(command)" : "/\(command) \(args)",
                            origin: .localCommand(command: command, args: args, output: output, stream: stream, truncated: false))
    }

    private func turnView(_ turn: ChatTurn, folds: FoldResolver? = nil, width: CGFloat = 700) -> ChatTurnView {
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState(), folds: folds)
        view.setIslandWidth(width)
        return view
    }

    private func openFolds() -> FoldResolver {
        var folds = FoldResolver()
        folds.resultStates[LocalCommandRecordKey.blockIndex] = true
        return folds
    }

    private func isColor(_ a: Any?, _ b: NSColor) -> Bool {
        guard let a = (a as? NSColor)?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    private func headerLabel(_ view: LocalCommandRecordView) throws -> NSTextField {
        try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first, "the record's header label")
    }

    // MARK: Header text

    func testTheHeaderIsTheCommandWithItsArgumentsAndTheFirstOutputLine() {
        XCTAssertEqual(record(command: "model", args: "haiku", output: "Set model to claude-haiku-4-5").headerText,
                       "/model haiku · Set model to claude-haiku-4-5")
        XCTAssertEqual(record(output: "3k tokens used").headerText, "/context · 3k tokens used")
    }

    func testTheHeaderSaysNoOutputWhenThereIsNone() {
        for output in ["", "   ", "\n\n", " \n \t\n"] {
            let view = record(output: output)

            XCTAssertEqual(view.headerText, "/context · no output", output.debugDescription)
            XCTAssertFalse(view.hasChevron, output.debugDescription)
        }
    }

    func testTheHeaderShowsTheFirstNonBlankLineTrimmed() {
        XCTAssertEqual(record(output: "\n  first  \nsecond").headerText, "\u{25B8} /context · first")
    }

    func testTheHeaderOfAnErrorSaysErrorBetweenTheCommandAndTheOutput() {
        XCTAssertEqual(record(command: "model", args: "nope", output: "Unknown model", stream: "stderr").headerText,
                       "/model nope · error · Unknown model")
    }

    // MARK: Chevron

    func testTheChevronShowsOnlyWhenThereIsMoreThanOneNonBlankLine() {
        let cases: [(output: String, chevron: Bool)] = [
            ("", false), ("one line", false), ("one\n", false), ("a\n\n", false), ("\n\na", false), ("a\n   \n", false),
            ("a\nb", true), ("a\n  \nb", true), ("a\r\nb", true), ("a\n\n\nb", true), ("  a\n  b", true),
        ]
        for (output, chevron) in cases {
            let view = record(output: output)

            XCTAssertEqual(view.hasChevron, chevron, output.debugDescription)
            XCTAssertEqual(view.headerText.hasPrefix("\u{25B8} "), chevron, "collapsed header \(view.headerText.debugDescription)")
        }
    }

    func testTheChevronPointsDownWhenOpen() {
        let view = record(output: manyLines, expanded: true)

        XCTAssertTrue(view.headerText.hasPrefix("\u{25BE} /context"), view.headerText)
    }

    // MARK: Error colour

    func testOnlyTheWordErrorIsAmberAndTheRestOfTheHeaderIsMuted() throws {
        let view = record(command: "model", args: "nope", output: "Unknown model", stream: "stderr")
        let label = try headerLabel(view)
        let line = label.attributedStringValue
        let word = (line.string as NSString).range(of: "error")
        XCTAssertNotEqual(word.location, NSNotFound)

        for i in 0..<line.length {
            let color = line.attribute(.foregroundColor, at: i, effectiveRange: nil)
            if NSLocationInRange(i, word) {
                XCTAssertTrue(isColor(color, Theme.amber), "character \(i) of the word `error` is amber")
            } else {
                XCTAssertTrue(isColor(color, Theme.fgMuted), "character \(i) (\(line.string.debugDescription)) is the muted colour")
            }
        }
    }

    func testAnOrdinaryRecordIsMutedThroughoutEvenWhenItsOutputSaysError() throws {
        let view = record(output: "error: not really", stream: "stdout")
        let line = try headerLabel(view).attributedStringValue

        for i in 0..<line.length {
            XCTAssertTrue(isColor(line.attribute(.foregroundColor, at: i, effectiveRange: nil), Theme.fgMuted), "character \(i)")
        }
    }

    // MARK: Toggling

    func testToggleOpensAndClosesTheOutputAndReportsTheNewState() {
        let view = record(output: manyLines)
        var reported: [Bool] = []
        view.onExpansionChange = { reported.append($0) }
        XCTAssertFalse(view.isExpanded)
        XCTAssertNil(view.expandedText)
        XCTAssertNil(view.bodyFrame)

        view.toggle()

        XCTAssertTrue(view.isExpanded)
        XCTAssertEqual(view.expandedText, manyLines)
        XCTAssertNotNil(view.bodyFrame)

        view.toggle()

        XCTAssertFalse(view.isExpanded)
        XCTAssertNil(view.expandedText)
        XCTAssertEqual(reported, [true, false])
    }

    func testARecordWithNothingToOpenIgnoresToggle() {
        for output in ["", "one line", "one\n\n"] {
            let view = record(output: output)
            var calls = 0
            view.onExpansionChange = { _ in calls += 1 }

            view.toggle()

            XCTAssertFalse(view.isExpanded, output.debugDescription)
            XCTAssertEqual(calls, 0, output.debugDescription)
        }
    }

    func testARecordWithNothingToOpenNeverStartsOpen() {
        XCTAssertFalse(record(output: "one line", expanded: true).isExpanded)
    }

    func testAClickOnTheHeaderToggles() {
        let view = record(output: manyLines)
        let window = hosted(view)

        view.mouseDown(with: click(in: window, atY: 6))
        XCTAssertTrue(view.isExpanded)

        view.mouseDown(with: click(in: window, atY: 6))
        XCTAssertFalse(view.isExpanded)
    }

    func testAClickBelowTheHeaderDoesNotCloseTheOutput() {
        let view = record(output: manyLines, expanded: true)
        let window = hosted(view)

        view.mouseDown(with: click(in: window, atY: 60))

        XCTAssertTrue(view.isExpanded, "clicking the output (to select it) must not fold it")
    }

    func testSpaceAndReturnToggle() {
        let view = record(output: manyLines)

        view.keyDown(with: MotherNoticeFixtures.keyDown(49, " "))
        XCTAssertTrue(view.isExpanded, "Space opens")

        view.keyDown(with: MotherNoticeFixtures.keyDown(36, "\r"))
        XCTAssertFalse(view.isExpanded, "Return closes")
    }

    func testACommandKeyChordDoesNotToggle() {
        let view = record(output: manyLines)

        view.keyDown(with: MotherNoticeFixtures.keyDown(49, " ", flags: [.command]))

        XCTAssertFalse(view.isExpanded)
    }

    func testAVoiceOverPressToggles() {
        let view = record(output: manyLines)

        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(view.isExpanded)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertFalse(view.isExpanded)
    }

    func testARecordWithNothingToOpenRefusesAVoiceOverPress() {
        let view = record(output: "one line")

        XCTAssertFalse(view.accessibilityPerformPress())
        XCTAssertFalse(view.isExpanded)
    }

    // MARK: Accessibility

    func testTheAccessibilityLabelNamesTheCommandAndWhetherItsOutputIsOpen() {
        let view = record(command: "context", output: manyLines)

        XCTAssertEqual(view.accessibilityLabel(), "Command /context, output collapsed")
        view.toggle()
        XCTAssertEqual(view.accessibilityLabel(), "Command /context, output expanded")
    }

    func testTheAccessibilityValueIsTheFirstLineAndTheRoleIsAButtonOnlyWhenItCanOpen() {
        let openable = record(output: manyLines)
        let single = record(output: "just this")
        let none = record(output: "")

        XCTAssertEqual(openable.accessibilityValue() as? String, "line 1")
        XCTAssertEqual(single.accessibilityValue() as? String, "just this")
        XCTAssertEqual(none.accessibilityValue() as? String, "no output")
        XCTAssertEqual(openable.accessibilityRole(), .button)
        XCTAssertEqual(single.accessibilityRole(), .staticText)
        XCTAssertTrue(openable.isAccessibilityElement())
    }

    // MARK: Copy

    func testCopyOutputPutsTheFullOutputOnThePasteboardEvenWhileCollapsed() throws {
        let board = MotherNoticeFixtures.pasteboard(self)
        let output = "line 1\n\n  line 3 with trailing  \nlast\u{1B}[31m\u{202E}"
        let view = record(output: output, board: board)

        let menu = try XCTUnwrap(view.menu(for: MotherNoticeFixtures.rightClick()))
        let item = try XCTUnwrap(menu.items.first { $0.title == LocalCommandRecordView.copyMenuTitle }, "\(menu.items.map(\.title))")
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap((item.target ?? view) as? NSObject)
        _ = target.perform(action, with: item)

        XCTAssertEqual(board.string(forType: .string).map { Array($0.utf8) }, Array(output.utf8))
        XCTAssertEqual(LocalCommandRecordView.copyMenuTitle, "Copy Output")
    }

    // MARK: Inside a turn

    func testARecordTurnDrawsTheRecordAndNoBubbleOrMarker() {
        let view = turnView(turn(output: "3k tokens used"))

        XCTAssertEqual(view.localCommandRecordView?.headerText, "/context · 3k tokens used")
        XCTAssertFalse(view.hasUserBubble)
        XCTAssertNil(view.wakeMarkerView)
    }

    func testTheOpenStateSurvivesTheTurnViewBeingRebuiltFromTheFoldsTheToggleReported() throws {
        let record = turn(output: manyLines)
        let first = turnView(record)
        var reported: [(index: Int, open: Bool)] = []
        first.onBlockExpansion = { reported.append(($0, $1)) }

        try XCTUnwrap(first.localCommandRecordView).toggle()

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.index, LocalCommandRecordKey.blockIndex)
        XCTAssertEqual(reported.first?.open, true)

        // The pane records what was reported in the focus's folds; an evicted and rebuilt view reads it back.
        var folds = FoldResolver()
        for entry in reported { folds.resultStates[entry.index] = entry.open }
        let rebuilt = turnView(record, folds: folds)

        XCTAssertEqual(rebuilt.localCommandRecordView?.isExpanded, true)
        XCTAssertEqual(rebuilt.localCommandRecordView?.expandedText, manyLines)
    }

    func testARecordTurnStartsClosedWhenNothingWasChosen() {
        XCTAssertEqual(turnView(turn(output: manyLines)).localCommandRecordView?.isExpanded, false)
    }

    func testClosingARecordIsReportedToo() throws {
        let view = turnView(turn(output: manyLines), folds: openFolds())
        var reported: [Bool] = []
        view.onBlockExpansion = { index, open in
            if index == LocalCommandRecordKey.blockIndex { reported.append(open) }
        }

        try XCTUnwrap(view.localCommandRecordView).toggle()

        XCTAssertEqual(reported, [false])
    }

    func testTogglingTheRecordTellsTheOwnerTheTurnChangedHeight() throws {
        let view = turnView(turn(output: manyLines))
        var heightChanges = 0
        view.onIntrinsicHeightChange = { heightChanges += 1 }
        let before = view.islandHeight()

        try XCTUnwrap(view.localCommandRecordView).toggle()

        XCTAssertEqual(heightChanges, 1)
        XCTAssertGreaterThan(view.islandHeight(), before)
    }

    // MARK: Height

    func testACollapsedRecordTurnIsEstimatedAsChromePlusOneMarkerLinePlusTheGap() {
        let expected = TurnHeightEstimator.turnChrome + TurnHeightEstimator.wakeMarkerHeight + TurnHeightEstimator.userSlotGap
        for output in ["", "one line", manyLines, String(repeating: "wrapped ", count: 500)] {
            for width: CGFloat in [260, 700, 900] {
                XCTAssertEqual(TurnHeightEstimator.estimate(turn(output: output), width: width), expected, accuracy: 0.001,
                               "width \(width), \(output.count) characters")
            }
        }
    }

    func testAnOpenRecordTurnIsEstimatedAsTallAsItIsDrawn() {
        let long = (1...40).map { "line \($0) " + String(repeating: "word ", count: 30) }.joined(separator: "\n")
        for output in [manyLines, long] {
            for width: CGFloat in [260, 700, 900] {
                let record = turn(output: output)
                let drawn = turnView(record, folds: openFolds(), width: width).islandHeight()

                XCTAssertEqual(TurnHeightEstimator.estimate(record, width: width, folds: openFolds()), drawn, accuracy: 1,
                               "open, width \(width), \(output.count) characters")
                XCTAssertGreaterThan(drawn, TurnHeightEstimator.estimate(record, width: width), "open is taller than closed")
            }
        }
    }

    func testTheCollapsedRecordTurnIsEstimatedAsTallAsItIsDrawn() {
        for width: CGFloat in [260, 700, 900] {
            let record = turn(output: manyLines)

            XCTAssertEqual(turnView(record, width: width).islandHeight(), TurnHeightEstimator.estimate(record, width: width),
                           accuracy: 1, "width \(width)")
        }
    }

    func testARecordWithNothingToOpenIsEstimatedClosedEvenIfTheFoldSaysOpen() {
        let record = turn(output: "one line")

        XCTAssertEqual(TurnHeightEstimator.estimate(record, width: 700, folds: openFolds()),
                       TurnHeightEstimator.estimate(record, width: 700), accuracy: 0.001)
    }
}
