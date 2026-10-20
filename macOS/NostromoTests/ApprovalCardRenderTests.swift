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
// Two contracts:
//   * `ApprovalCardRenderTests`: render the input view's text area into a bitmap and count
//     pixels that are clearly not the modal background. Every fixture must draw ink, both in the
//     full card (at the app's width) and in a bare input view. Each run prints ONE content-free
//     line per fixture, prefixed `ATD-DIAG`, so the cause can be read from a CI log:
//         grep ATD-DIAG <log>
//   * `ApprovalCardFailClosedTests`: a card whose input has text but whose layout has no glyphs
//     (`ApprovalInputView.displayFailed`) can only be denied. The seam
//     `ApprovalInputView.forceNoGlyphsForTesting` makes the check treat the layout as empty.
//
// No wall clock, no pasteboard, no network, no ~/.nostromo.

// MARK: - Counting ink

/// What a bitmap of the input view's text area holds.
private struct InkCount {
    /// Pixels in the whole text area (the clip view) that differ from the modal background.
    let total: Int
    /// The same, for the top 20 pt of the text area: the first line.
    let firstLineBand: Int
    /// Pixels per point in the bitmap.
    let scale: CGFloat
    /// The text area, in pixels.
    let width: Int
    let height: Int
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

    static func luma(_ color: NSColor) -> Double {
        let c = ApprovalTestColors.rgb(color)
        return 255 * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)
    }

    static func luma(r: Double, g: Double, b: Double) -> Double {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Render `view`'s text area (its clip view, which sits to the right of the gutter and left of the
    /// scroller) and count its ink. Does not touch the text view's layout manager.
    static func count(in view: ApprovalInputView) -> InkCount? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let clip = view.contentView.frame   // in the input view's coordinates
        // A bitmap's first row is the top of the picture whatever the view's flippedness is.
        let topOffset = view.isFlipped ? clip.minY - bounds.minY : bounds.maxY - clip.maxY
        // The clip view reaches under the gutter (its bounds start at minus the gutter's width): the text
        // area starts where the gutter ends, so the gutter's own digits are not counted as text.
        let textMinX = max(clip.minX, view.verticalRulerView?.frame.maxX ?? clip.minX)
        let x0 = max(0, Int(((textMinX - bounds.minX) * scale).rounded()))
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

        var total = 0, band = 0
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let value: Double
                if direct, let raw {
                    let p = raw + y * rep.bytesPerRow + x * bytesPerPixel + colourOffset
                    value = luma(r: Double(p[0]), g: Double(p[1]), b: Double(p[2]))
                } else if let c = rep.colorAt(x: x, y: y) {
                    value = luma(c)
                } else {
                    continue
                }
                if abs(value - background) > threshold {
                    total += 1
                    if y < bandEnd { band += 1 }
                }
            }
        }
        return InkCount(total: total, firstLineBand: band, scale: scale, width: x1 - x0, height: y1 - y0)
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

/// What one fixture rendered as, with the one-line diagnostic.
private struct Measurement {
    let fixture: RenderFixture
    let ink: InkCount
    let diag: String
}

// MARK: - Pixels

final class ApprovalCardRenderTests: XCTestCase {

    /// The width of the approvals card in the app.
    private static let appCardWidth: CGFloat = 1514

