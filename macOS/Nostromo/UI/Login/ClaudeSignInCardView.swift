import AppKit
import NostromoKit
import os

private let signInLog = Logger(subsystem: "com.hammer.nostromo", category: "claude-login")

// CL2: the "Claude needs you to sign in" card for one focus.
//
// Every button runs `HumanGesture.permit` first. On `.refused` nothing is launched or sent, the
// card stays, and one content-free debug line records why. No button answers to Return or Esc
// (none is a default button), and nothing here takes keyboard focus.

final class ClaudeSignInCardView: NSView {

    typealias GesturePermit = (NSView) -> HumanGestureVerdict

    static let padding: CGFloat = 12
    static let buttonHeight: CGFloat = 24
    static let rowGap: CGFloat = 8

    let focusTag: String
    private(set) var model: ClaudeLoginCardModel
    private var claudeBin: String?
    /// What the last terminal launch said ("Opened …"); cleared when the phase or the hold changes.
    private var launchStatus = ""
    /// A launch is running; a second press during it opens nothing.
    private var opening = false
    private var shownHold: String?
    private var lastPhase: ClaudeLoginPhase
    private let store: ClaudeLoginStore
    private let launcher: LoginTerminalLauncher
    private let permit: GesturePermit
    private let copyToPasteboard: (String) -> Void

    let titleLabel = NSTextField(labelWithString: "")
    let bodyLabel = NSTextField(wrappingLabelWithString: "")
    /// "Opened tmux window …" / "Opened Terminal …" after a launch; empty before.
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let manualLabel = NSTextField(labelWithString: ClaudeLoginCardModel.manualCommandText)
    let openButton = NSButton(title: ClaudeLoginCardModel.openTerminalTitle, target: nil, action: nil)
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let resendButton = NSButton(title: "", target: nil, action: nil)
    let discardButton = NSButton(title: ClaudeLoginCardModel.discardTitle, target: nil, action: nil)

