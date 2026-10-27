import XCTest
import AppKit

// The confirmation shown before a multi-line paste reaches a remote shell (`PasteConfirmSheet`).
//
// The sheet is the last thing between a clipboard and a production shell, so every way out that is
// not a person deliberately clicking Paste must end in "nothing pasted":
//
//   * Return is the default button and it is Cancel. A person who types or hits Return as the sheet
//     appears (or a key an agent sent) never pastes.
//   * Escape cancels.
//   * Paste has no key equivalent at all. Only a click that is a human gesture pastes: a click that is
//     not one (nothing current, a synthetic event, an app-control request running) is refused, reported,
//     and leaves the sheet up.
//
// `PasteConfirmSheet.swift` is compiled into the test target (it imports only AppKit); the driving is
// real: a real sheet window attached to a real (off-screen) parent window, real key events.

final class PasteConfirmSheetTests: XCTestCase {

    private final class Calls {
        var pasted = 0
        var refused = 0
    }

    private struct Rig {
        let parent: NSWindow
        let sheet: PasteConfirmSheet
        let sheetWindow: NSWindow
        let calls: Calls
        /// Fulfilled when the sheet has been dismissed.
        let ended: XCTestExpectation
    }

    // MARK: Harness

    private func makeParent() -> NSWindow {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        parent.orderFrontRegardless()
        addTeardownBlock { parent.close() }
        return parent
    }

    private func presentSheet(lines: Int = 3, preview: String = "a\nb\nc", target: String = "PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler") -> Rig {
        let parent = makeParent()
        let calls = Calls()
        let sheet = PasteConfirmSheet(lines: lines, preview: preview, targetText: target,
                                      onPaste: { calls.pasted += 1 }, onRefused: { calls.refused += 1 })
        let sheetWindow = sheet.window!
        let ended = expectation(description: "the sheet is dismissed")
        ended.assertForOverFulfill = false
        parent.beginSheet(sheetWindow) { _ in ended.fulfill() }
        XCTAssertTrue(parent.attachedSheet === sheetWindow, "the sheet is up")
        return Rig(parent: parent, sheet: sheet, sheetWindow: sheetWindow, calls: calls, ended: ended)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { sub -> [NSButton] in
            (sub as? NSButton).map { [$0] + buttons(in: sub) } ?? buttons(in: sub)
        }
    }