    /// Lay out `fixture` in `mode`, render its text area and describe what happened.
    ///
    /// Order matters, because `textView.layoutManager` forces a fallback from TextKit 2 to TextKit 1
    /// (and the card's own code already does that on its way, see below):
    ///   1. read `textLayoutManager != nil` (`tk2BeforeRender`), before this test touches `layoutManager`;
    ///   2. render the pixels (the gutter's `drawHashMarksAndLabels` reads `layoutManager`, so a
    ///      bare view can fall back DURING the render; `tk2AfterRender` shows whether it did);
    ///   3. only then read `layoutManager`, the glyph count and the used rect.
    /// The card path has already touched `layoutManager` in `layout()` before step 1: the card's
    /// input marks lines as shown (`updateScrollProgress`) through it as soon as it is in a visible
    /// window. `tk2BeforeRender` is therefore a statement about the state AFTER layout.
    private func measure(_ fixture: RenderFixture, in mode: RenderMode) throws -> Measurement {
        let request = try fixture.request()
        let view: ApprovalInputView
        switch mode {
        case .card:
            let h = ApprovalCardHarness(self, request: request, width: Self.appCardWidth, maxHeight: fixture.cardMaxHeight)
            view = h.card.inputView
        case .bare, .bareOnScreen:
            let window = makeRigWindow(self, size: NSSize(width: Self.appCardWidth, height: fixture.bareHeight),
                                       appearance: NSAppearance(named: .darkAqua))
            view = ApprovalInputView(model: ApprovalDisplayModel(request: request))
            if mode == .bareOnScreen { view.isWindowShowing = { true } }
            view.frame = NSRect(x: 0, y: 0, width: Self.appCardWidth, height: fixture.bareHeight)
            window.contentView!.addSubview(view)
            window.contentView!.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }

        let tk2BeforeRender = view.textView.textLayoutManager != nil
        let rendered = InkCounter.count(in: view)
        let tk2AfterRender = view.textView.textLayoutManager != nil

        // Only now is the text view's layout manager touched.
        let textView = view.textView
        let layout = textView.layoutManager
        let glyphs = layout?.numberOfGlyphs ?? -1
        let used = textView.textContainer.flatMap { layout?.usedRect(for: $0) } ?? .zero
        let container = textView.textContainer?.containerSize ?? .zero
        let ink = rendered ?? InkCount(total: -1, firstLineBand: -1, scale: 0, width: 0, height: 0)
        let diag = "ATD-DIAG mode=\(mode.rawValue) fixture=\(fixture.name)"
            + " tk2BeforeRender=\(tk2BeforeRender) tk2AfterRender=\(tk2AfterRender)"
            + " glyphs=\(glyphs) usedRect=\(NSStringFromRect(used)) containerSize=\(NSStringFromSize(container))"
            + " textViewFrame=\(NSStringFromRect(textView.frame)) clipFrame=\(NSStringFromRect(view.contentView.frame))"
            + " storageLength=\(textView.textStorage?.length ?? -1) lines=\(view.lineNumbers.count)"
            + " inWindow=\(view.window != nil) windowVisible=\(view.window?.isVisible ?? false)"
            + " scale=\(ink.scale) rendered=\(rendered != nil) inkTotal=\(ink.total) inkFirstLine=\(ink.firstLineBand)"
            + " areaPx=\(ink.width)x\(ink.height)"
        print(diag)
        let full = diag + " | " + Self.layoutDump(of: view, fixture: fixture, mode: mode)
        return Measurement(fixture: fixture, ink: ink, diag: full)
    }

