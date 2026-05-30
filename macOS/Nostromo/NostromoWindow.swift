import AppKit

/// The main application window. Acts as its own NSWindowDelegate so it can
/// enforce the "always full-screen" constraint without bouncing through AppDelegate.
class NostromoWindow: NSWindow, NSWindowDelegate {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        // Reveal the window as the Space animation begins — the fade completes
        // by the time the transition settles, so content appears naturally.
        // Duration matches the macOS full-screen transition (~0.5 s).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            animator().alphaValue = 1.0
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        // Re-enter full screen immediately. This window lives in its Space —
        // swiping away is fine (system gesture), but exiting to windowed mode isn't.
        DispatchQueue.main.async { [weak self] in
            self?.toggleFullScreen(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Traffic lights are hidden, but just in case: route close to quit.
        NSApplication.shared.terminate(nil)
        return false
    }
}
