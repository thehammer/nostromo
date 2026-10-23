import XCTest
import AppKit
import NostromoKit

// The one test that uses a REAL full-screen window: the exact situation that crashed on
// macOS 27 (a full-screen window closed because its display vanished, outside any
// transition). A test double can only mimic AppKit's rule; this checks the rule itself.
//
// It enters real full-screen, which switches the machine to a new Space. On a developer's
// Mac that would flip their displays, so it runs only where `CI=true` (make ci-remote),
// and skips if the runner cannot enter full-screen at all.
//
// NostromoWindow.swift and DisplayTopology.swift are compiled into this target directly.

private let contentRect = NSRect(x: 100, y: 100, width: 800, height: 600)
private let baseMask: NSWindow.StyleMask = [.titled, .resizable, .fullSizeContentView]

/// A window configured the way `AppDelegate` creates one it will put in full-screen.
private func makeFullScreenCapableWindow() -> NostromoWindow {
    let win = NostromoWindow(contentRect: contentRect, styleMask: baseMask, backing: .buffered, defer: false)
    win.delegate = win
    win.collectionBehavior = [.fullScreenPrimary, .managed]
    return win
}

final class RealFullScreenTeardownTests: XCTestCase {

    /// Drains autorelease pools and spins the run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func spin(timeout: TimeInterval, until condition: () -> Bool = { false }) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if condition() { return true }
        } while Date() < deadline
        return condition()
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CI"] == "true",
                          "enters real full-screen, which flips the developer's Spaces; runs on CI only")
    }

    func test_a_real_full_screen_window_whose_display_vanished_closes_without_an_exception_and_is_freed() throws {
        weak var weakWindow: NostromoWindow?
        var held: NostromoWindow?

        // Never leave a full-screen window open, whatever path this test takes.
        defer {
            if let leftover = held, !leftover.isReleasedWhenClosed {   // closing one that is would over-release it
                spin(timeout: 5) { !leftover.isInTransition }
                leftover.isPendingScreenRemoval = true
                leftover.prepareForDisplayRemovalClose()
                _ = leftover.closeAfterDisplayRemoval(logContext: "test cleanup")
                held = nil
                spin(timeout: 3)
            }
        }

        autoreleasepool {
            let win = makeFullScreenCapableWindow()
            weakWindow = win
            held = win
        }
        // The window is passed (not bound to a local here) so the only strong reference left
        // after the call is `held`, which is what "the app lets go" drops.
        try enterFullScreenAndTearDown(try XCTUnwrap(held))

        held = nil
        XCTAssertTrue(spin(timeout: 10, until: { weakWindow == nil }),
                      "the window must be freed once the app drops its last reference")
    }

    /// Puts `window` in real full-screen, runs the production teardown on it, and checks it closed cleanly.
    private func enterFullScreenAndTearDown(_ window: NostromoWindow) throws {
        XCTAssertFalse(window.isReleasedWhenClosed)
        // Closing a window that is released when closed would over-release it: stop rather than crash.
        try XCTSkipIf(window.isReleasedWhenClosed, "window would be released when closed")

        window.orderFront(nil)
        window.toggleFullScreen(nil)
        let entered = spin(timeout: 10) { window.styleMask.contains(.fullScreen) && !window.isInTransition }
        guard entered else {
            print("RealFullScreenTeardownTests: full-screen was never entered: mask.fullScreen=\(window.styleMask.contains(.fullScreen)) inTransition=\(window.isInTransition) visible=\(window.isVisible)")
            throw XCTSkip("could not enter full screen on this runner")
        }

        // What happens when its display vanishes: the coordinator has flagged the window and waited
        // out its grace and any transition, then the app runs the teardown.
        window.isPendingScreenRemoval = true
        var windowsByDisplayUUID: [String: NostromoWindow] = ["display-uuid-1": window]
        var windows: [NostromoWindow] = [window]
        var closeResult: CaughtObjCException?
        let escaped = ObjCExceptionGuard.catching {
            VanishedWindowTeardown.run(.init(
                unbindKey: { windowsByDisplayUUID.removeValue(forKey: "display-uuid-1") },
                dropController: {},
                removeFromWindows: { windows.removeAll { $0 === window } },
                afterUnbind: {},
                prepareWindow: { window.prepareForDisplayRemovalClose() },
                close: { closeResult = window.closeAfterDisplayRemoval(logContext: "real full-screen test") }
            ))
        }

        XCTAssertNil(escaped, "an exception escaped the teardown of a real full-screen window")
        XCTAssertNil(closeResult, "AppKit raised while closing a real full-screen window: \(String(describing: closeResult))")
        spin(timeout: 3)
        XCTAssertFalse(window.isVisible, "the closed window must be off screen")
        XCTAssertTrue(windowsByDisplayUUID.isEmpty && windows.isEmpty, "the teardown unbinds the window")
    }
}
