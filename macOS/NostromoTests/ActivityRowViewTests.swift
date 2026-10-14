import XCTest
import AppKit
import NostromoKit

// FV2: the activity row as a control. Accessibility (role, label, value, press, reading order),
// keyboard, Reduce Motion, click, and what the row does while a live turn changes it.
//
// Stated from outside, like `ToolGroupRowTests`: the strings the row shows, the callbacks it
// fires, the heights it reports. The window is the shared offscreen rig; nothing here reads a
// clock or touches the real pasteboard.

private typealias F = FoldFixtures
private typealias X = FocusFixtures

private let rowPaneWidth: CGFloat = 900

private func rowKeyEvent(_ keyCode: UInt16, _ characters: String, in window: NSWindow,
                         flags: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: window.windowNumber, context: nil, characters: characters,
                     charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
}

private func rowArrow(_ function: Int) -> String { String(UnicodeScalar(UInt32(function))!) }

private enum RowKey {
    static let space: UInt16 = 49, `return`: UInt16 = 36, left: UInt16 = 123, right: UInt16 = 124
}

/// Two earlier messages with a failing group of three calls (t=0 to 4.1 s) after the first and
/// one more call after the second, then the latest message: the row reads
/// `2 messages, ran 4 commands · 1 failed · 4.1 s`.
private func standardBlocks() -> [TurnBlock] {
    [X.message("ALPHA-MSG")] + X.failingRun("f") + [X.message("BRAVO-MSG")] + F.run(1, prefix: "g")
        + [X.message("CHARLIE-MSG"), F.chip()]
}

private struct RowRig {
    let window: RigWindow
    let view: ActivityRowView
    let turn: ChatTurn
    var row: ActivityRowHeaderView { view.row }

    /// Re-measure and re-lay out after the lane changed.
    func relayout() {
        let height = ChatTurnView.measureIsland(view, width: ChatTurnView.blockWidth(paneWidth: rowPaneWidth))
        view.frame = NSRect(x: 20, y: 700 - height, width: view.frame.width, height: height)
        window.contentView!.layoutSubtreeIfNeeded()
    }
}

private func makeRig(_ testCase: XCTestCase, blocks: [TurnBlock] = standardBlocks(), expanded: Bool = false,
                     reduceMotion: @escaping () -> Bool = { false }, folds: FoldResolver = FoldResolver()) -> RowRig {
    let turn = F.turn(blocks)
    let segment = X.segments(of: turn)[0]
    let window = makeRigWindow(testCase, size: NSSize(width: 1000, height: 800))
    let view = ActivityRowView(segment: segment, blocks: X.blocks(for: segment, in: turn), contentAvailable: true,
                               interaction: TurnInteractionState(), folds: folds, isExpanded: expanded,
                               reduceMotion: reduceMotion)
    window.contentView!.addSubview(view)
    let rig = RowRig(window: window, view: view, turn: turn)
    rig.relayout()
    return rig
}

final class ActivityRowViewTests: XCTestCase {

    // MARK: The row

    func testTheRowIsTwentyTwoPointsAndSharesItsBaseWithTheToolGroupRow() {
        XCTAssertEqual(FoldRowView.height, 22)
        XCTAssertEqual(ToolGroupRowView.height, 22)
        let rig = makeRig(self)
        XCTAssertEqual(ChatTurnView.measureIsland(rig.view, width: ChatTurnView.blockWidth(paneWidth: rowPaneWidth)), 22,
                       accuracy: 0.5, "a collapsed activity row is one row, whatever it folds")
        XCTAssertTrue(rig.row is FoldRowView)
        let groupRow = ToolGroupRowView(group: F.plainGroup(calls: 2), isExpanded: false, payloadAvailable: true)
        XCTAssertTrue((groupRow as AnyObject) is FoldRowView)
    }

    func testTheRowShowsTheTitleTheFailureBadgeAndTheTimeOfItsSegment() {
        let rig = makeRig(self)
        let segment = X.segments(of: rig.turn)[0]

        XCTAssertEqual(rig.row.summaryField.stringValue, ActivitySummary.title(for: segment))
        XCTAssertEqual(rig.row.summaryField.stringValue, "2 messages, ran 4 commands")
        XCTAssertFalse(rig.row.badgeField.isHidden)
        XCTAssertEqual(rig.row.badgeField.stringValue.trimmingCharacters(in: .whitespaces), "· 1 failed")
        XCTAssertTrue(X.same(rig.row.badgeField.textColor, Theme.foldFailure))
        XCTAssertFalse(rig.row.timeField.isHidden)
        XCTAssertEqual(rig.row.timeField.stringValue.trimmingCharacters(in: .whitespaces), "· 4.1 s")
    }

