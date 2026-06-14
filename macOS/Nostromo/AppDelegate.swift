import AppKit
import os

private let appLog = Logger(subsystem: "com.hammer.nostromo.mac", category: "AppDelegate")

class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var windows: [NostromoWindow] = []
    private var windowsByScreenNumber: [Int: NostromoWindow] = [:]

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

        setupMenu()
        AppStore.shared.start()
        appLog.info("Opening windows for \(NSScreen.screens.count, privacy: .public) screen(s)")
        for (index, screen) in NSScreen.screens.enumerated() {
            openWindow(for: screen, index: index)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

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
        appLog.info("systemWillSleep — removing window animations")
        for win in windows {
            win.animationBehavior = .none
            win.contentView?.layer?.removeAllAnimations()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog.warning("applicationWillTerminate — saving state")
        FocusStore.shared.save()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appLog.info("applicationShouldHandleReopen — hasVisibleWindows=\(flag, privacy: .public) windowCount=\(self.windows.count, privacy: .public)")
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        appLog.warning("applicationShouldTerminateAfterLastWindowClosed — returning true, windowCount=\(self.windows.count, privacy: .public)")
        return true
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

        NSApplication.shared.mainMenu = mainMenu
    }

    private func openWindow(for screen: NSScreen, index: Int) {
        let win = NostromoWindow(
            contentRect: screen.frame,
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
        win.contentView = MainLayout(windowIndex: index)
        win.delegate = win

        // Position on the target screen before entering full-screen so the
        // Space is created on the right display.
        win.setFrameOrigin(screen.frame.origin)

        win.alphaValue = 0.0
        win.makeKeyAndOrderFront(nil)

        if !win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
        }

        windows.append(win)

        if let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? Int {
            windowsByScreenNumber[screenNumber] = win
        }
    }

    // MARK: - Screen change handling

    @objc private func screensDidChange(_ notification: Notification) {
        let currentScreenNumbers = Set(NSScreen.screens.compactMap {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int
        })

        // Close windows whose screen has disappeared.
        for (number, win) in windowsByScreenNumber where !currentScreenNumbers.contains(number) {
            win.close()
            windowsByScreenNumber.removeValue(forKey: number)
            windows.removeAll { $0 === win }
        }

        // Open windows for newly connected screens.
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? Int,
            windowsByScreenNumber[number] == nil else { continue }

            let index = windows.count
            openWindow(for: screen, index: index)
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NostromoWindow else { return }
        windows.removeAll { $0 === win }
        windowsByScreenNumber = windowsByScreenNumber.filter { $0.value !== win }
        appLog.warning("windowWillClose — remaining windows=\(self.windows.count, privacy: .public)")
    }
}
