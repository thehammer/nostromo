import AppKit

/// "Couldn't connect to PRODUCTION · admin-portal · scheduler": shown when the daemon says a
/// connection could not be made. No pane is left behind (the daemon closes it before it says so).
/// It names the reason and the fix: the remedy sits in a selectable, monospaced field with Copy, so a
/// command such as `aws sso login --sso-session …` can be pasted into a shell. Nothing here runs it.
///
/// Presented with `beginSheet` by `RemoteShellPresenter`. Every button is harmless (it dismisses the
/// sheet or copies text), so none needs a gesture check.
final class RemoteShellFailureSheet: NSWindowController {

    private static let contentWidth: CGFloat = 520

    private let remedy: String?
    private let remedyField = NSTextField(frame: .zero)

    init(failure: RemoteShellFailure) {
        remedy = failure.remedy

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 180),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Remote shell"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)

        super.init(window: win)
        buildContent(failure: failure)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func buildContent(failure: RemoteShellFailure) {
        guard let contentView = window?.contentView else { return }
        let textWidth = Self.contentWidth - 40

        let headingLabel = NSTextField(wrappingLabelWithString: failure.heading)
        headingLabel.preferredMaxLayoutWidth = textWidth
        headingLabel.font = .systemFont(ofSize: 17, weight: .bold)
        headingLabel.textColor = .systemRed
        headingLabel.maximumNumberOfLines = 0
        headingLabel.setAccessibilityIdentifier("remote-shell-failure-heading")

        let reasonLabel = NSTextField(wrappingLabelWithString: failure.reason)
        reasonLabel.preferredMaxLayoutWidth = textWidth
        reasonLabel.font = .systemFont(ofSize: 14, weight: .medium)
        reasonLabel.textColor = .white
        reasonLabel.maximumNumberOfLines = 0
        reasonLabel.setAccessibilityIdentifier("remote-shell-failure-reason")

        var rows: [NSView] = [headingLabel, reasonLabel]

        if let detail = failure.detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.preferredMaxLayoutWidth = textWidth
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 3
            detailLabel.setAccessibilityIdentifier("remote-shell-failure-detail")
            rows.append(detailLabel)
        }

        if let remedy {
            let fixLabel = NSTextField(labelWithString: "To fix it:")
            fixLabel.font = .systemFont(ofSize: 12)
            fixLabel.textColor = .secondaryLabelColor
            rows.append(fixLabel)

            remedyField.stringValue = remedy
            remedyField.isEditable = false
            remedyField.isSelectable = true
            remedyField.isBordered = true
            remedyField.drawsBackground = true
            remedyField.backgroundColor = NSColor(white: 0.12, alpha: 1)
            remedyField.textColor = .white
            remedyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            remedyField.usesSingleLineMode = false
            remedyField.maximumNumberOfLines = 0
            remedyField.lineBreakMode = .byWordWrapping
            remedyField.preferredMaxLayoutWidth = textWidth
            remedyField.setAccessibilityIdentifier("remote-shell-failure-remedy")
            rows.append(remedyField)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let okButton = NSButton(title: "OK", target: self, action: #selector(okTapped(_:)))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.setAccessibilityIdentifier("remote-shell-failure-ok")
        var buttonViews: [NSView] = []
        if remedy != nil {
            let copy = NSButton(title: "Copy", target: self, action: #selector(copyTapped(_:)))
            copy.bezelStyle = .rounded
            copy.setAccessibilityIdentifier("remote-shell-failure-copy")
            buttonViews.append(copy)
        }
        buttonViews.append(okButton)
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
        if remedy != nil {
            remedyField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window?.fitContent(toWidth: Self.contentWidth)
    }

    // MARK: - Actions

    /// Copies the remedy to the pasteboard. It runs nothing.
    @objc private func copyTapped(_ sender: Any?) {
        guard let remedy else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(remedy, forType: .string)
    }

    @objc private func okTapped(_ sender: Any?) {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
