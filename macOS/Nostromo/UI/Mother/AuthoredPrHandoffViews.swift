import AppKit
import NostromoKit

// The pieces the hand-off shows: the preview popover, the focus picker and the Start a session sheet.
//
// Everything the daemon sent (the message, focus names, folders) is plain text in labels and a read-only
// text view: never Markdown, attributed HTML or a link.

// MARK: - Presentation

enum AuthoredPrHandoffUI {
    private static var popover: NSPopover?
    private static var popoverDelegate: PopoverCloseDelegate?
    private static var sheet: NSWindow?
    private static var sheetParent: NSWindow?

    static func show(_ item: AuthoredPrPresented, from anchor: NSView) {
        dismiss()
        switch item {
        case .preview(let session):
            present(AuthoredPrPreviewViewController(session: session), from: anchor) { session.cancel() }
        case .picker(let session):
            present(AuthoredPrPickerViewController(session: session), from: anchor) { session.cancel() }
        case .start(let model):
            showSheet(AuthoredPrStartSessionViewController(model: model), from: anchor, model: model)
        }
    }

    static func dismiss() {
        if let popover {
            // Cleared first: closing runs the delegate, which must not cancel what is already finished.
            popoverDelegate?.onClose = nil
            self.popover = nil
            popoverDelegate = nil
            if popover.isShown { popover.close() }
        }
        if let sheet, let parent = sheetParent {
            self.sheet = nil
            sheetParent = nil
            parent.endSheet(sheet)
        }
    }

    private static func present(_ controller: NSViewController, from anchor: NSView, onClose: @escaping () -> Void) {
        let pop = NSPopover()
        pop.contentViewController = controller
        pop.behavior = .transient
        pop.animates = false
        let delegate = PopoverCloseDelegate()
        delegate.onClose = onClose
        pop.delegate = delegate
        popover = pop
        popoverDelegate = delegate
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private static func showSheet(_ controller: NSViewController, from anchor: NSView, model: AuthoredPrStartSessionModel) {
        guard let parent = anchor.window else { return }
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled]
        sheet = window
        sheetParent = parent
        parent.beginSheet(window) { _ in }
    }

    private final class PopoverCloseDelegate: NSObject, NSPopoverDelegate {
        var onClose: (() -> Void)?
        func popoverDidClose(_ notification: Notification) { onClose?() }
    }
}

// MARK: - Small helpers

private func label(_ font: NSFont, _ color: NSColor, lines: Int = 1) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: "")
    l.font = font
    l.textColor = color
    l.maximumNumberOfLines = lines
    l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    l.allowsEditingTextAttributes = false
    l.isSelectable = false
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
}

/// A read-only, selectable, monospaced text view in a scroll view, sized to its text (up to `maxHeight`).
final class AuthoredPrMessageView: NSView {
    static let insetX: CGFloat = 8
    static let insetY: CGFloat = 6

    let textView: NSTextView
    let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private let maxHeight: CGFloat

    init(width: CGFloat, maxHeight: CGFloat = 280) {
        // TextKit 1, so the text's height can be measured before the view is on screen.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 40), textContainer: container)
        self.maxHeight = maxHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 40))
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = AuthoredPrsPalette.text
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Self.insetX, height: Self.insetY)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = AuthoredPrsPalette.chipFill
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
            widthAnchor.constraint(equalToConstant: width),
        ])
        setAccessibilityElement(false)
        textView.setAccessibilityLabel("Message to send")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Show `text` verbatim and grow to fit all of it (a long message scrolls past `maxHeight`).
    func show(_ text: String) {
        if textView.string != text { textView.string = text }
        textView.frame.size.width = frame.width
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let needed = ceil(used + 2 * Self.insetY) + 2
        heightConstraint.constant = min(max(needed, 28), maxHeight)
        textView.frame.size.height = max(needed, heightConstraint.constant)
        needsLayout = true
    }
}

// MARK: - Preview

final class AuthoredPrPreviewViewController: NSViewController {
    static let width: CGFloat = 440
    static let padding: CGFloat = 16

    let session: AuthoredPrPreviewSession
    var clock: () -> Date = Date.init

    let titleLabel = label(.systemFont(ofSize: 13, weight: .semibold), AuthoredPrsPalette.text)
    let message = AuthoredPrMessageView(width: AuthoredPrPreviewViewController.width - 2 * AuthoredPrPreviewViewController.padding)
    let lastToldLabel = label(.systemFont(ofSize: 11), AuthoredPrsPalette.muted)
    let noteLabel = label(.systemFont(ofSize: 11), AuthoredPrsPalette.warning, lines: 2)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let sendButton = NSButton(title: "Send and switch ⏎", target: nil, action: nil)

