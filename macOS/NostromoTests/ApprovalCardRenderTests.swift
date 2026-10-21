import XCTest
import AppKit
import NostromoKit

// AP2a: the approval card's command text must actually be DRAWN, and when it cannot be the card
// must refuse to be allowed.
//
// The bug: in the real app the line-number gutter draws but the command text area is blank (zero
// glyph pixels) while the model string is present. `hasShownEveryLine` counts line fragments, not
// glyphs, so Allow once could be enabled over a blank input. A person must never approve text
// they were not shown.
//
// Contracts:
//   * `ApprovalCardRenderTests`: render the input view into a bitmap (at 1 and 2 pixels per point)
//     and count pixels that are clearly not the modal background: in the text area, and in the
//     line-number gutter (painted by the text view itself, there is no ruler view). Every fixture
//     must draw ink, in the full card (at the app's width) and in a bare input view, scrolled to the
//     top, middle and end, and after a resize.
//   * `ApprovalCardFailClosedTests`: a card whose input has text but whose layout has no glyphs
//     (`ApprovalInputView.displayFailed`) can only be denied, and says so in its banner without
//     losing the warnings it had. The seam `ApprovalInputView.forceNoGlyphsForTesting` makes the
//     check treat the layout as empty.
//   * `ApprovalInputViewLatchRulesTests`: `displayFailed` is only judged for a sized layout that is on
//     screen, and is final once given.
//   * `ApprovalInkCheckTests`: a line only counts as shown once a render of it holds glyph ink. Text
//     covered by something else (an overpaint) is never counted, repeated failures latch
//     `displayFailed`, one transient failure does not, blank rows demand no ink, and the check
//     renders once per coverage change, not once per look.
//   * `ApprovalInkFailureCountingTests`: failures are counted once per settle window of an injected
//     clock, so a burst of failing passes in one turn of the run loop is one failure, not three.
//   * `ApprovalInkChunkTests`: a long single line is judged in horizontal chunks: hiding only its
//     head, middle or tail keeps Allow off, a run of spaces is not a false failure, and a wrapped
//     line's continuation is judged too.
//   * `ApprovalPartialViewCoverageTests`: a line that can only be completed from partial views (a
//     clip shorter than two lines, awkward steps) is judged on the ink of those views: a blank text
//     area cannot be walked past with such steps.
//
// No wall clock, no pasteboard, no network, no ~/.nostromo.

// MARK: - Counting ink

/// What a bitmap of the input view holds: ink in the text area, and ink in the line-number gutter.
private struct InkCount {
    /// Pixels in the whole text area (the clip view, right of the gutter) that differ from the modal background.
    let total: Int
    /// The same, for the top 20 pt of the text area: the first line.
    let firstLineBand: Int
    /// Pixels per point in the bitmap.
    let scale: CGFloat
    /// The text area, in pixels.
    let width: Int
    let height: Int
    /// Ink pixels in the gutter strip (the left `gutterWidth` points of the clip view): the line numbers.
    let gutterInk: Int
    /// How many separate numbers the gutter holds: runs of ink rows, runs closer than 3 pt count as one.
    let gutterBands: Int
}

private enum InkCounter {

    /// How far (of 255, in luma) a pixel must be from the modal background to count as ink.
    ///
    /// Why this is safe for here-doc bodies: a here-doc line has a `heredocFill` background
    /// (`Theme.codeBlockBackground`, white 0.16, luma about 41) that is NOT text. It is about 23 away
    /// from the modal background (white 0.07, luma about 18), so it stays under the threshold and is
    /// not counted as ink; `testNoFillTheCardPaintsBehindTextCountsAsInk` pins that, so the counts
    /// cannot be inflated by a fill alone. Ink is text on a fill or on the background: command text
    /// is Theme.fg (luma 220), the dimmest token colour is well above 100.
    static let threshold = 60.0

    /// Two ink runs in the gutter closer than this (points) are one number (a digit has thin strokes).
    static let bandMergeGap: CGFloat = 3

    static func luma(_ color: NSColor) -> Double {
        let c = ApprovalTestColors.rgb(color)
        return 255 * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
    }

    static func luma(r: Double, g: Double, b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// A bitmap of `view`. With a `scale` it is a bitmap of exactly that many pixels per point (a
    /// retina bitmap is twice the points), whatever the screen the test runs on; without one it is
    /// the one AppKit makes for the view's window.
    static func render(_ view: NSView, scale: CGFloat?) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let rep: NSBitmapImageRep?
        if let scale {
            rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int((bounds.width * scale).rounded()),
                                   pixelsHigh: Int((bounds.height * scale).rounded()),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            rep?.size = bounds.size
        } else {
            rep = view.bitmapImageRepForCachingDisplay(in: bounds)
        }
        guard let rep else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    /// Render `view` and count the ink in its text area (its clip view without the gutter) and in its
    /// gutter. Does not touch the text view's layout manager.
    static func count(in view: ApprovalInputView, scale requested: CGFloat? = nil) -> InkCount? {
        let bounds = view.bounds
        guard let rep = render(view, scale: requested) else { return nil }

        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let clip = view.contentView.frame   // in the input view's coordinates
        // A bitmap's first row is the top of the picture whatever the view's flippedness is.
        let topOffset = view.isFlipped ? clip.minY - bounds.minY : bounds.maxY - clip.maxY
        // The gutter is the left part of the text view's inset: the text area starts where it ends, so
        // the gutter's own digits are not counted as text.
        let gutterMinX = clip.minX
        let textMinX = clip.minX + view.gutterWidth
        let gx0 = max(0, Int(((gutterMinX - bounds.minX) * scale).rounded()))
        let x0 = max(0, Int(((textMinX - bounds.minX) * scale).rounded()))
        let gx1 = min(rep.pixelsWide, x0)
        let y0 = max(0, Int((topOffset * scale).rounded()))
        let x1 = min(rep.pixelsWide, Int(((clip.maxX - bounds.minX) * scale).rounded()))
        let y1 = min(rep.pixelsHigh, y0 + Int((clip.height * scale).rounded()))
        guard x1 > x0, y1 > y0 else { return nil }
        let bandEnd = min(y1, y0 + Int((20 * scale).rounded()))

        let background = luma(ApprovalPalette.inputBackground)
        let raw = rep.bitmapData
        let direct = raw != nil && !rep.isPlanar && rep.bitsPerSample == 8 && rep.samplesPerPixel >= 3
            && !rep.bitmapFormat.contains(.floatingPointSamples)
        let bytesPerPixel = rep.bitsPerPixel / 8
        let colourOffset = rep.hasAlpha && rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0

        func isInk(_ x: Int, _ y: Int) -> Bool {
            let value: Double
            if direct, let raw {
                let p = raw + y * rep.bytesPerRow + x * bytesPerPixel + colourOffset
                value = luma(r: Double(p[0]), g: Double(p[1]), b: Double(p[2]))
            } else if let c = rep.colorAt(x: x, y: y) {
                value = luma(c)
            } else {
                return false
            }
            return abs(value - background) > threshold
        }

        var total = 0, band = 0, gutterInk = 0
        var gutterRows: [Int] = []
        for y in y0 ..< y1 {
            var rowHasGutterInk = false
            if gx1 > gx0 {
                for x in gx0 ..< gx1 where isInk(x, y) {
                    gutterInk += 1
                    rowHasGutterInk = true
                }
            }
            if rowHasGutterInk { gutterRows.append(y) }
            for x in x0 ..< x1 where isInk(x, y) {
                total += 1
                if y < bandEnd { band += 1 }
            }
        }
        let mergeGap = Int((bandMergeGap * scale).rounded())
        var bands = 0
        var previous: Int?
        for row in gutterRows {
            if let previous, row - previous - 1 <= mergeGap {} else { bands += 1 }
            previous = row
        }
        return InkCount(total: total, firstLineBand: band, scale: scale, width: x1 - x0, height: y1 - y0,
                        gutterInk: gutterInk, gutterBands: bands)
    }
}

// MARK: - The fixtures

private enum RenderFixture: CaseIterable {
    case singleLine, twelveLines, heredoc300, bidi

    var name: String {
        switch self {
        case .singleLine: return "single_line"
        case .twelveLines: return "twelve_lines"
        case .heredoc300: return "heredoc_300"
        case .bidi: return "bidi"
        }
    }

    func request() throws -> ApprovalRequestWire {
        switch self {
        case .singleLine: return try ApprovalTestRequests.bash("rm -rf /tmp/x/a")
        case .twelveLines: return try ApprovalTestRequests.shortLines(12)
        case .heredoc300: return try ApprovalTestRequests.heredoc300()
        case .bidi: return try ApprovalTestRequests.bidi()
        }
    }

    /// The height of a bare input view for this fixture.
    var bareHeight: CGFloat {
        switch self {
        case .singleLine, .bidi: return 30
        case .twelveLines: return 200
        case .heredoc300: return 320
        }
    }

    /// The most height the card gives its input.
    var cardMaxHeight: CGFloat { 400 }
}

private enum RenderMode: String {
    /// The whole `ApprovalCardView`, laid out by the harness at the app's card width.
    case card
    /// A bare `ApprovalInputView` in an offscreen window, as nothing else than a scroll view.
    case bare
    /// The same, with the "window is showing" check answered yes (the card's own tests do this),
    /// so `layout()` takes the path a visible window takes (it reads the text layout).
    case bareOnScreen = "bare_on_screen"
}

/// What one fixture rendered as, with a one-line description for assertion messages.
private struct Measurement {
    let fixture: RenderFixture
    let ink: InkCount
    let detail: String
}

// MARK: - Pixels

/// A fixture laid out in a mode: the input view, and how to resize what holds it.
private final class RenderSubject {
    let view: ApprovalInputView
    private let resizer: (CGFloat) -> Void

    init(view: ApprovalInputView, resizer: @escaping (CGFloat) -> Void) {
        self.view = view
        self.resizer = resizer
    }

    /// Give the card (or the bare input view) this width and lay it out again.
    func resize(toWidth width: CGFloat) { resizer(width) }
}

final class ApprovalCardRenderTests: XCTestCase {

    /// The width of the approvals card in the app.
    private static let appCardWidth: CGFloat = 1514

    /// The two densities every drawing test runs at: a plain bitmap and a retina one.
    private static let scales: [CGFloat] = [1.0, 2.0]

