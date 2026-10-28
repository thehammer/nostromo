import AppKit
import os

private let sheetLog = Logger(subsystem: "com.hammer.nostromo", category: "terminal")

/// "Connect to PRODUCTION": the one place a production shell opens.
///
/// It shows what will run (Command, Profile, Cluster, as the daemon pinned them) in a wrapping,
/// selectable block that is never cut. Connect is off when the daemon did not send a command: nothing
/// is authorised that the sheet does not show. An agent's name, focus and stated reason are marked as
/// the agent's and sanitised (`RemoteShellStore.sheetModel`).
///
/// Nothing has contacted AWS when this appears; the daemon launches `aws` only after it receives a
/// `connect` answer, and this sheet sends that answer from exactly one place, the Connect button.
///
/// - **Cancel** is the default button (`keyEquivalent = "\r"`), so Return cancels, and Escape cancels
///   too (an invisible second button and `cancelOperation` on the sheet's window).
/// - **Connect** has no key equivalent. It is a key view whatever the Keyboard navigation setting is
///   (`ConnectButton`), so Tab reaches it and Space presses it. Its action asks
///   `TerminalInputGuard.allowsControl` first: a synthesized click, a marked key or an Accessibility
///   press does nothing, is reported to the daemon, and leaves the sheet up.
/// - Any other way the sheet goes away without an answer (the window closed) counts as dismissed.
///   `closeWithoutAnswering` (the daemon resolved the request) sends nothing.
///
/// For a shell an agent (a focus) asked for there is one more choice, "Let <agent> follow this shell's
/// output", **unticked** every time the sheet appears. Connect sends it as `invite_follow`; no other
/// answer does, and a shell the user opened (or reconnected from a toast) has no checkbox and sends `false`.
///
/// Presented with `beginSheet` by `RemoteShellPresenter`, never run modally (see `DecisionSheet`).
final class RemoteShellConfirmSheet: NSWindowController, NSWindowDelegate {

    /// Connect is reachable with Tab whatever "Keyboard navigation" says (a plain `NSButton` joins the
    /// key view loop only when Full Keyboard Access is on). It is still never the default button.
    private final class ConnectButton: NSButton {
        override var canBecomeKeyView: Bool { true }
        override var acceptsFirstResponder: Bool { true }
    }