    private func views(in view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + views(in: $0) }
    }

    private func button(_ id: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> NSButton {
        try XCTUnwrap(buttons(in: rig.sheetWindow.contentView!).first { $0.accessibilityIdentifier() == id },
                      "no button \(id)", file: file, line: line)
    }

    private func field(_ id: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> NSTextField {
        try XCTUnwrap(views(in: rig.sheetWindow.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == id }, "no text field \(id)", file: file, line: line)
    }

    private func returnKey(in window: NSWindow, characters: String = "\r", keyCode: UInt16 = 36) -> NSEvent {
        GestureFixtures.key(in: window, characters: characters, keyCode: keyCode)
    }

    private func assertSheetDismissedWithoutPasting(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        wait(for: [rig.ended], timeout: 5)
        XCTAssertNil(rig.parent.attachedSheet, "the sheet is gone", file: file, line: line)
        XCTAssertEqual(rig.calls.pasted, 0, "nothing was pasted", file: file, line: line)
        XCTAssertEqual(rig.calls.refused, 0, "cancelling is not a refusal", file: file, line: line)
    }

    // MARK: What it shows

    func testTheTitleNamesTheLineCountAndTheTarget() throws {
        let rig = presentSheet(lines: 14, target: "PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler")
        XCTAssertEqual(try field("paste-confirm-title", in: rig).stringValue,
                       "Paste 14 lines into PRODUCTION \u{00B7} admin-portal \u{00B7} scheduler?")
    }

    func testTheTitleSaysOneLineForOneLine() throws {
        let rig = presentSheet(lines: 1, target: "REMOTE shell")
        XCTAssertEqual(try field("paste-confirm-title", in: rig).stringValue, "Paste 1 line into REMOTE shell?")
    }

    func testThePreviewOfWhatWillBePastedIsShown() throws {
        let rig = presentSheet(lines: 5, preview: "ls\ncd /\nrm -rf x\u{2026}")
        XCTAssertEqual(try field("paste-confirm-preview", in: rig).stringValue, "ls\ncd /\nrm -rf x\u{2026}")
    }

    // MARK: Return never pastes

    func testReturnCancelsAndNeverPastes() throws {
        let rig = presentSheet()
        let handled = rig.sheetWindow.performKeyEquivalent(with: returnKey(in: rig.sheetWindow))
        XCTAssertTrue(handled, "Return is handled by the sheet: it is the default (Cancel) button")
        assertSheetDismissedWithoutPasting(rig)
    }

    func testTheKeypadEnterKeyDoesNotPasteEither() throws {
        let rig = presentSheet()
        _ = rig.sheetWindow.performKeyEquivalent(with: returnKey(in: rig.sheetWindow, characters: "\u{3}", keyCode: 76))
        XCTAssertEqual(rig.calls.pasted, 0)
        XCTAssertEqual(rig.calls.refused, 0)
    }

    func testCancelIsTheOnlyButtonWithAReturnKeyEquivalent() throws {
        let rig = presentSheet()
        let cancel = try button("paste-confirm-cancel", in: rig)
        XCTAssertEqual(cancel.keyEquivalent, "\r", "Cancel is the default button")
        for other in buttons(in: rig.sheetWindow.contentView!) where other !== cancel {
            XCTAssertFalse(["\r", "\u{3}"].contains(other.keyEquivalent),
                           "\(other.accessibilityIdentifier()) answers Return")
        }
    }

    func testPasteHasNoKeyEquivalent() throws {
        let rig = presentSheet()
        XCTAssertEqual(try button("paste-confirm-paste", in: rig).keyEquivalent, "")
    }

    func testNoButtonOtherThanCancelAndTheHiddenEscapeHasAKeyEquivalent() throws {
        let rig = presentSheet()
        let cancel = try button("paste-confirm-cancel", in: rig)
        for other in buttons(in: rig.sheetWindow.contentView!) where other !== cancel {
            XCTAssertTrue(other.keyEquivalent.isEmpty || other.keyEquivalent == "\u{1b}",
                          "\(other.accessibilityIdentifier()) has key equivalent \(other.keyEquivalent.debugDescription)")
        }
    }

    // MARK: Escape cancels

    func testEscapeCancelsAndNeverPastes() throws {
        let rig = presentSheet()
        rig.sheetWindow.cancelOperation(nil)
        assertSheetDismissedWithoutPasting(rig)
    }

    func testTheCancelButtonCancelsAndNeverPastes() throws {
        let rig = presentSheet()
        try button("paste-confirm-cancel", in: rig).performClick(nil)
        assertSheetDismissedWithoutPasting(rig)
    }

    // MARK: Paste only for a human gesture

    func testAPasteClickThatIsNotAHumanGestureIsRefusedAndTheSheetStaysUp() throws {
        let rig = presentSheet()
        // No event of a person's click is current: `performClick` is what a synthetic or Accessibility
        // press looks like to the sheet.
        try button("paste-confirm-paste", in: rig).performClick(nil)
        XCTAssertEqual(rig.calls.pasted, 0, "nothing was pasted")
        XCTAssertEqual(rig.calls.refused, 1, "the refusal is reported")
        XCTAssertTrue(rig.parent.attachedSheet === rig.sheetWindow, "the sheet is still waiting for a person")
    }

    func testAPasteClickWhileAnAppControlRequestIsRunningIsRefused() throws {
        let rig = presentSheet()
        SyntheticInputGate.begin()
        addTeardownBlock { SyntheticInputGate.end() }
        try button("paste-confirm-paste", in: rig).performClick(nil)
        XCTAssertEqual(rig.calls.pasted, 0)
        XCTAssertEqual(rig.calls.refused, 1)
        XCTAssertTrue(rig.parent.attachedSheet === rig.sheetWindow)
    }

    func testARefusedPasteDoesNotStopCancelFromWorkingAfterwards() throws {
        let rig = presentSheet()
        try button("paste-confirm-paste", in: rig).performClick(nil)
        try button("paste-confirm-cancel", in: rig).performClick(nil)
        wait(for: [rig.ended], timeout: 5)
        XCTAssertEqual(rig.calls.pasted, 0)
        XCTAssertEqual(rig.calls.refused, 1)
        XCTAssertNil(rig.parent.attachedSheet)
    }
}
