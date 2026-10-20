import AppKit
import NostromoKit

// AP2a: the exact input of a permission request, as the card shows it.
//
// A non-editable, selectable, monospaced text view in its own scroll view. The line
// numbers are painted by the text view itself, in a gutter that is part of its own
// left inset (no NSRulerView: a ruler is a sibling of the clip view and can paint over
// the text; nothing here can overlap the text). It shows what `ApprovalDisplayModel` hands it and nothing
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
//
// Fail closed, twice. (1) A sized, on-screen layout of a model that has text must have
// glyphs (`displayFailed`, sticky). (2) A line fragment only counts as shown once it has
// been rendered (`cacheDisplay` of the scroll view, so anything painted over the text
// counts too) and the render holds glyph ink: pixels whose luma differs from the area's
// modal background by more than `ApprovalInkProbe.deltaThreshold`. A fragment that fails
// is not covered; after `maxInkFailures` failed evaluations in a row the card latches
// `displayFailed`.

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
/// every invisible character read by name (`ApprovalInputView.render`). It paints the line
/// numbers in the left part of its own inset, so they scroll with the text and can't overlap it.
final class ApprovalTextView: NSTextView {

    weak var gutterOwner: ApprovalInputView?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        NSColor.white.setFill(); NSRect(x: 0, y: 26, width: 4, height: 4).fill()  // TMP E4
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        gutterOwner?.gutterDiag += " draw(dirty=\(dirtyRect) owner=\(gutterOwner != nil))"  // TMP
        // TMP experiments: E1 bright rect unclipped; E2 white digit unclipped
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        NSString("8").draw(at: NSPoint(x: 9, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white])
        gutterOwner?.drawGutter(in: dirtyRect)
    }
}

final class ApprovalInputView: NSScrollView {

    let textView: ApprovalTextView
    /// True once every line has been fully visible (see `coveredCharacters`). Never goes back to false.
    private(set) var hasShownEveryLine = false
    /// Called once, when `hasShownEveryLine` becomes true.
    var onShownEveryLine: (() -> Void)?
    /// True once the text, though the model has some, could not be laid out or drawn: no glyphs or an
    /// empty used rect in a sized, on-screen layout, or `maxInkFailures` failed ink checks in a row.
    /// What is on screen can't be trusted to be the input, so the card must not offer Allow once.
    /// Never goes back to false, and is never set from a layout that has no size or isn't on screen.
    private(set) var displayFailed = false
    /// Called once, when `displayFailed` becomes true.
    var onDisplayFailed: (() -> Void)?
    #if DEBUG
    /// Tests only: treat the text layout as empty, as if no glyph had been laid out.
    var forceNoGlyphsForTesting = false
    #endif
    /// How many times the ink check has rendered the text area (once per coverage change).
    private(set) var inkCheckCount = 0
    /// Failed ink evaluations in a row; `maxInkFailures` of them latch `displayFailed`.
    private(set) var inkFailures = 0
    static let maxInkFailures = 3
    /// The width of the line-number gutter (the left part of the text view's inset).
    let gutterWidth: CGFloat
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
    /// Fragments that became covered during this evaluation, to be checked for ink (text-view coordinates).
    private var newlyCovered: [(chars: NSRange, top: CGFloat, bottom: CGFloat)] = []
    private var inkRecheckScheduled = false
    private var isUpdatingProgress = false
    var gutterDiag = ""  // TMP
    private var lastClipOriginY: CGFloat = 0
    private let font = Theme.codeFont(size: 12)
    private static let textInset = NSSize(width: 6, height: 6)
    private static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// A clip-origin change smaller than this (points) is layout settling, not a scroll.
    private static let scrollNoise: CGFloat = 2
    /// Spans of a line fragment that meet within this (points) count as one: scroll positions are pixel-snapped.
    private static let coverageTolerance: CGFloat = 1
    /// The clip view must be at least this tall (points) for what is in it to count as shown.
    private static let minimumCoveringHeight: CGFloat = 16

