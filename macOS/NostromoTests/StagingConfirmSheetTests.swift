import XCTest
import AppKit

// The confirmation a production-treated row asks when its text matches a destructive pattern
// (`StagingConfirmSheet`, opened by `StagingInsertController`).
//
// The sheet is the last thing between a staged `queue:flush` and a production shell, so:
//
//   * A click, Space or VoiceOver press on such a row opens it and sends NOTHING; a local row with a match,
//     and a production row without one, insert directly (Q5: confirm only on pattern matches).
//   * Cancel is the one default button (Return); Escape cancels; both send nothing and tell the daemon
//     `confirm_cancelled`. Insert has no key equivalent and is not the default.
//   * Only a person's Insert inserts, and then exactly the text the click began with, once, reported with
//     `confirmed: true`. A synthetic press is refused, reported, and leaves the sheet up.
//   * The sheet closes, sending nothing, when the terminal ends, the list goes, staging is turned off or the
//     window closes; a later insert works. One sheet per window. With no window, the insert is refused.
//
// Driven for real: a real sheet window attached to a real (off-screen) parent window, real mouse events.

final class StagingConfirmSheetTests: XCTestCase {

    private var rigs: [StagingRig] = []

    override func tearDown() {
        for rig in rigs { rig.tearDown() }
        rigs = []
        super.tearDown()
    }

    private struct Setup {
        let rig: StagingRig
        let window: NSWindow
        let row: StagingRowView
        let command: String
    }

    /// A production pane (ECS with a target, or `kind`) whose line is known empty, with `command` staged and readable.
    private func setup(command: String = "php artisan queue:flush", kind: TerminalKind? = .ecs, foreground: String? = nil,
                       gate: @escaping StagingInsertController.Gate = StagingGates.allowAll, enter: Bool = true) -> Setup {
        let rig = StagingRig(gate: gate, kind: kind, status: .running, isMirror: false)
        rigs.append(rig)
        if kind != .local { rig.context?.target = StagingFixtures.productionTarget }
        if enter { rig.typeEnter() }
        rig.ingest([StagingFixtures.entry("s-1", 1, command)], foreground: foreground)
        rig.settle()
        let window = rig.makeWindow()
        return Setup(rig: rig, window: window, row: rig.makeRow(in: window), command: command)
    }

    private func sheet(_ s: Setup, file: StaticString = #filePath, line: UInt = #line) throws -> StagingConfirmSheet {
        try XCTUnwrap(s.rig.controller.confirmSheet, "no sheet is up", file: file, line: line)
    }