    private func makeSubject(_ fixture: RenderFixture, in mode: RenderMode, height: CGFloat? = nil) throws -> RenderSubject {
        let request = try fixture.request()
        let bareHeight = height ?? fixture.bareHeight
        switch mode {
        case .card:
            let h = ApprovalCardHarness(self, request: request, width: Self.appCardWidth, maxHeight: fixture.cardMaxHeight)
            return RenderSubject(view: h.card.inputView, resizer: { width in
                let height = h.card.preferredHeight(forWidth: width, maxHeight: fixture.cardMaxHeight)
                h.card.frame = NSRect(x: 20, y: 20, width: width, height: height)
                h.window.contentView!.layoutSubtreeIfNeeded()
                h.card.layoutSubtreeIfNeeded()
            })
        case .bare, .bareOnScreen:
            let window = makeRigWindow(self, size: NSSize(width: Self.appCardWidth, height: bareHeight),
                                       appearance: NSAppearance(named: .darkAqua))
            let view = ApprovalInputView(model: ApprovalDisplayModel(request: request))
            if mode == .bareOnScreen { view.isWindowShowing = { true } }
            view.frame = NSRect(x: 0, y: 0, width: Self.appCardWidth, height: bareHeight)
            window.contentView!.addSubview(view)
            window.contentView!.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
            return RenderSubject(view: view, resizer: { width in
                view.frame = NSRect(x: 0, y: 0, width: width, height: bareHeight)
                window.contentView!.layoutSubtreeIfNeeded()
                view.layoutSubtreeIfNeeded()
            })
        }
    }

    /// Lay out `fixture` in `mode`, render its text area (at `scale` pixels per point, or the window's own)
    /// and describe what happened.
    ///
    /// Order matters, because `textView.layoutManager` forces a fallback from TextKit 2 to TextKit 1
    /// (and the card's own code already does that on its way, see below):
    ///   1. read `textLayoutManager != nil` (`tk2BeforeRender`), before this test touches `layoutManager`;
    ///   2. render the pixels (the text view paints its own gutter in `draw`, which reads `layoutManager`,
    ///      so a bare view can fall back DURING the render; `tk2AfterRender` shows whether it did);
    ///   3. only then read `layoutManager`, the glyph count and the used rect.
    /// The card path has already touched `layoutManager` in `layout()` before step 1: the card's
    /// input marks lines as shown (`updateScrollProgress`) through it as soon as it is in a visible
    /// window. `tk2BeforeRender` is therefore a statement about the state AFTER layout.
    private func measure(_ fixture: RenderFixture, in mode: RenderMode, scale requested: CGFloat? = nil) throws -> Measurement {
        let view = try makeSubject(fixture, in: mode).view

        let tk2BeforeRender = view.textView.textLayoutManager != nil
        let rendered = InkCounter.count(in: view, scale: requested)
        let tk2AfterRender = view.textView.textLayoutManager != nil

        // Only now is the text view's layout manager touched.
        let textView = view.textView
        let layout = textView.layoutManager
        let glyphs = layout?.numberOfGlyphs ?? -1
        let used = textView.textContainer.flatMap { layout?.usedRect(for: $0) } ?? .zero
        let container = textView.textContainer?.containerSize ?? .zero
        let ink = rendered ?? InkCount(total: -1, firstLineBand: -1, scale: 0, width: 0, height: 0, gutterInk: -1, gutterBands: -1)
        let detail = "mode=\(mode.rawValue) fixture=\(fixture.name)"
            + " tk2BeforeRender=\(tk2BeforeRender) tk2AfterRender=\(tk2AfterRender)"
            + " glyphs=\(glyphs) usedRect=\(NSStringFromRect(used)) containerSize=\(NSStringFromSize(container))"
            + " textViewFrame=\(NSStringFromRect(textView.frame)) clipFrame=\(NSStringFromRect(view.contentView.frame))"
            + " storageLength=\(textView.textStorage?.length ?? -1) lines=\(view.lineNumbers.count)"
            + " inWindow=\(view.window != nil) windowVisible=\(view.window?.isVisible ?? false)"
            + " requestedScale=\(requested.map { String(describing: $0) } ?? "native")"
            + " scale=\(ink.scale) rendered=\(rendered != nil) inkTotal=\(ink.total) inkFirstLine=\(ink.firstLineBand)"
            + " gutterInk=\(ink.gutterInk) gutterBands=\(ink.gutterBands)"
            + " areaPx=\(ink.width)x\(ink.height)"
        return Measurement(fixture: fixture, ink: ink, detail: detail)
    }

    /// Every fixture draws text in its first line AND numbers in the gutter, and more text draws more ink.
    private func assertDrawn(in mode: RenderMode, scale: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        var byFixture: [String: Measurement] = [:]
        let at = scale.map { " at \($0)x" } ?? ""
        for fixture in RenderFixture.allCases {
            let m = try measure(fixture, in: mode, scale: scale)
            byFixture[fixture.name] = m
            XCTAssertGreaterThanOrEqual(m.ink.firstLineBand, 40,
                                        "\(mode.rawValue)/\(fixture.name)\(at): the first line has no drawn text. \(m.detail)",
                                        file: file, line: line)
            XCTAssertGreaterThan(m.ink.gutterInk, 0,
                                 "\(mode.rawValue)/\(fixture.name)\(at): the gutter drew no line number. \(m.detail)",
                                 file: file, line: line)
        }
        let one = try XCTUnwrap(byFixture[RenderFixture.singleLine.name])
        let twelve = try XCTUnwrap(byFixture[RenderFixture.twelveLines.name])
        let heredoc = try XCTUnwrap(byFixture[RenderFixture.heredoc300.name])
        XCTAssertGreaterThan(twelve.ink.total, one.ink.total,
                             "\(mode.rawValue)\(at): twelve lines draw more ink than one. \(twelve.detail) | \(one.detail)", file: file, line: line)
        XCTAssertGreaterThan(heredoc.ink.total, one.ink.total,
                             "\(mode.rawValue)\(at): the visible part of 300 lines draws more ink than one line. \(heredoc.detail) | \(one.detail)",
                             file: file, line: line)
    }

    func testTheCommandTextIsDrawnInTheFullCardAtTheAppsWidth() throws {
        try assertDrawn(in: .card)
    }

    func testTheCommandTextIsDrawnInABareInputView() throws {
        try assertDrawn(in: .bare)
    }

    func testTheCommandTextIsDrawnInABareInputViewThatCountsItselfOnScreen() throws {
        try assertDrawn(in: .bareOnScreen)
    }

    // MARK: At 1x and 2x (ATF-4)

    func testTheCommandTextAndTheLineNumbersAreDrawnAtOneAndTwoPixelsPerPoint() throws {
        for mode in [RenderMode.card, .bare, .bareOnScreen] {
            for scale in Self.scales {
                try assertDrawn(in: mode, scale: scale)
            }
        }
    }

    /// A retina bitmap holds the same picture at four times the pixels: more ink in the text and the gutter.
    func testARetinaRenderHoldsAtLeastAsMuchInkAsAPlainOne() throws {
        for mode in [RenderMode.card, .bareOnScreen] {
            for fixture in RenderFixture.allCases {
                let view = try makeSubject(fixture, in: mode).view
                let plain = try XCTUnwrap(InkCounter.count(in: view, scale: 1))
                let retina = try XCTUnwrap(InkCounter.count(in: view, scale: 2))
                XCTAssertGreaterThan(retina.total, plain.total, "\(mode.rawValue)/\(fixture.name): text ink at 2x vs 1x")
                XCTAssertGreaterThan(retina.gutterInk, plain.gutterInk, "\(mode.rawValue)/\(fixture.name): gutter ink at 2x vs 1x")
            }
        }
    }

    /// The ink counter's premise: a here-doc's fill (and the other token fills) alone is not ink.
    func testNoFillTheCardPaintsBehindTextCountsAsInk() {
        let background = ApprovalTestColors.rgb(ApprovalPalette.inputBackground)
        let fills: [(String, NSColor)] = [
            ("heredocFill", ApprovalPalette.heredocFill),
            ("warningFill", ApprovalPalette.warningFill),
            ("separatorFill", ApprovalPalette.separatorFill),
        ]
        for (name, fill) in fills {
            let shown = ApprovalTestColors.composite(ApprovalTestColors.rgb(fill), over: background)
            let luma = 255 * InkCounter.luma(r: shown.r, g: shown.g, b: shown.b)
            XCTAssertLessThanOrEqual(abs(luma - InkCounter.luma(ApprovalPalette.inputBackground)), InkCounter.threshold,
                                     "\(name) is further from the input background than the ink threshold: the pixel count would count it as text")
            XCTAssertLessThanOrEqual(abs(luma - InkCounter.luma(ApprovalPalette.inputBackground)), ApprovalInkProbe.deltaThreshold,
                                     "\(name) is further from the input background than the card's own ink threshold: a fill alone would pass the runtime ink check")
        }
        let text = InkCounter.luma(ApprovalPalette.commandText)
        XCTAssertGreaterThan(abs(text - InkCounter.luma(ApprovalPalette.inputBackground)), InkCounter.threshold, "command text must be countable as ink")
    }

    /// Every colour text is drawn in (muted diff context, tokens, separators, additions, deletions) must be
    /// far enough from the background for the card's own runtime ink check to see it: otherwise a card
    /// showing only such text could never be allowed.
    func testEveryTextColourIsFarEnoughFromTheBackgroundToCountAsInk() {
        let background = InkCounter.luma(ApprovalPalette.inputBackground)
        let colours: [(String, NSColor)] = [
            ("commandText", ApprovalPalette.commandText),
            ("mutedText (diff context)", ApprovalPalette.mutedText),
            ("warning (invisible tokens)", ApprovalPalette.warning),
            ("separator", ApprovalPalette.separator),
            ("nonAscii", ApprovalPalette.nonAscii),
            ("diffAdd", ApprovalPalette.diffAdd),
            ("diffDelete", ApprovalPalette.diffDelete),
            ("gutterText", ApprovalPalette.gutterText),
        ]
        for (name, colour) in colours {
            let delta = abs(InkCounter.luma(colour) - background)
            XCTAssertGreaterThan(delta, ApprovalInkProbe.deltaThreshold, "\(name) is within the ink threshold of the input background (luma delta \(delta))")
            XCTAssertGreaterThan(delta, InkCounter.threshold, "\(name) is within the test's ink threshold of the input background (luma delta \(delta))")
        }
    }

    // MARK: The gutter, with no ruler (ATF-1)

    func testTheInputHasNoRulerViewAndKeepsItsLineNumbers() throws {
        for mode in [RenderMode.card, .bare, .bareOnScreen] {
            let view = try makeSubject(.heredoc300, in: mode).view
            XCTAssertNil(view.verticalRulerView, "\(mode.rawValue): a ruler is a sibling of the text and can paint over it")
            XCTAssertFalse(view.hasVerticalRuler, mode.rawValue)
            XCTAssertFalse(view.rulersVisible, mode.rawValue)
            XCTAssertFalse(rigAllSubviews(of: view).contains { $0 is NSRulerView }, "\(mode.rawValue): no ruler view anywhere in the input")
            XCTAssertEqual(view.lineNumbers, Array(1 ... 300), mode.rawValue)
        }
    }

    func testEveryLineGetsOneNumberInTheGutter() throws {
        for scale in Self.scales {
            let view = try makeSubject(.twelveLines, in: .bareOnScreen, height: 400).view
            let ink = try XCTUnwrap(InkCounter.count(in: view, scale: scale))
            XCTAssertEqual(view.visibleLineNumbers, Array(1 ... 12), "at \(scale)x")
            XCTAssertGreaterThan(ink.gutterInk, 0, "at \(scale)x")
            XCTAssertEqual(ink.gutterBands, 12, "at \(scale)x: twelve lines, twelve numbers in the gutter")
        }
    }

