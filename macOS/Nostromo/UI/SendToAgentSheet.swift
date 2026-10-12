import AppKit

// The confirmation sheet behind "Send to agent…" (Teri detail view, a pick, or ⌘⇧S on a
// selected row). It is filled from the daemon's `SendPreview`, lets the user change the
// agent, project, label and *instruction*, and only a deliberate confirm sends: the Start
// button, ⌘Return anywhere, or plain Return while no text is being edited (Return in a text
// view is a newline, and Return while an input method is composing belongs to the input
// method). Esc cancels.
//
// Two kinds of text, kept apart. The instruction is the user's own words and the only text
// the sheet sends. What the agent also receives (the item's title, fields, body, links) is
// third-party: the sheet shows it READ-ONLY under "What will be shared" and never sends it
// back, because the daemon rebuilds it from the item at send time and fences it as data.
//
// It knows nothing about `AppStore`: it sends through a `WorkSending` and reports what
// happened through `onFinished`, so tests drive the real sheet with a fake sender and
// `TeriBindings` supplies the real one.

/// Sends a confirmed request to the daemon and reports the answer once.
protocol WorkSending: AnyObject {
    func sendWork(_ request: WorkSendRequest, completion: @escaping (WorkResponse) -> Void)
}

/// How the sheet ended.
enum SendToAgentResult: Equatable {
    /// The daemon created the focus or queued the job (or answered `existing`).
    case sent(SendOutcome)
    /// The user chose the focus or job that already exists; nothing was sent.
    case goToExisting(SentMarker)
    case cancelled
}

enum SendDestination: Equatable {
    case focus
    case motherJob
}

/// The project last used for a Jira project, Sentry project or other source, so the next
/// item from it starts with that project chosen. One UserDefaults dictionary.
struct TeriProjectMRU {
    static let defaultsKey = "nostromo.teri.projectMRU.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The key an item's project is remembered under: its Jira project or Sentry project
    /// slug, else its source. Repo docs have their own repo and need none.
    static func key(for item: WorkItem) -> String? {
        switch item.source {
        case .jira:     return "jira:\(item.project ?? "")"
        case .sentry:   return "sentry:\(item.project ?? "")"
        case .todos:    return "todos"
        case .repoDocs: return nil
        }
    }

    func lastProject(for key: String) -> String? {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String])?[key]
    }

    func record(_ path: String, for key: String) {
        var all = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
        all[key] = path
        defaults.set(all, forKey: Self.defaultsKey)
    }
}

extension SentMarker {
    /// What a row or pick says about this marker: "sent to <label>" or "queued as Mother job".
    var markerText: String {
        kind == "mother_job" ? "queued as Mother job" : "sent to \(label)"
    }
}

/// The sheet's window. Decides what Return and Esc do before the key-equivalent pass can hand
/// them to a button: a multi-line text view keeps Return for a newline, and text being
/// composed by an input method keeps Return and Esc for the input method.
final class SendToAgentWindow: NSWindow {
    /// Plain Return with no text being edited: confirm.
    var onPlainReturn: (() -> Void)?
    /// ⌘Return (the primary button's key equivalent) was pressed but the button is disabled:
    /// the key is swallowed so a text view does not take it as a newline.
    var isConfirmEnabled: () -> Bool = { true }

    private static let returnKeyCodes: Set<UInt16> = [36, 76]   // Return, keypad Enter
    private static let escapeKeyCode: UInt16 = 53

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let isReturn = Self.returnKeyCodes.contains(event.keyCode)
        guard isReturn || event.keyCode == Self.escapeKeyCode else { return super.performKeyEquivalent(with: event) }

