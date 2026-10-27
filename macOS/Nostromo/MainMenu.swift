import AppKit

/// What the main menu's Debug and Session items do; `AppDelegate` is the app's one implementation.
/// A protocol so the menu can be built (and its key equivalents read) without an app delegate.
@objc protocol MainMenuActions: AnyObject {
    func copyTranscriptDiagnostics()
    func copyDaemonDiagnostics()
    func copyCodePaneDiagnostics()
    func copyPaneDiagnostics()
    func captureRenderStateNow()
    func goToApprovalCard(_ sender: Any?)
    func newTerminal(_ sender: Any?)
    func closeTerminalPane(_ sender: Any?)
    func terminalFind(_ sender: Any?)
    func copyTerminalLatencyStats()
}

enum MainMenu {

    /// The main menu `setupMenu()` installs. `target` is what the Debug and Approval Card items
    /// act on (the delegate); tests that only read the menu's key equivalents pass nil.
    static func make(target: AnyObject?) -> NSMenu {
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
        // Find acts on a terminal pane only: the items target the app delegate, which enables them (and
        // forwards the action to SwiftTerm's find bar) only while a terminal pane holds the keyboard.
        // They are not first-responder actions on purpose: an NSTextView (the REPL's input and
        // transcript) would otherwise answer `performFindPanelAction:` and open a find panel it never had.
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(title: "Find\u{2026}", action: #selector(MainMenuActions.terminalFind(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        findItem.target = target
        editMenu.addItem(findItem)
        let findNextItem = NSMenuItem(title: "Find Next", action: #selector(MainMenuActions.terminalFind(_:)), keyEquivalent: "g")
        findNextItem.tag = NSTextFinder.Action.nextMatch.rawValue
        findNextItem.target = target
        editMenu.addItem(findNextItem)

        // Terminal menu: ⌘T opens a shell in the key window's focus; ⇧⌘W closes the terminal pane that
        // holds the keyboard (only for a person: the item does nothing for a synthetic key or click).
        let terminalMenuItem = NSMenuItem()
        mainMenu.addItem(terminalMenuItem)
        let terminalMenu = NSMenu(title: "Terminal")
        terminalMenuItem.submenu = terminalMenu
        let newTerminalItem = NSMenuItem(title: "New Terminal", action: #selector(MainMenuActions.newTerminal(_:)),
                                         keyEquivalent: "t")
        newTerminalItem.target = target
        terminalMenu.addItem(newTerminalItem)
        let closeTerminalItem = NSMenuItem(title: "Close Terminal Pane", action: #selector(MainMenuActions.closeTerminalPane(_:)),
                                           keyEquivalent: "w")
        closeTerminalItem.keyEquivalentModifierMask = [.command, .shift]
        closeTerminalItem.target = target
        terminalMenu.addItem(closeTerminalItem)

        // Debug menu — the app's answer to "is it holding more than it should?"
        // without attaching a debugger. Several acceptance criteria for the
        // bounded-transcript work are numeric, and a number nobody can read is
        // not a criterion.
        let debugMenuItem = NSMenuItem()
        mainMenu.addItem(debugMenuItem)
        let debugMenu = NSMenu(title: "Debug")
        debugMenuItem.submenu = debugMenu
        let diagItem = NSMenuItem(title: "Copy transcript diagnostics",
                                  action: #selector(MainMenuActions.copyTranscriptDiagnostics),
                                  keyEquivalent: "d")
        diagItem.keyEquivalentModifierMask = [.command, .shift]
        diagItem.target = target
        debugMenu.addItem(diagItem)
        let daemonDiagItem = NSMenuItem(title: "Copy daemon diagnostics",
                                        action: #selector(MainMenuActions.copyDaemonDiagnostics),
                                        keyEquivalent: "i")
        daemonDiagItem.keyEquivalentModifierMask = [.command, .shift]
        daemonDiagItem.target = target
        debugMenu.addItem(daemonDiagItem)
        let codePaneDiagItem = NSMenuItem(title: "Copy code-pane diagnostics",
                                          action: #selector(MainMenuActions.copyCodePaneDiagnostics),
                                          keyEquivalent: "k")
        codePaneDiagItem.keyEquivalentModifierMask = [.command, .shift]
        codePaneDiagItem.target = target
        debugMenu.addItem(codePaneDiagItem)
        let paneDiagItem = NSMenuItem(title: "Copy pane diagnostics",
                                      action: #selector(MainMenuActions.copyPaneDiagnostics),
                                      keyEquivalent: "p")
        paneDiagItem.keyEquivalentModifierMask = [.command, .shift]
        paneDiagItem.target = target
        debugMenu.addItem(paneDiagItem)
        let terminalLatencyItem = NSMenuItem(title: "Copy terminal latency stats",
                                             action: #selector(MainMenuActions.copyTerminalLatencyStats),
                                             keyEquivalent: "")
        terminalLatencyItem.target = target
        debugMenu.addItem(terminalLatencyItem)
        // ⌥⇧⌘B: ⇧⌘B is the Session menu's Background Activity (BA3).
        let captureItem = NSMenuItem(title: "Capture render state now",
                                     action: #selector(MainMenuActions.captureRenderStateNow),
                                     keyEquivalent: "b")
        captureItem.keyEquivalentModifierMask = [.command, .shift, .option]
        captureItem.target = target
        debugMenu.addItem(captureItem)

        // Session menu — ⇧⌘M opens the model popup. The item has no target, so the action
        // walks the responder chain from the key window's first responder to that window's
        // input bar; `showModelPopover` below catches it when focus sits outside any bar.
        let sessionMenuItem = NSMenuItem()
        mainMenu.addItem(sessionMenuItem)
        let sessionMenu = NSMenu(title: "Session")
        sessionMenuItem.submenu = sessionMenu
        sessionMenu.addItem(ModelShortcut.makeMenuItem())
        // ⇧⌘B: the focused pane's Background activity popover, keyboard in the list (BA3). Routed
        // like ⇧⌘M; `AppDelegate.showBackgroundPopover` catches it when focus sits outside any bar.
        sessionMenu.addItem(BackgroundShortcut.makeMenuItem())
        // ⌥⌘A: move keyboard focus into the visible approval card (AP3). No visible card: a beep.
        let approvalCardItem = NSMenuItem(title: "Go to Approval Card", action: #selector(MainMenuActions.goToApprovalCard(_:)),
                                          keyEquivalent: "a")
        approvalCardItem.keyEquivalentModifierMask = [.command, .option]
        approvalCardItem.target = target
        sessionMenu.addItem(approvalCardItem)

        return mainMenu
    }
}
