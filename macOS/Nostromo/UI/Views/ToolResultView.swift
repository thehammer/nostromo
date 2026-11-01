import AppKit
import NostromoKit

// MARK: - ToolResultView

/// Tool result block — collapsed by default showing a line count chip.
/// Click to expand/collapse. Errors always start expanded.
///
/// Moved out of `ReplView.swift` so it can be compiled into the logic test
/// bundle: turn views are now destroyed and rebuilt routinely (eviction from the
/// materialized window, and every pane width change), so expansion state has to
/// be restored from `TurnInteractionStore` rather than assumed to survive in the
/// view. Without that, an expanded tool result silently re-collapsed after
/// eviction while `TurnListVirtualizer`'s height cache — keyed by content, which
/// is invariant across expansion — still held the *expanded* height, leaving
/// geometry and view disagreeing until the next measure.
final class ToolResultView: NSView {

    private var isExpanded  = false
    private let disclosure  = NSButton()
    private let contentWrap = NSView()
    private let lineCount:  Int
    private let content:    String
    private let isError:    Bool
    /// False when the turn's payload was dropped past the retention cap.
    /// Expanding then states that plainly instead of showing nothing.
    private let contentAvailable: Bool
    /// Guards against building the expensive full-content label more than once.
    private var labelBuilt  = false

    /// Where "Copy" puts the output. Injectable so tests never touch the
    /// operator's real clipboard.
    var pasteboard: NSPasteboard = .general

    /// Fired on expand/collapse with the *new* state, so the turn's height can be
    /// re-measured and the operator's choice persisted outside this view.
    var onExpansionChange: ((Bool) -> Void)?

    /// - Parameter explicitState: the operator's saved choice (`TranscriptFoldStore`), nil when
    ///   there is none: the result is then open when it is an error (TF4's rule).
    ///   Deliberately has **no default value**: the compiler is then the wiring
    ///   check for every construction site.
    init(data: ToolResultData, contentAvailable: Bool, explicitState: Bool?) {
        let nonEmpty = data.content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        lineCount  = max(nonEmpty.count, 1)
        content    = data.content
        isError    = data.isError
        self.contentAvailable = contentAvailable
        isExpanded = explicitState ?? data.isError

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        layer?.cornerRadius    = 6
        layer?.borderWidth     = 1
        layer?.borderColor     = isError
            ? Theme.redSweater.withAlphaComponent(0.5).cgColor
            : Theme.borderInactive.withAlphaComponent(0.6).cgColor

        // Disclosure button (always visible)
        disclosure.isBordered = false
        disclosure.target     = self
        disclosure.action     = #selector(toggleExpand)
        disclosure.translatesAutoresizingMaskIntoConstraints = false

        // Content label is built lazily (see buildLabelIfNeeded) — most tool
        // results are non-error and stay collapsed forever, and merely
        // constructing NSTextField(labelWithString:) with a large blob
        // triggers a full CoreText glyph-shaping pass via its internal
        // sizeToFit(), even when the view is immediately hidden. Replaying a
        // long-lived session's full turn history was paying that cost for
        // every historical tool result up front, pegging the main thread for
        // tens of seconds on launch/reconnect for no visible benefit.
        contentWrap.translatesAutoresizingMaskIntoConstraints = false

        // NSStackView collapses hidden arranged subviews automatically
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
            // alignment=.width doesn't reliably fill arranged subviews to stack width
            disclosure.widthAnchor.constraint(equalTo: vStack.widthAnchor),
            contentWrap.widthAnchor.constraint(equalTo: vStack.widthAnchor),
        ])

        // Restoring is silent: `applyState()` renders the restored state without
        // firing `onExpansionChange`, so re-materializing a turn never looks like
        // the operator clicking.
        applyState()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleExpand() {
        isExpanded.toggle()
        applyState()
        // The turn's height just changed. `ReplView` owns the geometry now, so
        // tell it rather than nudging AppKit and hoping — a stale height would
        // overlap this turn with its neighbour. The new state goes with it so the
        // choice outlives this view.
        onExpansionChange?(isExpanded)
    }

    /// Builds the full-content label on first actual need (see the doc
    /// comment on `contentWrap` in `init`). Safe to call repeatedly.
    private func buildLabelIfNeeded() {
        guard !labelBuilt else { return }
        labelBuilt = true
        // Never a silently-empty expansion: if the payload is gone, say so.
        let body = contentAvailable
            ? content
            : "(The full content of this tool result is no longer retained in this pane. "
              + "It remains in the Claude session transcript on disk.)"
        let label = CopyMenuTextField(labelWithString: body)
        label.isSelectable = true   // copyable: text in the transcript must be selectable
        label.lineBreakMode        = .byCharWrapping
        label.maximumNumberOfLines = 0
        // This is raw tool output (shell text, JSON, diffs) — it must render
        // character-for-character. Fira Code's `calt`-driven programming
        // ligatures apply by default to static NSTextField labels (unlike
        // NSTextView, which needs an explicit opt-in — see ChatTextView's
        // `.ligature = 2`), and they merge runs of hyphens (`---`) into a
        // single em-dash-like glyph and collapse things like `->`/`!=`. That
        // reads as data corruption when the text is meant to be verbatim, so
        // ligatures are explicitly disabled here.
        label.attributedStringValue = NSAttributedString(string: body, attributes: [
            .font:            Theme.monoFont,
            .foregroundColor: isError ? Theme.redSweater : Theme.fgMuted,
            .ligature:        0,
        ])
        // Biggest balloon driver: long single-line tool output (JSON, git status) had
        // an intrinsic width of ~8600pt. Yield horizontally so it wraps to the pane.
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

    /// Idle, "Copy" takes the whole output. Once the label holds a selection the
    /// field editor puts its own "Copy" (the selection) first, so this one is
    /// relabelled rather than duplicated.
    private func copyMenu(for label: NSTextField) -> NSMenu {
        let hasSelection = (label.currentEditor()?.selectedRange.length ?? 0) > 0
        let menu = NSMenu()
        let item = menu.addItem(withTitle: hasSelection ? "Copy all output" : "Copy",
                                action: #selector(copyOutput(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = label
        return menu
    }

    @objc private func copyOutput(_ sender: NSMenuItem) {
        guard let text = (sender.representedObject as? NSTextField)?.stringValue else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func applyState() {
        let arrow = isExpanded ? "▼" : "▶"
        let count = "\(lineCount) line\(lineCount == 1 ? "" : "s")"
        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.fgMuted,
        ]
        disclosure.attributedTitle = NSAttributedString(string: "\(arrow)  \(count)", attributes: attrs)
        if isExpanded { buildLabelIfNeeded() }
        contentWrap.isHidden = !isExpanded
    }
}

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
/// Expansion is kept outside the view (`TranscriptFoldStore`, through `onExpansionChange` and
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
