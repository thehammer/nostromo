// T6: link chips on a tracker item. A PR, ticket or file chip asks the daemon to open it as a
// `nostromo.show` would (never the transcript); a URL chip goes to the browser through the pane's
// injected opener; a reference with no URL is plain text.
import AppKit
import NostromoKit

final class TrackerLinkChip: NSView {
    static let height: CGFloat = 15
    static let hPad: CGFloat = 5
    static let maxWidth: CGFloat = 180

    let link: TrackerLinkWire
    let action: TrackerLinkAction
    /// Called when the chip is clicked and has something to open.
    var onActivate: ((TrackerLinkAction) -> Void)?

    private let label: NSTextField

    init(link: TrackerLinkWire, index: Int, muted: NSColor) {
        self.link = link
        self.action = TrackerLinkAction.action(for: link, index: index)
        let actionable = action != .inert
        label = NSTextField(labelWithString: link.text)
        label.font = TrackerTheme.metaFont
        label.textColor = actionable ? Theme.cornflower : muted
        label.lineBreakMode = .byTruncatingTail
        label.refusesFirstResponder = true
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.badgeFill.cgColor
        layer?.cornerRadius = 7
        addSubview(label)
        toolTip = link.url ?? link.text
        setAccessibilityRole(actionable ? .button : .staticText)
        setAccessibilityLabel(link.text)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The chip's width: its text plus padding, never past the cap.
    var fittingWidth: CGFloat {
        min(ceil(label.intrinsicContentSize.width) + Self.hPad * 2, Self.maxWidth)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: Self.hPad, y: 0, width: max(bounds.width - Self.hPad * 2, 1), height: bounds.height)
    }

    override func resetCursorRects() {
        if action != .inert { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// The chip takes the click itself (its label would otherwise swallow it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard action != .inert else { return }
        onActivate?(action)
    }
}
