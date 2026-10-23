import XCTest
import AppKit
import NostromoKit

// NostromoWindow.swift and DisplayTopology.swift are compiled into this target
// directly. Windows are never shown and no real display (or Space) is touched.
//
// Required behavior, for the window of a vanished display:
//  - Not mid-transition: a plain `close()`. `.fullScreen` is never cleared from `styleMask`.
//    On macOS 27 AppKit raises NSGenericException ("NSWindowStyleMaskFullScreen cleared on a
//    window outside of a full screen transition.") for that, which killed the app.
//  - Mid-transition (the coordinator's close deferrals ran out, or the untracked path with no
//    transition wait) and `.fullScreen` in the mask: `.fullScreen` is cleared FIRST (legal in a
//    transition, and the protection against the `_NSExitFullScreenTransitionController` crash a
//    full-screen window hits when closed mid-transition), then `close()` runs.
//  - Both the clear and the close are guarded: an exception raised by either is contained and
//    reported, not fatal, and `close()` still runs after a failed clear.
//
// The real rule can only be seen on a real full-screen window (RealFullScreenTeardownTests,
// CI only). Here a test double enforces the same rule on a window that only has the
// full-screen bit in its mask, so the check runs anywhere without moving a Space. The double
// also records the order of the mask clear and the close.

private let contentRect = NSRect(x: 100, y: 100, width: 800, height: 600)
private let baseMask: NSWindow.StyleMask = [.titled, .resizable, .fullSizeContentView]

private let macOS27Reason = "NSWindowStyleMaskFullScreen cleared on a window outside of a full screen transition."

/// A NostromoWindow whose `styleMask` follows macOS 27's rule: the full-screen bit may be
/// cleared only during a full-screen transition (`isInTransition`, which the delegate
/// callbacks drive). A violation is recorded and raised as an NSException, exactly as AppKit does.
private class LegalityCheckingWindow: NostromoWindow {

    /// Every illegal clearing of `.fullScreen` that was attempted.
    private(set) var violations: [String] = []
    /// How many times `close()` ran.
    private(set) var closeCount = 0
    /// Makes `close()` itself raise (a future OS that objects to the close).
    var raiseInClose = false
    /// Makes clearing `.fullScreen` raise even inside a transition (a future OS that objects to that).
    var raiseInTransitionClear = false
    /// What happened to the window, in order: "clearFullScreen" (a clear that took effect) and "close".
    private(set) var events: [String] = []
    /// Clears refused by `raiseInTransitionClear`.
    private(set) var refusedClears = 0

    /// Nil until `simulateFullScreenMask()`; then the mask the window reports.
    private var simulatedMask: NSWindow.StyleMask?

    /// Gives the window a mask with `.fullScreen` set, without asking AppKit to enter full-screen.
    func simulateFullScreenMask() {
        simulatedMask = super.styleMask.union(.fullScreen)
    }

    override var styleMask: NSWindow.StyleMask {
        get { simulatedMask ?? super.styleMask }
        set {
            guard let current = simulatedMask else { super.styleMask = newValue; return }
            if current.contains(.fullScreen), !newValue.contains(.fullScreen), !isInTransition {
                violations.append("styleMask cleared .fullScreen outside a transition")
                NSException(name: .genericException, reason: macOS27Reason, userInfo: nil).raise()
            }
            let clearsFullScreen = current.contains(.fullScreen) && !newValue.contains(.fullScreen)
            if clearsFullScreen, raiseInTransitionClear {
                refusedClears += 1
                NSException(name: .genericException, reason: "clear refused", userInfo: nil).raise()
            }
            if clearsFullScreen { events.append("clearFullScreen") }
            simulatedMask = newValue
        }
    }

    override func close() {
        closeCount += 1
        events.append("close")
        if raiseInClose {
            NSException(name: .genericException, reason: "close refused", userInfo: nil).raise()
        }
        super.close()
    }

    /// The window is mid full-screen exit (what AppKit tells the delegate before the transition).
    func beginSimulatedTransition() {
        windowWillExitFullScreen(Notification(name: NSWindow.willExitFullScreenNotification, object: self))
    }

    /// The transition is over, without the delegate's re-entry scheduling.
    func endSimulatedTransition() {
        windowDidFailToExitFullScreen(self)
    }
}

