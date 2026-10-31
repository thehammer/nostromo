import AppKit
import NostromoKit

/// A muted one-line marker in the transcript's user slot, standing in for a turn the user did not
/// type but the agent received (MF2c: a Mother job notice; BA6b reuses it for a background wake).
///
/// What it says is `WakeMarkerContent`, built in NostromoKit; this view only draws it and acts on
/// a click, Return or Space. The line is plain text that tail-truncates, so a long title can never
/// widen the transcript, and the height is fixed (`TurnHeightEstimator.wakeMarkerHeight`), so the
/// height estimator and the drawn turn agree and a notice arriving moves nothing.
///
/// Clicking opens the job in the Mother focus through `router`. That changes nothing in the world
/// (it is navigation, like selecting a row), so it is a view action and is not gesture-gated.
/// The context menu's "Copy Notice Text" puts the text the agent received (`noticeText`, the
/// turn's raw `userInput`) on the pasteboard, so nothing the agent was told is ever hidden.
final class WakeMarkerView: NSView, ArithmeticIsland {

    /// Opens the job with this id. The transcript passes `MotherJobRouting.open(jobId:)`.
    typealias Router = (String) -> Void

    static let copyMenuTitle = "Copy Notice Text"

    private let content: WakeMarkerContent
    private let noticeText: String
    private let router: Router
    private let pasteboard: NSPasteboard
    private let label = NSTextField(labelWithString: "")
    /// Where the press started, so a drag that ends elsewhere is not a click.
    private var pressStartedInside = false

    /// The one drawn line.
    var shownText: String { label.stringValue }

    init(content: WakeMarkerContent, noticeText: String,
         router: @escaping Router = { MotherJobRouting.open(jobId: $0) },
         pasteboard: NSPasteboard = .general) {
        self.content = content
        self.noticeText = noticeText
        self.router = router
        self.pasteboard = pasteboard
        super.init(frame: .zero)

        label.stringValue = content.line
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.fgMuted
        label.alignment = .right
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isSelectable = false
        // Yield horizontally so a long line truncates instead of demanding its full width.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: TurnHeightEstimator.wakeMarkerHeight),
        ])

        toolTip = content.tooltipLines.isEmpty ? nil : content.tooltipLines.joined(separator: "\n")
        focusRingType = .default
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Action

    /// What a click, Return or Space does: open the first job. Nothing when there is no target.
    func activate() {
        guard let id = firstJobId else { return }
        router(id)
    }

    // MARK: Layout

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TurnHeightEstimator.wakeMarkerHeight)
    }

    /// Fixed: the line is one truncating row, whatever it says and however wide the pane is.
    func arithmeticHeight(atWidth width: CGFloat) -> CGFloat { TurnHeightEstimator.wakeMarkerHeight }

    // MARK: Mouse

    /// Only the text itself takes a click; the rest of the row belongs to the transcript.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return textRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        pressStartedInside = hasTarget && textRect.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressStartedInside = false }
        guard pressStartedInside, textRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate()
    }

    override func resetCursorRects() {
        if hasTarget { addCursorRect(textRect, cursor: .pointingHand) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: Self.copyMenuTitle, action: #selector(copyNoticeText(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func copyNoticeText(_ sender: Any?) {
        pasteboard.clearContents()
        pasteboard.setString(noticeText, forType: .string)
    }

    // MARK: Keyboard

    /// Focusable from the keyboard, but a click never takes focus from the composer: the window
    /// asks this during the mouse-down it is about to deliver.
    override var acceptsFirstResponder: Bool {
        guard hasTarget else { return false }
        guard let type = NSApp?.currentEvent?.type else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    override var canBecomeKeyView: Bool { hasTarget }

    override func becomeFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        noteFocusRingMaskChanged()
        return super.resignFirstResponder()
    }

    override var focusRingMaskBounds: NSRect { textRect }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4).fill() }

    override func keyDown(with event: NSEvent) {
        // ⌘→, ⌥←, ⌃↑… belong to someone else.
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 49, 36, 76: activate()     // Space, Return, keypad Enter
        default: super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { hasTarget ? .button : .staticText }
    override func accessibilityLabel() -> String? { content.accessibilityLabel }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        guard hasTarget else { return false }
        activate()
        return true
    }

    // MARK: Private

    private var hasTarget: Bool { firstJobId != nil }

    private var firstJobId: String? {
        switch content.target {
        case .motherJob(let id): return id
        case .motherJobs(let ids): return ids.first
        case .none: return nil
        }
    }

    /// The text's own rectangle: right-aligned, as wide as the line (at most the row).
    private var textRect: NSRect {
        let width = min(ceil(label.intrinsicContentSize.width), bounds.width)
        return NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }
}
