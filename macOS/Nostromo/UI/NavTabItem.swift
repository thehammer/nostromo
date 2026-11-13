import AppKit
import NostromoKit

// MARK: - NavRowHighlight

/// How a focus row is marked: the fill behind it and the 3 pt bars down its leading edge (left to right).
/// Two independent inputs: the focus is the active one (cornflower), an agent is blocked on the operator
/// (red). Active-and-blocked is its own look: the active cornflower bar stays first with the red bar
/// beside it, and the red fill wins, so neither fact hides the other. Bars overlay the row's leading
/// inset; they never move text or change the row's height.
struct NavRowHighlight: Equatable {
    var fill: NSColor?
    var bars: [NSColor]

    static func style(isActive: Bool, isBlocking: Bool) -> NavRowHighlight {
        switch (isActive, isBlocking) {
        case (false, false): return NavRowHighlight(fill: nil, bars: [])
        case (true, false): return NavRowHighlight(fill: Theme.cornflower.withAlphaComponent(0.12), bars: [Theme.cornflower])
        case (false, true): return NavRowHighlight(fill: Theme.blockingRowFill, bars: [Theme.needsYouNow])
        case (true, true): return NavRowHighlight(fill: Theme.blockingRowFill, bars: [Theme.cornflower, Theme.needsYouNow])
        }
    }
}

// MARK: - NeedsYouPillView

/// One of the two "needs you" pills on a row's second line: a glyph and a count. Blocking is red with a
/// hand (stopped, needs your yes); waiting is outlined amber with a list. The glyph is what tells them
/// apart without colour. The waiting pill can collapse to glyph and count with no padding or outline.
private final class NeedsYouPillView: NSView {
    enum Kind { case blocking, waiting }

    static let height: CGFloat = 14
    private static let padding: CGFloat = 5
    private static let glyphWidth: CGFloat = 10
    private static let glyphGap: CGFloat = 2
    private static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

    let kind: Kind
    private let glyph = NSImageView()
    private let count = NSTextField(labelWithString: "")
    private(set) var text = ""
    private(set) var isCollapsed = false
    private var configured = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        let symbol = kind == .blocking ? "hand.raised.fill" : "list.bullet"
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        glyph.imageScaling = .scaleProportionallyDown
        glyph.contentTintColor = kind == .blocking ? .white : Theme.waitingPillText
        count.font = Self.font
        count.textColor = kind == .blocking ? .white : Theme.waitingPillText
        count.alignment = .left
        addSubview(glyph)
        addSubview(count)
        setAccessibilityElement(false)
        apply(text: "", collapsed: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Set the count and whether the pill is collapsed (waiting only). Does not resize the view.
    func apply(text: String, collapsed: Bool) {
        let collapsed = collapsed && kind == .waiting
        guard !configured || text != self.text || collapsed != isCollapsed else { return }
        configured = true
        self.text = text
        isCollapsed = collapsed
        count.stringValue = text
        if kind == .blocking {
            layer?.backgroundColor = Theme.needsYouNow.cgColor
            layer?.borderWidth = 0
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = isCollapsed ? 0 : 1
            layer?.borderColor = Theme.waitingPillText.withAlphaComponent(0.6).cgColor
        }
        needsLayout = true
    }

    /// The width this pill takes for `text`, with padding (full) or without (collapsed).
    static func width(of text: String, collapsed: Bool) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return glyphWidth + glyphGap + textWidth + (collapsed ? 0 : 2 * padding)
    }

    override func layout() {
        super.layout()
        let inset = isCollapsed ? 0 : Self.padding
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
        glyph.frame = NSRect(x: inset, y: (bounds.height - 10) / 2, width: Self.glyphWidth, height: 10)
        let size = count.intrinsicContentSize
        count.frame = NSRect(x: inset + Self.glyphWidth + Self.glyphGap, y: (bounds.height - size.height) / 2,
                             width: textWidth, height: size.height)
    }
}

// MARK: - NeedsYouPillFit

/// What the second line gives up, in order, as the row narrows: first the branch text (to nothing),
/// then the waiting pill's padding (glyph and count only), never the blocking pill.
struct NeedsYouPillFit: Equatable {
    var slotWidth: CGFloat
    var branchVisible: Bool
    var waitingCollapsed: Bool