    func testAWrappedLineCarriesOneNumberNotOnePerFragment() throws {
        let long = "echo " + String(repeating: "0123456789", count: 40)
        let request = try ApprovalTestRequests.bash(long + "\necho end")
        let window = makeRigWindow(self, size: NSSize(width: 440, height: 340), appearance: NSAppearance(named: .darkAqua))
        let view = ApprovalInputView(model: ApprovalDisplayModel(request: request))
        view.isWindowShowing = { true }
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView!.addSubview(view)
        window.contentView!.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(view.contentHeight(forWidth: 400), 100, "precondition: the first line wraps into many fragments")
        XCTAssertEqual(view.lineNumbers, [1, 2])
        XCTAssertEqual(view.visibleLineNumbers, [1, 2], "both lines, and so every fragment of the first, are on screen")
        for scale in Self.scales {
            let ink = try XCTUnwrap(InkCounter.count(in: view, scale: scale))
            XCTAssertEqual(ink.gutterBands, 2, "at \(scale)x: a wrapped continuation carries no number: one for line 1, one for line 2")
            XCTAssertGreaterThanOrEqual(ink.firstLineBand, 40, "at \(scale)x: and the wrapped text is drawn")
        }
    }

    // MARK: Scrolled states and resizes (ATF-4)

    func testTheTextAndTheNumbersAreDrawnWhereverA300LineInputIsScrolledTo() throws {
        for mode in [RenderMode.card, .bareOnScreen] {
            for scale in Self.scales {
                let view = try makeSubject(.heredoc300, in: mode).view
                let last = view.textView.frame.height - view.contentView.bounds.height
                XCTAssertGreaterThan(last, 1000, "precondition: \(mode.rawValue) scrolls a long way")
                let lineHeight = view.textView.frame.height / 300
                let places: [(String, CGFloat)] = [("top", 0), ("middle", (last / 2).rounded()), ("end", last)]
                for (place, y) in places {
                    ApprovalTestViews.moveClip(of: view, toY: y)
                    let name = "\(mode.rawValue) at \(scale)x scrolled to the \(place)"
                    let ink = try XCTUnwrap(InkCounter.count(in: view, scale: scale), name)
                    XCTAssertGreaterThanOrEqual(ink.firstLineBand, 40, "\(name): the text area is blank")
                    XCTAssertGreaterThan(ink.gutterInk, 0, "\(name): the gutter shows no numbers")
                    let visible = view.visibleLineNumbers
                    guard let first = visible.first, let lastShown = visible.last else {
                        XCTFail("\(name): no line is visible")
                        continue
                    }
                    XCTAssertEqual(visible, Array(first ... lastShown), "\(name): the visible lines are consecutive")
                    let expectedFirst = max(1, Int(y / lineHeight) + 1)
                    XCTAssertLessThanOrEqual(abs(first - expectedFirst), 2, "\(name): the first visible line is \(first), the scroll position says \(expectedFirst)")
                    if place == "end" { XCTAssertEqual(lastShown, 300, "\(name): the last line is visible") }
                    XCTAssertLessThanOrEqual(abs(ink.gutterBands - visible.count), 2,
                                             "\(name): the gutter holds \(ink.gutterBands) numbers for \(visible.count) visible lines")
                }
            }
        }
    }

    func testTheTextIsStillDrawnAfterTheInputIsMadeNarrowerAndWiderAgain() throws {
        for mode in [RenderMode.card, .bareOnScreen] {
            for fixture in [RenderFixture.twelveLines, .heredoc300] {
                for scale in Self.scales {
                    let subject = try makeSubject(fixture, in: mode)
                    for width in [Self.appCardWidth, 520, 900, Self.appCardWidth] {
                        subject.resize(toWidth: width)
                        let name = "\(mode.rawValue)/\(fixture.name) at \(scale)x, \(Int(width)) pt wide"
                        XCTAssertGreaterThan(subject.view.textView.frame.width, 0, "\(name): precondition, the text view has a width")
                        let ink = try XCTUnwrap(InkCounter.count(in: subject.view, scale: scale), name)
                        XCTAssertGreaterThanOrEqual(ink.firstLineBand, 40, "\(name): the text area is blank")
                        XCTAssertGreaterThan(ink.gutterInk, 0, "\(name): the gutter shows no numbers")
                    }
                }
            }
        }
    }
}

// MARK: - Fail closed

/// How many times a card asked its host to re-measure it.
private final class LayoutRequestCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// What the card says when its input can't be shown (and the words the original warnings must survive next to).
private let displayFailedText = "Can't display this input safely. Deny it."

/// A card built the way the harness builds it, but with the render-failure seam set BEFORE its first layout.
private final class ForcedCardRig {
    let recorder: ApprovalRecorder
    let store: ApprovalStore
    let window: NSWindow
    let card: ApprovalCardView
    let layoutRequests: LayoutRequestCounter
    let width: CGFloat
    let maxHeight: CGFloat

    init(_ testCase: XCTestCase, request: ApprovalRequestWire, forceNoGlyphs: Bool,
         width: CGFloat = 560, maxHeight: CGFloat = 520, windowID: String = "w-test") {
        let window = makeRigWindow(testCase, size: NSSize(width: width + 80, height: maxHeight + 80))
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        store.handle(.request(request))
        let entry = store.entry(id: request.id)!
        let card = ApprovalCardView(entry: entry, store: store, windowID: { windowID },
                                    permit: ApprovalCardHarness.humanPermit, armDelay: 0, isOnScreen: { true })
        let requests = LayoutRequestCounter()
        card.onNeedsLayout = { requests.record() }
        card.inputView.forceNoGlyphsForTesting = forceNoGlyphs
        var height = card.preferredHeight(forWidth: width, maxHeight: maxHeight)
        card.frame = NSRect(x: 20, y: 20, width: width, height: height)
        window.contentView!.addSubview(card)
        window.contentView!.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        // The card can change what it shows (a banner) once the input has a size: re-measure, as the host does.
        height = card.preferredHeight(forWidth: width, maxHeight: maxHeight)
        card.frame = NSRect(x: 20, y: 20, width: width, height: height)
        window.contentView!.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        self.recorder = recorder
        self.store = store
        self.window = window
        self.card = card
        self.layoutRequests = requests
        self.width = width
        self.maxHeight = maxHeight
    }

    /// What the host does when the card asks: measure again, set the frame, lay out. Returns the new height.
    @discardableResult
    func remeasure() -> CGFloat {
        let height = card.preferredHeight(forWidth: width, maxHeight: maxHeight)
        card.frame = NSRect(x: 20, y: 20, width: width, height: height)
        window.contentView!.layoutSubtreeIfNeeded()
        card.layoutSubtreeIfNeeded()
        return height
    }
}

final class ApprovalCardFailClosedTests: XCTestCase {

    private static let failureBanner = "Can't display this input safely. Deny it."
    private let deny = ApprovalDecisionWire(kind: .deny)
    private let denyAndStop = ApprovalDecisionWire(kind: .denyAndStop)

    private func optionEnabled(_ id: String, in card: ApprovalCardView) -> Bool? {
        card.listing.options.first { $0.id == id }?.enabled
    }

    // MARK: A card whose text cannot be drawn can only be denied

    func testAnInputThatHasTextButNoGlyphsCannotBeAllowedEvenOnceEveryLineWasScrolledPast() throws {
        let requests: [(String, ApprovalRequestWire, CGFloat)] = [
            ("one line", try ApprovalTestRequests.simpleRm(), 520),
            ("300 lines", try ApprovalTestRequests.heredoc300(), 300),
        ]
        for (name, request, maxHeight) in requests {
            let rig = ForcedCardRig(self, request: request, forceNoGlyphs: true, maxHeight: maxHeight)
            let card = rig.card
            ApprovalTestViews.readThrough(card.inputView)

            XCTAssertTrue(card.inputView.displayFailed, "\(name): the input has text and no glyphs")
            XCTAssertFalse(card.canAllow, name)
            XCTAssertEqual(card.allowButton?.isEnabled, false, "\(name): Allow once is disabled")
            XCTAssertEqual(optionEnabled("allow_once", in: card), false, name)

            card.allowButton?.performClick(nil)
            if let allow = card.allowButton, let action = allow.action {
                _ = NSApp.sendAction(action, to: allow.target, from: allow)
            }
            XCTAssertTrue(rig.recorder.sent.isEmpty, "\(name): nothing was allowed")
            XCTAssertEqual(rig.store.entry(id: request.id)?.state, ApprovalAnswerState.pending, name)
        }
    }

    func testTheBannerTellsThePersonToDenyAnInputItCannotDisplay() throws {
        let rig = ForcedCardRig(self, request: try ApprovalTestRequests.simpleRm(), forceNoGlyphs: true)

        let listed = try XCTUnwrap(rig.card.listing.banner, "no banner on the card")
        XCTAssertTrue(listed.hasPrefix(Self.failureBanner), "banner was: \(listed)")
        let onCard = ApprovalTestViews.label(startingWith: Self.failureBanner, in: rig.card)
        XCTAssertNotNil(onCard, "the banner is a visible label on the card; labels: \(ApprovalTestViews.labelTexts(in: rig.card))")
    }

    func testEveryDenyStaysEnabledOnACardThatCannotDisplayItsInput() throws {
        let rig = ForcedCardRig(self, request: try ApprovalTestRequests.simpleRm(), forceNoGlyphs: true)
        let card = rig.card

        XCTAssertTrue(card.denyButton.isEnabled)
        XCTAssertEqual(card.denyMoreButton?.isEnabled, true, "Deny with a note")
        XCTAssertEqual(card.denyAndStopButton?.isEnabled, true)
        XCTAssertEqual(optionEnabled("deny", in: card), true)
        XCTAssertEqual(optionEnabled("deny_with_note", in: card), true)
        XCTAssertEqual(optionEnabled("deny_and_stop", in: card), true)
    }

    func testDenyAnswersACardThatCannotDisplayItsInput() throws {
        let rig = ForcedCardRig(self, request: try ApprovalTestRequests.simpleRm(), forceNoGlyphs: true)

        rig.card.denyButton.performClick(nil)

        XCTAssertEqual(rig.recorder.sent, [ApprovalRecorder.Sent(requestID: "req-1", decision: deny, windowID: "w-test")])
    }

    func testDenyAndStopAnswersACardThatCannotDisplayItsInput() throws {
        let rig = ForcedCardRig(self, request: try ApprovalTestRequests.simpleRm(), forceNoGlyphs: true)
        let stop = try XCTUnwrap(rig.card.denyAndStopButton)

        stop.performClick(nil)

        XCTAssertEqual(rig.recorder.sent, [ApprovalRecorder.Sent(requestID: "req-1", decision: denyAndStop, windowID: "w-test")])
    }

