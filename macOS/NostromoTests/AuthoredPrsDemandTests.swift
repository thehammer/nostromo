import XCTest
import AppKit
import NostromoKit

// Whether anyone is looking at the PR list, as the app tells the daemon: `visible`, `hidden` or `idle`. The
// reporter is built with plain `NotificationCenter` instances so no real system notification is involved,
// and a recorded `send`. Nothing here talks to a daemon.
//
// Mutations (derived by reading the source, to be run by hand), and the test that fails for each:
//   M1 idle threshold 900 -> 899 or 901 -> testIdleBeginsAtFifteenMinutesExactly
//   M2 lock/unlock notifications not observed (or not on the injected distributed center)
//        -> testLockingTheScreenIsIdleAndUnlockingReturnsToTheRightLevel
//   M3 sleep/wake notifications not observed -> testSleepIsIdleAndWakingReturnsToTheRightLevel
//   M4 `evaluate()` sends every time instead of on change -> testOnlyChangesAreSent
//   M5 `connectionStarted()` does not forget the last level -> testAConnectionStartingResendsTheCurrentLevel,
//        testALostConnectionIsForgottenAndTheNextOneIsTold
//   M6 the `supported` guard removed -> testADaemonWithoutTheFeatureIsToldNothingAtAll
//   M7 `isOnScreen` ignores a hidden view, a hidden app or an invisible window
//        -> testAnOverviewIsOnScreenOnlyWhenItsViewItsAppAndItsWindowAreAllVisible
//   M8 `viewDidMoveToWindow` does not tell the reporter (or `overviewRemoved` is not sent)
//        -> testAnOverviewJoiningAWindowReportsVisibleAndLeavingItReportsHidden
final class AuthoredPrsDemandTests: XCTestCase {

    private var windows: [NSWindow] = []
    private var reporters: [AuthoredPrsDemandReporter] = []
    private var overviews: [AuthoredPrsOverviewView] = []