    func testTheBadgeAndTimeAreHiddenWhenThereIsNothingToSay() {
        let rig = makeRig(self, blocks: [X.message("A-MSG")] + F.run(2, prefix: "a") + [X.message("B-MSG")])
        XCTAssertTrue(rig.row.badgeField.isHidden, "nothing failed")
        XCTAssertTrue(rig.row.timeField.isHidden, "no call has a time: left out, never guessed")
    }

    // MARK: Accessibility

    func testTheRowIsAnAccessibleDisclosureTriangleWithTheFullSummaryAndTheState() {
        let rig = makeRig(self)
        let label = rig.row.accessibilityLabel() ?? ""

        XCTAssertEqual(rig.row.accessibilityRole(), .disclosureTriangle)
        XCTAssertTrue(rig.row.isAccessibilityElement())
        XCTAssertEqual(label, ActivitySummary.accessibilityLabel(for: X.segments(of: rig.turn)[0]))
        XCTAssertTrue(label.contains("2 earlier messages"), label)
        XCTAssertTrue(label.contains("1 failed call"), label)
        XCTAssertTrue(label.contains("4.1 s"), label)
        XCTAssertEqual(rig.row.accessibilityValue() as? String, "collapsed")

        rig.view.setExpanded(true)
        XCTAssertEqual(rig.row.accessibilityValue() as? String, "expanded")
    }

    func testAccessibilityPressTogglesTheRowAndTheLane() {
        let rig = makeRig(self)
        var toggles: [Bool] = []
        rig.view.onToggle = { toggles.append($0) }

        XCTAssertTrue(rig.row.accessibilityPerformPress())
        XCTAssertEqual(toggles, [true])
        XCTAssertTrue(rig.view.isExpanded)
        XCTAssertEqual(rig.row.accessibilityValue() as? String, "expanded")
        XCTAssertFalse(rig.view.laneMemberViews.isEmpty)

        XCTAssertTrue(rig.row.accessibilityPerformPress())
        XCTAssertEqual(toggles, [true, false])
        XCTAssertEqual(rig.row.accessibilityValue() as? String, "collapsed")
    }

    func testSettingTheStateProgrammaticallyIsNotTheOperatorsToggle() {
        let rig = makeRig(self)
        rig.view.onToggle = { _ in XCTFail("a programmatic change is not a click") }
        rig.view.setExpanded(true)
        rig.view.setExpanded(false)
        XCTAssertFalse(rig.view.isExpanded)
    }

    func testExpandedLaneMembersFollowTheRowInReadingOrder() throws {
        let rig = makeRig(self)
        rig.view.setExpanded(true)
        rig.relayout()

        let order = rig.view.subviews
        let rowIndex = try XCTUnwrap(order.firstIndex { $0 === rig.row })
        let memberIndices = try rig.view.laneMemberViews.map { member in try XCTUnwrap(order.firstIndex { $0 === member }) }
        XCTAssertEqual(rig.view.laneMemberViews.map(X.typeName), ["TextBlockView", "ToolGroupView", "TextBlockView", "ToolGroupView"])
        XCTAssertTrue(memberIndices.allSatisfy { $0 > rowIndex }, "members come after the row")
        XCTAssertEqual(memberIndices, memberIndices.sorted(), "and in the order they happened")
        XCTAssertTrue(X.contains("ALPHA-MSG", in: rig.view.laneMemberViews[0]))
        XCTAssertTrue(X.contains("BRAVO-MSG", in: rig.view.laneMemberViews[2]))
    }

    func testTheRowStaysBeforeTheLatestMessageInATurnWhateverItsState() throws {
        let view = X.view(F.turn(standardBlocks()), folds: FoldResolver(expandedByDefault: true))
        let order = X.columns(view)
        XCTAssertEqual(order.map(X.typeName), ["ActivityRowView", "TextBlockView", "ResultChipView"])
        let row = try XCTUnwrap(view.activityRowViews.first)
        row.row.toggle()   // close
        view.setIslandWidth(X.paneWidth)
        XCTAssertEqual(X.kinds(view), ["ActivityRowView", "TextBlockView", "ResultChipView"],
                       "re-measuring keeps the reading order")
    }