    static let pillGap: CGFloat = 3
    static let branchGap: CGFloat = 4
    static let minBranchWidth: CGFloat = 16

    /// `blocking` and `waiting` are the pills' widths (0 when absent), `waitingCollapsed` the waiting
    /// pill's width without padding; `available` is the row's width from the branch text's leading edge
    /// to the pills' trailing edge.
    static func make(blocking: CGFloat, waiting: CGFloat, waitingCollapsed: CGFloat, available: CGFloat) -> NeedsYouPillFit {
        func total(_ w: CGFloat) -> CGFloat {
            blocking + w + (blocking > 0 && w > 0 ? pillGap : 0)
        }
        let full = total(waiting)
        guard full > 0 else { return NeedsYouPillFit(slotWidth: 0, branchVisible: true, waitingCollapsed: false) }
        if full > available {
            return NeedsYouPillFit(slotWidth: min(total(waitingCollapsed), max(available, blocking)),
                                   branchVisible: false, waitingCollapsed: true)
        }
        return NeedsYouPillFit(slotWidth: full,
                               branchVisible: available - full - branchGap >= minBranchWidth, waitingCollapsed: false)
    }
}

// MARK: - FocusActivityMarkView

/// The quiet mark at the leading edge of a focus row: a hollow ring (activity since the operator looked), a
/// filled dot (unread responses), or a filled amber dot with a "!" cut out (a problem). Always the same 8 pt
/// square in the same place, shown or hidden, so a mark appearing moves nothing. No animation. The shapes
/// differ, so the state never rests on colour alone. Not an accessibility element: the row says it.
private final class FocusActivityMarkView: NSView {
    static let size: CGFloat = 8
    private static let ringWidth: CGFloat = 1.5

    /// The "!" of the problem dot, cut out in `Theme.focusMarkGlyph`.
    let glyph = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        layer?.addSublayer(glyph)
        glyph.frame = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: 3.25, y: 3.8, width: 1.5, height: 2.7), cornerWidth: 0.6, cornerHeight: 0.6)
        path.addEllipse(in: CGRect(x: 3.25, y: 1.5, width: 1.5, height: 1.5))
        glyph.path = path
        glyph.fillColor = Theme.focusMarkGlyph.cgColor
        glyph.isHidden = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: FocusActivityState) {
        isHidden = state == .none
        toolTip = state.toolTip
        guard let layer else { return }
        switch state {
        case .none:
            break
        case .activity:
            layer.backgroundColor = NSColor.clear.cgColor
            layer.borderColor = Theme.focusMark.cgColor
            layer.borderWidth = Self.ringWidth
            glyph.isHidden = true
        case .unread:
            layer.backgroundColor = Theme.focusMark.cgColor
            layer.borderWidth = 0
            glyph.isHidden = true
        case .problem:
            layer.backgroundColor = Theme.focusMarkProblem.cgColor
            layer.borderWidth = 0
            glyph.fillColor = Theme.focusMarkGlyph.cgColor
            glyph.isHidden = false
        }
    }
}

// MARK: - NavTabItem

/// One focus row in the sidebar. Internal (not private) only so a logic test can lay it out.
class NavTabItem: NSView, NSGestureRecognizerDelegate {

    let focus: Focus
    var onTap: (() -> Void)?
    /// Click on the count pill. Falls back to `onTap` when unset.
    var onBadgeTap: (() -> Void)?

