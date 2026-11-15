import XCTest
import AppKit
import NostromoKit

// The Overview from the keyboard: arrows move between rows and fold groups, Return on a row does nothing yet,
// ⌘O and ⌘R work only while the list has the keyboard, and ⌘0 puts the keyboard on the list.
//
// Real key events are sent to the outline (`keyDown`, `performKeyEquivalent`) with the list as first responder.
// If an arrow test ever fails with "nothing moved", suspect `interpretKeyEvents` not reaching `moveDown:` in a
// window that was never ordered front, and fall back to calling `moveDown(_:)` / `moveLeft(_:)` directly.
//
// Mutations (derived by reading the source, to be run by hand), and the test that fails for each:
//   M1 `keyDown` lets Return fall through to `super` and opens/refreshes -> testReturnOnARowSendsNothing
//   M2 `performKeyEquivalent` drops its first-responder guard (⌘O/⌘R fire anywhere in the window)
//        -> testCommandOAndCommandROnlyActWhileTheListHasTheKeyboard
//   M3 ⌘O also fires with Shift held -> testCommandOAndCommandROnlyActWhileTheListHasTheKeyboard
//   M4 `focusList()` does nothing / `applyRequestedOverview` does not call it
//        -> testCommandZeroLeavesTheKeyboardOnTheList
//   M5 the outline refuses first responder (`acceptsFirstResponder` false) -> every test here (precondition)
//   M6 a collapsed group re-expands on the next snapshot -> testACollapsedGroupStaysCollapsedWhenANewSnapshotArrives
final class AuthoredPrsKeyboardTests: XCTestCase {

    private var windows: [NSWindow] = []
    private let clock = APT.FakeClock()

    private let a = APT.pr(1, title: "A", group: .needsYou)
    private let b = APT.pr(2, title: "B", group: .needsYou)
    private let c = APT.pr(3, title: "C", group: .ready)

    override func setUp() {
        super.setUp()
        MotherView.requestedJobId = nil
        AppStore.shared.resetAuthoredPrsForTesting()
        AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        let name = "AuthoredPrsKeyboardTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let previous = MotherView.widthDefaults
        MotherView.widthDefaults = suite
        addTeardownBlock {
            MotherView.widthDefaults = previous
            suite.removePersistentDomain(forName: name)
        }
    }

    override func tearDown() {
        MotherView.requestedJobId = nil
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        AppStore.shared.resetAuthoredPrsForTesting()
        AppStore.shared.applyBrokerEventForTesting(.snapshot([]))
        super.tearDown()
    }

    /// An Overview in a window with the list focused, and counters on everything it could send.
    private struct Rig {
        let window: NSWindow
        let overview: AuthoredPrsOverviewView
        var outline: AuthoredPrsOutlineView { overview.outline }
    }

    private final class Counters {
        var refreshes = 0, storeRefreshes = 0, opened: [URL] = [], jobs: [String] = []
    }

    private func makeRig(_ prs: [AuthoredPr], refreshBlocked: AuthoredPrsRefreshBlocked? = nil,
                         focused: Bool = true) -> (rig: Rig, counters: Counters) {
        let counters = Counters()
        let window = APT.window(size: NSSize(width: 700, height: 500))
        let overview = AuthoredPrsOverviewView(clock: clock.read, timeZone: APT.utc, store: nil)
        window.contentView = overview
        windows.append(window)
        overview.refreshAction = { counters.refreshes += 1 }
        overview.opener = { counters.opened.append($0) }
        overview.onOpenJob = { counters.jobs.append($0) }
        AppStore.shared.authoredPrsRefreshSender = { counters.storeRefreshes += 1 }
        overview.layoutSubtreeIfNeeded()
        overview.apply(snapshot: APT.snapshot(prs, refreshBlocked: refreshBlocked), connection: .connected)
        overview.layoutSubtreeIfNeeded()
        if focused { overview.focusList() }
        return (Rig(window: window, overview: overview), counters)
    }

