import AppKit

// Bringing a focus up for the person: the window already showing it, or the window they clicked in, with the
// keyboard in the focus's input.

/// One window that can show a focus. `MainLayoutHost` is the real one; tests use fakes.
protocol FocusHostWindow: AnyObject {
    var nsWindow: NSWindow? { get }
    /// The focus this window is showing.
    var shownFocusTag: String? { get }
    func bringToFront()
    /// Switch this window to the open focus `tag`; false when there is no such focus yet.
    func switchTo(tag: String) -> Bool
    /// Make the focus's input the first responder; false when it is not on screen yet.
    func focusInput() -> Bool
}

final class FocusPresenter {
    /// Every app window that can show a focus.
    var hosts: () -> [FocusHostWindow]
    var activateApp: () -> Void
    /// Runs `work` after a delay: a focus a daemon just created may need a moment to appear. Tests run it at once.
    var later: (TimeInterval, @escaping () -> Void) -> Void
    /// How many times the switch and the input focus are retried while the focus is still arriving.
    var attempts = 20

    init(hosts: @escaping () -> [FocusHostWindow] = { FocusPresenter.liveHosts() },
         activateApp: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
         later: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.hosts = hosts
        self.activateApp = activateApp
        self.later = later
    }

    /// Show the focus `tag`: raise the window that already shows it, else switch the window the person clicked
    /// in (`origin`, or the key window). Either way the input gets the keyboard.
    ///
    /// The window is switched directly rather than through `focusSelectionRequests`, which picks the key
    /// window and can race the popover that was just closed.
    func show(tag: String, from origin: NSWindow?) {
        attempt(tag: tag, origin: origin, remaining: attempts, activated: false)
    }

    private func attempt(tag: String, origin: NSWindow?, remaining: Int, activated: Bool) {
        let all = hosts()
        let target: FocusHostWindow?
        if let shown = all.first(where: { $0.shownFocusTag == tag }) {
            ActivationAudit.note("authored-pr:present-focus-window")
            shown.bringToFront()
            target = shown
        } else {
            let clicked = all.first(where: { origin != nil && $0.nsWindow === origin })
                ?? all.first(where: { $0.nsWindow?.isKeyWindow == true })
            if let clicked, clicked.switchTo(tag: tag) {
                clicked.bringToFront()
                target = clicked
            } else {
                target = nil
            }
        }
        var activatedNow = activated
        if let target {
            // Once: a retry must not pull the app forward again after the person moved away.
            if !activated { activateApp(); activatedNow = true }
            if target.focusInput() { return }
        }
        guard remaining > 1 else { return }
        later(0.1) { [weak self] in
            self?.attempt(tag: tag, origin: origin, remaining: remaining - 1, activated: activatedNow)
        }
    }

    static func liveHosts() -> [FocusHostWindow] {
        NSApp.windows.compactMap { ($0.contentView as? MainLayout).map { MainLayoutHost(layout: $0) } }
    }
}

/// A `MainLayout` window as a `FocusHostWindow`.
final class MainLayoutHost: FocusHostWindow {
    private weak var layout: MainLayout?
    init(layout: MainLayout) { self.layout = layout }

    var nsWindow: NSWindow? { layout?.window }
    var shownFocusTag: String? { layout?.activeFocusTag }
    func bringToFront() {
        ActivationAudit.note("authored-pr:order-front")
        layout?.window?.makeKeyAndOrderFront(nil)
    }
    func switchTo(tag: String) -> Bool { layout?.showFocus(tag: tag) ?? false }
    func focusInput() -> Bool { layout?.focusInputBar() ?? false }
}
