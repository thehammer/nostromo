import AppKit

/// Small sheet to rename a dynamic focus (sidebar context menu → "Rename…").
///
/// Presented via `window.beginSheet(_:)`. The field is prefilled with the
/// current label (empty when the focus uses default naming). Saving a blank
/// value clears the label, restoring the default name.
final class RenameFocusSheet: NSWindowController {

    private let onSave: (String?) -> Void
    private let field = NSTextField()

    init(currentLabel: String?, onSave: @escaping (String?) -> Void) {
        self.onSave = onSave

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
            styleMask:   [.titled],
            backing:     .buffered,
            defer:       false
        )
        win.title                = "Rename Session"
        win.isReleasedWhenClosed = false
        win.appearance           = NSAppearance(named: .darkAqua)

        super.init(window: win)
        field.stringValue = currentLabel ?? ""
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build UI

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Rename Session")
        titleLabel.font      = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Label (blank = default name)"
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(field)

        let saveBtn = NSButton()
        saveBtn.title         = "Save"
        saveBtn.bezelStyle    = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.target        = self
        saveBtn.action        = #selector(saveTapped)
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(saveBtn)

        let cancelBtn = NSButton()
        cancelBtn.title         = "Cancel"
        cancelBtn.bezelStyle    = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.target        = self
        cancelBtn.action        = #selector(cancelTapped)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            field.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            cancelBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            saveBtn.centerYAnchor.constraint(equalTo: cancelBtn.centerYAnchor),
            saveBtn.trailingAnchor.constraint(equalTo: cancelBtn.leadingAnchor, constant: -8),
        ])
    }

    // MARK: - Actions

    @objc func saveTapped() {
        endSheet()
        onSave(Focus.normalizedLabel(field.stringValue))
    }

    @objc func cancelTapped() {
        endSheet()
    }

    private func endSheet() {
        if let window { window.sheetParent?.endSheet(window) }
    }

    // MARK: - Test seams

    func typeLabel(_ text: String) { field.stringValue = text }
    var labelText: String { field.stringValue }
}