    private func press(_ keyCode: UInt16, on rig: Rig) {
        rig.outline.keyDown(with: APT.arrowKey(keyCode, window: rig.window))
    }

    // MARK: - Arrows

    func testDownAndUpMoveTheSelectionRowByRow() {
        let (rig, _) = makeRig([a, b, c])
        XCTAssertTrue(rig.window.firstResponder === rig.outline, "precondition: the list has the keyboard")
        XCTAssertEqual(rig.outline.numberOfRows, 5, "precondition: header, two rows, header, one row")
        rig.overview.selectRow(id: a.id)

        press(APT.keyDown, on: rig)
        XCTAssertEqual(rig.overview.selectedRowId, b.id, "↓ moves to the next row")

        press(APT.keyDown, on: rig)
        XCTAssertEqual(rig.outline.selectedRow, 3, "↓ passes onto the next group's header")
        XCTAssertNil(rig.overview.selectedRowId, "a header is not a PR row")

        press(APT.keyDown, on: rig)
        XCTAssertEqual(rig.overview.selectedRowId, c.id)

        press(APT.keyUp, on: rig)
        XCTAssertEqual(rig.outline.selectedRow, 3)
        press(APT.keyUp, on: rig)
        XCTAssertEqual(rig.overview.selectedRowId, b.id, "↑ goes back")
        press(APT.keyUp, on: rig)
        XCTAssertEqual(rig.overview.selectedRowId, a.id)
    }

    func testDownWithNothingSelectedStartsAtTheTop() {
        let (rig, _) = makeRig([a, b, c])
        rig.overview.clearSelection()
        press(APT.keyDown, on: rig)
        XCTAssertGreaterThanOrEqual(rig.outline.selectedRow, 0, "the arrow keys work from a cold start")
    }

    func testLeftCollapsesAndRightExpandsTheSelectedGroup() {
        let (rig, _) = makeRig([a, b, c])
        rig.outline.selectRowIndexes([0], byExtendingSelection: false)   // NEEDS YOU
        XCTAssertEqual(rig.outline.numberOfRows, 5, "precondition")

        press(APT.keyLeft, on: rig)
        XCTAssertEqual(rig.outline.numberOfRows, 3, "← folds NEEDS YOU's two rows away")
        XCTAssertTrue(rig.overview.isCollapsed(.needsYou))

        press(APT.keyRight, on: rig)
        XCTAssertEqual(rig.outline.numberOfRows, 5, "→ opens it again")
        XCTAssertFalse(rig.overview.isCollapsed(.needsYou))
    }

    func testACollapsedGroupStaysCollapsedWhenANewSnapshotArrives() {
        let (rig, _) = makeRig([a, b, c])
        rig.overview.collapse(.needsYou)
        XCTAssertEqual(rig.outline.numberOfRows, 3, "precondition")

        rig.overview.apply(snapshot: APT.snapshot([a, b, c, APT.pr(4, group: .ready)]), connection: .connected)

        XCTAssertEqual(rig.outline.numberOfRows, 4, "NEEDS YOU is still folded: its header, READY's header and two rows")
        XCTAssertTrue(rig.overview.isCollapsed(.needsYou))
    }

    // MARK: - Return

    func testReturnOnARowSendsNothing() {
        let (rig, counters) = makeRig([a, b, c])
        rig.overview.selectRow(id: b.id)
        let selected = rig.outline.selectedRow

        rig.outline.keyDown(with: APT.key(APT.keyReturn, "\r", window: rig.window))
        rig.outline.keyDown(with: APT.key(APT.keyEnter, "\u{3}", window: rig.window))

        XCTAssertEqual(counters.refreshes, 0)
        XCTAssertEqual(counters.storeRefreshes, 0, "nothing reaches the daemon")
        XCTAssertTrue(counters.opened.isEmpty, "no browser")
        XCTAssertTrue(counters.jobs.isEmpty)
        XCTAssertEqual(rig.outline.selectedRow, selected, "the selection did not move")
        XCTAssertEqual(rig.overview.selectedRowId, b.id)
    }

