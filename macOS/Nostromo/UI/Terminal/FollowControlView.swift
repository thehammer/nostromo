import AppKit
import os

private let followLog = Logger(subsystem: "com.hammer.nostromo", category: "terminal")

/// What the header's Follow badge opens: the invite form for a pane nobody follows (and for a Move), or
/// the manage buttons for one that is followed or paused. Everything it says and offers comes from
/// `FollowModel`; this view only draws it and sends frames through `TerminalSessionStore`.
///
/// Following starts from exactly one place here, **Invite**, and a person's gesture is required for
/// every button that changes anything (Invite, Stop following, Resume): each asks
/// `TerminalInputGuard.allowsControl` first, so a synthetic click, a marked key or an Accessibility
/// press does nothing, is reported to the daemon, and leaves the popover up. Picking a focus and ticking
/// the box ask too (a synthetic change is undone), so a person only ever invites what they chose; Move to…
/// only swaps the buttons for the form and sends nothing.
///
/// When the daemon knows the staging-only follow (`FollowModel.offersStagingOnly`), the form also asks what
/// the agent gets: the terminal's output (today's follow, the default) or staging only (it may stage commands
/// and receives no output). Each radio asks the guard like the other controls, and Invite sends the frame of the
/// chosen mode: `terminal_follow_invite_staging_only` for staging only, never `terminal_follow_invite`.
///
/// Nothing is ticked and nothing is sent until Invite: the "Include what's on screen now" box starts off
/// and the warning line names where the output would go (the environment, in capitals, for a remote pane).
final class FollowControlView: NSView {

    private static let contentWidth: CGFloat = 320
    /// What the stack leaves for a label: the content width less its 16 pt side insets.
    private static let innerWidth: CGFloat = contentWidth - 32

    private enum Mode { case invite, manage }

    private var model: FollowModel
    private let store: TerminalSessionStore
    /// Closes the popover this view is in.
    private let closePopover: () -> Void
    private var mode: Mode
    /// Told the form's size whenever it changes (Move to… swaps the buttons for the form), so the
    /// popover can follow it.
    var onSizeChange: ((NSSize) -> Void)?

    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The picker's last choice a person made (or the default), restored when a synthetic change is refused.
    private var pickedIndex = 0
    private let includeScreenCheckbox = NSButton(checkboxWithTitle: FollowModel.includeScreenTitle, target: nil, action: nil)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private var headingLabel: NSTextField?
    private var inviteButton: NSButton?
    private let modeTitleLabel = NSTextField(wrappingLabelWithString: FollowModel.modeGroupTitle)
    private let outputRadio = NSButton(radioButtonWithTitle: FollowModel.outputOptionTitle, target: nil, action: nil)
    private let stagingOnlyRadio = NSButton(radioButtonWithTitle: FollowModel.stagingOnlyOptionTitle, target: nil, action: nil)
    /// What the form currently asks for. A person's choice only: a refused (synthetic) radio change is undone.
    private var inviteMode: FollowModel.InviteMode = .output
    /// The event behind the control's action: what `TerminalInputGuard` judges. A test seam; always the
    /// application's current event in the app.
    var eventSource: () -> NSEvent? = { NSApp.currentEvent }
    private let stack = NSStackView()

    init(model: FollowModel, store: TerminalSessionStore = .shared, closePopover: @escaping () -> Void) {
        self.model = model
        self.store = store
        self.closePopover = closePopover
        self.mode = model.actions.contains(.invite) ? .invite : .manage
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        setAccessibilityIdentifier("terminal-follow-popover")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("FollowControlView is created in code")
    }