    // MARK: Keyboard

    private func press(_ code: UInt16, _ characters: String, on row: FoldRowView, in window: NSWindow,
                       flags: NSEvent.ModifierFlags = []) {
        row.keyDown(with: rowKeyEvent(code, characters, in: window, flags: flags))
    }

    func testTheRowIsAKeyboardControl() {
        let rig = makeRig(self)
        XCTAssertTrue(rig.row.acceptsFirstResponder)
        XCTAssertTrue(rig.row.canBecomeKeyView)
        XCTAssertTrue(rig.window.makeFirstResponder(rig.row))
        XCTAssertTrue(rig.window.firstResponder === rig.row)
    }

    func testSpaceAndReturnToggleTheFocusedRow() {
        let rig = makeRig(self)
        var toggles: [Bool] = []
        rig.view.onToggle = { toggles.append($0) }
        XCTAssertTrue(rig.window.makeFirstResponder(rig.row))

        press(RowKey.space, " ", on: rig.row, in: rig.window)
        XCTAssertTrue(rig.view.isExpanded)
        press(RowKey.space, " ", on: rig.row, in: rig.window)
        XCTAssertFalse(rig.view.isExpanded)
        press(RowKey.return, "\r", on: rig.row, in: rig.window)
        XCTAssertTrue(rig.view.isExpanded)
        press(RowKey.return, "\r", on: rig.row, in: rig.window)
        XCTAssertFalse(rig.view.isExpanded)
        XCTAssertEqual(toggles, [true, false, true, false])
    }

    func testRightArrowOpensAndLeftArrowCloses() {
        let rig = makeRig(self)
        var toggles: [Bool] = []
        rig.view.onToggle = { toggles.append($0) }
        XCTAssertTrue(rig.window.makeFirstResponder(rig.row))

        press(RowKey.right, rowArrow(NSRightArrowFunctionKey), on: rig.row, in: rig.window)
        press(RowKey.right, rowArrow(NSRightArrowFunctionKey), on: rig.row, in: rig.window)
        XCTAssertTrue(rig.view.isExpanded, "→ opens and never closes")
        press(RowKey.left, rowArrow(NSLeftArrowFunctionKey), on: rig.row, in: rig.window)
        press(RowKey.left, rowArrow(NSLeftArrowFunctionKey), on: rig.row, in: rig.window)
        XCTAssertFalse(rig.view.isExpanded, "← closes and never opens")
        XCTAssertEqual(toggles, [true, false], "only real changes are reported")
    }

    func testKeysWithCommandOptionOrControlBelongToSomeoneElse() {
        let rig = makeRig(self)
        for flags: NSEvent.ModifierFlags in [.command, .option, .control] {
            press(RowKey.right, rowArrow(NSRightArrowFunctionKey), on: rig.row, in: rig.window, flags: flags)
            press(RowKey.space, " ", on: rig.row, in: rig.window, flags: flags)
            press(RowKey.return, "\r", on: rig.row, in: rig.window, flags: flags)
            XCTAssertFalse(rig.view.isExpanded, "\(flags) toggled the row")
        }
    }

    func testAClickOnTheRowToggles() throws {
        let rig = makeRig(self)
        var toggles: [Bool] = []
        rig.view.onToggle = { toggles.append($0) }

        let summary = rig.row.summaryField.convert(rig.row.summaryField.bounds, to: nil)
        try AppControlMouse.click(in: rig.window, at: NSPoint(x: summary.minX + 8, y: summary.midY))
        XCTAssertEqual(toggles, [true], "a click on the summary text")
        XCTAssertTrue(rig.view.isExpanded)
    }

    func testARowAppearingInALiveTurnTakesNoFocusFromTheComposer() throws {
        let rig = makeTranscriptRig(self, blocks: [X.message("FIRST-MSG")] + F.run(2, prefix: "a"))
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        rig.content.addSubview(composer)
        XCTAssertTrue(rig.window.makeFirstResponder(composer))

        rig.turn.update(turn: F.turn([X.message("FIRST-MSG")] + F.run(2, prefix: "a") + [X.message("SECOND-MSG")]))
        rig.relayout(width: 900)
        rigSettle()

        XCTAssertFalse(rig.turn.activityRowViews.isEmpty, "precondition: the roll-in built a row")
        XCTAssertTrue(rig.window.firstResponder === composer, "a row appearing took focus: \(String(describing: rig.window.firstResponder))")
    }