    private func assertNothingTyped(_ s: Setup, before: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(s.rig.target.attempts.isEmpty, "nothing reached the terminal. \(message)", file: file, line: line)
        XCTAssertEqual(s.rig.inputFrames.count, before, "no input frame. \(message)", file: file, line: line)
        XCTAssertTrue(s.rig.insertedFrames.isEmpty, "nothing was reported inserted. \(message)", file: file, line: line)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub -> [NSButton] in (sub as? NSButton).map { [$0] + buttons(in: sub) } ?? buttons(in: sub) }
    }

    private func views(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + views(in: $0) }
    }

    private var cancelledEvent: TerminalClientMessage {
        .stagingUIEvent(terminalId: StagingFixtures.terminalId, event: "confirm_cancelled")
    }

    // MARK: What opens it

    func testAClickOnADestructiveProductionRowOpensTheSheetAndSendsNothing() throws {
        let s = setup()
        let before = s.rig.inputFrames.count
        s.rig.click(s.row, in: s.window)

        XCTAssertEqual(s.rig.rowResults, [.confirming])
        let sheet = try sheet(s)
        XCTAssertTrue(s.window.attachedSheet === sheet.window, "the sheet hangs on the driver window")
        assertNothingTyped(s, before: before)
    }

    func testSpaceOpensItToo() throws {
        let s = setup(gate: StagingGates.real())
        let before = s.rig.inputFrames.count
        XCTAssertEqual(s.row.activate(with: StagingEvents.space(in: s.window)), .confirming)
        _ = try sheet(s)
        assertNothingTyped(s, before: before)
    }

    func testAVoiceOverPressOpensItToo() throws {
        let s = setup(gate: StagingGates.real(voiceOver: true))
        let before = s.rig.inputFrames.count
        XCTAssertEqual(s.row.activate(with: nil), .confirming)
        _ = try sheet(s)
        assertNothingTyped(s, before: before)
    }

    func testALocalRowWithAMatchAndAProductionRowWithoutOneInsertDirectly() {
        let local = setup(kind: .local)
        local.rig.click(local.row, in: local.window)
        XCTAssertEqual(local.rig.rowResults, [.inserted(bytes: local.command.utf8.count)], "local rows never ask")
        XCTAssertNil(local.rig.controller.confirmSheet)

        let plain = setup(command: "ls -la")
        plain.rig.click(plain.row, in: plain.window)
        XCTAssertEqual(plain.rig.rowResults, [.inserted(bytes: 6)], "no match: one click inserts, even in production (Q5)")
        XCTAssertNil(plain.rig.controller.confirmSheet)
        XCTAssertEqual(plain.rig.insertedFrames, [.stagingInserted(terminalId: StagingFixtures.terminalId, entryId: "s-1", bytes: 6, confirmed: false)])
    }

    func testALocalPaneRunningAnotherProgramGetsTheSheetAndTheTitleSaysSo() throws {
        let s = setup(kind: .local, foreground: "ssh")
        s.rig.click(s.row, in: s.window)
        XCTAssertEqual(s.rig.rowResults, [.confirming])
        XCTAssertEqual(try sheet(s).titleText, "Insert into a shell running ssh?")
    }

    func testTheSheetShowsTheEnvironmentTheTargetTheFullCommandAndTheMatch() throws {
        let command = "rm -rf " + String(repeating: "a", count: 940)
        let s = setup(command: command)
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)

        XCTAssertEqual(sheet.titleText, "Insert into PRODUCTION?")
        XCTAssertTrue(sheet.shownLines.contains("admin-portal \u{00B7} scheduler \u{00B7} shell"), "\(sheet.shownLines)")
        XCTAssertTrue(sheet.shownLines.contains("Matches a destructive pattern: rm -rf"), "\(sheet.shownLines)")
        XCTAssertTrue(sheet.shownLines.contains(StagingConfirmSheet.fixedLine))
        XCTAssertEqual(StagingConfirmSheet.fixedLine,
                       "Insert places the text at the prompt. Nothing runs until you press Enter. No label does not mean safe.")
        XCTAssertEqual(sheet.commandText, command, "the whole 1,000-character command is in the block, untruncated")
        let text = views(in: sheet.window!.contentView!).compactMap { $0 as? NSTextView }.first
        XCTAssertEqual(text?.string, command)
        XCTAssertLessThanOrEqual(sheet.commandBlockHeight, StagingConfirmSheet.maxCommandHeight, "it scrolls inside a capped height")
    }

    func testAnUnknownKindOrNoTargetSaysRemote() throws {
        let s = setup(kind: .unknown)
        s.rig.context?.target = nil
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)
        XCTAssertEqual(sheet.titleText, "Insert into REMOTE?")
        XCTAssertTrue(sheet.shownLines.contains("REMOTE shell"), "\(sheet.shownLines)")
    }

    func testTheSheetAddsTheAppsHazardLabels() throws {
        let s = setup(command: "php artisan queue:flush <queue>")
        s.rig.click(s.row, in: s.window)
        XCTAssertTrue(try sheet(s).shownLines.contains(StagingDrawerModel.placeholderLabel))
    }

    // MARK: Return and Escape cancel; Insert has no key

    func testReturnClicksTheDefaultButtonWhichIsCancelAndSendsNothingButTheCancelEvent() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let before = s.rig.inputFrames.count
        let sheet = try sheet(s)
        let window = try XCTUnwrap(sheet.window)
        let defaultCell = try XCTUnwrap(window.defaultButtonCell, "the sheet has a default button")
        XCTAssertTrue(defaultCell === sheet.cancelButton.cell, "Return is Cancel")
        XCTAssertFalse(defaultCell === sheet.insertButton.cell)

        defaultCell.performClick(nil)
        XCTAssertNil(s.window.attachedSheet)
        XCTAssertNil(s.rig.controller.confirmSheet)
        assertNothingTyped(s, before: before)
        XCTAssertTrue(s.rig.stagingFrames.contains(cancelledEvent), "the daemon is told it was cancelled")
    }

    func testReturnAndEnterKeyEventsNeverInsert() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let before = s.rig.inputFrames.count
        let window = try XCTUnwrap(try sheet(s).window)
        _ = window.performKeyEquivalent(with: StagingEvents.key(36, "\r", in: window))
        assertNothingTyped(s, before: before)
    }

    func testEscapeCancelsAndSendsNothing() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let before = s.rig.inputFrames.count
        try XCTUnwrap(try sheet(s).window).cancelOperation(nil)
        XCTAssertNil(s.window.attachedSheet)
        assertNothingTyped(s, before: before)
        XCTAssertTrue(s.rig.stagingFrames.contains(cancelledEvent))
    }

    func testInsertHasNoKeyEquivalentAndIsNotTheDefaultAndOnlyCancelAndTheHiddenEscapeButtonHaveOne() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)
        XCTAssertEqual(sheet.insertButton.keyEquivalent, "")
        XCTAssertEqual(sheet.cancelButton.keyEquivalent, "\r")
        XCTAssertEqual(sheet.escapeButton.keyEquivalent, "\u{1b}")
        for button in buttons(in: sheet.window!.contentView!) where button !== sheet.cancelButton {
            XCTAssertTrue(button.keyEquivalent.isEmpty || button.keyEquivalent == "\u{1b}", button.keyEquivalent.debugDescription)
        }
        XCTAssertTrue(sheet.insertButton.canBecomeKeyView, "Tab reaches Insert")
    }

    // MARK: Insert: only a person's, only the snapshot, once

    func testASyntheticInsertPressIsRefusedReportedAndLeavesTheSheetUp() throws {
        let s = setup(gate: StagingGates.real())
        s.rig.click(s.row, in: s.window)
        let before = s.rig.inputFrames.count
        let sheet = try sheet(s)

        // `performClick` is what a synthetic or Accessibility press looks like: no person's event is current.
        sheet.insertButton.performClick(nil)

        assertNothingTyped(s, before: before)
        XCTAssertTrue(s.rig.refusals.contains(.stagingConfirm), "the refusal is reported: \(s.rig.refusals)")
        XCTAssertTrue(s.window.attachedSheet === sheet.window, "the sheet still waits for a person")
    }

    func testARealInsertPlacesTheSnapshotOnceReportedAsConfirmed() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)

        sheet.insertButton.performClick(nil)

        XCTAssertEqual(s.rig.target.sent, [Array(s.command.utf8)], "exactly the command's bytes, once, no line break")
        XCTAssertEqual(s.rig.insertedFrames,
                       [.stagingInserted(terminalId: StagingFixtures.terminalId, entryId: "s-1", bytes: s.command.utf8.count, confirmed: true)])
        XCTAssertNil(s.window.attachedSheet)
        XCTAssertNil(s.rig.controller.confirmSheet)
        XCTAssertEqual(s.rig.target.focusCount, 1)
    }

    func testTextReplacedWhileTheSheetIsUpDoesNotChangeWhatIsInserted() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)

        s.rig.ingest([StagingFixtures.entry("s-1", 1, "rm -rf /srv")])
        XCTAssertNotNil(s.rig.controller.confirmSheet, "a replace does not close it")
        XCTAssertEqual(sheet.commandText, s.command, "it still shows what the click began with")
        sheet.insertButton.performClick(nil)

        XCTAssertEqual(s.rig.target.sent, [Array(s.command.utf8)])
    }

    func testAnInsertWhoseEntryWasRemovedMeanwhileInsertsNothing() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)
        let before = s.rig.inputFrames.count

        s.rig.ingest([StagingFixtures.entry("s-2", 2, "ls")])
        sheet.insertButton.performClick(nil)

        assertNothingTyped(s, before: before)
    }

    func testTheInsertIsCheckedAgainWhenThePaneStopsBeingSafeToTypeInto() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)
        let before = s.rig.inputFrames.count

        s.rig.target.isAlternateScreen = true
        sheet.insertButton.performClick(nil)

        assertNothingTyped(s, before: before, "a full-screen program started while the sheet was up")
    }

    func testTextThatMayJoinWhatIsAlreadyOnTheLineIsNotInsertedAfterTheSheet() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let sheet = try sheet(s)
        s.rig.typeEnter(Array("ls".utf8))     // the person typed something while the sheet was up
        let before = s.rig.inputFrames.count

        sheet.insertButton.performClick(nil)

        XCTAssertTrue(s.rig.target.attempts.isEmpty)
        XCTAssertEqual(s.rig.inputFrames.count, before)
    }

    // MARK: It closes by itself, sending nothing

    private func assertClosedWithoutSending(_ s: Setup, before: Int, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(s.rig.controller.confirmSheet, why, file: file, line: line)
        XCTAssertNil(s.window.attachedSheet, why, file: file, line: line)
        assertNothingTyped(s, before: before, why, file: file, line: line)
    }

    func testTheSheetClosesWhenTheTerminalEnds() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let before = s.rig.inputFrames.count
        s.rig.sessions.ingest(.terminalState(StagingFixtures.terminalInfo(kind: .ecs, status: .ended)))
        assertClosedWithoutSending(s, before: before, "the shell ended")
    }

    func testTheSheetClosesWhenTheListIsRemoved() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let before = s.rig.inputFrames.count
        s.rig.ingest([], state: .none)
        assertClosedWithoutSending(s, before: before, "the list went")
    }

    func testTheSheetClosesWhenStagingIsTurnedOffForTheTerminalOrGlobally() throws {
        let perTerminal = setup()
        perTerminal.rig.click(perTerminal.row, in: perTerminal.window)
        let before = perTerminal.rig.inputFrames.count
        perTerminal.rig.ingest([], state: .none, enabled: false)
        assertClosedWithoutSending(perTerminal, before: before, "turned off for the terminal")

        let global = setup()
        global.rig.click(global.row, in: global.window)
        let beforeGlobal = global.rig.inputFrames.count
        global.rig.staging.setGlobalEnabled(false)
        assertClosedWithoutSending(global, before: beforeGlobal, "turned off globally")
    }

    func testTheSheetClosesWhenTheParentWindowClosesAndALaterInsertWorks() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        _ = try sheet(s)
        let before = s.rig.inputFrames.count

        s.window.close()
        XCTAssertNil(s.rig.controller.confirmSheet, "the sheet state was cleared with the window")
        assertNothingTyped(s, before: before)

        let window = s.rig.makeWindow()
        let row = s.rig.makeRow(in: window)
        s.rig.click(row, in: window)
        XCTAssertNotNil(s.rig.controller.confirmSheet, "a later activation asks again instead of finding a sheet 'on screen'")
        s.rig.controller.confirmSheet?.insertButton.performClick(nil)
        XCTAssertEqual(s.rig.target.sent.count, 1, "and a later insert works")
    }

    func testOnlyOneSheetPerWindowAndActivatingRowsWhileItIsUpDoesNothing() throws {
        let s = setup()
        s.rig.click(s.row, in: s.window)
        let first = try sheet(s)
        let before = s.rig.inputFrames.count

        XCTAssertEqual(s.row.activate(with: StagingEvents.space(in: s.window)), .confirming)
        XCTAssertTrue(s.rig.controller.confirmSheet === first, "no second sheet")
        assertNothingTyped(s, before: before)
    }

    // MARK: Fail toward asking

    func testWithNoWindowTheInsertIsRefusedAndNothingFallsThroughToAnUnconfirmedInsert() throws {
        let s = setup()
        let snapshot = try XCTUnwrap(s.rig.controller.snapshot(entryId: "s-1"))
        let before = s.rig.inputFrames.count

        XCTAssertEqual(s.rig.controller.insert(snapshot, event: nil, control: NSView()), .refused(.notSent))
        XCTAssertNil(s.rig.controller.confirmSheet)
        assertNothingTyped(s, before: before)
    }

    func testAPaneThatWasLocalAtTheMouseDownButIsProductionAtTheMouseUpAsks() throws {
        let s = setup(kind: .local)
        s.rig.mouseDown(s.row, in: s.window)
        s.rig.context?.kind = .ecs
        s.rig.context?.target = StagingFixtures.productionTarget
        s.rig.mouseUp(s.row, in: s.window)

        XCTAssertEqual(s.rig.rowResults, [.confirming])
        XCTAssertNotNil(s.rig.controller.confirmSheet)
        XCTAssertTrue(s.rig.target.attempts.isEmpty)
    }

    func testAPaneThatWasProductionAtTheMouseDownButIsLocalAtTheMouseUpStillAsks() throws {
        let s = setup()
        s.rig.mouseDown(s.row, in: s.window)
        s.rig.context?.kind = .local
        s.rig.mouseUp(s.row, in: s.window)

        XCTAssertEqual(s.rig.rowResults, [.confirming], "fail toward asking")
        XCTAssertTrue(s.rig.target.attempts.isEmpty)
    }
}
