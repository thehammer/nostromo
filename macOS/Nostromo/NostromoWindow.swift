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

    func windowWillExitFullScreen(_ notification: Notification) {
        winLog.warning("windowWillExitFullScreen — \(self.title, privacy: .public) (not re-entering; see comment)")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        winLog.warning("windowDidExitFullScreen — \(self.title, privacy: .public) isFullScreen=\(self.styleMask.contains(.fullScreen), privacy: .public)")
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