    // MARK: What `approvals list` reports

    func testTheListingReportsDisplayFailedForACardThatCannotDisplayItsInput() throws {
        let rig = ForcedCardRig(self, request: try ApprovalTestRequests.simpleRm(), forceNoGlyphs: true)
        let listing = rig.card.listing

        XCTAssertTrue(listing.displayFailed)
        XCTAssertEqual(listing.jsonObject["display_failed"] as? Bool, true)
    }

    // MARK: The failure banner adds to the warnings, it does not replace them (ATF-5)

    func testTheFailureBannerComesFirstAndKeepsTheWarningsTheCardAlreadyHad() throws {
        let requests: [(String, ApprovalRequestWire)] = [
            ("invisible and direction-changing characters in the command", try ApprovalTestRequests.bidi()),
            ("an invisible character in another field of the input",
             try ApprovalTestRequests.bashWithExtras("ls", extras: ["note": "a\u{202E}b"])),
        ]
        for (name, request) in requests {
            let normal = ForcedCardRig(self, request: request, forceNoGlyphs: false)
            let original = try XCTUnwrap(normal.card.listing.banner, "\(name): precondition, the card has a warning of its own")
            XCTAssertFalse(original.hasPrefix(Self.failureBanner), name)

            let rig = ForcedCardRig(self, request: request, forceNoGlyphs: true)
            let listed = try XCTUnwrap(rig.card.listing.banner, "\(name): no banner on the card")
            XCTAssertTrue(listed.hasPrefix(Self.failureBanner), "\(name): the failure comes first. Banner was: \(listed)")
            XCTAssertTrue(listed.contains(original), "\(name): the warning the card had is still there. Banner was: \(listed)")

            let onCard = try XCTUnwrap(ApprovalTestViews.label(startingWith: Self.failureBanner, in: rig.card),
                                       "\(name): labels: \(ApprovalTestViews.labelTexts(in: rig.card))")
            XCTAssertTrue(onCard.stringValue.contains(original), "\(name): the label on the card keeps the warning. Label was: \(onCard.stringValue)")
        }
    }

    func testAFailureThatMakesTheBannerTallerAsksForARelayoutOnceAndSettles() throws {
        let request = try ApprovalTestRequests.bidi()
        let normal = ForcedCardRig(self, request: request, forceNoGlyphs: false)
        XCTAssertEqual(normal.layoutRequests.count, 0, "precondition: a card that displays fine never asks to be re-measured")
        let heightBefore = normal.card.frame.height

        let rig = ForcedCardRig(self, request: request, forceNoGlyphs: true)
        let card = rig.card
        let requested = rig.layoutRequests.count
        XCTAssertGreaterThan(requested, 0, "the card asks its host to re-measure it when its banner grows")
        XCTAssertLessThanOrEqual(requested, 2, "and does so a small, bounded number of times")

        // The host re-measures as asked; then nothing more is asked, whatever else happens.
        let height = rig.remeasure()
        let settled = card.frame
        for _ in 0 ..< 5 {
            card.inputView.updateScrollProgress()
            rig.window.contentView!.layoutSubtreeIfNeeded()
            card.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(rig.layoutRequests.count, requested, "no relayout loop: evaluating and laying out again asks for nothing")
        XCTAssertEqual(card.frame, settled, "the frame is stable")
        XCTAssertEqual(rig.remeasure(), height, "and so is the height the card wants")

        XCTAssertGreaterThan(height, heightBefore, "the card is taller than without the failure: the longer banner has room")
        let label = try XCTUnwrap(ApprovalTestViews.label(startingWith: Self.failureBanner, in: card))
        XCTAssertGreaterThanOrEqual(label.frame.height, 2 * label.font!.pointSize, "the banner label has room for at least its two lines")
        XCTAssertLessThanOrEqual(label.frame.maxY, card.bounds.height, "the banner is inside the card, not clipped by its edge")
    }

    // MARK: The banner has room for everything it says

    func testTheBannerWithEveryWarningStackedAndTheFailureLineIsNeverTruncatedAndTheCardGrowsToHoldIt() throws {
        // Invisible characters in the command and in another field of the request, and the failure line.
        let request = try ApprovalTestRequests.bash(ApprovalTestRequests.bidiCommand, cwd: "/tmp/a\u{202E}b")
        let normal = ForcedCardRig(self, request: request, forceNoGlyphs: false, width: 280)
        let original = try XCTUnwrap(normal.card.listing.banner, "precondition: the card has a warning of its own")
        let normalHeight = normal.remeasure()

        let rig = ForcedCardRig(self, request: request, forceNoGlyphs: true, width: 280)
        let height = rig.remeasure()
        let label = try XCTUnwrap(ApprovalTestViews.label(startingWith: Self.failureBanner, in: rig.card),
                                  "labels: \(ApprovalTestViews.labelTexts(in: rig.card))")

        XCTAssertEqual(label.maximumNumberOfLines, 0, "the banner grows to what it says: no cap on its lines")
        XCTAssertTrue(label.stringValue.hasPrefix(Self.failureBanner), "the failure comes first: \(label.stringValue)")
        XCTAssertTrue(label.stringValue.contains(original), "every warning the card had is still in full: \(label.stringValue)")
        XCTAssertEqual(rig.card.listing.banner, label.stringValue, "and the listing says the same")

        let cell = try XCTUnwrap(label.cell)
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height
        XCTAssertGreaterThan(needed, 2.5 * label.font!.pointSize + 10, "precondition: at this width the banner needs more than two lines")
        XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, needed,
                                    "the label is \(label.frame.height) pt tall, its text needs \(needed): the banner is cut off")
        XCTAssertGreaterThanOrEqual(label.frame.minY, 0, "the banner is inside the card")
        XCTAssertLessThanOrEqual(label.frame.maxY, rig.card.bounds.height, "the banner is inside the card, not clipped by its edge")
        XCTAssertGreaterThan(height, normalHeight, "the card is taller than without the failure: the longer banner has room")
    }

    // MARK: A normal card is unaffected

    func testANormalCardHasNotFailedToDisplayAndCanBeAllowedOnceReadThrough() throws {
        let requests: [(String, ApprovalRequestWire, CGFloat)] = [
            ("one line", try ApprovalTestRequests.simpleRm(), 520),
            ("300 lines", try ApprovalTestRequests.heredoc300(), 300),
        ]
        for (name, request, maxHeight) in requests {
            let rig = ForcedCardRig(self, request: request, forceNoGlyphs: false, maxHeight: maxHeight)
            let card = rig.card
            ApprovalTestViews.readThrough(card.inputView)

            XCTAssertFalse(card.inputView.displayFailed, name)
            XCTAssertFalse(card.listing.displayFailed, name)
            XCTAssertEqual(card.listing.jsonObject["display_failed"] as? Bool, false, name)
            XCTAssertTrue(card.canAllow, "\(name): the whole input was read through")
            XCTAssertEqual(card.allowButton?.isEnabled, true, name)
            XCTAssertNil(ApprovalTestViews.label(startingWith: Self.failureBanner, in: card), "\(name): no failure banner")
        }
    }
}

// MARK: - When a layout can be judged (ATF-2)

/// A switch a test flips to say "the window is showing now": stands in for `isWindowShowing`.
private final class ShowingBox {
    var showing: Bool
    init(_ showing: Bool) { self.showing = showing }
}

/// A bare input view in a rig window whose "is the window showing?" answer a test controls.
private final class BareInputRig {
    let window: NSWindow
    let view: ApprovalInputView
    let box: ShowingBox

    init(_ testCase: XCTestCase, request: ApprovalRequestWire, showing: Bool, forceNoGlyphs: Bool,
         width: CGFloat = 500, height: CGFloat = 120) {
        let box = ShowingBox(showing)
        let window = makeRigWindow(testCase, size: NSSize(width: width + 40, height: height + 40),
                                   appearance: NSAppearance(named: .darkAqua))
        let view = ApprovalInputView(model: ApprovalDisplayModel(request: request))
        view.isWindowShowing = { box.showing }
        view.forceNoGlyphsForTesting = forceNoGlyphs
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView!.addSubview(view)
        window.contentView!.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        self.box = box
        self.window = window
        self.view = view
    }

    /// Lay the view out again and re-evaluate it, as a window showing does on every pass.
    func settle() {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.updateScrollProgress()
    }
}

/// `displayFailed` is a verdict on a layout that has a size and is on screen. It is never a verdict on
/// one that has neither, and once given it is final.
final class ApprovalInputViewLatchRulesTests: XCTestCase {

    func testALayoutWithNoWidthIsNotAVerdictButASizedOneIs() throws {
        let rig = BareInputRig(self, request: try ApprovalTestRequests.simpleRm(), showing: false, forceNoGlyphs: true)
        let view = rig.view

        // The first layout a window shows can have a text view of no width at all.
        view.textView.setFrameSize(NSSize(width: 0, height: view.textView.frame.height))
        rig.box.showing = true
        view.updateScrollProgress()
        XCTAssertEqual(view.textView.frame.width, 0, "precondition: the text view has no width")
        XCTAssertFalse(view.displayFailed, "a layout with no width says nothing about whether text can be drawn")
        view.updateScrollProgress()
        XCTAssertFalse(view.displayFailed, "however often it is looked at")

        // Then the real layout: sized, on screen, text with no glyphs.
        view.textView.setFrameSize(NSSize(width: view.contentView.bounds.width, height: view.textView.frame.height))
        view.layoutSubtreeIfNeeded()
        view.updateScrollProgress()
        XCTAssertGreaterThan(view.textView.frame.width, 0, "precondition: the text view has a width now")
        XCTAssertGreaterThan(view.textView.textContainer?.containerSize.width ?? 0, 0, "precondition: and so has its container")
        XCTAssertTrue(view.displayFailed, "a sized, on-screen layout of text with no glyphs is a failure")
    }

    func testASizedOnScreenLayoutWithNoGlyphsFailsAndSaysSoOnce() throws {
        let rig = BareInputRig(self, request: try ApprovalTestRequests.simpleRm(), showing: false, forceNoGlyphs: true)
        let view = rig.view
        var told = 0
        view.onDisplayFailed = { told += 1 }

        rig.box.showing = true
        view.updateScrollProgress()
        XCTAssertTrue(view.displayFailed)
        XCTAssertFalse(view.hasShownEveryLine, "nothing is earned by text that has no glyphs")
        for _ in 0 ..< 3 { rig.settle() }
        XCTAssertEqual(told, 1, "the failure is reported once")
    }

    func testALayoutThatIsOnScreenFromTheStartFailsWithoutAnyoneAskingTwice() throws {
        let rig = BareInputRig(self, request: try ApprovalTestRequests.simpleRm(), showing: true, forceNoGlyphs: true)
        XCTAssertTrue(rig.view.displayFailed, "the layout the window showed was sized and had no glyphs")
        XCTAssertFalse(rig.view.hasShownEveryLine)
    }

