import AppKit
import NostromoKit

/// The one line under the "Waiting on you" strip for background work: `◷ 2 running in the
/// background`, built from BA's chip state (`TrackerBackgroundSummary`), so the numbers are the
/// input-bar chip's. It lists no tasks and writes nothing to the board. A click opens the focus's
/// Background activity popover; with no REPL pane to open it from, the row is disabled.
final class TrackerBackgroundRow: NSView {
    override var isFlipped: Bool { true }

    static let height: CGFloat = 22

    /// A click on the row while it is enabled.
    var onClick: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private(set) var summary = TrackerBackgroundSummary(chip: .hidden)
    private(set) var isEnabled = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.badgeFill.cgColor
        label.font = TrackerTheme.metaFont
        label.textColor = TrackerTheme.text
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.refusesFirstResponder = true
        addSubview(label)
        setAccessibilityRole(.button)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// What the row reads (empty when hidden).
    var text: String { label.stringValue }

    /// 0 while the chip is hidden.
    var preferredHeight: CGFloat { summary.isHidden ? 0 : Self.height }

    func update(_ summary: TrackerBackgroundSummary, enabled: Bool) {
        guard summary != self.summary || enabled != isEnabled else { return }
        self.summary = summary
        isEnabled = enabled
        label.stringValue = summary.text ?? ""
        label.textColor = enabled ? TrackerTheme.text : TrackerTheme.muted
        toolTip = enabled ? nil : "Background activity isn't available here"
        setAccessibilityLabel(summary.accessibilityLabel)
        setAccessibilityEnabled(enabled)
        isHidden = summary.isHidden
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: TrackerRowView.hPad, y: 3, width: max(bounds.width - TrackerRowView.hPad * 2, 1), height: 16)
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !summary.isHidden else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !summary.isHidden else { return false }
        onClick?()
        return true
    }
}