    /// Pill text currently shown (nil when hidden). Exposed for tests.
    var pillText: String? { pillBox.isHidden ? nil : pillLabel.stringValue }
    /// The "needs you" counts on the second line: blocking (red, hand) and waiting (amber, list).
    /// Exposed for tests and `approvals badges`.
    private(set) var blocking = 0
    private(set) var waiting = 0
    var blockingPillText: String? { blocking > 0 ? Self.countText(blocking) : nil }
    var waitingPillText: String? { waiting > 0 ? Self.countText(waiting) : nil }
    /// An agent is blocked on the operator: the row carries the red highlight.
    var showsBlockingHighlight: Bool { blocking > 0 }
    var highlight: NavRowHighlight { .style(isActive: isActive, isBlocking: blocking > 0) }
    /// Frames in this view's coordinates (nil when hidden), and what the second line has given up.
    var blockingPillFrame: NSRect? { blocking > 0 && !pillSlot.isHidden ? pillSlot.convert(blockingPill.frame, to: self) : nil }
    var waitingPillFrame: NSRect? { waiting > 0 && !pillSlot.isHidden ? pillSlot.convert(waitingPill.frame, to: self) : nil }
    var secondaryFrame: NSRect? { secondaryLabel?.frame }
    /// What `updateAppearance` actually drew: the row's layer fill, each leading bar (hidden, colour) and
    /// the waiting pill's outline (nil when it has none). Exposed for tests.
    var drawnFill: CGColor? { layer?.backgroundColor }
    var drawnBars: [(isHidden: Bool, color: CGColor?)] { bars.map { ($0.isHidden, $0.layer?.backgroundColor) } }
    var waitingPillOutline: CGColor? { (waitingPill.layer?.borderWidth ?? 0) > 0 ? waitingPill.layer?.borderColor : nil }
    var secondaryVisible: Bool { secondaryLabel.map { !$0.isHidden } ?? false }
    var waitingPillIsCollapsed: Bool { waiting > 0 && waitingPill.isCollapsed }
    var blockingPillToolTip: String? { blockingPill.toolTip }
    var waitingPillToolTip: String? { waitingPill.toolTip }
    /// Clicks on the blocking and waiting pills; each falls back to `onTap` when unset.
    var onBlockingPillTap: (() -> Void)?
    var onWaitingPillTap: (() -> Void)?
    /// Second-line text currently shown. Exposed for tests.
    var secondaryText: String? { secondaryLabel?.stringValue }

    // MARK: Focus activity mark (exposed for tests)

    /// How much further right the name and the second line sit than the leading bars' inset alone would
    /// put them, to make room for the activity mark's reserved slot. Constant for every row.
    static let activitySlotWidth: CGFloat = 10
    /// Gap between the mark and the name.
    private static let activityMarkGap: CGFloat = 4

    /// What the mark says now.
    private(set) var activityState: FocusActivityState = .none
    /// The mark's fixed frame in this row's coordinates, whether or not a mark shows.
    var activitySlotFrame: NSRect { activityMark.frame }
    /// The mark's frame while one shows; `nil` when there is none.
    var activityMarkFrame: NSRect? { activityMark.isHidden ? nil : activityMark.frame }
    var activityToolTip: String? { activityMark.isHidden ? nil : activityMark.toolTip }
    var activityMarkIsAccessibilityElement: Bool { activityMark.isAccessibilityElement() }
    /// Where the name is laid out by its constraints (its alignment rect: the frame less the text field's own
    /// 2 pt side padding). The mark's slot is measured from this edge, so the 4 pt gap is to the text itself.
    var nameAlignmentFrame: NSRect { label.alignmentRect(forFrame: label.frame) }

    /// What the mark's layers actually draw; `nil` when no mark shows.
    struct DrawnActivityMark: Equatable {
        enum Shape: Equatable { case ring, dot, warningDot }
        var shape: Shape
        var fill: CGColor?
        var stroke: CGColor?
        var strokeWidth: CGFloat
        var glyph: CGColor?
        var size: CGSize
    }

    var drawnActivityMark: DrawnActivityMark? {
        guard !activityMark.isHidden, let layer = activityMark.layer else { return nil }
        let hasGlyph = !activityMark.glyph.isHidden
        let shape: DrawnActivityMark.Shape = hasGlyph ? .warningDot : (layer.borderWidth > 0 ? .ring : .dot)
        return DrawnActivityMark(shape: shape, fill: layer.backgroundColor, stroke: layer.borderColor,
                                 strokeWidth: layer.borderWidth, glyph: hasGlyph ? activityMark.glyph.fillColor : nil,
                                 size: activityMark.bounds.size)
    }

