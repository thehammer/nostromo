import AppKit

/// The Overview's DEPENDS ON section: what a job depends on, and why it waits.
/// Text comes from job files (untrusted), so it is shown as plain single-line strings.
/// Nothing here reports an intrinsic width, so it can never widen the pane.
final class MotherDependencySectionView: NSView {
    static let collapsedLimit = 5

    /// A single-line label that never sets its container's width.
    private final class LineLabel: NSTextField {
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width = NSView.noIntrinsicMetric
            return size
        }
    }
    private final class LineButton: NSButton {
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width = NSView.noIntrinsicMetric
            return size
        }
    }
    /// A wrapping label pinned to its container's width; it wraps, never truncates.
    private final class WrapLabel: NSTextField {
        override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width = NSView.noIntrinsicMetric
            return size
        }
        override func layout() {
            super.layout()
            if preferredMaxLayoutWidth != bounds.width {
                preferredMaxLayoutWidth = bounds.width
                invalidateIntrinsicContentSize()
            }
        }
    }

    final class RowView: NSStackView {
        let row: MotherDependencyRow
        fileprivate(set) var button: NSButton?
        fileprivate(set) var textLabel: NSTextField?
        fileprivate(set) var reasonLabel: NSTextField?
        init(row: MotherDependencyRow) {
            self.row = row
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// Called with the dependency's full job id when an in-queue row is pressed.
    var onOpen: ((String) -> Void)?
    private(set) var rows: [MotherDependencyRow] = []
    private(set) var isExpanded = false
    private(set) var visibleRowViews: [RowView] = []
    let headerLabel = NSTextField(labelWithString: "DEPENDS ON")
    let toggleButton: NSButton = NSButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        headerLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        headerLabel.textColor = Theme.fgMuted
        toggleButton.isBordered = false
        toggleButton.alignment = .left
        toggleButton.target = self
        toggleButton.action = #selector(toggle)
        toggleButton.setButtonType(.momentaryChange)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { rows.isEmpty }

    /// The rows to show: the first five, with the one Mother names moved to the front if it is beyond them.
    static func visibleRows(_ rows: [MotherDependencyRow], expanded: Bool) -> [MotherDependencyRow] {
        guard !expanded, rows.count > collapsedLimit else { return rows }
        var shown = Array(rows.prefix(collapsedLimit))
        if !shown.contains(where: { $0.reasonLine != nil }),
           let named = rows.first(where: { $0.reasonLine != nil }) {
            shown.removeLast()
            shown.insert(named, at: 0)
        }
        return shown
    }

    /// Rebuilds only when the rows differ from the ones shown.
    func update(rows newRows: [MotherDependencyRow]) {
        guard newRows != rows else { return }
        rows = newRows
        rebuild()
    }

    @objc private func toggle() {
        isExpanded.toggle()
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        visibleRowViews = []
        guard !rows.isEmpty else {
            setAccessibilityLabel(nil)
            return
        }
        setAccessibilityLabel("Depends on, \(rows.count) \(rows.count == 1 ? "job" : "jobs")")
        stack.addArrangedSubview(headerLabel)
        for row in Self.visibleRows(rows, expanded: isExpanded) {
            let view = makeRowView(row)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            visibleRowViews.append(view)
        }
        if rows.count > Self.collapsedLimit {
            let title = isExpanded ? "Show fewer" : "Show all \(rows.count)"
            toggleButton.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: Theme.followBlue,
            ])
            toggleButton.setAccessibilityLabel(isExpanded ? "Show fewer dependencies" : "Show all \(rows.count) dependencies")
            toggleButton.refusesFirstResponder = false
            stack.addArrangedSubview(toggleButton)
        }
    }

    private func lineText(_ row: MotherDependencyRow) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let out = NSMutableAttributedString()
        if let state = row.state {
            out.append(NSAttributedString(string: state.uppercased() + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: Theme.fgMuted, .paragraphStyle: para]))
        }
        out.append(NSAttributedString(string: row.lineText, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: row.inQueue ? Theme.followBlue : Theme.fg,
            .paragraphStyle: para]))
        return out
    }

    private func makeRowView(_ row: MotherDependencyRow) -> RowView {
        let view = RowView(row: row)
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 2
        let attributed = lineText(row)
        let line: NSView
        if row.inQueue {
            let b = LineButton(title: "", target: self, action: #selector(pressed(_:)))
            b.isBordered = false
            b.alignment = .left
            b.lineBreakMode = .byTruncatingTail
            b.setButtonType(.momentaryChange)
            b.attributedTitle = attributed
            b.toolTip = row.title
            b.identifier = NSUserInterfaceItemIdentifier(row.id)
            b.setAccessibilityLabel(row.accessibilityLabel)
            b.setAccessibilityHelp("Opens this job in the Mother pane")
            view.button = b
            line = b
        } else {
            let l = LineLabel(labelWithString: "")
            l.attributedStringValue = attributed
            l.lineBreakMode = .byTruncatingTail
            l.maximumNumberOfLines = 1
            l.isSelectable = false
            l.setAccessibilityLabel(row.accessibilityLabel)
            l.setAccessibilityRole(.staticText)
            view.textLabel = l
            line = l
        }
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        if let reason = row.reasonLine {
            let r = WrapLabel(wrappingLabelWithString: reason)
            r.font = .systemFont(ofSize: 11)
            r.textColor = row.isBlocked ? Theme.amber : Theme.fgMuted
            r.lineBreakMode = .byWordWrapping
            r.maximumNumberOfLines = 0
            r.isSelectable = false
            r.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            r.setAccessibilityElement(false)  // the row's label already reads it
            view.reasonLabel = r
            view.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        return view
    }

    @objc private func pressed(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onOpen?(id) }
    }
}
