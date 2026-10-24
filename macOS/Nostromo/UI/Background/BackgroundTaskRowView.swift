import AppKit
import NostromoKit

/// Explicit colours for the Background activity popover (Dark Aqua pinned; nothing here uses a
/// system label colour, which goes dark-on-dark on this UI, #234). Contract §2.9; the ratios are
/// pinned by `BackgroundChipAppearanceTests`.
enum BackgroundPalette {
    /// The popover's own background (the model popup's).
    static let background = NSColor(calibratedWhite: 0.12, alpha: 1)
    /// Row text: kind, title, status, time.
    static let text = Theme.fg
    /// Sign of life, ended-ago, section headers, housekeeping rows (dimmed by colour, not alpha).
    static let muted = Theme.fgMuted
    static let failed = Theme.foldFailure
    /// The selected row's ring. A ring, not a fill: a fill under muted text would take it below 4.5:1.
    static let selectionRing = NSColor.white.withAlphaComponent(0.55)
    static let separator = NSColor(white: 1, alpha: 0.12)
}

/// One task in the popover: `◷ Shell  npm run build   running  14 s`, and under it, muted, the
/// latest sign of life (`last: build: 3/7 jobs passed`, `18.2k tokens · 11 tools · Edit`).
/// Fixed height: one line, or two when there is a sign of life. One line each, truncated with an
/// ellipsis; the full description is the tooltip. Children are indented under their parent.
final class BackgroundTaskRowView: NSView {
    static let lineHeight: CGFloat = 22
    static let signOfLifeHeight: CGFloat = 16
    static let indentStep: CGFloat = 16
    static let horizontalInset: CGFloat = 10
    private static let font = NSFont.systemFont(ofSize: 12)
    private static let kindFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let mutedFont = NSFont.systemFont(ofSize: 11)

    static func height(for row: BackgroundTaskRow) -> CGFloat {
        lineHeight + (row.signOfLife == nil ? 0 : signOfLifeHeight)
    }

    private(set) var row: BackgroundTaskRow
    private(set) var isSelected = false

    /// A click on the row.
    var onClick: ((BackgroundTaskRowView) -> Void)?
    /// The row's context menu (built by the popover, which knows the actions).
    var menuProvider: ((BackgroundTaskRow) -> NSMenu?)?

    private let iconField = NSTextField(labelWithString: "")
    private let kindField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let statusField = NSTextField(labelWithString: "")
    private let timeField = NSTextField(labelWithString: "")
    private let agoField = NSTextField(labelWithString: "")
    private let signOfLifeField = NSTextField(labelWithString: "")
    private let line = NSStackView()
    private var leadingConstraint: NSLayoutConstraint!

    var titleText: String { titleField.stringValue }
    var kindText: String { kindField.stringValue }
    var statusText: String { statusField.stringValue }
    var timeText: String { timeField.stringValue }
    var endedAgoText: String { agoField.stringValue }
    var iconText: String { iconField.stringValue }
    /// Empty when the row has no sign of life (the second line is not drawn then).
    var signOfLifeText: String { signOfLifeField.isHidden ? "" : signOfLifeField.stringValue }
    var titleColor: NSColor? { titleField.textColor }
    var statusColor: NSColor? { statusField.textColor }
    var signOfLifeColor: NSColor? { signOfLifeField.textColor }
    var endedAgoColor: NSColor? { agoField.textColor }
    var indentation: CGFloat { leadingConstraint.constant - Self.horizontalInset }

    init(row: BackgroundTaskRow) {
        self.row = row
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.height(for: row)))
        wantsLayer = true
        layer?.cornerRadius = 4

        for field in [iconField, kindField, titleField, statusField, timeField, agoField, signOfLifeField] {
            field.isSelectable = false
            field.drawsBackground = false
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        iconField.font = Self.font
        kindField.font = Self.kindFont
        titleField.font = Self.font
        statusField.font = Self.font
        timeField.font = Self.font
        agoField.font = Self.mutedFont
        signOfLifeField.font = Self.mutedFont

        line.orientation = .horizontal
        line.alignment = .firstBaseline
        line.spacing = 6
        line.translatesAutoresizingMaskIntoConstraints = false
        for field in [iconField, kindField, titleField, statusField, timeField, agoField] {
            line.addArrangedSubview(field)
        }
        line.setCustomSpacing(4, after: iconField)
        line.setCustomSpacing(10, after: titleField)
        // The title gives way first: everything else keeps its natural width.
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        for field in [iconField, kindField, statusField, timeField, agoField] {
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        signOfLifeField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        addSubview(line)
        addSubview(signOfLifeField)

        leadingConstraint = line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset)
        NSLayoutConstraint.activate([
            leadingConstraint,
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            iconField.widthAnchor.constraint(equalToConstant: 14),
            kindField.widthAnchor.constraint(equalToConstant: 62),
            signOfLifeField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            signOfLifeField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalInset),
            signOfLifeField.topAnchor.constraint(equalTo: topAnchor, constant: Self.lineHeight - 3),
        ])

        setAccessibilityElement(true)
        // One element with its own label; its text fields would be read again.
        setAccessibilityChildren([])
        setAccessibilityRole(.staticText)
        apply(row)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `row` (a later state of the same task, or the next tick). Never resizes the row's width.
    func apply(_ row: BackgroundTaskRow) {
        self.row = row
        iconField.stringValue = row.statusIcon
        kindField.stringValue = row.kindLabel
        titleField.stringValue = row.title
        statusField.stringValue = row.statusLabel
        timeField.stringValue = row.timeText ?? ""
        timeField.isHidden = row.timeText == nil
        agoField.stringValue = row.endedAgoText.map { "\u{00B7} " + $0 } ?? ""
        agoField.isHidden = row.endedAgoText == nil
        signOfLifeField.stringValue = row.signOfLife ?? ""
        signOfLifeField.isHidden = row.signOfLife == nil
        leadingConstraint.constant = Self.horizontalInset + CGFloat(row.depth) * Self.indentStep

        let main = row.isHousekeeping ? BackgroundPalette.muted : BackgroundPalette.text
        iconField.textColor = row.isFailed ? BackgroundPalette.failed : main
        kindField.textColor = main
        titleField.textColor = main
        statusField.textColor = row.isFailed ? BackgroundPalette.failed : main
        timeField.textColor = main
        agoField.textColor = BackgroundPalette.muted
        signOfLifeField.textColor = BackgroundPalette.muted

        toolTip = row.description.isEmpty ? row.title : row.description
        setAccessibilityLabel(row.accessibilityLabel)
        if frame.height != Self.height(for: row) {
            setFrameSize(NSSize(width: frame.width, height: Self.height(for: row)))
        }
    }

    func setSelected(_ on: Bool) {
        guard isSelected != on else { return }
        isSelected = on
        layer?.borderWidth = on ? 1.5 : 0
        layer?.borderColor = on ? BackgroundPalette.selectionRing.cgColor : nil
        setAccessibilitySelected(on)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row)
    }
}
