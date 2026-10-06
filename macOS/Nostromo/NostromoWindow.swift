import AppKit
import os

private let winLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "NostromoWindow")

/// The main application window. Acts as its own NSWindowDelegate so it can
/// enforce the "always full-screen" constraint without bouncing through AppDelegate.
///
/// ## Sleep/wake crash history (macOS 26)
///
/// Three distinct crash paths have been observed, all rooted in
/// `_NSExitFullScreenTransitionController.contentWindowID` being called on a
/// stale/deallocated controller:
///
/// 1. `_doFailedToExitFullScreen` — exit transition fails mid-stream.
///    Fix: let the exit complete; re-enter in `windowDidExitFullScreen`.
/// 2. `NSMenuBarWindowManager._reactToDisplayChanges` — display config change
///    on wake races with our re-entry. Fix: abort if display change fires during
///    the re-entry window.
/// 3. `_NSEnterFullScreenTransitionController._doFailedToEnterFullScreen` — our
///    re-entry fires before the EXIT controller has fully cleaned up, the ENTER
///    fails, and its failure handler crashes referencing the stale EXIT controller.
///    Fix: wait 3 s (not 0.6 s) before re-entering; don't retry a failed re-entry
///    (leave the window windowed and let the user restore it).
class NostromoWindow: NSWindow, NSWindowDelegate {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Guards against re-entry triggering another exit during startup or when
    /// multiple windows are entering full-screen simultaneously.
    private var isReenteringFullScreen = false

    /// True when a post-exit re-entry is in progress (different from startup).
    /// Used by `windowDidFailToEnterFullScreen` to suppress retries during
    /// post-wake recovery — retrying a failed post-wake re-entry re-triggers
    /// the `_doFailedToEnterFullScreen` crash.
    private var isPostExitReentry = false

    /// Set to true while a display configuration change is in progress so
    /// deferred re-entry callbacks know to abort rather than firing into a
    /// menu-bar manager that is mid-cleanup.
    private var displayChangePending = false

    // MARK: - Startup retry (bounded + serialized)
    //
    // Crash path #4: at launch every window enters full-screen at once and one or
    // more report `windowDidFailToEnterFullScreen`. Each used to retry every
    // 0.5 s with no limit, firing `toggleFullScreen` into a transition that was
    // still in flight on another window; AppKit then crashed in
    // `_doSucceededToEnterFullScreen` and left an orphan "Nostromo" Space behind.
    // Retries are now capped per window, wait for any in-flight transition on a
    // sibling window, and back off.

    /// Windows currently mid enter/exit transition (app-wide).
    private static var transitioning = Set<ObjectIdentifier>()
    private static let maxStartupRetries = 2
    private var startupRetries = 0

    deinit { Self.transitioning.remove(ObjectIdentifier(self)) }

    private var inTransition: Bool { Self.transitioning.contains(ObjectIdentifier(self)) }

