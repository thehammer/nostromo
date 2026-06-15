import AppKit
import os

private let winLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "NostromoWindow")

/// The main application window. Acts as its own NSWindowDelegate so it can
/// enforce the "always full-screen" constraint without bouncing through AppDelegate.
///
/// ## Sleep/wake strategy
///
/// Blocking `windowShouldExitFullScreen` or overriding `toggleFullScreen` is
/// insufficient on macOS 26: the system schedules `_NSExitFullScreenTransitionController.start`
/// as a run-loop block that fires before any delegate hook, and fighting the exit
/// mid-stream causes a use-after-free SIGSEGV inside the controller's own cleanup
/// chain (`_doFailedToExitFullScreen` / `contentWindowID`).
///
/// The only crash-free approach: **let the exit complete**, then immediately
/// re-enter full screen in `windowDidExitFullScreen`. The user may see a brief
/// flash on wake, but no crash. A `isReenteringFullScreen` flag prevents the
/// re-entry from triggering another exit and creating a toggle loop.
class NostromoWindow: NSWindow, NSWindowDelegate {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Guards against re-entry triggering another exit during startup or when
    /// multiple windows are entering full-screen simultaneously.
    private var isReenteringFullScreen = false

    // MARK: - NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        winLog.info("windowWillEnterFullScreen — \(self.title, privacy: .public)")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            animator().alphaValue = 1.0
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        winLog.info("windowDidEnterFullScreen — \(self.title, privacy: .public)")
        isReenteringFullScreen = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        // One window in the simultaneous multi-window startup sequence occasionally
        // fails. Retry after a short delay to let sibling animations settle.
        winLog.warning("windowDidFailToEnterFullScreen — \(self.title, privacy: .public) — retrying in 0.5s")
        isReenteringFullScreen = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            winLog.warning("windowDidFailToEnterFullScreen — retrying toggleFullScreen for \(window.title, privacy: .public)")
            window.toggleFullScreen(nil)
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        winLog.warning("windowWillExitFullScreen — \(self.title, privacy: .public) — will re-enter after exit completes")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        winLog.warning("windowDidExitFullScreen — \(self.title, privacy: .public) — re-entering full screen")
        guard !isReenteringFullScreen else {
            winLog.warning("windowDidExitFullScreen — re-entry already in progress, skipping")
            return
        }
        isReenteringFullScreen = true
        // Re-enter after the run-loop drains any remaining transition cleanup.
        // Do NOT call toggleFullScreen synchronously here — the previous exit's
        // animation context may still be active, which would cause a toggle loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.styleMask.contains(.fullScreen) else {
                self?.isReenteringFullScreen = false
                return
            }
            winLog.warning("windowDidExitFullScreen — calling toggleFullScreen to re-enter (\(self.title, privacy: .public))")
            self.toggleFullScreen(nil)
        }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        winLog.warning("windowDidFailToExitFullScreen — \(self.title, privacy: .public)")
        isReenteringFullScreen = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Traffic lights are hidden, but just in case: route close to quit.
        winLog.warning("windowShouldClose — routing to app terminate")
        NSApplication.shared.terminate(nil)
        return false
    }

    // Swallow Escape so it can't trigger a full-screen exit via cancelOperation.
    override func cancelOperation(_ sender: Any?) {
        winLog.debug("cancelOperation swallowed (Escape key)")
    }
}
