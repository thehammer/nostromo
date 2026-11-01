import AppKit
import NostromoKit

/// What a task window's body views share: they take new content (the header's text, the task's end)
/// without the window changing size, order or key status.
protocol TaskWindowBody: NSView {
    /// Show `content` (called again whenever the task's entry changes).
    func apply(content: TaskWindowContent)
}

/// The colours a task window draws with, all explicit (the panel is Dark Aqua, but a contrast
/// target must not depend on the system's appearance). Contract §2.9.
enum TaskWindowPalette {
    static let background = Theme.bg
    static let text = Theme.fg
    /// Muted header fields (started at, elapsed, activity). Lighter than `Theme.fgMuted`, which
    /// measures 4.5:1 only on the lighter popover: this sits on the darker window background.
    static let muted = BackgroundPalette.muted
    static let failed = Theme.foldFailure
    static let separator = NSColor(white: 1, alpha: 0.12)
}

/// The header above every task view: kind and status on one line, the description in full (wrapped),
/// when it started and how long it has run (or ran), the activity of an agent, and the closing words
/// of an ended task.
///
/// Every label wraps or truncates with a low horizontal compression resistance and is tied to the
/// header's own width, so a long description, a narrow window or a hostile string can never ask the
/// panel to grow. Text arrives already sanitised (`TaskWindowContent`).
final class TaskWindowHeaderView: NSView {
    static let inset: CGFloat = 12
    static let descriptionLineLimit = 6
    static let summaryLineLimit = 8

    private let kindLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(wrappingLabelWithString: "")
    private let activityLabel = NSTextField(wrappingLabelWithString: "")
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private let rule = NSView()
    private var wrapping: [NSTextField] { [descriptionLabel, metaLabel, activityLabel, summaryLabel] }

    private(set) var content: TaskWindowContent?

    // What is drawn, for tests.
    var kindText: String { kindLabel.stringValue }
    var statusText: String { statusLabel.stringValue }
    var descriptionText: String { descriptionLabel.stringValue }
    var metaText: String { metaLabel.stringValue }
    var activityText: String { activityLabel.stringValue }
    var summaryText: String { summaryLabel.stringValue }
    var kindColor: NSColor? { kindLabel.textColor }
    var statusColor: NSColor? { statusLabel.textColor }
    var descriptionColor: NSColor? { descriptionLabel.textColor }
    var metaColor: NSColor? { metaLabel.textColor }
    var summaryColor: NSColor? { summaryLabel.textColor }
    var descriptionToolTip: String? { descriptionLabel.toolTip }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TaskWindowPalette.background.cgColor

        kindLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        kindLabel.textColor = TaskWindowPalette.text
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = TaskWindowPalette.text
        for label in [kindLabel, statusLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.isSelectable = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        kindLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        configure(descriptionLabel, font: .systemFont(ofSize: 13), color: TaskWindowPalette.text,
                  lines: Self.descriptionLineLimit)
        configure(metaLabel, font: .systemFont(ofSize: 11), color: TaskWindowPalette.muted, lines: 2)
        configure(activityLabel, font: .systemFont(ofSize: 11), color: TaskWindowPalette.muted, lines: 2)
        configure(summaryLabel, font: .systemFont(ofSize: 12), color: TaskWindowPalette.text,
                  lines: Self.summaryLineLimit)

        let titleLine = NSStackView(views: [kindLabel, statusLabel])
        titleLine.orientation = .horizontal
        titleLine.alignment = .firstBaseline
        titleLine.spacing = 8
        titleLine.distribution = .fill

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [titleLine, descriptionLabel, metaLabel, activityLabel, summaryLabel] { stack.addArrangedSubview(view) }
        addSubview(stack)

        rule.wantsLayer = true
        rule.layer?.backgroundColor = TaskWindowPalette.separator.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        let inset = Self.inset
        var constraints = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -10),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            titleLine.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
        ]
        // The wrapping labels take the header's width, whatever their text asks for.
        for label in wrapping {
            constraints.append(label.leadingAnchor.constraint(equalTo: stack.leadingAnchor))
            constraints.append(label.trailingAnchor.constraint(equalTo: stack.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `content`; empty fields leave their line out.
    func apply(_ content: TaskWindowContent) {
        guard self.content != content else { return }
        self.content = content
        kindLabel.stringValue = content.kindLabel
        statusLabel.stringValue = content.statusText
        statusLabel.textColor = content.isFailed ? TaskWindowPalette.failed : TaskWindowPalette.text
        descriptionLabel.stringValue = content.description
        descriptionLabel.toolTip = content.description.isEmpty ? nil : content.description
        descriptionLabel.isHidden = content.description.isEmpty
        let meta = [content.startedText, content.timeText].compactMap { $0 }.joined(separator: ToolGroupSummary.separator)
        metaLabel.stringValue = meta
        metaLabel.isHidden = meta.isEmpty
        activityLabel.stringValue = content.activityText ?? ""
        activityLabel.isHidden = content.activityText == nil
        summaryLabel.stringValue = content.summary ?? ""
        summaryLabel.isHidden = content.summary == nil
        summaryLabel.textColor = content.isFailed ? TaskWindowPalette.failed : TaskWindowPalette.text
        summaryLabel.toolTip = content.summary
        toolTip = content.accessibilityLabel
        setAccessibilityLabel(content.accessibilityLabel)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // A wrapping label measures itself against `preferredMaxLayoutWidth`: tell it the width it
        // really has, then lay out again so the stack takes the wrapped heights.
        let width = max(0, bounds.width - 2 * Self.inset)
        var changed = false
        for label in wrapping where abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            changed = true
        }
        if changed { super.layout() }
    }

    // MARK: Private

    private func configure(_ label: NSTextField, font: NSFont, color: NSColor, lines: Int) {
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = lines
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
}
