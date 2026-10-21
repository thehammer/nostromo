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
// counts too) and the render holds glyph ink in EVERY horizontal chunk of it that has
// text (about 8 characters each): pixels whose luma differs from the area's modal
// background by more than `ApprovalInkProbe.deltaThreshold`. A fragment that fails is not
// covered; `maxInkFailures` failed evaluations, at least `failureSettleWindow` apart,
// latch `displayFailed`. A fragment completed from several partial views is judged on
// the ink of all of them, when it completes.
//
// What the ink check does NOT cover: `cacheDisplay` runs the view's own draw path, not the
// window server's compositor. A CALayer- or compositor-level overpaint is invisible to it.

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

    /// The numbers go on the background pass, before the text: on CI, anything drawn in the inset after
    /// `super.draw` (clipped or not, any colour or font) never reached the bitmap; on the background pass
    /// it does. The cause was not identified.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        gutterOwner?.drawGutter(in: rect)
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
    /// Counted ink failures in a row; `maxInkFailures` of them latch `displayFailed`. A failure is
    /// counted at most once per `failureSettleWindow`: many failing passes in one turn of the run loop
    /// (a resize storm, a card re-parented mid-animation) are one unsettled layout, not three verdicts.
    private(set) var inkFailures = 0
    static let maxInkFailures = 3
    /// Failed evaluations closer together than this (seconds) count as one.
    static let failureSettleWindow: TimeInterval = 0.15
    /// The time failures are spaced by. A test replaces it.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastCountedFailureAt: TimeInterval?
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
    /// each that have been on screen, and the ink found in each chunk of it in those views. A fragment
    /// is covered once its spans add up to all of it and its chunks have ink.
    private var partlySeen: [NSRange: PartialView] = [:]
    /// The text view's width when `partlySeen` was recorded; a re-wrap invalidates it.
    private var coverageWidth: CGFloat = 0
    #if DEBUG
    /// Tests only: replaces the window half of "is this on screen?" (a visible, not occluded window). The
    /// rest (in a window, not hidden, not zero-sized) always applies. Not in release builds: it could
    /// only ever make a card easier to read through.
    var isWindowShowing: (() -> Bool)?
    #endif
    private var inkRecheckScheduled = false
    private var isUpdatingProgress = false
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
    /// A line fragment is judged in chunks of about this many characters.
    private static let chunkCharacters = 8
    /// A chunk must show this many bright pixels (at 1x) for each character that draws, at most `inkPerChunk`.
    private static let inkPerMark = 2
    private static let inkPerChunk = 12

    /// A run of a line fragment's characters, and where it is laid out (text-view x).
    private struct InkChunk {
        let minX: CGFloat
        let maxX: CGFloat
        /// How many of its characters draw a mark (not whitespace, control or format).
        let marks: Int
    }

    /// A line fragment to judge: its rows (text-view y) and its chunks.
    private struct JudgedFragment {
        let chars: NSRange
        let top: CGFloat
        let bottom: CGFloat
        let chunks: [InkChunk]
    }

    /// What one evaluation saw of a fragment that has something to judge.
    private struct Sighting {
        let fragment: JudgedFragment
        /// The rows of it (text-view y) that are on screen now and were not before: the ones to count ink in.
        let rows: [ClosedRange<CGFloat>]
        /// Every span of it seen so far, this one included.
        let spans: [ClosedRange<CGFloat>]
        /// All of it is on screen now.
        let isWhole: Bool
        /// Its spans add up to all of it.
        let completes: Bool
    }

    /// A fragment seen in part: the spans so far and the ink in each chunk in them.
    private struct PartialView {
        let spans: [ClosedRange<CGFloat>]
        let ink: [Int]
    }

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
        #if DEBUG
        if let isWindowShowing { return isWindowShowing() }
        #endif
        return window.isVisible && window.occlusionState.contains(.visible)
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
        judgeInk(of: coverVisibleFragments())
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

    /// A fragment seen this pass is judged for glyph ink in each horizontal chunk, in one render of the
    /// whole input view (so a sibling painting over the text is seen), on its own row band (ink in one
    /// row can't vouch for a blank one). One render per coverage change. A whole-on-screen fragment is
    /// judged now; one that is only part on screen adds what each view shows to what its earlier views
    /// showed, and is judged when its views add up to all of it. A fragment that fails stays un-covered
    /// (it is judged again on the next evaluation). Failures are counted at most once per settle window.
    private func judgeInk(of sightings: [Sighting]) {
        guard !sightings.isEmpty else {
            if partlySeen.isEmpty { resetInkFailures() }
            return
        }
        inkCheckCount += 1
        let rows = sightings.flatMap(\.rows)
        let render = renderInkArea(top: rows.map(\.lowerBound).min() ?? 0, bottom: rows.map(\.upperBound).max() ?? 0)
        var judged = false, failed = false
        for sighting in sightings {
            let fragment = sighting.fragment
            let required = fragment.chunks.map { requiredInk(forMarks: $0.marks, in: render) }
            let found = render.flatMap { inkCounts(of: fragment, rows: sighting.rows, required: required, in: $0) }
            let earlier = sighting.isWhole ? [] : partlySeen[fragment.chars]?.ink ?? []
            let total = found.map { counts in counts.indices.map { counts[$0] + (earlier.indices.contains($0) ? earlier[$0] : 0) } }
            if sighting.isWhole || sighting.completes {
                partlySeen[fragment.chars] = nil
                if let total, zip(total, required).allSatisfy({ $0 >= $1 }) {
                    judged = true
                    coveredCharacters.insert(integersIn: fragment.chars.location ..< NSMaxRange(fragment.chars))
                } else {
                    failed = true
                }
            } else if let total {
                partlySeen[fragment.chars] = PartialView(spans: sighting.spans, ink: total)
            } else {
                failed = true
            }
        }
        // A pass resets the count. So does an evaluation with nothing left to judge. A view that only added
        // to a fragment's partial views is neither.
        if failed { recordInkFailure() } else if judged { resetInkFailures() }
    }

    private func resetInkFailures() {
        inkFailures = 0
        lastCountedFailureAt = nil
    }

    /// A failed evaluation. Count it unless one was counted within the settle window; either way look again.
    private func recordInkFailure() {
        scheduleInkRecheck()
        let now = clock()
        if let last = lastCountedFailureAt, now - last < Self.failureSettleWindow { return }
        lastCountedFailureAt = now
        inkFailures += 1
        if inkFailures >= Self.maxInkFailures { latchDisplayFailed() }
    }

    /// The text area (right of the gutter) of the rows `top ..< bottom` (text-view coordinates), in this view's coordinates.
    private func textArea(top: CGFloat, bottom: CGFloat) -> NSRect {
        let visible = textView.visibleRect
        let area = NSRect(x: gutterWidth, y: top, width: visible.maxX - gutterWidth, height: bottom - top).intersection(visible)
        return area.isNull ? .null : convert(area, from: textView)
    }

    /// One render of this view over the text area of the rows `top ..< bottom` (nil if it can't be made).
    private func renderInkArea(top: CGFloat, bottom: CGFloat) -> (rep: NSBitmapImageRep, rect: NSRect)? {
        let area = textArea(top: top, bottom: bottom)
        guard !area.isNull else { return nil }
        let rect = area.integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let rep = bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        cacheDisplay(in: rect, to: rep)
        return (rep, rect)
    }

    /// The bright pixels a chunk with `marks` characters that draw must show: about a glyph's worth each
    /// (a few for a short one, a dozen for a full chunk), in pixels, so more at 2x.
    private func requiredInk(forMarks marks: Int, in render: (rep: NSBitmapImageRep, rect: NSRect)?) -> Int {
        guard marks > 0 else { return 0 }
        let scale = render.map { CGFloat($0.rep.pixelsHigh) / max(1, $0.rect.height) } ?? 1
        return max(1, Int((CGFloat(min(Self.inkPerChunk, Self.inkPerMark * marks)) * scale * scale).rounded()))
    }

    /// The ink in each chunk of `fragment`, over `rows` (text-view y spans), at most `required` per chunk.
    /// Nil if the render can't be read.
    private func inkCounts(of fragment: JudgedFragment, rows: [ClosedRange<CGFloat>], required: [Int],
                           in render: (rep: NSBitmapImageRep, rect: NSRect)) -> [Int]? {
        guard render.rect.height > 0, render.rect.width > 0 else { return nil }
        let scale = CGFloat(render.rep.pixelsHigh) / render.rect.height
        let scaleX = CGFloat(render.rep.pixelsWide) / render.rect.width
        var counts = [Int](repeating: 0, count: fragment.chunks.count)
        for row in rows {
            let band = textArea(top: row.lowerBound, bottom: row.upperBound)
            guard !band.isNull else { continue }
            let offset = isFlipped ? band.minY - render.rect.minY : render.rect.maxY - band.maxY
            let first = max(0, Int((offset * scale).rounded(.down)))
            let last = min(render.rep.pixelsHigh, Int(((offset + band.height) * scale).rounded(.up)))
            guard last > first else { continue }
            let columns: [Range<Int>] = fragment.chunks.map { chunk in
                let span = convert(NSRect(x: chunk.minX, y: row.lowerBound, width: chunk.maxX - chunk.minX, height: 1), from: textView)
                let lower = max(0, Int(((span.minX - render.rect.minX) * scaleX).rounded(.down)))
                let upper = min(render.rep.pixelsWide, Int(((span.maxX - render.rect.minX) * scaleX).rounded(.up)))
                return lower ..< max(lower, upper)
            }
            let limits = zip(required, counts).map { max(0, $0 - $1) }
            guard let found = ApprovalInkProbe.inkCounts(in: render.rep, rows: first ..< last, columns: columns, limits: limits) else { return nil }
            for i in counts.indices { counts[i] += found[i] }
        }
        return counts
    }

    /// A failed evaluation may be a layout that hasn't settled: look again once the settle window has
    /// passed, so the next failure is a separate one (once at a time). The failure count bounds this.
    private func scheduleInkRecheck() {
        guard !inkRecheckScheduled else { return }
        inkRecheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.failureSettleWindow + 0.02) { [weak self] in
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

    /// Record the part of each line fragment that is on screen now. Returns what there is to judge for ink.
    private func coverVisibleFragments() -> [Sighting] {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return [] }
        if abs(textView.frame.width - coverageWidth) > 0.5 {
            partlySeen.removeAll()
            coverageWidth = textView.frame.width
        }
        let clip = contentView.bounds
        // A view shorter than a line of text shows no line: nothing counts (and the 1 pt tolerance
        // below can't be chained across tiny slivers).
        guard clip.height >= Self.minimumCoveringHeight else { return [] }
        let origin = textView.textContainerOrigin
        var sightings: [Sighting] = []
        let glyphs = layout.glyphRange(forBoundingRect: clip.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        if glyphs.length > 0 {
            layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, glyphRange, _ in
                let chars = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                self.noteSeen(chars, top: rect.minY + origin.y, bottom: rect.maxY + origin.y, usedWidth: used.minX ... used.maxX,
                              clip: clip, into: &sightings)
            }
        }
        let extra = layout.extraLineFragmentRect
        if !extra.isEmpty {
            noteSeen(NSRange(location: textView.string.utf16.count, length: 1),
                     top: extra.minY + origin.y, bottom: extra.maxY + origin.y, usedWidth: 0 ... 0, clip: clip, into: &sightings)
        }
        return sightings
    }

    /// A fragment spanning `top ..< bottom` was in `clip`. Cover its characters once all of it has been, and
    /// the ink in it has been judged (a fragment with nothing that draws is covered without a judgement).
    private func noteSeen(_ chars: NSRange, top: CGFloat, bottom: CGFloat, usedWidth: ClosedRange<CGFloat>,
                          clip: NSRect, into sightings: inout [Sighting]) {
        guard chars.length > 0 else { return }
        let range = chars.location ..< NSMaxRange(chars)
        guard !coveredCharacters.contains(integersIn: range) else { return }
        let seenTop = max(top, clip.minY), seenBottom = min(bottom, clip.maxY)
        guard seenBottom > seenTop else { return }
        let before = partlySeen[chars]?.spans ?? []
        let spans = Self.merge(before + [seenTop ... seenBottom])
        let completes = spans.count == 1 && spans[0].lowerBound <= top + Self.coverageTolerance
            && spans[0].upperBound >= bottom - Self.coverageTolerance
        let fragment = judgedFragment(chars, top: top, bottom: bottom, usedWidth: usedWidth)
        guard fragment.chunks.contains(where: { $0.marks > 0 }) else {
            if completes {
                coveredCharacters.insert(integersIn: range)
                partlySeen[chars] = nil
            } else {
                partlySeen[chars] = PartialView(spans: spans, ink: [])
            }
            return
        }
        let isWhole = seenTop <= top + Self.coverageTolerance && seenBottom >= bottom - Self.coverageTolerance
        let rows = isWhole ? [top ... bottom] : Self.subtract(seenTop ... seenBottom, from: before)
        guard !rows.isEmpty else { return }
        sightings.append(Sighting(fragment: fragment, rows: rows, spans: spans, isWhole: isWhole, completes: completes))
    }

    /// `fragment`'s characters cut into chunks of about `Self.chunkCharacters`, each with where its glyphs
    /// are laid out (text-view x, within the fragment's used width) and how many of its characters draw.
    private func judgedFragment(_ chars: NSRange, top: CGFloat, bottom: CGFloat, usedWidth: ClosedRange<CGFloat>) -> JudgedFragment {
        let text = (textView.textStorage?.string ?? "") as NSString
        guard let layout = textView.layoutManager, chars.location < text.length else {
            return JudgedFragment(chars: chars, top: top, bottom: bottom, chunks: [])
        }
        let limit = min(NSMaxRange(chars), text.length)
        let length = limit - chars.location
        let count = max(1, length / Self.chunkCharacters)
        let originX = textView.textContainerOrigin.x
        var starts: [Int] = []
        for i in 0 ..< count {
            let raw = chars.location + i * length / count
            let start = i == 0 ? chars.location : max(starts[i - 1], text.rangeOfComposedCharacterSequence(at: raw).location)
            starts.append(start)
        }
        // Where each chunk starts, from the glyph positions (the fragment's own text, whatever the fonts).
        func x(ofCharacter offset: Int) -> CGFloat {
            let glyph = layout.glyphIndexForCharacter(at: offset)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return rect.minX + layout.location(forGlyphAt: glyph).x
        }
        var chunks: [InkChunk] = []
        for i in starts.indices {
            let end = i + 1 < starts.count ? starts[i + 1] : limit
            guard end > starts[i] else { continue }
            let range = NSRange(location: starts[i], length: end - starts[i])
            let lower = min(max(usedWidth.lowerBound, x(ofCharacter: starts[i])), usedWidth.upperBound)
            let upper = i + 1 < starts.count ? min(max(lower, x(ofCharacter: starts[i + 1])), usedWidth.upperBound) : usedWidth.upperBound
            chunks.append(InkChunk(minX: lower + originX, maxX: upper + originX,
                                   marks: ApprovalInkProbe.visibleCharacterCount(in: text, range: range)))
        }
        return JudgedFragment(chars: chars, top: top, bottom: bottom, chunks: chunks)
    }

    /// Spans that meet within `coverageTolerance` are one.
    private static func merge(_ input: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var merged: [ClosedRange<CGFloat>] = []
        for span in input.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, span.lowerBound <= last.upperBound + coverageTolerance {
                merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, span.upperBound)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// The parts of `span` that none of `seen` covers.
    private static func subtract(_ span: ClosedRange<CGFloat>, from seen: [ClosedRange<CGFloat>]) -> [ClosedRange<CGFloat>] {
        var rest = [span]
        for old in seen {
            rest = rest.flatMap { piece -> [ClosedRange<CGFloat>] in
                guard old.lowerBound < piece.upperBound, old.upperBound > piece.lowerBound else { return [piece] }
                var parts: [ClosedRange<CGFloat>] = []
                if piece.lowerBound < old.lowerBound { parts.append(piece.lowerBound ... old.lowerBound) }
                if old.upperBound < piece.upperBound { parts.append(old.upperBound ... piece.upperBound) }
                return parts
            }
        }
        return rest.filter { $0.upperBound - $0.lowerBound > 0.5 }
    }

    // MARK: Drawing support (the gutter)

    /// Paint the line numbers in the gutter strip of the text view (called from its `drawBackground`,
    /// in its coordinates, after it has painted its background). The numbers are right-aligned in the
    /// strip, which is part of the inset: they can't reach the text.
    fileprivate func drawGutter(in dirty: NSRect) {
        guard dirty.minX < gutterWidth, dirty.height > 0 else { return }
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

    /// How many ink pixels each column range of `rep` holds within `rows`, counting no further than its limit
    /// (a range with limit 0 is skipped). The modal background is taken from a sparse sample of all the
    /// columns of those rows, then each range is scanned until it has enough ink (a normal rendering stops
    /// early). Nil when the bitmap can't be read.
    static func inkCounts(in rep: NSBitmapImageRep, rows: Range<Int>, columns: [Range<Int>], limits: [Int]) -> [Int]? {
        let width = rep.pixelsWide
        let rows = max(0, rows.lowerBound) ..< min(rep.pixelsHigh, rows.upperBound)
        guard width > 0, !rows.isEmpty, columns.count == limits.count else { return nil }
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
        for y in stride(from: rows.lowerBound, to: rows.upperBound, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                if let value = luma(x, y) { histogram[min(255, max(0, Int(value.rounded())))] += 1 }
            }
        }
        guard let modal = histogram.indices.max(by: { histogram[$0] < histogram[$1] }), histogram[modal] > 0 else { return nil }
        let background = Double(modal)

        var counts = [Int](repeating: 0, count: columns.count)
        for (i, range) in columns.enumerated() where limits[i] > 0 {
            let xs = max(0, range.lowerBound) ..< min(width, range.upperBound)
            scan: for y in rows {
                for x in xs {
                    guard let value = luma(x, y), abs(value - background) > deltaThreshold else { continue }
                    counts[i] += 1
                    if counts[i] >= limits[i] { break scan }
                }
            }
        }
        return counts
    }
}
