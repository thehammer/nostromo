import XCTest
import AppKit

// `IdleBannerView`: the yellow strip under a remote pane's header that counts down to the idle close.
//
//   * It shows only for a running shell whose daemon sent `idle_closes_at`, and only while the view is in
//     a window; otherwise it is hidden and has no timer.
//   * The text uses the daemon's own figure (`idle_warn_after_secs`), not a constant.
//   * Its one-second timer runs in the common run-loop modes (a default-mode timer freezes while a menu is
//     open or a divider is dragged), and is invalidated and nil'd when the banner hides or leaves its window.

final class IdleBannerViewTests: XCTestCase {

    private var window: NSWindow!
    private var clock = Date(timeIntervalSinceReferenceDate: 2_000_000)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        clock = Date(timeIntervalSinceReferenceDate: 2_000_000)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        addTeardownBlock { [window] in window?.close() }
    }

    private func rfc3339(secondsFromNow: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: clock.addingTimeInterval(secondsFromNow))
    }

    private func info(status: TerminalStatus = .running, closesIn: TimeInterval? = 120, warn: Int? = 130) -> TerminalInfo {
        var info = TerminalInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a", kind: .ecs, label: "production", cwd: nil,
                                target: TerminalTarget(project: "admin-portal", environment: "production", service: "scheduler", shellType: "shell"),
                                status: status, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                                requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil, follower: nil,
                                idleClosesAt: closesIn.map(rfc3339(secondsFromNow:)))
        info.idleWarnAfterSecs = warn
        return info
    }

    private func makeBanner(_ info: TerminalInfo?, inWindow: Bool = true) -> IdleBannerView {
        let banner = IdleBannerView()
        banner.now = { [unowned self] in self.clock }
        banner.frame = NSRect(x: 0, y: 0, width: 500, height: IdleBannerView.height)
        banner.update(info: info)
        if inWindow { window.contentView!.addSubview(banner) }
        addTeardownBlock { banner.removeFromSuperview() }
        banner.layoutSubtreeIfNeeded()
        return banner
    }

    private func labelText(_ banner: IdleBannerView) -> String? {
        var stack = banner.subviews
        while let view = stack.popLast() {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == "terminal-idle-label" { return field.stringValue }
            stack += view.subviews
        }
        return nil
    }

    func testTheBannerCountsDownWithTheDaemonsOwnWarnFigure() throws {
        let banner = makeBanner(info(closesIn: 119, warn: 130))
        XCTAssertFalse(banner.isHidden)
        XCTAssertEqual(banner.accessibilityIdentifier(), "terminal-idle-banner")
        XCTAssertEqual(labelText(banner), "Closing in 1:59 (no keystrokes for 2 minutes 10 seconds)")
    }

    func testThirteenMinutesAppearsOnlyWhenTheDaemonSaysSo() {
        XCTAssertEqual(labelText(makeBanner(info(closesIn: 90, warn: 780))), "Closing in 1:30 (no keystrokes for 13 minutes)")
        XCTAssertEqual(labelText(makeBanner(info(closesIn: 90, warn: 60))), "Closing in 1:30 (no keystrokes for 1 minute)")
    }

    func testAnOlderDaemonWithoutAFigureGetsTheVagueWording() {
        XCTAssertEqual(labelText(makeBanner(info(closesIn: 90, warn: nil))), "Closing in 1:30 (no keystrokes for a while)")
    }

    func testTheCountdownTimerIsRunningAndRegisteredInEveryRunLoopMode() throws {
        let banner = makeBanner(info())
        let timer = try XCTUnwrap(banner.timer, "a counting banner has a timer")
        XCTAssertTrue(timer.isValid)
        XCTAssertTrue(CFRunLoopContainsTimer(CFRunLoopGetMain(), unsafeBitCast(timer, to: CFRunLoopTimer.self), CFRunLoopMode.commonModes),
                      "a timer in the default mode alone stops while a menu or a drag tracks, freezing the countdown")
    }

    func testUpdatingWithoutTheIdleWarningStopsTheTimerAndHidesTheBanner() throws {
        let banner = makeBanner(info())
        let timer = try XCTUnwrap(banner.timer)
        banner.update(info: info(closesIn: nil, warn: nil))
        XCTAssertNil(banner.timer)
        XCTAssertFalse(timer.isValid)
        XCTAssertTrue(banner.isHidden)
    }

    func testUpdatingToAnEndedShellHidesTheBannerAndStopsTheTimer() throws {
        let banner = makeBanner(info())
        let timer = try XCTUnwrap(banner.timer)
        banner.update(info: info(status: .ended))
        XCTAssertNil(banner.timer)
        XCTAssertFalse(timer.isValid)
        XCTAssertTrue(banner.isHidden)
    }

    func testRemovingTheBannerFromItsWindowStopsTheTimer() throws {
        let banner = makeBanner(info())
        let timer = try XCTUnwrap(banner.timer)
        banner.removeFromSuperview()
        XCTAssertNil(banner.timer)
        XCTAssertFalse(timer.isValid)
        XCTAssertTrue(banner.isHidden)
    }

    func testABannerNotInAWindowIsHiddenAndRunsNoTimer() {
        let banner = makeBanner(info(), inWindow: false)
        XCTAssertTrue(banner.isHidden)
        XCTAssertNil(banner.timer)
    }

    func testAnEndedShellNeverShowsTheBannerWhateverTheDaemonLastSaid() {
        let banner = makeBanner(info(status: .ended))
        XCTAssertTrue(banner.isHidden)
        XCTAssertNil(banner.timer)
    }

    func testAShellStillConnectingNeverShowsTheBanner() {
        let banner = makeBanner(info(status: .connecting))
        XCTAssertTrue(banner.isHidden)
        XCTAssertNil(banner.timer)
    }

    func testNoIdleWarningMeansNoBannerAndNoTimer() {
        let banner = makeBanner(info(closesIn: nil, warn: nil))
        XCTAssertTrue(banner.isHidden)
        XCTAssertNil(banner.timer)
    }

    func testTheTimerAndBannerComeBackWhenTheViewReturnsToAWindow() throws {
        let banner = makeBanner(info())
        banner.removeFromSuperview()
        window.contentView!.addSubview(banner)
        XCTAssertFalse(banner.isHidden)
        XCTAssertTrue(try XCTUnwrap(banner.timer).isValid)
    }

    func testTheHostIsToldWhenTheBannerAppearsAndDisappears() {
        let banner = IdleBannerView()
        banner.now = { [unowned self] in self.clock }
        var changes = 0
        banner.onVisibilityChange = { changes += 1 }
        window.contentView!.addSubview(banner)
        addTeardownBlock { banner.removeFromSuperview() }
        banner.update(info: info())
        XCTAssertEqual(changes, 1)
        banner.update(info: info(closesIn: nil))
        XCTAssertEqual(changes, 2)
        banner.update(info: info(closesIn: nil))
        XCTAssertEqual(changes, 2, "no change, no call")
    }

    func testThePastDeadlineStillShowsZeroNotNegative() {
        let banner = makeBanner(info(closesIn: -30, warn: 780))
        XCTAssertEqual(labelText(banner), "Closing in 0:00 (no keystrokes for 13 minutes)")
    }
}
