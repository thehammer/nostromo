import AppKit

/// Sheet controller for creating a new dynamic Focus.
///
/// Presented via `window.beginSheet(_:)`. Discovers available agents from
/// `~/.claude/agents/*.md` and project directories from `~/Code/`.
final class CreateFocusSheet: NSWindowController, NSTextFieldDelegate {

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

    // Data
    private var agents:   [String] = []
    private var projects: [String] = []

    /// `agents` / `projects` override filesystem discovery (used by tests).
    init(orgResolver: RepoOrgResolver = RepoOrgResolver(),
         agents: [String]? = nil, projects: [String]? = nil,
         onCreate: @escaping (Focus) -> Void) {
        self.onCreate = onCreate
        self.orgResolver = orgResolver

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 256),
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
            projectPopup.removeAllItems()
            projectPopup.addItems(withTitles: projects.map { URL(fileURLWithPath: $0).lastPathComponent })
        }
        createBtn.isEnabled = !self.agents.isEmpty
        updatePreview()
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
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            agentLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            agentLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            agentLabel.widthAnchor.constraint(equalToConstant: 60),

            agentPopup.centerYAnchor.constraint(equalTo: agentLabel.centerYAnchor),
            agentPopup.leadingAnchor.constraint(equalTo: agentLabel.trailingAnchor, constant: 8),
            agentPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            projectLabel.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 14),
            projectLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            projectLabel.widthAnchor.constraint(equalToConstant: 60),

            projectPopup.centerYAnchor.constraint(equalTo: projectLabel.centerYAnchor),
            projectPopup.leadingAnchor.constraint(equalTo: projectLabel.trailingAnchor, constant: 8),
            projectPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            labelLabel.topAnchor.constraint(equalTo: projectLabel.bottomAnchor, constant: 14),
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
        // Agents: ~/.claude/agents/*.md — filename sans extension is the agent tag
        let agentsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/agents")
        agents = (try? FileManager.default.contentsOfDirectory(
            at: agentsDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []

        agentPopup.removeAllItems()
        agentPopup.addItems(withTitles: agents)
        // Default to claudia if present
        if let idx = agents.firstIndex(of: "claudia") {
            agentPopup.selectItem(at: idx)
        }

        // Projects: ~/Code/ subdirectories, excluding git worktrees.
        // A worktree has `.git` as a plain file; a normal repo has `.git` as a directory.
        let codeDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Code")
        let fm = FileManager.default
        projects = (try? fm.contentsOfDirectory(
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

        projectPopup.removeAllItems()
        projectPopup.addItems(withTitles: projects.map { URL(fileURLWithPath: $0).lastPathComponent })

        createBtn.isEnabled = !agents.isEmpty
    }

    // MARK: - Preview

    @objc private func pickerChanged() { updatePreview() }

    func controlTextDidChange(_ obj: Notification) { refreshPreviewText() }

    private func updatePreview() {
        guard !agents.isEmpty, !projects.isEmpty else {
            labelField.placeholderString = nil
            namePreview.stringValue = agents.isEmpty ? "No agents found in ~/.claude/agents" : ""
            return
        }
        let agentTag    = agents[agentPopup.indexOfSelectedItem]
        let projectPath = projects[projectPopup.indexOfSelectedItem]
        let cached = orgResolver.cached(projectPath)
        showPreview(agentTag: agentTag, projectPath: projectPath, org: cached ?? nil)
        if cached == nil {
            orgResolver.resolve(projectPath) { [weak self] org in
                guard let self, !self.agents.isEmpty, !self.projects.isEmpty,
                      self.projects[self.projectPopup.indexOfSelectedItem] == projectPath
                else { return }   // selection moved on; drop the stale result
                self.showPreview(agentTag: self.agents[self.agentPopup.indexOfSelectedItem],
                                 projectPath: projectPath, org: org)
            }
        }
    }

    private func showPreview(agentTag: String, projectPath: String, org: String?) {
        let preview = Focus(id: "preview", agentTag: agentTag, projectPath: projectPath,
                            isBuiltIn: false, org: org)
        // The placeholder is the default name, so a blank label field reads as
        // "this is what you'll get".
        labelField.placeholderString = preview.displayName
        namePreview.stringValue = "→ \(Focus.normalizedLabel(labelField.stringValue) ?? preview.displayName)"
    }

    /// Re-render the preview after the label text changed (no org lookup needed:
    /// the org never affects the name).
    private func refreshPreviewText() {
        guard !agents.isEmpty, !projects.isEmpty else { return }
        showPreview(agentTag: agents[agentPopup.indexOfSelectedItem],
                    projectPath: projects[projectPopup.indexOfSelectedItem], org: nil)
    }

    // MARK: - Actions

    @objc func createTapped() {
        guard !isCreating, !isCancelled, !agents.isEmpty, !projects.isEmpty else { return }
        isCreating = true
        createBtn.isEnabled = false
        let agentTag    = agents[agentPopup.indexOfSelectedItem]
        let projectPath = projects[projectPopup.indexOfSelectedItem]
        let label       = Focus.normalizedLabel(labelField.stringValue)
        orgResolver.resolve(projectPath) { [weak self] org in   // org is nil if the lookup failed
            guard let self else { return }
            self.isCreating = false
            guard !self.isCancelled else { return }
            let focus = Focus(id: UUID().uuidString,
                              agentTag: agentTag,
                              projectPath: projectPath,
                              isBuiltIn: false,
                              org: org,
                              sessionSummary: nil,
                              label: label)
            if let window = self.window { window.sheetParent?.endSheet(window) }
            self.onCreate(focus)
        }
    }

    @objc func cancelTapped() {
        isCancelled = true
        if let window { window.sheetParent?.endSheet(window) }
    }

    // MARK: - Test seams

    var previewText: String { namePreview.stringValue }
    var isCreateEnabled: Bool { createBtn.isEnabled }
    /// Type into the optional Label field.
    func typeLabel(_ text: String) {
        labelField.stringValue = text
        refreshPreviewText()
    }
    func selectProject(at index: Int) { projectPopup.selectItem(at: index); updatePreview() }
}