    // Test hooks (read-only geometry in this view's coordinates, and click simulation
    // that runs the same actions the gesture recognizers do). Used by logic tests only.
    var pillFrame: NSRect? { pillBox.isHidden ? nil : pillBox.frame }
    var attentionDotFrame: NSRect? { attentionDot.isHidden ? nil : attentionDot.frame }
    var labelFrame: NSRect { label.frame }
    func simulateRowClick() { tapped() }
    func simulatePillClick() { pillTapped() }
    func simulateBlockingPillClick() { blockingPillTapped() }
    func simulateWaitingPillClick() { waitingPillTapped() }

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    /// An outstanding request (e.g. a pending decision) is waiting on this focus.
    var needsAttention: Bool = false {
        didSet {
            attentionDot.isHidden = !needsAttention
            labelClearsAttentionDot?.isActive = needsAttention
            pillClearsAttentionDot?.isActive = needsAttention
            pillAtEdge?.isActive = !needsAttention
            updateBadgeReserve()
        }
    }

    /// Environments of the remote shells open in this focus (uppercased, production first): one red
    /// badge each, next to the label.
    var environments: [String] = [] {
        didSet {
            guard environments != oldValue else { return }
            badgeBoxes.forEach { $0.removeFromSuperview() }
            badgeBoxes = environments.map(Self.makeEnvironmentBadge)
            var x: CGFloat = 0
            for box in badgeBoxes {
                box.frame.origin = NSPoint(x: x, y: 0)
                badgeClip.addSubview(box)
                x += box.frame.width + Self.badgeSpacing
            }
            badgesWidth = max(0, x - Self.badgeSpacing)
            badgeClip.isHidden = environments.isEmpty
            updateBadgeReserve()
            needsLayout = true
        }
    }
    /// The badge texts shown. Exposed for tests.
    var environmentBadgeTexts: [String] { environments }

    var sweaterColor: NSColor? = nil {
        didSet { updateAppearance() }
    }

    /// The badges sit in a box that clips them, placed by hand in `layout()` from where the label, the
    /// count pill and the dots actually are: no constraint ties them to anything, so no layout can have a
    /// conflict to break. Only the label yields (a soft constraint at priority 800, above the label's own
    /// resistance to being squeezed), down to 40 pt of its text (900); then the last badge is cut off.
    private let badgeClip = NSView()
    private var badgeBoxes: [NSView] = []
    private var badgesWidth: CGFloat = 0
    private var labelYieldsToBadges: NSLayoutConstraint?
    private var labelKeepsItsName: NSLayoutConstraint?
    private static let pillTrailing: CGFloat = 8
    /// Between the second-line text and the pills.
    private static let branchGap: CGFloat = NeedsYouPillFit.branchGap
    private static let badgeSpacing: CGFloat = 3
    private static let badgeHeight: CGFloat = 14
    /// The leading highlight bars (3 pt each, at x = 0 and 3): see `NavRowHighlight`.
    private let bars           = [NSView(), NSView()]
    /// The blocking and waiting pills sit in this slot, right-aligned on the second line. They are placed
    /// by hand in `layout()`; only the second-line text yields to them (`secondaryClearsPills`).
    private let pillSlot       = NSView()
    private let blockingPill   = NeedsYouPillView(kind: .blocking)
    private let waitingPill    = NeedsYouPillView(kind: .waiting)
    private var secondaryClearsPills: NSLayoutConstraint?
    private var pillSlotWidth: CGFloat = 0
    private let secondaryLeading: CGFloat
    private let label          = NSTextField(labelWithString: "")
    private let dot            = NSView()
    private let attentionDot   = NSView()
    private let activityMark   = FocusActivityMarkView(frame: .zero)
    /// The badge's spoken label (with its attention suffix), kept so the activity phrase can be composed on.
    private var badgeAccessibilityText: String?
    /// Keeps the primary label's text out from under the attention dot. Active only
    /// while the dot is shown; it only narrows the label's trailing edge, so it never
    /// changes the row's height or the label's single-line truncation.
    private var labelClearsAttentionDot: NSLayoutConstraint?
    private let pillBox        = NSView()
    private let pillLabel      = NSTextField(labelWithString: "")
    /// The pill sits at the trailing edge, or left of the attention dot while it shows.
    private var pillAtEdge: NSLayoutConstraint?
    private var pillClearsAttentionDot: NSLayoutConstraint?
    /// Keeps the title out from under the pill; active only while the pill shows.
    private var labelClearsPill: NSLayoutConstraint?
    /// The row's text. Renaming it in place re-measures the width the label keeps (`labelKeepsItsName`).
    var displayOverride: String {
        didSet {
            guard displayOverride != oldValue else { return }
            updateKeptNameWidth()
            updateAppearance()
            updateAccessibility()
        }
    }
    /// Top-level rows (not nested under a repo header) use the repo-header look.
    private let isTopLevel: Bool
    private let baseSecondary: String?
    private let secondaryLabel: NSTextField?

