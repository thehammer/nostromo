import AppKit
import UserNotifications
import os

private let appLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "AppDelegate")

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppAppearance.apply(to: NSApplication.shared)
    }

    private(set) var windows: [NostromoWindow] = []

    /// Every window is bound to ONE display, keyed by its stable display UUID
    /// (not `NSScreenNumber`, which can change across reconnects; not the window
    /// index). A display that reappears gets a window with the same UUID, and so
    /// the same remembered focus (`DisplayFocusKeys`).
    private var windowsByDisplayUUID: [String: NostromoWindow] = [:]
    private var placementControllers: [String: WindowPlacementController] = [:]

    private let screens: ScreenProviding = SystemScreenProvider.shared
    private let placementLog = WindowPlacementLog.shared
    /// Monotonic; reporting identity for the daemon (`window_id`), never a memory key.
    private var nextWindowIndex = 0
    /// False while the launch is waiting for slow displays: `screensDidChange`
    /// feeds the waiter instead of opening windows.
    private var launchWindowsOpened = false
    private var displayWaiter: DisplayAvailabilityWaiter?
    /// Records `LastKnownDisplayCount` only once the topology has been stable for a few seconds.
    private lazy var stableCountRecorder = StableDisplayCountRecorder(
        scheduler: MainQueueScheduler.shared,
        screenCount: { [screens] in screens.displays.count }
    )
    /// Turns raw `didChangeScreenParameters` into: nothing (unchanged topology), one
    /// debounced pass, and a close only after a vanished display stays gone for a grace.
    private lazy var topologyCoordinator = DisplayTopologyCoordinator(
        scheduler: MainQueueScheduler.shared,
        host: DisplayTopologyCoordinator.Host(
            attachedDisplays: { [screens] in screens.displays },
            boundUUIDs: { [weak self] in Set(self?.windowsByDisplayUUID.keys.map { $0 } ?? []) },
            topologyChanged: { [weak self] in
                self?.logTopology(scope: "screensDidChange")
                self?.stableCountRecorder.topologyChanged()
            },
            rehome: { [weak self] uuid in self?.placementControllers[uuid]?.displaysReconfigured() },
            openWindows: { [weak self] displays in self?.openWindowsForNewDisplays(displays) },
            closeWindow: { [weak self] uuid in self?.closeWindowForVanishedDisplay(uuid) },
            passFinished: { [weak self] in self?.closeUntrackedWindows() },
            log: { [weak self] message in self?.placementLog.log("screensDidChange", message) },
            driftedUUIDs: { [weak self] in self?.driftedWindowUUIDs() ?? [] },
            setPendingRemoval: { [weak self] uuid, pending in
                self?.windowsByDisplayUUID[uuid]?.isPendingScreenRemoval = pending
            },
            isWindowTransitioning: { [weak self] uuid in self?.windowsByDisplayUUID[uuid]?.isInTransition ?? false }
        )
    )
    /// Set when screen loss closed the last window (lid closed, no externals).
    /// The app must survive that and re-open windows when a display returns.
    private var lastWindowClosedByScreenLoss = false
    private var didShowSeparateSpacesBanner = false

    private static let displayWaitTimeout: TimeInterval = 5
    private static let staggerInterval: TimeInterval = 0.7

    func applicationDidFinishLaunching(_ notification: Notification) {
        appLog.info("applicationDidFinishLaunching — pid=\(ProcessInfo.processInfo.processIdentifier, privacy: .public) screens=\(NSScreen.screens.count, privacy: .public)")

        // Enforce single instance: if another Nostromo process is already running,
        // signal it to come forward and exit self.
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }

        if !others.isEmpty {
            appLog.warning("Another Nostromo already running (pid=\(others.first?.processIdentifier ?? -1, privacy: .public)) — activating it and quitting self")
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }

        // Set at launch, before anything can post: a notification delivered with no delegate
        // is shown by the system and its click goes nowhere (see `NeedsYouRouting`).
        UNUserNotificationCenter.current().delegate = self

        setupMenu()
        // The approval store listens from before the daemon connects: a permission request
        // is an event, and one that arrives with no listener is gone until the next snapshot.
        _ = ApprovalStore.shared
        AppStore.shared.start()
        AppStore.shared.startMemoryWatchdog()
        // The single app-wide owner of decision-modal presentation — started
        // once, here, so it's the ONLY subscriber to decision-request
        // broadcasts no matter how many windows this launch ends up opening
        // (see DecisionPresenter's header comment for why that matters).
        DecisionPresenter.shared.start()
        // Opt-in QA control socket (NOSTROMO_APP_CONTROL=1 or the AppControlEnabled default).
        AppControlServer.shared.startIfEnabled(appDelegate: self)
        TranscriptDiagnostics.startStreamingIfRequested()

        // Registered BEFORE any window opens: while the launch waits for slow
        // displays, `screensDidChange` is what feeds the waiter.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        logTopology(scope: "launch")

        // `NOSTROMO_WINDOW_MODE=smoke` (W1 — launch-smoke-test): open exactly
        // one window, for the main screen only, instead of one per attached
        // display. Unset (the default) is byte-identical to today's
        // behaviour — every other launch path is untouched.
        if ProcessInfo.processInfo.environment["NOSTROMO_WINDOW_MODE"] == "smoke" {
            appLog.info("NOSTROMO_WINDOW_MODE=smoke — opening a single non-key window")
            launchWindowsOpened = true
            if let screen = NSScreen.main, let display = DisplayInfo(screen: screen) {
                openWindow(for: display, staggerDelay: 0, smoke: true)
            } else {
                appLog.error("NOSTROMO_WINDOW_MODE=smoke but NSScreen.main is nil — no window opened")
            }
        } else {
            let displays = screens.displays
            // NOTE: the legacy focus-key migration runs in `openLaunchWindows`, AFTER any
            // display wait, so it never sees a partial display set first.
            let expected = LastKnownDisplayCount.load()
            if displays.count < expected {
                // Externals still enumerating: wait (bounded) instead of piling
                // every window onto the laptop. `screensDidChange` feeds the waiter.
                placementLog.log("launch", "only \(displays.count) of last-known \(expected) display(s) attached — waiting up to \(Int(Self.displayWaitTimeout)) s", warning: true)
                displayWaiter = DisplayAvailabilityWaiter(
                    expected: expected,
                    timeout: Self.displayWaitTimeout,
                    scheduler: MainQueueScheduler.shared,
                    screenCount: { NSScreen.screens.count }
                ) { [weak self] reached in
                    self?.displayWaiter = nil
                    self?.placementLog.log("launch", reached ? "expected displays attached" : "display wait timed out", warning: !reached)
                    self?.openLaunchWindows(topologyKnown: reached)
                }
            } else {
                openLaunchWindows()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Quiesce all window animations before sleep so AppKit's internal
        // scene/transition cleanup (NSScrubberChangeTransition et al.) doesn't
        // race with in-flight CALayer animations and produce a use-after-free.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep(_ note: Notification) {
        // Set animationBehavior = .none so no new animations start during sleep.
        // Do NOT call removeAllAnimations() — forcibly removing in-flight animations
        // leaves NSAnimationManager's KVO observers dangling, which causes a
        // SIGABRT in the display link callback on wake.
        appLog.info("systemWillSleep — disabling window animation behavior")
        for win in windows {
            win.animationBehavior = .none
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog.warning("applicationWillTerminate — saving state")
        FocusStore.shared.save()
        TeriSentryTab.tracker.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appLog.info("applicationShouldHandleReopen — hasVisibleWindows=\(flag, privacy: .public) windowCount=\(self.windows.count, privacy: .public)")
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the last window by hand routes to terminate in `windowShouldClose`,
        // so the only close that reaches here without quitting is the orphan close
        // when every display vanished (lid closed, no externals). That must NOT quit:
        // the displays come back and `screensDidChange` re-opens the windows.
        let terminate = !lastWindowClosedByScreenLoss
        appLog.warning("applicationShouldTerminateAfterLastWindowClosed — returning \(terminate, privacy: .public), windowCount=\(self.windows.count, privacy: .public)")
        return terminate
    }

    // MARK: - Debug

    @objc private func copyTranscriptDiagnostics() {
        TranscriptDiagnostics.copyReportToPasteboard()
    }

    @objc private func copyDaemonDiagnostics() {
        DaemonDiagnostics.copyReportToPasteboard()
    }

    @objc private func copyCodePaneDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AppStore.shared.codePaneDiagnosticsReport(), forType: .string)
        appLog.info("code-pane diagnostics copied to pasteboard")
    }

    /// Debug ▸ Capture render state now: the same content-free capture the blank detector writes by
    /// itself, for every transcript pane on screen, right away (no rate limit). Press it the moment a
    /// pane blanks if nothing was captured: the recorder already holds the seconds before.
    @objc private func captureRenderStateNow() {
        let files = PaneRenderWatch.captureAllVisible()
        appLog.info("render state captured for \(files.count, privacy: .public) pane(s)")
        guard !files.isEmpty else { NSSound.beep(); return }
        // The paths on the pasteboard, ready to send.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func copyPaneDiagnostics() {
        let report = AppStore.shared.paneDiagnosticsReport()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
        appLog.info("pane diagnostics copied to pasteboard")
    }

    // MARK: - Private

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(
            title: "Quit Nostromo",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        // Edit menu — required for Cmd+C/V/A/X to route correctly to NSTextView
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))

        // Debug menu — the app's answer to "is it holding more than it should?"
        // without attaching a debugger. Several acceptance criteria for the
        // bounded-transcript work are numeric, and a number nobody can read is
        // not a criterion.
        let debugMenuItem = NSMenuItem()
        mainMenu.addItem(debugMenuItem)
        let debugMenu = NSMenu(title: "Debug")
        debugMenuItem.submenu = debugMenu
        let diagItem = NSMenuItem(title: "Copy transcript diagnostics",
                                  action: #selector(copyTranscriptDiagnostics),
                                  keyEquivalent: "d")
        diagItem.keyEquivalentModifierMask = [.command, .shift]
        diagItem.target = self
        debugMenu.addItem(diagItem)
        let daemonDiagItem = NSMenuItem(title: "Copy daemon diagnostics",
                                        action: #selector(copyDaemonDiagnostics),
                                        keyEquivalent: "i")
        daemonDiagItem.keyEquivalentModifierMask = [.command, .shift]
        daemonDiagItem.target = self
        debugMenu.addItem(daemonDiagItem)
        let codePaneDiagItem = NSMenuItem(title: "Copy code-pane diagnostics",
                                          action: #selector(copyCodePaneDiagnostics),
                                          keyEquivalent: "k")
        codePaneDiagItem.keyEquivalentModifierMask = [.command, .shift]
        codePaneDiagItem.target = self
        debugMenu.addItem(codePaneDiagItem)
        let paneDiagItem = NSMenuItem(title: "Copy pane diagnostics",
                                      action: #selector(copyPaneDiagnostics),
                                      keyEquivalent: "p")
        paneDiagItem.keyEquivalentModifierMask = [.command, .shift]
        paneDiagItem.target = self
        debugMenu.addItem(paneDiagItem)
        let captureItem = NSMenuItem(title: "Capture render state now",
                                     action: #selector(captureRenderStateNow),
                                     keyEquivalent: "b")
        captureItem.keyEquivalentModifierMask = [.command, .shift]
        captureItem.target = self
        debugMenu.addItem(captureItem)

        // Session menu — ⇧⌘M opens the model popup. The item has no target, so the action
        // walks the responder chain from the key window's first responder to that window's
        // input bar; `showModelPopover` below catches it when focus sits outside any bar.
        let sessionMenuItem = NSMenuItem()
        mainMenu.addItem(sessionMenuItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionMenuItem.submenu = sessionMenu
        sessionMenu.addItem(ModelShortcut.makeMenuItem())

        NSApplication.shared.mainMenu = mainMenu
    }

    /// ⇧⌘M with focus outside every input bar (a list, the transcript): open the key
    /// window's bar. A bar that holds focus handles the action itself, before this.
    @objc func showModelPopover(_ sender: Any?) {
        ModelShortcut.bar(in: NSApp.keyWindow)?.showModelPopover(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == ModelShortcut.action ? !ModelShortcut.bars(in: NSApp.keyWindow).isEmpty : true
    }

    /// Open one window per attached display, then activate ONCE at the end
    /// (windows are only ordered front while being placed, so activation can't
    /// drag them toward the key screen mid-placement).
    private func openLaunchWindows(topologyKnown: Bool = true) {
        launchWindowsOpened = true
        let displays = screens.displays
        placementLog.log("launch", "opening windows for \(displays.count) display(s)")
        migrateLegacyFocusKeys(onto: displays)
        // The topology the launch windows are opened for: the first notification
        // after launch is only a change if it differs from this.
        topologyCoordinator.recordHandled(displays)
        stableCountRecorder.launchWindowsOpened(topologyKnown: topologyKnown)
        for (slot, display) in displays.enumerated() {
            openWindow(for: display, staggerDelay: Self.staggerInterval * Double(slot))
        }
        NSApp.activate(ignoringOtherApps: true)
        // Key window: the menu-bar display's (`NSScreen.screens.first`, which `isMain` now means).
        if let keyUUID = (displays.first { $0.isMain } ?? displays.first)?.uuid {
            windowsByDisplayUUID[keyUUID]?.makeKeyAndOrderFront(nil)
        }
        for (uuid, win) in windowsByDisplayUUID {
            placementLog.log(windowScope(uuid), "after activate: \(win.placementSnapshot)")
        }
        warnIfScreensShareSpaces()
    }

    private func windowScope(_ uuid: String) -> String {
        "win → \(uuid)"
    }

    /// Idempotent (per-index consumed flags): safe to run whenever displays are
    /// (re)enumerated, and must run BEFORE the windows that read the keys are created.
    private func migrateLegacyFocusKeys(onto displays: [DisplayInfo]) {
        let migrated = DisplayFocusKeys.migrateLegacyKeys(onto: displays)
        if migrated > 0 {
            placementLog.log("launch", "migrated \(migrated) legacy window-index focus key(s) onto displays (index order = NSScreen.screens order)")
        }
    }

    /// Close a window that has no live placement controller. Such a window would stay
    /// `alphaValue = 0` and windowed forever; closing is safe (it is not full-screen, and
    /// a full-screen one is closed like screen removal, with the same transition rule: see
    /// `closeAfterDisplayRemoval`).
    private func closeUntrackedWindow(_ win: NostromoWindow, reason: String) {
        placementLog.log("windows", "closing untracked window '\(win.title)': \(reason)", warning: true)
        let index = windows.firstIndex { $0 === win }
        win.prepareForDisplayRemovalClose()
        windows.removeAll { $0 === win }
        win.closeAfterDisplayRemoval(logContext: "untracked window \(index.map(String.init) ?? "?")")
    }

    private func logTopology(scope: String) {
        let displays = screens.displays
        placementLog.log(scope, "\(displays.count) display(s); NSScreen.screensHaveSeparateSpaces=\(screens.screensHaveSeparateSpaces)")
        for display in displays { placementLog.log(scope, display.logDescription) }
    }

    /// Per-display full-screen Spaces cannot work when "Displays have separate
    /// Spaces" is off: log loudly and tell the user once, non-modally.
    private func warnIfScreensShareSpaces() {
        guard !screens.screensHaveSeparateSpaces, !didShowSeparateSpacesBanner else { return }
        didShowSeparateSpacesBanner = true
        placementLog.log("launch", "WARNING: 'Displays have separate Spaces' is OFF — each display cannot get its own full-screen Space. Enable it in System Settings > Desktop & Dock, then log out and back in.", warning: true)
        // Let the first window finish its layout/transition before the toast appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let layout = self?.windows.first?.contentView as? MainLayout else { return }
            layout.showBanner(
                message: "Displays don't have separate Spaces — enable it in System Settings > Desktop & Dock, then log out/in.",
                severity: .warning
            )
        }
    }

    private func openWindow(for display: DisplayInfo, staggerDelay: TimeInterval, smoke: Bool = false) {
        // One window per key. A bound key must never be overwritten: the displaced window
        // would lose its controller and sit invisible (alpha 0) and windowed forever.
        guard windowsByDisplayUUID[display.uuid] == nil else {
            placementLog.log("launch", "display key \(display.uuid) already has a window — not opening a second", warning: true)
            return
        }
        let index = nextWindowIndex
        nextWindowIndex += 1
        lastWindowClosedByScreenLoss = false
        let scope = "win#\(index) → \(display.uuid)"

        // Smoke mode uses a fixed 1440x900 content frame rather than the
        // screen's frame — a real, on-screen size a `NSSplitView` can lay
        // out at, without taking over the whole display.
        // Otherwise the frame is the display's `visibleFrame` (inside the
        // menu-bar band), so AppKit has no reason to constrain it elsewhere.
        let contentRect = smoke
            ? NSRect(x: display.frame.origin.x, y: display.frame.origin.y, width: 1440, height: 900)
            : display.placementFrame
        let win = NostromoWindow(
            contentRect: contentRect,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true

        win.collectionBehavior = [.fullScreenPrimary, .managed]
        win.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 1.0)
        win.isMovable = false
        // Window restoration must never override the origin we place at.
        win.isRestorable = false
        // Smoke keeps AppKit's normal frame constraining (small/headless displays).
        win.allowsUnconstrainedFrame = !smoke
        win.contentView = MainLayout(windowIndex: index, displayUUID: display.uuid)
        win.delegate = win

        placementLog.log(scope, "created: target=\(display.logDescription) requested=\(DisplayInfo.fmt(contentRect)) → \(win.placementSnapshot)")

        // Position on the target screen before entering full-screen so the
        // Space is created on the right display.
        if smoke {
            win.setFrameOrigin(contentRect.origin)
        } else {
            win.setFrame(display.placementFrame, display: false)
        }
        placementLog.log(scope, "after setFrame: \(win.placementSnapshot)")

        win.alphaValue = 0.0

        if smoke {
            // Ordered in, never made key — focus is not stolen from
            // whatever the operator is doing — and never full-screened.
            // `windowWillEnterFullScreen`'s fade to alpha 1.0
            // (NostromoWindow.swift) is never reached, so the window stays
            // fully transparent: laid out and on screen, invisible to the
            // operator. See docs/diagnostics.md for the residual this
            // accepts (no full-screen transition is exercised) and the
            // empirical check the plan required before landing this.
            win.orderFront(nil)
        } else {
            // Ordered front WITHOUT activating: activation is done once, after
            // every window is placed, so it can't pull a window toward the key screen.
            win.orderFront(nil)
            placementLog.log(scope, "after orderFront: \(win.placementSnapshot)")

            let controller = WindowPlacementController(
                window: win, targetUUID: display.uuid, screens: screens
            ) { [placementLog] message, warning in
                placementLog.log(scope, message, warning: warning)
            }
            placementControllers[display.uuid] = controller
            win.lifecycleHandler = { [weak controller] event in controller?.windowEvent(event) }
            // Stagger: entering full-screen on every display in the same instant
            // is what makes a window fail (and its retry crash AppKit). One
            // window per 0.7 s keeps transitions from overlapping. `begin()`
            // verifies the placement, then toggles full-screen.
            MainQueueScheduler.shared.schedule(after: staggerDelay) { [weak self, weak controller, weak win] in
                guard let win else { return }
                guard let controller, self?.placementControllers[display.uuid] === controller else {
                    self?.closeUntrackedWindow(win, reason: "no live placement controller for \(display.uuid)")
                    return
                }
                controller.begin()
            }
        }

        windows.append(win)
        windowsByDisplayUUID[display.uuid] = win
    }

    // MARK: - Screen change handling

    @objc private func screensDidChange(_ notification: Notification) {
        guard launchWindowsOpened else {
            logTopology(scope: "screensDidChange")
            displayWaiter?.screensChanged()
            return
        }
        // Does no work here: the coordinator debounces the burst, then handles the
        // settled topology once (and not at all if it equals the last handled one).
        topologyCoordinator.displaysChanged()
    }

    /// Open windows for newly connected or REconnected displays, bound to the same
    /// UUID (so they recover their remembered focus), through the same
    /// verified-placement path as launch. A base delay lets the topology settle.
    private func openWindowsForNewDisplays(_ displays: [DisplayInfo]) {
        migrateLegacyFocusKeys(onto: screens.displays)
        for (slot, display) in displays.enumerated() {
            placementLog.log("screensDidChange", "display \(display.uuid) attached — opening window")
            openWindow(for: display, staggerDelay: Self.staggerInterval * Double(slot + 1))
        }
    }

    /// Keys whose window is on a different display than its own (macOS moved it).
    private func driftedWindowUUIDs() -> Set<String> {
        Set(windowsByDisplayUUID.compactMap { uuid, win in
            guard let current = win.currentDisplayUUID, current != uuid else { return nil }
            return uuid
        })
    }

    /// Close the window of a display that stayed gone for the whole grace period (the
    /// coordinator has already waited out the window's own transition and checked the
    /// display is still gone). Marks it orphaned first so windowShouldClose allows the
    /// close without terminating the app, and disables animations. A settled full-screen window
    /// is closed as-is (clearing `.fullScreen` outside a transition throws on macOS 27); one
    /// still mid-transition gets the bit cleared first (see `NostromoWindow.closeAfterDisplayRemoval`).
    /// The order of the steps is `VanishedWindowTeardown`'s contract (unbind before any AppKit call).
    private func closeWindowForVanishedDisplay(_ uuid: String) {
        guard let win = windowsByDisplayUUID[uuid] else { return }
        let logContext = "window \(windows.firstIndex { $0 === win }.map(String.init) ?? "?"), display \(uuid.prefix(8))"
        VanishedWindowTeardown.run(.init(
            unbindKey: { [self] in windowsByDisplayUUID.removeValue(forKey: uuid) },
            dropController: { [self] in placementControllers.removeValue(forKey: uuid) },
            removeFromWindows: { [self] in windows.removeAll { $0 === win } },
            afterUnbind: { [self] in
                // A momentarily empty topology (lid closed, no externals) closes every
                // window but must not quit the app — see applicationShouldTerminateAfterLastWindowClosed.
                if windowsByDisplayUUID.isEmpty { lastWindowClosedByScreenLoss = true }
                appLog.info("screensDidChange — display \(uuid, privacy: .public) removed, closing orphaned window '\(win.title, privacy: .public)'")
                placementLog.log("screensDidChange", "display \(uuid) removed — closing its window")
            },
            prepareWindow: { win.prepareForDisplayRemovalClose() },
            close: { win.closeAfterDisplayRemoval(logContext: logContext) }
        ))
    }

    /// Safety net: any window without a bound controller is invisible and useless.
    private func closeUntrackedWindows() {
        for win in windows where !placementControllers.keys.contains(where: { windowsByDisplayUUID[$0] === win }) {
            if win.allowsUnconstrainedFrame { closeUntrackedWindow(win, reason: "not bound to a controller") }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NostromoWindow else { return }
        windows.removeAll { $0 === win }
        TeriSentryTab.tracker.flush()
        let closedUUIDs = windowsByDisplayUUID.filter { $0.value === win }.map(\.key)
        for uuid in closedUUIDs {
            windowsByDisplayUUID.removeValue(forKey: uuid)
            placementControllers.removeValue(forKey: uuid)
        }
        appLog.warning("windowWillClose — remaining windows=\(self.windows.count, privacy: .public)")
    }
}

// MARK: - "Needs you" notifications

/// Clicks on, and presentation of, the notifications `NeedsYouNotifier` posts. What a
/// notification says is decided in NostromoKit; where a click goes is `NeedsYouRouting`.
extension AppDelegate: UNUserNotificationCenterDelegate {

    /// A click on the notification (never an arrival) is the only thing that brings the app
    /// forward for a "needs you" item: it is a user act, so activating is allowed here.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Another producer's items route to their focus once a router exists (AP3); for now the
        // app just comes forward.
        NeedsYouRouting.route(userInfo: response.notification.request.content.userInfo)
    }

    /// While the app is active, show a banner only if the operator is not already looking at the
    /// Mother view in the key window (the item is on screen there).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(Self.motherViewIsVisible(in: NSApp.keyWindow?.contentView) ? [] : [.banner])
    }

    private static func motherViewIsVisible(in view: NSView?) -> Bool {
        guard let view else { return false }
        if view is MotherView { return !view.isHiddenOrHasHiddenAncestor }
        return view.subviews.contains { motherViewIsVisible(in: $0) }
    }
}
