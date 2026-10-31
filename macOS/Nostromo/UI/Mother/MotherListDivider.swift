import AppKit

/// The Mother list column's width rules (Mother focus v2, Q2): 280 pt by default, never under 220 pt,
/// never so wide that the detail drops under 320 pt, remembered per window.
enum MotherListWidth {
    static let defaultWidth: CGFloat = 280
    static let minimum: CGFloat = 220
    static let detailMinimum: CGFloat = 320
    /// What the divider's accessibility increment and decrement move by.
    static let accessibilityStep: CGFloat = 20

    static func maximum(viewWidth: CGFloat) -> CGFloat { max(minimum, viewWidth - detailMinimum) }

    static func clamp(_ width: CGFloat, viewWidth: CGFloat) -> CGFloat {
        min(max(width, minimum), maximum(viewWidth: viewWidth))
    }

    static func defaultsKey(windowKey: String) -> String { "MotherListWidth.\(windowKey)" }

    static func stored(in defaults: UserDefaults, windowKey: String) -> CGFloat? {
        guard let value = defaults.object(forKey: defaultsKey(windowKey: windowKey)) as? Double, value.isFinite else { return nil }
        return CGFloat(value)
    }

    static func store(_ width: CGFloat, in defaults: UserDefaults, windowKey: String) {
        defaults.set(Double(width), forKey: defaultsKey(windowKey: windowKey))
    }
}

/// An invisible 6 pt grab area over the 1 px divider between the job list and the detail. Dragging asks
/// for a new list width; nothing here lays anything out.
final class MotherListDivider: NSView {
    static let hitWidth: CGFloat = 6

    /// The list width the drag asks for. Called for every drag event.
    var onResize: ((CGFloat) -> Void)?
    /// The drag ended (or an accessibility step finished) at this width: the moment to remember it.
    var onCommit: (() -> Void)?
    /// The current list width, read when a drag starts and for the accessibility value.
    var currentWidth: () -> CGFloat = { MotherListWidth.defaultWidth }

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartX = event.locationInWindow.x
        dragStartWidth = currentWidth()
    }

    override func mouseDragged(with event: NSEvent) {
        onResize?(dragStartWidth + event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) { onCommit?() }

    // MARK: Accessibility: a splitter whose value is the list width

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Job list width" }
    override func accessibilityValue() -> Any? { NSNumber(value: Double(currentWidth())) }

    override func accessibilityPerformIncrement() -> Bool { step(MotherListWidth.accessibilityStep) }
    override func accessibilityPerformDecrement() -> Bool { step(-MotherListWidth.accessibilityStep) }

    private func step(_ delta: CGFloat) -> Bool {
        onResize?(currentWidth() + delta)
        onCommit?()
        return true
    }
}