    // MARK: - Command-O and Command-R

    func testCommandOAndCommandROnlyActWhileTheListHasTheKeyboard() {
        let (rig, counters) = makeRig([a, b, c])
        rig.overview.selectRow(id: a.id)
        XCTAssertTrue(rig.window.firstResponder === rig.outline, "precondition")

        XCTAssertTrue(rig.outline.performKeyEquivalent(with: APT.command("o", window: rig.window)), "⌘O is ours with the list focused")
        XCTAssertEqual(counters.opened, [URL(string: "https://github.com/carefeed/portal/pull/1")!])
        XCTAssertTrue(rig.outline.performKeyEquivalent(with: APT.command("r", window: rig.window)), "⌘R is ours with the list focused")
        XCTAssertEqual(counters.refreshes, 1)

        XCTAssertFalse(rig.outline.performKeyEquivalent(with: APT.command("o", extra: .shift, window: rig.window)), "⇧⌘O is not ours")
        XCTAssertFalse(rig.outline.performKeyEquivalent(with: APT.command("r", extra: .option, window: rig.window)), "⌥⌘R is not ours")
        XCTAssertEqual(counters.opened.count, 1)
        XCTAssertEqual(counters.refreshes, 1)

        // The keyboard is somewhere else in the window: ⌘O and ⌘R mean what they always did.
        _ = rig.window.makeFirstResponder(nil)
        XCTAssertFalse(rig.window.firstResponder === rig.outline, "precondition: the list lost the keyboard")
        XCTAssertFalse(rig.outline.performKeyEquivalent(with: APT.command("o", window: rig.window)))
        XCTAssertFalse(rig.outline.performKeyEquivalent(with: APT.command("r", window: rig.window)))
        XCTAssertEqual(counters.opened.count, 1, "no second open")
        XCTAssertEqual(counters.refreshes, 1, "no second refresh")
    }

    func testCommandRWhileRefreshIsBlockedAsksForNothing() {
        let (rig, counters) = makeRig([a, b, c], refreshBlocked: .running)
        _ = rig.outline.performKeyEquivalent(with: APT.command("r", window: rig.window))
        XCTAssertEqual(counters.refreshes, 0)
        XCTAssertEqual(counters.storeRefreshes, 0)
    }

    func testCommandOWithNoRowSelectedOpensNothing() {
        let (rig, counters) = makeRig([a, b, c])
        rig.overview.clearSelection()
        _ = rig.outline.performKeyEquivalent(with: APT.command("o", window: rig.window))
        XCTAssertTrue(counters.opened.isEmpty)
    }

    // MARK: - Reachable without a mouse

    func testCommandZeroLeavesTheKeyboardOnTheList() {
        let window = APT.window(size: NSSize(width: 900, height: 600))
        let view = MotherView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = view
        windows.append(window)
        view.layoutSubtreeIfNeeded()
        AppStore.shared.daemonConnectedForTesting(authoredPrs: true)
        AppStore.shared.applyAuthoredPrsForTesting(APT.snapshot([a, b, c]))
        XCTAssertFalse(window.firstResponder === view.overviewView.outline, "precondition: the keyboard is not on the list")

        MotherView.requestShowOverview { }
        view.applyRequestedOverview(isKeyWindow: true)
        APT.flushMain()

        XCTAssertTrue(window.firstResponder === view.overviewView.outline, "⌘0 puts the keyboard on the list")
        // And from there the arrows work, with no mouse.
        view.overviewView.outline.keyDown(with: APT.arrowKey(APT.keyDown, window: window))
        XCTAssertGreaterThanOrEqual(view.overviewView.outline.selectedRow, 0, "↓ selects a row")
    }
}
