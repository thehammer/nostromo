import AppKit
import NostromoKit

// AP2a: the exact input of a permission request, as the card shows it.
//
// A non-editable, selectable, monospaced text view in its own scroll view, with a
// line-number gutter. It shows what `ApprovalDisplayModel` hands it and nothing
// else: every line, never elided, never markdown, never a link. Separators are
// highlighted; invisible characters are shown as tokens in the warning colour;
// non-ASCII characters are tinted and carry a tooltip with their code point and
// name; a here-doc body is set off; an Edit is a diff.
//
// It reports `hasShownEveryLine` once the LAST line has been fully on screen at
// least once (it stays true). The card keeps Allow disabled until then: a person
// must never approve text they were not shown.

/// The card's colours. Explicit, because the whole app is pinned to Dark Aqua and a
/// colour that follows the system could flip in a non-key window.
enum ApprovalPalette {
    static let cardBackground = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)
    static let inputBackground = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    static let border = Theme.borderInactive

    /// Command text, file headers, JSON.
    static let commandText = Theme.fg
    /// "Agent says", the countdown and context lines.
    static let mutedText = Theme.fgMuted
    /// Invisible-character tokens and the banner.
    static let warning = Theme.amber
    static let warningFill = Theme.amber.withAlphaComponent(0.20)
    /// A separator (`&&`, `|`, `;`).
    static let separator = Theme.cornflower
    static let separatorFill = Theme.cornflower.withAlphaComponent(0.16)
    /// A non-ASCII look-alike.
    static let nonAscii = Theme.attention
    static let diffAdd = Theme.sage
    static let diffDelete = Theme.foldFailure
    static let heredocFill = Theme.codeBlockBackground
    static let gutterText = NSColor(white: 150 / 255, alpha: 1)
}

/// The text view. Its accessibility value is set to the input spoken line by line, with
/// every invisible character read by name (`ApprovalInputView.render`).
final class ApprovalTextView: NSTextView {}

final class ApprovalInputView: NSScrollView {

    let textView: ApprovalTextView
    /// True once the last line has been fully visible. Never goes back to false.
    private(set) var hasShownEveryLine = false
    /// Called once, when `hasShownEveryLine` becomes true.
    var onShownEveryLine: (() -> Void)?

    /// One entry per display line: its number and where it starts in `textView.string` (UTF-16).
    private(set) var lineNumbers: [Int] = []
    private var lineStarts: [Int] = []
    private var ignoreProgressUntilPersonScrolls = false
    private var lastClipOriginY: CGFloat = 0
    private let ruler = ApprovalLineNumberRuler()
    private let font = Theme.codeFont(size: 12)
    private static let textInset = NSSize(width: 6, height: 6)
    /// A clip-origin change smaller than this (points) is layout settling, not a scroll.
    private static let scrollNoise: CGFloat = 2

    init(model: ApprovalDisplayModel) {
        textView = ApprovalTextView(frame: .zero)
        super.init(frame: .zero)

        appearance = NSAppearance(named: .darkAqua)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false
        scrollerStyle = .legacy   // always visible: a person can see there is more to scroll to
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = ApprovalPalette.inputBackground
        translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = ApprovalPalette.inputBackground
        textView.textContainerInset = Self.textInset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.selectedTextAttributes = Theme.selectionAttributes
        let lineTotal = model.allLines.count
        textView.setAccessibilityLabel("Requested input, \(lineTotal) line\(lineTotal == 1 ? "" : "s")")
        documentView = textView

        ruler.owner = self
        verticalRulerView = ruler
        hasVerticalRuler = true
        rulersVisible = true

        render(model)

        contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(textViewFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: contentView)
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollArea)
        setAccessibilityLabel("Requested input")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Reading

    /// Exactly the text in the view, one string per display line.
    var displayedLines: [String] {
        textView.string.components(separatedBy: "\n")
    }

