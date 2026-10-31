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

    private func makeWindow(identifier: String?, width: CGFloat = 800) -> (NSWindow, MotherView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        if let identifier { window.identifier = NSUserInterfaceItemIdentifier(identifier) }
        let view = MotherView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
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
}
