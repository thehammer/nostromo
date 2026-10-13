import AppKit

/// What the "Model…" menu item sends down the responder chain. `ReplInputBar` implements
/// it by opening its model popover.
@objc protocol ModelShortcutTarget {
    @objc func showModelPopover(_ sender: Any?)
}

/// ⇧⌘M: opens the model popup of the key window's input bar.
enum ModelShortcut {
    static let keyEquivalent = "m"
    static let modifierMask: NSEvent.ModifierFlags = [.command, .shift]
    static let menuTitle = "Model\u{2026}"

    static var action: Selector { #selector(ModelShortcutTarget.showModelPopover(_:)) }

    /// The menu item `AppDelegate` installs. Its target is nil, so the action walks the
    /// responder chain from the key window's first responder.
    static func makeMenuItem() -> NSMenuItem {
        NSMenuItem(title: "", action: nil, keyEquivalent: "")
    }
}

/// The model chip in the input bar. An `NSButton` that draws its own title with explicit
/// colours: a system-drawn bezel title follows the Mac's light/dark setting and is
/// invisible on this always-dark UI (#234).
///
/// (Skeleton: filled in by the implementation step of M2.)
final class ModelChip: NSButton {
    /// Title alpha for a fact, and for a pending or disabled chip.
    static let normalAlpha: CGFloat = 0.88
    static let pendingAlpha: CGFloat = 0.62

    /// The pill fill, drawn over the input bar's background.
    static let fillColor = NSColor.clear

    func apply(_ chip: ModelPresentation.Chip) {}
}