    init(session: AuthoredPrPreviewSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 220))
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.keyEquivalent = "\r"
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for b in [cancelButton, sendButton] { b.translatesAutoresizingMaskIntoConstraints = false }
        sendButton.setAccessibilityIdentifier("authored-pr-send")
        cancelButton.setAccessibilityIdentifier("authored-pr-cancel")
        for v in [titleLabel, message, lastToldLabel, noteLabel, cancelButton, sendButton] as [NSView] { root.addSubview(v) }
        let p = Self.padding
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            message.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            lastToldLabel.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 8),
            lastToldLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            lastToldLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            noteLabel.topAnchor.constraint(equalTo: lastToldLabel.bottomAnchor, constant: 4),
            noteLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            noteLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            sendButton.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 10),
            sendButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            sendButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -p),
            cancelButton.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
        ])
        view = root
        session.onChange = { [weak self] in self?.apply() }
        apply()
    }

    /// Reflect the session: the title, the message verbatim, last told, the note, the buttons.
    func apply() {
        titleLabel.stringValue = session.title
        if let payload = session.payload {
            message.show(payload.text)
            lastToldLabel.stringValue = AuthoredPrsPresentation.lastToldLine(payload.lastTold, now: clock())
        } else {
            message.show(session.phase == .loading ? "Preparing the message…" : "")
            lastToldLabel.stringValue = ""
        }
        noteLabel.stringValue = session.note ?? ""
        noteLabel.isHidden = session.note == nil
        sendButton.title = session.sendTitle
        sendButton.isEnabled = session.phase == .ready || session.phase == .ownerClosed
        sendButton.setAccessibilityLabel(session.phase == .ownerClosed ? "Start a session" : "Send message and switch")
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: view.fittingSize.height)
    }

    @objc private func cancelPressed() { session.cancel() }

    @objc private func sendPressed() { session.send(event: NSApp.currentEvent, control: sendButton) }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(sendButton)
    }
}

// MARK: - Picker

final class AuthoredPrPickerTable: NSTableView {
    var onReturn: ((NSEvent) -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            if selectedRow >= 0 { onReturn?(event) }
        case 53:
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}

final class AuthoredPrPickerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 38

    let session: AuthoredPrPickerSession
    let table = AuthoredPrPickerTable()
    private let titleLabel = label(.systemFont(ofSize: 13, weight: .semibold), AuthoredPrsPalette.text)
    private let noteLabel = label(.systemFont(ofSize: 11), AuthoredPrsPalette.warning, lines: 2)
    private let scroll = NSScrollView()

    init(session: AuthoredPrPickerSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        titleLabel.stringValue = "Choose a focus for PR \(session.row.number)"
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("focus"))
        column.width = Self.width - 32
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.focusRingType = .none
        table.target = self
        table.action = #selector(clicked)
        table.onReturn = { [weak self] event in self?.choose(self?.table.selectedRow ?? -1, event: event) }
        table.onEscape = { [weak self] in self?.session.cancel() }
        table.setAccessibilityLabel("Focuses")
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        for v in [titleLabel, scroll, noteLabel] as [NSView] { root.addSubview(v) }
        let p: CGFloat = 16
        let rows = CGFloat(min(max(session.entries.count, 1), 8))
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            scroll.heightAnchor.constraint(equalToConstant: rows * Self.rowHeight),
            noteLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            noteLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            noteLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            noteLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -p),
        ])
        view = root
        session.onChange = { [weak self] in self?.apply() }
        apply()
        table.reloadData()
        // Nothing is preselected: the person chooses.
        table.deselectAll(nil)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: Self.width, height: view.fittingSize.height)
    }

    private func apply() {
        noteLabel.stringValue = session.note ?? ""
        noteLabel.isHidden = session.note == nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(table)
    }

    @objc private func clicked() { choose(table.clickedRow, event: NSApp.currentEvent) }

    private func choose(_ row: Int, event: NSEvent?) {
        session.choose(row, event: event, control: table)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { session.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = session.entries[row]
        let cell = NSView()
        let title = label(.systemFont(ofSize: 12), AuthoredPrsPalette.text)
        title.stringValue = entry.title
        let detail = label(.systemFont(ofSize: 11), AuthoredPrsPalette.muted)
        detail.stringValue = entry.detail ?? ""
        detail.isHidden = entry.detail == nil
        cell.addSubview(title)
        cell.addSubview(detail)
        let centered = entry.detail == nil
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            centered ? title.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                     : title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            detail.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
        ])
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.row)
        cell.setAccessibilityLabel([entry.title, entry.detail].compactMap { $0 }.joined(separator: ", "))
        return cell
    }
}

