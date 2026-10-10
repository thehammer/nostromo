import AppKit

// MARK: - Injected actions

/// What the detail pane needs from the outside world. Closures, so tests inject
/// fakes and production wires the daemon (`FredBindings`). Completions are
/// delivered on the main thread.
struct FredDetailActions {
    /// Ask the daemon for the detail of `mail:<id>` / `event:<id>`.
    var requestDetail: (_ itemId: String, _ completion: @escaping (Result<WorkItemDetail, WorkError>) -> Void) -> Void
    /// Send `text` into Fred's own session. `nil` = accepted.
    var seedFred: (_ text: String, _ completion: @escaping (WorkError?) -> Void) -> Void
    var open: (URL) -> Void
}

/// The message or event the pane shows.
enum FredDetailSubject {
    case mail(MailboxItem)
    case event(CalendarEvent)

    var itemId: String {
        switch self {
        case .mail(let m): return "mail:\(m.id)"
        case .event(let e): return "event:\(e.id)"
        }
    }

    var webLink: String? {
        switch self {
        case .mail(let m): return m.webLink
        case .event(let e): return e.webLink
        }
    }

    var isMail: Bool {
        if case .mail = self { return true }
        return false
    }
}

// MARK: - Default prompts

/// The editable text the confirmation starts from. Both tell Fred not to act
/// on the world: neither flow sends mail, RSVPs or edits the calendar.
enum FredDetailPrompts {
    static let askIntro = "Here is an email from my inbox. Summarise it and tell me if it needs a reply; "
        + "if so, draft one for me to review. Do not send anything."
    static let prepIntro = "Brief me for this meeting: related email threads, related Jira issues, "
        + "and open questions. Do not RSVP or change the calendar."

    static func ask(_ d: WorkItemDetail) -> String {
        compose(intro: askIntro, d, titleLabel: "Subject")
    }

    static func prep(_ d: WorkItemDetail) -> String {
        compose(intro: prepIntro, d, titleLabel: "Meeting")
    }

    private static func compose(intro: String, _ d: WorkItemDetail, titleLabel: String) -> String {
        var lines = [intro, ""]
        lines += d.fields.map { "\($0.label): \($0.value)" }
        lines.append("\(titleLabel): \(d.title)")
        if !d.markdown.isEmpty { lines += ["", d.markdown] }
        return lines.joined(separator: "\n")
    }
}

// MARK: - View

/// Read-only detail of the selected message or event, with Open in Outlook and
/// Ask Fred… / Prep with Fred. The seed actions open an inline confirmation
/// (editable prompt; Return sends, Esc cancels) and never send anything
/// themselves: Fred's own agent panel receives the text.
final class FredDetailView: NSView {

    static let couldNotSeedNotRunning = "Fred's session isn't running; open Fred's chat once and retry."

    private(set) var displayedFields: [(label: String, value: String)] = []
    private(set) var displayedBody = ""
    private(set) var errorText: String?
    private(set) var isConfirming = false

    var promptText: String {
        get { promptView.string }
        set { promptView.string = newValue }
    }

    private let subject: FredDetailSubject
    private let actions: FredDetailActions
    private var detail: WorkItemDetail?
    private var isSending = false

