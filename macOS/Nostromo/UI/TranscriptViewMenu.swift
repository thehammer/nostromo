import AppKit
import NostromoKit

/// What View ▸ Focus / Show All Activity (and the same two items in a fold row's context menu) send
/// down the responder chain. `ReplView` implements it, for its own focus. A change of mode only
/// changes how the transcript is shown: it is not a `HumanGesture`-gated act (like `ModelShortcut`),
/// and nothing about it reaches the agent (Claude's own `viewMode` is never sent).
@objc protocol TranscriptViewModeTarget {
    @objc func setTranscriptFocusMode(_ sender: Any?)
    @objc func setTranscriptAllActivityMode(_ sender: Any?)
    /// The pane's focus is in All activity (its effective mode: its own choice, else the default).
    @objc var transcriptShowsAllActivity: Bool { get }
}

/// The app-level handler of View ▸ Default for New Focuses: it acts on the global default, not on
/// a pane, so its items name it as their target instead of using the responder chain.
final class TranscriptDefaultModeHandler: NSObject, NSMenuItemValidation {
    /// Resolved when an item is used or validated, so building the menu never opens the shared store.
    private let store: () -> TranscriptFoldStore

    init(store: @escaping () -> TranscriptFoldStore) {
        self.store = store
    }

    /// `sender.representedObject` is the mode's raw value.
    @objc func setTranscriptDefaultMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = TranscriptViewMode(rawValue: raw) else { return }
        store().defaultMode = mode
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let raw = menuItem.representedObject as? String {
            menuItem.state = raw == store().defaultMode.rawValue ? .on : .off
        }
        return true
    }
}

/// The View menu (FV4): **Focus** ⌥⌘← and **Show All Activity** ⌥⌘→, a radio pair for the focused
/// pane's focus, and **Default for New Focuses ▸ Focus / All Activity** for the focuses that have
/// no choice of their own. Installed by `MainMenu.make`.
///
/// The pane items have no target: the action walks the responder chain from the key window's first
/// responder to the `ReplView` around it. Where focus is somewhere no transcript pane sits above
/// (a terminal pane, a list), `AppDelegate` catches the action and `target(in:)` picks the key
/// window's single visible `ReplView`; with none, or several, the items are disabled.
enum TranscriptViewMenu {
    static let menuTitle = "View"
    static let focusTitle = "Focus"
    static let allActivityTitle = "Show All Activity"
    static let defaultSubmenuTitle = "Default for New Focuses"
    static let defaultFocusTitle = "Focus"
    static let defaultAllActivityTitle = "All Activity"

    /// ⌥⌘← and ⌥⌘→.
    static let focusKeyEquivalent = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
    static let allActivityKeyEquivalent = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
    static let modifierMask: NSEvent.ModifierFlags = [.command, .option]

    static var focusAction: Selector { #selector(TranscriptViewModeTarget.setTranscriptFocusMode(_:)) }
    static var allActivityAction: Selector { #selector(TranscriptViewModeTarget.setTranscriptAllActivityMode(_:)) }
    static var defaultAction: Selector { #selector(TranscriptDefaultModeHandler.setTranscriptDefaultMode(_:)) }

    /// Insert the View menu between Edit and the menu after it (Terminal). `store` backs the
    /// Default submenu.
    static func install(in mainMenu: NSMenu, store: @autoclosure @escaping () -> TranscriptFoldStore = .shared) {
        let viewItem = NSMenuItem()
        viewItem.title = menuTitle
        let viewMenu = NSMenu(title: menuTitle)
        viewItem.submenu = viewMenu

        let focusItem = NSMenuItem(title: focusTitle, action: focusAction, keyEquivalent: focusKeyEquivalent)
        focusItem.keyEquivalentModifierMask = modifierMask
        viewMenu.addItem(focusItem)
        let allActivityItem = NSMenuItem(title: allActivityTitle, action: allActivityAction,
                                         keyEquivalent: allActivityKeyEquivalent)
        allActivityItem.keyEquivalentModifierMask = modifierMask
        viewMenu.addItem(allActivityItem)
        viewMenu.addItem(.separator())

        // The handler is the default items' target, which a menu item holds weakly: the View item holds it.
        let handler = TranscriptDefaultModeHandler(store: store)
        viewItem.representedObject = handler
        let defaultItem = NSMenuItem(title: defaultSubmenuTitle, action: nil, keyEquivalent: "")
        let defaultMenu = NSMenu(title: defaultSubmenuTitle)
        defaultItem.submenu = defaultMenu
        for (title, mode) in [(defaultFocusTitle, TranscriptViewMode.focus),
                              (defaultAllActivityTitle, TranscriptViewMode.allActivity)] {
            let item = NSMenuItem(title: title, action: defaultAction, keyEquivalent: "")
            item.target = handler
            item.representedObject = mode.rawValue
            defaultMenu.addItem(item)
        }
        viewMenu.addItem(defaultItem)

        let afterEdit = mainMenu.items.firstIndex { $0.submenu?.title == "Edit" }.map { $0 + 1 }
        mainMenu.insertItem(viewItem, at: afterEdit ?? mainMenu.items.count)
    }

    /// A separator, then Focus and Show All Activity, for a fold row's context menu. No key
    /// equivalents here (the main menu owns them); no target, so they act on the pane the row is in.
    static func appendModeItems(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: focusTitle, action: focusAction, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: allActivityTitle, action: allActivityAction, keyEquivalent: ""))
    }

    /// The visible transcript panes of `window`.
    static func targets(in window: NSWindow?) -> [TranscriptViewModeTarget & NSView] {
        var found: [TranscriptViewModeTarget & NSView] = []
        func walk(_ view: NSView) {
            if let pane = view as? (TranscriptViewModeTarget & NSView), !pane.isHiddenOrHasHiddenAncestor {
                found.append(pane)
                return
            }
            view.subviews.forEach(walk)
        }
        if let content = window?.contentView { walk(content) }
        return found
    }

    /// The pane the mode items act on in `window`: the one holding the keyboard focus, else the
    /// window's single visible pane (a terminal pane or a list has focus), else none.
    static func target(in window: NSWindow?) -> (TranscriptViewModeTarget & NSView)? {
        var view = window?.firstResponder as? NSView
        while let current = view {
            if let pane = current as? (TranscriptViewModeTarget & NSView) { return pane }
            view = current.superview
        }
        let visible = targets(in: window)
        return visible.count == 1 ? visible[0] : nil
    }

    /// Enable the item when there is a pane to act on, and set the radio state from its mode.
    static func validate(_ item: NSMenuItem, target: TranscriptViewModeTarget?) -> Bool {
        guard let target else {
            item.state = .off
            return false
        }
        if item.action == focusAction { item.state = target.transcriptShowsAllActivity ? .off : .on }
        if item.action == allActivityAction { item.state = target.transcriptShowsAllActivity ? .on : .off }
        return true
    }
}
