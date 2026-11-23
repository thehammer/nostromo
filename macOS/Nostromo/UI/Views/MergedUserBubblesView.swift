import AppKit

// A turn that answers several messages the daemon merged into one frame (`merged_turns_v1`): one
// user bubble per message, in the order typed, each showing exactly what was typed, then a small
// muted "sent together" caption. It fills the user slot of `ChatTurnView` where a single
// `UserBubbleView` would be, and is measured the same way (detached, at a fixed width).

final class MergedUserBubblesView: NSView {

    static let caption = "sent together"
    /// Gap between two bubbles, and between the last one and the caption.
    static let spacing: CGFloat = 6

    private let stack = NSStackView()
    private let captionLabel = NSTextField(labelWithString: MergedUserBubblesView.caption)
    private(set) var bubbles: [UserBubbleView] = []

    /// The text each bubble shows, in order.
    var shownParts: [String] { bubbles.map(\.shownText) }
    var captionText: String { captionLabel.stringValue }

    /// What VoiceOver reads for the group; each bubble reads its own full text inside it.
    static func accessibilityGroupLabel(count: Int) -> String { "Sent together, \(count) messages" }

    init(parts: [String]) {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for part in parts {
            let bubble = UserBubbleView(text: part)
            bubbles.append(bubble)
            stack.addArrangedSubview(bubble)
            bubble.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        captionLabel.font = .systemFont(ofSize: 10)
        captionLabel.textColor = Theme.fgMuted
        captionLabel.alignment = .right
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(captionLabel)
        captionLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.accessibilityGroupLabel(count: parts.count))
        captionLabel.setAccessibilityElement(false)   // the group label already says it
    }

    required init?(coder: NSCoder) { fatalError() }
}
