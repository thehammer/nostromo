import AppKit
import NostromoKit

/// The fold index of a local command's record in `FoldResolver` (`explicitResult(block: nil, index:)`).
/// Negative and far from `TerminalDeliveryBlockKey`'s small negatives, so it can never be the index of
/// one of the turn's own blocks or of a delivery item.
enum LocalCommandRecordKey {
    static let blockIndex = -1_000_000
}

/// What a local command's record is made of, and how tall it is, from the turn alone. Shared by the view
/// and `TurnHeightEstimator`, so the two agree: the expanded body is measured with the same TextKit stack
/// the view draws with.
enum LocalCommandRecordMetrics {
    /// The collapsed record is one marker line, like `WakeMarkerView`.
    static let headerHeight: CGFloat = TurnHeightEstimator.wakeMarkerHeight
    /// Between the header and the expanded output.
    static let bodyGap: CGFloat = 2
    /// Under the expanded output.
    static let bottomPadding: CGFloat = 6
    static let bodyFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let headerFont = NSFont.systemFont(ofSize: 11)

    /// The first output line, or nil for none (blank lines do not count).
    static func firstLine(of output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// More than one non-blank line: the record can open.
    static func isExpandable(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count > 1
    }

    /// The one collapsed line: `/<command> <args> · <first output line>`, or `no output`. `chevron`
    /// leads it when the record can open.
    static func headerLine(command: String, args: String, output: String, stderr: Bool, expanded: Bool) -> String {
        let name = args.isEmpty ? "/\(command)" : "/\(command) \(args)"
        let first = firstLine(of: output) ?? "no output"
        let chevron = isExpandable(output) ? (expanded ? "\u{25BE} " : "\u{25B8} ") : ""
        return stderr ? "\(chevron)\(name) · error · \(first)" : "\(chevron)\(name) · \(first)"
    }

    /// The TextKit stack the body is drawn with (the view's text view uses this very one).
    static func makeBodyStack(text: String, width: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let storage = NSTextStorage(string: text, attributes: [
            .font: bodyFont, .foregroundColor: Theme.fgMuted, .paragraphStyle: style,
        ])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return (storage, layout, container)
    }

    private static var cache: [String: CGFloat] = [:]

    /// Height of `text` wrapped to `width`, measured (not estimated).
    static func bodyHeight(_ text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let key = "\(text.hashValue)|\(text.utf8.count)|\(Int(width.rounded()))"
        if let hit = cache[key] { return hit }
        let (storage, layout, container) = makeBodyStack(text: text, width: width)
        let height = withExtendedLifetime(storage) { () -> CGFloat in
            layout.ensureLayout(for: container)
            return max(0, ceil(layout.usedRect(for: container).height) - ceil(bodyFont.ascender - bodyFont.descender + bodyFont.leading))
        }
        if cache.count > 256 { cache.removeAll() }
        cache[key] = height
        return height
    }

    /// The record's height at `width`.
    static func height(output: String, expanded: Bool, width: CGFloat) -> CGFloat {
        guard expanded, isExpandable(output) else { return headerHeight }
        return headerHeight + bodyGap + bodyHeight(output, width: width) + bottomPadding
    }
}

/// A local slash command's answer (`/context`, `/model haiku`, `/usage`), drawn where the user's
/// message would be, muted and collapsible: never a bubble, because the user never sent the CLI a
/// message, they ran a command. The daemon sends it as a turn with a `local_command` origin.
///
/// Collapsed it is one line, `/<command> <args> · <first output line>` (or `no output`), with a chevron
/// when the output has more than one line. Expanded, the output sits below in muted monospace, selectable
/// and wrapped to the pane width. Click, Space, Return or a VoiceOver press toggles it. Its height is
/// arithmetic (`LocalCommandRecordMetrics`), so the estimator and the drawn turn agree.
final class LocalCommandRecordView: NSView, ArithmeticIsland {

    static let copyMenuTitle = "Copy Output"

    private let command: String
    private let args: String
    private let output: String
    private let isError: Bool
    private let pasteboard: NSPasteboard
    private let header = NSTextField(labelWithString: "")
    private var body: NSTextView?
    /// The text storage the body's layout manager reads (a layout manager does not retain its storage).
    private var bodyStorage: NSTextStorage?
    private(set) var isExpanded: Bool