        // Composition owns the key: Return commits the candidate, Esc abandons it.
        if (firstResponder as? NSTextInputClient)?.hasMarkedText() == true { return false }
        guard isReturn else { return super.performKeyEquivalent(with: event) }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if flags == .command {
            return isConfirmEnabled() ? super.performKeyEquivalent(with: event) : true
        }
        if flags.isEmpty {
            // In a text view (the field editor of a text field is one) Return is the
            // text's: a newline, or the field's own end of editing. Never a confirm.
            if firstResponder is NSTextView { return false }
            onPlainReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SendToAgentSheet: NSWindowController, NSTextFieldDelegate {

    static let motherWarning = "Mother runs unattended; a raw item is not a plan"
    static let confirmHint = "⌘Return starts · Return adds a line in the instruction · Esc cancels"
    static let timedOutMessage = "The daemon did not answer in time. The first attempt may have gone through: " +
        "check the sidebar and Mother's queue. Pressing the button again retries without sending a second copy."

    private let itemId: String
    private let mruKey: String?
    private let existing: SentMarker?
    private let orgResolver: RepoOrgResolver
    private let mru: TeriProjectMRU
    private let sender: WorkSending
    private let onFinished: (SendToAgentResult) -> Void

    private var agents: [String]
    private var projects: [String]
    private var isFinished = false
    /// The last attempt that timed out. A retry of the same send reuses its request id, so the
    /// daemon hands back what the first attempt did instead of creating a second focus or job.
    private var timedOutRequest: WorkSendRequest?

    private(set) var destination: SendDestination = .focus
    private(set) var isSending = false

    // UI
    private let destinationControl = NSSegmentedControl(labels: ["New focus", "Mother job"],
                                                        trackingMode: .selectOne, target: nil, action: nil)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let existingLabel = NSTextField(wrappingLabelWithString: "")
    private let agentPopup = NSPopUpButton()
    private let projectPopup = NSPopUpButton()
    private let chooseButton = NSButton()
    private let labelField = NSTextField()
    private let orgLabel = NSTextField(labelWithString: "—")
    private let instructionView = NSTextView()
    private let sharedView = NSTextView()
    private let sharedToggle = NSButton()
    private let sharedScroll = NSScrollView()
    private var sharedRow: NSView?
    private let hintLabel = NSTextField(wrappingLabelWithString: SendToAgentSheet.confirmHint)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let secondaryButton = NSButton()
    let primaryButton = NSButton()
    let cancelButton = NSButton()

    init(itemId: String, mruKey: String?, preview: SendPreview, agents: [String], projects: [String],
         orgResolver: RepoOrgResolver, mru: TeriProjectMRU, sender: WorkSending,
         onFinished: @escaping (SendToAgentResult) -> Void) {
        self.itemId = itemId
        self.mruKey = mruKey
        self.existing = preview.existing.last
        self.orgResolver = orgResolver
        self.mru = mru
        self.sender = sender
        self.onFinished = onFinished
        self.agents = agents
        self.projects = projects

        let win = SendToAgentWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Send to agent"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        super.init(window: win)
        win.onPlainReturn = { [weak self] in self?.confirmFromKeyboard() }
        win.isConfirmEnabled = { [weak self] in self?.primaryButton.isEnabled ?? false }

        buildContent()
        applyDefaults(preview)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Test seams: state

    var isMotherEnabled: Bool { destinationControl.isEnabled(forSegment: 1) }
    var motherWarningText: String { warningLabel.stringValue }
    var selectedAgent: String { agentPopup.titleOfSelectedItem ?? "" }
    var workingDirectory: String? { projectPopup.selectedItem?.representedObject as? String }
    var labelText: String { labelField.stringValue }
    /// The user's editable instruction.
    var instructionText: String { instructionView.string }
    /// The read-only "What will be shared" preview.
    var sharedText: String { sharedView.string }
    var isSharedEditable: Bool { sharedView.isEditable }
    var isSharedExpanded: Bool { !sharedScroll.isHidden }
    var hintText: String { hintLabel.stringValue }
    var primaryToolTip: String? { primaryButton.toolTip }
    /// The text view Return must keep for a newline, for key-event tests.
    var instructionTextView: NSTextView { instructionView }
    var labelTextField: NSTextField { labelField }
    var orgText: String { orgLabel.stringValue }
    var isStartEnabled: Bool { primaryButton.isEnabled }
    var primaryButtonTitle: String { primaryButton.title }
    var secondaryButtonTitle: String? { secondaryButton.isHidden ? nil : secondaryButton.title }
    var errorText: String { errorLabel.stringValue }

    // MARK: - Test seams: actions

    func setDestination(_ new: SendDestination) {
        guard !isSending, new == .focus || workingDirectory != nil else { return }
        destination = new
        refresh()
    }

    func selectAgent(_ name: String) {
        if !agents.contains(name) {
            agents.append(name)
            agentPopup.addItem(withTitle: name)
        }
        agentPopup.selectItem(withTitle: name)
        refresh()
    }

    func selectProject(_ path: String?) {
        var index = 0   // "No project"
        if let path {
            if !projects.contains(path) {
                projects.append(path)
                addProjectItem(path)
            }
            index = projectPopup.itemArray.firstIndex { ($0.representedObject as? String) == path } ?? 0
        }
        projectPopup.selectItem(at: index)
        projectChanged()
    }

    func typeLabel(_ text: String) {
        labelField.stringValue = text
        refresh()
    }

    func typeInstruction(_ text: String) {
        instructionView.string = text
    }

    func toggleShared() {
        setSharedExpanded(sharedScroll.isHidden)
    }

    /// Start, or Go to existing focus when the item already has one.
    @objc func primaryTapped() {
        if let existing {
            finish(.goToExisting(existing))
        } else {
            send(allowDuplicate: false)
        }
    }

    /// Create another: sends even though a focus or job exists.
    @objc func secondaryTapped() {
        send(allowDuplicate: true)
    }

    /// Plain Return while nothing is being edited (the window decided that).
    private func confirmFromKeyboard() {
        guard primaryButton.isEnabled else { return }
        primaryTapped()
    }

    @objc func cancelTapped() {
        guard !isSending else { return }
        finish(.cancelled)
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    // MARK: - Sending

    private var trimmedLabel: String {
        labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool {
        !isSending && !selectedAgent.isEmpty && workingDirectory != nil && !trimmedLabel.isEmpty
    }

    private func send(allowDuplicate: Bool) {
        guard canStart, !isFinished else { return }
        isSending = true
        errorLabel.stringValue = ""
        var request = WorkSendRequest(
            requestId: UUID().uuidString,
            itemId: itemId,
            destination: destination == .motherJob ? "mother_job" : "focus",
            agent: selectedAgent,
            workingDirectory: workingDirectory,
            label: trimmedLabel,
            instruction: instructionView.string,
            allowDuplicate: allowDuplicate)
        if let earlier = timedOutRequest, earlier.isSameSend(as: request) {
            request = WorkSendRequest(
                requestId: earlier.requestId, itemId: request.itemId, destination: request.destination,
                agent: request.agent, workingDirectory: request.workingDirectory, label: request.label,
                instruction: request.instruction, allowDuplicate: request.allowDuplicate)
        }
        timedOutRequest = nil
        refresh()
        sender.sendWork(request) { [weak self] response in
            self?.received(response, for: request)
        }
    }

    private func received(_ response: WorkResponse, for request: WorkSendRequest) {
        guard !isFinished else { return }
        isSending = false
        switch response {
        case .sendResult(.ok(let outcome)):
            if let mruKey, let directory = request.workingDirectory { mru.record(directory, for: mruKey) }
            finish(.sent(outcome))
            return
        case .sendResult(.err(let error)), .failed(let error):
            showError(error.message)
        case .timedOut:
            timedOutRequest = request
            showError(Self.timedOutMessage)
        case .detail, .sendPreview:
            showError("The daemon sent an unexpected answer.")
        }
        refresh()
    }

    /// Show `message` inline and have VoiceOver say it: the label appears below the fold of what
    /// a screen-reader user is focused on.
    private func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: errorLabel, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func finish(_ result: SendToAgentResult) {
        guard !isFinished else { return }
        isFinished = true
        if let window { window.sheetParent?.endSheet(window) }
        onFinished(result)
    }

    // MARK: - State

    private func applyDefaults(_ preview: SendPreview) {
        if !agents.contains(preview.agent) { agents.insert(preview.agent, at: 0) }
        agentPopup.removeAllItems()
        agentPopup.addItems(withTitles: agents)
        if agents.contains(preview.agent) {
            agentPopup.selectItem(withTitle: preview.agent)
        } else if let claudia = agents.firstIndex(of: "claudia") {
            agentPopup.selectItem(at: claudia)
        }

        projectPopup.removeAllItems()
        projectPopup.addItem(withTitle: "No project")
        projectPopup.lastItem?.representedObject = nil
        for path in projects { addProjectItem(path) }
        let initial = preview.workingDirectory ?? mruKey.flatMap { mru.lastProject(for: $0) }
        selectProject(initial)

        labelField.stringValue = preview.label
        instructionView.string = preview.instruction
        sharedView.string = preview.context

        if let existing {
            let isJob = existing.kind == "mother_job"
            existingLabel.stringValue = isJob
                ? "This item is already queued as a Mother job."
                : "This item already has a live focus: \(existing.label)."
            existingLabel.isHidden = false
            primaryButton.title = isJob ? "Go to existing job" : "Go to existing focus"
            secondaryButton.isHidden = false
        }
    }

    private func addProjectItem(_ path: String) {
        projectPopup.addItem(withTitle: URL(fileURLWithPath: path).lastPathComponent)
        projectPopup.lastItem?.representedObject = path
        projectPopup.lastItem?.toolTip = path
    }

    @objc private func projectChanged() {
        if workingDirectory == nil, destination == .motherJob { destination = .focus }
        updateOrg()
        refresh()
    }

    @objc private func agentChanged() { refresh() }

    @objc private func destinationChanged() {
        setDestination(destinationControl.selectedSegment == 1 ? .motherJob : .focus)
        refresh()
    }

    @objc private func chooseProject() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.selectProject(url.path)
        }
    }

    /// Pull the controls in line with the state: what is enabled, shown or titled.
    private func refresh() {
        let idle = !isSending
        let toMother = destination == .motherJob
        destinationControl.setEnabled(workingDirectory != nil && idle, forSegment: 1)
        destinationControl.setEnabled(idle, forSegment: 0)
        destinationControl.selectedSegment = toMother ? 1 : 0
        warningLabel.stringValue = toMother ? Self.motherWarning : ""
        warningLabel.isHidden = !toMother
        agentPopup.isEnabled = idle
        projectPopup.isEnabled = idle
        chooseButton.isEnabled = idle
        labelField.isEnabled = idle
        instructionView.isEditable = idle
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        cancelButton.isEnabled = idle
        if idle { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        if existing != nil {
            // Go to existing is always available; only creating another needs a valid form.
            primaryButton.isEnabled = idle
            secondaryButton.isEnabled = canStart
        } else {
            primaryButton.isEnabled = canStart
        }
    }

    private func updateOrg() {
        guard let path = workingDirectory else {
            orgLabel.stringValue = "—"
            return
        }
        if let cached = orgResolver.cached(path) {
            orgLabel.stringValue = cached ?? "—"
            return
        }
        orgLabel.stringValue = "—"   // until the lookup answers
        orgResolver.resolve(path) { [weak self] org in
            guard let self, self.workingDirectory == path else { return }   // selection moved on
            self.orgLabel.stringValue = org ?? "—"
        }
    }

    // MARK: - Build UI

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Send to agent")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .white

        destinationControl.target = self
        destinationControl.action = #selector(destinationChanged)
        destinationControl.setAccessibilityLabel("Destination")

        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = Theme.amber
        warningLabel.isHidden = true
        existingLabel.font = .systemFont(ofSize: 11)
        existingLabel.textColor = Theme.cornflower
        existingLabel.isHidden = true

        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)
        projectPopup.target = self
        projectPopup.action = #selector(projectChanged)
        chooseButton.title = "Choose…"
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseProject)
        let projectRow = NSStackView(views: [projectPopup, chooseButton])
        projectRow.spacing = 8

        labelField.font = .systemFont(ofSize: 12)
        labelField.usesSingleLineMode = true
        labelField.lineBreakMode = .byTruncatingTail
        labelField.delegate = self
        orgLabel.font = .systemFont(ofSize: 12)
        orgLabel.textColor = Theme.fgMuted
        orgLabel.setAccessibilityLabel("Org")

        Self.configureTextView(instructionView, editable: true)
        instructionView.setAccessibilityLabel("Instruction for the agent")
        instructionView.setAccessibilityHelp("Return adds a line. Command Return starts.")
        let instructionScroll = Self.scroll(around: instructionView, minHeight: 90)

        Self.configureTextView(sharedView, editable: false)
        sharedView.textColor = Theme.fgMuted
        sharedView.setAccessibilityLabel("What will be shared with the agent, read only")
        sharedScroll.documentView = sharedView
        sharedScroll.hasVerticalScroller = true
        sharedScroll.borderType = .lineBorder
        sharedScroll.translatesAutoresizingMaskIntoConstraints = false
        sharedScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        sharedScroll.isHidden = true
        sharedToggle.setButtonType(.pushOnPushOff)
        sharedToggle.bezelStyle = .disclosure
        sharedToggle.title = ""
        sharedToggle.target = self
        sharedToggle.action = #selector(sharedToggled)
        sharedToggle.setAccessibilityLabel("What will be shared")
        sharedToggle.toolTip = "The item's own text. The agent gets it as untrusted data; you cannot edit it here."
        let sharedCaption = NSTextField(labelWithString: "What will be shared (read-only)")
        sharedCaption.font = .systemFont(ofSize: 11)
        sharedCaption.textColor = Theme.fgMuted
        let sharedHeader = NSStackView(views: [sharedToggle, sharedCaption])
        sharedHeader.orientation = .horizontal
        sharedHeader.spacing = 6

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = Theme.redSweater
        errorLabel.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        secondaryButton.title = "Create another"
        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryTapped)
        secondaryButton.isHidden = true

        primaryButton.title = "Start"
        primaryButton.bezelStyle = .rounded
        // ⌘Return, not Return: Return belongs to the text being typed (see `SendToAgentWindow`).
        primaryButton.keyEquivalent = "\r"
        primaryButton.keyEquivalentModifierMask = .command
        primaryButton.toolTip = "Start (⌘Return)"
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = Theme.fgMuted
        agentPopup.setAccessibilityLabel("Agent")
        projectPopup.setAccessibilityLabel("Project")
        chooseButton.setAccessibilityLabel("Choose another project folder")
        labelField.setAccessibilityLabel("Label")
        errorLabel.setAccessibilityLabel("Error")

        let buttons = NSStackView(views: [spinner, secondaryButton, cancelButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let sharedRow = Self.row("", sharedScroll, alignTop: true)
        self.sharedRow = sharedRow
        sharedRow.isHidden = true
        let column = NSStackView(views: [
            title,
            Self.row("Send as:", destinationControl),
            warningLabel,
            existingLabel,
            Self.row("Agent:", agentPopup),
            Self.row("Project:", projectRow),
            Self.row("Label:", labelField),
            Self.row("Org:", orgLabel),
            Self.row("Say:", instructionScroll, alignTop: true),
            sharedHeader,
            sharedRow,
            errorLabel,
            buttons,
            hintLabel,
        ])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
        for view in column.arrangedSubviews where view !== title && view !== buttons && view !== hintLabel {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        buttons.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
        hintLabel.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
    }

    @objc private func sharedToggled() {
        setSharedExpanded(sharedToggle.state == .on)
    }

    private func setSharedExpanded(_ expanded: Bool) {
        sharedScroll.isHidden = !expanded
        sharedRow?.isHidden = !expanded
        sharedToggle.state = expanded ? .on : .off
    }

    private static func configureTextView(_ view: NSTextView, editable: Bool) {
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textColor = Theme.fg
        view.backgroundColor = Theme.bg
        view.insertionPointColor = .white
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 6, height: 6)
    }

    private static func scroll(around view: NSTextView, minHeight: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return scroll
    }

    /// A label on the left and its control filling the rest.
    private static func row(_ caption: String, _ control: NSView, alignTop: Bool = false) -> NSView {
        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = alignTop ? .top : .centerY
        row.spacing = 8
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
}

// MARK: - Toast

/// A short notice at the bottom of a window: a refused press ("already preparing"), a Mother job's
/// confirmation, "not loaded yet". It also goes to VoiceOver as an announcement, because a banner
/// that fades on its own is not something a screen-reader user finds by looking.
enum TeriToast {
    static let identifier = NSUserInterfaceItemIdentifier("teri.toast")
    /// How long it stays. Not observed by tests: they look for the banner, never for its end.
    static let lifetime: TimeInterval = 5

    /// Show `text` on `window`, replacing any earlier toast there.
    static func show(_ text: String, in window: NSWindow?) {
        guard let content = window?.contentView else { return }
        dismiss(in: window)
        let label = NSTextField(wrappingLabelWithString: text)
        label.identifier = identifier
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.backgroundColor = Theme.bgBarActive
        label.drawsBackground = true
        label.isBordered = false
        label.alignment = .center
        label.setAccessibilityRole(.staticText)
        label.setAccessibilityLabel(text)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -32),
        ])
        NSAccessibility.post(
            element: label, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime) { [weak label] in label?.removeFromSuperview() }
    }

