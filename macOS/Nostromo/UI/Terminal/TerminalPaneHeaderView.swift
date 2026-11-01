import AppKit
import QuartzCore

/// The band at the top of a terminal pane: the environment of a remote shell, then what it is (project,
/// service, shell, or a local shell's directory), the mirror hint, the Follow badge and a close x. No
/// SwiftTerm, so the tests lay it out directly.
///
/// A pane that is not known to be local is red whatever its kind says. The environment ("PRODUCTION", or
/// "REMOTE" when the daemon sent no target) is its own label on the left: it is never truncated and its
/// font shrinks (down to 6 pt) before it would clip, whatever the width or height. Only the rest
/// truncates, and the mirror hint gives way first. The header is 24 pt tall, or the pane's whole height
/// when that is less (the host gives it what it has).
///
/// The Follow badge ("Not shared", "Followed by Claudia", "Paused, too much output") sits left of the
/// close x in every pane, local or remote, and is never hidden: the title and the hint give way to it,
/// and it keeps at least `FollowModel.badgeMinWidth` unless the pane is so narrow that the remote token
/// would otherwise not fit (then it shrinks to a coloured pill; the tooltip and accessibility label always
/// carry the whole sentence). It is a filled pill with dark text, so it reads on the red header too.
final class TerminalPaneHeaderView: NSView {

    static let height: CGFloat = 24

    /// A click anywhere in the header that is not on the close button.
    var onMouseDown: ((NSEvent) -> Void)?
    /// The host wires its action here.
    let closeButton = NSButton()
    /// The Follow badge. The host wires its action (it opens the invite or manage popover).
    let followButton = NSButton()
    /// `3 staged`: shown while the staged-commands drawer is closed and a list exists; a gated click reopens it.
    /// In a remote pane it sits after the environment token and is hidden before it would displace or clip it.
    let stagedChip = NSButton()
    /// How many times the chip pulsed for a new entry (tests).
    private(set) var chipPulseCount = 0
    private var chipCount: Int?

    private let environmentLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let mirrorHint = NSTextField(labelWithString: "")
    private var isRemote = false

    private static let closeWidth: CGFloat = 28
    private static let gap: CGFloat = 8
    /// The widest the badge asks for: a long focus name truncates (the tooltip has it all).
    private static let badgeMaxWidth: CGFloat = 200
    /// The narrowest a squeezed badge gets: still a visible, coloured pill.
    private static let badgeFloorWidth: CGFloat = 20
    private static let badgePadding: CGFloat = 12
    private static let badgeMaxHeight: CGFloat = 18

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
        followButton.isBordered = false
        followButton.wantsLayer = true
        followButton.layer?.cornerRadius = 4
        followButton.lineBreakMode = .byTruncatingTail
        followButton.setAccessibilityIdentifier("terminal-follow")
        stagedChip.isBordered = false
        stagedChip.wantsLayer = true
        stagedChip.layer?.cornerRadius = 4
        stagedChip.lineBreakMode = .byClipping
        stagedChip.isHidden = true
        stagedChip.setAccessibilityIdentifier("terminal-staged-chip")
        for view in [environmentLabel, titleLabel, mirrorHint, stagedChip, followButton, closeButton] { addSubview(view) }
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
    ///
    /// `follow` is what the Follow badge says; nil (no pane information yet) shows "Not shared".
    func apply(info: TerminalInfo?, mirrorHint hint: String, follow: FollowModel? = nil) {
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
        applyBadge(follow)
        needsLayout = true
    }

