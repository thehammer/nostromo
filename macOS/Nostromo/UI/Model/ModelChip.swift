import AppKit

/// What the "Model…" menu item sends down the responder chain. `ReplInputBar` implements
/// it by opening its model popover.
@objc protocol ModelShortcutTarget {
    @objc func showModelPopover(_ sender: Any?)
    /// False while the bar has no model chip to open from (no state, or nostromd unreachable).
    @objc var canShowModelPopover: Bool { get }
}

/// ⇧⌘M: opens the model popup of the key window's input bar.
enum ModelShortcut {
    static let keyEquivalent = "m"
    static let modifierMask: NSEvent.ModifierFlags = [.command, .shift]
    static let menuTitle = "Model\u{2026}"

    static var action: Selector { #selector(ModelShortcutTarget.showModelPopover(_:)) }

    /// The menu item `AppDelegate` installs. Its target is nil, so the action walks the
    /// responder chain from the key window's first responder to that window's input bar.
    static func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: menuTitle, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifierMask
        return item
    }

    /// The input bars of `window` that can open a popup, for the menu's fallback when the
    /// first responder is somewhere no bar sits above (a list, the transcript).
    static func bars(in window: NSWindow?) -> [ModelShortcutTarget & NSView] {
        var found: [ModelShortcutTarget & NSView] = []
        func walk(_ view: NSView) {
            if let bar = view as? (ModelShortcutTarget & NSView),
               bar.canShowModelPopover, !bar.isHiddenOrHasHiddenAncestor { found.append(bar) }
            view.subviews.forEach(walk)
        }
        if let content = window?.contentView { walk(content) }
        return found
    }

    /// The bar ⇧⌘M opens in `window`: the one the keyboard focus belongs to, else the first.
    /// Walking up from the first responder, the first container that holds a bar decides: a bar
    /// itself (focus in its text view), or the pane whose transcript has focus. In a window of
    /// several panes that is the pane in use, not whichever sits first in the view tree.
    static func bar(in window: NSWindow?) -> (ModelShortcutTarget & NSView)? {
        let eligible = bars(in: window)
        guard eligible.count > 1, let responder = window?.firstResponder as? NSView else { return eligible.first }
        var container: NSView? = responder
        while let view = container {
            let inside = eligible.filter { $0 === view || $0.isDescendant(of: view) }
            if let bar = inside.first { return bar }
            container = view.superview
        }
        return eligible.first
    }
}

/// The model chip in the input bar. An `NSButton` that draws its own title with explicit
/// colours: a system-drawn bezel title follows the Mac's light/dark setting and is
/// invisible on this always-dark UI (#234), and a window going inactive dims it further.
/// Nothing here reads the window's key state or the app's appearance.
final class ModelChip: NSButton {
    /// Title alpha for a fact, and for a pending, switching or disabled chip. White on the
    /// input bar's background: ≥ 4.5:1 in both (pinned in `ModelChipAppearanceTests`).
    static let normalAlpha: CGFloat = 0.88
    static let pendingAlpha: CGFloat = 0.62

    /// The pill fill, drawn over the input bar's background.
    static let fillColor = NSColor.white.withAlphaComponent(0.10)
    private static let pressedFillColor = NSColor.white.withAlphaComponent(0.18)

    static let height: CGFloat = 22
    private static let horizontalPadding: CGFloat = 9
    static let maxWidth: CGFloat = 190
    private static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    private(set) var chipStyle: ModelPresentation.ChipStyle = .normal
    /// The chip holds the keyboard focus (Tab with Full Keyboard Access). Drawn as a ring in
    /// `draw`, because the system's own ring is off: this control draws itself.
    private(set) var hasKeyboardFocus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        focusRingType = .none
        appearance = NSAppearance(named: .darkAqua)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show a presentation: title, tooltip, accessibility strings, style and enabled state.
    func apply(_ chip: ModelPresentation.Chip) {
        title = chip.title
        toolTip = chip.tooltip
        setAccessibilityLabel(chip.accessibilityLabel)
        setAccessibilityHelp(chip.accessibilityHint)
        chipStyle = chip.style
        isEnabled = chip.isEnabled
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let text = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        return NSSize(width: min(Self.maxWidth, text + 2 * Self.horizontalPadding), height: Self.height)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasKeyboardFocus = true; needsDisplay = true }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { hasKeyboardFocus = false; needsDisplay = true }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        // Deliberately no `super.draw`: the cell would draw the title in a system colour.
        let pill = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        (isHighlighted ? Self.pressedFillColor : Self.fillColor).setFill()
        pill.fill()

        let dimmed = chipStyle == .pending || !isEnabled
        let alpha = dimmed ? Self.pendingAlpha : Self.normalAlpha
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: NSColor.white.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ])
        if hasKeyboardFocus {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            NSColor.white.withAlphaComponent(Self.normalAlpha).setStroke()
            ring.stroke()
        }
        let inner = bounds.insetBy(dx: Self.horizontalPadding, dy: 0)
        let lineHeight = ceil(text.size().height)
        text.draw(in: NSRect(x: inner.minX, y: inner.midY - lineHeight / 2, width: inner.width, height: lineHeight))
    }
}
