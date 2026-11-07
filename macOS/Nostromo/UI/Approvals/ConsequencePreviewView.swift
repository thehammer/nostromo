import AppKit
import NostromoKit

// AP7: what an `rm` / `rmdir` / `mv` in the command would touch, drawn under the input on the
// approval card. Lines only: the view is not interactive (no first responder, no buttons, it takes no
// click), and its height is fixed when the card is built from the number of lines the targets need
// (`ApprovalPreviewText.reservedLineCount`, the worst case while targets can still grow), so counts arriving later change what is drawn and never
// the card's height or the place of any button. A line that does not fit the width has its path cut in the
// middle (counts and warnings stay); nothing wraps.

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
        let shown = Self.fit(all, into: reservedLines)
        guard shown != lines else { return }
        lines = shown
        setAccessibilityValue(lineTexts.joined(separator: "\n"))
        needsDisplay = true
    }

    /// `all` in `room` lines. When some must be cut, the last line left says how many, so nothing disappears silently.
    static func fit(_ all: [ApprovalPreviewText.Line], into room: Int) -> [ApprovalPreviewText.Line] {
        guard all.count > room else { return all }
        guard room > 0 else { return [] }
        let kept = all.prefix(room - 1)
        let cut = all.count - kept.count
        let note = ApprovalPreviewText.Line(spans: [.init(text: "and \(cut) more line\(cut == 1 ? "" : "s") not shown", style: .warning)])
        return Array(kept) + [note]
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

    /// What is drawn for `line` at `width` points: a long path is cut in the middle so the counts and the
    /// warnings stay.
    func fittedString(for line: ApprovalPreviewText.Line, width: CGFloat) -> NSAttributedString {
        let fitted = ApprovalPreviewText.fit(line, toWidth: width) { text in
            NSAttributedString(string: text, attributes: [.font: Self.font]).size().width
        }
        return attributedString(for: fitted)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, line) in lines.enumerated() {
            let rect = NSRect(x: 0, y: CGFloat(i) * Self.lineHeight, width: bounds.width, height: Self.lineHeight)
            fittedString(for: line, width: bounds.width).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