    // MARK: Reduce Motion

    func testTheTriangleDoesNotAnimateUnderReduceMotion() {
        let rig = makeRig(self, reduceMotion: { true })
        rig.row.setExpanded(true, animated: true)
        XCTAssertTrue(rig.row.triangleLayer.animationKeys()?.isEmpty ?? true)
        rig.row.toggle()
        XCTAssertTrue(rig.row.triangleLayer.animationKeys()?.isEmpty ?? true,
                      "\(String(describing: rig.row.triangleLayer.animationKeys()))")
    }

    func testTheTriangleAnimatesWhenMotionIsAllowed() {
        let rig = makeRig(self, reduceMotion: { false })
        rig.row.toggle()
        XCTAssertFalse(rig.row.triangleLayer.animationKeys()?.isEmpty ?? true)
    }

    // MARK: Live

    func testWhileATurnRunsTheRowsCountsUpdateInPlaceAndItsHeightStaysTwentyTwo() throws {
        let width = ChatTurnView.blockWidth(paneWidth: rowPaneWidth)
        let stream = FocusStream([X.message("FIRST-MSG")] + F.run(2, prefix: "a") + [X.message("SECOND-MSG")])
        let row = try XCTUnwrap(stream.view.activityRowViews.first)
        XCTAssertEqual(row.row.summaryField.stringValue, "1 message, ran 2 commands")
        XCTAssertEqual(ChatTurnView.measureIsland(row, width: width), 22, accuracy: 0.5)

        stream.append(F.run(3, prefix: "b") + [X.message("THIRD-MSG")])

        XCTAssertTrue(stream.view.activityRowViews.first === row, "the row view is updated, not replaced")
        XCTAssertEqual(row.row.summaryField.stringValue, "2 messages, ran 5 commands")
        XCTAssertEqual(ChatTurnView.measureIsland(row, width: width), 22, accuracy: 0.5, "the row height never changes")
        XCTAssertEqual(row.row.frame.height, FoldRowView.height, accuracy: 0.5)
        XCTAssertEqual(row.row.accessibilityLabel(), ActivitySummary.accessibilityLabel(for: row.segment))
    }

    func testMembersAppendToAnOpenLaneInOrder() throws {
        let stream = FocusStream([X.message("FIRST-MSG")] + F.run(2, prefix: "a") + [X.message("SECOND-MSG")])
        let row = try XCTUnwrap(stream.view.activityRowViews.first)
        row.row.toggle()
        XCTAssertEqual(row.laneMemberViews.map(X.typeName), ["TextBlockView", "ToolGroupView"])
        let before = row.laneMemberViews

        stream.append(F.run(2, prefix: "b") + [X.message("THIRD-MSG")])

        XCTAssertTrue(row.isExpanded)
        XCTAssertEqual(row.laneMemberViews.map(X.typeName), ["TextBlockView", "ToolGroupView", "TextBlockView", "ToolGroupView"])
        XCTAssertTrue(zip(before, row.laneMemberViews).allSatisfy { $0 === $1 }, "existing members are kept")
        XCTAssertTrue(X.contains("SECOND-MSG", in: row.laneMemberViews[2]))
        XCTAssertTrue(row.laneGroupViews.allSatisfy { !$0.isExpanded }, "a group that joins the lane arrives collapsed")
    }

    func testAnOpenRowsHeightGrowsWithItsLaneAndCollapsingRestoresIt() throws {
        let rig = makeRig(self)
        let width = ChatTurnView.blockWidth(paneWidth: rowPaneWidth)
        let collapsed = ChatTurnView.measureIsland(rig.view, width: width)

        rig.view.setExpanded(true)
        let open = ChatTurnView.measureIsland(rig.view, width: width)
        XCTAssertGreaterThan(open, collapsed + 40, "two messages and a group row appeared")

        rig.view.setExpanded(false)
        XCTAssertEqual(ChatTurnView.measureIsland(rig.view, width: width), collapsed, accuracy: 0.5)
    }
}