/// A window configured the way `AppDelegate` finds one before the teardown: not yet orphaned,
/// default animation, a lifecycle observer attached.
private func makeFullScreenMaskedWindow() -> LegalityCheckingWindow {
    let win = LegalityCheckingWindow(contentRect: contentRect, styleMask: baseMask, backing: .buffered, defer: true)
    win.delegate = win
    win.isOrphanedByScreenRemoval = false
    win.animationBehavior = .default
    win.lifecycleHandler = { _ in }
    win.simulateFullScreenMask()
    return win
}

private struct TeardownOutcome {
    var order: [String] = []
    /// What `closeAfterDisplayRemoval` returned.
    var closeResult: CaughtObjCException?
    /// An exception that got out of the whole teardown (must stay nil).
    var escaped: CaughtObjCException?
    var finished = false
}

/// The teardown composed the way `AppDelegate.closeWindowForVanishedDisplay` composes it.
private func runDisplayRemovalTeardown(on win: NostromoWindow, uuid: String = "display-uuid-1",
                                       onUnbind: @escaping () -> Void = {}) -> TeardownOutcome {
    var outcome = TeardownOutcome()
    var windowsByDisplayUUID: [String: NostromoWindow] = [uuid: win]
    var windows: [NostromoWindow] = [win]

    let escaped = ObjCExceptionGuard.catching {
        VanishedWindowTeardown.run(.init(
            unbindKey: { outcome.order.append("unbindKey"); windowsByDisplayUUID.removeValue(forKey: uuid); onUnbind() },
            dropController: { outcome.order.append("dropController") },
            removeFromWindows: { outcome.order.append("removeFromWindows"); windows.removeAll { $0 === win } },
            afterUnbind: { outcome.order.append("afterUnbind") },
            prepareWindow: { outcome.order.append("prepareWindow"); win.prepareForDisplayRemovalClose() },
            close: {
                outcome.order.append("close")
                outcome.closeResult = win.closeAfterDisplayRemoval(logContext: "display \(uuid)")
            }
        ))
        outcome.finished = true
    }
    outcome.escaped = escaped
    return outcome
}

// MARK: - Minimal coordinator fakes (the ones in DisplayTopologyTests.swift are private to that file)

/// A virtual clock: `advance(by:)` fires every closure that falls due, in time order (ties in
/// scheduling order), including closures scheduled while firing.
private final class LegalityVirtualClock: PlacementScheduler {
    private(set) var now: TimeInterval = 0
    private var queue: [(due: TimeInterval, seq: Int, work: () -> Void)] = []
    private var seq = 0

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        seq += 1
        queue.append((now + max(delay, 0), seq, work))
    }

    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let index = nextDueIndex(upTo: target) {
            let item = queue.remove(at: index)
            now = max(now, item.due)
            item.work()
        }
        now = target
    }

    private func nextDueIndex(upTo target: TimeInterval) -> Int? {
        var best: Int?
        for (i, item) in queue.enumerated() where item.due <= target {
            if let b = best {
                if (item.due, item.seq) < (queue[b].due, queue[b].seq) { best = i }
            } else {
                best = i
            }
        }
        return best
    }
}

private enum LegalityDisplays {
    static let builtIn = DisplayInfo(
        uuid: "BUILT-IN", screenNumber: 1,
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073),
        backingScaleFactor: 2, localizedName: "Built-in", isMain: true)

    static func airPlay(uuid: String) -> DisplayInfo {
        DisplayInfo(
            uuid: uuid, screenNumber: 4,
            frame: CGRect(x: 4270, y: 0, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 4270, y: 0, width: 1920, height: 1055),
            backingScaleFactor: 1, localizedName: "Flex Room", isMain: false)
    }
}

final class FullScreenTeardownLegalityTests: XCTestCase {

    // SAFETY: with `isReleasedWhenClosed == true`, closing a strongly held window
    // over-releases it. Same guard as NostromoWindowCloseLifetimeTests.
    private func requireNotReleasedWhenClosed(_ win: NSWindow) -> Bool {
        XCTAssertFalse(win.isReleasedWhenClosed)
        return !win.isReleasedWhenClosed
    }

    // MARK: - The test double is faithful (so the tests below can fail)

