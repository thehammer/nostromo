import AppKit
import NostromoKit

// AP7: what an `rm` / `rmdir` / `mv` in the command would touch, drawn under the input on the
// approval card. Lines only: the view is not interactive (no first responder, no buttons, it takes no
// click), and its height is fixed when the card is built from the number of lines the targets need
// (`ApprovalPreviewText.reservedLineCount`), so counts arriving later change what is drawn and never
// the card's height or the place of any button. A line that does not fit the width is cut with `…`;
// nothing wraps.

final class ConsequencePreviewView: NSView {

    static let lineHeight: CGFloat = 14
    static let font = NSFont.systemFont(ofSize: 11)

    /// The room this view takes, in lines. Never changes.
    let reservedLines: Int

    private(set) var lines: [ApprovalPreviewText.Line] = []

    init(reservedLines: Int) {
        self.reservedLines = max(0, reservedLines)
        super.init(frame: .zero)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("What this command would touch")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The height `reservedLines` lines take.
    var reservedHeight: CGFloat { CGFloat(reservedLines) * Self.lineHeight }

    // Layout is top-down, like the card.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Show `preview`. Changes what is drawn, never the frame.
    func setPreview(_ preview: ApprovalPreview?, cwd: String?, home: String?) {
        let all = preview.map { ApprovalPreviewText.lines(for: $0, cwd: cwd, home: home) } ?? []
        let shown = Array(all.prefix(reservedLines))
        guard shown != lines else { return }
        lines = shown
        setAccessibilityValue(lineTexts.joined(separator: "\n"))
        needsDisplay = true
    }

    /// The text of the lines shown (`approvals list` reports it).
    var lineTexts: [String] { lines.map(\.text) }

    /// Which lines carry a warning-coloured span.
    var warningLines: [Bool] { lines.map(\.hasWarning) }

    static func color(for style: ApprovalPreviewText.Style) -> NSColor {
        switch style {
        case .normal: return ApprovalPalette.commandText
        case .warning: return ApprovalPalette.warning
        case .muted: return ApprovalPalette.mutedText
        }
    }

    func attributedString(for line: ApprovalPreviewText.Line) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        for span in line.spans {
            out.append(NSAttributedString(string: span.text, attributes: [
                .font: Self.font, .foregroundColor: Self.color(for: span.style), .paragraphStyle: paragraph,
            ]))
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, line) in lines.enumerated() {
            let rect = NSRect(x: 0, y: CGFloat(i) * Self.lineHeight, width: bounds.width, height: Self.lineHeight)
            attributedString(for: line).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
