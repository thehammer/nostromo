import AppKit
import NostromoKit

// The native `/mcp` panel (`session_mcp_v1`): which MCP servers a session has, their states, and explicit
// Reconnect and Disable/Enable buttons. What the panel shows comes from the daemon's `session_mcp_result`,
// which carries names, states and counts only: never a server's configuration.

// MARK: - McpIntent

enum McpIntent {
    /// Typing exactly `/mcp` (after trimming) opens the panel, but only against a daemon that takes
    /// `session_mcp`. `/mcp <args>`, `/mcpx` and `/MCP` are the CLI's, and are sent as typed.
    static func isPanelRequest(text: String, features: [String]?) -> Bool {
        NostromodClient.supportsSessionMcp(features: features)
            && text.trimmingCharacters(in: .whitespacesAndNewlines) == "/mcp"
    }
}

// MARK: - Columns

/// The table's column widths, shared by the header and every row so they line up.
enum McpColumns {
    static let inset: CGFloat = 16
    static let gap: CGFloat = 8
    static let nameMin: CGFloat = 110
    static let status: CGFloat = 124
    static let scope: CGFloat = 64
    static let transport: CGFloat = 96
    static let tools: CGFloat = 52
    static let spinner: CGFloat = 16
    static let reconnect: CGFloat = 96
    static let toggle: CGFloat = 80
}

// MARK: - Controls

/// A button that takes keyboard focus whenever it is enabled (Tab) and is pressed by Return as well as Space.
final class McpActionButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class McpFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private func mcpLabel(_ font: NSFont, _ color: NSColor, alignment: NSTextAlignment = .left) -> NSTextField {
    let f = NSTextField(labelWithString: "")
    f.font = font
    f.textColor = color
    f.alignment = alignment
    f.lineBreakMode = .byTruncatingTail
    f.maximumNumberOfLines = 1
    f.usesSingleLineMode = true
    f.isSelectable = false
    f.translatesAutoresizingMaskIntoConstraints = false
    f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    f.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return f
}

// MARK: - Row

/// One server: name, status (an icon and a word), scope, transport, tool count, and its two buttons.
final class McpRowView: NSView {
    static let font = NSFont.systemFont(ofSize: 12)
    static let detailFont = NSFont.systemFont(ofSize: 11)
    static let rowHeight: CGFloat = 28

    let nameField = mcpLabel(McpRowView.font, Theme.fg)
    let statusIcon = NSImageView()
    let statusLabel = mcpLabel(McpRowView.font, Theme.fg)
    let scopeField = mcpLabel(McpRowView.font, Theme.fgMuted)
    let transportField = mcpLabel(McpRowView.font, Theme.fgMuted)
    let toolsField = mcpLabel(McpRowView.font, Theme.fgMuted, alignment: .right)
    let errorField = mcpLabel(McpRowView.detailFont, Theme.fgMuted)
    let noteField = mcpLabel(McpRowView.detailFont, Theme.amber)
    let spinner = NSProgressIndicator()
    private let detailStack = NSStackView()
    let reconnectButton = McpActionButton(title: "Reconnect", target: nil, action: nil)
    let toggleButton = McpActionButton(title: "Disable", target: nil, action: nil)

    /// Called with the button that was pressed, so the owner can hold the press to `HumanGesture`.
    var onReconnect: ((NSView) -> Void)?
    var onToggle: ((NSView) -> Void)?
    private(set) var row: McpRow?
    /// How many times `configure` changed what the row shows (a test seam: an unchanged row is left alone).
    private(set) var applyCount = 0
    private var shown: Shown?

    private struct Shown: Equatable {
        let row: McpRow
        let note: McpRowNote?
        let busy: Bool
        let cooling: Bool
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    static func color(for status: McpStatusKind) -> NSColor {
        switch status {
        case .connected: return Theme.sage
        case .needsAuth: return Theme.amber
        case .failed: return Theme.foldFailure
        case .disabled: return Theme.fgMuted
        case .pending, .unknown: return Theme.fg
        }
    }

