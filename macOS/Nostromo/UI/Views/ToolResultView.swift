import AppKit

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

    /// Fired on expand/collapse with the *new* state, so the turn's height can be
    /// re-measured and the operator's choice persisted outside this view.
    var onExpansionChange: ((Bool) -> Void)?

    /// - Parameter startExpanded: restored from `TurnInteractionState`.
    ///   Deliberately has **no default value**: the compiler is then the wiring
    ///   check for the single construction site in `ChatTurnView`.
    init(data: ToolResultData, contentAvailable: Bool, startExpanded: Bool) {
        let nonEmpty = data.content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        lineCount  = max(nonEmpty.count, 1)
        content    = data.content
        isError    = data.isError
        self.contentAvailable = contentAvailable
        isExpanded = data.isError || startExpanded   // errors always open

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
        let label = NSTextField(labelWithString: body)
        label.font                 = Theme.monoFont
        label.textColor            = isError ? Theme.redSweater : Theme.fgMuted
        label.lineBreakMode        = .byCharWrapping
        label.maximumNumberOfLines = 0
        // Biggest balloon driver: long single-line tool output (JSON, git status) had
        // an intrinsic width of ~8600pt. Yield horizontally so it wraps to the pane.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentWrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentWrap.topAnchor),
            label.leadingAnchor.constraint(equalTo: contentWrap.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentWrap.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: contentWrap.bottomAnchor),
        ])
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