// MARK: - Start a session

final class AuthoredPrStartSessionViewController: NSViewController, NSTextFieldDelegate {
    static let width: CGFloat = 480
    static let padding: CGFloat = 20

    let model: AuthoredPrStartSessionModel
    let folderField = NSTextField(string: "")
    let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    let agentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let message = AuthoredPrMessageView(width: AuthoredPrStartSessionViewController.width - 2 * AuthoredPrStartSessionViewController.padding)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let startButton = NSButton(title: "Start and send", target: nil, action: nil)
    private let titleLabel = label(.systemFont(ofSize: 14, weight: .semibold), AuthoredPrsPalette.text)
    private let folderLabel = label(.systemFont(ofSize: 12), AuthoredPrsPalette.muted)
    private let agentLabel = label(.systemFont(ofSize: 12), AuthoredPrsPalette.muted)
    private let messageLabel = label(.systemFont(ofSize: 12), AuthoredPrsPalette.muted)
    private let noteLabel = label(.systemFont(ofSize: 11), AuthoredPrsPalette.warning, lines: 2)

    init(model: AuthoredPrStartSessionModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 380))
        titleLabel.stringValue = "Start a session for PR \(model.row.number)"
        folderLabel.stringValue = "Folder"
        agentLabel.stringValue = "Agent"
        messageLabel.stringValue = "Message"
        folderField.placeholderString = "Choose the folder this PR is checked out in"
        folderField.delegate = self
        folderField.translatesAutoresizingMaskIntoConstraints = false
        folderField.lineBreakMode = .byTruncatingHead
        chooseButton.target = self
        chooseButton.action = #selector(choosePressed)
        agentPopup.addItems(withTitles: model.agents)
        if let agent = model.agent { agentPopup.selectItem(withTitle: agent) }
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"
        startButton.target = self
        startButton.action = #selector(startPressed)
        startButton.keyEquivalent = "\r"
        for v in [chooseButton, agentPopup, cancelButton, startButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        startButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        chooseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [titleLabel, folderLabel, folderField, chooseButton, agentLabel, agentPopup, messageLabel, message,
                  noteLabel, cancelButton, startButton] as [NSView] { root.addSubview(v) }
        let p = Self.padding
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: p),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            titleLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            folderLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            folderLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            folderField.topAnchor.constraint(equalTo: folderLabel.bottomAnchor, constant: 4),
            folderField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            chooseButton.centerYAnchor.constraint(equalTo: folderField.centerYAnchor),
            chooseButton.leadingAnchor.constraint(equalTo: folderField.trailingAnchor, constant: 8),
            chooseButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            agentLabel.topAnchor.constraint(equalTo: folderField.bottomAnchor, constant: 12),
            agentLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            agentPopup.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 4),
            agentPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            messageLabel.topAnchor.constraint(equalTo: agentPopup.bottomAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            message.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 4),
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            noteLabel.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 8),
            noteLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: p),
            noteLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            startButton.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 12),
            startButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -p),
            startButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -p),
            cancelButton.centerYAnchor.constraint(equalTo: startButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: startButton.leadingAnchor, constant: -8),
        ])
        view = root
        model.onChange = { [weak self] in self?.apply() }
        apply()
    }

    func apply() {
        if folderField.stringValue != model.folder { folderField.stringValue = model.folder }
        if let agent = model.agent, agentPopup.titleOfSelectedItem != agent { agentPopup.selectItem(withTitle: agent) }
        message.show(model.payload?.text ?? (model.phase == .loading ? "Preparing the message…" : ""))
        noteLabel.stringValue = model.note ?? ""
        noteLabel.isHidden = model.note == nil
        startButton.isEnabled = model.canStart
        view.layoutSubtreeIfNeeded()
    }

    func controlTextDidChange(_ obj: Notification) { model.folder = folderField.stringValue }

    @objc private func agentChanged() { model.agent = agentPopup.titleOfSelectedItem }

    @objc private func choosePressed() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.model.folder = url.path }
        }
    }

    @objc private func cancelPressed() { model.cancel() }

    @objc private func startPressed() { model.start(event: NSApp.currentEvent, control: startButton) }
}
