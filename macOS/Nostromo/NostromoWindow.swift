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

    /// Set to true while a display configuration change is in progress so
    /// deferred re-entry callbacks know to abort rather than firing into a
    /// menu-bar manager that is mid-cleanup (macOS 26 crash path via
    /// NSMenuBarWindowManager._reactToDisplayChanges).
    private var displayChangePending = false

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
        displayChangePending   = false   // clear any stale flag from a prior wake

        // Observe display changes so we can abort if the menu bar manager starts
        // reacting to a configuration change (NSMenuBarWindowManager path, macOS 26).
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.displayChangePending = true
            winLog.warning("windowDidExitFullScreen — display change detected, will abort re-entry if pending")
        }

        // Re-enter after the run-loop drains any remaining transition cleanup.
        // Delay extended to 0.6 s (was 0.3 s) to give the menu bar manager more
        // time to settle before we call toggleFullScreen again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            NotificationCenter.default.removeObserver(observer)
            guard let self, !self.styleMask.contains(.fullScreen) else {
                self?.isReenteringFullScreen = false
                return
            }
            guard !self.displayChangePending else {
                winLog.warning("windowDidExitFullScreen — aborting re-entry: display change in progress (\(self.title, privacy: .public))")
                self.isReenteringFullScreen = false
                // Schedule a follow-up re-entry once the display change settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self, !self.styleMask.contains(.fullScreen),
                          !self.isReenteringFullScreen else { return }
                    winLog.warning("windowDidExitFullScreen — follow-up re-entry after display settle (\(self.title, privacy: .public))")
                    self.displayChangePending = false
                    self.toggleFullScreen(nil)
                }
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