    init(tag: String, session: ClaudeLoginSession, claudeBin: String?, watch: ClaudeLoginWatch = .keychain,
         store: ClaudeLoginStore,
         launcher: LoginTerminalLauncher = LoginTerminalLauncher(),
         permit: GesturePermit? = nil,
         copyToPasteboard: @escaping (String) -> Void = { text in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.focusTag = tag
        self.claudeBin = claudeBin
        self.shownHold = session.holdId
        self.lastPhase = session.phase
        self.store = store
        self.launcher = launcher
        self.permit = permit ?? { HumanGesture.permit(NSApp.currentEvent, control: $0) }
        self.copyToPasteboard = copyToPasteboard
        model = ClaudeLoginCardModel(session: session, claudeBin: claudeBin, watch: watch)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = ApprovalPalette.cardBackground.cgColor
        layer?.borderColor = Theme.amber.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.fg
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = Theme.fgMuted
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.fgMuted
        manualLabel.font = .systemFont(ofSize: 12)
        manualLabel.textColor = Theme.fg
        manualLabel.lineBreakMode = .byTruncatingTail

        let wiring: [(NSButton, Selector, String)] = [
            (openButton, #selector(openPressed), "open-terminal"),
            (copyButton, #selector(copyPressed), "copy-command"),
            (resendButton, #selector(resendPressed), "resend"),
            (discardButton, #selector(discardPressed), "discard"),
        ]
        for (button, action, id) in wiring {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.identifier = NSUserInterfaceItemIdentifier(id)
        }
        for v in [titleLabel, bodyLabel, statusLabel, manualLabel, openButton, copyButton, resendButton, discardButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        apply(model)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(ClaudeLoginCardModel.title)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Show what `session` says now (a phase change, a new queue count).
    func update(session: ClaudeLoginSession, claudeBin: String?, watch: ClaudeLoginWatch = .keychain) {
        self.claudeBin = claudeBin
        let next = ClaudeLoginCardModel(session: session, claudeBin: claudeBin, watch: watch)
        // What a launch said belongs to the state it was said in.
        if session.phase != lastPhase || session.holdId != shownHold { launchStatus = "" }
        lastPhase = session.phase
        shownHold = session.holdId
        let shown = statusText
        guard next != model || shown != statusLabel.stringValue else { return }
        model = next
        apply(next)
        needsLayout = true
        superview?.needsLayout = true
    }

    /// A failed action's notice wins over the launch message.
    private var statusText: String { store.notice(tag: focusTag) ?? launchStatus }

    private func apply(_ m: ClaudeLoginCardModel) {
        titleLabel.stringValue = m.title
        bodyLabel.stringValue = m.body
        openButton.isHidden = !m.showsOpenTerminal
        manualLabel.isHidden = !m.showsManualCommand
        copyButton.isHidden = !m.showsManualCommand
        resendButton.title = m.resendTitle
        resendButton.isEnabled = m.resendEnabled
        discardButton.isHidden = !m.showsDiscard
        statusLabel.stringValue = statusText
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
    }

    // MARK: Layout

    static let controlGap: CGFloat = 8

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        let inner = max(0, width - 2 * Self.padding)
        var h = Self.padding + 18 + 4 + textHeight(bodyLabel, width: inner)
        if !statusLabel.isHidden { h += 4 + textHeight(statusLabel, width: inner) }
        return h + Self.rowGap + controlsHeight(inner: inner) + Self.padding
    }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard let cell = label.cell else { return 16 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// The visible controls, left to right, wrapped onto further lines when a line is full. Each is
    /// no wider than the card's inside, so a narrow pane clips nothing.
    private func controlRows(inner: CGFloat) -> [[(view: NSView, width: CGFloat)]] {
        var rows: [[(view: NSView, width: CGFloat)]] = [[]]
        var x: CGFloat = 0
        for view in [manualLabel, openButton, copyButton, resendButton, discardButton] as [NSView] where !view.isHidden {
            let natural = view === manualLabel ? ceil(manualLabel.intrinsicContentSize.width)
                                               : ceil((view as! NSButton).intrinsicContentSize.width) + 8
            let w = min(natural, inner)
            let lead = rows[rows.count - 1].isEmpty ? 0 : Self.controlGap
            if x + lead + w > inner, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            x += (rows[rows.count - 1].isEmpty ? 0 : Self.controlGap) + w
            rows[rows.count - 1].append((view, w))
        }
        return rows
    }

    private func controlsHeight(inner: CGFloat) -> CGFloat {
        let n = CGFloat(controlRows(inner: inner).count)
        return n * Self.buttonHeight + (n - 1) * Self.controlGap
    }

    override func layout() {
        super.layout()
        let pad = Self.padding
        let inner = max(0, bounds.width - 2 * pad)
        // Top-down in AppKit's bottom-up coordinates.
        var y = bounds.height - pad - 18
        titleLabel.frame = NSRect(x: pad, y: y, width: inner, height: 18)
        let bodyH = textHeight(bodyLabel, width: inner)
        y -= 4 + bodyH
        bodyLabel.frame = NSRect(x: pad, y: y, width: inner, height: bodyH)
        if !statusLabel.isHidden {
            let h = textHeight(statusLabel, width: inner)
            y -= 4 + h
            statusLabel.frame = NSRect(x: pad, y: y, width: inner, height: h)
        }
        // Controls sit at the bottom, the last line on the padding.
        let rows = controlRows(inner: inner)
        for (i, row) in rows.enumerated() {
            let rowY = pad + CGFloat(rows.count - 1 - i) * (Self.buttonHeight + Self.controlGap)
            var x = pad
            for (view, w) in row {
                let isLabel = view === manualLabel
                view.frame = NSRect(x: x, y: isLabel ? rowY + 3 : rowY, width: w,
                                    height: isLabel ? Self.buttonHeight - 6 : Self.buttonHeight)
                x += w + Self.controlGap
            }
        }
    }

    // MARK: Actions

    /// Only a person may press these. A refused gesture does nothing and keeps the card.
    private func isHuman(_ control: NSView, _ name: String) -> Bool {
        switch permit(control) {
        case .human:
            return true
        case .refused(let reason):
            signInLog.debug("claude sign-in \(name, privacy: .public) refused: \(reason.rawValue, privacy: .public)")
            return false
        }
    }

    @objc private func openPressed(_ sender: NSButton) {
        guard !opening, isHuman(sender, "open-terminal"), let bin = claudeBin else { return }
        opening = true
        sender.isEnabled = false
        launcher.open(claudeBin: bin) { [weak self] outcome in
            guard let self else { return }
            self.opening = false
            self.openButton.isEnabled = true
            let next = self.model.afterSignIn
            switch outcome {
            case .tmuxWindow?:
                self.launchStatus = "Opened tmux window \"\(LoginTerminalLauncher.windowName)\". Finish signing in there. \(next)"
            case .terminalApp?:
                self.launchStatus = "Opened Terminal. Finish signing in there. \(next)"
            case nil:
                self.launchStatus = "Couldn't open a terminal. Run `claude auth login` in one yourself."
            }
            self.apply(self.model)
            self.needsLayout = true
            self.superview?.needsLayout = true
        }
    }

    @objc private func copyPressed(_ sender: NSButton) {
        guard isHuman(sender, "copy-command") else { return }
        copyToPasteboard(ClaudeLoginCardModel.manualCommand)
    }

    @objc private func resendPressed(_ sender: NSButton) {
        guard isHuman(sender, "resend") else { return }
        store.retry(tag: focusTag)
    }

    @objc private func discardPressed(_ sender: NSButton) {
        guard isHuman(sender, "discard") else { return }
        store.discard(tag: focusTag)
    }
}