    /// Run `body` once no NostromoWindow is mid-transition, polling every 0.5 s
    /// for up to `budget` seconds; gives up (does nothing) past the budget.
    private static func whenIdle(budget: TimeInterval, _ body: @escaping () -> Void) {
        if transitioning.isEmpty { body(); return }
        guard budget > 0 else {
            winLog.warning("startup retry — gave up waiting for in-flight transitions")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            whenIdle(budget: budget - 0.5, body)
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        Self.transitioning.insert(ObjectIdentifier(self))
        winLog.info("windowWillEnterFullScreen — \(self.title, privacy: .public)")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.5
            animator().alphaValue = 1.0
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        winLog.info("windowDidEnterFullScreen — \(self.title, privacy: .public)")
        Self.transitioning.remove(ObjectIdentifier(self))
        startupRetries = 0
        isReenteringFullScreen = false
        isPostExitReentry      = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        Self.transitioning.remove(ObjectIdentifier(self))
        isReenteringFullScreen = false

        if isPostExitReentry {
            // This failure is from our post-wake re-entry attempt. The EXIT
            // controller is still cleaning up; retrying immediately re-triggers
            // the _doFailedToEnterFullScreen crash. Accept the windowed state —
            // the user can swipe/Mission-Control back to full-screen if needed.
            winLog.warning("windowDidFailToEnterFullScreen — post-exit re-entry failed, leaving windowed (\(window.title, privacy: .public))")
            isPostExitReentry = false
            return
        }

        // Startup failure: a window in the simultaneous multi-window sequence
        // occasionally fails. Retry — but only a couple of times, only once no
        // sibling is mid-transition, and with a growing delay.
        guard startupRetries < Self.maxStartupRetries else {
            winLog.warning("windowDidFailToEnterFullScreen — giving up after \(self.startupRetries) startup retries, leaving windowed (\(window.title, privacy: .public))")
            return
        }
        startupRetries += 1
        let delay = 1.0 * Double(startupRetries)
        winLog.warning("windowDidFailToEnterFullScreen — startup retry \(self.startupRetries)/\(Self.maxStartupRetries) in \(delay)s (\(window.title, privacy: .public))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
            Self.whenIdle(budget: 5) {
                guard let self, let window,
                      !window.styleMask.contains(.fullScreen), !self.inTransition else { return }
                winLog.warning("windowDidFailToEnterFullScreen — retrying toggleFullScreen for \(window.title, privacy: .public)")
                window.toggleFullScreen(nil)
            }
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        Self.transitioning.insert(ObjectIdentifier(self))
        winLog.warning("windowWillExitFullScreen — \(self.title, privacy: .public) — will re-enter after exit completes")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        Self.transitioning.remove(ObjectIdentifier(self))
        winLog.warning("windowDidExitFullScreen — \(self.title, privacy: .public) — scheduling re-entry")
        guard !isReenteringFullScreen else {
            winLog.warning("windowDidExitFullScreen — re-entry already in progress, skipping")
            return
        }
        isReenteringFullScreen = true
        isPostExitReentry      = true
        displayChangePending   = false

        // Watch for display configuration changes during the re-entry window.
        let observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.displayChangePending = true
            winLog.warning("windowDidExitFullScreen — display change detected during re-entry window")
        }

        // Wait 3 s before calling toggleFullScreen. Crash path #3 shows that
        // 0.6 s is insufficient — the EXIT controller's cleanup is still in
        // progress and the ENTER transition's failure handler crashes when it
        // references the stale EXIT controller. 3 s gives macOS enough runway
        // to complete all cleanup before we attempt re-entry.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            NotificationCenter.default.removeObserver(observer)
            guard let self, !self.styleMask.contains(.fullScreen) else {
                self?.isReenteringFullScreen = false
                self?.isPostExitReentry      = false
                return
            }
            guard !self.displayChangePending else {
                winLog.warning("windowDidExitFullScreen — aborting: display change in progress (\(self.title, privacy: .public))")
                self.isReenteringFullScreen = false
                // Re-attempt after the display change settles.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, !self.styleMask.contains(.fullScreen),
                          !self.isReenteringFullScreen else {
                        self?.isPostExitReentry = false
                        return
                    }
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
        Self.transitioning.remove(ObjectIdentifier(self))
        isReenteringFullScreen = false
        isPostExitReentry      = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isOrphanedByScreenRemoval {
            // Screen disconnected — allow this window to close without terminating.
            // AppDelegate.screensDidChange handles cleanup; we just let it go.
            winLog.info("windowShouldClose — orphaned by screen removal, allowing close (\(self.title, privacy: .public))")
            return true
        }
        // Traffic lights are hidden, but just in case: route close to quit.
        winLog.warning("windowShouldClose — routing to app terminate")
        NSApplication.shared.terminate(nil)
        return false
    }

    /// Set by AppDelegate.screensDidChange before calling close() on a window
    /// whose screen has disappeared. Prevents the close from terminating the app —
    /// disconnecting a monitor should remove that window, not quit Nostromo.
    var isOrphanedByScreenRemoval = false

    // Swallow Escape so it can't trigger a full-screen exit via cancelOperation.
    override func cancelOperation(_ sender: Any?) {
        winLog.debug("cancelOperation swallowed (Escape key)")
    }
}