    func test_the_double_raises_and_records_when_full_screen_is_cleared_outside_a_transition() {
        let win = makeFullScreenMaskedWindow()
        XCTAssertFalse(win.isInTransition)

        let caught = ObjCExceptionGuard.catching {
            var mask = win.styleMask
            mask.remove(.fullScreen)
            win.styleMask = mask
        }

        XCTAssertEqual(caught, CaughtObjCException(name: "NSGenericException", reason: macOS27Reason))
        XCTAssertEqual(win.violations.count, 1)
        XCTAssertTrue(win.styleMask.contains(.fullScreen), "a refused change leaves the mask alone")
    }

    func test_the_double_allows_clearing_full_screen_during_a_transition() {
        let win = makeFullScreenMaskedWindow()
        win.beginSimulatedTransition()
        defer { win.endSimulatedTransition() }
        XCTAssertTrue(win.isInTransition)

        let caught = ObjCExceptionGuard.catching {
            var mask = win.styleMask
            mask.remove(.fullScreen)
            win.styleMask = mask
        }

        XCTAssertNil(caught)
        XCTAssertTrue(win.violations.isEmpty)
        XCTAssertFalse(win.styleMask.contains(.fullScreen))
    }

    // MARK: - FS-1: outside a transition the display-removal teardown never touches the mask