    static func symbol(for status: McpStatusKind) -> String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .needsAuth: return "key.fill"
        case .failed: return "xmark.octagon.fill"
        case .disabled: return "minus.circle"
        case .pending: return "clock"
        case .unknown: return "questionmark.circle"
        }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        appearance = NSAppearance(named: .darkAqua)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.imageScaling = .scaleProportionallyDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        for button in [reconnectButton, toggleButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnectClicked)
        toggleButton.target = self
        toggleButton.action = #selector(toggleClicked)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The two detail lines collapse to nothing when hidden, so a plain row stays one line tall.
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 0
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addArrangedSubview(errorField)
        detailStack.addArrangedSubview(noteField)
        for v in [nameField, statusIcon, statusLabel, scopeField, transportField, toolsField,
                  spinner, reconnectButton, toggleButton, detailStack] as [NSView] {
            addSubview(v)
        }
        let inset = McpColumns.inset, gap = McpColumns.gap
        let top = McpRowView.rowHeight / 2
        NSLayoutConstraint.activate([
            nameField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            nameField.centerYAnchor.constraint(equalTo: topAnchor, constant: top),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: McpColumns.nameMin),

            statusIcon.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: gap),
            statusIcon.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 14),
            statusIcon.heightAnchor.constraint(equalToConstant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 4),
            statusLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: McpColumns.status - 18),

            scopeField.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: gap),
            scopeField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            scopeField.widthAnchor.constraint(equalToConstant: McpColumns.scope),

            transportField.leadingAnchor.constraint(equalTo: scopeField.trailingAnchor, constant: gap),
            transportField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            transportField.widthAnchor.constraint(equalToConstant: McpColumns.transport),

            toolsField.leadingAnchor.constraint(equalTo: transportField.trailingAnchor, constant: gap),
            toolsField.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            toolsField.widthAnchor.constraint(equalToConstant: McpColumns.tools),

            spinner.leadingAnchor.constraint(equalTo: toolsField.trailingAnchor, constant: gap),
            spinner.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: McpColumns.spinner),
            spinner.heightAnchor.constraint(equalToConstant: McpColumns.spinner),

            reconnectButton.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: gap),
            reconnectButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            reconnectButton.widthAnchor.constraint(equalToConstant: McpColumns.reconnect),

            toggleButton.leadingAnchor.constraint(equalTo: reconnectButton.trailingAnchor, constant: gap),
            toggleButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            toggleButton.widthAnchor.constraint(equalToConstant: McpColumns.toggle),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),

            detailStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            detailStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            detailStack.topAnchor.constraint(equalTo: topAnchor, constant: McpRowView.rowHeight - 6),
            errorField.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            noteField.widthAnchor.constraint(equalTo: detailStack.widthAnchor),
            // The row is as tall as its content: the detail lines (none, one or two) end 6 pt above its
            // bottom edge, and a row with none is the one-line `rowHeight`.
            bottomAnchor.constraint(equalTo: detailStack.bottomAnchor, constant: 6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: McpRowView.rowHeight),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    /// Show `row`. `note` is the last result for this row; `busy` a request in flight; `cooling` the 5 s
    /// after a click. Buttons are off in either case, and for whatever the row may not do.
    func configure(row: McpRow, note: McpRowNote?, busy: Bool, cooling: Bool) {
        let next = Shown(row: row, note: note, busy: busy, cooling: cooling)
        guard next != shown else { return }
        shown = next
        applyCount += 1
        self.row = row
        nameField.stringValue = row.name
        nameField.toolTip = row.name
        let tint = Self.color(for: row.status)
        statusLabel.stringValue = row.statusWord
        statusLabel.textColor = tint
        statusIcon.image = NSImage(systemSymbolName: Self.symbol(for: row.status), accessibilityDescription: nil)
        statusIcon.contentTintColor = tint
        scopeField.stringValue = row.scope
        transportField.stringValue = row.transport
        toolsField.stringValue = row.toolCountText
        // One detail line under the row: the bridge note, else the server's own error.
        let detail = row.bridgeNote ?? row.error
        errorField.stringValue = detail ?? ""
        errorField.textColor = row.bridgeNote == nil ? Theme.fgMuted : Theme.amber
        errorField.isHidden = detail == nil
        noteField.stringValue = note?.text ?? ""
        noteField.textColor = (note?.isError ?? true) ? Theme.amber : Theme.fgMuted
        noteField.isHidden = note == nil

        reconnectButton.isHidden = !row.canReconnect
        toggleButton.isHidden = !row.canToggle
        toggleButton.title = row.toggleTitle
        let idle = !busy && !cooling
        reconnectButton.isEnabled = idle
        toggleButton.isEnabled = idle
        reconnectButton.setAccessibilityLabel(row.reconnectLabel)
        toggleButton.setAccessibilityLabel(row.toggleLabel)
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        setAccessibilityLabel(row.rowLabel + (note.map { ", \($0.text)" } ?? ""))
    }

    @objc private func reconnectClicked() { onReconnect?(reconnectButton) }
    @objc private func toggleClicked() { onToggle?(toggleButton) }
}

