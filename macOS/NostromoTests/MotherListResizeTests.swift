import XCTest
import AppKit

// MotherView, MotherListWidth and MotherListDivider are compiled into this target directly.
//
// MF5: the Mother list column is resizable.
//
//   - 280 pt by default, never under 220 pt, never so wide the detail drops under 320 pt.
//   - The width is remembered per window (keyed by the window's identifier) and restored, clamped to the
//     new bounds, by a new Mother view in a window with the same identifier.
//   - The drag handle is a 6 pt splitter that VoiceOver can step by 20 pt.
//
// The width store is a throwaway UserDefaults suite; `.standard` is never written.

final class MotherListResizeTests: XCTestCase {

    private var suiteName = ""
    private var suite: UserDefaults!
    private var previousDefaults: UserDefaults!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        suiteName = "MotherListResizeTests.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        previousDefaults = MotherView.widthDefaults
        MotherView.widthDefaults = suite
    }

    override func tearDown() {
        for w in windows { w.orderOut(nil); w.contentView = nil }
        windows = []
        MotherView.widthDefaults = previousDefaults
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeWindow(identifier: String?, storageKey: String? = nil, width: CGFloat = 800) -> (NSWindow, MotherView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        if let identifier { window.identifier = NSUserInterfaceItemIdentifier(identifier) }
        let frame = NSRect(x: 0, y: 0, width: width, height: 600)
        let view = storageKey == nil ? MotherView(frame: frame) : MotherView(frame: frame, storageKey: storageKey)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        windows.append(window)
        return (window, view)
    }

    private func resize(_ window: NSWindow, _ view: MotherView, to width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 600))
        view.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        view.layoutSubtreeIfNeeded()
    }

    private func tabRegion(in view: MotherView) -> NSView? {
        view.subviews.first { $0 is TabRegionView }
    }

    private func mouse(_ type: NSEvent.EventType, x: CGFloat, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    private func storedWidthKeys() -> [String] {
        suite.dictionaryRepresentation().keys.filter { $0.hasPrefix("MotherListWidth.") }
    }

    private func uniqueID() -> String { "mother-list-test-\(UUID().uuidString)" }

    // MARK: - The rules

    func testTheDefaultWidthIs280() {
        XCTAssertEqual(MotherListWidth.defaultWidth, 280)
    }

    func testTheWidthIsNeverUnder220() {
        XCTAssertEqual(MotherListWidth.clamp(0, viewWidth: 1000), 220)
        XCTAssertEqual(MotherListWidth.clamp(219, viewWidth: 1000), 220)
        XCTAssertEqual(MotherListWidth.clamp(220, viewWidth: 1000), 220)
        XCTAssertEqual(MotherListWidth.clamp(-50, viewWidth: 1000), 220)
    }

    func testTheWidthLeavesTheDetailAtLeast320() {
        XCTAssertEqual(MotherListWidth.clamp(5000, viewWidth: 1000), 680)
        XCTAssertEqual(MotherListWidth.clamp(680, viewWidth: 1000), 680)
        XCTAssertEqual(MotherListWidth.clamp(681, viewWidth: 1000), 680)
        XCTAssertEqual(MotherListWidth.clamp(300, viewWidth: 1000), 300)
    }

    func testTheMaximumNeverDropsBelowTheMinimumInANarrowView() {
        XCTAssertEqual(MotherListWidth.clamp(400, viewWidth: 400), 220)
        XCTAssertEqual(MotherListWidth.clamp(280, viewWidth: 100), 220)
        XCTAssertEqual(MotherListWidth.clamp(280, viewWidth: 0), 220)
    }

    // MARK: - The view

    func testANewMotherViewShowsTheDefaultWidth() {
        let (_, view) = makeWindow(identifier: uniqueID())
        XCTAssertEqual(view.listColumnWidth, 280)
    }

    func testSettingTheListWidthClampsToTheRules() {
        let (_, view) = makeWindow(identifier: uniqueID(), width: 800)
        view.setListWidth(350)
        XCTAssertEqual(view.listColumnWidth, 350)
        view.setListWidth(100)
        XCTAssertEqual(view.listColumnWidth, 220)
        view.setListWidth(10_000)
        XCTAssertEqual(view.listColumnWidth, 480, "800 wide leaves 320 for the detail")
    }

    func testTheListColumnReallyHasThatWidthAfterLayout() {
        let (_, view) = makeWindow(identifier: uniqueID(), width: 800)
        view.setListWidth(350)
        view.layoutSubtreeIfNeeded()
        let detail = tabRegion(in: view)
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.frame.minX ?? 0, 351, accuracy: 1.5, "list 350 + 1 pt divider")
    }

    func testTheDetailKeepsAtLeast320WhenTheWindowShrinks() throws {
        let (window, view) = makeWindow(identifier: uniqueID(), width: 900)
        view.setListWidth(560)
        view.layoutSubtreeIfNeeded()

        resize(window, view, to: 600)
        XCTAssertEqual(view.listColumnWidth, 280, "the column gives way so the detail keeps 320")
        let detail = try XCTUnwrap(tabRegion(in: view))
        // The maximum is view width − 320 (Q2), so the 1 pt divider comes out of the detail's 320.
        XCTAssertGreaterThanOrEqual(detail.frame.width, 320 - 1.5)
    }

    func testAWiderWindowGivesBackWhatTheReaderAskedFor() {
        let (window, view) = makeWindow(identifier: uniqueID(), width: 900)
        view.setListWidth(560)
        resize(window, view, to: 600)
        XCTAssertEqual(view.listColumnWidth, 280)
        resize(window, view, to: 900)
        XCTAssertEqual(view.listColumnWidth, 560, "shrinking the window is not a request for a narrower list")
    }

    // MARK: - Remembering

    func testRememberingStoresTheWidthUnderTheWindowsIdentifier() {
        let id = uniqueID()
        let (_, view) = makeWindow(identifier: id)
        view.setListWidth(350)
        view.rememberListWidth()
        XCTAssertEqual(suite.object(forKey: "MotherListWidth.\(id)") as? Double, 350)
    }

    func testResizingWithoutRememberingStoresNothing() {
        let id = uniqueID()
        let (_, view) = makeWindow(identifier: id)
        view.setListWidth(350)   // what every drag event does
        XCTAssertNil(suite.object(forKey: "MotherListWidth.\(id)"), "only the end of a drag remembers")
    }

    func testANewViewInAWindowWithTheSameIdentifierRestoresTheWidth() {
        let id = uniqueID()
        let (_, first) = makeWindow(identifier: id, width: 1000)
        first.setListWidth(350)
        first.rememberListWidth()

        let (_, second) = makeWindow(identifier: id, width: 1000)
        XCTAssertEqual(second.listColumnWidth, 350)
    }

    func testTheRestoredWidthIsClampedToTheNewBounds() {
        let id = uniqueID()
        let (_, first) = makeWindow(identifier: id, width: 1000)
        first.setListWidth(600)
        first.rememberListWidth()

        let (_, narrower) = makeWindow(identifier: id, width: 700)
        XCTAssertEqual(narrower.listColumnWidth, 380, "700 leaves 320 for the detail")
    }

    func testAWindowWithADifferentIdentifierGetsTheDefault() {
        let (_, first) = makeWindow(identifier: uniqueID())
        first.setListWidth(350)
        first.rememberListWidth()

        let (_, other) = makeWindow(identifier: uniqueID())
        XCTAssertEqual(other.listColumnWidth, 280)
    }

    func testAWindowWithNoIdentifierRemembersNothing() {
        let (_, view) = makeWindow(identifier: nil)
        view.setListWidth(350)
        view.rememberListWidth()
        let keys = suite.dictionaryRepresentation().keys.filter { $0.hasPrefix("MotherListWidth.") }
        XCTAssertTrue(keys.isEmpty)
    }

    func testAStoredNonsenseWidthIsIgnored() {
        let id = uniqueID()
        suite.set("wide", forKey: "MotherListWidth.\(id)")
        let (_, view) = makeWindow(identifier: id)
        XCTAssertEqual(view.listColumnWidth, 280)
    }

    func testTheStorageKeyIsPrefixedWithTheWindowKey() {
        XCTAssertEqual(MotherListWidth.defaultsKey(windowKey: "abc"), "MotherListWidth.abc")
    }

    // MARK: - The divider

    func testTheDividerIsASplitterWhoseValueIsTheListWidth() {
        let (_, view) = makeWindow(identifier: uniqueID())
        let divider = view.listDivider
        XCTAssertEqual(divider.accessibilityRole(), .splitter)
        XCTAssertTrue(divider.isAccessibilityElement())
        XCTAssertEqual((divider.accessibilityValue() as? NSNumber)?.doubleValue, 280)
        view.setListWidth(333)
        XCTAssertEqual((divider.accessibilityValue() as? NSNumber)?.doubleValue, 333)
    }

    func testTheDividerHasALabel() {
        let (_, view) = makeWindow(identifier: uniqueID())
        XCTAssertFalse((view.listDivider.accessibilityLabel() ?? "").isEmpty)
    }

    func testIncrementAndDecrementMoveTheListBy20() {
        let (_, view) = makeWindow(identifier: uniqueID(), width: 1000)
        let divider = view.listDivider
        XCTAssertTrue(divider.accessibilityPerformIncrement())
        XCTAssertEqual(view.listColumnWidth, 300)
        XCTAssertTrue(divider.accessibilityPerformDecrement())
        XCTAssertTrue(divider.accessibilityPerformDecrement())
        XCTAssertEqual(view.listColumnWidth, 260)
        XCTAssertEqual((divider.accessibilityValue() as? NSNumber)?.doubleValue, 260)
    }

    func testStepsStopAtTheMinimumAndTheMaximum() {
        let (_, view) = makeWindow(identifier: uniqueID(), width: 800)
        let divider = view.listDivider
        view.setListWidth(230)
        _ = divider.accessibilityPerformDecrement()
        XCTAssertEqual(view.listColumnWidth, 220)
        _ = divider.accessibilityPerformDecrement()
        XCTAssertEqual(view.listColumnWidth, 220)

        view.setListWidth(470)
        _ = divider.accessibilityPerformIncrement()
        XCTAssertEqual(view.listColumnWidth, 480)
        _ = divider.accessibilityPerformIncrement()
        XCTAssertEqual(view.listColumnWidth, 480)
    }

    func testAnAccessibilityStepIsRemembered() {
        let id = uniqueID()
        let (_, view) = makeWindow(identifier: id, width: 1000)
        _ = view.listDivider.accessibilityPerformIncrement()
        XCTAssertEqual(suite.object(forKey: "MotherListWidth.\(id)") as? Double, 300)
    }

    func testTheDividersGrabAreaIs6PointsWide() {
        XCTAssertEqual(MotherListDivider.hitWidth, 6)
        let (_, view) = makeWindow(identifier: uniqueID())
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.listDivider.frame.width, 6, accuracy: 0.5)
    }

    // MARK: - Storage key (the app's windows have neither an autosave name nor an identifier)

    func testAViewWithAStorageKeyRemembersTheWidthInAWindowWithNoIdentifier() {
        let key = uniqueID()
        let (window, view) = makeWindow(identifier: nil, storageKey: key)
        XCTAssertNil(window.identifier)
        view.setListWidth(350)
        view.rememberListWidth()
        XCTAssertEqual(suite.object(forKey: "MotherListWidth.\(key)") as? Double, 350)
    }

    func testANewViewWithTheSameStorageKeyRestoresTheWidthInAnotherUnnamedWindow() {
        let key = uniqueID()
        let (_, first) = makeWindow(identifier: nil, storageKey: key, width: 1000)
        first.setListWidth(350)
        first.rememberListWidth()

        let (second, view) = makeWindow(identifier: nil, storageKey: key, width: 1000)
        XCTAssertNil(second.identifier)
        XCTAssertEqual(view.listColumnWidth, 350)
    }

    func testADifferentStorageKeyGetsTheDefaultWidth() {
        let (_, first) = makeWindow(identifier: nil, storageKey: uniqueID())
        first.setListWidth(350)
        first.rememberListWidth()
        let (_, other) = makeWindow(identifier: nil, storageKey: uniqueID())
        XCTAssertEqual(other.listColumnWidth, 280)
    }

    func testAViewWithNoStorageKeyInAnUnnamedWindowStoresNothing() {
        let (_, view) = makeWindow(identifier: nil, storageKey: nil)
        view.setListWidth(350)
        view.rememberListWidth()
        XCTAssertTrue(storedWidthKeys().isEmpty)
    }

    // MARK: - The divider reads the width that is shown, not the one asked for

    func testWhenTheWindowIsTooNarrowTheDividerReportsTheShownWidth() {
        let (window, view) = makeWindow(identifier: uniqueID(), width: 900)
        view.setListWidth(560)
        resize(window, view, to: 600)
        XCTAssertEqual(view.listColumnWidth, 280)
        XCTAssertEqual(view.listDivider.currentWidth(), 280)
        XCTAssertEqual((view.listDivider.accessibilityValue() as? NSNumber)?.doubleValue, 280)
    }

    func testAnAccessibilityStepFromANarrowedColumnMovesFromTheShownWidth() {
        let (window, view) = makeWindow(identifier: uniqueID(), width: 900)
        view.setListWidth(560)
        resize(window, view, to: 600)
        // 280 is the widest a 600 pt view allows, so only a decrement tells the shown width from the asked one.
        XCTAssertTrue(view.listDivider.accessibilityPerformDecrement())
        XCTAssertEqual(view.listColumnWidth, 260, "20 less than the 280 shown, not 20 less than the 560 asked for")
    }

    func testADragFromANarrowedColumnMovesFromTheShownWidth() {
        let (window, view) = makeWindow(identifier: uniqueID(), width: 900)
        view.setListWidth(560)
        resize(window, view, to: 600)
        let divider = view.listDivider
        divider.mouseDown(with: mouse(.leftMouseDown, x: 100, in: window))
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 70, in: window))
        XCTAssertEqual(view.listColumnWidth, 250, "280 shown - a 30 pt drag")
    }

    // MARK: - A click is not a choice of width

    func testAClickOnTheDividerWithoutADragDoesNotCommitOrStore() {
        let key = uniqueID()
        let (window, view) = makeWindow(identifier: nil, storageKey: key)
        let divider = view.listDivider
        var commits = 0
        let original = divider.onCommit
        divider.onCommit = { commits += 1; original?() }

        divider.mouseDown(with: mouse(.leftMouseDown, x: 100, in: window))
        divider.mouseUp(with: mouse(.leftMouseUp, x: 100, in: window))

        XCTAssertEqual(commits, 0)
        XCTAssertNil(suite.object(forKey: "MotherListWidth.\(key)"))
    }

    func testADragThatChangesTheWidthCommitsAndStoresIt() {
        let key = uniqueID()
        let (window, view) = makeWindow(identifier: nil, storageKey: key)
        let divider = view.listDivider
        var commits = 0
        let original = divider.onCommit
        divider.onCommit = { commits += 1; original?() }

        divider.mouseDown(with: mouse(.leftMouseDown, x: 100, in: window))
        divider.mouseDragged(with: mouse(.leftMouseDragged, x: 130, in: window))
        divider.mouseUp(with: mouse(.leftMouseUp, x: 130, in: window))

        XCTAssertEqual(commits, 1)
        XCTAssertEqual(suite.object(forKey: "MotherListWidth.\(key)") as? Double, 310)
    }
}