    /// The toast on `window` now, if any (tests, accessibility).
    static func text(in window: NSWindow?) -> String? {
        (window?.contentView?.subviews.first { $0.identifier == identifier } as? NSTextField)?.stringValue
    }

    static func dismiss(in window: NSWindow?) {
        window?.contentView?.subviews.filter { $0.identifier == identifier }.forEach { $0.removeFromSuperview() }
    }
}

// MARK: - The flow around the sheet

/// Asks the daemon for an item's send defaults.
protocol SendPreviewing: AnyObject {
    func requestSendPreview(_ itemId: String, completion: @escaping (WorkResponse) -> Void)
}

/// Where "go to the existing focus / job" lands. False when there is nothing to go to yet.
protocol SendNavigating: AnyObject {
    func goToFocus(tag: String) -> Bool
    func goToJob(_ jobId: String) -> Bool
}

/// Everything around the sheet that is not the sheet: the preview request in flight (the surface
/// shows progress meanwhile), one send at a time with a notice for a press that is refused, and
/// what to tell the user when the sheet ends (a queued Mother job's id; an existing focus the Mac
/// cannot find yet). `TeriBindings` supplies the real store, navigation and sheet.
final class SendToAgentFlow {
    enum Press: Equatable {
        case started
        case alreadyPreparing
        case sheetOpen
        case noWindow
    }

