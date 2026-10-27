import AppKit

/// "Paste 14 lines into PRODUCTION · admin-portal · scheduler? Each line may run as a command." and the
/// first three lines of what would be pasted, so the person sees what they confirm.
///
/// Shown by `NostromoTerminalView` for a paste (or dictated or replaced text) with a newline into a
/// shell that is not known to be local. Nothing has been sent when it appears; the paste happens from
/// exactly one place, the Paste button.
///
/// - **Cancel** is the default button (`keyEquivalent = "\r"`), so Return cancels; Escape cancels too.
/// - **Paste** has no key equivalent (Tab then Space, or a click) and asks
///   `TerminalInputGuard.allowsControl` first: a synthetic click does nothing and is reported.
final class PasteConfirmSheet: NSWindowController {

    private final class PasteButton: NSButton {
        override var canBecomeKeyView: Bool { true }
        override var acceptsFirstResponder: Bool { true }
    }

    private final class SheetWindow: NSWindow {
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    private static let contentWidth: CGFloat = 440

    private let cancelButton = NSButton(frame: .zero)
    private let pasteButton = PasteButton(frame: .zero)
    private let escapeButton = NSButton(frame: .zero)
    private let onPaste: () -> Void
    private let onRefused: () -> Void
    private var finished = false

    /// `onPaste` runs after the sheet closes, only for a human's Paste; `onRefused` when a Paste was
    /// not a human gesture (the sheet stays up).
    init(lines: Int, preview: String, targetText: String, onPaste: @escaping () -> Void, onRefused: @escaping () -> Void) {
        self.onPaste = onPaste
        self.onRefused = onRefused
        let win = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 140),
                              styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Paste"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.initialFirstResponder = nil
        super.init(window: win)
        win.onCancel = { [weak self] in self?.cancelTapped(nil) }
        build(lines: lines, preview: preview, targetText: targetText)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build(lines: Int, preview: String, targetText: String) {
        guard let contentView = window?.contentView else { return }
        let textWidth = Self.contentWidth - 40

        let title = NSTextField(wrappingLabelWithString: "Paste \(lines) \(lines == 1 ? "line" : "lines") into \(targetText)?")
        title.preferredMaxLayoutWidth = textWidth
        title.font = .systemFont(ofSize: 15, weight: .bold)
        title.textColor = .white
        title.maximumNumberOfLines = 0
        title.isSelectable = false
        title.setAccessibilityIdentifier("paste-confirm-title")

        let detail = NSTextField(wrappingLabelWithString: "Each line may run as a command.")
        detail.preferredMaxLayoutWidth = textWidth
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .systemRed
        detail.isSelectable = false

        let previewField = NSTextField(wrappingLabelWithString: preview)
        previewField.preferredMaxLayoutWidth = textWidth
        previewField.font = Theme.codeFont(size: 12)
        previewField.textColor = Theme.fg
        previewField.maximumNumberOfLines = 8
        previewField.lineBreakMode = .byTruncatingTail
        previewField.isSelectable = false
        previewField.setAccessibilityIdentifier("paste-confirm-preview")

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.setAccessibilityIdentifier("paste-confirm-cancel")

        pasteButton.title = "Paste"
        pasteButton.bezelStyle = .rounded
        pasteButton.target = self
        pasteButton.action = #selector(pasteTapped(_:))
        pasteButton.setAccessibilityIdentifier("paste-confirm-paste")

        escapeButton.isTransparent = true
        escapeButton.keyEquivalent = "\u{1b}"
        escapeButton.target = self
        escapeButton.action = #selector(cancelTapped(_:))

        let stack = NSStackView(views: [title, detail, previewField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let buttons = NSStackView(views: [cancelButton, pasteButton])
        buttons.spacing = 8
        for view in [stack, buttons, escapeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: textWidth),
            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            escapeButton.widthAnchor.constraint(equalToConstant: 1),
            escapeButton.heightAnchor.constraint(equalToConstant: 1),
            escapeButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            escapeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        window?.setContentSize(NSSize(width: Self.contentWidth, height: contentView.fittingSize.height))
    }

    /// Cancel, Return and Escape. Sends nothing.
    @objc private func cancelTapped(_ sender: Any?) {
        finish(paste: false)
    }

    @objc private func pasteTapped(_ sender: NSButton) {
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            onRefused()
            return
        }
        finish(paste: true)
    }

    private func finish(paste: Bool) {
        guard !finished else { return }
        finished = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        if paste { onPaste() }
    }
}