    /// TEMPORARY diagnostics (content-free): the view geometry, a luma histogram of the text area and a PNG of it.
    private static func layoutDump(of view: ApprovalInputView, fixture: RenderFixture, mode: RenderMode) -> String {
        let tv = view.textView
        func r(_ rect: NSRect) -> String { NSStringFromRect(rect) }
        var out = "ATD-GEOM mode=\(mode.rawValue) fixture=\(fixture.name) view=\(r(view.frame)) bounds=\(r(view.bounds))"
            + " clipFrame=\(r(view.contentView.frame)) clipBounds=\(r(view.contentView.bounds))"
            + " tvFrame=\(r(tv.frame)) tvBounds=\(r(tv.bounds)) tvSuper=\(tv.superview.map { String(describing: type(of: $0)) } ?? "nil")"
            + " tvOrigin=\(NSStringFromPoint(tv.textContainerOrigin)) tvFlipped=\(tv.isFlipped) tvHidden=\(tv.isHidden) tvAlpha=\(tv.alphaValue)"
            + " rulerDrawRect=\(r(view.verticalRulerView.flatMap { ($0 as? ApprovalLineNumberRuler)?.lastDrawRect } ?? .zero)) tvVisible=\(r(tv.visibleRect)) docVisible=\(r(view.documentVisibleRect))"
            + " rulersVisible=\(view.rulersVisible) ruler=\(view.verticalRulerView.map { r($0.frame) } ?? "nil")"
            + " thickness=\(view.verticalRulerView?.ruleThickness ?? -1) required=\(view.verticalRulerView?.requiredThickness ?? -1)"
            + " subviews=" + view.subviews.map { "\(type(of: $0))\(r($0.frame))" }.joined(separator: ",")
            + " drawsBg=\(tv.drawsBackground) fgAttr=\(String(describing: tv.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)))"
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            var hist = [Int](repeating: 0, count: 9)   // luma / 32
            var maxLuma = 0.0
            var cells: [String: Int] = [:]
            for y in 0 ..< rep.pixelsHigh {
                for x in 0 ..< rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    let l = InkCounter.luma(c)
                    hist[min(8, Int(l / 32))] += 1
                    maxLuma = max(maxLuma, l)
                    if l > 60 { cells["\(x / 100)"] = (cells["\(x / 100)"] ?? 0) + 1 }
                }
            }
            out += " | ATD-HIST mode=\(mode.rawValue) fixture=\(fixture.name) px=\(rep.pixelsWide)x\(rep.pixelsHigh) maxLuma=\(maxLuma) hist=\(hist)"
                + " brightByX100=\(cells.sorted { Int($0.key)! < Int($1.key)! }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
            if fixture == .singleLine || fixture == .twelveLines, let png = rep.representation(using: .png, properties: [:]) {
                out += " | ATD-PNG mode=\(mode.rawValue) fixture=\(fixture.name) \(png.base64EncodedString())"
            }
        }
        return out
    }

    private func assertDrawn(in mode: RenderMode, file: StaticString = #filePath, line: UInt = #line) throws {
        var byFixture: [String: Measurement] = [:]
        for fixture in RenderFixture.allCases {
            let m = try measure(fixture, in: mode)
            byFixture[fixture.name] = m
            XCTAssertGreaterThanOrEqual(m.ink.firstLineBand, 40,
                                        "\(mode.rawValue)/\(fixture.name): the first line has no drawn text. \(m.diag)",
                                        file: file, line: line)
        }
        let one = try XCTUnwrap(byFixture[RenderFixture.singleLine.name])
        let twelve = try XCTUnwrap(byFixture[RenderFixture.twelveLines.name])
        let heredoc = try XCTUnwrap(byFixture[RenderFixture.heredoc300.name])
        XCTAssertGreaterThan(twelve.ink.total, one.ink.total,
                             "\(mode.rawValue): twelve lines draw more ink than one. \(twelve.diag) | \(one.diag)", file: file, line: line)
        XCTAssertGreaterThan(heredoc.ink.total, one.ink.total,
                             "\(mode.rawValue): the visible part of 300 lines draws more ink than one line. \(heredoc.diag) | \(one.diag)",
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

    func testTmpRulerRect() throws {
        var msgs: [String] = []
        for f in RenderFixture.allCases {
            let m = try measure(f, in: .bareOnScreen)
            let marker = m.diag.components(separatedBy: " | ").first { $0.hasPrefix("ATD-GEOM") } ?? ""
            msgs.append(marker.replacingOccurrences(of: "ATD-GEOM", with: "RECT"))
        }
        XCTFail("ATD-RECT " + msgs.joined(separator: " ## "))
    }

    /// The ink counter's premise: a here-doc's fill (and the other token fills) alone is not ink.
    func testNoFillTheCardPaintsBehindTextCountsAsInk() {
        let background = InkCounter.luma(ApprovalPalette.inputBackground)
        let fills: [(String, NSColor)] = [
            ("heredocFill", ApprovalPalette.heredocFill),
        ]
        for (name, fill) in fills {
            XCTAssertLessThanOrEqual(abs(InkCounter.luma(fill) - background), InkCounter.threshold,
                                     "\(name) is further from the input background than the ink threshold: the pixel count would count it as text")
        }
        let text = InkCounter.luma(ApprovalPalette.commandText)
        XCTAssertGreaterThan(abs(text - background), InkCounter.threshold, "command text must be countable as ink")
    }
}

// MARK: - Fail closed

/// A card built the way the harness builds it, but with the render-failure seam set BEFORE its first layout.
private final class ForcedCardRig {
    let recorder: ApprovalRecorder
    let store: ApprovalStore
    let window: NSWindow
    let card: ApprovalCardView

    init(_ testCase: XCTestCase, request: ApprovalRequestWire, forceNoGlyphs: Bool,
         width: CGFloat = 560, maxHeight: CGFloat = 520, windowID: String = "w-test") {
        let window = makeRigWindow(testCase, size: NSSize(width: width + 80, height: maxHeight + 80))
        let recorder = ApprovalRecorder()
        let store = recorder.makeStore()
        store.handle(.request(request))
        let entry = store.entry(id: request.id)!
        let card = ApprovalCardView(entry: entry, store: store, windowID: { windowID },
                                    permit: ApprovalCardHarness.humanPermit, armDelay: 0, isOnScreen: { true })
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
