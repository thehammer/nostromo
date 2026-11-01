import AppKit
import NostromoKit

// MF6: the muted bar over a focus's transcript while Mother job notices for that focus are held by the
// loop guard or the wake cap. It has no buttons: the person's next message in the focus releases the hold.
// It is information only: never first responder, never makes anything else so, and the host that floats it
// never moves the transcript or the composer for it.

final class MotherNoticeHeldBar: NSView {

    static let height: CGFloat = 28

    let textLabel = NSTextField(labelWithString: "")
    private(set) var reason: MotherHeldBarReason

    init(reason: MotherHeldBarReason) {
        self.reason = reason
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = ApprovalPalette.cardBackground.cgColor
        layer?.borderColor = ApprovalPalette.mutedText.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.font = .systemFont(ofSize: 11)
        textLabel.textColor = ApprovalPalette.mutedText
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textLabel.translatesAutoresizingMaskIntoConstraints = true
        addSubview(textLabel)
        setReason(reason)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Read-only information: the bar is never a keyboard target.
    override var acceptsFirstResponder: Bool { false }

    /// Change the text in place (the frame is the host's to set).
    func setReason(_ reason: MotherHeldBarReason) {
        self.reason = reason
        let text = MotherNoticeText.heldBarText(reason)
        textLabel.stringValue = text
        textLabel.toolTip = text
        setAccessibilityLabel(text)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        textLabel.frame = NSRect(x: pad, y: (bounds.height - 16) / 2, width: max(0, bounds.width - 2 * pad), height: 16)
    }
}
