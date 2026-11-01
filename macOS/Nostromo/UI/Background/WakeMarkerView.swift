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

    /// Opens what the marker's target names. The default handles the Mother targets (the first job);
    /// a pane that knows its session passes one that also opens background tasks.
    typealias Router = (WakeMarkerTarget) -> Void

    /// The router for the Mother targets; background targets go nowhere.
    static let defaultRouter: Router = { target in
        switch target {
        case .motherJob(let id): MotherJobRouting.open(jobId: id)
        case .motherJobs(let ids): if let id = ids.first { MotherJobRouting.open(jobId: id) }
        case .backgroundTask, .backgroundTasks, .none: break
        }
    }

    /// The router a pane installs: a background task opens its window (`openTask` says whether the
    /// store knew it; if not, the pane's list opens instead), several events open the list, and the
    /// Mother targets go where `defaultRouter` sends them.
    static func paneRouter(openTask: @escaping (String) -> Bool, showList: @escaping () -> Void) -> Router {
        { target in
            switch target {
            case .backgroundTask(let id): if !openTask(id) { showList() }
            case .backgroundTasks: showList()
            case .motherJob, .motherJobs, .none: defaultRouter(target)
            }
        }
    }

    static let copyMenuTitle = "Copy Notice Text"
    static let copyEventMenuTitle = "Copy Event Text"

    private let content: WakeMarkerContent
    private let noticeText: String
    private let copyMenuTitle: String
    private let router: Router
    private let pasteboard: NSPasteboard
    private let label = NSTextField(labelWithString: "")
    /// Where the press started, so a drag that ends elsewhere is not a click.
    private var pressStartedInside = false

    /// The one drawn line.
    var shownText: String { label.stringValue }

    init(content: WakeMarkerContent, noticeText: String,
         router: @escaping Router = WakeMarkerView.defaultRouter,
         copyMenuTitle: String = WakeMarkerView.copyMenuTitle,
         pasteboard: NSPasteboard = .general) {
        self.copyMenuTitle = copyMenuTitle
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

    /// What a click, Return or Space does: hand the target to the router. Nothing when there is none.
    func activate() {
        guard hasTarget else { return }
        router(content.target)
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
        let item = NSMenuItem(title: copyMenuTitle, action: #selector(copyNoticeText(_:)), keyEquivalent: "")
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
    override func accessibilityHelp() -> String? {
        switch content.target {
        case .motherJob, .motherJobs: return "Opens the job in Mother"
        case .backgroundTask: return "Opens the task's window"
        case .backgroundTasks: return "Opens the background activity list"
        case .none: return nil
        }
    }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool {
        guard hasTarget else { return false }
        activate()
        return true
    }

    // MARK: Private

    private var hasTarget: Bool { content.target != .none }

    /// The text's own rectangle: right-aligned, as wide as the line (at most the row).
    private var textRect: NSRect {
        let width = min(ceil(label.intrinsicContentSize.width), bounds.width)
        return NSRect(x: bounds.maxX - width, y: bounds.minY, width: width, height: bounds.height)
    }
}
