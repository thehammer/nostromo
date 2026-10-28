import AppKit

/// The band at the top of a terminal pane: the environment of a remote shell, then what it is (project,
/// service, shell, or a local shell's directory), the mirror hint, and a close x. No SwiftTerm, so the
/// tests lay it out directly.
///
/// A pane that is not known to be local is red whatever its kind says. The environment ("PRODUCTION", or
/// "REMOTE" when the daemon sent no target) is its own label on the left: it is never truncated and its
/// font shrinks (down to 6 pt) before it would clip, whatever the width or height. Only the rest
/// truncates, and the mirror hint gives way first. The header is 24 pt tall, or the pane's whole height
/// when that is less (the host gives it what it has).
final class TerminalPaneHeaderView: NSView {

    static let height: CGFloat = 24

    /// A click anywhere in the header that is not on the close button.
    var onMouseDown: ((NSEvent) -> Void)?
    /// The host wires its action here.
    let closeButton = NSButton()

    private let environmentLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let mirrorHint = NSTextField(labelWithString: "")
    private var isRemote = false

    private static let closeWidth: CGFloat = 28
    private static let gap: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = Theme.bgBar.cgColor
        titleLabel.font = Theme.statusFont
        titleLabel.textColor = Theme.fgMuted
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setAccessibilityIdentifier("terminal-title")
        environmentLabel.lineBreakMode = .byClipping
        environmentLabel.isHidden = true
        environmentLabel.setAccessibilityIdentifier("terminal-environment")
        closeButton.isBordered = false
        closeButton.setAccessibilityIdentifier("terminal-close-x")
        closeButton.setAccessibilityLabel("Close terminal")
        mirrorHint.font = Theme.statusFont
        mirrorHint.textColor = Theme.fgMuted
        mirrorHint.lineBreakMode = .byTruncatingHead
        mirrorHint.isHidden = true
        mirrorHint.setAccessibilityIdentifier("terminal-mirror-hint")
        for view in [environmentLabel, titleLabel, mirrorHint, closeButton] { addSubview(view) }
        apply(info: nil, mirrorHint: "")
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalPaneHeaderView is created in code")
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(event)
    }

    /// Set the texts and colours from the daemon's description of the pane (nil: not known yet, shown
    /// as a plain "Terminal"). `mirrorHint` is empty unless this window is a mirror.
    func apply(info: TerminalInfo?, mirrorHint hint: String) {
        isRemote = info.map { TerminalChromeModel.isRemote($0) } ?? false
        if let info, isRemote {
            environmentLabel.stringValue = TerminalChromeModel.environmentToken(for: info)
            titleLabel.stringValue = TerminalChromeModel.headerDetail(for: info)
        } else {
            environmentLabel.stringValue = ""
            titleLabel.stringValue = info?.headerTitle() ?? "Terminal"
        }
        environmentLabel.setAccessibilityLabel(isRemote ? "remote shell: \(environmentLabel.stringValue)" : nil)
        environmentLabel.isHidden = !isRemote
        environmentLabel.textColor = Theme.hazardText
        layer?.backgroundColor = (isRemote ? Theme.hazardRed : Theme.bgBar).cgColor
        titleLabel.textColor = isRemote ? Theme.hazardText : Theme.fgMuted
        titleLabel.font = isRemote ? NSFont.systemFont(ofSize: 12, weight: .semibold) : Theme.statusFont
        mirrorHint.stringValue = hint
        mirrorHint.isHidden = hint.isEmpty
        mirrorHint.textColor = isRemote ? Theme.hazardText : Theme.fgMuted
        closeButton.attributedTitle = NSAttributedString(string: "\u{00D7}", attributes: [
            .font: NSFont.systemFont(ofSize: 16, weight: .regular),
            .foregroundColor: isRemote ? Theme.hazardText : Theme.fgMuted,
        ])
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        closeButton.frame = NSRect(x: bounds.width - Self.closeWidth - 2, y: 0, width: Self.closeWidth, height: h)
        let labelSize = titleLabel.intrinsicContentSize
        let textEnd = max(10, bounds.width - Self.closeWidth - 10)
        guard isRemote else {
            // The hint keeps its width unless the pane is very narrow; the title gives way to it.
            let available = textEnd - 10
            let hintW = mirrorHint.isHidden ? 0 : min(mirrorHint.intrinsicContentSize.width, available * 0.6)
            let gap = mirrorHint.isHidden ? 0 : Self.gap
            mirrorHint.frame = NSRect(x: 10 + available - hintW, y: (h - labelSize.height) / 2, width: hintW, height: labelSize.height)
            titleLabel.frame = NSRect(x: 10, y: (h - labelSize.height) / 2, width: max(0, available - hintW - gap), height: labelSize.height)
            return
        }
        // The environment is laid out first, at its full width; then the title; the mirror hint gets only
        // what the title does not need.
        let envSize = fitEnvironmentLabel(width: textEnd - 10, height: h)
        environmentLabel.frame = NSRect(x: 10, y: (h - envSize.height) / 2, width: envSize.width, height: envSize.height)
        let restStart = 10 + envSize.width + Self.gap
        let rest = max(0, textEnd - restStart)
        var hintW: CGFloat = 0
        if !mirrorHint.isHidden {
            hintW = min(mirrorHint.intrinsicContentSize.width, max(0, rest - labelSize.width - Self.gap))
            if hintW < 16 { hintW = 0 }
        }
        let gap = hintW > 0 ? Self.gap : 0
        let y = (h - labelSize.height) / 2
        titleLabel.frame = NSRect(x: restStart, y: y, width: max(0, rest - hintW - gap), height: labelSize.height)
        mirrorHint.frame = NSRect(x: textEnd - hintW, y: y, width: hintW, height: labelSize.height)
    }

    /// The environment label's size in the largest bold font (12 pt down to 6 pt) that fits `width` x `height`.
    private func fitEnvironmentLabel(width: CGFloat, height: CGFloat) -> NSSize {
        var size: CGFloat = 12
        while true {
            environmentLabel.font = NSFont.systemFont(ofSize: size, weight: .bold)
            let fitted = environmentLabel.intrinsicContentSize
            if (fitted.width <= width && fitted.height <= height) || size <= 6 { return fitted }
            size -= 1
        }
    }
}