    /// Fired on a toggle with the new state, so the turn can be re-measured and the choice kept outside
    /// this view (`ChatTurnView` → `ReplView`'s `foldSync`).
    var onExpansionChange: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    init(command: String, args: String, output: String, stream: String, startExpanded: Bool,
         pasteboard: NSPasteboard = .general) {
        self.command = command
        self.args = args
        self.output = output
        self.isError = stream == "stderr"
        self.pasteboard = pasteboard
        self.isExpanded = startExpanded && LocalCommandRecordMetrics.isExpandable(output)
        super.init(frame: .zero)

        header.isSelectable = false
        header.lineBreakMode = .byTruncatingTail
        header.maximumNumberOfLines = 1
        header.usesSingleLineMode = true
        header.alignment = .right
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(header)
        applyState()
        focusRingType = .default
        toolTip = String(output.prefix(1000))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Inspection

    /// The one drawn header line.
    var headerText: String { header.stringValue }
    /// The output below the header; nil while collapsed.
    var expandedText: String? { isExpanded ? body?.string : nil }
    /// A chevron shows: the output has more than one line.
    var hasChevron: Bool { LocalCommandRecordMetrics.isExpandable(output) }
    /// The output's frame in this view (nil while collapsed).
    var bodyFrame: NSRect? { isExpanded ? body?.frame : nil }
    var headerFrame: NSRect { header.frame }

    // MARK: Action

    /// What a click, Space, Return or a VoiceOver press does.
    func toggle() {
        guard hasChevron else { return }
        isExpanded.toggle()
        applyState()
        onExpansionChange?(isExpanded)
    }

    @objc private func copyOutput(_ sender: Any?) {
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    // MARK: Layout

    private var layoutWidth: CGFloat { max(bounds.width, 1) }

    func arithmeticHeight(atWidth width: CGFloat) -> CGFloat {
        LocalCommandRecordMetrics.height(output: output, expanded: isExpanded, width: width)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: LocalCommandRecordMetrics.height(output: output, expanded: isExpanded, width: layoutWidth))
    }

    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: LocalCommandRecordMetrics.headerHeight)
        if let body {
            let y = LocalCommandRecordMetrics.headerHeight + LocalCommandRecordMetrics.bodyGap
            let h = LocalCommandRecordMetrics.bodyHeight(output, width: bounds.width)
            body.frame = NSRect(x: 0, y: y, width: bounds.width, height: h)
        }
    }

    // MARK: State

    private func applyState() {
        let line = LocalCommandRecordMetrics.headerLine(command: command, args: args, output: output,
                                                         stderr: isError, expanded: isExpanded)
        let text = NSMutableAttributedString(string: line, attributes: [
            .font: LocalCommandRecordMetrics.headerFont, .foregroundColor: Theme.fgMuted,
        ])
        if isError, let r = line.range(of: " · error · ") {
            let word = (line as NSString).range(of: "error", range: NSRange(r, in: line))
            text.addAttribute(.foregroundColor, value: Theme.amber, range: word)
        }
        header.attributedStringValue = text
        if isExpanded, body == nil {
            let (storage, _, container) = LocalCommandRecordMetrics.makeBodyStack(text: output, width: layoutWidth)
            bodyStorage = storage
            let textView = NSTextView(frame: .zero, textContainer: container)
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = .zero
            textView.isVerticallyResizable = false
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.setAccessibilityLabel("Output of \(LocalCommandRecordMetrics.headerLine(command: command, args: args, output: "", stderr: false, expanded: false))")
            addSubview(textView)
            body = textView
        } else if !isExpanded {
            body?.removeFromSuperview()
            body = nil
            bodyStorage = nil
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        setAccessibilityLabel(accessibilityLabelText)
    }

    private var accessibilityLabelText: String {
        "Command /\(command), output \(isExpanded ? "expanded" : "collapsed")"
    }

    // MARK: Mouse and keyboard

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.y <= LocalCommandRecordMetrics.headerHeight { toggle() } else { super.mouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: Self.copyMenuTitle, action: #selector(copyOutput(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Focusable from the keyboard when it can open, but a click never takes focus from the composer.
    override var acceptsFirstResponder: Bool {
        guard hasChevron else { return false }
        guard let type = NSApp?.currentEvent?.type else { return true }
        return ![.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
    }

    override var canBecomeKeyView: Bool { hasChevron }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 49, 36, 76: toggle()      // Space, Return, keypad Enter
        default: super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: LocalCommandRecordMetrics.headerHeight) }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill() }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { hasChevron ? .button : .staticText }
    override func accessibilityLabel() -> String? { accessibilityLabelText }
    override func accessibilityValue() -> Any? { LocalCommandRecordMetrics.firstLine(of: output) ?? "no output" }
    override func accessibilityPerformPress() -> Bool {
        guard hasChevron else { return false }
        toggle()
        return true
    }
    override func accessibilityChildren() -> [Any]? { [] }
}
