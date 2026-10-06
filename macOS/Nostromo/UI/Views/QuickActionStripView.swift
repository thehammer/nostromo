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
            stack.addArrangedSubview(btn)
        }
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

        // Fixed height; horizontal padding via contentEdgeInsets equivalent
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: Self.buttonHeight).isActive = true

        return btn
    }

    @objc private func pillTapped(_ sender: NSButton) {
        let index = sender.tag
        guard actions.indices.contains(index) else { return }
        onTap(actions[index])
    }
}