    private let titleLabel = NSTextField(labelWithString: "")
    private let fieldsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "Open in Outlook", target: nil, action: nil)
    private let seedButton: NSButton
    private let bodyScroll = NSScrollView()
    private let bodyView = NSTextView()
    private let confirmBox = NSView()
    private let promptScroll = NSScrollView()
    private let promptView = FredPromptTextView()
    private let sendButton = NSButton(title: "Send to Fred", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(subject: FredDetailSubject, actions: FredDetailActions) {
        self.subject = subject
        self.actions = actions
        self.seedButton = NSButton(title: subject.isMail ? "Ask Fred…" : "Prep with Fred", target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError("FredDetailView is built in code") }

    override var isFlipped: Bool { true }

    // MARK: Actions

    /// "Ask Fred…" (message) / "Prep with Fred" (event): open the confirmation
    /// with the default prompt. No-op until the detail has loaded.
    func beginSeed() {
        guard let detail, !isConfirming else { return }
        promptText = subject.isMail ? FredDetailPrompts.ask(detail) : FredDetailPrompts.prep(detail)
        isConfirming = true
        setError(nil)
        confirmBox.isHidden = false
        needsLayout = true
        window?.makeFirstResponder(promptView)
    }

    /// Send the (edited) prompt to Fred's session, once.
    func confirmSeed() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConfirming, !isSending, !text.isEmpty else { return }
        isSending = true
        actions.seedFred(promptText) { [weak self] failure in
            guard let self else { return }
            self.isSending = false
            if let failure {
                self.setError(failure.code == "fred_not_running"
                    ? Self.couldNotSeedNotRunning
                    : "Couldn't send to Fred: \(failure.message)")
            } else {
                self.closeConfirmation()
                self.statusLabel.stringValue = "Sent to Fred. Switch to Fred's chat to follow along."
                self.statusLabel.textColor = Theme.fgMuted
                self.statusLabel.isHidden = false
                self.needsLayout = true
            }
        }
    }

    /// Esc: close the confirmation, send nothing.
    func cancelSeed() {
        guard !isSending else { return }
        closeConfirmation()
    }

    func openInOutlook() {
        let link = detail?.links.first { $0.label == "Open in Outlook" }?.url ?? subject.webLink
        guard let link, let url = URL(string: link) else { return }
        actions.open(url)
    }

    // MARK: Loading

    private func load() {
        titleLabel.stringValue = "Loading…"
        seedButton.isEnabled = false
        actions.requestDetail(subject.itemId) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let d):
                self.detail = d
                self.show(d)
            case .failure(let e):
                self.titleLabel.stringValue = ""
                self.setError(e.message)   // the daemon's messages are already plain English
            }
        }
    }

    private func show(_ d: WorkItemDetail) {
        titleLabel.stringValue = d.title
        displayedFields = d.fields.map { (label: $0.label, value: $0.value) }
        displayedBody = d.markdown
        fieldsLabel.stringValue = d.fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        bodyView.string = d.markdown
        seedButton.isEnabled = true
        openButton.isEnabled = d.links.contains { $0.label == "Open in Outlook" } || subject.webLink != nil
        needsLayout = true
    }

    private func setError(_ text: String?) {
        errorText = text
        statusLabel.stringValue = text ?? ""
        statusLabel.textColor = Theme.redSweater
        statusLabel.isHidden = text == nil
        needsLayout = true
    }

    private func closeConfirmation() {
        isConfirming = false
        confirmBox.isHidden = true
        needsLayout = true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad: CGFloat = 12
        let inner = max(0, w - 2 * pad)
        var y: CGFloat = 8
        titleLabel.frame = NSRect(x: pad, y: y, width: inner, height: 18)
        y += 22
        fieldsLabel.preferredMaxLayoutWidth = inner
        let fieldsH = fieldsLabel.stringValue.isEmpty ? 0 : fieldsLabel.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height
        fieldsLabel.frame = NSRect(x: pad, y: y, width: inner, height: fieldsH)
        y += fieldsH + (fieldsH > 0 ? 6 : 0)
        openButton.sizeToFit()
        seedButton.sizeToFit()
        openButton.frame.origin = NSPoint(x: pad, y: y)
        seedButton.frame.origin = NSPoint(x: pad + openButton.frame.width + 8, y: y)
        y += 28
        if !statusLabel.isHidden {
            let h = statusLabel.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude)).height
            statusLabel.frame = NSRect(x: pad, y: y, width: inner, height: h)
            y += h + 4
        }
        let remaining = max(0, bounds.height - y)
        if isConfirming {
            confirmBox.frame = NSRect(x: 0, y: y, width: w, height: remaining)
            let buttonsY = max(0, remaining - 32)
            promptScroll.frame = NSRect(x: pad, y: 0, width: inner, height: max(0, buttonsY - 4))
            sendButton.sizeToFit()
            cancelButton.sizeToFit()
            sendButton.frame.origin = NSPoint(x: w - pad - sendButton.frame.width, y: buttonsY + 2)
            cancelButton.frame.origin = NSPoint(x: sendButton.frame.minX - 8 - cancelButton.frame.width, y: buttonsY + 2)
            bodyScroll.frame = .zero
        } else {
            bodyScroll.frame = NSRect(x: pad, y: y, width: inner, height: remaining)
        }
    }

    // MARK: Build

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor
        setAccessibilityIdentifier("fred.detail")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.fg
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("fred.detail.title")

        fieldsLabel.font = .systemFont(ofSize: 11)
        fieldsLabel.textColor = Theme.fgMuted
        fieldsLabel.isSelectable = true
        fieldsLabel.setAccessibilityIdentifier("fred.detail.fields")

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.isHidden = true
        statusLabel.setAccessibilityIdentifier("fred.detail.status")

        openButton.target = self
        openButton.action = #selector(openPressed)
        openButton.keyEquivalent = "o"
        openButton.keyEquivalentModifierMask = .command
        openButton.bezelStyle = .rounded
        openButton.setAccessibilityIdentifier("fred.detail.open")
        seedButton.target = self
        seedButton.action = #selector(seedPressed)
        seedButton.bezelStyle = .rounded
        seedButton.setAccessibilityIdentifier("fred.detail.seed")

        bodyView.isEditable = false
        bodyView.isSelectable = true
        bodyView.drawsBackground = false
        bodyView.textColor = Theme.fg
        bodyView.font = .systemFont(ofSize: 12)
        bodyView.isVerticallyResizable = true
        bodyView.autoresizingMask = [.width]
        bodyView.textContainerInset = NSSize(width: 0, height: 4)
        bodyView.setAccessibilityIdentifier("fred.detail.body")
        bodyScroll.documentView = bodyView
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false

        promptView.isRichText = false
        promptView.isEditable = true
        promptView.font = .systemFont(ofSize: 12)
        promptView.isVerticallyResizable = true
        promptView.autoresizingMask = [.width]
        promptView.onConfirm = { [weak self] in self?.confirmSeed() }
        promptView.onCancel = { [weak self] in self?.cancelSeed() }
        promptView.setAccessibilityIdentifier("fred.detail.prompt")
        promptScroll.documentView = promptView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .lineBorder

        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.bezelStyle = .rounded
        sendButton.setAccessibilityIdentifier("fred.detail.confirm")
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.bezelStyle = .rounded
        cancelButton.setAccessibilityIdentifier("fred.detail.cancel")
        for v in [promptScroll, sendButton, cancelButton] { confirmBox.addSubview(v) }
        confirmBox.isHidden = true
        confirmBox.wantsLayer = true
        confirmBox.layer?.backgroundColor = Theme.bg.cgColor

        for v in [titleLabel, fieldsLabel, openButton, seedButton, statusLabel, bodyScroll, confirmBox] { addSubview(v) }
    }

    @objc private func openPressed() { openInOutlook() }
    @objc private func seedPressed() { beginSeed() }
    @objc private func sendPressed() { confirmSeed() }
    @objc private func cancelPressed() { cancelSeed() }
}

/// The prompt editor: Return confirms, Shift-Return inserts a newline, Esc cancels.
private final class FredPromptTextView: NSTextView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !event.modifierFlags.contains(.shift) {
            onConfirm?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