    init(model: ApprovalDisplayModel) {
        modelHasText = model.allLines.contains { line in line.runs.contains { !$0.text.isEmpty } }
        gutterWidth = Self.gutterWidth(forLineCount: max(1, model.allLines.count))
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
        // The gutter is the left part of the inset: the text starts after it, so nothing can overlap it.
        textView.textContainerInset = NSSize(width: gutterWidth + Self.textInset.width, height: Self.textInset.height)
        textView.gutterOwner = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.selectedTextAttributes = Theme.selectionAttributes
        let lineTotal = model.allLines.count
        textView.setAccessibilityLabel("Requested input, \(lineTotal) line\(lineTotal == 1 ? "" : "s")")
        documentView = textView

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

    /// The gutter's width for a model of `count` lines: room for the digits.
    static func gutterWidth(forLineCount count: Int) -> CGFloat {
        CGFloat(String(count).count) * 7 + 14
    }

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
        let textWidth = max(40, width - scroller - 2 * textView.textContainerInset.width)
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
        // Nothing is judged, or earned, until the card can really be seen at a size.
        // Lay the text out even when nobody can see it yet: the text view takes its height from that,
        // and the scroll range (and what is on screen once shown) depends on it. No verdict is drawn here.
        if !displayFailed, modelHasText, bounds.width > 0, bounds.height > 0,
           let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
        }
        guard !displayFailed, isShowingOnScreen, !isUpdatingProgress else { return }
        // `fitTextView` can resize the text view, which posts a frame change that lands back here:
        // that nested pass must not count a second evaluation (or a second failure).
        isUpdatingProgress = true
        defer { isUpdatingProgress = false }
        checkLayout()
        guard !displayFailed, !hasShownEveryLine, !ignoreProgressUntilPersonScrolls else { return }
        if textView.string.isEmpty { return markShownEveryLine() }
        guard contentView.bounds.height > 0, textView.frame.width > 0 else { return }
        fitTextView()
        newlyCovered.removeAll()
        coverVisibleFragments()
        verifyInk(ofNewlyCovered: newlyCovered)
        newlyCovered.removeAll()
        guard !displayFailed else { return }
        if coveredCharacters.contains(integersIn: 0 ..< coverageTotal) { markShownEveryLine() }
    }

    override func layout() {
        super.layout()
        updateScrollProgress()
    }

    // MARK: Fail closed

    /// A layout that can be judged: the view is on screen (the caller checked), the text view and
    /// its container have a width. A zero-width first layout is not a verdict.
    private var hasSizedLayout: Bool {
        textView.frame.width > 0 && (textView.textContainer?.containerSize.width ?? 0) > 0
    }

    /// A sized layout of a model that has text must have glyphs with a non-empty extent. If not,
    /// what a person would be asked to approve may not be on screen.
    private func checkLayout() {
        guard modelHasText, hasSizedLayout else { return }
        var laidOut = true
        #if DEBUG
        if forceNoGlyphsForTesting { laidOut = false }
        #endif
        if laidOut {
            if let layout = textView.layoutManager, let container = textView.textContainer {
                layout.ensureLayout(for: container)
                laidOut = layout.numberOfGlyphs > 0 && !layout.usedRect(for: container).isEmpty
            } else {
                laidOut = false
            }
        }
        if !laidOut { latchDisplayFailed() }
    }

    private func latchDisplayFailed() {
        guard !displayFailed else { return }
        displayFailed = true
        onDisplayFailed?()
    }

    /// The fragments that just became covered must show glyph ink in a render of the whole input
    /// view (so a sibling painting over the text is seen). One render per coverage change. A
    /// fragment that fails is un-covered (it will be judged again on the next evaluation) and
    /// `maxInkFailures` failures in a row latch `displayFailed`.
    private func verifyInk(ofNewlyCovered fragments: [(chars: NSRange, top: CGFloat, bottom: CGFloat)]) {
        guard !fragments.isEmpty else { return }
        let text = (textView.textStorage?.string ?? "") as NSString
        let expected = fragments.reduce(0) { $0 + ApprovalInkProbe.visibleCharacterCount(in: text, range: $1.chars) }
        // Nothing but whitespace to see: nothing to demand.
        guard expected > 0 else {
            inkFailures = 0
            return
        }
        let top = fragments.map(\.top).min() ?? 0, bottom = fragments.map(\.bottom).max() ?? 0
        inkCheckCount += 1
        if inkAreaShowsText(top: top, bottom: bottom, expected: expected) {
            inkFailures = 0
            return
        }
        for fragment in fragments {
            coveredCharacters.remove(integersIn: fragment.chars.location ..< NSMaxRange(fragment.chars))
        }
        inkFailures += 1
        if inkFailures >= Self.maxInkFailures {
            latchDisplayFailed()
        } else {
            scheduleInkRecheck()
        }
    }

    /// Render the text area (right of the gutter) of the rows `top ..< bottom` (text-view coordinates)
    /// and look for ink. The render is of this view, so everything painted over the text counts.
    private func inkAreaShowsText(top: CGFloat, bottom: CGFloat, expected: Int) -> Bool {
        let visible = textView.visibleRect
        let area = NSRect(x: gutterWidth, y: top, width: visible.maxX - gutterWidth, height: bottom - top).intersection(visible)
        guard !area.isNull else { return false }
        let rect = convert(area, from: textView).integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1,
              let rep = bitmapImageRepForCachingDisplay(in: rect) else { return false }
        cacheDisplay(in: rect, to: rep)
        return ApprovalInkProbe.hasInk(in: rep, atLeast: min(ApprovalInkProbe.inkCeiling, expected))
    }

    /// A failed evaluation may be a layout that hasn't settled: look again on the next turn of the
    /// run loop (once at a time). The failure count bounds this.
    private func scheduleInkRecheck() {
        guard !inkRecheckScheduled else { return }
        inkRecheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inkRecheckScheduled = false
            self.updateScrollProgress()
        }
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
            newlyCovered.append((chars: chars, top: top, bottom: bottom))
            partlySeen[chars] = nil
        } else {
            partlySeen[chars] = merged
        }
    }

    // MARK: Drawing support (the gutter)

    /// Paint the line numbers in the gutter strip of the text view (called from its `draw`, in its
    /// coordinates). Only the strip is touched: the fill and the digits are clipped to it.
    fileprivate func drawGutter(in dirty: NSRect) {
        let strip = NSRect(x: 0, y: dirty.minY, width: gutterWidth, height: dirty.height)
        gutterDiag += " drawGutter(lines=\(lineNumbers.count) top0=\(String(describing: lineTop(at: 0))) gutter=\(gutterWidth))"  // TMP
        guard dirty.minX < gutterWidth, strip.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        strip.clip()
        ApprovalPalette.inputBackground.setFill()
        strip.fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.gutterFont, .foregroundColor: ApprovalPalette.gutterText]
        for index in lineNumbers.indices {
            guard let top = lineTop(at: index) else { continue }
            if top > dirty.maxY { break }
            if top + 16 < dirty.minY { continue }
            let label = NSAttributedString(string: String(lineNumbers[index]), attributes: attrs)
            label.draw(at: NSPoint(x: gutterWidth - label.size().width - 6, y: top + 2))
        }
    }

    /// The top of display line `index` in text-view coordinates, or nil before layout.
    private func lineTop(at index: Int) -> CGFloat? {
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

// MARK: - Ink probe

/// Looking for glyph ink in a rendering of the text area. Ink is a pixel whose luma differs from the
/// area's modal background by more than `deltaThreshold` (of 255): a luma DELTA, not an absolute colour,
/// so muted tokens count and a here-doc's fill (luma about 23 from the input background) does not.
enum ApprovalInkProbe {

    static let deltaThreshold = 60.0
    /// The most ink ever demanded: enough that a rendering of real text can't miss it, few enough that
    /// one short token passes.
    static let inkCeiling = 40

    /// How many characters in `range` of `text` are meant to draw a mark (not whitespace, control or format).
    static func visibleCharacterCount(in text: NSString, range: NSRange) -> Int {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
        guard r.length > 0 else { return 0 }
        let invisible: Set<Unicode.GeneralCategory> = [.spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format,
                                                       .nonspacingMark, .enclosingMark]
        return text.substring(with: r).unicodeScalars.reduce(0) { count, scalar in
            invisible.contains(scalar.properties.generalCategory) ? count : count + 1
        }
    }

    /// True when `rep` holds at least `minimum` ink pixels. The modal background is taken from a sparse
    /// sample, then the pixels are scanned until enough ink is found (a normal rendering stops early).
    static func hasInk(in rep: NSBitmapImageRep, atLeast minimum: Int) -> Bool {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard minimum > 0, width > 0, height > 0 else { return false }
        let direct = rep.bitmapData != nil && !rep.isPlanar && rep.bitsPerSample == 8 && rep.samplesPerPixel >= 3
            && !rep.bitmapFormat.contains(.floatingPointSamples)
        let bytesPerPixel = rep.bitsPerPixel / 8
        let colourOffset = rep.hasAlpha && rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
        let raw = rep.bitmapData

        func luma(_ x: Int, _ y: Int) -> Double? {
            if direct, let raw {
                let p = raw + y * rep.bytesPerRow + x * bytesPerPixel + colourOffset
                return 0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])
            }
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return 255 * (0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent))
        }

        var histogram = [Int](repeating: 0, count: 256)
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                if let value = luma(x, y) { histogram[min(255, max(0, Int(value.rounded())))] += 1 }
            }
        }
        guard let modal = histogram.indices.max(by: { histogram[$0] < histogram[$1] }), histogram[modal] > 0 else { return false }
        let background = Double(modal)

        var ink = 0
        for y in 0 ..< height {
            for x in 0 ..< width {
                guard let value = luma(x, y), abs(value - background) > deltaThreshold else { continue }
                ink += 1
                if ink >= minimum { return true }
            }
        }
        return false
    }
}