    static let preparingNotice = "Still preparing the previous Send to agent. One moment."
    static let sheetOpenNotice = "A Send to agent sheet is already open."
    static let focusNotLoadedNotice = "A focus for this item exists but is not loaded yet; try again in a moment."
    static let jobNotLoadedNotice = "Mother is not loaded yet; try again in a moment."

    private(set) var isPreviewing = false { didSet { if isPreviewing != oldValue { onPreparingChanged?(isPreviewing) } } }
    private(set) var isSheetOpen = false
    /// The surface shows (or stops showing) that a send is being prepared.
    var onPreparingChanged: ((Bool) -> Void)?

    /// Ask for `itemId`'s defaults and, once they arrive, have `presentSheet` show the sheet. A
    /// press while a preview is pending or a sheet is up is refused with a notice, never silently.
    @discardableResult
    func begin(itemId: String, window: NSWindow?, previewer: SendPreviewing,
               presentSheet: @escaping (SendPreview, NSWindow) -> Bool,
               showError: @escaping (String, NSWindow) -> Void) -> Press {
        guard let window else { return .noWindow }
        if isPreviewing {
            TeriToast.show(Self.preparingNotice, in: window)
            return .alreadyPreparing
        }
        if isSheetOpen {
            TeriToast.show(Self.sheetOpenNotice, in: window)
            return .sheetOpen
        }
        isPreviewing = true
        previewer.requestSendPreview(itemId) { [weak self, weak window] response in
            guard let self else { return }
            self.isPreviewing = false
            guard let window else { return }
            switch response {
            case .sendPreview(.ok(let preview)):
                if presentSheet(preview, window) { self.isSheetOpen = true }
            case .sendPreview(.err(let error)), .failed(let error):
                showError(error.message, window)
            case .timedOut:
                showError("The daemon did not answer in time.", window)
            case .detail, .sendResult:
                break
            }
        }
        return .started
    }

