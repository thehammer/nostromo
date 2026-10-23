import AppKit
import NostromoKit
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

    /// `NSWindow` defaults `isReleasedWhenClosed` to true for windows made in code: `close()`
    /// then sends the window an extra `release`. The app holds these windows strongly
    /// (`windows`, `windowsByDisplayUUID`), so ARC already owns them and the extra release
    /// over-releases: the crash surfaces later, when an autorelease pool drains (crash
    /// report 2026-10-22 17:10, a display-removal close). This is the only designated init,
    /// so every `NostromoWindow` (and subclass) gets the flag cleared.
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Placement observer (set by AppDelegate). Receives screen / full-screen
    /// lifecycle events so the window's display can be verified. Observation only:
    /// it never changes what the safeguards below do.
    var lifecycleHandler: ((WindowLifecycleEvent) -> Void)?

    /// True for the real (always-full-screen) windows. The launch-smoke window — a
    /// fixed 1440x900 that must stay on a possibly small display — opts out.
    var allowsUnconstrainedFrame = true

    /// A window whose frame is `screen.frame` (it includes the menu-bar band, so it is
    /// taller than `visibleFrame`) gets "constrained" by AppKit, which can shove it onto
    /// the main display — notably for displays stacked above/left of main. Before
    /// full-screen the frame we ask for is the frame we get; once full-screen, AppKit owns it.
    ///
    /// Scoped to the placement phases only: a window left windowed after the controller
    /// gave up (it is `isMovable = false`) must still be pulled back on-screen by AppKit.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if Self.leavesFrameUnconstrained(allowsUnconstrainedFrame: allowsUnconstrainedFrame,
                                         isFullScreen: styleMask.contains(.fullScreen),
                                         phase: placementPhase) {
            return frameRect
        }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    /// Mirrors `WindowPlacementController`'s phase (set via `placementPhaseChanged`).
    var placementPhase: PlacementPhase = .idle

    /// `.idle` covers the initial `setFrame` at creation, before the controller begins.
    static func leavesFrameUnconstrained(allowsUnconstrainedFrame: Bool, isFullScreen: Bool,
                                         phase: PlacementPhase) -> Bool {
        guard allowsUnconstrainedFrame, !isFullScreen else { return false }
        switch phase {
        case .idle, .placing, .enteringFullScreen: return true
        case .exitingForRetry, .fullScreen, .gaveUp: return false
        }
    }

    /// Delay between `windowDidExitFullScreen` and the window's own re-entry toggle.
    /// 0.6 s was insufficient (crash path #3). The controller's post-exit re-placement
    /// must land comfortably before this.
    static let reentryDelay: TimeInterval = 3.0

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
    fileprivate static var transitioning = Set<ObjectIdentifier>()
    private static let maxStartupRetries = 2
    private var startupRetries = 0
    /// Set when startup retries are exhausted. The window stays windowed until
    /// the next time it becomes key (you came back to it), when it gets one
    /// fresh, serialized attempt — a locked or asleep display fails every
    /// attempt, and bounded retries alone would leave it windowed for good.
    private var gaveUpOnFullScreen = false

    deinit { Self.transitioning.remove(ObjectIdentifier(self)) }

    /// This window (not a sibling) is mid enter/exit transition.
    var isInTransition: Bool { Self.transitioning.contains(ObjectIdentifier(self)) }

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

    func windowDidBecomeKey(_ notification: Notification) {
        guard gaveUpOnFullScreen, !styleMask.contains(.fullScreen), !isInTransition else { return }
        gaveUpOnFullScreen = false
        startupRetries = 0
        winLog.warning("windowDidBecomeKey — retrying full-screen once after an earlier give-up (\(self.title, privacy: .public))")
        Self.whenIdle(budget: 5) { [weak self] in
            guard let self, !self.styleMask.contains(.fullScreen), !self.isInTransition else { return }
            guard !self.isPendingScreenRemoval else { self.fullScreenDeferredByPendingRemoval = true; return }
            self.toggleFullScreen(nil)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        lifecycleHandler?(.didChangeScreen)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        lifecycleHandler?(.willEnterFullScreen)
        Self.transitioning.insert(ObjectIdentifier(self))
        winLog.info("windowWillEnterFullScreen — \(self.title, privacy: .public)")
        // Set directly, not through `animator()`: a fade here runs under
        // NSAnimationManager, which KVO-observes the window. Full-screen entry
        // swaps windows underneath it (and we retry entry after display
        // sleep/wake), and on completion AppKit raised an NSException from
        // `-removeObserver:forKeyPath:` inside a display-link callback, which
        // aborted the app (crash report 2026-10-07 10:17).
        alphaValue = 1.0
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        lifecycleHandler?(.didEnterFullScreen)
        winLog.info("windowDidEnterFullScreen — \(self.title, privacy: .public)")
        Self.transitioning.remove(ObjectIdentifier(self))
        startupRetries = 0
        gaveUpOnFullScreen = false
        isReenteringFullScreen = false
        isPostExitReentry      = false
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        lifecycleHandler?(.didFailToEnterFullScreen)
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

        // A window whose display is gone starts no entry or retry; it resumes if the display returns.
        guard !isPendingScreenRemoval else {
            fullScreenDeferredByPendingRemoval = true
            return
        }

        // Startup failure: a window in the simultaneous multi-window sequence
        // occasionally fails. Retry — but only a couple of times, only once no
        // sibling is mid-transition, and with a growing delay.
        guard startupRetries < Self.maxStartupRetries else {
            winLog.warning("windowDidFailToEnterFullScreen — giving up after \(self.startupRetries) startup retries, leaving windowed until next activation (\(window.title, privacy: .public))")
            gaveUpOnFullScreen = true
            return
        }
        startupRetries += 1
        let delay = 1.0 * Double(startupRetries)
        winLog.warning("windowDidFailToEnterFullScreen — startup retry \(self.startupRetries)/\(Self.maxStartupRetries) in \(delay)s (\(window.title, privacy: .public))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
            Self.whenIdle(budget: 5) {
                guard let self, let window,
                      !window.styleMask.contains(.fullScreen), !self.isInTransition else { return }
                guard !self.isPendingScreenRemoval else { self.fullScreenDeferredByPendingRemoval = true; return }
                winLog.warning("windowDidFailToEnterFullScreen — retrying toggleFullScreen for \(window.title, privacy: .public)")
                window.toggleFullScreen(nil)
            }
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        lifecycleHandler?(.willExitFullScreen)
        Self.transitioning.insert(ObjectIdentifier(self))
        winLog.warning("windowWillExitFullScreen — \(self.title, privacy: .public) — will re-enter after exit completes")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        // Observation only: a wrong-display retry re-places the window ~1 s LATER
        // (deferred and re-verified by the controller, never inside this callback),
        // so the delayed re-entry below enters full-screen on the right display.
        lifecycleHandler?(.didExitFullScreen)
        Self.transitioning.remove(ObjectIdentifier(self))
        winLog.warning("windowDidExitFullScreen — \(self.title, privacy: .public) — scheduling re-entry")
        guard !isReenteringFullScreen else {
            winLog.warning("windowDidExitFullScreen — re-entry already in progress, skipping")
            return
        }
        // Its display is gone and the close is waiting out the grace: entering full-screen
        // now would build a Space on a display that is about to lose this window.
        guard !isPendingScreenRemoval else {
            winLog.warning("windowDidExitFullScreen — display removal pending, not re-entering (\(self.title, privacy: .public))")
            fullScreenDeferredByPendingRemoval = true
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
        scheduler.schedule(after: Self.reentryDelay) { [weak self] in
            NotificationCenter.default.removeObserver(observer)
            guard let self, !self.styleMask.contains(.fullScreen) else {
                self?.isReenteringFullScreen = false
                self?.isPostExitReentry      = false
                return
            }
            guard !self.isPendingScreenRemoval else {
                winLog.warning("windowDidExitFullScreen — display removal pending at re-entry time, not re-entering (\(self.title, privacy: .public))")
                self.fullScreenDeferredByPendingRemoval = true
                self.isReenteringFullScreen = false
                self.isPostExitReentry      = false
                return
            }
            guard !self.displayChangePending else {
                winLog.warning("windowDidExitFullScreen — aborting: display change in progress (\(self.title, privacy: .public))")
                self.isReenteringFullScreen = false
                // Re-attempt after the display change settles.
                self.scheduler.schedule(after: 2.0) { [weak self] in
                    guard let self, !self.styleMask.contains(.fullScreen),
                          !self.isReenteringFullScreen else {
                        self?.isPostExitReentry = false
                        return
                    }
                    guard !self.isPendingScreenRemoval else {
                        self.fullScreenDeferredByPendingRemoval = true
                        self.isPostExitReentry = false
                        return
                    }
                    winLog.warning("windowDidExitFullScreen — follow-up re-entry after display settle (\(self.title, privacy: .public))")
                    self.displayChangePending = false
                    self.lifecycleHandler?(.willReenterFullScreen)
                    self.toggleFullScreen(nil)
                }
                return
            }
            winLog.warning("windowDidExitFullScreen — calling toggleFullScreen to re-enter (\(self.title, privacy: .public))")
            self.lifecycleHandler?(.willReenterFullScreen)
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

    /// Everything that must be true before a window whose display is gone is closed:
    /// the orphan flag (so `windowShouldClose` lets the close through instead of
    /// terminating the app), no close animation, and no placement observer.
    func prepareForDisplayRemovalClose() {
        isOrphanedByScreenRemoval = true
        animationBehavior = .none
        lifecycleHandler = nil
    }

    /// Closes the window of a vanished display, full-screen or not.
    ///
    /// Never clears `.fullScreen` from `styleMask`: macOS 27 raises an uncaught
    /// NSGenericException ("NSWindowStyleMaskFullScreen cleared on a window outside of a
    /// full screen transition") for that, and the exception killed the whole app. A
    /// plain `close()` is the supported way to dismiss a full-screen window; the
    /// `_NSExitFullScreenTransitionController` crash it was once dropped to avoid is
    /// covered by closing only once this window's own transition has ended (the
    /// topology coordinator defers `attemptClose` for that) and by `prepareForDisplayRemovalClose`.
    ///
    /// `close()` still goes through the ObjC guard, so a throw on a future OS is logged
    /// and survived rather than fatal. Returns the caught exception, if any. Logs the
    /// exception name and `logContext` only — never the window title or the exception
    /// reason, which can embed window descriptions.
    @discardableResult
    func closeAfterDisplayRemoval(logContext: String) -> CaughtObjCException? {
        let caught = ObjCExceptionGuard.catching { close() }
        if let caught {
            winLog.error("closeAfterDisplayRemoval — close() raised \(caught.name, privacy: .public) and was contained (\(logContext, privacy: .public))")
        }
        return caught
    }

    /// Set while this window's display is gone and its close waits out the grace. Such a
    /// window starts no full-screen entry, retry or re-entry (it would build a Space on a
    /// display about to lose its window, and the close would then wait on that transition).
    /// Clearing it (the display returned) resumes any entry that was held back.
    var isPendingScreenRemoval = false {
        didSet {
            if oldValue, !isPendingScreenRemoval { resumeDeferredFullScreen() }
        }
    }

    /// An entry/re-entry/retry was suppressed by `isPendingScreenRemoval` and is owed.
    private var fullScreenDeferredByPendingRemoval = false

    /// The display came back: do the held-back entry, with the same runway as any
    /// post-exit re-entry (crash path #3).
    private func resumeDeferredFullScreen() {
        guard fullScreenDeferredByPendingRemoval, !isReenteringFullScreen else { return }
        fullScreenDeferredByPendingRemoval = false
        isReenteringFullScreen = true
        isPostExitReentry      = true
        scheduler.schedule(after: Self.reentryDelay) { [weak self] in
            guard let self else { return }
            guard !self.isPendingScreenRemoval, !self.styleMask.contains(.fullScreen), !self.isInTransition else {
                if self.isPendingScreenRemoval { self.fullScreenDeferredByPendingRemoval = true }
                self.isReenteringFullScreen = false
                self.isPostExitReentry      = false
                return
            }
            winLog.warning("resuming full-screen entry after a display removal was called off (\(self.title, privacy: .public))")
            self.lifecycleHandler?(.willReenterFullScreen)
            self.toggleFullScreen(nil)
        }
    }

    /// Times the post-exit re-entry; injected so tests need no wall clock.
    var scheduler: PlacementScheduler = MainQueueScheduler.shared

    // Swallow Escape so it can't trigger a full-screen exit via cancelOperation.
    override func cancelOperation(_ sender: Any?) {
        winLog.debug("cancelOperation swallowed (Escape key)")
    }
}

// MARK: - PlacementWindowing

extension NostromoWindow: PlacementWindowing {
    var currentDisplayUUID: String? { screen.flatMap { SystemScreenProvider.shared.displayKey(for: $0) } }

    var isDisplayChangePending: Bool { displayChangePending }

    func placementPhaseChanged(_ phase: PlacementPhase) { placementPhase = phase }

    var isFullScreen: Bool { styleMask.contains(.fullScreen) }

    var isAnyTransitionInFlight: Bool { !Self.transitioning.isEmpty }

    var placementSnapshot: String {
        let screenText = screen.flatMap { s in
            SystemScreenProvider.shared.displayKey(for: s).map { "\($0) (\(s.localizedName))" }
        } ?? "nil"
        return "frame=\(DisplayInfo.fmt(frame)) screen=\(screenText) fullScreen=\(isFullScreen) alpha=\(alphaValue)"
    }

    func place(on display: DisplayInfo) {
        setFrame(display.placementFrame, display: false)
    }

    func toggleFullScreenNow() {
        toggleFullScreen(nil)
    }
}