    init(focus: Focus, label displayLabel: String, secondary: String?, indented: Bool) {
        self.focus           = focus
        self.secondaryLeading = 3 + (indented ? 6 + Theme.navChildIndent : 6) + NavTabItem.activitySlotWidth
        self.displayOverride = displayLabel
        self.baseSecondary   = secondary
        self.isTopLevel      = !indented
        self.secondaryLabel  = secondary.map { text in
            let tf = NSTextField(labelWithString: text)
            tf.font           = Theme.navSubFont
            tf.textColor      = Theme.fgMuted
            tf.alignment      = .left
            tf.lineBreakMode  = .byTruncatingTail
            tf.maximumNumberOfLines = 1
            tf.translatesAutoresizingMaskIntoConstraints = false
            return tf
        }
        super.init(frame: .zero)
        wantsLayer = true

        // The name and the second line start after the bars' inset and the activity mark's reserved slot.
        let leadingInset: CGFloat = (indented ? 6 + Theme.navChildIndent : 6) + NavTabItem.activitySlotWidth

        // Leading highlight bars — 3px, full height; the first is at the edge, the second beside it.
        for (index, bar) in bars.enumerated() {
            bar.wantsLayer = true
            bar.isHidden = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(index) * 3),
                bar.topAnchor.constraint(equalTo: topAnchor),
                bar.bottomAnchor.constraint(equalTo: bottomAnchor),
                bar.widthAnchor.constraint(equalToConstant: 3),
            ])
        }
        let accentBar = bars[0]

        // Primary label — left-aligned
        label.stringValue    = displayLabel
        label.font           = indented ? Theme.tabFont : Theme.navRepoFont
        label.textColor      = indented ? Theme.fgMuted : Theme.navRepoColor
        label.alignment      = .left
        label.lineBreakMode  = .byTruncatingTail
        label.isEditable     = false
        label.isBordered     = false
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Sweater dot — 6px circle, right-aligned, hidden by default
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Attention dot — 8px, in the same trailing column as the sweater dot but
        // on the label's line, so it never shares a position with it. It only reserves
        // horizontal room (`labelClearsAttentionDot`, while shown), never vertical, so
        // showing or hiding it can never change the row's height.
        attentionDot.wantsLayer = true
        attentionDot.layer?.cornerRadius = 4
        attentionDot.layer?.backgroundColor = Theme.attention.cgColor
        attentionDot.isHidden = true
        attentionDot.translatesAutoresizingMaskIntoConstraints = false
        attentionDot.setAccessibilityElement(true)
        attentionDot.setAccessibilityRole(.image)
        attentionDot.setAccessibilityLabel("needs your attention")
        addSubview(attentionDot)
        NSLayoutConstraint.activate([
            attentionDot.widthAnchor.constraint(equalToConstant: 8),
            attentionDot.heightAnchor.constraint(equalToConstant: 8),
            attentionDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            attentionDot.centerYAnchor.constraint(equalTo: topAnchor, constant: 13),
        ])

        // Label constraints — different depending on whether secondary is shown
        if let sl = secondaryLabel {
            addSubview(sl)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: leadingInset),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
                label.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),

                sl.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: leadingInset),
                sl.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
                sl.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            ])
            // The second-line text yields to the pills; `layout()` sets how much (the slot's width).
            let clearsPills = sl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.pillTrailing - Self.branchGap)
            clearsPills.priority = NSLayoutConstraint.Priority(999)
            clearsPills.isActive = true
            sl.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
            secondaryClearsPills = clearsPills
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: leadingInset),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        labelClearsAttentionDot = label.trailingAnchor.constraint(lessThanOrEqualTo: attentionDot.leadingAnchor, constant: -4)
        labelClearsAttentionDot?.isActive = needsAttention

        // Activity mark: a fixed 8 pt square in the slot just left of the name, on the name's line. It only
        // ever shows or hides; its place and size never depend on the state, so nothing else moves.
        activityMark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityMark)
        NSLayoutConstraint.activate([
            activityMark.widthAnchor.constraint(equalToConstant: FocusActivityMarkView.size),
            activityMark.heightAnchor.constraint(equalToConstant: FocusActivityMarkView.size),
            activityMark.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -Self.activityMarkGap),
            activityMark.centerYAnchor.constraint(equalTo: label.centerYAnchor),
        ])

        // Count pill — text only, on the title line (same line as the attention dot, to its
        // left while that shows). Horizontal room only: it never changes the row's height.
        pillBox.wantsLayer = true
        pillBox.layer?.cornerRadius = 7
        pillBox.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.25).cgColor
        pillBox.isHidden = true
        pillBox.translatesAutoresizingMaskIntoConstraints = false
        pillLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        pillLabel.textColor = NSColor.white
        pillLabel.alignment = .center
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pillBox.addSubview(pillLabel)
        addSubview(pillBox)
        pillAtEdge = pillBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        pillClearsAttentionDot = pillBox.trailingAnchor.constraint(equalTo: attentionDot.leadingAnchor, constant: -4)
        pillAtEdge?.isActive = true
        NSLayoutConstraint.activate([
            pillBox.heightAnchor.constraint(equalToConstant: 14),
            pillBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),
            pillBox.centerYAnchor.constraint(equalTo: topAnchor, constant: 13),
            pillLabel.leadingAnchor.constraint(equalTo: pillBox.leadingAnchor, constant: 5),
            pillLabel.trailingAnchor.constraint(equalTo: pillBox.trailingAnchor, constant: -5),
            pillLabel.centerYAnchor.constraint(equalTo: pillBox.centerYAnchor),
        ])
        pillBox.setContentCompressionResistancePriority(.required, for: .horizontal)
        pillLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelClearsPill = label.trailingAnchor.constraint(lessThanOrEqualTo: pillBox.leadingAnchor, constant: -4)

        // Environment badges (hazard red) just after the label: see `badgeClip`. These two constraints are
        // soft (800 and 900) and active only while badges show; the required ones above are untouched.
        badgeClip.wantsLayer = true
        badgeClip.layer?.masksToBounds = true
        badgeClip.isHidden = true
        addSubview(badgeClip)
        let yields = label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -60)
        yields.priority = NSLayoutConstraint.Priority(800)
        labelYieldsToBadges = yields
        let keeps = label.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.keptNameWidth(displayLabel, font: label.font))
        keeps.priority = NSLayoutConstraint.Priority(900)
        labelKeepsItsName = keeps

        let rowClick = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        rowClick.delegate = self
        addGestureRecognizer(rowClick)
        pillBox.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillTapped)))

        // Blocking and waiting pills: on the second line only (rows always have one in the app).
        pillSlot.wantsLayer = true
        pillSlot.layer?.masksToBounds = true
        pillSlot.isHidden = true
        pillSlot.addSubview(blockingPill)
        pillSlot.addSubview(waitingPill)
        blockingPill.isHidden = true
        waitingPill.isHidden = true
        blockingPill.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(blockingPillTapped)))
        waitingPill.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(waitingPillTapped)))
        addSubview(pillSlot)

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func keptNameWidth(_ text: String, font: NSFont?) -> CGFloat {
        min(40, ceil((text as NSString).size(withAttributes: [.font: font as Any]).width))
    }

    private func updateKeptNameWidth() {
        labelKeepsItsName?.constant = Self.keptNameWidth(displayOverride, font: label.font)
    }

    /// How far from the trailing edge the label should stop to leave room for the badges: the sweater
    /// dot, the pill and the attention dot (each while it shows), a gap, the badges, a gap. Only the
    /// label's soft constraint reads it; where the badges really go is decided in `layout()`.
    private func updateBadgeReserve() {
        let showing = !environments.isEmpty
        labelYieldsToBadges?.isActive = showing
        labelKeepsItsName?.isActive = showing
        guard showing else { return }
        var column: CGFloat = 14
        if needsAttention { column = max(column, 15) }
        if !pillBox.isHidden {
            let pillWidth = max(14, pillLabel.intrinsicContentSize.width + 10)
            column = max(column, (needsAttention ? 19 : 8) + pillWidth)
        }
        labelYieldsToBadges?.constant = -(column + 4 + badgesWidth + 6)
    }

    override func layout() {
        fitNeedsYouPills()
        super.layout()
        placeNeedsYouPills()
        // The badges start after the label and end before the sweater dot, the pill and the attention
        // dot; what does not fit is cut off (the last badge first).
        guard !environments.isEmpty else { return }
        var limit = dot.frame.minX - 4
        if !pillBox.isHidden { limit = min(limit, pillBox.frame.minX - 4) }
        if !attentionDot.isHidden { limit = min(limit, attentionDot.frame.minX - 4) }
        let x = label.frame.maxX + 6
        let width = min(badgesWidth, limit - x)
        badgeClip.isHidden = width < 4
        badgeClip.frame = NSRect(x: x, y: label.frame.midY - Self.badgeHeight / 2, width: max(0, width), height: Self.badgeHeight)
    }

    private static func makeEnvironmentBadge(_ name: String) -> NSView {
        let text = NSTextField(labelWithString: name.uppercased())
        text.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        text.textColor = Theme.hazardText
        let size = text.intrinsicContentSize
        let box = NSView(frame: NSRect(x: 0, y: 0, width: ceil(size.width) + 8, height: badgeHeight))
        box.wantsLayer = true
        box.layer?.backgroundColor = Theme.hazardRed.cgColor
        box.layer?.cornerRadius = 3
        text.frame = NSRect(x: 4, y: (badgeHeight - size.height) / 2, width: ceil(size.width), height: size.height)
        box.addSubview(text)
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.staticText)
        box.setAccessibilityLabel("remote shell open: \(name)")
        return box
    }

    @objc private func tapped() { onTap?() }

    @objc private func pillTapped() { (onBadgeTap ?? onTap)?() }

    @objc private func blockingPillTapped() { (onBlockingPillTap ?? onTap)?() }

    @objc private func waitingPillTapped() { (onWaitingPillTap ?? onTap)?() }

    private static func countText(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }

    /// Decide, from the row's width, how much room the pills take and what the second line gives up.
    /// Only horizontal: it never touches the title line or the row's height.
    private func fitNeedsYouPills() {
        guard let clearsPills = secondaryClearsPills, let secondaryLabel else { return }
        let blockingText = blockingPillText ?? "", waitingText = waitingPillText ?? ""
        let fit = NeedsYouPillFit.make(
            blocking: NeedsYouPillView.width(of: blockingText, collapsed: false),
            waiting: NeedsYouPillView.width(of: waitingText, collapsed: false),
            waitingCollapsed: NeedsYouPillView.width(of: waitingText, collapsed: true),
            available: bounds.width - secondaryLeading - Self.pillTrailing)
        let reserve = fit.slotWidth > 0 ? -(Self.pillTrailing + fit.slotWidth + Self.branchGap) : -(Self.pillTrailing + Self.branchGap)
        if clearsPills.constant != reserve { clearsPills.constant = reserve }
        if secondaryLabel.isHidden == fit.branchVisible { secondaryLabel.isHidden = !fit.branchVisible }
        blockingPill.apply(text: blockingText, collapsed: false)
        waitingPill.apply(text: waitingText, collapsed: fit.waitingCollapsed)
        pillSlot.isHidden = fit.slotWidth == 0
        pillSlotWidth = fit.slotWidth
    }

    /// Put the slot on the second line, right-aligned, and the pills in it (blocking first, waiting after).
    private func placeNeedsYouPills() {
        guard let secondaryLabel, !pillSlot.isHidden else { return }
        let height = NeedsYouPillView.height
        // One point below the second line's centre, clear of the sweater dot on the row's middle.
        pillSlot.frame = NSRect(x: bounds.width - Self.pillTrailing - pillSlotWidth,
                                y: secondaryLabel.frame.midY - height / 2 - 1, width: pillSlotWidth, height: height)
        var x: CGFloat = 0
        for pill in [blockingPill, waitingPill] where !pill.isHidden {
            let width = NeedsYouPillView.width(of: pill.text, collapsed: pill.isCollapsed)
            pill.frame = NSRect(x: x, y: 0, width: width, height: height)
            x += width + NeedsYouPillFit.pillGap
        }
    }

    /// A click on the pill belongs to the pill's own recognizer, not the row's.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let pills = [pillBox.isHidden ? nil : pillBox.frame, blockingPillFrame, waitingPillFrame].compactMap { $0 }
        return !pills.contains { $0.contains(point) }
    }

    /// Apply a badge in place: pill text, the blocking and waiting pills, second line (Fred/Mother/Teri
    /// built-ins only) and accessibility label. `nil` clears them. Never changes the row's height.
    func setBadge(_ badge: FocusBadge?) {
        if let pill = badge?.pill {
            pillLabel.stringValue = pill
            pillBox.isHidden = false
            pillBox.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.25).cgColor
        } else {
            pillBox.isHidden = true
        }
        labelClearsPill?.isActive = !pillBox.isHidden
        updateBadgeReserve()
        applyNeedsYou(blocking: badge?.blocking ?? 0, waiting: badge?.waiting ?? 0)

        if focus.isBuiltIn, ["fred", "mother", "teri"].contains(focus.agentTag.lowercased()) {
            secondaryLabel?.stringValue = badge?.detail ?? baseSecondary ?? ""
        }

        if let badge {
            // `needsYouNow` adds nothing here: the blocking phrase is already in the label.
            let suffix = badge.level == .attention ? ", needs your attention" : ""
            badgeAccessibilityText = badge.accessibilityLabel + suffix
        } else {
            badgeAccessibilityText = nil
        }
        updateAccessibility()
    }

    /// Show `state` as the row's activity mark, in place. Never changes the row's size or what is where.
    func setActivity(_ state: FocusActivityState) {
        guard state != activityState else { return }
        activityState = state
        activityMark.apply(state)
        updateAccessibility()
    }

    /// The row's spoken label: the badge's phrases, then the activity phrase. A row with neither is not an
    /// accessibility element (its name is read from its label). The mark itself is never one.
    private func updateAccessibility() {
        let phrase = activityState.accessibilityPhrase
        let text: String?
        switch (badgeAccessibilityText, phrase) {
        case (nil, nil): text = nil
        case (let badge?, nil): text = badge
        case (let badge?, let phrase?) where !badge.isEmpty: text = badge + ", " + phrase
        case (_, let phrase?): text = displayOverride + ", " + phrase
        }
        if let text {
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(text)
        } else {
            setAccessibilityElement(false)
            setAccessibilityLabel(nil)
        }
    }

    private func applyNeedsYou(blocking: Int, waiting: Int) {
        let wasBlocking = self.blocking > 0
        self.blocking = max(0, blocking)
        self.waiting = max(0, waiting)
        blockingPill.isHidden = self.blocking == 0
        waitingPill.isHidden = self.waiting == 0
        blockingPill.toolTip = self.blocking == 0 ? nil
            : "\(self.blocking) \(self.blocking == 1 ? "approval" : "approvals") blocking: the agent is stopped until you decide"
        waitingPill.toolTip = self.waiting == 0 ? nil
            : "\(self.waiting) \(self.waiting == 1 ? "item" : "items") waiting for you: nothing is stalled"
        if wasBlocking != (self.blocking > 0) { updateAppearance() }
        needsLayout = true
    }

    private func updateAppearance() {
        let style = highlight
        for (index, bar) in bars.enumerated() {
            bar.isHidden = index >= style.bars.count
            if index < style.bars.count { bar.layer?.backgroundColor = style.bars[index].cgColor }
        }
        layer?.backgroundColor = (style.fill ?? .clear).cgColor

        // An attributed string overrides the label's lineBreakMode, so carry truncation here.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        if isActive {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isTopLevel ? Theme.navRepoFont : Theme.tabFontBold, .foregroundColor: NSColor.white, .paragraphStyle: para,
            ]
            label.attributedStringValue = NSAttributedString(string: displayOverride, attributes: attrs)
        } else {
            let color = sweaterColor ?? (isTopLevel ? Theme.navRepoColor : Theme.fgMuted)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isTopLevel ? Theme.navRepoFont : Theme.tabFont, .foregroundColor: color, .paragraphStyle: para,
            ]
            label.attributedStringValue = NSAttributedString(string: displayOverride, attributes: attrs)
        }

        if let sc = sweaterColor {
            dot.isHidden = false
            dot.layer?.backgroundColor = sc.cgColor
        } else {
            dot.isHidden = true
        }
    }
}