    /// The display line numbers wholly or partly on screen now (empty before layout).
    var visibleLineNumbers: [Int] {
        guard let layout = textView.layoutManager, let container = textView.textContainer, !lineNumbers.isEmpty else { return [] }
        let visible = documentVisibleRect.offsetBy(dx: -textView.textContainerOrigin.x, dy: -textView.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        guard glyphs.length > 0 else { return [] }
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(containing: chars.location)
        let last = lineIndex(containing: max(chars.location, NSMaxRange(chars) - 1))
        return Array(lineNumbers[first ... last])
    }

    /// The height of all the text at `width` (the whole view's width, gutter and scroller included).
    /// Measured on a scratch layout, so it doesn't depend on the live text view's size, which
    /// isn't known until the card has been laid out.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let source = textView.textStorage else { return 0 }
        let scroller = hasVerticalScroller ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let textWidth = max(40, width - ruler.ruleThickness - scroller - 2 * Self.textInset.width)
        let storage = NSTextStorage(attributedString: source)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textView.textContainer?.lineFragmentPadding ?? 2
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height + 2 * Self.textInset.height)
    }

    // MARK: Scrolling

    /// Scroll so the last line is on screen. (What a person does with the scroll wheel, for tests and scripts.)
    func scrollToEnd() {
        fitTextView()
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        updateScrollProgress()
    }

    func scrollToTop() {
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Re-check which lines are on screen. Called after layout and every scroll.
    func updateScrollProgress() {
        ruler.needsDisplay = true
        guard !hasShownEveryLine, !ignoreProgressUntilPersonScrolls else { return }
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        if textView.string.isEmpty { return markShownEveryLine() }
        guard contentView.bounds.height > 0, bounds.width > 0, textView.frame.width > 0 else { return }
        fitTextView()
        let lastGlyph = layout.numberOfGlyphs - 1
        guard lastGlyph >= 0 else { return markShownEveryLine() }
        let lastLine = layout.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let bottom = lastLine.maxY + textView.textContainerOrigin.y
        if bottom <= contentView.bounds.maxY + 1 { markShownEveryLine() }
    }

    override func layout() {
        super.layout()
        updateScrollProgress()
    }

    /// Size the text view to its laid-out text (never smaller than the clip), so what is on
    /// screen can be read from the clip's bounds without waiting for AppKit to resize it.
    private func fitTextView() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height + 2 * Self.textInset.height)
        let height = max(used, contentView.bounds.height)
        if abs(textView.frame.height - height) > 0.5 {
            textView.setFrameSize(NSSize(width: textView.frame.width, height: height))
        }
    }

    // MARK: Drawing support (the gutter)

    /// The top of display line `index` in text-view coordinates, or nil before layout.
    fileprivate func lineTop(at index: Int) -> CGFloat? {
        guard lineStarts.indices.contains(index), let layout = textView.layoutManager,
              layout.numberOfGlyphs > 0 else { return nil }
        if lineStarts[index] >= textView.string.utf16.count {
            // A last line with no text (the command ended in a newline) sits in the extra fragment.
            let extra = layout.extraLineFragmentRect
            return extra.isEmpty ? nil : extra.minY + textView.textContainerOrigin.y
        }
        let glyph = layout.glyphIndexForCharacter(at: min(lineStarts[index], max(0, textView.string.utf16.count - 1)))
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return rect.minY + textView.textContainerOrigin.y
    }

    fileprivate var lineCount: Int { lineNumbers.count }

    // MARK: Building the text

    private func render(_ model: ApprovalDisplayModel) {
        let text = NSMutableAttributedString()
        var spoken: [String] = []
        lineNumbers = []
        lineStarts = []
        for (i, line) in model.allLines.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "\n", attributes: baseAttributes(for: line.kind))) }
            lineNumbers.append(line.number)
            lineStarts.append(text.length)
            for run in line.runs { text.append(attributed(run, in: line)) }
            spoken.append(line.spokenText)
        }
        textView.textStorage?.setAttributedString(text)
        textView.setAccessibilityValue(spoken.joined(separator: "\n"))
        ruler.ruleThickness = ApprovalLineNumberRuler.thickness(forLineCount: max(1, model.allLines.count))
    }

    private func baseAttributes(for kind: ApprovalLineKind) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ApprovalPalette.commandText]
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping   // wrapped, never elided: a long token breaks anywhere
        // Left to right, always: right-to-left letters must not reorder a command on screen.
        style.baseWritingDirection = .leftToRight
        switch kind {
        case .heredocBody, .heredocEnd:
            style.firstLineHeadIndent = 14
            style.headIndent = 14
            attrs[.backgroundColor] = ApprovalPalette.heredocFill
        case .diffAdd:
            attrs[.foregroundColor] = ApprovalPalette.diffAdd
        case .diffDel:
            attrs[.foregroundColor] = ApprovalPalette.diffDelete
        case .diffCtx:
            attrs[.foregroundColor] = ApprovalPalette.mutedText
        case .fileHeader:
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        case .command, .json, .unknown:
            break
        }
        attrs[.paragraphStyle] = style
        return attrs
    }

    private func attributed(_ run: ApprovalRenderRun, in line: ApprovalRenderLine) -> NSAttributedString {
        var attrs = baseAttributes(for: line.kind)
        switch run.kind {
        case .plain:
            break
        case .separator:
            attrs[.foregroundColor] = ApprovalPalette.separator
            attrs[.backgroundColor] = ApprovalPalette.separatorFill
            attrs[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        case .invisible:
            attrs[.foregroundColor] = ApprovalPalette.warning
            attrs[.backgroundColor] = ApprovalPalette.warningFill
            attrs[.toolTip] = run.codePoint.map { ApprovalDisplayModel.describe(codePoint: $0) } ?? run.text
        case .nonAscii:
            attrs[.foregroundColor] = ApprovalPalette.nonAscii
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            if let tip = run.tooltip { attrs[.toolTip] = tip }
        }
        attrs[.writingDirection] = [NSWritingDirection.leftToRight.rawValue | NSWritingDirectionFormatType.override.rawValue]
        return NSAttributedString(string: run.text, attributes: attrs)
    }

    // MARK: Private

    /// Whether `event` is a person scrolling or pressing a key (not nil, not a mouse move, not
    /// app-control's, and fresh: AppKit leaves `NSApp.currentEvent` on the last event it
    /// dispatched, long after it happened). After a scroll the app-control socket made, only such an event lets the
    /// next movement of the input count as a person looking at it. A test replaces it.
    var isPersonEvent: (NSEvent?) -> Bool = { event in
        guard let event, !SyntheticInputGate.isSynthetic(event),
              ProcessInfo.processInfo.systemUptime - event.timestamp <= HumanGesture.maxEventAge else { return false }
        return [.scrollWheel, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .keyDown].contains(event.type)
    }

    @objc private func clipBoundsChanged(_ note: Notification) {
        // Only a scroll (the clip's origin moved) says anything about what was looked at; a
        // resize or a layout pass is neither a person nor the app-control socket.
        let origin = contentView.bounds.origin.y
        guard abs(origin - lastClipOriginY) > Self.scrollNoise else { return updateScrollProgress() }
        lastClipOriginY = origin
        let event = NSApp.currentEvent
        // A scroll the app-control socket made is not a person looking at the text: it
        // doesn't count towards "every line has been shown" until a person scrolls.
        if SyntheticInputGate.isSynthetic(event) && !SyntheticInputGate.allowsSynthetic {
            ignoreProgressUntilPersonScrolls = true
            return
        }
        if ignoreProgressUntilPersonScrolls {
            // Layout can move the clip too (a clamp after a resize): it takes a person's event to count.
            guard isPersonEvent(event) else { return }
            ignoreProgressUntilPersonScrolls = false
        }
        updateScrollProgress()
    }

    @objc private func textViewFrameChanged(_ note: Notification) {
        updateScrollProgress()
    }

    private func markShownEveryLine() {
        guard !hasShownEveryLine else { return }
        hasShownEveryLine = true
        onShownEveryLine?()
    }

    private func lineIndex(containing offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

// MARK: - The gutter

/// Line numbers, drawn at the first visual line of each display line (a long line that
/// wraps shows its number once).
final class ApprovalLineNumberRuler: NSRulerView {

    weak var owner: ApprovalInputView?

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    static func thickness(forLineCount count: Int) -> CGFloat {
        CGFloat(String(count).count) * 7 + 14
    }

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = nil
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        ApprovalPalette.inputBackground.setFill()
        rect.fill()
        guard let owner, let textView = scrollView?.documentView as? NSTextView else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: ApprovalPalette.gutterText]
        for index in 0 ..< owner.lineCount {
            guard let top = owner.lineTop(at: index) else { continue }
            let y = convert(NSPoint(x: 0, y: top), from: textView).y
            if y > rect.maxY { break }
            if y + 16 < rect.minY { continue }
            let label = NSAttributedString(string: String(owner.lineNumbers[index]), attributes: attrs)
            let size = label.size()
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + 2))
        }
    }
}