    func test_tearing_down_a_full_screen_window_outside_a_transition_does_not_clear_its_mask_or_raise() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        XCTAssertTrue(win.styleMask.contains(.fullScreen))
        XCTAssertFalse(win.isInTransition, "the coordinator closes only once the window's own transition has ended")

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped, "no exception may escape the teardown")
        XCTAssertTrue(outcome.finished)
        XCTAssertNil(outcome.closeResult)
        XCTAssertEqual(win.violations, [], "the teardown must never clear .fullScreen outside a transition")
        XCTAssertEqual(win.closeCount, 1, "the window is closed exactly once")
        XCTAssertTrue(win.styleMask.contains(.fullScreen), "the mask is left exactly as it was")
        XCTAssertEqual(win.events, ["close"], "outside a transition: a plain close, no mask change")
        XCTAssertTrue(win.isOrphanedByScreenRemoval, "so windowShouldClose lets the close through instead of quitting")
        XCTAssertEqual(win.animationBehavior, NSWindow.AnimationBehavior.none)
        XCTAssertNil(win.lifecycleHandler)
        XCTAssertEqual(outcome.order, ["unbindKey", "dropController", "removeFromWindows", "afterUnbind",
                                       "prepareWindow", "close"])
    }

    func test_tearing_down_a_window_that_is_not_full_screen_closes_it_once() {
        let win = LegalityCheckingWindow(contentRect: contentRect, styleMask: baseMask, backing: .buffered, defer: true)
        win.delegate = win
        guard requireNotReleasedWhenClosed(win) else { return }
        XCTAssertFalse(win.styleMask.contains(.fullScreen))

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped)
        XCTAssertNil(outcome.closeResult)
        XCTAssertEqual(win.violations, [])
        XCTAssertEqual(win.closeCount, 1)
        XCTAssertTrue(win.isOrphanedByScreenRemoval)
    }

    func test_closing_an_untracked_full_screen_window_does_not_clear_its_mask_or_raise() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }

        // `closeUntrackedWindow` has no key to unbind: it is just these two calls.
        var closeResult: CaughtObjCException?
        let escaped = ObjCExceptionGuard.catching {
            win.prepareForDisplayRemovalClose()
            closeResult = win.closeAfterDisplayRemoval(logContext: "no live placement controller for display-uuid-1")
        }

        XCTAssertNil(escaped)
        XCTAssertNil(closeResult)
        XCTAssertEqual(win.violations, [])
        XCTAssertEqual(win.closeCount, 1)
        XCTAssertTrue(win.styleMask.contains(.fullScreen))
        XCTAssertEqual(win.events, ["close"], "outside a transition: a plain close, no mask change")
        XCTAssertTrue(win.isOrphanedByScreenRemoval)
        XCTAssertEqual(win.animationBehavior, NSWindow.AnimationBehavior.none)
        XCTAssertNil(win.lifecycleHandler)
    }

    // MARK: - FS-3: mid-transition, the mask is cleared first, then the window is closed

    func test_closing_a_full_screen_window_that_is_mid_transition_clears_the_mask_first_and_then_closes() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        win.beginSimulatedTransition()
        defer { win.endSimulatedTransition() }
        XCTAssertTrue(win.styleMask.contains(.fullScreen))

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped, "no exception may escape the teardown")
        XCTAssertTrue(outcome.finished)
        XCTAssertNil(outcome.closeResult)
        XCTAssertEqual(win.violations, [], "clearing the bit mid-transition is legal: no violation")
        XCTAssertFalse(win.styleMask.contains(.fullScreen), "the bit is cleared so the close cannot hit the exit-transition crash")
        XCTAssertEqual(win.closeCount, 1)
        XCTAssertEqual(win.events, ["clearFullScreen", "close"], "the mask is cleared BEFORE close() runs")
    }

    func test_closing_a_mid_transition_window_that_is_not_full_screen_does_not_touch_its_mask() {
        let win = LegalityCheckingWindow(contentRect: contentRect, styleMask: baseMask, backing: .buffered, defer: true)
        win.delegate = win
        guard requireNotReleasedWhenClosed(win) else { return }
        win.lifecycleHandler = { _ in }
        win.beginSimulatedTransition()
        defer { win.endSimulatedTransition() }
        let maskBefore = win.styleMask
        XCTAssertFalse(maskBefore.contains(.fullScreen))

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped)
        XCTAssertNil(outcome.closeResult)
        XCTAssertEqual(win.violations, [])
        XCTAssertEqual(win.styleMask, maskBefore, "nothing to clear: the mask is left exactly as it was")
        XCTAssertEqual(win.events, ["close"])
        XCTAssertEqual(win.closeCount, 1)
    }

    func test_closing_an_untracked_mid_transition_full_screen_window_clears_the_mask_first_and_then_closes() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        win.beginSimulatedTransition()
        defer { win.endSimulatedTransition() }

        // `closeUntrackedWindow` has no key to unbind and does not wait for a transition.
        var closeResult: CaughtObjCException?
        let escaped = ObjCExceptionGuard.catching {
            win.prepareForDisplayRemovalClose()
            closeResult = win.closeAfterDisplayRemoval(logContext: "no live placement controller for display-uuid-1")
        }

        XCTAssertNil(escaped)
        XCTAssertNil(closeResult)
        XCTAssertEqual(win.violations, [])
        XCTAssertFalse(win.styleMask.contains(.fullScreen))
        XCTAssertEqual(win.closeCount, 1)
        XCTAssertEqual(win.events, ["clearFullScreen", "close"], "the mask is cleared BEFORE close() runs")
        XCTAssertTrue(win.isOrphanedByScreenRemoval)
        XCTAssertEqual(win.animationBehavior, NSWindow.AnimationBehavior.none)
        XCTAssertNil(win.lifecycleHandler)
    }

    func test_a_window_still_mid_transition_when_the_coordinators_deferrals_run_out_is_closed_once_with_the_protected_sequence() {
        let air = "AIRPLAY-DISPLAY"
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        win.beginSimulatedTransition()                      // the transition never ends during this test
        defer { win.endSimulatedTransition() }

        let clock = LegalityVirtualClock()
        var bound: Set<String> = [LegalityDisplays.builtIn.uuid, air]
        var attached = [LegalityDisplays.builtIn, LegalityDisplays.airPlay(uuid: air)]
        var outcomes: [TeardownOutcome] = []
        let host = DisplayTopologyCoordinator.Host(
            attachedDisplays: { attached },
            boundUUIDs: { bound },
            topologyChanged: {},
            rehome: { _ in },
            openWindows: { _ in },
            closeWindow: { uuid in
                guard uuid == air else { return }
                outcomes.append(runDisplayRemovalTeardown(on: win, uuid: uuid, onUnbind: { _ = bound.remove(uuid) }))
            },
            passFinished: {},
            log: { _ in },
            isWindowTransitioning: { _ in true })           // the host keeps seeing the window mid-transition
        let coordinator = DisplayTopologyCoordinator(scheduler: clock, host: host)
        coordinator.recordHandled(attached)

        attached = [LegalityDisplays.builtIn]               // the AirPlay display vanishes
        coordinator.displaysChanged()
        clock.advance(by: DisplayTopologyCoordinator.defaultSettleDelay)
        clock.advance(by: DisplayTopologyCoordinator.defaultCloseGrace)
        XCTAssertEqual(outcomes.count, 0, "the close is deferred while the window is mid-transition")
        XCTAssertEqual(win.closeCount, 0)

        let deferral = DisplayTopologyCoordinator.defaultCloseDeferralInterval
        let limit = DisplayTopologyCoordinator.defaultCloseDeferralLimit
        clock.advance(by: deferral * Double(limit - 1))
        XCTAssertEqual(outcomes.count, 0, "still within the deferral bound")

        clock.advance(by: deferral * 2)                     // the deferrals have run out: closed anyway
        clock.advance(by: 60)                               // and never again

        XCTAssertEqual(outcomes.count, 1, "exactly one teardown")
        guard let outcome = outcomes.first else { return }
        XCTAssertNil(outcome.escaped, "no exception may escape the teardown")
        XCTAssertTrue(outcome.finished)
        XCTAssertNil(outcome.closeResult)
        XCTAssertEqual(outcome.order, ["unbindKey", "dropController", "removeFromWindows", "afterUnbind",
                                       "prepareWindow", "close"])
        XCTAssertEqual(win.violations, [])
        XCTAssertEqual(win.closeCount, 1)
        XCTAssertFalse(win.styleMask.contains(.fullScreen))
        XCTAssertEqual(win.events, ["clearFullScreen", "close"], "the mask is cleared BEFORE close() runs")
        XCTAssertTrue(win.isOrphanedByScreenRemoval)
        XCTAssertEqual(bound, [LegalityDisplays.builtIn.uuid], "the key was unbound")
    }

    func test_an_exception_raised_by_the_mask_clear_is_contained_and_close_still_runs_once() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        win.raiseInTransitionClear = true
        win.beginSimulatedTransition()
        defer { win.endSimulatedTransition() }

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped, "the app must not be taken down by a throwing mask clear")
        XCTAssertTrue(outcome.finished, "the teardown runs to the end")
        XCTAssertEqual(win.refusedClears, 1, "the clear was attempted")
        XCTAssertEqual(win.closeCount, 1, "close() still runs after a failed clear, and only once")
        XCTAssertEqual(win.events, ["close"], "the refused clear changed nothing")
        XCTAssertTrue(win.styleMask.contains(.fullScreen))
        XCTAssertNil(outcome.closeResult, "the return value is close()'s exception only, not the clear's")
        XCTAssertEqual(outcome.order.last, "close")
    }

    func test_when_both_the_mask_clear_and_close_raise_both_are_contained_and_the_close_result_is_returned() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        win.raiseInTransitionClear = true
        win.raiseInClose = true
        win.beginSimulatedTransition()
        defer { win.endSimulatedTransition() }

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped)
        XCTAssertTrue(outcome.finished)
        XCTAssertEqual(win.refusedClears, 1)
        XCTAssertEqual(win.closeCount, 1)
        XCTAssertEqual(outcome.closeResult, CaughtObjCException(name: "NSGenericException", reason: "close refused"))
    }

    // MARK: - FS-2: an exception from close() is contained

    func test_an_exception_raised_by_close_is_returned_not_thrown_and_the_teardown_completes() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        win.raiseInClose = true

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped, "the app must not be taken down by a throwing close()")
        XCTAssertTrue(outcome.finished, "the teardown runs to the end")
        XCTAssertEqual(outcome.closeResult, CaughtObjCException(name: "NSGenericException", reason: "close refused"))
        XCTAssertEqual(win.closeCount, 1, "a throwing close is not retried")
        XCTAssertEqual(win.violations, [])
        XCTAssertEqual(outcome.order.last, "close")
    }

    func test_an_exception_from_one_windows_close_does_not_stop_the_next_window_closing() {
        let first = makeFullScreenMaskedWindow()
        let second = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(first), requireNotReleasedWhenClosed(second) else { return }
        first.raiseInClose = true

        let a = runDisplayRemovalTeardown(on: first, uuid: "display-a")
        let b = runDisplayRemovalTeardown(on: second, uuid: "display-b")

        XCTAssertNotNil(a.closeResult)
        XCTAssertNil(b.closeResult, "the guard is not left poisoned by an earlier catch")
        XCTAssertEqual(second.closeCount, 1)
        XCTAssertEqual(second.violations, [])
    }
}
