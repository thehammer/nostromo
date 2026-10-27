import AppKit

// MARK: - NavTabItem

/// One focus row in the sidebar. Internal (not private) only so a logic test can lay it out.
class NavTabItem: NSView, NSGestureRecognizerDelegate {

    let focus: Focus
    var onTap: (() -> Void)?
    /// Click on the count pill. Falls back to `onTap` when unset.
    var onBadgeTap: (() -> Void)?

    /// Pill text currently shown (nil when hidden). Exposed for tests.
    var pillText: String? { pillBox.isHidden ? nil : pillLabel.stringValue }
    /// The pill shown is the red "needs you now" one. Exposed for tests and `approvals badges`.
    private(set) var showsNeedsYouNow = false
    /// Second-line text currently shown. Exposed for tests.
    var secondaryText: String? { secondaryLabel?.stringValue }

    // Test hooks (read-only geometry in this view's coordinates, and click simulation
    // that runs the same actions the gesture recognizers do). Used by logic tests only.
    var pillFrame: NSRect? { pillBox.isHidden ? nil : pillBox.frame }
    var attentionDotFrame: NSRect? { attentionDot.isHidden ? nil : attentionDot.frame }
    var labelFrame: NSRect { label.frame }
    func simulateRowClick() { tapped() }
    func simulatePillClick() { pillTapped() }

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
    private static let badgeSpacing: CGFloat = 3
    private static let badgeHeight: CGFloat = 14
    private let accentBar      = NSView()
    private let label          = NSTextField(labelWithString: "")
    private let dot            = NSView()
    private let attentionDot   = NSView()
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
    private let displayOverride: String
    /// Top-level rows (not nested under a repo header) use the repo-header look.
    private let isTopLevel: Bool
    private let baseSecondary: String?
    private let secondaryLabel: NSTextField?

    init(focus: Focus, label displayLabel: String, secondary: String?, indented: Bool) {
        self.focus           = focus
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

        let leadingInset: CGFloat = indented ? 6 + Theme.navChildIndent : 6

        // Left accent bar — 3px, full height
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = Theme.cornflower.cgColor
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(accentBar)
        NSLayoutConstraint.activate([
            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
        ])

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
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor, constant: leadingInset),
                label.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }

        labelClearsAttentionDot = label.trailingAnchor.constraint(lessThanOrEqualTo: attentionDot.leadingAnchor, constant: -4)
        labelClearsAttentionDot?.isActive = needsAttention

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
        let labelTextWidth = ceil((displayLabel as NSString).size(withAttributes: [.font: label.font as Any]).width)
        let keeps = label.widthAnchor.constraint(greaterThanOrEqualToConstant: min(40, labelTextWidth))
        keeps.priority = NSLayoutConstraint.Priority(900)
        labelKeepsItsName = keeps

        let rowClick = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        rowClick.delegate = self
        addGestureRecognizer(rowClick)
        pillBox.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(pillTapped)))

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

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
        super.layout()
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

    /// A click on the pill belongs to the pill's own recognizer, not the row's.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        pillBox.isHidden || !pillBox.frame.contains(convert(event.locationInWindow, from: nil))
    }

    /// Apply a badge in place: pill text, second line (Fred/Mother/Teri built-ins only)
    /// and accessibility label. `nil` clears them. Never changes the row's height.
    func setBadge(_ badge: FocusBadge?) {
        showsNeedsYouNow = badge?.level == .needsYouNow && badge?.pill != nil
        if let pill = badge?.pill {
            pillLabel.stringValue = pill
            pillBox.isHidden = false
            // The red "needs you now" variant is opaque; the rest keep the quiet cornflower.
            pillBox.layer?.backgroundColor = badge?.level == .needsYouNow
                ? Theme.needsYouNow.cgColor
                : Theme.cornflower.withAlphaComponent(0.25).cgColor
        } else {
            pillBox.isHidden = true
        }
        labelClearsPill?.isActive = !pillBox.isHidden
        updateBadgeReserve()

        if focus.isBuiltIn, ["fred", "mother", "teri"].contains(focus.agentTag.lowercased()) {
            secondaryLabel?.stringValue = badge?.detail ?? baseSecondary ?? ""
        }

        if let badge {
            let suffix: String
            switch badge.level {
            case .needsYouNow: suffix = ", needs you now"
            case .attention: suffix = ", needs your attention"
            case .info: suffix = ""
            }
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(badge.accessibilityLabel + suffix)
        } else {
            setAccessibilityElement(false)
            setAccessibilityLabel(nil)
        }
    }

    private func updateAppearance() {
        accentBar.isHidden = !isActive
        layer?.backgroundColor = isActive
            ? Theme.cornflower.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor

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