    func testAViewThatIsNotShowingOnScreenIsNeverJudgedUntilItIs() throws {
        let rig = BareInputRig(self, request: try ApprovalTestRequests.simpleRm(), showing: false, forceNoGlyphs: true)
        let view = rig.view

        for _ in 0 ..< 3 { rig.settle() }
        XCTAssertFalse(view.displayFailed, "a window nobody can see says nothing about the text")
        XCTAssertFalse(view.hasShownEveryLine, "and earns no coverage")

        rig.box.showing = true
        rig.settle()
        XCTAssertTrue(view.displayFailed, "it is judged as soon as it is showing")
    }

    func testACardInAWindowThatIsNotShowingNeverShowsTheFailure() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.simpleRm(), isOnScreen: nil)
        let card = h.card
        card.inputView.forceNoGlyphsForTesting = true

        h.relayout()
        card.inputView.updateScrollProgress()

        XCTAssertFalse(h.window.isVisible, "precondition: the rig window is never ordered in")
        XCTAssertFalse(card.inputView.displayFailed)
        XCTAssertFalse(card.listing.displayFailed)
        XCTAssertNil(card.listing.banner, "no banner for a layout that was never on screen")
        XCTAssertTrue(card.denyButton.isEnabled, "Deny is there regardless")
    }

    func testOnceAnInputHasFailedAllowStaysOffForGoodEvenAfterAFullReadThrough() throws {
        let requests: [(String, ApprovalRequestWire, CGFloat)] = [
            ("one line", try ApprovalTestRequests.simpleRm(), 520),
            ("300 lines", try ApprovalTestRequests.heredoc300(), 300),
        ]
        for (name, request, maxHeight) in requests {
            let rig = ForcedCardRig(self, request: request, forceNoGlyphs: true, maxHeight: maxHeight)
            let card = rig.card
            XCTAssertTrue(card.inputView.displayFailed, "\(name): precondition, it failed")

            // Whatever happens next: the text now lays out, the card is read to the end and laid out again.
            card.inputView.forceNoGlyphsForTesting = false
            rig.remeasure()
            ApprovalTestViews.readThrough(card.inputView)
            card.inputView.updateScrollProgress()
            card.inputView.scrollToEnd()
            rig.remeasure()

            XCTAssertTrue(card.inputView.displayFailed, "\(name): a failure never goes away")
            XCTAssertTrue(card.listing.displayFailed, name)
            XCTAssertFalse(card.canAllow, name)
            XCTAssertEqual(card.allowButton?.isEnabled, false, "\(name): Allow once stays disabled")
            XCTAssertEqual(rig.card.listing.options.first { $0.id == "allow_once" }?.enabled, false, name)
            XCTAssertNotNil(ApprovalTestViews.label(startingWith: displayFailedText, in: card), "\(name): the banner stays")
            XCTAssertTrue(card.denyButton.isEnabled, "\(name): and Deny stays enabled")
        }
    }
}

// MARK: - The runtime ink check (ATF-3)

/// Paints over the text area, as a sibling subview painted over the text would. Mouse-transparent.
private final class OverpaintView: NSView {
    let fill: NSColor

    init(frame: NSRect, fill: NSColor) {
        self.fill = fill
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // On macOS 14+ a view does not clip to its bounds and the dirty rect can be larger than they are:
        // paint only the overpaint's own area.
        let area = dirtyRect.intersection(bounds)
        guard !area.isNull else { return }
        fill.setFill()
        area.fill()
    }
}

/// The time an input view's failures are spaced by, in a test's hands.
private final class RigClock {
    var now: TimeInterval = 1000
}

/// A line fragment of the input's layout, in text-view coordinates.
private struct RigFragment {
    /// The whole fragment: its row band.
    let rect: NSRect
    /// The part of it that holds text.
    let used: NSRect
}

/// A card in a rig window that is NOT showing until the test says so, so that the first coverage it
/// earns (and the first ink check) happens after the test has set the scene (an overpaint).
/// The input's clock is the rig's: it moves only when the test moves it.
private final class OverpaintRig {
    let harness: ApprovalCardHarness
    let box: ShowingBox
    private let clockBox = RigClock()
    private var overlay: OverpaintView?

    var card: ApprovalCardView { harness.card }
    var view: ApprovalInputView { harness.card.inputView }
    /// The input's clock now.
    var now: TimeInterval { clockBox.now }

    init(_ testCase: XCTestCase, request: ApprovalRequestWire, width: CGFloat = 560, maxHeight: CGFloat = 520) {
        let box = ShowingBox(false)
        harness = ApprovalCardHarness(testCase, request: request, width: width, maxHeight: maxHeight,
                                      isOnScreen: { box.showing })
        self.box = box
        let clockBox = self.clockBox
        harness.card.inputView.clock = { clockBox.now }
    }

    /// Put a view over the text area (right of the gutter), above the clip view, as a sibling of it.
    /// With no span given it covers the whole text area; the rows and columns it covers can be limited,
    /// in text-view coordinates (a span not given runs to the edge of the text area).
    func paintOver(with fill: NSColor = ApprovalPalette.inputBackground,
                   fromTextX: CGFloat? = nil, toTextX: CGFloat? = nil,
                   fromTextY: CGFloat? = nil, toTextY: CGFloat? = nil) {
        removeOverpaint()
        let clip = view.contentView.frame
        let gutter = view.gutterWidth
        var frame = NSRect(x: clip.minX + gutter, y: clip.minY, width: clip.width - gutter, height: clip.height)
        if fromTextX != nil || toTextX != nil || fromTextY != nil || toTextY != nil {
            // The clip's own bounds (the same coordinates as the text view's): set whether or not the text view has
            // been sized yet, which `visibleRect` is not before the view is shown.
            let visible = view.contentView.bounds
            let x0 = fromTextX ?? gutter, x1 = toTextX ?? visible.maxX
            let y0 = fromTextY ?? visible.minY, y1 = toTextY ?? visible.maxY
            frame = view.convert(NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), from: view.textView)
        }
        let overlay = OverpaintView(frame: frame, fill: fill)
        view.addSubview(overlay)
        self.overlay = overlay
    }

    func removeOverpaint() {
        overlay?.removeFromSuperview()
        overlay = nil
    }

    /// The window is showing now.
    func show() { box.showing = true }

    /// Move the input's clock on.
    func advance(by seconds: TimeInterval) { clockBox.now += seconds }

    /// Look at the input `times` times, without scrolling it and without waiting for the run loop, each
    /// look a full settle window (and a little more) after the one before: every failed look is counted.
    func evaluate(_ times: Int) {
        for _ in 0 ..< times {
            advance(by: ApprovalInputView.failureSettleWindow + 0.05)
            view.updateScrollProgress()
        }
    }

    /// Look at the input `times` times in a row with no time passing: a resize storm in one turn of the run loop.
    func evaluateBurst(_ times: Int) {
        for _ in 0 ..< times { view.updateScrollProgress() }
    }

    /// The input's line fragments, top to bottom, as the layout has them (text-view coordinates).
    var fragments: [RigFragment] {
        guard let layout = view.textView.layoutManager, let container = view.textView.textContainer else { return [] }
        layout.ensureLayout(for: container)
        let origin = view.textView.textContainerOrigin
        var out: [RigFragment] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, used, _, _, _ in
            out.append(RigFragment(rect: rect.offsetBy(dx: origin.x, dy: origin.y), used: used.offsetBy(dx: origin.x, dy: origin.y)))
        }
        return out
    }
}

/// Allow once is off: the card cannot be allowed and its button is disabled.
private func assertAllowIsOff(_ card: ApprovalCardView, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(card.canAllow, name, file: file, line: line)
    XCTAssertEqual(card.allowButton?.isEnabled, false, "\(name): Allow once is disabled", file: file, line: line)
}

/// Commands for the tests of a long line in a wide card.
private enum ApprovalLongLine {
    /// 85 characters: one line fragment in a card about 900 pt wide.
    static let command = "git commit -m 'update the build script for the release pipeline now' && rm -rf /tmp/x"
    /// 53 characters, 40 of them spaces in the middle.
    static let spaced = "echo start" + String(repeating: " ", count: 40) + "end"
}

final class ApprovalInkCheckTests: XCTestCase {

    private let maxFailures = ApprovalInputView.maxInkFailures

    private func assertDenyOnly(_ card: ApprovalCardView, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(card.canAllow, name, file: file, line: line)
        XCTAssertEqual(card.allowButton?.isEnabled, false, "\(name): Allow once is disabled", file: file, line: line)
    }

    // MARK: Text that draws passes

    func testTextThatReallyDrawsPassesTheInkCheckAndAllowOpensAfterTheReadThrough() throws {
        let spaced = "echo start" + String(repeating: " ", count: 40) + "end"
        let cases: [(String, ApprovalRequestWire, CGFloat, CGFloat)] = [
            ("one line", try ApprovalTestRequests.simpleRm(), 520, 560),
            ("12 lines in a short card", try ApprovalTestRequests.shortLines(12), 150, 560),
            ("300 lines (a here-doc's fill is not ink, its text is)", try ApprovalTestRequests.heredoc300(), 300, 560),
            ("an edit: muted diff context, additions, deletions", try ApprovalTestRequests.edit(), 100, 560),
            ("a write: all additions", try ApprovalTestRequests.write(), 100, 560),
            ("invisible-character tokens and direction marks", try ApprovalTestRequests.bidi(), 520, 560),
            ("an 85-character command on one line of a wide card", try ApprovalTestRequests.bash(ApprovalLongLine.command), 300, 960),
            ("a command with a run of 40 spaces in the middle", try ApprovalTestRequests.bash(spaced), 300, 560),
        ]
        for (name, request, maxHeight, width) in cases {
            let h = ApprovalCardHarness(self, request: request, width: width, maxHeight: maxHeight)
            let view = h.card.inputView
            ApprovalTestViews.readThrough(view)

            XCTAssertFalse(view.displayFailed, "\(name): real text must not fail the ink check")
            XCTAssertEqual(view.inkFailures, 0, name)
            XCTAssertTrue(view.hasShownEveryLine, "\(name): lines never shown: \(view.linesNotYetShown)")
            XCTAssertTrue(view.linesNotYetShown.isEmpty, name)
            XCTAssertGreaterThanOrEqual(view.inkCheckCount, 1, "\(name): the text was checked for ink")
            XCTAssertTrue(h.card.canAllow, name)
            XCTAssertEqual(h.card.allowButton?.isEnabled, true, name)
            XCTAssertNil(ApprovalTestViews.label(startingWith: displayFailedText, in: h.card), "\(name): no failure banner")
        }
    }

    // MARK: Text that is covered does not pass

    /// Ink in the first rows must not vouch for blank rows in the same batch.
    func testInkInSomeRowsDoesNotVouchForRowsThatAreOverpainted() throws {
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.shortLines(12), maxHeight: 520)
        rig.paintOver(fromTextY: 60)
        rig.show()

