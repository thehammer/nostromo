import AppKit
import NostromoKit

/// The Background activity chip in the input bar (BA3): `◷ 2 running`, `✓ 3 done`, `✕ 1 failed`, or
/// hidden. A sibling of `ModelChip`: an `NSButton` that draws its own title with explicit colours
/// (a system-drawn title follows the Mac's light/dark setting and goes dark-on-dark here, #234),
/// same height, font, padding and fill, and its own focus ring.
///
/// It lives right-aligned in a slot (`slotWidth` wide when there is room) the input bar reserves, so
/// a chip appearing, changing or going never changes the composer's width (contract §2.7). In a
/// narrow pane the bar gives the slot up before it shrinks the composer, and the chip follows its
/// slot: the whole text, then the icon alone (`Fit.iconOnly`), then nothing (`Fit.hidden`). Updating
/// it never moves the keyboard focus: `apply` only sets text and redraws. It can be reached with
/// Tab (Full Keyboard Access) like any button, which is the only way it becomes first responder.
final class BackgroundChip: NSButton {
    /// How much of its text the chip shows.
    enum Fit: Equatable {
        case full
        case iconOnly
        case hidden
    }

    static let height: CGFloat = ModelChip.height
    static let horizontalPadding: CGFloat = 9
    static let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Running and done text. `Theme.fgMuted` (white 140) measures 4.3:1 on the chip fill over the
    /// input bar, under the 4.5:1 floor, so the chip uses a lighter grey (contract §2.9 allows the
    /// adjustment; `BackgroundChipAppearanceTests` pins the ratio).
    static let textColor = NSColor(white: 170 / 255, alpha: 1)
    /// Failed text: the transcript's failure colour.
    static let failedTextColor = Theme.foldFailure
    static let fillColor = ModelChip.fillColor
    private static let pressedFillColor = NSColor.white.withAlphaComponent(0.18)

    /// The width the input bar reserves when there is room: the longest text (`◷ 99+ running`) in
    /// the chip font, plus padding.
    static let slotWidth: CGFloat = {
        let text = BackgroundChipState.running(BackgroundChipState.countCap + 1).text ?? ""
        let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
        return ceil(width) + 2 * horizontalPadding
    }()

    /// The narrowest slot the icon alone fits (`◷`, `✓` and `✕` measured, the widest one), plus padding.
    static let iconWidth: CGFloat = {
        let width = ["\u{25F7}", "\u{2713}", "\u{2715}"]
            .map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }
            .max() ?? 0
        return ceil(width) + 2 * horizontalPadding
    }()

    private(set) var chipState: BackgroundChipState = .hidden
    /// How much of the text the chip shows; the input bar sets it from the room its slot has.
    private(set) var fit: Fit = .full
    /// The chip holds the keyboard focus (Tab with Full Keyboard Access); drawn as a ring.
    private(set) var hasKeyboardFocus = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        focusRingType = .none
        appearance = NSAppearance(named: .darkAqua)
        translatesAutoresizingMaskIntoConstraints = false
        refusesFirstResponder = false   // Tab reachability only; nothing else focuses it
        // A button resists compression at 750, over the composer's minimum and the window's own size:
        // its slot gives way instead, and the chip follows its slot (`Fit`).
        setContentCompressionResistancePriority(NSLayoutConstraint.Priority(500), for: .horizontal)
        setAccessibilityRole(.button)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `state`. Hidden for `.hidden`. Never touches the window's first responder.
    func apply(_ state: BackgroundChipState, tooltip: String?) {
        chipState = state
        toolTip = tooltip
        setAccessibilityLabel(state.accessibilityLabel)
        refresh()
    }

    /// Show `fit` of the text. Changes only what the chip draws and whether it is hidden: no layout
    /// outside the chip (its size follows its slot), no first-responder change.
    func setFit(_ fit: Fit) {
        guard fit != self.fit else { return }
        self.fit = fit
        refresh()
    }

    private func refresh() {
        switch fit {
        case .full: title = chipState.text ?? ""
        case .iconOnly: title = chipState.icon ?? ""
        case .hidden: title = ""
        }
        isHidden = chipState == .hidden || fit == .hidden
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The colour the title is drawn in.
    var titleColor: NSColor {
        if case .failed = chipState { return Self.failedTextColor }
        return Self.textColor
    }

    override var intrinsicContentSize: NSSize {
        let text = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        return NSSize(width: min(Self.slotWidth, text + 2 * Self.horizontalPadding), height: Self.height)
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

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: Self.font,
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph,
        ])
        if hasKeyboardFocus {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 2
            NSColor.white.withAlphaComponent(ModelChip.normalAlpha).setStroke()
            ring.stroke()
        }
        let inner = bounds.insetBy(dx: Self.horizontalPadding, dy: 0)
        let lineHeight = ceil(text.size().height)
        text.draw(in: NSRect(x: inner.minX, y: inner.midY - lineHeight / 2, width: inner.width, height: lineHeight))
    }
}
