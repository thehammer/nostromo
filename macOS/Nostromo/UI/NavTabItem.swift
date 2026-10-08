import AppKit

// MARK: - NavTabItem

/// One focus row in the sidebar. Internal (not private) only so a logic test can lay it out.
class NavTabItem: NSView {

    let focus: Focus
    var onTap: (() -> Void)?

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    /// An outstanding request (e.g. a pending decision) is waiting on this focus.
    var needsAttention: Bool = false {
        didSet {
            attentionDot.isHidden = !needsAttention
            labelClearsAttentionDot?.isActive = needsAttention
        }
    }

    var sweaterColor: NSColor? = nil {
        didSet { updateAppearance() }
    }

    private let accentBar      = NSView()
    private let label          = NSTextField(labelWithString: "")
    private let dot            = NSView()
    private let attentionDot   = NSView()
    /// Keeps the primary label's text out from under the attention dot. Active only
    /// while the dot is shown; it only narrows the label's trailing edge, so it never
    /// changes the row's height or the label's single-line truncation.
    private var labelClearsAttentionDot: NSLayoutConstraint?
    private let displayOverride: String
    private let secondaryLabel: NSTextField?

    init(focus: Focus, label displayLabel: String, secondary: String?, indented: Bool) {
        self.focus           = focus
        self.displayOverride = displayLabel
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
        label.font           = Theme.tabFont
        label.textColor      = Theme.fgMuted
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

        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tapped)))

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    private func updateAppearance() {
        accentBar.isHidden = !isActive
        layer?.backgroundColor = isActive
            ? Theme.cornflower.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor

        if isActive {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tabFontBold, .foregroundColor: NSColor.white,
            ]
            label.attributedStringValue = NSAttributedString(string: displayOverride, attributes: attrs)
        } else {
            let color = sweaterColor ?? Theme.fgMuted
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Theme.tabFont, .foregroundColor: color,
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