        rig.evaluate(1)
        XCTAssertFalse(rig.view.hasShownEveryLine, "rows 4 to 12 are painted over: they were not shown")
        assertDenyOnly(rig.card, "12 lines, the lower rows overpainted")
        XCTAssertFalse(rig.view.linesNotYetShown.isEmpty)

        rig.evaluate(maxFailures)
        XCTAssertTrue(rig.view.displayFailed, "repeated failures latch")
        assertDenyOnly(rig.card, "12 lines, the lower rows overpainted, latched")
    }

    func testAnOverpaintedTextAreaIsNeverCountedAsShownAndEndsAsADisplayFailure() throws {
        let fills: [(String, NSColor)] = [
            ("the modal background (a blank text area)", ApprovalPalette.inputBackground),
            ("mid grey", NSColor(white: 0.5, alpha: 1)),
            ("black", NSColor(white: 0, alpha: 1)),
        ]
        let cases: [(String, ApprovalRequestWire, CGFloat)] = [
            ("one line", try ApprovalTestRequests.simpleRm(), 520),
            ("12 lines", try ApprovalTestRequests.shortLines(12), 520),
            ("300 lines", try ApprovalTestRequests.heredoc300(), 300),
        ]
        for (fillName, fill) in fills {
            for (name, request, maxHeight) in cases {
                let label = "\(name) under \(fillName)"
                let rig = OverpaintRig(self, request: request, maxHeight: maxHeight)
                rig.paintOver(with: fill)
                rig.show()
                let card = rig.card, view = rig.view

                rig.evaluate(1)
                XCTAssertFalse(view.hasShownEveryLine, "\(label): lines covered by something else are not shown")
                XCTAssertFalse(view.displayFailed, "\(label): one failed check is not yet a verdict")
                assertDenyOnly(card, label)

                rig.evaluate(self.maxFailures)
                ApprovalTestViews.readThrough(view)
                rig.evaluate(self.maxFailures)

                XCTAssertTrue(view.displayFailed, "\(label): repeated failed checks latch the failure")
                XCTAssertFalse(view.hasShownEveryLine, "\(label): lines never shown: \(view.linesNotYetShown)")
                XCTAssertGreaterThanOrEqual(view.inkCheckCount, 1, label)
                assertDenyOnly(card, label)
                XCTAssertTrue(card.listing.displayFailed, label)
                XCTAssertNotNil(ApprovalTestViews.label(startingWith: displayFailedText, in: card), "\(label): the banner says so")
                XCTAssertTrue(card.denyButton.isEnabled, "\(label): Deny stays enabled")
                XCTAssertEqual(card.denyMoreButton?.isEnabled, true, label)
                XCTAssertEqual(card.denyAndStopButton?.isEnabled, true, label)
            }
        }
    }

    func testTheFailureIsNotFinalUntilTheLastOfTheFailedChecksAndAllowIsOffThroughout() throws {
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.shortLines(12))
        rig.paintOver()
        rig.show()
        let view = rig.view

        var calls = 0
        while !view.displayFailed && calls <= maxFailures {
            rig.evaluate(1)
            calls += 1
            if !view.displayFailed {
                assertDenyOnly(rig.card, "after \(calls) look(s) at an overpainted input")
                XCTAssertFalse(view.hasShownEveryLine, "after \(calls) look(s)")
                XCTAssertEqual(rig.card.allowButton?.title, "Scroll to the end to allow", "after \(calls) look(s)")
            }
            if calls == 1 {
                XCTAssertFalse(view.displayFailed, "the first failed check does not latch")
                XCTAssertGreaterThanOrEqual(view.inkFailures, 1, "but it is counted")
            }
        }
        XCTAssertTrue(view.displayFailed, "the failure latches after at most \(maxFailures) failed looks")
        XCTAssertGreaterThanOrEqual(calls, 2, "and not on the first")
        XCTAssertLessThanOrEqual(calls, maxFailures)
    }

    func testTextCoveredAfterTheFirstScreenWasFineBlocksTheRestOfTheReadThrough() throws {
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        rig.show()
        let view = rig.view
        rig.evaluate(1)
        XCTAssertEqual(view.inkFailures, 0, "precondition: the first screen drew")
        XCTAssertFalse(view.displayFailed)
        XCTAssertGreaterThanOrEqual(view.inkCheckCount, 1)

        rig.paintOver()
        ApprovalTestViews.readThrough(view)

        XCTAssertFalse(view.hasShownEveryLine, "the rest of the input was covered while it was scrolled past")
        XCTAssertFalse(view.linesNotYetShown.isEmpty)
        assertDenyOnly(rig.card, "read through under an overpaint")
        rig.evaluate(maxFailures)
        XCTAssertTrue(view.displayFailed)
        assertDenyOnly(rig.card, "latched")
    }

    func testATransientFailureDoesNotLatchAndTheNextGoodLookEnablesAllow() throws {
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.shortLines(12))
        rig.paintOver()
        rig.show()
        let card = rig.card, view = rig.view

        rig.evaluate(1)
        XCTAssertFalse(view.hasShownEveryLine, "precondition: covered, so not shown")
        XCTAssertFalse(view.displayFailed, "precondition: one failure")
        assertDenyOnly(card, "while covered")

        rig.removeOverpaint()
        rig.evaluate(2)

        XCTAssertFalse(view.displayFailed, "a failure that went away does not latch")
        XCTAssertEqual(view.inkFailures, 0, "and a good look resets the count")
        XCTAssertTrue(view.hasShownEveryLine, "the lines that were covered are shown now: \(view.linesNotYetShown)")
        XCTAssertTrue(card.canAllow)
        XCTAssertEqual(card.allowButton?.isEnabled, true)
        XCTAssertEqual(card.allowButton?.title, "Allow once")
    }

    // MARK: Blank rows demand nothing

    func testAnInputOfNothingButBlankLinesNeverDemandsInkEvenUnderAnOverpaint() throws {
        for covered in [false, true] {
            let rig = OverpaintRig(self, request: try ApprovalTestRequests.bash("\n\n\n"))
            if covered { rig.paintOver() }
            rig.show()
            rig.evaluate(maxFailures + 1)
            ApprovalTestViews.readThrough(rig.view)
            let name = covered ? "covered" : "plain"

            XCTAssertFalse(rig.view.displayFailed, "\(name): nothing to see, nothing to fail")
            XCTAssertEqual(rig.view.inkFailures, 0, name)
            XCTAssertEqual(rig.view.inkCheckCount, 0, "\(name): blank rows are not rendered for ink")
            XCTAssertTrue(rig.view.hasShownEveryLine, "\(name): lines never shown: \(rig.view.linesNotYetShown)")
        }
    }

    func testBlankRowsAboveATokenNeverDemandInkButTheTokenDoes() throws {
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.bash(String(repeating: "\n", count: 40) + "echo hi"), maxHeight: 150)
        rig.paintOver()
        rig.show()
        let view = rig.view
        let clip = view.contentView.bounds.height

        // Scroll through the blank rows only: the token is 40 lines down.
        rig.evaluate(1)
        XCTAssertLessThan(clip + 200, view.textView.frame.height - 60, "precondition: 200 pt down is still all blank rows")
        ApprovalTestViews.readThrough(view, upTo: 200)
        XCTAssertEqual(view.inkCheckCount, 0, "blank rows are never rendered for ink")
        XCTAssertEqual(view.inkFailures, 0)
        XCTAssertFalse(view.displayFailed)

        // The token is covered by the overpaint: it does not count.
        ApprovalTestViews.readThrough(view)
        XCTAssertGreaterThanOrEqual(view.inkCheckCount, 1, "the row with the token is checked")
        XCTAssertFalse(view.hasShownEveryLine, "the token was never shown")
        XCTAssertTrue(view.linesNotYetShown.contains(41), "line 41 (the token) was not shown: \(view.linesNotYetShown)")
    }

    // MARK: Cost

    func testAnUnchangedViewIsNeverRenderedAgain() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView
        let afterFirstScreen = view.inkCheckCount
        XCTAssertGreaterThanOrEqual(afterFirstScreen, 1, "precondition: the first screen was checked")

        for _ in 0 ..< 100 { view.updateScrollProgress() }
        XCTAssertEqual(view.inkCheckCount, afterFirstScreen, "no clip movement and no new rows: no render")

        h.relayout()
        for _ in 0 ..< 20 { view.updateScrollProgress() }
        XCTAssertEqual(view.inkCheckCount, afterFirstScreen, "a layout pass that moves nothing is no render either")
    }

    func testTheInkCheckRendersAtMostOncePerScrollStepAndFarLessOftenThanItIsAskedTo() throws {
        let h = ApprovalCardHarness(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = h.card.inputView
        let visible = view.contentView.bounds.height
        let end = view.textView.frame.height - visible
        XCTAssertGreaterThan(end, 1000, "precondition: a long way to scroll")

        var steps = 0, asked = 0
        var previous = view.inkCheckCount
        let start = previous
        var y: CGFloat = 0
        while true {
            ApprovalTestViews.moveClip(of: view, toY: y)
            for _ in 0 ..< 5 {
                view.updateScrollProgress()
                asked += 1
            }
            steps += 1
            XCTAssertLessThanOrEqual(view.inkCheckCount - previous, 1, "at most one render for the step to y = \(y)")
            previous = view.inkCheckCount
            if y >= end { break }
            y = min(y + visible / 2, end)
        }

        XCTAssertTrue(view.hasShownEveryLine, "precondition: it was read through")
        XCTAssertLessThanOrEqual(view.inkCheckCount - start, steps, "never more renders than steps")
        XCTAssertLessThan(view.inkCheckCount * 2, asked, "renders: \(view.inkCheckCount), evaluations asked for: \(asked)")
    }
}

// MARK: - Failures are counted once per settle window (ATG-1)

/// `maxInkFailures` failed evaluations latch `displayFailed`, but a failure only counts if no failure was
/// counted within `ApprovalInputView.failureSettleWindow` before it (on the input's own clock): a storm of
/// failing passes in one turn of the run loop (a resize, a card re-parented mid-animation) is one unsettled
/// layout, not three verdicts. Allow stays off the whole time.
final class ApprovalInkFailureCountingTests: XCTestCase {

    private let maxFailures = ApprovalInputView.maxInkFailures
    private let window = ApprovalInputView.failureSettleWindow

