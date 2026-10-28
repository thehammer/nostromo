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
/// press does nothing, is reported to the daemon, and leaves the popover up. Picking a focus, ticking
/// the box and Move to… only change what the form shows, so they need no gesture.
///
/// Nothing is ticked and nothing is sent until Invite: the "Include what's on screen now" box starts off
/// and the warning line names where the output would go (the environment, in capitals, for a remote pane).
final class FollowControlView: NSView {

    private static let contentWidth: CGFloat = 320

    private enum Mode { case invite, manage }

    private let model: FollowModel
    private let store: TerminalSessionStore
    /// Closes the popover this view is in.
    private let closePopover: () -> Void
    private var mode: Mode
    /// Told the form's size whenever it changes (Move to… swaps the buttons for the form), so the
    /// popover can follow it.
    var onSizeChange: ((NSSize) -> Void)?

    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let includeScreenCheckbox = NSButton(checkboxWithTitle: FollowModel.includeScreenTitle, target: nil, action: nil)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
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
        let innerWidth = Self.contentWidth - 32
        let heading = makeLabel(model.state == .notShared ? "Let an agent follow this terminal" : "Move this terminal to another agent",
                            font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor, id: "terminal-follow-heading")
        stack.addArrangedSubview(heading)

        // A Move is to another focus: the one that follows already is not offered.
        let offered = model.focuses.filter { $0.tag != model.info.follower?.tag }
        picker.removeAllItems()
        for option in offered {
            picker.addItem(withTitle: option.name)
            picker.lastItem?.representedObject = option.tag
        }
        if let tag = model.defaultInviteTag, let index = offered.firstIndex(where: { $0.tag == tag }) {
            picker.selectItem(at: index)
        }
        picker.target = self
        picker.action = #selector(followFocusChanged(_:))
        picker.setAccessibilityIdentifier("terminal-follow-picker")
        picker.setAccessibilityLabel("Agent focus to follow this terminal")
        stack.addArrangedSubview(picker)

        includeScreenCheckbox.state = FollowModel.includeScreenDefault ? .on : .off
        includeScreenCheckbox.setAccessibilityIdentifier("terminal-follow-include-screen")
        stack.addArrangedSubview(includeScreenCheckbox)

        warningLabel.font = .systemFont(ofSize: 12, weight: TerminalChromeModel.isRemote(model.info) ? .semibold : .regular)
        warningLabel.textColor = TerminalChromeModel.isRemote(model.info) ? .systemRed : .secondaryLabelColor
        warningLabel.preferredMaxLayoutWidth = innerWidth
        warningLabel.maximumNumberOfLines = 0
        warningLabel.isSelectable = false
        warningLabel.setAccessibilityIdentifier("terminal-follow-warning")
        stack.addArrangedSubview(warningLabel)
        updateWarning()

        let invite = makeButton("Invite", id: "terminal-follow-invite", label: "Invite the chosen agent to follow this terminal",
                            action: #selector(inviteTapped(_:)))
        invite.isEnabled = picker.numberOfItems > 0
        stack.addArrangedSubview(invite)
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
        field.preferredMaxLayoutWidth = Self.contentWidth - 32
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

    private var selectedTag: String? {
        picker.selectedItem?.representedObject as? String
    }

    private func updateWarning() {
        warningLabel.stringValue = selectedTag.map { model.warning(forFocusTag: $0) } ?? ""
    }

    // MARK: - Actions

    /// Changes which focus the warning names. Sends nothing.
    @objc private func followFocusChanged(_ sender: NSPopUpButton) {
        updateWarning()
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
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            followLog.notice("follow invite refused: not a human gesture (terminal \(id, privacy: .public))")
            store.reportRefusal(terminalId: id, op: .followInvite)
            return
        }
        store.inviteFollow(terminalId: id, followerTag: tag, includeScreen: includeScreenCheckbox.state == .on)
        closePopover()
    }

    /// Takes effect at once: the daemon discards output it has not delivered yet.
    @objc private func stopTapped(_ sender: NSButton) {
        let id = model.info.terminalId
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            store.reportRefusal(terminalId: id, op: .followStop)
            return
        }
        store.stopFollow(terminalId: id)
        closePopover()
    }

    @objc private func resumeTapped(_ sender: NSButton) {
        let id = model.info.terminalId
        guard TerminalInputGuard.allowsControl(event: NSApp.currentEvent, control: sender) else {
            store.reportRefusal(terminalId: id, op: .followResume)
            return
        }
        store.resumeFollow(terminalId: id)
        closePopover()
    }
}
