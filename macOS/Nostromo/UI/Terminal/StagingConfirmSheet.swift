import AppKit

/// "Insert into PRODUCTION?": the question a production-treated row that matches a destructive pattern
/// asks before its text is placed at the prompt (R7). Shown on the driver window by
/// `StagingInsertController`. Nothing has been sent when it appears; the text goes out from exactly one
/// place, the Insert button, and then only the snapshot the click began with.
///
/// It shows everything that will happen and wraps all of it, never truncating: the title (the environment,
/// uppercased and red; `REMOTE` without a target), the target line, the full command in a monospaced,
/// selectable block that scrolls inside a capped height, the patterns it matched, the app's own hazard
/// labels, and the fixed line "Insert places the text at the prompt. Nothing runs until you press Enter.
/// No label does not mean safe." Agent text appears only in the command block.
///
/// - **Cancel** is the one button that answers Return, and Escape cancels too.
/// - **Insert** answers to no key at all (Tab reaches it, Space activates it, or a click) and asks
///   `TerminalInputGuard.allowsControl` first: a synthetic click does nothing and is reported.
final class StagingConfirmSheet: NSWindowController {

    static let fixedLine = "Insert places the text at the prompt. Nothing runs until you press Enter. No label does not mean safe."
    static let contentWidth: CGFloat = 480
    static let maxCommandHeight: CGFloat = 180

    private final class InsertButton: NSButton {
        override var canBecomeKeyView: Bool { true }
        override var acceptsFirstResponder: Bool { true }
    }

    private final class SheetWindow: NSWindow {
        var onCancel: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    let cancelButton = NSButton(frame: .zero)
    let insertButton: NSButton = InsertButton(frame: .zero)
    let escapeButton = NSButton(frame: .zero)
    /// What the sheet shows (tests read them).
    private(set) var titleText = ""
    private(set) var commandText = ""
    private(set) var shownLines: [String] = []
    private(set) var commandBlockHeight: CGFloat = 0
    private(set) var isFinished = false

    private let onInsert: (NSButton) -> Void
    private let onCancel: () -> Void
    private let onRefused: () -> Void
    /// Whether an Insert press is a person's (the real guard unless a test says otherwise).
    private let gate: (NSEvent?, NSView) -> Bool

    /// `onInsert` runs (with the Insert button) after the sheet closes, only for a person's Insert; `onCancel` after Cancel, Return
    /// or Escape; `onRefused` when an Insert was not a person's (the sheet stays up).
    init(title: String, targetLine: String, command: String, matches: [String], hazardLabels: [String],
         gate: @escaping (NSEvent?, NSView) -> Bool = { TerminalInputGuard.allowsControl(event: $0, control: $1) },
         onInsert: @escaping (NSButton) -> Void, onCancel: @escaping () -> Void, onRefused: @escaping () -> Void) {
        self.gate = gate
        self.onInsert = onInsert
        self.onCancel = onCancel
        self.onRefused = onRefused
        let win = SheetWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Insert"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.initialFirstResponder = nil
        super.init(window: win)
        win.onCancel = { [weak self] in self?.cancelTapped(nil) }
        build(title: title, targetLine: targetLine, command: command, matches: matches, hazardLabels: hazardLabels)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Closes the sheet without calling anything back (the terminal ended, the list went, staging was turned
    /// off, the parent window is closing).
    func dismiss() {
        guard !isFinished else { return }
        isFinished = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
    }

    private func build(title: String, targetLine: String, command: String, matches: [String], hazardLabels: [String]) {
        guard let contentView = window?.contentView else { return }
        let textWidth = Self.contentWidth - 40
        titleText = title
        commandText = command

        let titleField = wrapping(title, font: .systemFont(ofSize: 17, weight: .bold), color: .systemRed, width: textWidth)
        titleField.setAccessibilityIdentifier("staging-confirm-title")
        let targetField = wrapping(targetLine, font: .systemFont(ofSize: 13), color: .white, width: textWidth)
        targetField.setAccessibilityIdentifier("staging-confirm-target")

        let block = commandBlock(command, width: textWidth)
        var lines: [NSView] = [titleField, targetField, block]
        shownLines = [title, targetLine]
        let matched = "Matches a destructive pattern: " + matches.joined(separator: ", ")
        let matchField = wrapping(matched, font: .systemFont(ofSize: 13, weight: .semibold), color: .systemOrange, width: textWidth)
        matchField.setAccessibilityIdentifier("staging-confirm-match")
        lines.append(matchField)
        shownLines.append(matched)
        for label in hazardLabels {
            lines.append(wrapping(label, font: .systemFont(ofSize: 12), color: .systemOrange, width: textWidth))
            shownLines.append(label)
        }
        let fixed = wrapping(Self.fixedLine, font: .systemFont(ofSize: 12), color: Theme.fgMuted, width: textWidth)
        fixed.setAccessibilityIdentifier("staging-confirm-note")
        lines.append(fixed)
        shownLines.append(Self.fixedLine)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped(_:))
        cancelButton.setAccessibilityIdentifier("staging-confirm-cancel")

        insertButton.title = "Insert"
        insertButton.bezelStyle = .rounded
        insertButton.target = self
        insertButton.action = #selector(insertTapped(_:))
        insertButton.setAccessibilityIdentifier("staging-confirm-insert")

        escapeButton.isTransparent = true
        escapeButton.keyEquivalent = "\u{1b}"
        escapeButton.target = self
        escapeButton.action = #selector(cancelTapped(_:))

        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let buttons = NSStackView(views: [cancelButton, insertButton])
        buttons.spacing = 8
        for view in [stack, buttons, escapeButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.widthAnchor.constraint(equalToConstant: textWidth),
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

    private func wrapping(_ text: String, font: NSFont, color: NSColor, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.preferredMaxLayoutWidth = width
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 0
        field.isSelectable = false
        return field
    }

    /// The full command, monospaced and selectable, wrapped at any character; the block grows with the text up
    /// to `maxCommandHeight` and scrolls beyond it. Never truncated.
    private func commandBlock(_ command: String, width: CGFloat) -> NSView {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.baseWritingDirection = .leftToRight
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let attributed = NSAttributedString(string: command, attributes: [
            .font: font, .foregroundColor: Theme.fg, .paragraphStyle: style,
        ])
        let inset: CGFloat = 6
        let measured = ceil(attributed.boundingRect(with: NSSize(width: width - 2 * inset - 12, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let height = min(Self.maxCommandHeight, measured + 2 * inset + 4)
        commandBlockHeight = height

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(white: 1, alpha: 0.06)
        textView.textContainerInset = NSSize(width: inset, height: inset)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(attributed)
        textView.setAccessibilityIdentifier("staging-confirm-command")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    /// Cancel, Return and Escape. Sends nothing.
    @objc private func cancelTapped(_ sender: Any?) {
        guard !isFinished else { return }
        isFinished = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onCancel()
    }

    @objc private func insertTapped(_ sender: NSButton) {
        guard !isFinished else { return }
        guard gate(NSApp.currentEvent, sender) else {
            onRefused()
            return
        }
        isFinished = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        onInsert(sender)
    }
}
