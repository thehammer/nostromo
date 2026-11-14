import AppKit

// MARK: - QuickActionStripView

/// Horizontal strip of pill buttons, one per QuickAction.
/// Sits between the transcript scroll view and the input bar in ReplView.
class QuickActionStripView: NSView {

    // The strip's content geometry, and the height derived from it. ReplView
    // pins the strip to `height`; it used to hard-code 40 while the content
    // needed 1 + 8 + 24 + 8 = 41, so AppKit logged "Unable to simultaneously
    // satisfy constraints" on every layout rebuild and broke the buttons'
    // 24pt height to recover (found in live QA, 2026-10-06). Deriving it from
    // the same constants the constraints use means the two cannot drift apart.
    static let borderHeight: CGFloat = 1
    static let verticalInset: CGFloat = 8
    static let buttonHeight: CGFloat = 24
    static let height: CGFloat = borderHeight + verticalInset + buttonHeight + verticalInset

    private let onTap: (QuickAction) -> Void
    private var actions: [QuickAction] = []
    private var buttons: [String: NSButton] = [:]
    private var disabledReasons: [String: String] = [:]

    /// Padding either side of a pill's label.
    static let pillHorizontalPadding: CGFloat = 10
    static let enabledLabelColor = Theme.fg
    /// A disabled pill's label: dimmer than the enabled one, still readable (3:1 on the strip).
    static let disabledLabelColor = Theme.fg.withAlphaComponent(0.55)

    init(actions: [QuickAction], onTap: @escaping (QuickAction) -> Void) {
        self.actions = actions
        self.onTap   = onTap
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor

        // 1pt top border to match input bar / toolbar style
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderInactive.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)

        // Horizontal left-aligned stack of pill buttons
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment   = .centerY
        stack.spacing     = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: Self.borderHeight),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: border.bottomAnchor, constant: Self.verticalInset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalInset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])

        for (index, action) in actions.enumerated() {
            let btn = makePillButton(action: action, tag: index)
            buttons[action.id] = btn
            stack.addArrangedSubview(btn)
            applyAppearance(of: action)
        }
    }

    // MARK: Per-action enabling

    /// Enables or disables one action's pill. A disabled pill is drawn dimmed, not hidden, ignores
    /// clicks, and says why (`reason`) in its tooltip and accessibility help, before the action's own help.
    func setEnabled(_ enabled: Bool, forActionID id: String, reason: String? = nil) {
        guard buttons[id] != nil, let action = actions.first(where: { $0.id == id }) else { return }
        if enabled { disabledReasons[id] = nil } else { disabledReasons[id] = reason ?? "Unavailable right now." }
        applyAppearance(of: action)
    }

    func isEnabled(actionID id: String) -> Bool { buttons[id]?.isEnabled ?? false }

    /// The tooltip of an action's pill (also its accessibility help).
    func tooltip(forActionID id: String) -> String? { buttons[id]?.toolTip }

    /// The pill for an action, for tests that measure or click it.
    func pill(forActionID id: String) -> NSButton? { buttons[id] }

    /// Press an action's pill the way a click does: nothing happens when it is disabled.
    func tap(actionID id: String) {
        buttons[id]?.performClick(nil)
    }

    private func applyAppearance(of action: QuickAction) {
        guard let btn = buttons[action.id] else { return }
        let reason = disabledReasons[action.id]
        let enabled = reason == nil
        btn.isEnabled = enabled
        btn.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(enabled ? 0.20 : 0.08).cgColor
        btn.attributedTitle = NSAttributedString(string: action.label, attributes: [
            .font:            NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: enabled ? Self.enabledLabelColor : Self.disabledLabelColor,
        ])
        let help = [reason, action.help].compactMap { $0 }.joined(separator: " ")
        btn.toolTip = help.isEmpty ? nil : help
        btn.setAccessibilityLabel(action.accessibilityName)
        btn.setAccessibilityHelp(help.isEmpty ? nil : help)
    }

    private func makePillButton(action: QuickAction, tag index: Int) -> NSButton {
        let btn = NSButton()
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.20).cgColor
        btn.layer?.cornerRadius    = 5
        btn.tag    = index
        btn.target = self
        btn.action = #selector(pillTapped(_:))

        let attrs: [NSAttributedString.Key: Any] = [
            .font:            NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: Theme.fg,
        ]
        btn.attributedTitle = NSAttributedString(string: action.label, attributes: attrs)

        // Fixed height; the width is the label plus padding on both sides, so no label's last glyph
        // can sit against the pill's edge.
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true
        let labelWidth = ceil(btn.attributedTitle.size().width)
        btn.widthAnchor.constraint(equalToConstant: labelWidth + 2 * Self.pillHorizontalPadding).isActive = true

        return btn
    }

    @objc private func pillTapped(_ sender: NSButton) {
        let index = sender.tag
        guard actions.indices.contains(index), sender.isEnabled else { return }
        onTap(actions[index])
    }
}
