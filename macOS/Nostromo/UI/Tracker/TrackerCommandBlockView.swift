import AppKit
import NostromoKit

/// A staged command, display-only by requirement: monospaced text exactly as staged, an environment
/// badge, a line count for a multi-line command, **Copy** and a **Ran it** checkbox. Nothing here
/// runs, sends or types anything: the person copies the text and pastes it themselves. There is no
/// Run, Send, Execute or Open-in-shell element, no context-menu item that does any of those, and no
/// key equivalent.
///
/// The command is untrusted text (the daemon refuses hostile text, the Mac does not rely on it):
/// what is drawn, and what Copy puts on the pasteboard, is `TrackerCommandText.displayed(_:)`.
/// Lines never wrap: the text scrolls sideways inside the block, and the block stops growing after
/// `maxVisibleLines` (it then scrolls up and down inside itself).
final class TrackerCommandBlockView: NSView {
    override var isFlipped: Bool { true }

    static let pad: CGFloat = 6
    static let headerHeight: CGFloat = 20
    static let maxVisibleLines = 12
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// The text as drawn, and as Copy copies it.
    let displayedText: String
    let env: TrackerEnvWire?
    let isHazard: Bool
    /// `PROD`, `CANADA`, ... (nil when this block does not draw the badge or the environment is unknown).
    let envBadgeText: String?
    /// "3 lines" for a multi-line command.
    let lineBadgeText: String?
    private(set) var isRan: Bool

    /// Fired by the Ran it checkbox; the owner sends the pane's Tick. The checkbox never flips by itself:
    /// it shows what the board says. Fires only for a person's own click (`HumanGesture.permit`): input
    /// from app-control, an Accessibility press or a stale event is refused, says so on the block
    /// (`noticeText`) and sends nothing.
    var onRanIt: (() -> Void)?

    /// The gate the Ran it checkbox asks first. Tests replace it; the live one is `HumanGesture.permit`
    /// on the current event, exactly like the staging and Merge controls.
    typealias Permit = (NSView) -> HumanGestureVerdict
    var permit: Permit = { HumanGesture.permit(NSApp?.currentEvent, control: $0) }

    /// Why the last Ran it press did nothing ("Not ticked: click it yourself"), nil after a person's click.
    private(set) var noticeText: String?
    private(set) var noticeLabel: NSTextField?

    /// The command is longer than the block shows (`TrackerCommandText.maxScalars`): what is drawn is a
    /// cut, so Copy is off rather than put half a command on the clipboard.
    let isCut: Bool

    private let pasteboard: NSPasteboard
    private let lineCount: Int
    private let scroll = NSScrollView()
    private let textView = NSTextView(frame: .zero)
    private let edge = NSView()
    private(set) var copyButton: NSButton!
    private(set) var ranItCheckbox: NSButton!
    private(set) var envBadge: NSTextField?
    private(set) var lineBadge: NSTextField?
    private(set) var cutBadge: NSTextField?

