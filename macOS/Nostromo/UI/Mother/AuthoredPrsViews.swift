import AppKit
import NostromoKit

// The pieces of the My open PRs Overview: the header, a group header, a PR row and the count pill.
//
// Everything a PR's author or GitHub wrote (title, check names, logins, branches, repo and focus names) is
// shown as plain text in labels: never Markdown, attributed HTML or a link. The one link is the Mother
// job id, which selects that job in the list.

// MARK: - Palette

/// Colours that read in both appearances. The Mother pane is dark; the tests render both.
enum AuthoredPrsPalette {
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
    static let text = dynamic(dark: Theme.fg, light: NSColor(white: 0.10, alpha: 1))
    static let muted = dynamic(dark: NSColor(white: 0.62, alpha: 1), light: NSColor(white: 0.38, alpha: 1))
    static let background = dynamic(dark: Theme.bg, light: .white)
    static let chipFill = dynamic(dark: NSColor(white: 1, alpha: 0.14), light: NSColor(white: 0, alpha: 0.10))
    static let selection = dynamic(dark: Theme.cornflower.withAlphaComponent(0.24), light: Theme.cornflower.withAlphaComponent(0.20))
    static let hover = dynamic(dark: NSColor(white: 1, alpha: 0.06), light: NSColor(white: 0, alpha: 0.05))
    static let passing = dynamic(dark: Theme.sage, light: NSColor(red: 0.07, green: 0.5, blue: 0.2, alpha: 1))
    static let failing = dynamic(dark: Theme.redSweater, light: NSColor(red: 0.75, green: 0.1, blue: 0.1, alpha: 1))
    static let pending = dynamic(dark: Theme.amber, light: NSColor(red: 0.62, green: 0.42, blue: 0, alpha: 1))
    static let merged = dynamic(dark: Theme.attention, light: NSColor(red: 0.45, green: 0.2, blue: 0.7, alpha: 1))
    static let link = dynamic(dark: Theme.followBlue, light: NSColor(red: 0.1, green: 0.35, blue: 0.8, alpha: 1))
    static let warning = dynamic(dark: Theme.amber, light: NSColor(red: 0.62, green: 0.42, blue: 0, alpha: 1))
    /// Perri's badge. Each is at least 4.5:1 over `background` in both appearances (a test measures it); the glyph
    /// and the words, never the colour alone, say which verdict it is.
    static let perriApproved = passing
    /// An approval of an older version: the same as the muted text, so it reads as quieter than a current one.
    static let perriMuted = muted
    static let perriChanges = dynamic(dark: NSColor(red: 1, green: 0.42, blue: 0.42, alpha: 1),
                                      light: NSColor(red: 0.75, green: 0.1, blue: 0.1, alpha: 1))

    static func statusColor(_ kind: AuthoredPrRowModel.StatusKind) -> NSColor {
        switch kind {
        case .passing: return passing
        case .failing: return failing
        case .pending: return pending
        case .merged: return merged
        case .none, .closed: return muted
        }
    }
}

private func plainLabel(font: NSFont, color: NSColor, truncates: Bool = true) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = font
    label.textColor = color
    label.lineBreakMode = truncates ? .byTruncatingTail : .byClipping
    label.maximumNumberOfLines = 1
    label.cell?.usesSingleLineMode = true
    label.cell?.truncatesLastVisibleLine = truncates
    label.allowsEditingTextAttributes = false
    label.isSelectable = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return label
}

// MARK: - Chip and count pill

/// A rounded chip with one short text, drawn directly (not through a text cell, which insets its text and
/// clips the last glyph of a tight frame). Used for the repo chip, the Draft badge and every count.
final class AuthoredPrsChipView: NSView {
    static let height: CGFloat = 16
    static let horizontalPadding: CGFloat = 6
    static let font = NSFont.systemFont(ofSize: 10, weight: .semibold)

    var text: String { didSet { guard text != oldValue else { return }; invalidateIntrinsicContentSize(); needsDisplay = true } }

    /// The width the chip needs for `text`: its ink plus padding on both sides.
    static func width(for text: String) -> CGFloat {
        max(height, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * horizontalPadding)
    }

