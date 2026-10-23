import AppKit
import NostromoKit

// AP2b: the production-shell guard's bar. A one-line, non-blocking notice floating above the approval card
// slot: `Blocked: Cody tried to send input to a production shell`. There is no card and no answer for it:
// the guard decided before anything was asked. It has a close button, and a link to the approvals log that
// is inert until AP5 wires it. It never takes focus: nothing here is first responder, and nothing makes it so.

final class GuardBlockedBar: NSView {

    static let height: CGFloat = 28
    static let closeWidth: CGFloat = 24
    static let linkWidth: CGFloat = 92

    let textLabel = NSTextField(labelWithString: "")
    let closeButton = NSButton()
    /// `View in log`: disabled and without a target until AP5.
    let logLink = NSButton()

    /// The person pressed close.
    var onClose: (() -> Void)?

    init(text: String) {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = ApprovalPalette.cardBackground.cgColor
        layer?.borderColor = ApprovalPalette.warning.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        textLabel.font = .systemFont(ofSize: 12, weight: .medium)
        textLabel.textColor = ApprovalPalette.commandText
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        logLink.isBordered = false
        logLink.isEnabled = false
        logLink.target = nil
        logLink.action = nil
        logLink.refusesFirstResponder = true
        logLink.attributedTitle = NSAttributedString(string: "View in log", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: ApprovalPalette.mutedText,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        logLink.setAccessibilityLabel("View in the approvals log (not available yet)")

        closeButton.isBordered = false
        closeButton.title = "✕"
        closeButton.font = .systemFont(ofSize: 11, weight: .semibold)
        closeButton.contentTintColor = ApprovalPalette.mutedText
        closeButton.refusesFirstResponder = true
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityLabel("Close")
        closeButton.toolTip = "Close"

        for v in [textLabel, logLink, closeButton] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        setText(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Read-only information: the bar is never a keyboard target.
    override var acceptsFirstResponder: Bool { false }

    /// Change the line's text in place (the frame is the host's to set).
    func setText(_ text: String) {
        ApprovalContextText.set(textLabel, text, wraps: false, font: .systemFont(ofSize: 12, weight: .medium),
                                color: ApprovalPalette.commandText)
        textLabel.toolTip = ApprovalDisplayModel.contextText(text, keepingLineFeeds: false)
        setAccessibilityLabel(ApprovalDisplayModel.contextText(text, keepingLineFeeds: false))
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let h = bounds.height
        closeButton.frame = NSRect(x: bounds.width - Self.closeWidth - 2, y: 0, width: Self.closeWidth, height: h)
        let linkX = closeButton.frame.minX - Self.linkWidth - 4
        let showLink = linkX > pad + 80
        logLink.isHidden = !showLink
        logLink.frame = NSRect(x: linkX, y: (h - 16) / 2, width: Self.linkWidth, height: 16)
        let right = showLink ? linkX - 8 : closeButton.frame.minX - 4
        textLabel.frame = NSRect(x: pad, y: (h - 16) / 2, width: max(0, right - pad), height: 16)
    }

    @objc private func closePressed() { onClose?() }
}
