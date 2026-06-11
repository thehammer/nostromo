import AppKit
import os

private let winLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "NostromoWindow")

/// The main application window. Acts as its own NSWindowDelegate so it can
/// enforce the "always full-screen" constraint without bouncing through AppDelegate.
class NostromoWindow: NSWindow, NSWindowDelegate {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        winLog.info("windowWillEnterFullScreen — \(self.title, privacy: .public) isFullScreen=\(self.styleMask.contains(.fullScreen), privacy: .public)")
        // Reveal the window as the Space animation begins — the fade completes
        // by the time the transition settles, so content appears naturally.
        // Duration matches the macOS full-screen transition (~0.5 s).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            animator().alphaValue = 1.0
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        winLog.info("windowDidEnterFullScreen — \(self.title, privacy: .public)")
    }

    func windowShouldExitFullScreen(_ sender: NSWindow) -> Bool {
        // Block ALL exit-full-screen attempts. macOS fires these on sleep/wake
        // via _NSExitFullScreenTransitionController, which holds an internal
        // reference to the window and calls `isVisible` on it during the
        // transition. If anything has invalidated that pointer by the time the
        // async callback fires, AppKit crashes with EXC_BAD_ACCESS (SIGSEGV)
        // deep inside _doFailedToExitFullScreen — before any delegate hook is
        // reached. Returning false here prevents the transition controller from
        // ever being created, which is the only safe fix on macOS 26.
        // (Crash reports: 2026-06-10-160411, 2026-06-11-080220.)
        winLog.warning("windowShouldExitFullScreen — returning false to prevent transition controller crash (\(self.title, privacy: .public))")
        return false
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        // Fires only if windowShouldExitFullScreen returns true (e.g. user
        // explicitly exits via Mission Control despite the block above, or
        // in a future macOS that ignores the delegate return value).
        winLog.warning("windowWillExitFullScreen — \(self.title, privacy: .public) (not re-entering; see comment)")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        winLog.warning("windowDidExitFullScreen — \(self.title, privacy: .public) isFullScreen=\(self.styleMask.contains(.fullScreen), privacy: .public)")
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        // Fallback for any path that bypasses windowShouldExitFullScreen.
        winLog.warning("windowDidFailToExitFullScreen — \(self.title, privacy: .public) (suppressed)")
    }

    // Note: we deliberately do NOT force re-entry on windowWillExitFullScreen.
    // Calling toggleFullScreen here during the initial multi-screen startup
    // sequence triggers a toggle loop (macOS fires this during entry transitions
    // when multiple windows enter full-screen simultaneously), causing all windows
    // to close and the app to quit cleanly. The window lives in its own Space;
    // swiping away via Mission Control is fine — it stays in the Space.

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Traffic lights are hidden, but just in case: route close to quit.
        winLog.warning("windowShouldClose — routing to app terminate")
        NSApplication.shared.terminate(nil)
        return false
    }
}
