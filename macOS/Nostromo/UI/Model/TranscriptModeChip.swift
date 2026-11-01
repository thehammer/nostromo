import AppKit
import NostromoKit

/// The transcript view chip in the input bar (FV4): `Focus` or `All activity`, beside the model
/// chip. A sibling of `ModelChip` and `BackgroundChip`: an `NSButton` that draws its own title with
/// explicit colours (a system-drawn title follows the Mac's light/dark setting and goes dark-on-dark
/// on this always-dark UI, #234), same height, font, padding and fill, and its own focus ring.
///
/// It lives in a fixed-width slot (`slotWidth`, the wider title) the input bar reserves, so toggling
/// the mode never changes the composer's width. In a narrow pane the bar lets the slot give way
/// (after the background slot, before the model chip), and the label then truncates. A focus left in
/// All activity reads at a glance: its fill is a little brighter (`allActivityFillColor`).
///
/// Its title, label and tooltip are fixed strings: no transcript or agent text ever reaches it.
final class TranscriptModeChip: NSButton {

    static let height: CGFloat = ModelChip.height
    static let horizontalPadding: CGFloat = 9
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Title alpha: white on the fill over the input bar, ≥ 4.5:1 in both states (pinned in
    /// `TranscriptModeChipAppearanceTests`).
    static let titleAlpha: CGFloat = 0.88
    static let focusFillColor = ModelChip.fillColor
    /// The All activity fill: brighter than Focus's, still under the title at ≥ 4.5:1.
    static let allActivityFillColor = NSColor.white.withAlphaComponent(0.22)
    private static let pressedFillColor = NSColor.white.withAlphaComponent(0.30)

    /// The width the input bar reserves: the wider title in the chip font, plus padding.
    static let slotWidth: CGFloat = {
        let width = TranscriptViewMode.allCases
            .map { NSAttributedString(string: title(for: $0), attributes: [.font: font]).size().width }
            .max() ?? 0
        return ceil(width) + 2 * horizontalPadding
    }()

    static func title(for mode: TranscriptViewMode) -> String {
        switch mode {
        case .focus:       return "Focus"
        case .allActivity: return "All activity"
        }
    }

    static func accessibilityLabel(for mode: TranscriptViewMode) -> String {
        "Transcript view: \(title(for: mode))"
    }

    private static func tooltip(for mode: TranscriptViewMode) -> String {
        switch mode {
        case .focus:       return "Transcript view: Focus. Click to show all activity (\u{2325}\u{2318}\u{2192})."
        case .allActivity: return "Transcript view: All activity. Click to fold activity (\u{2325}\u{2318}\u{2190})."
        }
    }

    private(set) var mode: TranscriptViewMode = .focus
    /// The chip holds the keyboard focus (Tab). Drawn as a ring in `draw`, because the system's own
    /// ring is off: this control draws itself.
    private(set) var hasKeyboardFocus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        focusRingType = .none
        appearance = NSAppearance(named: .darkAqua)
        translatesAutoresizingMaskIntoConstraints = false
        refusesFirstResponder = false   // Tab reaches it
        // Its slot gives way in a narrow bar; a button's own 750 resistance would outrank that.
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        setAccessibilityRole(.button)
        apply(.focus)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `mode`: title, tooltip, accessibility label and fill. Never touches the first responder.
    func apply(_ mode: TranscriptViewMode) {
        self.mode = mode
        title = Self.title(for: mode)
        toolTip = Self.tooltip(for: mode)
        setAccessibilityLabel(Self.accessibilityLabel(for: mode))
        needsDisplay = true
    }

    /// The slot's width, whatever the mode; the bar may squeeze it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.slotWidth, height: Self.height)
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
        let fill = mode == .allActivity ? Self.allActivityFillColor : Self.focusFillColor
        (isHighlighted ? Self.pressedFillColor : fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: NSColor.white.withAlphaComponent(Self.titleAlpha),
            .paragraphStyle: paragraph,
        ])
        let inner = bounds.insetBy(dx: Self.horizontalPadding, dy: 0)
        let lineHeight = ceil(text.size().height)
        text.draw(in: NSRect(x: inner.minX, y: inner.midY - lineHeight / 2, width: max(inner.width, 0), height: lineHeight))
        if hasKeyboardFocus {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            NSColor.white.withAlphaComponent(Self.titleAlpha).setStroke()
            ring.stroke()
        }
    }
}
