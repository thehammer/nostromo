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
// It reports `hasShownEveryLine` once EVERY line (every wrapped fragment of every
// line) has been on screen, in full, at some moment while the card's window was
// showing (it stays true). The card keeps Allow disabled until then: a person must
// never approve text they were not shown. Jumping to the end shows the end only, so
// it does not count for the lines in between; scrolling through them does.

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
    /// True once every line has been fully visible (see `coveredCharacters`). Never goes back to false.
    private(set) var hasShownEveryLine = false
    /// Called once, when `hasShownEveryLine` becomes true.
    var onShownEveryLine: (() -> Void)?
    /// True once the text, though the model has some, could not be laid out (no glyphs, or an empty
    /// used rect, in a view that has a size): what is on screen can't be trusted to be the input, so
    /// the card must not offer Allow once. Never goes back to false.
    private(set) var displayFailed = false
    /// Called once, when `displayFailed` becomes true.
    var onDisplayFailed: (() -> Void)?
    /// Tests only: treat the text layout as empty, as if no glyph had been laid out.
    var forceNoGlyphsForTesting = false
    private let modelHasText: Bool

    /// One entry per display line: its number and where it starts in `textView.string` (UTF-16).
    private(set) var lineNumbers: [Int] = []
    private var lineStarts: [Int] = []
    private var ignoreProgressUntilPersonScrolls = false
    /// The UTF-16 offsets of the text that have been on screen, whole line fragments at a time
    /// (offsets, not fragment numbers, so a re-wrap after a resize keeps what was seen). One
    /// extra offset, just past the end, stands for a last line with no text. Only grows.
    private var coveredCharacters = IndexSet()
    /// Line fragments seen only in part so far: the vertical spans (text-view coordinates) of
    /// each that have been on screen. A fragment is covered once its spans add up to all of it.
    private var partlySeen: [NSRange: [ClosedRange<CGFloat>]] = [:]
    /// The text view's width when `partlySeen` was recorded; a re-wrap invalidates it.
    private var coverageWidth: CGFloat = 0
    /// Replaces the window half of "is this on screen?" (a visible, not occluded window). The
    /// rest (in a window, not hidden, not zero-sized) always applies. Tests set it.
    var isWindowShowing: (() -> Bool)?
    private var lastClipOriginY: CGFloat = 0
    private let ruler = ApprovalLineNumberRuler()
    private let font = Theme.codeFont(size: 12)
    private static let textInset = NSSize(width: 6, height: 6)
    /// A clip-origin change smaller than this (points) is layout settling, not a scroll.
    private static let scrollNoise: CGFloat = 2
    /// Spans of a line fragment that meet within this (points) count as one: scroll positions are pixel-snapped.
    private static let coverageTolerance: CGFloat = 1
    /// The clip view must be at least this tall (points) for what is in it to count as shown.
    private static let minimumCoveringHeight: CGFloat = 16

    init(model: ApprovalDisplayModel) {
        modelHasText = model.allLines.contains { line in line.runs.contains { !$0.text.isEmpty } }
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

    // MARK: On screen

    /// Coverage is only earned while the card can really be seen: in a window that is visible
    /// and not occluded, not hidden, and not laid out at zero size.
    private var isShowingOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor, bounds.width > 0, bounds.height > 0 else { return false }
        return isWindowShowing?() ?? (window.isVisible && window.occlusionState.contains(.visible))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let old = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: old)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisibleOrNot),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: window)
        updateScrollProgress()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateScrollProgress()
    }

    @objc private func windowBecameVisibleOrNot(_ note: Notification) {
        updateScrollProgress()
    }

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

    /// The display line numbers with any text still never shown (empty once `hasShownEveryLine`).
    var linesNotYetShown: [Int] {
        guard !lineStarts.isEmpty else { return [] }
        let total = coverageTotal
        return lineStarts.indices.compactMap { i in
            let end = i + 1 < lineStarts.count ? lineStarts[i + 1] : total
            return end <= lineStarts[i] || coveredCharacters.contains(integersIn: lineStarts[i] ..< end) ? nil : lineNumbers[i]
        }
    }

    /// The height of all the text at `width` (the whole view's width, gutter and scroller included).
    /// Measured on a scratch layout, so it doesn't depend on the live text view's size, which
    /// isn't known until the card has been laid out.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let source = textView.textStorage else { return 0 }
        let scroller = hasVerticalScroller ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollerStyle) : 0
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

    /// Jump so the last line is on screen (End, Cmd-Down, a scroller drag). For tests and scripts. A jump
    /// shows the end and nothing between: only what is on screen after it counts.
    func scrollToEnd() {
        fitTextView()
        textView.scrollRangeToVisible(NSRange(location: (textView.string as NSString).length, length: 0))
        updateScrollProgress()
    }

    func scrollToTop() {
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// Re-check which lines are on screen and add them to what has been shown. Called after
    /// layout, on every clip movement and when the window's visibility changes.
    func updateScrollProgress() {
        ruler.needsDisplay = true
        checkDisplay()
        guard !displayFailed, !hasShownEveryLine, !ignoreProgressUntilPersonScrolls else { return }
        guard isShowingOnScreen else { return }
        if textView.string.isEmpty { return markShownEveryLine() }
        guard contentView.bounds.height > 0, textView.frame.width > 0 else { return }
        fitTextView()
        coverVisibleFragments()
        if coveredCharacters.contains(integersIn: 0 ..< coverageTotal) { markShownEveryLine() }
    }

    override func layout() {
        super.layout()
        updateScrollProgress()
    }

    /// Fail closed: a view that has a size and whose model has text must have laid out glyphs with a
    /// non-empty extent. If not, what a person would be asked to approve may not be on screen.
    private func checkDisplay() {
        guard !displayFailed, modelHasText, bounds.width > 0, bounds.height > 0 else { return }
        var laidOut = !forceNoGlyphsForTesting
        if laidOut {
            if let layout = textView.layoutManager, let container = textView.textContainer {
                layout.ensureLayout(for: container)
                laidOut = layout.numberOfGlyphs > 0 && !layout.usedRect(for: container).isEmpty
            } else {
                laidOut = false
            }
        }
        guard !laidOut else { return }
        displayFailed = true
        onDisplayFailed?()
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

    /// How many offsets must be covered: every character, plus one for a last line with no text.
    private var coverageTotal: Int {
        let length = textView.string.utf16.count
        guard let layout = textView.layoutManager, !layout.extraLineFragmentRect.isEmpty else { return length }
        return length + 1
    }

    /// Record the part of each line fragment that is on screen now.
    private func coverVisibleFragments() {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return }
        if abs(textView.frame.width - coverageWidth) > 0.5 {
            partlySeen.removeAll()
            coverageWidth = textView.frame.width
        }
        let clip = contentView.bounds
        // A view shorter than a line of text shows no line: nothing counts (and the 1 pt tolerance
        // below can't be chained across tiny slivers).
        guard clip.height >= Self.minimumCoveringHeight else { return }
        let origin = textView.textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRect: clip.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        if glyphs.length > 0 {
            layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, glyphRange, _ in
                let chars = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                self.noteSeen(chars, top: rect.minY + origin.y, bottom: rect.maxY + origin.y, clip: clip)
            }
        }
        let extra = layout.extraLineFragmentRect
        if !extra.isEmpty {
            noteSeen(NSRange(location: textView.string.utf16.count, length: 1),
                     top: extra.minY + origin.y, bottom: extra.maxY + origin.y, clip: clip)
        }
    }

    /// A fragment spanning `top ..< bottom` was in `clip`. Cover its characters once all of it has been.
    private func noteSeen(_ chars: NSRange, top: CGFloat, bottom: CGFloat, clip: NSRect) {
        guard chars.length > 0 else { return }
        let range = chars.location ..< NSMaxRange(chars)
        guard !coveredCharacters.contains(integersIn: range) else { return }
        let seenTop = max(top, clip.minY), seenBottom = min(bottom, clip.maxY)
        guard seenBottom > seenTop else { return }
        var spans = (partlySeen[chars] ?? []) + [seenTop ... seenBottom]
        spans.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<CGFloat>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound <= last.upperBound + Self.coverageTolerance {
                merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        if merged.count == 1, merged[0].lowerBound <= top + Self.coverageTolerance,
           merged[0].upperBound >= bottom - Self.coverageTolerance {
            coveredCharacters.insert(integersIn: range)
            partlySeen[chars] = nil
        } else {
            partlySeen[chars] = merged
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
        clipsToBounds = true
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// TEMPORARY (diagnostic): the last rect AppKit asked the gutter to draw.
    private(set) var lastDrawRect = NSRect.zero

    override func drawHashMarksAndLabels(in rect: NSRect) {
        lastDrawRect = rect
        // Only the gutter's own strip: `rect` can reach beyond it (over the text view's text).
        ApprovalPalette.inputBackground.setFill()
        rect.intersection(bounds).fill()
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