    override func tearDown() {
        for overview in overviews { overview.demand = nil }
        overviews = []
        for reporter in reporters { reporter.stop() }
        reporters = []
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    /// A reporter wired to three private notification centers and recording what it sends.
    private final class Rig {
        var sent: [String] = []
        var idle: TimeInterval = 0
        var overviewVisible = false
        var supported = true
        let distributed = NotificationCenter()
        let workspace = NotificationCenter()
        let app = NotificationCenter()
        private(set) var reporter: AuthoredPrsDemandReporter!

        init(visibleCheck: (() -> Bool)? = nil) {
            reporter = AuthoredPrsDemandReporter(
                supported: { [unowned self] in self.supported },
                send: { [unowned self] level in self.sent.append(level) },
                idleSeconds: { [unowned self] in self.idle },
                isOverviewVisible: visibleCheck ?? { [unowned self] in self.overviewVisible },
                distributedCenter: distributed, workspaceCenter: workspace, appCenter: app)
        }
    }

    private func makeRig(visible: Bool = false, started: Bool = true) -> Rig {
        let rig = Rig()
        rig.overviewVisible = visible
        reporters.append(rig.reporter)
        if started { rig.reporter.start() }
        return rig
    }

    private func post(_ name: String, on center: NotificationCenter) {
        center.post(name: Notification.Name(name), object: nil)
        APT.flushMain()
    }

    // MARK: - Levels

    func testAVisibleOverviewIsReportedVisible() {
        let rig = makeRig(visible: true)
        XCTAssertEqual(rig.sent, ["visible"])
    }

    func testAnOverviewNobodyIsLookingAtIsReportedHidden() {
        let rig = makeRig(visible: false)
        XCTAssertEqual(rig.sent, ["hidden"])
    }

    func testSwitchingToAJobAnotherFocusOrHidingTheAppReportsHidden() {
        let rig = makeRig(visible: true)
        XCTAssertEqual(rig.sent, ["visible"], "precondition")

        // A job is selected, or another focus is shown: the Overview is no longer on screen.
        rig.overviewVisible = false
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["visible", "hidden"])

        // It comes back, and then the whole app is hidden: the app's notification makes the reporter look again.
        rig.overviewVisible = true
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["visible", "hidden", "visible"])
        rig.overviewVisible = false
        rig.app.post(name: NSApplication.didHideNotification, object: nil)
        APT.flushMain()
        XCTAssertEqual(rig.sent, ["visible", "hidden", "visible", "hidden"])
    }

    func testAppAndWindowNotificationsMakeTheReporterLookAgain() {
        let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification, NSWindow.didChangeScreenNotification]
        for name in names {
            let rig = makeRig(visible: false)
            rig.overviewVisible = true
            rig.app.post(name: name, object: nil)
            APT.flushMain()
            XCTAssertEqual(rig.sent, ["hidden", "visible"], "\(name.rawValue) triggers a re-evaluation")
        }
    }

    // MARK: - Idle

    func testIdleBeginsAtFifteenMinutesExactly() {
        let rig = makeRig(visible: true)
        rig.idle = 899
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["visible"], "899 s of no input is not idle")

        rig.idle = 900
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["visible", "idle"], "900 s is")

        rig.idle = 3
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["visible", "idle", "visible"], "any input and it is back")
    }

    func testIdleOutranksVisibleAndHidden() {
        let rig = makeRig(visible: false)
        rig.idle = 5000
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["hidden", "idle"])
        rig.overviewVisible = true
        rig.reporter.evaluate()
        XCTAssertEqual(rig.sent, ["hidden", "idle"], "visible but away is still idle: nothing new to say")
    }

    func testLockingTheScreenIsIdleAndUnlockingReturnsToTheRightLevel() {
        let rig = makeRig(visible: true)
        post("com.apple.screenIsLocked", on: rig.distributed)
        XCTAssertEqual(rig.sent, ["visible", "idle"])

        post("com.apple.screenIsUnlocked", on: rig.distributed)
        XCTAssertEqual(rig.sent, ["visible", "idle", "visible"], "unlocked with the Overview showing: visible")

        let hidden = makeRig(visible: false)
        post("com.apple.screenIsLocked", on: hidden.distributed)
        post("com.apple.screenIsUnlocked", on: hidden.distributed)
        XCTAssertEqual(hidden.sent, ["hidden", "idle", "hidden"], "unlocked with something else showing: hidden")
    }

    func testSleepIsIdleAndWakingReturnsToTheRightLevel() {
        let rig = makeRig(visible: true)
        rig.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        APT.flushMain()
        XCTAssertEqual(rig.sent, ["visible", "idle"])

        rig.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        APT.flushMain()
        XCTAssertEqual(rig.sent, ["visible", "idle", "visible"])
    }

    func testNotificationsOnTheWrongCenterAreIgnored() {
        let rig = makeRig(visible: true)
        // The lock arrives on the distributed center, sleep on the workspace's: not the other way round.
        rig.workspace.post(name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        rig.distributed.post(name: NSWorkspace.willSleepNotification, object: nil)
        APT.flushMain()
        XCTAssertEqual(rig.sent, ["visible"])
    }

    // MARK: - Only changes are sent

    func testOnlyChangesAreSent() {
        let rig = makeRig(visible: true)
        for _ in 0..<5 { rig.reporter.evaluate() }
        XCTAssertEqual(rig.sent, ["visible"], "the same level five times is one message")
    }

    func testAStoppedReporterListensToNothing() {
        let rig = makeRig(visible: true)
        rig.reporter.stop()
        rig.overviewVisible = false
        rig.app.post(name: NSApplication.didHideNotification, object: nil)
        post("com.apple.screenIsLocked", on: rig.distributed)
        XCTAssertEqual(rig.sent, ["visible"])
    }

    // MARK: - Connections

    func testAConnectionStartingResendsTheCurrentLevel() {
        let rig = makeRig(visible: true)
        XCTAssertEqual(rig.sent, ["visible"], "precondition")

        rig.reporter.connectionStarted()

        XCTAssertEqual(rig.sent, ["visible", "visible"], "a new daemon connection knows nothing of the last level")
    }

    func testALostConnectionIsForgottenAndTheNextOneIsTold() {
        let rig = makeRig(visible: true)
        XCTAssertEqual(rig.reporter.lastSent, .visible, "precondition")

        rig.reporter.connectionLost()
        XCTAssertNil(rig.reporter.lastSent, "what was sent went with the connection")
        XCTAssertEqual(rig.sent, ["visible"], "losing the connection sends nothing")

        rig.reporter.connectionStarted()
        XCTAssertEqual(rig.sent, ["visible", "visible"])
        XCTAssertEqual(rig.reporter.lastSent, .visible)
    }

    func testTheLevelAtReconnectIsTheLevelNowNotTheOldOne() {
        let rig = makeRig(visible: true)
        rig.reporter.connectionLost()
        rig.overviewVisible = false

        rig.reporter.connectionStarted()

        XCTAssertEqual(rig.sent, ["visible", "hidden"])
    }

    func testADaemonWithoutTheFeatureIsToldNothingAtAll() {
        let rig = makeRig(visible: true, started: false)
        rig.supported = false
        rig.reporter.start()
        rig.overviewVisible = false
        rig.reporter.evaluate()
        rig.idle = 5000
        rig.reporter.evaluate()
        post("com.apple.screenIsLocked", on: rig.distributed)
        rig.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        rig.app.post(name: NSApplication.didHideNotification, object: nil)
        APT.flushMain()
        rig.reporter.connectionStarted()
        rig.reporter.connectionLost()
        rig.reporter.connectionStarted()

        XCTAssertTrue(rig.sent.isEmpty, "an old daemon cannot decode the message: nothing is sent: \(rig.sent)")
    }

    func testADaemonThatLaterAdvertisesTheFeatureIsToldTheCurrentLevelOnItsWelcome() {
        let rig = makeRig(visible: true, started: false)
        rig.supported = false
        rig.reporter.start()
        XCTAssertTrue(rig.sent.isEmpty, "precondition")

        rig.supported = true
        rig.reporter.connectionStarted()

        XCTAssertEqual(rig.sent, ["visible"])
    }

    // MARK: - What counts as on screen

    func testAnOverviewIsOnScreenOnlyWhenItsViewItsAppAndItsWindowAreAllVisible() {
        let window = APT.window(size: NSSize(width: 400, height: 300))
        windows.append(window)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        container.addSubview(view)
        window.contentView = container

        XCTAssertTrue(AuthoredPrsDemandReporter.isOnScreen([view], appIsHidden: false) { _ in true }, "control: all visible")
        XCTAssertFalse(AuthoredPrsDemandReporter.isOnScreen([view], appIsHidden: true) { _ in true }, "a hidden app")
        XCTAssertFalse(AuthoredPrsDemandReporter.isOnScreen([view], appIsHidden: false) { _ in false }, "a window that is not visible")

        view.isHidden = true
        XCTAssertFalse(AuthoredPrsDemandReporter.isOnScreen([view], appIsHidden: false) { _ in true }, "a hidden view")
        view.isHidden = false
        container.isHidden = true
        XCTAssertFalse(AuthoredPrsDemandReporter.isOnScreen([view], appIsHidden: false) { _ in true }, "a view under a hidden ancestor")
        container.isHidden = false

        let loose = NSView()
        XCTAssertFalse(AuthoredPrsDemandReporter.isOnScreen([loose], appIsHidden: false) { _ in true }, "a view in no window")
        XCTAssertFalse(AuthoredPrsDemandReporter.isOnScreen([], appIsHidden: false) { _ in true }, "no views at all")
        XCTAssertTrue(AuthoredPrsDemandReporter.isOnScreen([loose, view], appIsHidden: false) { _ in true }, "any one on screen is enough")
    }

    // MARK: - The Overview registers with the reporter

    private func overviewRig() -> (rig: Rig, overview: AuthoredPrsOverviewView, window: NSWindow) {
        let overview = AuthoredPrsOverviewView(clock: APT.FakeClock().read, timeZone: APT.utc, store: nil)
        // Visible exactly when the Overview is in a window and not hidden: the view's own lifecycle drives it.
        let rig = Rig(visibleCheck: { [unowned overview] in
            AuthoredPrsDemandReporter.isOnScreen([overview], appIsHidden: false) { _ in true }
        })
        reporters.append(rig.reporter)
        overviews.append(overview)
        overview.demand = rig.reporter
        let window = APT.window(size: NSSize(width: 600, height: 400))
        windows.append(window)
        return (rig, overview, window)
    }

    func testAnOverviewJoiningAWindowReportsVisibleAndLeavingItReportsHidden() {
        let (rig, overview, window) = overviewRig()
        rig.reporter.start()
        XCTAssertEqual(rig.sent, ["hidden"], "an Overview in no window is not visible")

        window.contentView = overview
        XCTAssertEqual(rig.sent, ["hidden", "visible"], "joining a window reports visible")

        window.contentView = nil
        XCTAssertNil(overview.window)
        XCTAssertEqual(rig.sent, ["hidden", "visible", "hidden"], "leaving it reports hidden")
    }

    func testHidingAndUnhidingTheOverviewReportsTheChange() {
        let (rig, overview, window) = overviewRig()
        window.contentView = overview
        rig.reporter.start()
        XCTAssertEqual(rig.sent, ["visible"])

        overview.isHidden = true   // a job's detail covers it
        XCTAssertEqual(rig.sent, ["visible", "hidden"])

        overview.isHidden = false
        XCTAssertEqual(rig.sent, ["visible", "hidden", "visible"])
    }

    func testTheReportersOwnViewRegistryKeepsAnOverviewInAnInvisibleWindowHidden() {
        // The default visibility check (no injection): a window that is not on screen is not visible.
        let center = NotificationCenter()
        var sent: [String] = []
        let reporter = AuthoredPrsDemandReporter(supported: { true }, send: { sent.append($0) }, idleSeconds: { 0 },
                                                 distributedCenter: center, workspaceCenter: center, appCenter: center)
        reporters.append(reporter)
        let overview = AuthoredPrsOverviewView(clock: APT.FakeClock().read, timeZone: APT.utc, store: nil)
        overviews.append(overview)
        overview.demand = reporter
        let window = APT.window(size: NSSize(width: 600, height: 400))   // never ordered front
        windows.append(window)
        reporter.start()

        window.contentView = overview

        XCTAssertEqual(reporter.level, .hidden, "joined a window nobody can see")
        XCTAssertEqual(sent, ["hidden"], "reported once, as hidden")
    }
}