/// The result of the last action on a row: shown under it.
struct McpRowNote: Equatable {
    let text: String
    let isError: Bool
}

// MARK: - Panel view

/// The sheet's content: header, column titles, the rows, a state line, the footnote, Refresh and Close.
final class McpPanelView: NSView {
    static let defaultSize = NSSize(width: 820, height: 460)
    static let minSize = NSSize(width: 740, height: 340)

    let titleField = mcpLabel(NSFont.systemFont(ofSize: 14, weight: .semibold), Theme.fg)
    let subtitleField = mcpLabel(NSFont.systemFont(ofSize: 11), Theme.fgMuted)
    let stateField = NSTextField(wrappingLabelWithString: "")
    let footnoteField = mcpLabel(NSFont.systemFont(ofSize: 11), Theme.fgMuted)
    let refreshButton = McpActionButton(title: "Refresh", target: nil, action: nil)
    let closeButton = McpActionButton(title: "Close", target: nil, action: nil)
    private(set) var rowViews: [McpRowView] = []
    /// How often the row stack was rebuilt (a test seam).
    private(set) var stackRebuildCount = 0

    private let columnHeader = NSView()
    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        appearance = NSAppearance(named: .darkAqua)

        stateField.font = NSFont.systemFont(ofSize: 12)
        stateField.textColor = Theme.fg
        stateField.isSelectable = false
        stateField.translatesAutoresizingMaskIntoConstraints = false
        footnoteField.stringValue = McpPanelModel.footnote
        subtitleField.stringValue = McpPanelModel.header
        refreshButton.bezelStyle = .rounded
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"
        for b in [refreshButton, closeButton] { b.translatesAutoresizingMaskIntoConstraints = false }
        refreshButton.setAccessibilityLabel("Refresh MCP servers")
        closeButton.setAccessibilityLabel("Close")

        buildColumnHeader()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = McpFlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        columnHeader.translatesAutoresizingMaskIntoConstraints = false