    init(text: String = "") {
        self.text = text
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.init(999), for: .horizontal)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width(for: text), height: Self.height) }

    override func draw(_ dirtyRect: NSRect) {
        AuthoredPrsPalette.chipFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: AuthoredPrsPalette.text]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded()),
                                withAttributes: attrs)
    }
}

// MARK: - Header

/// `My open PRs · 14`, each source's freshness in words, and ⟳. Always visible above the list.
final class AuthoredPrsHeaderView: NSView {
    struct Note: Equatable {
        var text: String
        var isWarning = false
    }

    static let barHeight: CGFloat = 32
    static let noteHeight: CGFloat = 20

    let titleLabel = plainLabel(font: .systemFont(ofSize: 13, weight: .semibold), color: AuthoredPrsPalette.text, truncates: false)
    let freshnessLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted)
    let refreshButton = NSButton()
    private var noteLabels: [NSTextField] = []
    var onRefresh: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        freshnessLabel.alignment = .right
        freshnessLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        refreshButton.isBordered = false
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageOnly
        refreshButton.contentTintColor = AuthoredPrsPalette.muted
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        refreshButton.setAccessibilityLabel("Refresh my open PRs")
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        for v in [titleLabel, freshnessLabel, refreshButton] as [NSView] { addSubview(v) }
        let bar = Self.barHeight
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: bar / 2),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            refreshButton.centerYAnchor.constraint(equalTo: topAnchor, constant: bar / 2),
            refreshButton.widthAnchor.constraint(equalToConstant: 24),
            refreshButton.heightAnchor.constraint(equalToConstant: 24),
            freshnessLabel.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -6),
            freshnessLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            freshnessLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: bar / 2),
        ])
        apply(model: nil, notes: [])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `model` nil before the first snapshot: the title alone.
    func apply(model: AuthoredPrsHeaderModel?, notes newNotes: [Note]) {
        titleLabel.stringValue = model?.countText ?? "My open PRs"
        freshnessLabel.stringValue = model?.freshness ?? ""
        freshnessLabel.toolTip = model?.freshness
        let enabled = model?.refreshEnabled ?? false
        refreshButton.isEnabled = enabled
        refreshButton.toolTip = enabled ? "Refresh now (⌘R)" : (model?.refreshDisabledReason ?? "Waiting for the first update")
        refreshButton.alphaValue = enabled ? 1 : 0.4
        setAccessibilityElement(false)
        titleLabel.setAccessibilityLabel(model.map { "\($0.countText). \($0.freshness)" } ?? "My open PRs")

        noteLabels.forEach { $0.removeFromSuperview() }
        // Each note is its own line, pinned to the header's padding: a long one truncates, never widens the header.
        noteLabels = newNotes.map { note in
            let label = plainLabel(font: .systemFont(ofSize: 11), color: note.isWarning ? AuthoredPrsPalette.warning : AuthoredPrsPalette.muted)
            label.stringValue = note.text
            label.toolTip = note.text
            label.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            return label
        }
        for (index, label) in noteLabels.enumerated() {
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: Self.barHeight + CGFloat(index) * Self.noteHeight),
                label.heightAnchor.constraint(equalToConstant: Self.noteHeight),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            ])
        }
    }

    /// The header's height for `noteCount` note lines.
    static func height(noteCount: Int) -> CGFloat { barHeight + CGFloat(noteCount) * noteHeight + 2 }

    @objc private func refreshPressed() { onRefresh?() }
}

// MARK: - Group header and "Show N more"

/// `NEEDS YOU` and a count pill. A heading for VoiceOver, with its count.
final class AuthoredPrsGroupHeaderView: NSView {
    static let height: CGFloat = 26

    let titleLabel = plainLabel(font: .systemFont(ofSize: 11, weight: .semibold), color: AuthoredPrsPalette.muted, truncates: false)
    let countPill = AuthoredPrsChipView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        addSubview(titleLabel)
        addSubview(countPill)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countPill.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            countPill.heightAnchor.constraint(equalToConstant: AuthoredPrsChipView.height),
            countPill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ group: AuthoredPrsGroupModel) {
        titleLabel.stringValue = group.title
        countPill.text = group.countText
        setAccessibilityElement(true)
        setAccessibilityRole(NSAccessibility.Role(rawValue: "AXHeading"))
        setAccessibilityLabel(group.accessibilityLabel)
        setAccessibilityChildren([])
    }
}