    /// Escape lands in `cancelOperation`, which cancels like the Cancel button.
    private final class SheetWindow: NSWindow {
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) {
            onCancel?()
        }
    }

    private static let contentWidth: CGFloat = 480
    /// The most height the Command / Profile / Cluster block takes; a longer command scrolls inside it.
    /// Tall enough for the longest command the daemon accepts (256 characters, about four wrapped
    /// lines) plus the Profile and Cluster rows, so the last row is never cut off.
    private static let maxDetailsHeight: CGFloat = 260

    let requestId: String
    private let store: RemoteShellStore
    private let terminals: TerminalSessionStore

    private let cancelButton = NSButton(frame: .zero)
    private let connectButton = ConnectButton(frame: .zero)
    /// Invisible, so Escape has a key equivalent without a second visible button.
    private let escapeButton = NSButton(frame: .zero)
    /// "Let <agent> follow this shell's output": present only for an agent's request, unticked.
    private let followCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// Set before anything that can close the sheet, so no later path can answer for it.
    private var resolved = false
    /// Why Connect is off (the sheet can't show what would run). Nil when Connect is offered.
    private let connectBlockedReason: String?

    init(request: RemoteShellConfirmRequest, model: RemoteShellSheetModel,
         store: RemoteShellStore = .shared, terminals: TerminalSessionStore = .shared) {
        self.requestId = request.requestId
        self.store = store
        self.terminals = terminals
        self.connectBlockedReason = model.connectBlockedReason

        let win = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Remote shell"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.initialFirstResponder = nil

        super.init(window: win)
        win.delegate = self
        win.onCancel = { [weak self] in self?.cancelTapped(nil) }
        buildContent(model: model)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Closing without an answer

    /// The daemon resolved the request (or another sheet replaced this one): close without sending
    /// anything. `completion` runs once the sheet is off its window.
    func closeWithoutAnswering(completion: (() -> Void)? = nil) {
        guard !resolved else {
            completion?()
            return
        }
        resolved = true
        disableButtons()
        endSheetIfPresented(completion: completion)
    }

    /// The window closed some way that is not Cancel or Connect: that is a dismissal, never a Connect.
    func windowWillClose(_ notification: Notification) {
        finish(decision: .dismiss)
    }

    // MARK: - Build

    private func buildContent(model: RemoteShellSheetModel) {
        guard let contentView = window?.contentView else { return }
        let textWidth = Self.contentWidth - 40

        // Largest, bold, red: what this connects to, named first. It wraps: a long name is never cut.
        let titleLabel = NSTextField(wrappingLabelWithString: model.title)
        titleLabel.preferredMaxLayoutWidth = textWidth
        titleLabel.font = .systemFont(ofSize: 30, weight: .heavy)
        titleLabel.textColor = .systemRed
        titleLabel.maximumNumberOfLines = 0
        titleLabel.isSelectable = false
        titleLabel.setAccessibilityIdentifier("remote-shell-title")

        // The shell type is last, so a long project or service name must not push it out of view.
        let subtitleLabel = NSTextField(wrappingLabelWithString: model.subtitle)
        subtitleLabel.preferredMaxLayoutWidth = textWidth
        subtitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitleLabel.textColor = .white
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.isSelectable = false
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setAccessibilityIdentifier("remote-shell-target")

        var rows: [NSView] = [titleLabel, subtitleLabel]
        rows.append(makeDetailsBlock(model.details, width: textWidth))

        if let blocked = connectBlockedReason {
            let blockedLabel = NSTextField(wrappingLabelWithString: blocked)
            blockedLabel.preferredMaxLayoutWidth = textWidth
            blockedLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            blockedLabel.textColor = .systemRed
            blockedLabel.maximumNumberOfLines = 0
            blockedLabel.setAccessibilityIdentifier("remote-shell-blocked")
            rows.append(blockedLabel)
        }

        // Agent-supplied text: marked as such, on its own lines, never inside quote marks.
        if let requestedBy = model.requestedBy {
            let requesterLabel = NSTextField(wrappingLabelWithString: requestedBy)
            requesterLabel.preferredMaxLayoutWidth = textWidth
            requesterLabel.font = .systemFont(ofSize: 13)
            requesterLabel.textColor = .secondaryLabelColor
            requesterLabel.maximumNumberOfLines = 0
            requesterLabel.isSelectable = false
            requesterLabel.setAccessibilityIdentifier("remote-shell-requester")
            rows.append(requesterLabel)
        }
        if let reason = model.reason {
            let heading = NSTextField(labelWithString: "Agent's stated reason (unverified)")
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = .tertiaryLabelColor
            heading.setAccessibilityIdentifier("remote-shell-reason-heading")
            rows.append(heading)

            let reasonLabel = NSTextField(wrappingLabelWithString: reason)
            reasonLabel.preferredMaxLayoutWidth = textWidth
            reasonLabel.font = .systemFont(ofSize: 13)
            reasonLabel.textColor = .secondaryLabelColor
            reasonLabel.maximumNumberOfLines = 0
            reasonLabel.isSelectable = false
            reasonLabel.setAccessibilityIdentifier("remote-shell-reason")
            rows.append(reasonLabel)
        }
        if let title = model.followCheckboxTitle {
            followCheckbox.title = title
            // Never on until a person ticks it.
            followCheckbox.state = .off
            // A long agent name wraps; the sheet never cuts what it says.
            followCheckbox.lineBreakMode = .byWordWrapping
            followCheckbox.translatesAutoresizingMaskIntoConstraints = false
            followCheckbox.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth).isActive = true
            followCheckbox.setAccessibilityIdentifier("remote-shell-follow")
            rows.append(followCheckbox)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        configureButtons()
        let buttons = NSStackView(views: [cancelButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)

        // Zero-size and see-through, but in the hierarchy: a key equivalent only fires for a visible view.
        escapeButton.title = ""
        escapeButton.isBordered = false
        escapeButton.keyEquivalent = "\u{1b}"
        escapeButton.target = self
        escapeButton.action = #selector(cancelTapped(_:))
        escapeButton.alphaValue = 0
        escapeButton.setAccessibilityElement(false)
        escapeButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(escapeButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),

            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 22),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            escapeButton.widthAnchor.constraint(equalToConstant: 1),
            escapeButton.heightAnchor.constraint(equalToConstant: 1),
            escapeButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            escapeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window?.fitContent(toWidth: Self.contentWidth)
    }

    /// Command, Profile and Cluster: what will run. Selectable and monospaced, wrapped at any
    /// character (a long command has no spaces to break at) and never cut. It grows with its text up to
    /// `maxDetailsHeight`, then scrolls inside itself.
    private func makeDetailsBlock(_ details: [RemoteShellDetail], width: CGFloat) -> NSView {
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let text = NSMutableAttributedString()
        for (index, detail) in details.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n\n")) }
            text.append(NSAttributedString(string: detail.label.uppercased() + "\n", attributes: [
                .font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]))
            text.append(NSAttributedString(string: detail.value, attributes: [
                .font: valueFont, .foregroundColor: NSColor.white]))
        }

        let inset = NSSize(width: 8, height: 8)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        textView.textContainerInset = inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(text)
        textView.setAccessibilityIdentifier("remote-shell-details")

        // Lay the text out at the final width to learn how tall it needs to be.
        let container = textView.textContainer
        container?.containerSize = NSSize(width: width - 2 * inset.width, height: .greatestFiniteMagnitude)
        if let container { textView.layoutManager?.ensureLayout(for: container) }
        let used = container.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 0
        // A little slack for the scroll view's border, so the last line is not clipped.
        let needed = ceil(used) + 2 * inset.height + 4

        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        // Always visible: if the block ever does scroll, the user can see there is more below.
        scroll.autohidesScrollers = false
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = textView.backgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: width),
            scroll.heightAnchor.constraint(equalToConstant: min(needed, Self.maxDetailsHeight)),
        ])
        return scroll
    }

    private func configureButtons() {
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.setAccessibilityIdentifier("remote-shell-cancel")

        connectButton.title = "Connect"
        connectButton.bezelStyle = .rounded
        connectButton.target = self
        connectButton.action = #selector(connectTapped(_:))
        // Nothing may be authorised that the sheet does not show.
        connectButton.isEnabled = connectBlockedReason == nil
        connectButton.setAccessibilityIdentifier("remote-shell-connect")
    }

    // MARK: - Actions

    /// Cancel, Return and Escape. Harmless: it can only stop a connection, so it needs no gesture.
    @objc private func cancelTapped(_ sender: Any?) {
        finish(decision: .cancel)
    }

    /// The only thing that can open a production shell. A person's click, or Tab then Space.
    @objc private func connectTapped(_ sender: NSButton) {
        guard connectBlockedReason == nil else { return }
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            sheetLog.notice("connect refused: not a human gesture (request \(self.requestId, privacy: .public))")
            terminals.reportRefusal(terminalId: nil, op: .connect)
            return
        }
        finish(decision: .connect)
    }

    // MARK: - Private

    /// The one path every answer takes: claim it, close the sheet, then send. The store sends at
    /// most one answer per request, so a second path (Cancel after Connect) sends nothing.
    private func finish(decision: RemoteShellDecision) {
        guard !resolved else { return }
        resolved = true
        // Read before the sheet closes. Only a Connect on a sheet that offered the box, with it ticked,
        // invites the agent.
        let invite = decision == .connect && followCheckbox.superview != nil && followCheckbox.state == .on
        disableButtons()
        endSheetIfPresented(completion: nil)
        _ = store.answer(requestId: requestId, decision: decision, inviteFollow: invite)
    }

    private func disableButtons() {
        cancelButton.isEnabled = false
        connectButton.isEnabled = false
        escapeButton.isEnabled = false
    }

    private func endSheetIfPresented(completion: (() -> Void)?) {
        guard let window, let parent = window.sheetParent else {
            completion?()
            return
        }
        parent.endSheet(window)
        completion?()
    }
}