    /// Shows `n staged` (nil hides it). `pulse`: a new entry arrived (a short pulse, none under Reduce Motion).
    func setStagedChip(count: Int?, pulse: Bool = false) {
        chipCount = count
        if let count {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            stagedChip.attributedTitle = NSAttributedString(string: "\(count) staged", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: isRemote ? Theme.hazardText : Theme.bg,
                .paragraphStyle: paragraph,
            ])
            stagedChip.layer?.backgroundColor = (isRemote ? Theme.bg : Theme.followBlue).cgColor
            stagedChip.setAccessibilityLabel("\(count) staged commands, hidden. Show staged commands")
            stagedChip.toolTip = "Show the staged commands"
        }
        if count == nil { setChipHidden(true) }
        if pulse, count != nil {
            chipPulseCount += 1
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = stagedChip.layer {
                let animation = CABasicAnimation(keyPath: "opacity")
                animation.fromValue = 1
                animation.toValue = 0.3
                animation.duration = 0.35
                animation.autoreverses = true
                layer.add(animation, forKey: "staging-chip-pulse")
            }
        }
        needsLayout = true
    }

    /// Whether the chip is on screen (it hides when there is no room that does not belong to the token).
    var isChipShown: Bool { !stagedChip.isHidden }

    private func setChipHidden(_ hidden: Bool) {
        if stagedChip.isHidden != hidden { stagedChip.isHidden = hidden }
    }

    private var chipWidth: CGFloat {
        ceil(stagedChip.attributedTitle.size().width) + 14
    }

    override func layout() {
        super.layout()
        // Decided here and assigned once at the end: flipping `isHidden` inside `layout` would ask for another pass.
        var chipShown = chipCount != nil
        let h = bounds.height
        closeButton.frame = NSRect(x: bounds.width - Self.closeWidth - 2, y: 0, width: Self.closeWidth, height: h)
        let labelSize = titleLabel.intrinsicContentSize
        let textEnd = max(10, bounds.width - Self.closeWidth - 10)
        let badgeW = badgeWidth(available: textEnd - 10)
        let badgeH = min(h, Self.badgeMaxHeight)
        followButton.frame = NSRect(x: textEnd - badgeW, y: (h - badgeH) / 2, width: badgeW, height: badgeH)
        // Everything else lives left of the badge.
        let contentEnd = max(10, followButton.frame.minX - Self.gap)
        guard isRemote else {
            // The hint keeps its width unless the pane is very narrow; the title gives way to it.
            var start: CGFloat = 10
            var available = contentEnd - 10
            if chipShown {
                if available >= chipWidth + Self.gap + 40 {
                    stagedChip.frame = NSRect(x: start, y: (h - Self.badgeMaxHeight) / 2 + 1, width: chipWidth, height: min(h, Self.badgeMaxHeight))
                    start += chipWidth + Self.gap
                    available -= chipWidth + Self.gap
                } else {
                    chipShown = false
                }
            }
            setChipHidden(!chipShown)
            let hintW = mirrorHint.isHidden ? 0 : min(mirrorHint.intrinsicContentSize.width, available * 0.6)
            let gap = mirrorHint.isHidden ? 0 : Self.gap
            mirrorHint.frame = NSRect(x: start + available - hintW, y: (h - labelSize.height) / 2, width: hintW, height: labelSize.height)
            titleLabel.frame = NSRect(x: start, y: (h - labelSize.height) / 2, width: max(0, available - hintW - gap), height: labelSize.height)
            return
        }
        // The environment is laid out first, at its full width; then the title; the mirror hint gets only
        // what the title does not need.
        let envSize = fitEnvironmentLabel(width: contentEnd - 10, height: h)
        environmentLabel.frame = NSRect(x: 10, y: (h - envSize.height) / 2, width: envSize.width, height: envSize.height)
        var restStart = 10 + envSize.width + Self.gap
        var rest = max(0, contentEnd - restStart)
        // The chip only takes room the token does not need, and only while some is left for the title too.
        if chipShown {
            if rest >= chipWidth + Self.gap + 24 {
                stagedChip.frame = NSRect(x: restStart, y: (h - Self.badgeMaxHeight) / 2 + 1, width: chipWidth, height: min(h, Self.badgeMaxHeight))
                restStart += chipWidth + Self.gap
                rest -= chipWidth + Self.gap
            } else {
                chipShown = false
            }
        }
        setChipHidden(!chipShown)
        var hintW: CGFloat = 0
        if !mirrorHint.isHidden {
            hintW = min(mirrorHint.intrinsicContentSize.width, max(0, rest - labelSize.width - Self.gap))
            if hintW < 16 { hintW = 0 }
        }
        let gap = hintW > 0 ? Self.gap : 0
        let y = (h - labelSize.height) / 2
        titleLabel.frame = NSRect(x: restStart, y: y, width: max(0, rest - hintW - gap), height: labelSize.height)
        mirrorHint.frame = NSRect(x: contentEnd - hintW, y: y, width: hintW, height: labelSize.height)
    }

    /// The badge's text, colour and description. A pill filled with the model's colour, dark text on it.
    private func applyBadge(_ follow: FollowModel?) {
        let text = follow?.badgeText ?? FollowModel.notSharedText
        let color = follow?.badgeColor ?? Theme.fgMuted
        let description = follow?.badgeDescription ?? FollowModel.notSharedDescription
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        followButton.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.bg,
            .paragraphStyle: paragraph,
        ])
        followButton.layer?.backgroundColor = color.cgColor
        followButton.toolTip = description
        followButton.setAccessibilityLabel("Follow: \(text). \(description)")
    }

    /// How wide the badge is: what its text wants (at least `FollowModel.badgeMinWidth`, at most
    /// `badgeMaxWidth`), squeezed when the pane is narrow. A remote header's token is never cut, so the
    /// badge may shrink to `badgeFloorWidth` to leave the token its smallest size; it never vanishes.
    private func badgeWidth(available: CGFloat) -> CGFloat {
        let wanted = followButton.attributedTitle.size().width + Self.badgePadding
        var width = min(Self.badgeMaxWidth, max(FollowModel.badgeMinWidth, wanted))
        if isRemote {
            // First the badge gives up room down to its minimum, so the token keeps its full size...
            let fullToken = tokenWidth(fontSize: 12)
            width = min(width, max(FollowModel.badgeMinWidth, available - fullToken - Self.gap))
            // ...then, only when even the smallest token would not fit, below it.
            let smallestToken = tokenWidth(fontSize: 6)
            width = min(width, available - smallestToken - Self.gap)
        }
        return max(Self.badgeFloorWidth, min(width, max(Self.badgeFloorWidth, available)))
    }

    /// The width the environment token takes at `fontSize` (bold), measured on a scratch label so the real
    /// one's font is only ever set by `fitEnvironmentLabel`.
    private func tokenWidth(fontSize: CGFloat) -> CGFloat {
        let scratch = NSTextField(labelWithString: environmentLabel.stringValue)
        scratch.lineBreakMode = environmentLabel.lineBreakMode
        scratch.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        return scratch.intrinsicContentSize.width
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
