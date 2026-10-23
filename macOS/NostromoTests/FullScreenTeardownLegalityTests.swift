import XCTest
import AppKit
import NostromoKit

// NostromoWindow.swift and DisplayTopology.swift are compiled into this target
// directly. Windows are never shown and no real display (or Space) is touched.
//
// Required behavior: closing the window of a vanished display never clears
// `.fullScreen` from its `styleMask`. On macOS 27 AppKit raises NSGenericException
// ("NSWindowStyleMaskFullScreen cleared on a window outside of a full screen
// transition.") for that, which killed the app. The close is also guarded, so an
// exception raised by `close()` itself is contained and reported, not fatal.
//
// The real rule can only be seen on a real full-screen window (RealFullScreenTeardownTests,
// CI only). Here a test double enforces the same rule on a window that only has the
// full-screen bit in its mask, so the check runs anywhere without moving a Space.

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
            simulatedMask = newValue
        }
    }

    override func close() {
        closeCount += 1
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
private func runDisplayRemovalTeardown(on win: NostromoWindow, uuid: String = "display-uuid-1") -> TeardownOutcome {
    var outcome = TeardownOutcome()
    var windowsByDisplayUUID: [String: NostromoWindow] = [uuid: win]
    var windows: [NostromoWindow] = [win]

    let escaped = ObjCExceptionGuard.catching {
        VanishedWindowTeardown.run(.init(
            unbindKey: { outcome.order.append("unbindKey"); windowsByDisplayUUID.removeValue(forKey: uuid) },
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

    // MARK: - FS-1: the display-removal teardown never touches the mask

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
        XCTAssertTrue(win.isOrphanedByScreenRemoval)
        XCTAssertEqual(win.animationBehavior, NSWindow.AnimationBehavior.none)
        XCTAssertNil(win.lifecycleHandler)
    }

    func test_closing_a_full_screen_window_that_is_mid_transition_still_never_touches_the_mask() {
        let win = makeFullScreenMaskedWindow()
        guard requireNotReleasedWhenClosed(win) else { return }
        win.beginSimulatedTransition()
        defer { win.endSimulatedTransition() }

        let outcome = runDisplayRemovalTeardown(on: win)

        XCTAssertNil(outcome.escaped)
        XCTAssertEqual(win.violations, [])
        XCTAssertTrue(win.styleMask.contains(.fullScreen), "the mask is not the teardown's to change, even when that would be legal")
        XCTAssertEqual(win.closeCount, 1)
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
