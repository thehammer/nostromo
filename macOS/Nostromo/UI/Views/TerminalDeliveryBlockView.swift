import AppKit
import NostromoKit

// MARK: - TerminalDeliveryBlockView

/// One item of a terminal delivery turn (terminal slice 3e): what the agent received from a
/// terminal it follows, shown in the transcript instead of a user bubble.
///
/// An output item is a collapsed disclosure like `ToolResultView`'s — "▶ Output from production ·
/// scheduler shell, 42 lines" — and expanded shows exactly the text of that element of the
/// message the agent got, advisory line included, monospaced and selectable, with the
/// `[redacted: …]` markers highlighted (the user sees what was withheld). A follow notice is one
/// muted line and does not expand.
///
/// Expansion is kept outside the view (`TurnInteractionStore`, through `onExpansionChange` and
/// `startExpanded`) for the reason `ToolResultView` gives: turn views are rebuilt routinely.
final class TerminalDeliveryBlockView: NSView {

    private let item: TerminalOriginItem
    /// The element's text, exactly as the agent received it; nil when the turn no longer holds it.
    private let text: String?

    private(set) var isExpanded: Bool
    private let disclosure  = NSButton()
    private let contentWrap = NSView()
    /// Guards against building the (possibly large) text label more than once.
    private var labelBuilt = false

    /// Fired on expand/collapse with the *new* state, so the turn can be re-measured and the
    /// choice kept outside this view.
    var onExpansionChange: ((Bool) -> Void)?

    /// Where "Copy" puts the output. Injectable so tests never touch the real clipboard.
    var pasteboard: NSPasteboard = .general

    /// `startExpanded` has no default on purpose: the compiler is then the wiring check for the
    /// one construction site in `ChatTurnView`. A notice never expands.
    init(item: TerminalOriginItem, text: String?, startExpanded: Bool) {
        self.item = item
        self.text = text
        isExpanded = startExpanded && !item.isNotice
        super.init(frame: .zero)
        if item.isNotice { buildNotice() } else { buildDisclosure() }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Inspection

    var isNotice: Bool { item.isNotice }

    /// The collapsed line (and a notice's whole line).
    var summaryText: String { TerminalDeliveryText.summary(for: item) }

    /// What the expanded block shows; nil while collapsed and for a notice.
    var expandedText: String? { isExpanded ? bodyText : nil }

    /// The ranges of `expandedText` carrying the redaction highlight.
    var highlightedRanges: [NSRange] {
        isExpanded ? TerminalDeliveryText.redactionRanges(in: bodyText) : []
    }

    /// What a click does.
    func toggle() {
        guard !item.isNotice else { return }
        isExpanded.toggle()
        applyState()
        onExpansionChange?(isExpanded)
    }

    // MARK: Build

    private func buildNotice() {
        let label = CopyMenuTextField(labelWithString: summaryText)
        label.isSelectable         = true   // transcript text is copyable
        label.font                 = .systemFont(ofSize: 10)
        label.textColor            = Theme.fgMuted
        label.lineBreakMode        = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.toolTip              = summaryText
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(summaryText)
    }

    private func buildDisclosure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        layer?.cornerRadius    = 6
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.borderInactive.withAlphaComponent(0.6).cgColor

        disclosure.isBordered = false
        disclosure.alignment  = .left
        disclosure.lineBreakMode = .byTruncatingTail
        disclosure.target     = self
        disclosure.action     = #selector(clicked)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.translatesAutoresizingMaskIntoConstraints = false

        // Same structure and metrics as `ToolResultView`, so a collapsed block is as tall as a
        // collapsed tool result (`TurnHeightEstimator.deliveryCollapsed`).
        let vStack = NSStackView(views: [disclosure, contentWrap])
        vStack.orientation = .vertical
        vStack.spacing     = 4
        vStack.alignment   = .width
        vStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vStack)
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            vStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            vStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            disclosure.widthAnchor.constraint(equalTo: vStack.widthAnchor),
            contentWrap.widthAnchor.constraint(equalTo: vStack.widthAnchor),
        ])
        // Restoring is silent: no `onExpansionChange` for a state the view starts in.
        applyState()
    }

    @objc private func clicked() { toggle() }

    // MARK: State

    /// What the expanded block shows: the element, or a plain statement when the turn no longer
    /// holds it (never a silently empty expansion).
    private var bodyText: String {
        text ?? "(The text of this delivery is no longer retained in this pane. "
            + "It remains in the Claude session transcript on disk.)"
    }

    private func applyState() {
        let arrow = isExpanded ? "▼" : "▶"
        disclosure.attributedTitle = NSAttributedString(string: "\(arrow)  \(summaryText)", attributes: [
            .font:            NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.fgMuted,
        ])
        disclosure.setAccessibilityLabel(
            TerminalDeliveryText.spokenLabel(for: item, isExpanded: isExpanded))
        disclosure.setAccessibilityRole(.button)
        if isExpanded { buildLabelIfNeeded() }
        contentWrap.isHidden = !isExpanded
    }

    /// Builds the text label on first need: most deliveries stay collapsed forever, and shaping a
    /// large blob of text costs a CoreText pass even when the view is hidden.
    private func buildLabelIfNeeded() {
        guard !labelBuilt else { return }
        labelBuilt = true
        let body = bodyText
        let label = CopyMenuTextField(labelWithString: body)
        label.isSelectable         = true   // copyable: text in the transcript must be selectable
        label.lineBreakMode        = .byCharWrapping
        label.maximumNumberOfLines = 0
        // Raw terminal text: ligatures off, so it renders character for character (see
        // `ToolResultView`). The markers of what was withheld stand out against the rest.
        let attributed = NSMutableAttributedString(string: body, attributes: [
            .font:            Theme.monoFont,
            .foregroundColor: Theme.fgMuted,
            .ligature:        0,
        ])
        for range in TerminalDeliveryText.redactionRanges(in: body) {
            attributed.addAttributes([
                .foregroundColor: Theme.amber,
                .backgroundColor: Theme.amber.withAlphaComponent(0.18),
            ], range: range)
        }
        label.attributedStringValue = attributed
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.menuProvider = { [weak self, weak label] in label.flatMap { self?.copyMenu(for: $0) } ?? NSMenu() }
        label.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentWrap.topAnchor),
            label.leadingAnchor.constraint(equalTo: contentWrap.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentWrap.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: contentWrap.bottomAnchor),
        ])
    }

    // MARK: Copy menu

    private func copyMenu(for label: NSTextField) -> NSMenu {
        let hasSelection = (label.currentEditor()?.selectedRange.length ?? 0) > 0
        let menu = NSMenu()
        let entry = menu.addItem(withTitle: hasSelection ? "Copy all output" : "Copy",
                                 action: #selector(copyOutput(_:)), keyEquivalent: "")
        entry.target = self
        return menu
    }

    @objc private func copyOutput(_ sender: NSMenuItem) {
        pasteboard.clearContents()
        pasteboard.setString(bodyText, forType: .string)
    }
}
