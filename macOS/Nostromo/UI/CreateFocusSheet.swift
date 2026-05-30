import AppKit

/// Sheet controller for creating a new dynamic Focus.
///
/// Presented via `window.beginSheet(_:)`. Discovers available agents from
/// `~/.claude/agents/*.md` and project directories from `~/Code/`.
final class CreateFocusSheet: NSWindowController {

    private let onCreate: (Focus) -> Void

    // UI
    private let agentPopup   = NSPopUpButton()
    private let projectPopup = NSPopUpButton()
    private let namePreview  = NSTextField(labelWithString: "")
    private let createBtn    = NSButton()

    // Data
    private var agents:   [String] = []
    private var projects: [String] = []

    init(onCreate: @escaping (Focus) -> Void) {
        self.onCreate = onCreate

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
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

            namePreview.topAnchor.constraint(equalTo: projectLabel.bottomAnchor, constant: 14),
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

    private func updatePreview() {
        guard !agents.isEmpty, !projects.isEmpty else {
            namePreview.stringValue = agents.isEmpty ? "No agents found in ~/.claude/agents" : ""
            return
        }
        let agentTag     = agents[agentPopup.indexOfSelectedItem]
        let projectPath  = projects[projectPopup.indexOfSelectedItem]
        let preview = Focus(id: "preview", agentTag: agentTag, projectPath: projectPath, isBuiltIn: false)
        namePreview.stringValue = "→ \(preview.displayName)"
    }

    // MARK: - Actions

    @objc private func createTapped() {
        guard !agents.isEmpty, !projects.isEmpty else { return }
        let agentTag    = agents[agentPopup.indexOfSelectedItem]
        let projectPath = projects[projectPopup.indexOfSelectedItem]
        let focus = Focus(id: UUID().uuidString,
                          agentTag: agentTag,
                          projectPath: projectPath,
                          isBuiltIn: false)
        window?.sheetParent?.endSheet(window!)
        onCreate(focus)
    }

    @objc private func cancelTapped() {
        window?.sheetParent?.endSheet(window!)
    }
}
