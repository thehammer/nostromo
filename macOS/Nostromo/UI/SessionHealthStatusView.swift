import AppKit

/// Inline health status strip shown in the pace-bars row when the active focus
/// session is unhealthy. Replaces the bars in place so the layout is unchanged.
///
/// Shows:
///   - A plain-text status line ("crashed — retrying" / "stopped — won't restart")
///   - Recovery buttons: Restart / New session / Dismiss
///
/// Recovery wires to the existing `ChatSession` action methods:
///   - Restart  → `ChatSession.restart()`
///   - New session → `ChatSession.newSession()`
///   - Dismiss  → `ChatSession.dismissHealth()` (suppresses until next health change)
class SessionHealthStatusView: NSView {

    // MARK: - Subviews

    private let statusLabel  = NSTextField(labelWithString: "")
    private let restartBtn   = NSButton()
    private let newSessionBtn = NSButton()
    private let dismissBtn   = NSButton()

    // MARK: - State

    private weak var chatSession: ChatSession?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // Status label
        statusLabel.font      = Theme.firaCode(size: 11)
        statusLabel.textColor = Theme.fgMuted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // Buttons
        for (btn, title) in [(restartBtn, "Restart"), (newSessionBtn, "New session"), (dismissBtn, "Dismiss")] {
            btn.title        = title
            btn.bezelStyle   = .rounded
            btn.isBordered   = true
            btn.font         = NSFont.systemFont(ofSize: 11, weight: .regular)
            btn.translatesAutoresizingMaskIntoConstraints = false
            addSubview(btn)
        }

        restartBtn.target    = self
        restartBtn.action    = #selector(restartTapped)
        newSessionBtn.target = self
        newSessionBtn.action = #selector(newSessionTapped)
        dismissBtn.target    = self
        dismissBtn.action    = #selector(dismissTapped)

        NSLayoutConstraint.activate([
            // Status label — left-aligned, vertically centered
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Buttons — stacked right-to-left from trailing edge
            dismissBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dismissBtn.centerYAnchor.constraint(equalTo: centerYAnchor),

            newSessionBtn.trailingAnchor.constraint(equalTo: dismissBtn.leadingAnchor, constant: -6),
            newSessionBtn.centerYAnchor.constraint(equalTo: centerYAnchor),

            restartBtn.trailingAnchor.constraint(equalTo: newSessionBtn.leadingAnchor, constant: -6),
            restartBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    // MARK: - Configure

    func configure(health: SessionHealth, chatSession: ChatSession?) {
        self.chatSession = chatSession

        switch health {
        case .recovering:
            statusLabel.stringValue = "crashed — retrying"
            statusLabel.textColor   = Theme.amber
            restartBtn.isHidden     = false
        case .permanentlyDown:
            statusLabel.stringValue = "stopped — won't restart"
            statusLabel.textColor   = Theme.redSweater
            restartBtn.isHidden     = false
        case .healthy:
            // Not expected — caller removes this view when healthy.
            statusLabel.stringValue = ""
            restartBtn.isHidden     = true
        }
    }

    // MARK: - Actions

    @objc private func restartTapped() {
        chatSession?.restart()
    }

    @objc private func newSessionTapped() {
        chatSession?.newSession()
    }

    @objc private func dismissTapped() {
        chatSession?.dismissHealth()
        // PaceBarsView subscribes to $activeFocusAgentTag; re-publishing the current
        // value forces a re-evaluation of displayedHealth (which now returns .healthy
        // because isDismissed is true) so the health strip removes itself.
        AppStore.shared.setActiveFocusAgentTag(AppStore.shared.activeFocusAgentTag)
    }
}