    /// A 12-line card whose text area is overpainted, showing.
    private func coveredRig() throws -> OverpaintRig {
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.shortLines(12))
        rig.paintOver()
        rig.show()
        return rig
    }

    private func assertStillBlocked(_ rig: OverpaintRig, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(rig.view.hasShownEveryLine, "\(name): lines never shown: \(rig.view.linesNotYetShown)", file: file, line: line)
        assertAllowIsOff(rig.card, name, file: file, line: line)
    }

    func testAStormOfFailingPassesInOneTurnCountsAsOneFailureAndDoesNotLatch() throws {
        let rig = try coveredRig()

        rig.evaluateBurst(10)

        XCTAssertEqual(rig.view.inkFailures, 1, "ten failing passes with no time between them are one failure")
        XCTAssertFalse(rig.view.displayFailed, "a storm is not a verdict")
        assertStillBlocked(rig, "after a storm of failing passes")

        rig.evaluateBurst(10)
        XCTAssertEqual(rig.view.inkFailures, 1, "and a second storm in the same turn adds nothing")
        XCTAssertFalse(rig.view.displayFailed)
        assertStillBlocked(rig, "after two storms")
    }

    func testThreeFailuresSpacedPastTheWindowLatchTheDisplayFailureAndTheBannerSaysSo() throws {
        let rig = try coveredRig()

        rig.evaluate(1)
        XCTAssertEqual(rig.view.inkFailures, 1)
        XCTAssertFalse(rig.view.displayFailed)
        rig.evaluate(1)
        XCTAssertEqual(rig.view.inkFailures, 2)
        XCTAssertFalse(rig.view.displayFailed, "two failures are not enough")
        assertStillBlocked(rig, "after two spaced failures")

        rig.evaluate(1)
        XCTAssertTrue(rig.view.displayFailed, "the third failure, spaced like the others, latches")
        assertStillBlocked(rig, "latched")
        XCTAssertNotNil(ApprovalTestViews.label(startingWith: displayFailedText, in: rig.card), "the banner says so")
        XCTAssertTrue(rig.card.denyButton.isEnabled, "Deny stays enabled")
    }

    func testAStormBetweenSpacedFailuresAddsNothingToTheCount() throws {
        let rig = try coveredRig()

        rig.evaluate(1)
        rig.evaluateBurst(10)
        XCTAssertEqual(rig.view.inkFailures, 1, "the storm after the first failure adds nothing")

        rig.evaluate(1)
        XCTAssertEqual(rig.view.inkFailures, 2, "a failure after the window counts")
        rig.evaluateBurst(10)
        XCTAssertEqual(rig.view.inkFailures, 2, "the storm after the second failure adds nothing")
        XCTAssertFalse(rig.view.displayFailed, "two counted failures, however many passes there were")
        assertStillBlocked(rig, "after storms between two failures")

        rig.evaluate(1)
        XCTAssertTrue(rig.view.displayFailed, "the third counted failure latches")
        assertStillBlocked(rig, "latched")
    }

    func testAGoodLookForgetsTheFailuresSoTheNextOnesStartCountingFromOne() throws {
        // 300 lines: one good look at the first screen does not finish the read-through.
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.heredoc300(), maxHeight: 300)
        let view = rig.view
        rig.paintOver()
        rig.show()

        rig.evaluate(2)
        XCTAssertEqual(view.inkFailures, 2, "precondition: two counted failures")
        XCTAssertFalse(view.displayFailed)

        rig.removeOverpaint()
        rig.evaluate(1)
        XCTAssertEqual(view.inkFailures, 0, "a good look resets the count")
        XCTAssertFalse(view.hasShownEveryLine, "precondition: there is much more to read")
        XCTAssertFalse(view.displayFailed)

        // Covered again, on the next screen: one failure, however many passes it takes to look at it.
        rig.paintOver()
        rig.advance(by: window + 0.05)
        ApprovalTestViews.moveClip(of: view, toY: view.contentView.bounds.height)
        rig.evaluateBurst(1)
        XCTAssertEqual(view.inkFailures, 1, "the count starts again from one, not from three")
        XCTAssertFalse(view.displayFailed, "the failures before the good look are forgotten")
        assertStillBlocked(rig, "covered again after a good look")
    }

    func testAFailureInsideTheWindowIsNotCountedAndOneAfterItIs() throws {
        let rig = try coveredRig()

        rig.evaluate(1)
        XCTAssertEqual(rig.view.inkFailures, 1, "precondition: the first failure counts")

        rig.advance(by: window * 0.5)
        rig.evaluateBurst(1)
        XCTAssertEqual(rig.view.inkFailures, 1, "a failure half a window after the counted one is not counted")

        // The window runs from the last COUNTED failure, not from the last one seen.
        rig.advance(by: window * 0.7)
        rig.evaluateBurst(1)
        XCTAssertEqual(rig.view.inkFailures, 2, "a failure 1.2 windows after the counted one is")
        XCTAssertFalse(rig.view.displayFailed)
        assertStillBlocked(rig, "after a counted and an uncounted failure")
    }
}

// MARK: - A long line is judged in chunks (ATG-2)

/// A line fragment is judged in horizontal chunks of about eight characters: every chunk that has text needs
/// ink, a chunk of spaces needs none. Hiding only one end or the middle of a long line must not pass because the
/// rest of the line draws.
final class ApprovalInkChunkTests: XCTestCase {

    private let maxFailures = ApprovalInputView.maxInkFailures

    /// A wide card and the one line fragment of `command` in it.
    private func wideRig(_ command: String, minimumWidth: CGFloat) throws -> (rig: OverpaintRig, fragment: RigFragment) {
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.bash(command), width: 960, maxHeight: 300)
        let fragments = rig.fragments
        XCTAssertEqual(fragments.count, 1, "precondition: the command is ONE line fragment in a card this wide")
        let fragment = try XCTUnwrap(fragments.first)
        XCTAssertGreaterThan(fragment.used.width, minimumWidth, "precondition: the text is wide enough to hide a part of it")
        return (rig, fragment)
    }

    /// Hide the part of the long command between `from` and `to` (fractions of its laid-out width; nil is its end)
    /// and check that Allow stays off, and that the card ends as a display failure with its banner.
    private func assertHidingBlocksAllow(_ name: String, from: CGFloat?, to: CGFloat?,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let (rig, fragment) = try wideRig(ApprovalLongLine.command, minimumWidth: 400)
        let view = rig.view
        let x0 = from.map { fragment.used.minX + fragment.used.width * $0 }
        let x1 = to.map { fragment.used.minX + fragment.used.width * $0 }
        let covered = (x1 ?? view.textView.visibleRect.maxX) - (x0 ?? view.gutterWidth)
        XCTAssertGreaterThanOrEqual(covered, 100, "\(name): precondition, the overlay is wide enough to hold whole chunks", file: file, line: line)
        rig.paintOver(fromTextX: x0, toTextX: x1)
        rig.show()

        rig.evaluate(1)
        XCTAssertFalse(view.hasShownEveryLine, "\(name): the line was shown though part of it is hidden", file: file, line: line)
        XCTAssertFalse(view.displayFailed, "\(name): one failed look is not a verdict", file: file, line: line)
        XCTAssertGreaterThanOrEqual(view.inkFailures, 1, "\(name): the hidden part is a failure", file: file, line: line)
        assertAllowIsOff(rig.card, name, file: file, line: line)

        rig.evaluate(maxFailures)
        XCTAssertTrue(view.displayFailed, "\(name): repeated failures latch", file: file, line: line)
        XCTAssertFalse(view.hasShownEveryLine, "\(name): lines never shown: \(view.linesNotYetShown)", file: file, line: line)
        assertAllowIsOff(rig.card, "\(name), latched", file: file, line: line)
        XCTAssertNotNil(ApprovalTestViews.label(startingWith: displayFailedText, in: rig.card), "\(name): the banner says so",
                        file: file, line: line)
    }

    func testALongLineThatDrawsAllTheWayAcrossCanBeAllowed() throws {
        let (rig, _) = try wideRig(ApprovalLongLine.command, minimumWidth: 400)
        rig.show()
        rig.evaluate(1)
        ApprovalTestViews.readThrough(rig.view)

        XCTAssertFalse(rig.view.displayFailed)
        XCTAssertEqual(rig.view.inkFailures, 0)
        XCTAssertTrue(rig.view.hasShownEveryLine, "lines never shown: \(rig.view.linesNotYetShown)")
        XCTAssertTrue(rig.card.canAllow)
        XCTAssertEqual(rig.card.allowButton?.isEnabled, true)
    }

    func testAnOverpaintHidingOnlyTheTailOfALongLineKeepsAllowOff() throws {
        try assertHidingBlocksAllow("the last 45% of the line", from: 0.55, to: nil)
    }

    func testAnOverpaintHidingOnlyTheMiddleOfALongLineKeepsAllowOff() throws {
        try assertHidingBlocksAllow("the middle (30% to 60%) of the line", from: 0.30, to: 0.60)
    }

    func testAnOverpaintHidingOnlyTheHeadOfALongLineKeepsAllowOff() throws {
        try assertHidingBlocksAllow("the first quarter of the line", from: nil, to: 0.25)
    }

    func testARunOfSpacesInTheMiddleOfALineIsNotAFalseFailure() throws {
        let (rig, fragment) = try wideRig(ApprovalLongLine.spaced, minimumWidth: 200)
        XCTAssertLessThan(fragment.used.width, 960, "precondition: fits")
        rig.show()
        rig.evaluate(1)
        ApprovalTestViews.readThrough(rig.view)

        XCTAssertFalse(rig.view.displayFailed, "chunks of nothing but spaces demand no ink")
        XCTAssertEqual(rig.view.inkFailures, 0)
        XCTAssertTrue(rig.view.hasShownEveryLine, "lines never shown: \(rig.view.linesNotYetShown)")
        XCTAssertTrue(rig.card.canAllow)
        XCTAssertEqual(rig.card.allowButton?.isEnabled, true)
    }

    func testAWrappedLongLineWhoseContinuationIsOverpaintedIsNotShown() throws {
        let token = String(repeating: "0123456789", count: 20)   // 200 characters, no break: it wraps anywhere
        let rig = OverpaintRig(self, request: try ApprovalTestRequests.bash(token), width: 400, maxHeight: 300)
        let view = rig.view
        let fragments = rig.fragments
        XCTAssertGreaterThanOrEqual(fragments.count, 3, "precondition: the token wraps into three or more fragments")
        guard fragments.count >= 2 else { return }

        // Everything from the second fragment down is hidden; the first fragment is drawn.
        rig.paintOver(fromTextY: fragments[1].rect.minY)
        rig.show()

        rig.evaluate(1)
        let ink = try XCTUnwrap(InkCounter.count(in: view))
        XCTAssertGreaterThanOrEqual(ink.firstLineBand, 40, "precondition: the first fragment draws")
        XCTAssertFalse(view.hasShownEveryLine, "the continuation of the line is hidden: the line was not shown")
        XCTAssertTrue(view.linesNotYetShown.contains(1), "line 1 is not shown: \(view.linesNotYetShown)")
        XCTAssertFalse(view.displayFailed)
        XCTAssertGreaterThanOrEqual(view.inkFailures, 1, "the hidden continuation is a failure")
        assertAllowIsOff(rig.card, "first fragment drawn, the rest hidden")

        rig.evaluate(maxFailures)
        XCTAssertTrue(view.displayFailed, "repeated failures latch")
        assertAllowIsOff(rig.card, "latched")
        XCTAssertNotNil(ApprovalTestViews.label(startingWith: displayFailedText, in: rig.card), "the banner says so")
    }
}