        for v in [titleField, subtitleField, columnHeader, scroll, stateField, footnoteField, refreshButton, closeButton] as [NSView] {
            addSubview(v)
        }
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: McpColumns.inset),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -McpColumns.inset),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),

            columnHeader.topAnchor.constraint(equalTo: subtitleField.bottomAnchor, constant: 10),
            columnHeader.leadingAnchor.constraint(equalTo: leadingAnchor),
            columnHeader.trailingAnchor.constraint(equalTo: trailingAnchor),
            columnHeader.heightAnchor.constraint(equalToConstant: 20),

            scroll.topAnchor.constraint(equalTo: columnHeader.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),

            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            stateField.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            stateField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: McpColumns.inset),
            stateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -McpColumns.inset),

            footnoteField.topAnchor.constraint(equalTo: stateField.bottomAnchor, constant: 4),
            footnoteField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: McpColumns.inset),
            footnoteField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -McpColumns.inset),

            refreshButton.topAnchor.constraint(equalTo: footnoteField.bottomAnchor, constant: 10),
            refreshButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: McpColumns.inset),
            closeButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -McpColumns.inset),
            refreshButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func buildColumnHeader() {
        func title(_ text: String, alignment: NSTextAlignment = .left) -> NSTextField {
            let f = mcpLabel(NSFont.systemFont(ofSize: 10, weight: .semibold), Theme.fgMuted, alignment: alignment)
            f.stringValue = text.uppercased()
            f.setAccessibilityElement(false)
            columnHeader.addSubview(f)
            return f
        }
        let name = title("Server"), status = title("Status"), scope = title("Scope")
        let transport = title("Transport"), tools = title("Tools", alignment: .right)
        let gap = McpColumns.gap
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: columnHeader.leadingAnchor, constant: McpColumns.inset),
            name.centerYAnchor.constraint(equalTo: columnHeader.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: gap),
            status.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: McpColumns.status),
            scope.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: gap),
            scope.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            scope.widthAnchor.constraint(equalToConstant: McpColumns.scope),
            transport.leadingAnchor.constraint(equalTo: scope.trailingAnchor, constant: gap),
            transport.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            transport.widthAnchor.constraint(equalToConstant: McpColumns.transport),
            tools.leadingAnchor.constraint(equalTo: transport.trailingAnchor, constant: gap),
            tools.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            tools.widthAnchor.constraint(equalToConstant: McpColumns.tools),
            // The name column ends where a row's does: everything to its right is fixed.
            name.trailingAnchor.constraint(equalTo: columnHeader.trailingAnchor,
                constant: -(McpColumns.inset + 7 * gap + McpColumns.status + McpColumns.scope + McpColumns.transport
                            + McpColumns.tools + McpColumns.spinner + McpColumns.reconnect + McpColumns.toggle)),
        ])
    }

    /// Show `rows`. The same row views in the same order leave the stack alone; only a different set rebuilds it.
    /// Either way the Tab order is rebuilt, because a button may have appeared, vanished or been enabled.
    func show(rows: [McpRowView], stateText: String?, showFootnote: Bool, refreshEnabled: Bool) {
        if !rows.elementsEqual(rowViews, by: ===) {
            // Keyboard focus survives the rebuild: find the same button in the new rows.
            let focused = window?.firstResponder as? McpActionButton
            let focusedKey = focused.flatMap { button -> (Int, Bool)? in
                guard let idx = rowViews.firstIndex(where: { $0.reconnectButton === button || $0.toggleButton === button }) else { return nil }
                return (idx, rowViews[idx].reconnectButton === button)
            }
            for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
            rowViews = rows
            for r in rows {
                stack.addArrangedSubview(r)
                r.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                r.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
            stackRebuildCount += 1
            if let (idx, wasReconnect) = focusedKey, idx < rows.count {
                let target = wasReconnect ? rows[idx].reconnectButton : rows[idx].toggleButton
                if target.isEnabled { window?.makeFirstResponder(target) }
            }
        }
        columnHeader.isHidden = rows.isEmpty
        stateField.stringValue = stateText ?? ""
        stateField.isHidden = stateText == nil
        footnoteField.isHidden = !showFootnote
        refreshButton.isEnabled = refreshEnabled
        rebuildKeyLoop()
    }

    /// Tab order, set by hand and rebuilt after every render (the rows are made after the window is up, and
    /// the window does not work one out for itself): each row's Reconnect then Disable/Enable, in order,
    /// then Refresh, then Close, then round again. A button that is off stays in the chain; the window skips it.
    private func rebuildKeyLoop() {
        var chain: [NSView] = []
        for row in rowViews {
            for button in [row.reconnectButton, row.toggleButton] {
                if button.isHidden { button.nextKeyView = nil } else { chain.append(button) }
            }
        }
        chain += [refreshButton, closeButton]
        for (a, b) in zip(chain, chain.dropFirst()) { a.nextKeyView = b }
        chain.last?.nextKeyView = chain.first
    }

    func setHeader(focusName: String) {
        titleField.stringValue = "MCP servers · \(focusName)"
        closeButton.setAccessibilityLabel("Close MCP servers")
    }
}

