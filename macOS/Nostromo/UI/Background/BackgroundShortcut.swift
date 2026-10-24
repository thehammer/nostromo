import AppKit

/// What the "Background Activity…" menu item sends down the responder chain. `ReplInputBar`
/// implements it by opening (or closing) its Background activity popover.
@objc protocol BackgroundShortcutTarget {
    @objc func showBackgroundPopover(_ sender: Any?)
    /// False while the bar has no session, or the daemon does not report background tasks.
    @objc var canShowBackgroundPopover: Bool { get }
}

/// ⇧⌘B: opens the Background activity popover of the focused pane's input bar, with the keyboard
/// in the list (an explicit keyboard intent). Routed like `ModelShortcut`.
enum BackgroundShortcut {
    static let keyEquivalent = "b"
    static let modifierMask: NSEvent.ModifierFlags = [.command, .shift]
    static let menuTitle = "Background Activity\u{2026}"

    static var action: Selector { #selector(BackgroundShortcutTarget.showBackgroundPopover(_:)) }

    /// The menu item `MainMenu` installs in the Session menu. No target: the action walks the
    /// responder chain from the key window's first responder to that window's input bar.
    static func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: menuTitle, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifierMask
        return item
    }

    /// The input bars of `window` that can open the popover.
    static func bars(in window: NSWindow?) -> [BackgroundShortcutTarget & NSView] {
        var found: [BackgroundShortcutTarget & NSView] = []
        func walk(_ view: NSView) {
            if let bar = view as? (BackgroundShortcutTarget & NSView),
               bar.canShowBackgroundPopover, !bar.isHiddenOrHasHiddenAncestor { found.append(bar) }
            view.subviews.forEach(walk)
        }
        if let content = window?.contentView { walk(content) }
        return found
    }

    /// The bar ⇧⌘B opens in `window`: the one the keyboard focus belongs to, else the first.
    /// Walking up from the first responder, the first container that holds a bar decides (the
    /// pane in use, not whichever sits first in the view tree).
    static func bar(in window: NSWindow?) -> (BackgroundShortcutTarget & NSView)? {
        let eligible = bars(in: window)
        guard eligible.count > 1, let responder = window?.firstResponder as? NSView else { return eligible.first }
        var container: NSView? = responder
        while let view = container {
            if let bar = eligible.first(where: { $0 === view || $0.isDescendant(of: view) }) { return bar }
            container = view.superview
        }
        return eligible.first
    }
}