// MARK: - A line completed from partial views is judged too (ATG-3)

/// A bare input view in a rig window, a clip view only a line or so tall, with a clock and an overpaint the test controls.
private final class PartialViewRig {
    let window: NSWindow
    let view: ApprovalInputView
    let box: ShowingBox
    private let clockBox: RigClock
    private let width: CGFloat
    private var overlay: OverpaintView?

    init(_ testCase: XCTestCase, request: ApprovalRequestWire, clipHeight: CGFloat, width: CGFloat = 500) {
        let box = ShowingBox(false)
        let clockBox = RigClock()
        let window = makeRigWindow(testCase, size: NSSize(width: width + 40, height: 400), appearance: NSAppearance(named: .darkAqua))
        let view = ApprovalInputView(model: ApprovalDisplayModel(request: request))
        view.isWindowShowing = { box.showing }
        view.clock = { clockBox.now }
        view.frame = NSRect(x: 0, y: 0, width: width, height: clipHeight)
        window.contentView!.addSubview(view)
        window.contentView!.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        self.box = box
        self.clockBox = clockBox
        self.window = window
        self.view = view
        self.width = width
    }

    /// Make the input view this tall (so its clip view is) and lay it out.
    func setClipHeight(_ height: CGFloat) {
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView!.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    func show() { box.showing = true }

    /// Move the input's clock a settle window (and a little more) on.
    func tick() { clockBox.now += ApprovalInputView.failureSettleWindow + 0.05 }

    /// Cover the whole text area.
    func paintOver() {
        overlay?.removeFromSuperview()
        let clip = view.contentView.frame
        let gutter = view.gutterWidth
        let overlay = OverpaintView(frame: NSRect(x: clip.minX + gutter, y: clip.minY, width: clip.width - gutter, height: clip.height),
                                    fill: ApprovalPalette.inputBackground)
        view.addSubview(overlay)
        self.overlay = overlay
    }

    /// The vertical extent of every line fragment, in text-view coordinates.
    func fragmentSpans() -> [ClosedRange<CGFloat>] {
        guard let layout = view.textView.layoutManager, let container = view.textView.textContainer else { return [] }
        layout.ensureLayout(for: container)
        let origin = view.textView.textContainerOrigin
        var spans: [ClosedRange<CGFloat>] = []
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, _, _ in
            spans.append((rect.minY + origin.y) ... (rect.maxY + origin.y))
        }
        return spans
    }

    /// The clip origins of a read-through in steps of `step`: from the top, then the end.
    func clipPositions(step: CGFloat) -> [CGFloat] {
        let clip = view.contentView.bounds.height
        let end = max(0, view.contentHeight(forWidth: view.bounds.width) - clip)
        var positions: [CGFloat] = []
        var y: CGFloat = 0
        while y < end {
            positions.append(y)
            y += step
        }
        positions.append(end)
        return positions
    }

    /// Move the clip view to each of `positions`, in order (the clock a settle window on before each, if `spaced`).
    func walk(_ positions: [CGFloat], spaced: Bool) {
        for y in positions {
            if spaced { tick() }
            ApprovalTestViews.moveClip(of: view, toY: y)
        }
    }

    /// Step through the input in steps of `step` and report whether no fragment was ever wholly in the clip
    /// (within 1 pt, the card's own tolerance) while the views of each fragment still add up to all of it.
    /// Meant for a view that is not showing (it earns nothing).
    func scan(step: CGFloat) -> (noWholeFragment: Bool, everyFragmentCompletes: Bool) {
        // A showing view sizes its text view to its text (that is what sets how far it scrolls); this one is not showing.
        let height = max(view.contentHeight(forWidth: view.bounds.width), view.contentView.bounds.height)
        if abs(view.textView.frame.height - height) > 0.5 {
            view.textView.setFrameSize(NSSize(width: view.textView.frame.width, height: height))
        }
        let spans = fragmentSpans()
        guard !spans.isEmpty else { return (false, false) }
        var seen = [[ClosedRange<CGFloat>]](repeating: [], count: spans.count)
        var noWhole = true
        for y in clipPositions(step: step) {
            ApprovalTestViews.moveClip(of: view, toY: y)
            let clip = view.contentView.bounds
            if clip.height < 16 { return (false, false) }
            for (i, span) in spans.enumerated() {
                if span.lowerBound >= clip.minY - 1, span.upperBound <= clip.maxY + 1 { noWhole = false }
                let low = max(span.lowerBound, clip.minY), high = min(span.upperBound, clip.maxY)
                if high > low { seen[i].append(low ... high) }
            }
        }
        ApprovalTestViews.moveClip(of: view, toY: 0)
        var completes = true
        for (i, span) in spans.enumerated() {
            var merged: [ClosedRange<CGFloat>] = []
            for part in seen[i].sorted(by: { $0.lowerBound < $1.lowerBound }) {
                if let last = merged.last, part.lowerBound <= last.upperBound + 1 {
                    merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, part.upperBound)
                } else {
                    merged.append(part)
                }
            }
            if merged.count != 1 || merged[0].lowerBound > span.lowerBound + 1 || merged[0].upperBound < span.upperBound - 1 {
                completes = false
            }
        }
        return (noWhole, completes)
    }
}

/// A clip view a line or so tall, moved in steps that never show a whole line: every line can only be completed
/// from two or more partial views. What those views show is what is judged.
final class ApprovalPartialViewCoverageTests: XCTestCase {

    private let maxFailures = ApprovalInputView.maxInkFailures

    /// A clip height (16 to 20 pt: tall enough to count, shorter than two lines) and a step for which no line is ever
    /// wholly in the clip at any position of the read-through, though every line is completed by the views taken together.
    private func findAwkwardStepping(_ request: ApprovalRequestWire) -> (clip: CGFloat, step: CGFloat)? {
        let probe = PartialViewRig(self, request: request, clipHeight: 16)
        for clip in stride(from: 16.0, through: 20.0, by: 0.5) {
            probe.setClipHeight(CGFloat(clip))
            for step in stride(from: 14.5, through: 3.0, by: -0.5) {
                let result = probe.scan(step: CGFloat(step))
                if result.noWholeFragment && result.everyFragmentCompletes { return (CGFloat(clip), CGFloat(step)) }
            }
        }
        return nil
    }

    private struct Stepping {
        let rig: PartialViewRig
        let positions: [CGFloat]
    }

    /// A rig of the 20-line request at the found clip height, not yet showing, and the positions to visit.
    private func steppedRig(_ request: ApprovalRequestWire, _ plan: (clip: CGFloat, step: CGFloat)) -> Stepping {
        let rig = PartialViewRig(self, request: request, clipHeight: plan.clip)
        XCTAssertEqual(rig.view.contentView.bounds.height, plan.clip, accuracy: 0.01, "precondition: the clip is as tall as planned")
        return Stepping(rig: rig, positions: rig.clipPositions(step: plan.step))
    }

    func testABlankTextAreaCannotBeWalkedPastInStepsThatNeverShowAWholeLine() throws {
        let request = try ApprovalTestRequests.shortLines(20)
        let plan = try XCTUnwrap(findAwkwardStepping(request),
                                 "no clip height (16 to 20 pt) and step (3 to 14.5 pt) shows no line whole at every position")
        let stepping = steppedRig(request, plan)
        let rig = stepping.rig, view = rig.view
        rig.paintOver()
        rig.show()
        view.updateScrollProgress()

        rig.walk(stepping.positions, spaced: false)
        XCTAssertFalse(view.hasShownEveryLine, "every line was completed from partial views of a blank area: lines never shown: \(view.linesNotYetShown)")
        XCTAssertFalse(view.linesNotYetShown.isEmpty)
        XCTAssertGreaterThanOrEqual(view.inkCheckCount, 1, "the lines that were completed from partial views were checked for ink")
        XCTAssertFalse(view.displayFailed, "one walk in one turn of the run loop is not a verdict")

        // And again, a settle window between the steps: still nothing earned.
        rig.walk(stepping.positions, spaced: true)
        XCTAssertFalse(view.hasShownEveryLine, "lines never shown: \(view.linesNotYetShown)")
        XCTAssertFalse(view.linesNotYetShown.isEmpty)

        // Looked at in a taller view (the blank area still blank), the failures are counted and latch.
        rig.box.showing = false
        rig.setClipHeight(150)
        rig.paintOver()
        rig.box.showing = true
        var looks = 0
        while !view.displayFailed && looks < 2 * maxFailures {
            rig.tick()
            view.updateScrollProgress()
            looks += 1
        }
        XCTAssertTrue(view.displayFailed, "repeated, spaced failures latch")
        XCTAssertFalse(view.hasShownEveryLine, "lines never shown: \(view.linesNotYetShown)")
    }

    func testRealTextCompletedFromPartialViewsIsStillShownAndNeverFails() throws {
        let request = try ApprovalTestRequests.shortLines(20)
        let plan = try XCTUnwrap(findAwkwardStepping(request),
                                 "no clip height (16 to 20 pt) and step (3 to 14.5 pt) shows no line whole at every position")
        let stepping = steppedRig(request, plan)
        let rig = stepping.rig, view = rig.view
        rig.show()
        view.updateScrollProgress()

        rig.walk(stepping.positions, spaced: false)

        XCTAssertFalse(view.displayFailed, "real text must not fail the ink check")
        XCTAssertEqual(view.inkFailures, 0)
        XCTAssertTrue(view.hasShownEveryLine, "lines never shown: \(view.linesNotYetShown)")
        XCTAssertGreaterThanOrEqual(view.inkCheckCount, 1, "the lines completed from partial views were checked")
    }

    func testAnOverpaintPutOverTheTextAfterTheFirstHalfWasReadStillBlocksTheRest() throws {
        let request = try ApprovalTestRequests.shortLines(20)
        let plan = try XCTUnwrap(findAwkwardStepping(request),
                                 "no clip height (16 to 20 pt) and step (3 to 14.5 pt) shows no line whole at every position")
        let stepping = steppedRig(request, plan)
        let rig = stepping.rig, view = rig.view
        rig.show()
        view.updateScrollProgress()

        let half = stepping.positions.count / 2
        rig.walk(Array(stepping.positions[..<half]), spaced: false)
        XCTAssertFalse(view.linesNotYetShown.contains(1), "precondition: the first lines were read: \(view.linesNotYetShown)")
        XCTAssertFalse(view.hasShownEveryLine, "precondition: the second half is still to read")

        rig.paintOver()
        rig.walk(Array(stepping.positions[half...]), spaced: false)

        XCTAssertFalse(view.hasShownEveryLine, "the second half was read under an overpaint: lines never shown: \(view.linesNotYetShown)")
        XCTAssertTrue(view.linesNotYetShown.contains(20), "the last line was not shown: \(view.linesNotYetShown)")
        XCTAssertFalse(view.linesNotYetShown.contains(1), "what was shown before the overpaint stays shown")
        XCTAssertFalse(view.displayFailed, "one pass in one turn of the run loop is not a verdict")
    }
}