// MARK: - Confirmation

/// A sheet window that turns Esc into its own cancel.
final class McpConfirmWindow: NSWindow {
    var cancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { cancel?() }
}

/// "Disable this MCP server?": Cancel is the default button (Return), so Return can never confirm the
/// disable; Disable is a separate, destructive button that has to be pressed.
final class McpConfirmSheet {
    let window: McpConfirmWindow
    let message: String
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let disableButton = NSButton(title: "Disable", target: nil, action: nil)

    init(message: String) {
        self.message = message
        window = McpConfirmWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled],
                                  backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let title = NSTextField(labelWithString: "Disable this MCP server?")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: message)
        body.font = NSFont.systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = 380
        cancelButton.keyEquivalent = "\r"
        cancelButton.setAccessibilityLabel("Cancel")
        disableButton.hasDestructiveAction = true
        disableButton.setAccessibilityLabel("Disable")
        for v in [title, body, cancelButton, disableButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            window.contentView?.addSubview(v)
        }
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cancelButton.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 16),
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancelButton.widthAnchor.constraint(equalToConstant: 80),
            disableButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -10),
            disableButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            disableButton.widthAnchor.constraint(equalToConstant: 80),
        ])
        window.initialFirstResponder = cancelButton
    }
}

// MARK: - Controller

/// Owns one open panel: asks the daemon, keeps the rows' state, rate-limits clicks on this side too,
/// and confirms a disable before sending it.
final class McpPanelController: NSObject {
    /// A clicked row's buttons stay off this long, whatever the daemon answers.
    static let cooldown: TimeInterval = 5

    /// The panels that are open, by tag: a second `/mcp` while one is open does nothing.
    private static var open: [String: McpPanelController] = [:]

    let tag: String
    let focusName: String
    let projectPath: String?
    let panelView = McpPanelView(frame: NSRect(origin: .zero, size: McpPanelView.defaultSize))
    private(set) var phase: McpPanelPhase = .loading
    private(set) var notes: [String: McpRowNote] = [:]
    private(set) var inFlight: Set<String> = []
    private(set) var isRefreshing = false
    private(set) var isClosed = false

    /// Whether a press is a person's own (`HumanGesture`): Reconnect, Enable, Disable and the confirmation's
    /// Disable all ask first, so app-control input or an Accessibility press does nothing. Tests replace it.
    var permit: (NSView) -> HumanGestureVerdict = { HumanGesture.permit(NSApp?.currentEvent, control: $0) }

    /// The confirmation sheet while it is up (a test seam: its buttons are the real ones).
    private(set) var confirmSheet: McpConfirmSheet?
    /// The sheet this panel is shown in (a test seam).
    var sheetWindow: NSWindow? { sheet }
    /// How many times the rows were brought up to date (a test seam).
    private(set) var renderCount = 0

    /// Asks before a disable; calls back with the answer. The default is a sheet on the panel.
    var confirmDisable: (_ message: String, _ completion: @escaping (Bool) -> Void) -> Void = { _, completion in completion(false) }

    private let requests: McpRequests
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var cooldownUntil: [String: Date] = [:]
    /// One row view per server name, kept between renders: a change touches its own row, not all of them.
    private var rowViewsByName: [String: McpRowView] = [:]
    private var sheet: NSWindow?
    private weak var parent: NSWindow?

    init(tag: String, focusName: String, projectPath: String?, requests: McpRequests = .shared,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.tag = tag
        self.focusName = focusName
        self.projectPath = projectPath
        self.requests = requests
        self.now = now
        self.schedule = schedule
        super.init()
        panelView.setHeader(focusName: focusName)
        panelView.refreshButton.target = self
        panelView.refreshButton.action = #selector(refreshClicked)
        panelView.closeButton.target = self
        panelView.closeButton.action = #selector(closeClicked)
        confirmDisable = { [weak self] message, completion in
            guard let self else { return completion(false) }
            self.confirmWithSheet(message, completion)
        }
        render()
    }

