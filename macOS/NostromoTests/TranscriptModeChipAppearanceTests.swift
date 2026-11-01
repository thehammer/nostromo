import XCTest
import AppKit
import NostromoKit

// FV4: what the transcript view chip looks like.
//
// The app is pinned to Dark Aqua (#234): a system-drawn label would resolve dark-on-dark on this
// always-dark UI. So the chip draws its own title with explicit colours, and these tests prove it the
// way ModelChipAppearanceTests does for its sibling: the REAL chip, in a REAL input bar (bound the way
// `ReplView` binds it), is rendered into a bitmap and the pixels are measured. The PRD asks for
// >= 4.5:1 for text, in the key window and in an inactive one, in both modes; and a visible focus ring
// (>= 3:1 against the bar) only while the chip holds the keyboard.
//
// `StateWindow`, `WindowBag`, `measureRegion`, `modelRelativeLuminance` and `modelContrastRatio` are
// ModelChipAppearanceTests' shared helpers.

// MARK: - Pixel helpers

private func fv4Bitmap(of host: NSView) -> (rep: NSBitmapImageRep, scale: CGFloat)? {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return (rep, CGFloat(rep.pixelsWide) / host.bounds.width)
}

private func fv4PixelLuminance(of host: NSView, at point: NSPoint) -> Double {
    guard let (rep, scale) = fv4Bitmap(of: host),
          let color = rep.colorAt(x: Int(point.x * scale), y: Int((host.bounds.height - point.y) * scale)) else { return 0 }
    return modelRelativeLuminance(color)
}