    /// The sheet went away (however it ended).
    func sheetDismissed() { isSheetOpen = false }

    /// What the sheet's result means for the user, on `window`.
    func handle(_ result: SendToAgentResult, window: NSWindow?, navigator: SendNavigating) {
        switch result {
        case .sent(let outcome) where outcome.kind == "existing":
            if let tag = outcome.focusTag {
                if !navigator.goToFocus(tag: tag) { TeriToast.show(Self.focusNotLoadedNotice, in: window) }
            } else if let job = outcome.jobId, !navigator.goToJob(job) {
                TeriToast.show(Self.jobNotLoadedNotice, in: window)
            }
        case .sent(let outcome) where outcome.kind == "mother_job":
            let id = outcome.jobId.map { " \($0)" } ?? ""
            TeriToast.show("Queued as Mother job\(id). It runs unattended; follow it in Mother.", in: window)
        case .goToExisting(let marker):
            let found = marker.kind == "mother_job"
                ? navigator.goToJob(marker.targetId) : navigator.goToFocus(tag: marker.targetId)
            if !found {
                TeriToast.show(marker.kind == "mother_job" ? Self.jobNotLoadedNotice : Self.focusNotLoadedNotice,
                               in: window)
            }
        case .sent, .cancelled:
            break   // a new focus selects itself (`select_for_client`)
        }
    }
}

// MARK: - The real sender

extension WorkStore: WorkSending, SendPreviewing {
    func sendWork(_ request: WorkSendRequest, completion: @escaping (WorkResponse) -> Void) {
        guard isConnected, let sendFrame else {
            completion(.failed(WorkError(code: "not_connected", message: "Not connected to nostromd")))
            return
        }
        expect(requestId: request.requestId, completion: completion)
        sendFrame(.send(request))
    }

    /// Ask the daemon for the defaults of sending `itemId`.
    func requestSendPreview(_ itemId: String, completion: @escaping (WorkResponse) -> Void) {
        guard isConnected, let sendFrame else {
            completion(.failed(WorkError(code: "not_connected", message: "Not connected to nostromd")))
            return
        }
        let requestId = UUID().uuidString
        expect(requestId: requestId, completion: completion)
        sendFrame(.sendPreviewRequest(requestId: requestId, itemId: itemId))
    }
}
