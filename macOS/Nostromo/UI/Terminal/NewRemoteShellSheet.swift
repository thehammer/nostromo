import AppKit

/// Terminal > New Remote Shell… (⇧⌘T): pick project, environment, service and shell type, then
/// Submit. Submit only asks the daemon to open the same "Connect to …" sheet an agent's request
/// would (without a "Requested by" line); nothing connects until Connect is clicked there. So the
/// picker itself needs no gesture check.
///
/// The choices come from the daemon's `remote_shell_targets`. The project starts as the one the
/// focus's directory belongs to (`ProjectDetection`), then production, the project's default
/// service, and `shell` (`RemoteShellPickerModel`). When the daemon has no ECS configuration the
/// sheet says why and where to set it up instead.
///
/// Presented with `beginSheet` by `AppDelegate.newRemoteShell`.
final class NewRemoteShellSheet: NSWindowController {

    private static let contentWidth: CGFloat = 420

    private let tag: String
    private let store: RemoteShellStore
    private var model: RemoteShellPickerModel?

    private let projectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let environmentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let servicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let shellTypePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let submitButton = NSButton(frame: .zero)

    /// - Parameters:
    ///   - targets: what the daemon offers, or nil when it has not said yet.
    ///   - tag: the focus the pane would open in.
    ///   - projectPath: that focus's project directory, for the project preselection.
    init(targets: RemoteShellTargets?, tag: String, projectPath: String?,
         home: String = NSHomeDirectory(), store: RemoteShellStore = .shared) {
        self.tag = tag
        self.store = store
        if let targets, targets.configured {
            model = RemoteShellPickerModel(targets: targets, projectPath: projectPath, home: home)
        }

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 200),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.title = "New Remote Shell"
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)

        super.init(window: win)
        if model != nil {
            buildPicker()
        } else {
            buildProblem(Self.problemText(for: targets))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// What the sheet says when there is nothing to pick from.
    static func problemText(for targets: RemoteShellTargets?) -> String {
        guard let targets else {
            return "Nostromo has not received the remote shell choices from its daemon yet. Try again in a moment."
        }
        if !targets.configured {
            let why = targets.problem ?? "Remote shells are not set up."
            return "\(why)\n\nRemote shells use the carefeed ECS settings. Put your AWS profiles in "
                + "~/.claude/ecs-local.json (run ecs_setup in a shell), then try again."
        }
        return "The ECS settings list no projects to connect to."
    }

    // MARK: - Build

    private func buildPicker() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "New Remote Shell")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white

        let note = NSTextField(wrappingLabelWithString:
            "Nothing connects until you click Connect on the next sheet.")
        note.preferredMaxLayoutWidth = Self.contentWidth - 40
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 0

        projectPopup.target = self
        projectPopup.action = #selector(projectChanged(_:))
        environmentPopup.target = self
        environmentPopup.action = #selector(environmentChanged(_:))
        servicePopup.target = self
        servicePopup.action = #selector(serviceChanged(_:))
        shellTypePopup.target = self
        shellTypePopup.action = #selector(shellTypeChanged(_:))
        for (popup, id) in [(projectPopup, "project"), (environmentPopup, "environment"),
                            (servicePopup, "service"), (shellTypePopup, "shell-type")] {
            popup.setAccessibilityIdentifier("new-remote-shell-\(id)")
        }

        let grid = NSGridView(views: [
            [Self.label("Project"), projectPopup],
            [Self.label("Environment"), environmentPopup],
            [Self.label("Service"), servicePopup],
            [Self.label("Shell type"), shellTypePopup],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, grid, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityIdentifier("new-remote-shell-cancel")
        submitButton.title = "Submit"
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"
        submitButton.target = self
        submitButton.action = #selector(submitTapped(_:))
        submitButton.setAccessibilityIdentifier("new-remote-shell-submit")
        let buttons = NSStackView(views: [cancel, submitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttons)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
        refreshPopups()
        window?.fitContent(toWidth: Self.contentWidth)
    }

    private func buildProblem(_ text: String) {
        guard let contentView = window?.contentView else { return }
        let title = NSTextField(labelWithString: "New Remote Shell")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        let body = NSTextField(wrappingLabelWithString: text)
        body.preferredMaxLayoutWidth = Self.contentWidth - 40
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.maximumNumberOfLines = 0
        body.isSelectable = true
        body.setAccessibilityIdentifier("new-remote-shell-problem")
        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let ok = NSButton(title: "OK", target: self, action: #selector(okTapped(_:)))
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.translatesAutoresizingMaskIntoConstraints = false
        ok.setAccessibilityIdentifier("new-remote-shell-ok")
        contentView.addSubview(ok)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            ok.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 18),
            ok.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            ok.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
        window?.fitContent(toWidth: Self.contentWidth)
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    // MARK: - State

    /// Show the model's lists and selections.
    private func refreshPopups() {
        guard let model else { return }
        Self.fill(projectPopup, items: model.projects, selected: model.project)
        Self.fill(environmentPopup, items: model.environments, selected: model.environment)
        Self.fill(servicePopup, items: model.services, selected: model.service)
        Self.fill(shellTypePopup, items: model.shellTypes, selected: model.shellType)
        submitButton.isEnabled = !model.environment.isEmpty && !model.service.isEmpty && !model.shellType.isEmpty
    }

    private static func fill(_ popup: NSPopUpButton, items: [String], selected: String) {
        popup.removeAllItems()
        popup.addItems(withTitles: items)
        popup.selectItem(withTitle: selected)
    }

    // MARK: - Actions

    @objc private func projectChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        model?.selectProject(name)
        refreshPopups()
    }

    @objc private func environmentChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        model?.selectEnvironment(name)
        refreshPopups()
    }

    @objc private func serviceChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        model?.selectService(name)
        refreshPopups()
    }

    @objc private func shellTypeChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem else { return }
        model?.selectShellType(name)
        refreshPopups()
    }

    /// Asks the daemon to show the confirm sheet. It does not connect.
    @objc private func submitTapped(_ sender: Any?) {
        guard let model else { return }
        store.open(tag: tag, target: model.selection)
        endSheet()
    }

    @objc private func cancelTapped(_ sender: Any?) {
        endSheet()
    }

    @objc private func okTapped(_ sender: Any?) {
        endSheet()
    }

    private func endSheet() {
        guard let window, let parent = window.sheetParent else { return }
        parent.endSheet(window)
    }
}