/// The box (in `host` coordinates) around every pixel of `region` brighter than `threshold`.
private func fv4InkBounds(of host: NSView, region: NSRect, brighterThan threshold: Double) -> NSRect? {
    guard let (rep, scale) = fv4Bitmap(of: host) else { return nil }
    var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
    for x in Int(region.minX * scale) ..< Int(region.maxX * scale) {
        for y in Int((host.bounds.height - region.maxY) * scale) ..< Int((host.bounds.height - region.minY) * scale) {
            guard let color = rep.colorAt(x: x, y: y), modelRelativeLuminance(color) > threshold else { continue }
            let px = CGFloat(x) / scale
            let py = host.bounds.height - CGFloat(y) / scale
            minX = min(minX, px); maxX = max(maxX, px + 1 / scale)
            minY = min(minY, py - 1 / scale); maxY = max(maxY, py)
        }
    }
    guard minX.isFinite else { return nil }
    return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// `top` laid over opaque `bottom`.
private func fv4Composite(_ top: NSColor, over bottom: NSColor) -> NSColor {
    guard let t = top.usingColorSpace(.sRGB), let b = bottom.usingColorSpace(.sRGB) else { return bottom }
    let a = t.alphaComponent
    return NSColor(srgbRed: t.redComponent * a + b.redComponent * (1 - a),
                   green: t.greenComponent * a + b.greenComponent * (1 - a),
                   blue: t.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
}

// MARK: - Tests

final class TranscriptModeChipAppearanceTests: XCTestCase {
    private var previousAppearance: NSAppearance?
    private let windows = WindowBag()
    private var worlds: [FV4StoreWorld] = []

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
        worlds = []
    }

    override func tearDown() {
        windows.tearDown()
        worlds = []
        NSApplication.shared.appearance = previousAppearance
        super.tearDown()
    }

    /// The input bar's background, resolved the way the dark UI draws it.
    private func barBackground() -> NSColor {
        var cg = Theme.bgBar.cgColor
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { cg = Theme.bgBar.cgColor }
        return NSColor(cgColor: cg) ?? .black
    }

    private struct Host {
        let window: StateWindow
        let bar: ReplInputBar
        var chip: TranscriptModeChip { bar.modeChip }
    }

    /// A real input bar bound to a focus in `mode`, in a window that reports itself key (or inactive).
    private func makeHost(mode: TranscriptViewMode, key: Bool, focused: Bool = false, width: CGFloat = 600) -> Host {
        let world = FV4StoreWorld(self)
        worlds.append(world)
        let tag = "fv4-chip-\(UUID().uuidString)"
        world.store.setMode(tag: tag, mode)
        let window = windows.makeStateWindow(key: key, width: width, height: 60)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        window.contentView = content
        let bar = ReplInputBar(frame: content.bounds)
        content.addSubview(bar)
        bar.bindMode(tag: tag, store: world.store)
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
        if focused { _ = bar.modeChip.becomeFirstResponder() }
        XCTAssertEqual(window.isKeyWindow, key, "precondition: the host window is \(key ? "key" : "inactive")")
        XCTAssertEqual(bar.modeChip.mode, mode, "precondition: the chip reads the focus's mode")
        return Host(window: window, bar: bar)
    }

    private func measure(_ host: Host) -> RegionLuminance {
        let frame = host.chip.frame
        return measureRegion(of: host.bar, region: frame, textArea: frame.insetBy(dx: 6, dy: 4))
    }

    /// The best contrast (against `background`, a relative luminance) among the pixels of each side's
    /// outer `band` points of the chip, along the middle of the side. A focus ring is on every side.
    private func edgeContrast(host: NSView, chip: NSRect, background: Double, band: CGFloat = 3) -> [String: Double] {
        guard let (rep, scale) = fv4Bitmap(of: host) else { return [:] }
        func best(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> Double {
            var result = 0.0
            var px = Int(x.lowerBound * scale)
            while px <= Int(x.upperBound * scale) {
                var py = Int((host.bounds.height - y.upperBound) * scale)
                while py <= Int((host.bounds.height - y.lowerBound) * scale) {
                    if let c = rep.colorAt(x: px, y: py) {
                        result = max(result, modelContrastRatio(modelRelativeLuminance(c), background))
                    }
                    py += 1
                }
                px += 1
            }
            return result
        }
        let midX = chip.midX, midY = chip.midY
        return [
            "left": best(x: chip.minX ... (chip.minX + band), y: (midY - 2) ... (midY + 2)),
            "right": best(x: (chip.maxX - band - 0.5) ... (chip.maxX - 0.5), y: (midY - 2) ... (midY + 2)),
            "top": best(x: (midX - 2) ... (midX + 2), y: (chip.maxY - band - 0.5) ... (chip.maxY - 0.5)),
            "bottom": best(x: (midX - 2) ... (midX + 2), y: chip.minY ... (chip.minY + band)),
        ]
    }

    private func barBackgroundLuminance(_ host: Host) -> Double {
        // Three points left of the chip is the bar itself (the gap before the chip's slot).
        fv4PixelLuminance(of: host.bar, at: NSPoint(x: host.chip.frame.minX - 3, y: host.chip.frame.midY))
    }

    // MARK: Legibility

    func testTheTitleMeetsContrastInBothModesInTheKeyWindowAndAnInactiveOne() {
        for mode in TranscriptViewMode.allCases {
            for key in [true, false] {
                let m = measure(makeHost(mode: mode, key: key))
                let ratio = modelContrastRatio(m.brightestText, m.fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5,
                    "\(mode), \(key ? "key" : "inactive") window: the title must reach 4.5:1 against the chip's fill (text \(m.brightestText), fill \(m.fill), ratio \(ratio))")
            }
        }
    }

    func testTheTitleIsLighterThanTheFillItSitsOn() {
        // Contrast alone would also pass for dark text on a light fill; this UI is light on dark.
        for mode in TranscriptViewMode.allCases {
            let m = measure(makeHost(mode: mode, key: true))
            XCTAssertGreaterThan(m.brightestText, m.fill + 0.2, "\(mode): text \(m.brightestText), fill \(m.fill)")
        }
    }

    func testAFocusLeftInAllActivityReadsAtAGlanceBecauseItsFillIsBrighter() {
        let focus = measure(makeHost(mode: .focus, key: true))
        let all = measure(makeHost(mode: .allActivity, key: true))

        XCTAssertGreaterThan(all.fill, focus.fill, "All activity's fill is brighter than Focus's (\(all.fill) vs \(focus.fill))")
    }

    func testTheColoursReachContrastByArithmeticToo() {
        let bar = barBackground()
        let title = NSColor.white.withAlphaComponent(TranscriptModeChip.titleAlpha)
        for (mode, fill) in [("Focus", TranscriptModeChip.focusFillColor), ("All activity", TranscriptModeChip.allActivityFillColor)] {
            let fillOnBar = fv4Composite(fill, over: bar)
            let titleOnFill = fv4Composite(title, over: fillOnBar)
            let ratio = modelContrastRatio(modelRelativeLuminance(titleOnFill), modelRelativeLuminance(fillOnBar))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(mode): \(ratio):1")
        }
        XCTAssertEqual(TranscriptModeChip.titleAlpha, 0.88, accuracy: 0.0001, "the PRD's title alpha, as the model chip's")
        XCTAssertEqual(TranscriptModeChip.focusFillColor, ModelChip.fillColor, "the sibling's fill")
    }

    func testTheTitleIsNotSystemDrawnSoTheAppAppearanceDoesNotChangeIt() {
        for mode in TranscriptViewMode.allCases {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            let inAqua = measure(makeHost(mode: mode, key: true))
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            let inDark = measure(makeHost(mode: mode, key: true))

            XCTAssertGreaterThan(inAqua.brightestText, inAqua.fill + 0.2, "\(mode): even under Aqua the title is drawn, and light on the dark fill")
            XCTAssertGreaterThan(inDark.brightestText, inDark.fill + 0.2, "\(mode): the title is drawn under Dark Aqua")
            XCTAssertEqual(inAqua.brightestText, inDark.brightestText, accuracy: 0.02,
                           "\(mode): the same pixels whatever the app appearance is: no system-drawn title")
        }
    }

    // MARK: Keyboard focus

    func testAFocusedChipDrawsARingOnEverySideThatAnUnfocusedOneLacks() {
        for mode in TranscriptViewMode.allCases {
            let plain = makeHost(mode: mode, key: true, focused: false)
            let ringed = makeHost(mode: mode, key: true, focused: true)
            let background = barBackgroundLuminance(plain)

            let without = edgeContrast(host: plain.bar, chip: plain.chip.frame, background: background)
            let with = edgeContrast(host: ringed.bar, chip: ringed.chip.frame, background: background)

            XCTAssertEqual(Set(with.keys), ["left", "right", "top", "bottom"])
            for (side, ratio) in with {
                XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(mode): the focus ring on the \(side) edge must reach 3:1 against the bar (got \(ratio):1)")
            }
            for (side, ratio) in without {
                XCTAssertLessThan(ratio, 3.0, "\(mode): an unfocused chip has no ring on the \(side) edge (got \(ratio):1)")
            }
        }
    }

    func testTheFocusRingGoesWhenFocusDoes() {
        let host = makeHost(mode: .focus, key: true, focused: true)
        let background = barBackgroundLuminance(host)
        XCTAssertGreaterThanOrEqual(edgeContrast(host: host.bar, chip: host.chip.frame, background: background)["left"] ?? 0, 3.0,
                                    "precondition: ringed")

        _ = host.chip.resignFirstResponder()
        host.chip.displayIfNeeded()

        XCTAssertFalse(host.chip.hasKeyboardFocus)
        XCTAssertLessThan(edgeContrast(host: host.bar, chip: host.chip.frame, background: background)["left"] ?? 0, 3.0)
    }

    func testTheTitleStaysLegibleWhileTheChipHasKeyboardFocus() {
        for mode in TranscriptViewMode.allCases {
            for key in [true, false] {
                let m = measure(makeHost(mode: mode, key: key, focused: true))
                let ratio = modelContrastRatio(m.brightestText, m.fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "focused, \(mode), \(key ? "key" : "inactive") window: \(ratio):1")
                XCTAssertGreaterThan(m.brightestText, m.fill + 0.2)
            }
        }
    }

    // MARK: A squeezed chip

    func testTheLabelTruncatesInsideItsPaddingAtANarrowWidthAndNeverWraps() {
        for mode in TranscriptViewMode.allCases {
            let window = windows.makeStateWindow(key: true)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
            host.wantsLayer = true
            host.layer?.backgroundColor = barBackground().cgColor
            window.contentView = host
            let chip = TranscriptModeChip()
            let frame = NSRect(x: 12, y: 14, width: 44, height: TranscriptModeChip.height)
            chip.frame = frame
            host.addSubview(chip)
            chip.apply(mode)
            window.orderFront(nil)

            let fill = measureRegion(of: host, region: frame, textArea: frame.insetBy(dx: 6, dy: 4)).fill
            let ink = fv4InkBounds(of: host, region: frame.insetBy(dx: 2, dy: 2), brighterThan: fill + 0.2)

            guard let ink else { XCTFail("\(mode): at \(frame.width) pt the chip still shows something"); continue }
            let padding = TranscriptModeChip.horizontalPadding
            XCTAssertGreaterThanOrEqual(ink.minX, frame.minX + padding - 1.5, "\(mode): the text stays inside the left padding (ink \(ink))")
            XCTAssertLessThanOrEqual(ink.maxX, frame.maxX - padding + 1.5, "\(mode): the text stops at the right padding (ink \(ink))")
            let line = ceil(NSAttributedString(string: "Focus", attributes: [.font: TranscriptModeChip.font]).size().height)
            XCTAssertLessThanOrEqual(ink.height, line + 3, "\(mode): one line of text, never two (ink \(ink))")
        }
    }
}