    // MARK: - Content

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        switch mode {
        case .invite: buildInviteForm()
        case .manage: buildManageButtons()
        }
        layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.contentWidth, height: fittingSize.height)
        setFrameSize(size)
        onSizeChange?(size)
    }

    private func buildInviteForm() {
        inviteMode = .output
        let heading = makeLabel(model.inviteHeading,
                            font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor, id: "terminal-follow-heading")
        headingLabel = heading
        stack.addArrangedSubview(heading)

        fillPicker(keeping: nil)
        picker.target = self
        picker.action = #selector(followFocusChanged(_:))
        picker.setAccessibilityIdentifier("terminal-follow-picker")
        picker.setAccessibilityLabel("Agent focus to follow this terminal")
        stack.addArrangedSubview(picker)

        if model.offersStagingOnly { addModeChoice() }

        includeScreenCheckbox.state = FollowModel.includeScreenDefault ? .on : .off
        includeScreenCheckbox.target = self
        includeScreenCheckbox.action = #selector(includeScreenToggled(_:))
        includeScreenCheckbox.setAccessibilityIdentifier("terminal-follow-include-screen")
        stack.addArrangedSubview(includeScreenCheckbox)

        let isRemote = TerminalChromeModel.isRemote(model.info)
        warningLabel.font = .systemFont(ofSize: 12, weight: isRemote ? .semibold : .regular)
        warningLabel.textColor = isRemote ? .systemRed : .secondaryLabelColor
        warningLabel.preferredMaxLayoutWidth = Self.innerWidth
        warningLabel.maximumNumberOfLines = 0
        warningLabel.isSelectable = false
        warningLabel.setAccessibilityIdentifier("terminal-follow-warning")
        stack.addArrangedSubview(warningLabel)
        updateWarning()

        let invite = makeButton("Invite", id: "terminal-follow-invite", label: "Invite the chosen agent to follow this terminal",
                            action: #selector(inviteTapped(_:)))
        invite.isEnabled = picker.numberOfItems > 0
        inviteButton = invite
        stack.addArrangedSubview(invite)
        refreshForm()
    }

    /// "What the agent gets": two radios, output first and chosen. No key equivalent on either.
    private func addModeChoice() {
        modeTitleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        modeTitleLabel.textColor = .labelColor
        modeTitleLabel.preferredMaxLayoutWidth = Self.innerWidth
        modeTitleLabel.maximumNumberOfLines = 0
        modeTitleLabel.isSelectable = false
        modeTitleLabel.setAccessibilityIdentifier("terminal-follow-mode-title")
        stack.addArrangedSubview(modeTitleLabel)
        for (radio, id) in [(outputRadio, "terminal-follow-mode-output"), (stagingOnlyRadio, "terminal-follow-mode-staging-only")] {
            radio.target = self
            radio.action = #selector(inviteModeChanged(_:))
            radio.setAccessibilityIdentifier(id)
            radio.font = .systemFont(ofSize: 12)
            // Wrapped, at a height measured here: a button does not report a wrapped title's height by itself.
            radio.cell?.wraps = true
            radio.lineBreakMode = .byWordWrapping
            radio.translatesAutoresizingMaskIntoConstraints = false
            let textWidth = Self.innerWidth - 22
            let measured = (radio.title as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: [.font: NSFont.systemFont(ofSize: 12)]).height
            NSLayoutConstraint.activate([
                radio.widthAnchor.constraint(equalToConstant: Self.innerWidth),
                radio.heightAnchor.constraint(equalToConstant: ceil(measured) + 4),
            ])
            stack.addArrangedSubview(radio)
        }
        applyRadioStates()
    }

    private func applyRadioStates() {
        outputRadio.state = inviteMode == .output ? .on : .off
        stagingOnlyRadio.state = inviteMode == .stagingOnly ? .on : .off
    }

    /// Everything on the form that depends on the mode and the chosen focus: the heading, the picker's focuses,
    /// the include-screen box, the warning and Invite's spoken label.
    private func refreshForm() {
        fillPicker(keeping: selectedTag)
        refreshDetails()
    }

    /// `refreshForm` without refilling the picker.
    private func refreshDetails() {
        headingLabel?.stringValue = model.inviteHeading(forTag: selectedTag, mode: inviteMode)
        let output = inviteMode == .output
        // With no output going out there is no screen to include.
        if !output { includeScreenCheckbox.state = .off }
        includeScreenCheckbox.isEnabled = output
        updateWarning()
        inviteButton?.setAccessibilityLabel(model.inviteAccessibilityLabel(mode: inviteMode))
        inviteButton?.isEnabled = picker.numberOfItems > 0
    }

    private func buildManageButtons() {
        let status = makeLabel(model.badgeText, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor,
                           id: "terminal-follow-status")
        stack.addArrangedSubview(status)
        let detail = makeLabel(model.badgeDescription, font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                           id: "terminal-follow-detail")
        stack.addArrangedSubview(detail)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        for action in model.actions {
            switch action {
            case .resume:
                row.addArrangedSubview(makeButton("Resume", id: "terminal-follow-resume", label: "Resume following",
                                              action: #selector(resumeTapped(_:))))
            case .stop:
                row.addArrangedSubview(makeButton("Stop following", id: "terminal-follow-stop", label: "Stop following this terminal",
                                              action: #selector(stopTapped(_:))))
            case .move:
                row.addArrangedSubview(makeButton("Move to\u{2026}", id: "terminal-follow-move", label: "Move the following to another agent",
                                              action: #selector(moveTapped(_:))))
            case .invite:
                break
            }
        }
        stack.addArrangedSubview(row)
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor, id: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.preferredMaxLayoutWidth = Self.innerWidth
        field.maximumNumberOfLines = 0
        field.isSelectable = false
        field.setAccessibilityIdentifier(id)
        return field
    }

    private func makeButton(_ title: String, id: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier(id)
        button.setAccessibilityLabel(label)
        return button
    }

    /// Lists the focuses the model offers, selecting `tag` when it is still offered, else the model's default.
    private func fillPicker(keeping tag: String?) {
        let offered = model.inviteFocuses(for: inviteMode)
        picker.removeAllItems()
        for option in offered {
            picker.addItem(withTitle: option.name)
            picker.lastItem?.representedObject = option.tag
        }
        let wanted = [tag, model.defaultInviteTag].compactMap { $0 }
        if let index = wanted.lazy.compactMap({ t in offered.firstIndex(where: { $0.tag == t }) }).first {
            picker.selectItem(at: index)
        }
        pickedIndex = max(0, picker.indexOfSelectedItem)
    }

    /// A focus was renamed, added or removed while the popover is open: the picker shows the current names
    /// and keeps the person's choice. Sends nothing.
    func update(model newModel: FollowModel) {
        guard newModel.focuses != model.focuses else { return }
        let chosen = selectedTag
        model = newModel
        guard mode == .invite else { return }
        fillPicker(keeping: chosen)
        refreshDetails()
    }

    private var selectedTag: String? {
        picker.selectedItem?.representedObject as? String
    }

    private func updateWarning() {
        warningLabel.stringValue = selectedTag.map { model.warning(forFocusTag: $0, mode: inviteMode) } ?? ""
    }

    // MARK: - Actions

    /// Changes which focus the warning names. Only a person's choice counts: a synthetic one is undone and
    /// reported, so the form never holds a focus a person did not pick. Sends nothing.
    @objc private func followFocusChanged(_ sender: NSPopUpButton) {
        // A popup's action carries the mouse event that tracked its menu, which belongs to the menu's window.
        guard TerminalInputGuard.allowsControl(event: eventSource(), control: sender, fromMenu: true) else {
            picker.selectItem(at: pickedIndex)
            store.reportRefusal(terminalId: model.info.terminalId, op: .followInvite)
            updateWarning()
            return
        }
        pickedIndex = picker.indexOfSelectedItem
        headingLabel?.stringValue = model.inviteHeading(forTag: selectedTag, mode: inviteMode)
        updateWarning()
    }

    /// The "What the agent gets" radios: a person's choice only. A synthetic change is undone and reported.
    /// Sends nothing: Invite does.
    @objc private func inviteModeChanged(_ sender: NSButton) {
        guard TerminalInputGuard.allowsControl(event: eventSource(), control: sender) else {
            applyRadioStates()
            store.reportRefusal(terminalId: model.info.terminalId, op: .followInvite)
            return
        }
        inviteMode = sender === stagingOnlyRadio ? .stagingOnly : .output
        applyRadioStates()
        refreshForm()
    }

    /// The "Include what's on screen now" box: a person's tick only. A synthetic one is undone and reported.
    @objc private func includeScreenToggled(_ sender: NSButton) {
        guard TerminalInputGuard.allowsControl(event: eventSource(), control: sender) else {
            sender.state = FollowModel.includeScreenDefault ? .on : .off
            store.reportRefusal(terminalId: model.info.terminalId, op: .followInvite)
            return
        }
    }

    /// Shows the invite form for a followed pane. Sends nothing; the Invite button still has to be pressed.
    @objc private func moveTapped(_ sender: NSButton) {
        mode = .invite
        rebuild()
    }

    /// The only thing here that starts following (or hands it to another focus). A person's click.
    @objc private func inviteTapped(_ sender: NSButton) {
        guard let tag = selectedTag else { return }
        let id = model.info.terminalId
        guard TerminalInputGuard.allowsControl(event: eventSource(), control: sender) else {
            followLog.notice("follow invite refused: not a human gesture (terminal \(id, privacy: .public))")
            store.reportRefusal(terminalId: id, op: .followInvite)
            return
        }
        switch inviteMode {
        case .stagingOnly:
            store.inviteFollowStagingOnly(terminalId: id, followerTag: tag)
        case .output:
            store.inviteFollow(terminalId: id, followerTag: tag, includeScreen: includeScreenCheckbox.state == .on)
        }
        closePopover()
    }

    /// Takes effect at once: the daemon discards output it has not delivered yet.
    @objc private func stopTapped(_ sender: NSButton) {
        let id = model.info.terminalId
        guard TerminalInputGuard.allowsControl(event: eventSource(), control: sender) else {
            store.reportRefusal(terminalId: id, op: .followStop)
            return
        }
        store.stopFollow(terminalId: id)
        closePopover()
    }

    @objc private func resumeTapped(_ sender: NSButton) {
        let id = model.info.terminalId
        guard TerminalInputGuard.allowsControl(event: eventSource(), control: sender) else {
            store.reportRefusal(terminalId: id, op: .followResume)
            return
        }
        store.resumeFollow(terminalId: id)
        closePopover()
    }
}