/// `Show 12 more`: the rest of a group past the 25-row cap.
final class AuthoredPrsShowMoreView: NSView {
    static let height: CGFloat = 26
    let button = NSButton()
    var onPress: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.target = self
        button.action = #selector(pressed)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) {
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: AuthoredPrsPalette.link])
        button.setAccessibilityLabel(title)
    }

    @objc private func pressed() { onPress?() }
}

// MARK: - Row

/// One PR, four lines:
///
///     ✗ failing  #458  Slash commands 1: picker with help text        [nostromo]  2h
///                Checks: 1 failed (swift-tests) · 9 passed
///                Changes requested by dana · 3 new comments · 2 unresolved
///                base: slash-commands-0 · Mother job a1b2c3 · Cody (nostromo)
///
/// The title truncates at the tail; the repo chip, age, number and status never do. The checks and review
/// lines and the last line truncate at the tail. Colour is never the only signal: a glyph and a word always.
final class AuthoredPrRowView: NSView {
    static let topPadding: CGFloat = 6
    static let firstLineHeight: CGFloat = 18
    static let lineHeight: CGFloat = 15
    static let lineGap: CGFloat = 2
    static let bottomPadding: CGFloat = 6
    static let sidePadding: CGFloat = 12
    static let detailIndent: CGFloat = 16
    /// The height every row is laid out at (and that the outline's delegate answers).
    static let rowHeight: CGFloat = topPadding + firstLineHeight + lineGap + 3 * lineHeight + bottomPadding

