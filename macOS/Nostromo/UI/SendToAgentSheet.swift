import AppKit

// The confirmation sheet behind "Send to agent…" (Teri detail view, a pick, or ⌘⇧S on a
// selected row). It is filled from the daemon's `SendPreview`, lets the user change
// anything, and only a press of Start (or Return) sends. It knows nothing about
// `AppStore`: it sends through a `WorkSending` and reports what happened through
// `onFinished`, so tests drive the real sheet with a fake sender and `TeriBindings`
// supplies the real one.

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

final class SendToAgentSheet: NSWindowController, NSTextFieldDelegate {

    static let motherWarning = "Mother runs unattended; a raw item is not a plan"

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
    private let contextView = NSTextView()
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

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "Send to agent"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        super.init(window: win)

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
    var contextText: String { contextView.string }
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

    func typeContext(_ text: String) {
        contextView.string = text
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
        let request = WorkSendRequest(
            requestId: UUID().uuidString,
            itemId: itemId,
            destination: destination == .motherJob ? "mother_job" : "focus",
            agent: selectedAgent,
            workingDirectory: workingDirectory,
            label: trimmedLabel,
            context: contextView.string,
            allowDuplicate: allowDuplicate)
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
            errorLabel.stringValue = error.message
        case .timedOut:
            errorLabel.stringValue = "The daemon did not answer in time. Check Mother's queue and the sidebar before trying again."
        case .detail, .sendPreview:
            errorLabel.stringValue = "The daemon sent an unexpected answer."
        }
        refresh()
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
        contextView.string = preview.context

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
        contextView.isEditable = idle
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

        contextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        contextView.textColor = Theme.fg
        contextView.backgroundColor = Theme.bg
        contextView.insertionPointColor = .white
        contextView.isRichText = false
        contextView.isAutomaticQuoteSubstitutionEnabled = false
        contextView.isAutomaticDashSubstitutionEnabled = false
        contextView.isVerticallyResizable = true
        contextView.isHorizontallyResizable = false
        contextView.autoresizingMask = [.width]
        contextView.textContainer?.widthTracksTextView = true
        contextView.textContainerInset = NSSize(width: 6, height: 6)
        contextView.setAccessibilityLabel("Context")
        let scroll = NSScrollView()
        scroll.documentView = contextView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

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
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let buttons = NSStackView(views: [spinner, secondaryButton, cancelButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let column = NSStackView(views: [
            title,
            Self.row("Send as:", destinationControl),
            warningLabel,
            existingLabel,
            Self.row("Agent:", agentPopup),
            Self.row("Project:", projectRow),
            Self.row("Label:", labelField),
            Self.row("Org:", orgLabel),
            Self.row("Context:", scroll, alignTop: true),
            errorLabel,
            buttons,
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
        for view in column.arrangedSubviews where view !== title && view !== buttons {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        buttons.trailingAnchor.constraint(equalTo: column.trailingAnchor).isActive = true
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

// MARK: - The real sender

extension WorkStore: WorkSending {
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
