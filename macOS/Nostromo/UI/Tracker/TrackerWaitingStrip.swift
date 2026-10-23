import AppKit
import NostromoKit

/// The pinned "Waiting on you (N)" strip at the top of the tracker pane, outside its scroll view.
///
/// One line at a fixed height whatever N is (the entries are joined and truncated), and no height
/// at all when N is 0, so its height changes only when N crosses 0. The pane applies that change
/// above the scroll view's clip, keeping the clip's content where it was (`TrackerPaneView`).
/// Entries come from `TrackerPresentation.strip`, which T5 extends with more sources.
final class TrackerWaitingStrip: NSView {
    override var isFlipped: Bool { true }

    static let height: CGFloat = 26

    private let label = NSTextField(labelWithString: "")
    private(set) var strip = TrackerStrip(entries: [])

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = TrackerTheme.stripFill.cgColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.refusesFirstResponder = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    /// The height the strip wants: fixed while anything waits, 0 otherwise.
    var preferredHeight: CGFloat { strip.count > 0 ? Self.height : 0 }

    /// What the strip reads, as plain text.
    var text: String { label.stringValue }

    func update(_ strip: TrackerStrip) {
        guard strip != self.strip else { return }
        self.strip = strip
        let out = NSMutableAttributedString(string: strip.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: TrackerTheme.text])
        for (i, entry) in strip.entries.enumerated() {
            out.append(NSAttributedString(string: i == 0 ? ":  " : "  ·  ", attributes: [
                .font: TrackerTheme.metaFont, .foregroundColor: TrackerTheme.muted]))
            out.append(NSAttributedString(string: entry.text, attributes: [
                .font: TrackerTheme.metaFont, .foregroundColor: TrackerTheme.text]))
        }
        label.attributedStringValue = out
        label.toolTip = strip.entries.map { entry in
            entry.detail.map { "\(entry.text) (\($0))" } ?? entry.text
        }.joined(separator: "\n")
        isHidden = strip.count == 0
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: TrackerRowView.hPad, y: 5, width: max(bounds.width - TrackerRowView.hPad * 2, 1), height: 16)
    }
}