    let statusLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted, truncates: false)
    let numberLabel = plainLabel(font: .systemFont(ofSize: 12, weight: .semibold), color: AuthoredPrsPalette.text, truncates: false)
    let titleLabel = plainLabel(font: .systemFont(ofSize: 12), color: AuthoredPrsPalette.text)
    let draftBadge = AuthoredPrsChipView(text: "Draft")
    let repoChip = AuthoredPrsChipView()
    let ageLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted, truncates: false)
    let checksLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted)
    let reviewLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted)
    let baseLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted)
    let ownerPrefixLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted)
    let jobButton = NSButton()
    let ownerSuffixLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted)
    /// `Told Cody 1m ago`: never truncates, so the age is always readable.
    let toldLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.muted, truncates: false)
    /// Tell <focus>, Choose focus… or Start a session…: only on a fixable row, and only when the daemon can hand off.
    let tellButton = NSButton()
    /// `Perri ✓`: Perri's verdict, never truncated, at the end of the review line.
    let perriLabel = plainLabel(font: .systemFont(ofSize: 11, weight: .semibold), color: AuthoredPrsPalette.muted, truncates: false)
    /// Merge (or Merging…, Merged): only on an open READY row, and only when the daemon can merge. Its width is
    /// the same in every state, so the row does not shift as the state changes.
    let mergeButton = NSButton()
    /// Why the last merge failed, in the place of the owner line, with a way to dismiss it.
    let noticeLabel = plainLabel(font: .systemFont(ofSize: 11), color: AuthoredPrsPalette.warning)
    let noticeDismissButton = NSButton()
    private let noticeStack = NSStackView()
    private let lastStack = NSStackView()
    /// Where the detail lines end: the row's edge, or the visible button.
    private var trailingEdge: [NSLayoutConstraint] = []

    static let mergeButtonWidth: CGFloat = 78

    private(set) var model: AuthoredPrRowModel?
    /// Called with the Mother job id when its link is pressed.
    var onOpenJob: ((String) -> Void)?
    /// Called when the row's button is pressed (the current event is the click).
    var onTell: ((AuthoredPrRowModel) -> Void)?
    /// Called when Merge is pressed (or VoiceOver's Merge action runs).
    var onMerge: ((AuthoredPrRowModel) -> Void)?
    /// Called when the merge notice's dismiss button is pressed.
    var onDismissMergeNotice: ((AuthoredPrRowModel) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for label in [statusLabel, numberLabel, ageLabel] { label.setContentCompressionResistancePriority(.init(999), for: .horizontal) }
        titleLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        checksLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        reviewLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        baseLabel.setContentCompressionResistancePriority(.init(400), for: .horizontal)
        ownerPrefixLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        ownerSuffixLabel.setContentCompressionResistancePriority(.init(260), for: .horizontal)

        jobButton.isBordered = false
        jobButton.target = self
        jobButton.action = #selector(jobPressed)
        jobButton.translatesAutoresizingMaskIntoConstraints = false
        jobButton.setContentCompressionResistancePriority(.init(350), for: .horizontal)
        jobButton.setAccessibilityElement(false)

        let first = NSStackView(views: [statusLabel, numberLabel, titleLabel, draftBadge, repoChip, ageLabel])
        toldLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        toldLabel.setContentHuggingPriority(.required, for: .horizontal)
        tellButton.bezelStyle = .rounded
        tellButton.controlSize = .small
        tellButton.font = .systemFont(ofSize: 11)
        tellButton.lineBreakMode = .byClipping
        tellButton.target = self
        tellButton.action = #selector(tellPressed)
        tellButton.translatesAutoresizingMaskIntoConstraints = false
        tellButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        tellButton.setContentHuggingPriority(.required, for: .horizontal)
        tellButton.isHidden = true

        perriLabel.setContentCompressionResistancePriority(.init(999), for: .horizontal)
        perriLabel.setContentHuggingPriority(.required, for: .horizontal)
        perriLabel.isHidden = true
        mergeButton.bezelStyle = .rounded
        mergeButton.controlSize = .small
        mergeButton.font = .systemFont(ofSize: 11)
        mergeButton.lineBreakMode = .byClipping
        mergeButton.target = self
        mergeButton.action = #selector(mergePressed)
        // Merge has no key equivalent, here or anywhere.
        mergeButton.keyEquivalent = ""
        mergeButton.translatesAutoresizingMaskIntoConstraints = false
        mergeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        mergeButton.setContentHuggingPriority(.required, for: .horizontal)
        mergeButton.setAccessibilityIdentifier("authored-pr-merge")
        mergeButton.isHidden = true

        noticeLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        noticeLabel.isHidden = true
        noticeDismissButton.isBordered = false
        noticeDismissButton.title = "✕"
        noticeDismissButton.font = .systemFont(ofSize: 11, weight: .semibold)
        noticeDismissButton.contentTintColor = AuthoredPrsPalette.muted
        noticeDismissButton.attributedTitle = NSAttributedString(string: "✕", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: AuthoredPrsPalette.muted])
        noticeDismissButton.target = self
        noticeDismissButton.action = #selector(dismissNoticePressed)
        noticeDismissButton.translatesAutoresizingMaskIntoConstraints = false
        noticeDismissButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        noticeDismissButton.setContentHuggingPriority(.required, for: .horizontal)
        noticeDismissButton.setAccessibilityLabel("Dismiss merge message")
        noticeDismissButton.toolTip = "Dismiss"
        noticeDismissButton.isHidden = true

        let last = lastStack
        last.setViews([baseLabel, ownerPrefixLabel, jobButton, ownerSuffixLabel, toldLabel], in: .leading)
        noticeStack.setViews([noticeLabel, noticeDismissButton], in: .leading)
        for stack in [first, last, noticeStack] {
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
        }
        first.spacing = 6
        last.spacing = 0
        noticeStack.spacing = 6
        last.detachesHiddenViews = true
        noticeStack.detachesHiddenViews = true
        noticeStack.isHidden = true
        addSubview(checksLabel)
        addSubview(reviewLabel)
        addSubview(perriLabel)
        addSubview(tellButton)
        addSubview(mergeButton)

        let side = Self.sidePadding, indent = side + Self.detailIndent
        NSLayoutConstraint.activate([
            first.topAnchor.constraint(equalTo: topAnchor, constant: Self.topPadding),
            first.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side),
            first.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            first.heightAnchor.constraint(equalToConstant: Self.firstLineHeight),

            checksLabel.topAnchor.constraint(equalTo: first.bottomAnchor, constant: Self.lineGap),
            checksLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            checksLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight),

            reviewLabel.topAnchor.constraint(equalTo: checksLabel.bottomAnchor),
            reviewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            reviewLabel.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            // The verdict follows the review text and never truncates: the review line gives way to it.
            perriLabel.leadingAnchor.constraint(equalTo: reviewLabel.trailingAnchor, constant: 8),
            perriLabel.centerYAnchor.constraint(equalTo: reviewLabel.centerYAnchor),

            last.topAnchor.constraint(equalTo: reviewLabel.bottomAnchor),
            last.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            last.heightAnchor.constraint(equalToConstant: Self.lineHeight),
            last.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomPadding),
            noticeStack.topAnchor.constraint(equalTo: last.topAnchor),
            noticeStack.leadingAnchor.constraint(equalTo: last.leadingAnchor),
            noticeStack.heightAnchor.constraint(equalTo: last.heightAnchor),

            tellButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            tellButton.centerYAnchor.constraint(equalTo: reviewLabel.centerYAnchor),
            mergeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            mergeButton.centerYAnchor.constraint(equalTo: reviewLabel.centerYAnchor),
            mergeButton.widthAnchor.constraint(equalToConstant: Self.mergeButtonWidth),

            // A repo chip never truncates, except a pathological owner/name past half the row.
            repoChip.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5),
            draftBadge.heightAnchor.constraint(equalToConstant: AuthoredPrsChipView.height),
            repoChip.heightAnchor.constraint(equalToConstant: AuthoredPrsChipView.height),
        ])
        updateTrailingEdge(beside: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.rowHeight) }

    func configure(_ model: AuthoredPrRowModel) {
        self.model = model
        let status = NSMutableAttributedString(string: model.statusGlyph + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: AuthoredPrsPalette.statusColor(model.statusKind)])
        status.append(NSAttributedString(string: model.statusWord, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: AuthoredPrsPalette.statusColor(model.statusKind)]))
        statusLabel.attributedStringValue = status
        numberLabel.stringValue = model.numberText
        titleLabel.stringValue = model.title
        titleLabel.toolTip = model.title
        draftBadge.isHidden = !model.isDraft
        repoChip.text = model.repoChip
        repoChip.toolTip = model.repo
        ageLabel.stringValue = model.age
        checksLabel.stringValue = model.checksLine
        checksLabel.toolTip = model.checksTooltip
        reviewLabel.stringValue = model.reviewLine
        reviewLabel.toolTip = model.reviewLine

        baseLabel.isHidden = model.base == nil
        baseLabel.stringValue = model.base.map { "base: \($0) · " } ?? ""
        baseLabel.toolTip = model.base.map { "Base branch: \($0)" }
        ownerPrefixLabel.stringValue = model.ownerPrefix
        if let job = model.ownerJobId {
            jobButton.isHidden = false
            jobButton.attributedTitle = NSAttributedString(string: job, attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: AuthoredPrsPalette.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue])
            jobButton.toolTip = "Show Mother job \(job)"
        } else {
            jobButton.isHidden = true
        }
        let suffix = model.ownerSuffix + (model.detailsUnavailable ? " · details unavailable" : "")
        ownerSuffixLabel.stringValue = suffix
        ownerSuffixLabel.isHidden = suffix.isEmpty

        let told = model.toldText.map { " · " + $0 } ?? ""
        toldLabel.stringValue = told
        toldLabel.isHidden = told.isEmpty

        if let tell = model.tellButton {
            tellButton.isHidden = false
            tellButton.title = tell.title
            tellButton.toolTip = tell.title
            tellButton.setAccessibilityLabel(tell.accessibilityLabel)
            tellButton.setAccessibilityIdentifier("authored-pr-tell")
        } else {
            tellButton.isHidden = true
        }

        configurePerri(model.perriBadge)
        configureMerge(model.mergeButton)
        configureNotice(model.mergeNotice)
        // Never both: Tell is on a row that needs you, Merge on one that is ready.
        let sideButton: NSButton? = !mergeButton.isHidden ? mergeButton : (!tellButton.isHidden ? tellButton : nil)
        updateTrailingEdge(beside: sideButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        setAccessibilityLabel(model.accessibilityLabel)
        // The row is one element; its buttons are the children that are elements of their own.
        var children: [Any] = []
        if !tellButton.isHidden { children.append(tellButton) }
        if !mergeButton.isHidden { children.append(mergeButton) }
        if !noticeDismissButton.isHidden { children.append(noticeDismissButton) }
        setAccessibilityChildren(children)
        var actions: [NSAccessibilityCustomAction] = []
        if model.mergeButton?.isEnabled == true {
            actions.append(NSAccessibilityCustomAction(name: "Merge") { [weak self] in
                self?.mergePressed()
                return true
            })
        }
        if model.mergeNotice != nil {
            actions.append(NSAccessibilityCustomAction(name: "Dismiss merge message") { [weak self] in
                self?.dismissNoticePressed()
                return true
            })
        }
        if let job = model.ownerJobId {
            actions.append(NSAccessibilityCustomAction(name: "Show Mother job \(job)") { [weak self] in
                self?.jobPressed()
                return true
            })
        }
        setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
        needsLayout = true
    }

    private func configurePerri(_ badge: AuthoredPrPerriBadge?) {
        guard let badge else {
            perriLabel.isHidden = true
            perriLabel.stringValue = ""
            perriLabel.toolTip = nil
            return
        }
        perriLabel.isHidden = false
        perriLabel.stringValue = badge.text
        perriLabel.textColor = Self.perriColor(badge)
        perriLabel.toolTip = badge.tooltip
        perriLabel.setAccessibilityLabel(badge.accessibilityLabel)
    }

    private static func perriColor(_ badge: AuthoredPrPerriBadge) -> NSColor {
        switch badge.kind {
        case .approved: return AuthoredPrsPalette.perriApproved
        case .olderApproval: return AuthoredPrsPalette.perriMuted
        case .changesRequested: return AuthoredPrsPalette.perriChanges
        case .comments: return AuthoredPrsPalette.text
        }
    }

    private func configureMerge(_ merge: AuthoredPrMergeButton?) {
        guard let merge else {
            mergeButton.isHidden = true
            return
        }
        mergeButton.isHidden = false
        mergeButton.title = merge.title
        mergeButton.isEnabled = merge.isEnabled
        mergeButton.toolTip = merge.tooltip
        mergeButton.setAccessibilityLabel(merge.accessibilityLabel)
    }

    private func configureNotice(_ notice: String?) {
        let shown = notice != nil
        noticeLabel.stringValue = notice ?? ""
        noticeLabel.toolTip = notice
        noticeLabel.isHidden = !shown
        noticeDismissButton.isHidden = !shown
        noticeStack.isHidden = !shown
        // The notice takes the owner line's place; the row does not grow.
        lastStack.isHidden = shown
    }

    /// The detail lines end at the row's edge, or at the visible button. The verdict follows the review text and
    /// stays inside the same edge.
    private func updateTrailingEdge(beside button: NSButton?) {
        NSLayoutConstraint.deactivate(trailingEdge)
        let edge = button?.leadingAnchor ?? trailingAnchor
        let gap: CGFloat = button == nil ? -Self.sidePadding : -8
        var constraints = [
            checksLabel.trailingAnchor.constraint(equalTo: edge, constant: gap),
            lastStack.trailingAnchor.constraint(equalTo: edge, constant: gap),
            noticeStack.trailingAnchor.constraint(equalTo: edge, constant: gap),
        ]
        if perriLabel.isHidden {
            constraints.append(reviewLabel.trailingAnchor.constraint(equalTo: edge, constant: gap))
        } else {
            constraints.append(perriLabel.trailingAnchor.constraint(lessThanOrEqualTo: edge, constant: gap))
        }
        trailingEdge = constraints
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func jobPressed() {
        if let id = model?.ownerJobId { onOpenJob?(id) }
    }

    @objc private func tellPressed() {
        if let model { onTell?(model) }
    }

    @objc private func mergePressed() {
        if let model { onMerge?(model) }
    }

    @objc private func dismissNoticePressed() {
        if let model { onDismissMergeNotice?(model) }
    }
}

// MARK: - Row background

/// The outline's row: the list's own selection and hover colours, drawn by hand so a hovered row reads.
final class AuthoredPrsRowBackground: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }

    override func drawBackground(in dirtyRect: NSRect) {
        if isHovered && !isSelected {
            AuthoredPrsPalette.hover.setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        AuthoredPrsPalette.selection.setFill()
        bounds.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
