import AppKit
import os

private let sheetLog = Logger(subsystem: "com.hammer.nostromo", category: "terminal")

/// "Connect to PRODUCTION": the one place a production shell opens.
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

    let requestId: String
    private let store: RemoteShellStore
    private let terminals: TerminalSessionStore

    private let cancelButton = NSButton(frame: .zero)
    private let connectButton = ConnectButton(frame: .zero)
    /// Invisible, so Escape has a key equivalent without a second visible button.
    private let escapeButton = NSButton(frame: .zero)
    /// Room for slice 3c's "let the agent follow" checkbox. There is none yet.
    private let followSlot = NSView(frame: .zero)

    /// Set before anything that can close the sheet, so no later path can answer for it.
    private var resolved = false

    init(request: RemoteShellConfirmRequest, model: RemoteShellSheetModel,
         store: RemoteShellStore = .shared, terminals: TerminalSessionStore = .shared) {
        self.requestId = request.requestId
        self.store = store
        self.terminals = terminals

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

        // Largest, bold, red: what this connects to, named first.
        let titleLabel = NSTextField(labelWithString: model.title)
        titleLabel.font = .systemFont(ofSize: 30, weight: .heavy)
        titleLabel.textColor = .systemRed
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("remote-shell-title")

        let subtitleLabel = NSTextField(labelWithString: model.subtitle)
        subtitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitleLabel.textColor = .white
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setAccessibilityIdentifier("remote-shell-target")

        var rows: [NSView] = [titleLabel, subtitleLabel]
        if let requester = model.requesterLine {
            let requesterLabel = NSTextField(wrappingLabelWithString: requester)
            requesterLabel.preferredMaxLayoutWidth = textWidth
            requesterLabel.font = .systemFont(ofSize: 13)
            requesterLabel.textColor = .secondaryLabelColor
            requesterLabel.maximumNumberOfLines = 0
            requesterLabel.isSelectable = false
            requesterLabel.setAccessibilityIdentifier("remote-shell-requester")
            rows.append(requesterLabel)
        }
        followSlot.setAccessibilityIdentifier("remote-shell-follow-slot")
        followSlot.translatesAutoresizingMaskIntoConstraints = false
        followSlot.heightAnchor.constraint(equalToConstant: 0).isActive = true
        rows.append(followSlot)

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
        connectButton.setAccessibilityIdentifier("remote-shell-connect")
    }

    // MARK: - Actions

    /// Cancel, Return and Escape. Harmless: it can only stop a connection, so it needs no gesture.
    @objc private func cancelTapped(_ sender: Any?) {
        finish(decision: .cancel)
    }

    /// The only thing that can open a production shell. A person's click, or Tab then Space.
    @objc private func connectTapped(_ sender: NSButton) {
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
        disableButtons()
        endSheetIfPresented(completion: nil)
        _ = store.answer(requestId: requestId, decision: decision)
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
