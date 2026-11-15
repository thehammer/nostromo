import AppKit
import Combine
import NostromoKit

/// The sheet's window: it takes its own key equivalents (⌘1, ⌘2, ⌘⌫) before the main menu sees them, so
/// nothing global is bound.
final class FocusSheetWindow: NSWindow {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Sheet controller for creating a new dynamic Focus.
///
/// Presented via `window.beginSheet(_:)`. Discovers available agents from
/// `~/.claude/agents/*.md` and project directories from the code root (`~/Code` by default).
final class CreateFocusSheet: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {

    enum Tab: Int { case new, resume }
    /// The tab the sheet opens on: the last one used in this app run (New after a relaunch).
    static var rememberedTab: Tab = .new
    static let newSize = NSSize(width: 360, height: 358)
    static let resumeSize = NSSize(width: 600, height: 520)


    private let onCreate: (Focus) -> Void
    private let orgResolver: RepoOrgResolver
    private var isCreating = false
    private var isCancelled = false

    // UI
    private let agentPopup   = NSPopUpButton()
    private let projectPopup = NSPopUpButton()
    private let labelField   = NSTextField()
    private let namePreview  = NSTextField(labelWithString: "")
    private let createBtn    = NSButton()
    private let modelPickers: CreateFocusModelPickers
    private let tabControl = NSSegmentedControl(labels: ["New", "Resume"], trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let resumeBtn = NSButton()
    private var newTabViews: [NSView] = []
    private var resumeConstraints: [NSLayoutConstraint] = []
    let resumeTab = ResumeTabView()
    private let history: ConversationHistoryStore
    private let sheetUndo = UndoManager()
    private var cancellables = Set<AnyCancellable>()
    private(set) var currentTab: Tab = .new

    // Data
    private var agents:   [String] = []
    private var projects: [String] = []

    /// What the Project menu has selected: the single source of truth, so nothing indexes `projects` by
    /// menu position (the menu starts with No codebase and a separator).
    enum ProjectChoice: Equatable {
        case noCodebase
        case project(String)
    }
    /// Menu tag of the No codebase item; a repo's tag is its index in `projects`.
    private static let noCodebaseTag = -1
    /// An NSMenuItem's tag defaults to 0, which is also the first repo's: the separator gets its own.
    private static let separatorTag = -2
    private static let projectErrorHeight: CGFloat = 30
    private let projectError = NSTextField(wrappingLabelWithString: "")
    private var projectErrorHeightConstraint: NSLayoutConstraint?
    private var newTabExtraHeight: CGFloat = 0

    private var selectedProjectChoice: ProjectChoice? {
        guard let item = projectPopup.selectedItem else { return nil }
        if item.tag == Self.noCodebaseTag { return .noCodebase }
        return projects.indices.contains(item.tag) ? .project(projects[item.tag]) : nil
    }

    /// The menu: No codebase, a separator, then the repos. A repo is selected by default (as before);
    /// No codebase only when there are none.
    private func fillProjectMenu() {
        projectPopup.removeAllItems()
        guard let menu = projectPopup.menu else { return }
        let none = NSMenuItem(title: "No codebase", action: nil, keyEquivalent: "")
        none.tag = Self.noCodebaseTag
        menu.addItem(none)
        let separator = NSMenuItem.separator()
        separator.tag = Self.separatorTag
        menu.addItem(separator)
        for (index, path) in projects.enumerated() {
            let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        projectPopup.selectItem(at: projects.isEmpty ? 0 : 2)
    }

    private func showProjectError(_ text: String?) {
        projectError.stringValue = text ?? ""
        let extra = text == nil ? 0 : Self.projectErrorHeight
        projectErrorHeightConstraint?.constant = extra
        guard extra != newTabExtraHeight else { return }
        newTabExtraHeight = extra
        if currentTab == .new { window?.setContentSize(newTabSize) }
    }

    private var newTabSize: NSSize { NSSize(width: Self.newSize.width, height: Self.newSize.height + newTabExtraHeight) }

    /// `agents` / `projects` override filesystem discovery (used by tests).
    init(orgResolver: RepoOrgResolver = RepoOrgResolver(),
         agents: [String]? = nil, projects: [String]? = nil,
         modelStore: ModelStore = .shared,
         history: ConversationHistoryStore = .shared,
         switchToTag: @escaping (String) -> Bool = { _ in false },
         onCreate: @escaping (Focus) -> Void) {
        self.onCreate = onCreate
        self.history = history
        self.orgResolver = orgResolver
        self.modelPickers = CreateFocusModelPickers(store: modelStore)

        let win = FocusSheetWindow(
            contentRect: NSRect(origin: .zero, size: Self.newSize),
            styleMask:   [.titled],
            backing:     .buffered,
            defer:       false
        )
        win.title           = "New Focus"
        win.isReleasedWhenClosed = false
        win.appearance      = NSAppearance(named: .darkAqua)

        super.init(window: win)
        buildContent()
        loadData()
        if let agents { self.agents = agents; agentPopup.removeAllItems(); agentPopup.addItems(withTitles: agents) }
        if let projects {
            self.projects = projects
            fillProjectMenu()
        }
        createBtn.isEnabled = !self.agents.isEmpty
        updatePreview()
        modelPickers.agentChanged(to: selectedAgent)

        win.delegate = self
        win.onKeyEquivalent = { [weak self] in self?.handleKeyEquivalent($0) ?? false }
        history.switchToTag = switchToTag
        history.commitFocus = { [weak self] focus in self?.finishResume(with: focus) }
        buildTabs()
        selectTab(Self.rememberedTab)
    }

    private var selectedAgent: String? {
        agents.indices.contains(agentPopup.indexOfSelectedItem) ? agents[agentPopup.indexOfSelectedItem] : nil
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build UI

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        // Title label
        let titleLabel = NSTextField(labelWithString: "New Focus")
        titleLabel.font      = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        // Agent row
        let agentLabel = NSTextField(labelWithString: "Agent:")
        agentLabel.font      = .systemFont(ofSize: 12)
        agentLabel.textColor = .white
        agentLabel.isEditable = false
        agentLabel.isBordered = false
        agentLabel.drawsBackground = false
        agentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(agentLabel)

        agentPopup.translatesAutoresizingMaskIntoConstraints = false
        agentPopup.target = self
        agentPopup.action = #selector(pickerChanged)
        contentView.addSubview(agentPopup)

        // Model and effort rows (explicit colours: system-drawn labels go dark-on-dark here)
        func rowLabel(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font      = .systemFont(ofSize: 12)
            label.textColor = .white
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            label.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(label)
            return label
        }
        let modelLabel  = rowLabel("Model:")
        let effortLabel = rowLabel("Effort:")
        contentView.addSubview(modelPickers.modelPopup)
        contentView.addSubview(modelPickers.effortPopup)

        // Project row
        let projectLabel = NSTextField(labelWithString: "Project:")
        projectLabel.font      = .systemFont(ofSize: 12)
        projectLabel.textColor = .white
        projectLabel.isEditable = false
        projectLabel.isBordered = false
        projectLabel.drawsBackground = false
        projectLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(projectLabel)

        projectPopup.translatesAutoresizingMaskIntoConstraints = false
        projectPopup.target = self
        projectPopup.action = #selector(pickerChanged)
        contentView.addSubview(projectPopup)

        // Why a No codebase folder could not be made: under the Project row, hidden (zero height) otherwise.
        projectError.font = .systemFont(ofSize: 11)
        projectError.textColor = NSColor(srgbRed: 255/255, green: 130/255, blue: 120/255, alpha: 1)
        projectError.maximumNumberOfLines = 2
        projectError.translatesAutoresizingMaskIntoConstraints = false
        projectError.setAccessibilityLabel("Project error")
        contentView.addSubview(projectError)
        projectErrorHeightConstraint = projectError.heightAnchor.constraint(equalToConstant: 0)
        projectErrorHeightConstraint?.isActive = true

        // Label row (optional)
        let labelLabel = NSTextField(labelWithString: "Label:")
        labelLabel.font      = .systemFont(ofSize: 12)
        labelLabel.textColor = .white
        labelLabel.isEditable = false
        labelLabel.isBordered = false
        labelLabel.drawsBackground = false
        labelLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(labelLabel)

        labelField.font = .systemFont(ofSize: 12)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.usesSingleLineMode = true
        labelField.delegate = self
        labelField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(labelField)

        // Name preview
        namePreview.font      = .systemFont(ofSize: 11)
        namePreview.textColor = .gray
        namePreview.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(namePreview)

        // Buttons
        createBtn.title        = "Create"
        createBtn.bezelStyle   = .rounded
        createBtn.keyEquivalent = "\r"
        createBtn.target       = self
        createBtn.action       = #selector(createTapped)
        createBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(createBtn)

        let cancelBtn = NSButton()
        cancelBtn.title        = "Cancel"
        cancelBtn.bezelStyle   = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.target       = self
        cancelBtn.action       = #selector(cancelTapped)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            agentLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            agentLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            agentLabel.widthAnchor.constraint(equalToConstant: 60),

            agentPopup.centerYAnchor.constraint(equalTo: agentLabel.centerYAnchor),
            agentPopup.leadingAnchor.constraint(equalTo: agentLabel.trailingAnchor, constant: 8),
            agentPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            modelLabel.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 14),
            modelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            modelLabel.widthAnchor.constraint(equalToConstant: 60),

            modelPickers.modelPopup.centerYAnchor.constraint(equalTo: modelLabel.centerYAnchor),
            modelPickers.modelPopup.leadingAnchor.constraint(equalTo: modelLabel.trailingAnchor, constant: 8),
            modelPickers.modelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            effortLabel.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 14),
            effortLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            effortLabel.widthAnchor.constraint(equalToConstant: 60),

            modelPickers.effortPopup.centerYAnchor.constraint(equalTo: effortLabel.centerYAnchor),
            modelPickers.effortPopup.leadingAnchor.constraint(equalTo: effortLabel.trailingAnchor, constant: 8),
            modelPickers.effortPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            projectLabel.topAnchor.constraint(equalTo: effortLabel.bottomAnchor, constant: 14),
            projectLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            projectLabel.widthAnchor.constraint(equalToConstant: 60),

            projectPopup.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            projectPopup.leadingAnchor.constraint(equalTo: projectLabel.trailingAnchor, constant: 8),
            projectPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            projectError.topAnchor.constraint(equalTo: projectLabel.bottomAnchor, constant: 4),
            projectError.leadingAnchor.constraint(equalTo: projectPopup.leadingAnchor),
            projectError.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            labelLabel.topAnchor.constraint(equalTo: projectError.bottomAnchor, constant: 10),
            labelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            labelLabel.widthAnchor.constraint(equalToConstant: 60),

            labelField.centerYAnchor.constraint(equalTo: labelLabel.centerYAnchor),
            labelField.leadingAnchor.constraint(equalTo: labelLabel.trailingAnchor, constant: 8),
            labelField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            namePreview.topAnchor.constraint(equalTo: labelLabel.bottomAnchor, constant: 14),
            namePreview.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            namePreview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            cancelBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            createBtn.centerYAnchor.constraint(equalTo: cancelBtn.centerYAnchor),
            createBtn.trailingAnchor.constraint(equalTo: cancelBtn.leadingAnchor, constant: -8),
        ])
    }

    // MARK: - Data discovery

    private func loadData() {
        agents = Self.discoverAgents()
        agentPopup.removeAllItems()
        agentPopup.addItems(withTitles: agents)
        // Default to claudia if present
        if let idx = agents.firstIndex(of: "claudia") {
            agentPopup.selectItem(at: idx)
        }

        projects = Self.discoverProjects()
        fillProjectMenu()

        createBtn.isEnabled = !agents.isEmpty
    }

    /// Agents: ~/.claude/agents/*.md — filename sans extension is the agent tag.
    /// Also the agent list of the Send to agent sheet.
    static func discoverAgents() -> [String] {
        let agentsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/agents")
        return (try? FileManager.default.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
    }

    /// Projects: subdirectories of the code root (`~/Code` unless configured; see `CodeRoot`), excluding git worktrees.
    /// A worktree has `.git` as a plain file; a normal repo has `.git` as a directory.
    /// Also the project list of the Send to agent sheet.
    static func discoverProjects() -> [String] {
        let codeDir = CodeRoot.resolve()
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(
            at: codeDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles))?
            .filter { url in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return false }
                // Exclude worktrees — their .git is a file, not a directory
                let gitPath = url.appendingPathComponent(".git").path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: gitPath, isDirectory: &isDir) {
                    return isDir.boolValue  // true = real repo, false = worktree
                }
                return true  // no .git at all — include (e.g. non-git project dirs)
            }
            .map { $0.path }
            .sorted() ?? []
    }

    // MARK: - Preview

    @objc private func pickerChanged() {
        modelPickers.agentChanged(to: selectedAgent)
        updatePreview()
    }

    func controlTextDidChange(_ obj: Notification) { refreshPreviewText() }

    private func updatePreview() {
        guard !agents.isEmpty, let choice = selectedProjectChoice else {
            labelField.placeholderString = nil
            namePreview.stringValue = agents.isEmpty ? "No agents found in ~/.claude/agents" : ""
            return
        }
        showProjectError(nil)
        let agentTag = agents[agentPopup.indexOfSelectedItem]
        guard case .project(let projectPath) = choice else {
            showPreview(agentTag: agentTag, choice: .noCodebase, org: nil)   // always Personal: no org lookup
            return
        }
        let cached = orgResolver.cached(projectPath)
        showPreview(agentTag: agentTag, choice: choice, org: cached ?? nil)
        if cached == nil {
            orgResolver.resolve(projectPath) { [weak self] org in
                guard let self, !self.agents.isEmpty,
                      self.selectedProjectChoice == .project(projectPath)
                else { return }   // selection moved on; drop the stale result
                self.showPreview(agentTag: self.agents[self.agentPopup.indexOfSelectedItem],
                                 choice: choice, org: org)
            }
        }
    }

    private func showPreview(agentTag: String, choice: ProjectChoice, org: String?) {
        var preview = Focus(id: "preview", agentTag: agentTag, projectPath: nil, isBuiltIn: false, org: org)
        switch choice {
        case .noCodebase: preview.noCodebase = true
        case .project(let path): preview.projectPath = path
        }
        // The placeholder is the default name, so a blank label field reads as
        // "this is what you'll get".
        labelField.placeholderString = preview.displayName
        namePreview.stringValue = "→ \(Focus.normalizedLabel(labelField.stringValue) ?? preview.displayName)"
    }

    /// Re-render the preview after the label text changed (no org lookup needed:
    /// the org never affects the name).
    private func refreshPreviewText() {
        guard !agents.isEmpty, let choice = selectedProjectChoice else { return }
        showPreview(agentTag: agents[agentPopup.indexOfSelectedItem], choice: choice, org: nil)
    }

    // MARK: - Actions

    // MARK: - Tabs

    private func buildTabs() {
        guard let contentView = window?.contentView else { return }
        let cancel = contentView.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }
        newTabViews = contentView.subviews.filter { $0 !== createBtn && $0 !== cancel }
        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.segmentStyle = .texturedRounded
        tabControl.setAccessibilityLabel("New or Resume")
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabControl)

        resumeBtn.title = "Resume"
        resumeBtn.bezelStyle = .rounded
        resumeBtn.target = self
        resumeBtn.action = #selector(resumeTapped)
        resumeBtn.translatesAutoresizingMaskIntoConstraints = false
        resumeTab.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            tabControl.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
        ])

        resumeTab.onResume = { [weak self] e in self?.beginResume(e) }
        resumeTab.onRemove = { [weak self] e in self?.removeEntry(e) }
        resumeTab.onRename = { [weak self] e in self?.beginRename(e) }
        resumeTab.onShowTranscript = { e in
            if let path = e.transcriptPath, ConversationHistoryStore.isShowableTranscript(path) {
                ActivationAudit.note("resume:show-transcript-in-finder")
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
        resumeTab.onCancel = { [weak self] in self?.cancelTapped() }
        resumeTab.onSelectionChange = { [weak self] in self?.refreshResumeButton() }
        resumeTab.onFirstPromptsToggled = { [weak history] on in history?.setFirstPrompts(enabled: on) }

        // The store speaks on the main thread, so these are synchronous.
        history.changes.sink { [weak self] in self?.reloadHistory() }.store(in: &cancellables)
        history.resumeResults.sink { [weak self] id, result in self?.resumeFinished(id: id, result: result) }
            .store(in: &cancellables)
        reloadHistory()
        history.refresh()
    }

    private func reloadHistory() {
        resumeTab.update(history: history.history, supported: history.isSupported)
    }

    @objc private func tabChanged() { selectTab(Tab(rawValue: tabControl.selectedSegment) ?? .new) }

    func selectTab(_ tab: Tab) {
        currentTab = tab
        Self.rememberedTab = tab
        tabControl.selectedSegment = tab.rawValue
        let onNew = tab == .new
        newTabViews.forEach { $0.isHidden = !onNew }
        createBtn.isHidden = !onNew
        setResumeViewsAttached(!onNew)
        createBtn.keyEquivalent = onNew ? "\r" : ""
        resumeBtn.keyEquivalent = onNew ? "" : "\r"
        window?.setContentSize(onNew ? newTabSize : Self.resumeSize)
        if onNew {
            window?.makeFirstResponder(nil)
        } else {
            reloadHistory()
            history.refresh()
            window?.makeFirstResponder(resumeTab.searchField)
        }
        refreshResumeButton()
    }

    /// The Resume views live in the window only while that tab shows, so the New form is exactly as it was.
    private func setResumeViewsAttached(_ attached: Bool) {
        guard let contentView = window?.contentView else { return }
        if !attached {
            NSLayoutConstraint.deactivate(resumeConstraints)
            resumeConstraints = []
            resumeTab.removeFromSuperview()
            resumeBtn.removeFromSuperview()
            return
        }
        guard resumeTab.superview == nil else { return }
        let cancel = contentView.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }
        contentView.addSubview(resumeTab)
        contentView.addSubview(resumeBtn)
        if let cancel { contentView.addSubview(cancel, positioned: .above, relativeTo: resumeTab) }
        let anchor = cancel ?? createBtn
        resumeConstraints = [
            resumeTab.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 10),
            resumeTab.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            resumeTab.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            resumeTab.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            resumeBtn.trailingAnchor.constraint(equalTo: anchor.leadingAnchor, constant: -8),
            resumeBtn.centerYAnchor.constraint(equalTo: anchor.centerYAnchor),
        ]
        NSLayoutConstraint.activate(resumeConstraints)
    }

    private func refreshResumeButton() {
        guard let e = resumeTab.selectedEntry else { resumeBtn.isEnabled = false; return }
        resumeBtn.isEnabled = ResumeTabView.isResumable(e)
    }

    /// ⌘1 / ⌘2 switch tabs; ⌘⌫ removes the selected row on Resume. Local to the sheet.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "1": selectTab(.new); return true
        case "2": selectTab(.resume); return true
        case "r" where currentTab == .resume: resumeTab.renameSelected(); return true
        default: break
        }
        if event.keyCode == 51, currentTab == .resume { resumeTab.removeSelected(); return true }
        return false
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { sheetUndo }
    var sheetUndoManager: UndoManager { sheetUndo }

    // MARK: Resume and remove

    @objc private func resumeTapped() { resumeTab.resumeSelected() }

    /// How a `ResumeChoice` is shown; tests replace it to answer without a window.
    var choicePresenter: ((ResumeChoice, @escaping (ResumeChoice.Outcome) -> Void) -> Void)?

    /// The folder each conversation's last resume asked for, kept for a "Resume anyway" that follows.
    private var resumePlaces: [String: String] = [:]
    private var resumeNoCodebaseFolders: [String: String] = [:]

    /// Makes a no-codebase folder (Create, and Resume with no codebase). Tests replace it; it must not
    /// touch the real home or `~/.nostromo-spaces`.
    var noCodebaseFolderMaker: () -> Result<URL, NoCodebaseFolder.Failure> = { NoCodebaseFolder.create() }

    private func ask(_ choice: ResumeChoice, _ handle: @escaping (ResumeChoice.Outcome) -> Void) {
        if let present = choicePresenter { present(choice, handle) }
        else if let window { choice.present(on: window, completion: handle) }
    }

    private func startResume(_ id: String, place: String?, noCodebaseFolder: String? = nil,
                             confirmActiveElsewhere: Bool) {
        resumePlaces[id] = place
        resumeNoCodebaseFolders[id] = noCodebaseFolder
        history.resume(id, place: place, noCodebaseFolder: noCodebaseFolder,
                       confirmActiveElsewhere: confirmActiveElsewhere)
    }

    /// Make the new folder (nothing is sent when that fails: the reason is shown) and resume into it.
    private func resumeWithNoCodebase(_ id: String, confirmActiveElsewhere: Bool) {
        switch noCodebaseFolderMaker() {
        case .success(let folder):
            startResume(id, place: nil, noCodebaseFolder: folder.path, confirmActiveElsewhere: confirmActiveElsewhere)
        case .failure(let failure):
            resumeTab.showMessage(failure.reason)
        }
    }

    private func beginResume(_ e: ConversationEntryWire) {
        resumeTab.showMessage(nil)
        guard let choice = ResumeChoice.make(for: e) else { startResume(e.id, place: nil, confirmActiveElsewhere: false); return }
        // Nothing is sent until the user chooses; Cancel (the default for "open elsewhere") sends nothing.
        ask(choice) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .resumeInMain(let place):
                // A gone worktree that may also be open elsewhere needs both answers.
                if e.status.isAlsoActiveElsewhere {
                    self.ask(ResumeChoice.activeElsewhere()) { [weak self] second in
                        if second == .resumeAnyway {
                            self?.startResume(e.id, place: place, confirmActiveElsewhere: true)
                        }
                    }
                } else {
                    self.startResume(e.id, place: place, confirmActiveElsewhere: false)
                }
            case .resumeWithNoCodebase:
                if e.status.isAlsoActiveElsewhere {
                    self.ask(ResumeChoice.activeElsewhere()) { [weak self] second in
                        if second == .resumeAnyway { self?.resumeWithNoCodebase(e.id, confirmActiveElsewhere: true) }
                    }
                } else {
                    self.resumeWithNoCodebase(e.id, confirmActiveElsewhere: false)
                }
            case .resumeAnyway: self.startResume(e.id, place: nil, confirmActiveElsewhere: true)
            case .showTranscript: self.resumeTab.onShowTranscript?(e)
            case .cancel: break
            }
        }
    }

    /// The Rename sheet: one field, the same 60-character rule as a focus label.
    var renameTitleProvider: ((ConversationEntryWire, @escaping (String?) -> Void) -> Void)?

    private func beginRename(_ e: ConversationEntryWire) {
        let apply: (String?) -> Void = { [weak self] title in self?.history.rename(e.id, to: title) }
        if let provider = renameTitleProvider { provider(e, apply); return }
        guard let window else { return }
        let (alert, field) = RenameEntryAlert.make(currentTitle: e.title)
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { apply(field.stringValue) }
        }
    }

    /// The daemon holds the resumed tag for only its reservation window (15 s), so the org lookup
    /// that groups the focus gets this long; after it the focus opens without an org.
    static var resumeOrgLookupLimit: TimeInterval = 3

    private func finishResume(with focus: Focus) {
        // A resumed focus is grouped under its org like any other: look it up, then open it.
        var finished = false
        let finish: (String?) -> Void = { [weak self] org in
            guard !finished, let self else { return }
            finished = true
            guard !self.isCancelled else {
                // Cancelled while the lookup ran: the daemon still holds the tag.
                self.history.releaseResumedTag(focus.sessionTag)
                return
            }
            var focus = focus
            focus.org = org
            self.closeSheet()
            self.onCreate(focus)
        }
        // A no-codebase focus is always Personal: no org lookup.
        if focus.noCodebase { finish("Personal"); return }
        orgResolver.resolve(focus.projectPath ?? "", completion: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeOrgLookupLimit) { finish(nil) }
    }

    private func resumeFinished(id: String, result: ConversationHistoryStore.ResumeResult) {
        switch result {
        case .opened: break   // `finishResume` closed the sheet
        case .switched: closeSheet()
        case .waitingToStart: resumeTab.showMessage("Nostromo is starting\u{2026}")
        case .gaveUp: resumeTab.showMessage("Nostromo couldn\u{2019}t start. Try again in a moment.")
        // The list was stale: the daemon saw a recent write the row did not. Offer the choice
        // instead of an error, and keep the place the user already picked.
        case .refused("active_elsewhere"):
            ask(ResumeChoice.activeElsewhere()) { [weak self] outcome in
                guard outcome == .resumeAnyway else { return }
                self?.startResume(id, place: self?.resumePlaces[id],
                                  noCodebaseFolder: self?.resumeNoCodebaseFolders[id], confirmActiveElsewhere: true)
            }
        case .refused(let reason): resumeTab.showMessage(Self.refusalText(reason))
        }
    }

    static func refusalText(_ reason: String) -> String {
        switch reason {
        case "not_found": return "This conversation is no longer in History."
        case "active_elsewhere": return "This conversation may be open in another Claude window."
        case "folder_gone": return "The project folder is gone, so this can\u{2019}t be resumed here."
        default: return "Claude can\u{2019}t open this conversation."
        }
    }

    private func removeEntry(_ e: ConversationEntryWire) {
        history.remove(e.id)
        resumeTab.hide(e.id)
        sheetUndo.registerUndo(withTarget: self) { target in target.restoreEntry(e.id) }
        sheetUndo.setActionName("Remove from History")
    }

    private func restoreEntry(_ id: String) {
        history.restore(id)
        resumeTab.unhide(id)
        sheetUndo.registerUndo(withTarget: self) { target in
            if let e = target.history.entry(id) { target.removeEntry(e) }
        }
    }

    /// Close the sheet; what was removed is deleted now (the undo window is the sheet's lifetime).
    private func closeSheet() {
        history.purgeRemoved()
        history.cancelResumes()
        history.commitFocus = nil
        history.switchToTag = nil
        if let window { window.sheetParent?.endSheet(window) }
    }

    @objc func createTapped() {
        guard !isCreating, !isCancelled, !agents.isEmpty, let projectChoice = selectedProjectChoice else { return }
        isCreating = true
        createBtn.isEnabled = false
        let agentTag = agents[agentPopup.indexOfSelectedItem]
        let label    = Focus.normalizedLabel(labelField.stringValue)
        let choice   = modelPickers.choice
        func make(projectPath: String?, folder: String?, org: String?) -> Focus {
            var focus = Focus(id: UUID().uuidString,
                              agentTag: agentTag,
                              projectPath: projectPath,
                              isBuiltIn: false,
                              org: org,
                              sessionSummary: nil,
                              label: label,
                              initialModel: choice?.model,
                              initialEffort: choice?.effort)
            if let folder { focus.noCodebase = true; focus.workingDirectory = folder }
            return focus
        }
        switch projectChoice {
        case .noCodebase:
            // The folder is made now; a failure shows its reason, makes no focus and leaves nothing behind.
            switch noCodebaseFolderMaker() {
            case .failure(let failure):
                isCreating = false
                createBtn.isEnabled = !agents.isEmpty
                showProjectError(failure.reason)
            case .success(let folder):
                let focus = make(projectPath: nil, folder: folder.path, org: "Personal")
                closeSheet()
                onCreate(focus)
            }
        case .project(let projectPath):
            orgResolver.resolve(projectPath) { [weak self] org in   // org is nil if the lookup failed
                guard let self else { return }
                self.isCreating = false
                guard !self.isCancelled else { return }
                let focus = make(projectPath: projectPath, folder: nil, org: org)
                self.closeSheet()
                self.onCreate(focus)
            }
        }
    }

    @objc func cancelTapped() {
        isCancelled = true
        closeSheet()
    }

    // MARK: - Test seams

    var previewText: String { namePreview.stringValue }
    var isCreateEnabled: Bool { createBtn.isEnabled }
    /// Type into the optional Label field.
    func typeLabel(_ text: String) {
        labelField.stringValue = text
        refreshPreviewText()
    }
    /// The Model / Effort pickers' controller.
    var pickers: CreateFocusModelPickers { modelPickers }
    func selectAgent(at index: Int) { agentPopup.selectItem(at: index); pickerChanged() }
    /// Select the repo at `index` in the discovered projects (not a menu position).
    func selectProject(at index: Int) {
        guard let item = projectPopup.menu?.items.first(where: { !$0.isSeparatorItem && $0.tag == index }) else { return }
        projectPopup.select(item); updatePreview()
    }
    func selectNoCodebase() { projectPopup.selectItem(withTag: Self.noCodebaseTag); updatePreview() }
    var projectMenuTitles: [String] { projectPopup.menu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? [] }
    var projectErrorText: String { projectError.stringValue }
    var isResumeButtonEnabled: Bool { resumeBtn.isEnabled }
    func pressResume() { resumeTapped() }
}