    // MARK: Opening

    /// Open the panel for `tag` as a sheet on `window` and ask for the list. A panel already open for
    /// `tag` is left alone.
    @discardableResult
    static func present(on window: NSWindow?, tag: String, focusName: String, projectPath: String?) -> McpPanelController? {
        guard open[tag] == nil else { return open[tag] }
        let controller = McpPanelController(tag: tag, focusName: focusName, projectPath: projectPath)
        open[tag] = controller
        controller.show(on: window)
        return controller
    }

    func show(on window: NSWindow?) {
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: McpPanelView.defaultSize),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.title = "MCP servers"
        sheet.isReleasedWhenClosed = false
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.contentMinSize = McpPanelView.minSize
        sheet.contentView = panelView
        self.sheet = sheet
        parent = window
        // Only ever a sheet on a pane's window, never a free-floating window.
        guard let window else { finishClose(); return }
        window.beginSheet(sheet) { [weak self] _ in self?.finishClose() }
        sheet.makeFirstResponder(panelView.refreshButton)
        refresh()
    }

    // MARK: Actions

    func refresh() {
        guard !isRefreshing, !isClosed else { return }
        isRefreshing = true
        render()
        requests.request(tag: tag, action: "status") { [weak self] reply in
            self?.isRefreshing = false
            self?.handle(reply, server: nil, done: nil)
        }
    }

    func reconnect(_ server: String) {
        guard canStart(server) else { return }
        start(server)
        requests.request(tag: tag, action: "reconnect", server: server) { [weak self] reply in
            self?.handle(reply, server: server, done: "Reconnected.")
        }
    }

    /// Enable at once; disable after the confirmation.
    func toggle(_ server: String) {
        guard canStart(server), case .list(let rows) = phase,
              let row = rows.first(where: { $0.name == server }), row.canToggle else { return }
        if row.isDisabled {
            start(server)
            requests.request(tag: tag, action: "toggle", server: server, enabled: true) { [weak self] reply in
                self?.handle(reply, server: server, done: "Enabled.")
            }
        } else {
            confirmDisable(McpPanelModel.disableConfirmation(server: server, folder: projectPath)) { [weak self] confirmed in
                guard let self, confirmed, self.canStart(server) else { return }
                self.start(server)
                self.requests.request(tag: self.tag, action: "toggle", server: server, enabled: false) { [weak self] reply in
                    self?.handle(reply, server: server, done: "Disabled.")
                }
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        if let sheet, let parent, parent.sheets.contains(sheet) {
            parent.endSheet(sheet)
        } else {
            sheet?.orderOut(nil)
            finishClose()
        }
    }

    // MARK: State

    /// Whether `server`'s buttons are off: a request is running, or the last click is under 5 s old.
    func isCoolingOrBusy(_ server: String) -> Bool {
        inFlight.contains(server) || (cooldownUntil[server].map { $0 > now() } ?? false)
    }

    private func canStart(_ server: String) -> Bool { !isClosed && !isCoolingOrBusy(server) }

    private func start(_ server: String) {
        inFlight.insert(server)
        cooldownUntil[server] = now().addingTimeInterval(Self.cooldown)
        notes[server] = nil
        schedule(Self.cooldown) { [weak self] in self?.render() }
        render()
    }

    private func handle(_ reply: TaskReply<SessionMcpResultWire>, server: String?, done: String?) {
        if let server { inFlight.remove(server) }
        guard !isClosed else { return }
        switch reply {
        case .answered(let wire):
            if let next = McpPanelModel.phase(for: wire) { phase = next }
            if case .notRunning = phase { notes.removeAll() }
            if let server {
                switch wire.outcome {
                case .ok:
                    let text = wire.message.flatMap { $0.isEmpty ? nil : "\(done ?? "") \($0)" } ?? done
                    notes[server] = text.map { McpRowNote(text: $0.trimmingCharacters(in: .whitespaces), isError: false) }
                case .notRunning, .unsupported:
                    break
                default:
                    notes[server] = McpRowNote(text: McpPanelModel.failureText(wire), isError: true)
                }
            }
        case .timedOut:
            fail("The daemon did not answer in time.", server: server)
        case .failed(let reason):
            fail(reason, server: server)
        }
        render()
    }

    private func fail(_ text: String, server: String?) {
        if let server {
            notes[server] = McpRowNote(text: text, isError: true)
        } else {
            phase = .failed(text)
        }
    }

    private func render() {
        renderCount += 1
        var rows: [McpRowView] = []
        var stateText: String?
        var footnote = false
        switch phase {
        case .loading:
            stateText = "Loading MCP servers…"
        case .list(let list):
            footnote = true
            if list.isEmpty { stateText = "This session has no MCP servers." }
            var kept: [String: McpRowView] = [:]
            for row in list {
                // A name seen twice gets a view of its own that is not kept.
                let view = kept[row.name] == nil ? (rowViewsByName[row.name] ?? makeRowView(for: row.name)) : makeRowView(for: row.name)
                view.configure(row: row, note: notes[row.name], busy: inFlight.contains(row.name),
                               cooling: isCoolingOrBusy(row.name))
                if kept[row.name] == nil { kept[row.name] = view }
                rows.append(view)
            }
            rowViewsByName = kept
        case .notRunning:
            stateText = McpPanelModel.notRunningMessage
        case .unsupported(let message):
            stateText = String(message.prefix(1)).uppercased() + String(message.dropFirst()) + "."
        case .failed(let message):
            stateText = message
        }
        if case .list = phase {} else { rowViewsByName = [:] }
        if isRefreshing, case .list = phase { stateText = "Refreshing…" }
        panelView.show(rows: rows, stateText: stateText, showFootnote: footnote, refreshEnabled: !isRefreshing)
    }

    private func makeRowView(for name: String) -> McpRowView {
        let view = McpRowView()
        view.onReconnect = { [weak self] button in
            guard let self, self.isHuman(button) else { return }
            self.reconnect(name)
        }
        view.onToggle = { [weak self] button in
            guard let self, self.isHuman(button) else { return }
            self.toggle(name)
        }
        return view
    }

    private func isHuman(_ control: NSView) -> Bool {
        if case .human = permit(control) { return true }
        return false
    }

    private func confirmWithSheet(_ message: String, _ completion: @escaping (Bool) -> Void) {
        guard let sheet else { return completion(false) }
        let confirm = McpConfirmSheet(message: message)
        // Disable is pressed by a person or not at all: it ends the sheet itself once `permit` says so.
        confirm.disableButton.target = self
        confirm.disableButton.action = #selector(confirmDisableClicked(_:))
        confirm.cancelButton.target = self
        confirm.cancelButton.action = #selector(confirmCancelClicked(_:))
        confirm.window.cancel = { [weak self] in self?.endConfirmation(confirmed: false) }
        confirmSheet = confirm
        sheet.beginSheet(confirm.window) { [weak self] response in
            self?.confirmSheet = nil
            completion(response == .OK)
        }
    }

    @objc private func confirmDisableClicked(_ sender: NSButton) {
        guard isHuman(sender) else { return }
        endConfirmation(confirmed: true)
    }

    @objc private func confirmCancelClicked(_ sender: NSButton) { endConfirmation(confirmed: false) }

    private func endConfirmation(confirmed: Bool) {
        guard let confirm = confirmSheet else { return }
        sheet?.endSheet(confirm.window, returnCode: confirmed ? .OK : .cancel)
    }

    private func finishClose() {
        guard !isClosed else { return }
        isClosed = true
        sheet?.orderOut(nil)
        sheet = nil
        if Self.open[tag] === self { Self.open[tag] = nil }
    }

    @objc private func refreshClicked() { refresh() }
    @objc private func closeClicked() { close() }
}