    /// - Parameters:
    ///   - showsEnvBadge: a row that already draws the environment badge in its own right column passes false.
    init(command: String, env: TrackerEnvWire?, ran: Bool, canMarkRan: Bool, showsEnvBadge: Bool = true,
         pasteboard: NSPasteboard = .general) {
        let shown = TrackerCommandText.displayed(command)
        self.displayedText = shown
        self.isCut = TrackerCommandText.wasCut(command)
        self.env = env
        self.isHazard = env.map(TrackerEnvBadge.isHazard) ?? false
        self.envBadgeText = showsEnvBadge ? env.flatMap(TrackerEnvBadge.text) : nil
        self.lineBadgeText = TrackerCommandText.lineBadge(shown)
        self.lineCount = shown.split(separator: "\n", omittingEmptySubsequences: false).count
        self.isRan = ran
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
        build(canMarkRan: canMarkRan)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    // MARK: - Actions

    /// Copy puts exactly the displayed string on the pasteboard, as plain text only.
    @objc func copyPressed(_ sender: Any?) {
        guard !isCut else { return }
        pasteboard.clearContents()
        pasteboard.setString(displayedText, forType: .string)
    }

    @objc func ranItPressed(_ sender: NSButton) {
        // No optimistic display: the checkbox goes back to what the board says until the board changes.
        sender.state = isRan ? .on : .off
        guard case .human = permit(sender) else {
            showNotice(isRan ? "Not unticked: click it yourself" : "Not ticked: click it yourself")
            return
        }
        showNotice(nil)
        onRanIt?()
    }

    private func showNotice(_ text: String?) {
        noticeText = text
        noticeLabel?.stringValue = text ?? ""
        noticeLabel?.isHidden = text == nil
        noticeLabel?.setAccessibilityLabel(text.map { "\($0). The tick must come from you, not from another program." })
        needsLayout = true
    }

    // MARK: - Build

    private func build(canMarkRan: Bool) {
        if isHazard {
            edge.wantsLayer = true
            edge.layer?.backgroundColor = TrackerTheme.hazard.cgColor
            addSubview(edge)
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textColor = TrackerTheme.text
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = displayedText
        textView.setAccessibilityLabel("Staged command")
        textView.setAccessibilityRole(.textArea)
        // Right-click offers the system's own Copy/Select All only: never an item of ours.
        textView.menu = Self.copyOnlyMenu()

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = lineCount > Self.maxVisibleLines
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        addSubview(scroll)

        if let text = lineBadgeText {
            lineBadge = badge(text, hazard: false)
            lineBadge?.setAccessibilityLabel(text)
        }
        if let text = envBadgeText {
            // The words carry the meaning; the glyph and the red say "careful" without relying on colour alone.
            let shown = isHazard ? "\u{26A0}\u{FE0E} \(text)" : text
            envBadge = badge(shown, hazard: isHazard)
            envBadge?.setAccessibilityLabel("Environment: \(text)")
        }

        if isCut {
            let cut = badge("CUT", hazard: true)
            cut.setAccessibilityLabel("Command shown cut: it is longer than the block can show, so it cannot be copied")
            cut.toolTip = "Longer than this block shows: not copied."
            cutBadge = cut
        }
        let notice = NSTextField(labelWithString: "")
        notice.font = TrackerTheme.metaFont
        notice.textColor = Theme.amber
        notice.lineBreakMode = .byTruncatingTail
        notice.refusesFirstResponder = true
        notice.isHidden = true
        addSubview(notice)
        noticeLabel = notice

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyPressed(_:)))
        copy.isBordered = false
        copy.refusesFirstResponder = true
        copy.attributedTitle = NSAttributedString(string: "Copy", attributes: [
            .font: TrackerTheme.metaFont, .foregroundColor: Theme.cornflower])
        copy.setAccessibilityLabel("Copy command")
        copy.setAccessibilityHelp(isCut
            ? "Off: the command is longer than the block shows."
            : "Copies the command to the clipboard so you can paste it yourself.")
        copy.isEnabled = !isCut
        addSubview(copy)
        copyButton = copy

        let ran = NSButton(checkboxWithTitle: "Ran it", target: self, action: #selector(ranItPressed(_:)))
        ran.refusesFirstResponder = true
        ran.attributedTitle = NSAttributedString(string: "Ran it", attributes: [
            .font: TrackerTheme.metaFont, .foregroundColor: TrackerTheme.muted])
        ran.state = isRan ? .on : .off
        ran.isEnabled = canMarkRan
        // One click on a ticked box takes the tick back at once, so the ticked state says so: a command
        // that already ran must not look unrun by accident.
        if isRan {
            ran.toolTip = "Mark not run"
            ran.setAccessibilityLabel("Ran it, ticked")
            ran.setAccessibilityHelp("Click to mark not run. The command will show as not run, and nothing is undone on the terminal.")
        } else {
            ran.toolTip = "Tick after you have run it yourself"
            ran.setAccessibilityLabel("Ran it, not ticked")
            ran.setAccessibilityHelp("Tick this after you have done it yourself.")
        }
        addSubview(ran)
        ranItCheckbox = ran
    }

    private func badge(_ text: String, hazard: Bool) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = hazard ? TrackerTheme.hazard : TrackerTheme.muted
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.refusesFirstResponder = true
        label.wantsLayer = true
        label.layer?.backgroundColor = (hazard ? TrackerTheme.hazardFill : TrackerTheme.badgeFill).cgColor
        label.layer?.cornerRadius = 3
        addSubview(label)
        return label
    }

    private static func copyOnlyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: ""))
        return menu
    }

    // MARK: - Layout

    private var visibleLines: Int { min(lineCount, Self.maxVisibleLines) }
    private var lineHeight: CGFloat { ceil(Self.font.ascender - Self.font.descender + Self.font.leading) }
    private var textHeight: CGFloat { CGFloat(visibleLines) * lineHeight }

    /// The block's height at `width`: a header line, then the visible lines. Independent of the width.
    func height(forWidth width: CGFloat) -> CGFloat {
        Self.pad + Self.headerHeight + 2 + textHeight + Self.pad
    }

    private func badgeWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.intrinsicContentSize.width) + 8
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let pad = Self.pad
        edge.frame = NSRect(x: 0, y: 0, width: 3, height: bounds.height)
        var x = pad + (isHazard ? 3 : 0)
        for label in [envBadge, lineBadge, cutBadge].compactMap({ $0 }) {
            let bw = badgeWidth(label)
            label.frame = NSRect(x: x, y: pad + 2, width: bw, height: 15)
            x += bw + 4
        }
        var right = w - pad
        let ranWidth = ceil(ranItCheckbox.intrinsicContentSize.width)
        ranItCheckbox.frame = NSRect(x: right - ranWidth, y: pad, width: ranWidth, height: Self.headerHeight)
        right -= ranWidth + 8
        let copyWidth = ceil(copyButton.intrinsicContentSize.width)
        copyButton.frame = NSRect(x: right - copyWidth, y: pad, width: copyWidth, height: Self.headerHeight)
        if let noticeLabel {
            let room = max(right - copyWidth - 8 - x, 0)
            noticeLabel.frame = NSRect(x: x, y: pad + 2, width: room, height: 15)
        }

        let textX = pad + (isHazard ? 3 : 0)
        let area = NSRect(x: textX, y: pad + Self.headerHeight + 2,
                          width: max(w - textX - pad, 1), height: textHeight)
        scroll.frame = area
        let natural = ceil(displayedText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { ($0.replacingOccurrences(of: "\t", with: "        ") as NSString).size(withAttributes: [.font: Self.font]).width }
            .max() ?? 0)
        textView.frame = NSRect(x: 0, y: 0, width: max(natural + 2, area.width),
                                height: max(CGFloat(lineCount) * lineHeight, area.height))
    }
}
