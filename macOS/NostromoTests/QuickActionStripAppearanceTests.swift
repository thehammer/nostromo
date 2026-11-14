import XCTest
import AppKit
import NostromoKit

// The quick-action strip with both pills (Clear Context, Compact), RENDERED: real pixels in a bitmap, read back.
//
// Frames and strings cannot see the failures these guard against: a pill sized exactly to its label draws the
// label's last glyph against (or past) the pill's edge, and a strip too narrow for its pills cuts the last
// one. So the strip is put in a window, drawn with cacheDisplay, and the label ink (pixels lighter than the
// pill's own fill) is measured against the pill frames the strip reports: all of it inside its pill, the
// rightmost ink at least 2 px from the pill's right edge, nothing drawn between or beyond the pills, and the
// last pill whole inside the strip. A disabled pill's label is dimmer than an enabled one's, and still readable
// (>= 3:1 against the strip's own background).
//
// There is no pane minimum-width constant in the app: the narrowest width tested is the narrowest the strip
// itself can be laid out in (its leading inset, both pills, the gap and the trailing inset).
// QuickActionStripView, QuickAction and Theme are compiled into this target directly. Reuses the luminance
// helpers of ModelChipAppearanceTests.swift.

private final class StripHost: NSView {}

final class QuickActionStripAppearanceTests: XCTestCase {

    private let compactID = QuickAction.compact.id
    private let clearID = QuickAction.clearContext.id

    // MARK: Rendering

    private struct Shot {
        let strip: QuickActionStripView
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let size: NSSize

        func color(x: Int, y: Int) -> NSColor? {
            guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
            return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        }

        /// A view's frame as pixel bounds (left, right-exclusive, top, bottom-exclusive), top-down.
        func pixelRect(of view: NSView) -> (l: Int, r: Int, t: Int, b: Int) {
            let f = view.convert(view.bounds, to: strip)
            return (Int((f.minX * scale).rounded()), Int((f.maxX * scale).rounded()),
                    Int(((size.height - f.maxY) * scale).rounded()), Int(((size.height - f.minY) * scale).rounded()))
        }
    }

    private func makeWindow(_ size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.appearance = NSAppearance(named: .darkAqua)
        addTeardownBlock { window.orderOut(nil) }
        return window
    }

    private func render(width: CGFloat, compactEnabled: Bool = true, file: StaticString = #filePath,
                        line: UInt = #line) throws -> Shot {
        let strip = QuickActionStripView(actions: QuickAction.replDefaults) { _ in }
        if !compactEnabled { strip.setEnabled(false, forActionID: compactID, reason: "A turn is running.") }
        let size = NSSize(width: width, height: QuickActionStripView.height)
        let window = makeWindow(size)
        let host = StripHost(frame: NSRect(origin: .zero, size: size))
        window.contentView = host
        strip.frame = host.bounds
        host.addSubview(strip)
        host.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), file: file, line: line)
        host.cacheDisplay(in: host.bounds, to: rep)
        return Shot(strip: strip, rep: rep, scale: CGFloat(rep.pixelsWide) / size.width, size: size)
    }

    /// The narrowest width the strip with both pills can be laid out in.
    private func narrowestWidth() throws -> CGFloat {
        let wide = try render(width: 600)
        let compact = try XCTUnwrap(wide.strip.pill(forActionID: compactID))
        return ceil(compact.convert(compact.bounds, to: wide.strip).maxX + 8)
    }

    private var widthsUnderTest: [CGFloat] {
        get throws { [600, 260, try narrowestWidth()] }
    }

    // MARK: Measuring

    private struct PillInk {
        var fillLuminance: Double
        var leftmost: Int?
        var rightmost: Int?
        var brightest: NSColor?
        var brightestLuminance: Double { brightest.map(modelRelativeLuminance) ?? 0 }
    }

    /// Ink: a pixel clearly lighter than the pill's own fill. Scans every column of the pill's rows between
    /// `from` and `to` (pixel columns).
    private func ink(in shot: Shot, pill: NSButton, columns: Range<Int>? = nil) throws -> PillInk {
        let r = shot.pixelRect(of: pill)
        let midY = (r.t + r.b) / 2
        let fill = try XCTUnwrap(shot.color(x: r.l + Int(4 * shot.scale), y: midY), "the pill's fill")
        let fillLum = modelRelativeLuminance(fill)
        var result = PillInk(fillLuminance: fillLum)
        for x in (columns ?? 0 ..< shot.rep.pixelsWide) {
            for y in r.t ..< r.b {
                guard let c = shot.color(x: x, y: y), modelRelativeLuminance(c) > fillLum + 0.04 else { continue }
                result.leftmost = min(result.leftmost ?? x, x)
                result.rightmost = max(result.rightmost ?? x, x)
                if modelRelativeLuminance(c) > (result.brightest.map(modelRelativeLuminance) ?? -1) { result.brightest = c }
            }
        }
        return result
    }

    // MARK: Label ink inside the pill

    func testEachPillsLabelInkIsInsideItsPillWithAtLeastTwoPixelsToTheRightEdgeAtEveryWidth() throws {
        for width in try widthsUnderTest {
            let shot = try render(width: width)
            for id in [clearID, compactID] {
                let pill = try XCTUnwrap(shot.strip.pill(forActionID: id))
                let r = shot.pixelRect(of: pill)
                let result = try ink(in: shot, pill: pill, columns: r.l ..< r.r)

                let right = try XCTUnwrap(result.rightmost, "\(id) drew no label at width \(width)")
                let left = try XCTUnwrap(result.leftmost)
                XCTAssertGreaterThanOrEqual(r.r - (right + 1), 2, "\(id) label ink is within 2 px of the pill's right edge at width \(width)")
                XCTAssertGreaterThanOrEqual(left - r.l, 2, "\(id) label ink is within 2 px of the pill's left edge at width \(width)")
            }
        }
    }

    func testNoLabelInkSpillsOutsideThePillsIntoTheGapOrBeyondThem() throws {
        for width in try widthsUnderTest {
            let shot = try render(width: width)
            let clear = try XCTUnwrap(shot.strip.pill(forActionID: clearID))
            let compact = try XCTUnwrap(shot.strip.pill(forActionID: compactID))
            let a = shot.pixelRect(of: clear), b = shot.pixelRect(of: compact)

            for (name, columns) in [("before the first pill", 0 ..< a.l), ("between the pills", a.r ..< b.l),
                                    ("after the last pill", b.r ..< shot.rep.pixelsWide)] {
                let spill = try ink(in: shot, pill: compact, columns: columns)
                XCTAssertNil(spill.rightmost, "ink \(name) at width \(width)")
            }
        }
    }

    // MARK: The strip's edge

    func testNeitherPillIsCutByTheStripsTrailingEdgeAtEveryWidth() throws {
        for width in try widthsUnderTest {
            let shot = try render(width: width)
            for id in [clearID, compactID] {
                let pill = try XCTUnwrap(shot.strip.pill(forActionID: id))
                let frame = pill.convert(pill.bounds, to: shot.strip)
                XCTAssertLessThanOrEqual(frame.maxX, width, "\(id) frame ends inside the strip at width \(width)")
                XCTAssertGreaterThanOrEqual(frame.minX, 0)

                // Its last drawn column is still the pill's fill, not the strip's background.
                let r = shot.pixelRect(of: pill)
                let fill = try XCTUnwrap(shot.color(x: r.l + Int(4 * shot.scale), y: (r.t + r.b) / 2))
                let lastColumn = try XCTUnwrap(shot.color(x: r.r - 1, y: (r.t + r.b) / 2), "\(id) has a last column inside the bitmap at width \(width)")
                XCTAssertLessThan(abs(modelRelativeLuminance(lastColumn) - modelRelativeLuminance(fill)), 0.03,
                                  "\(id)'s right edge is drawn whole at width \(width)")
            }
        }
    }

    func testThePillsAreWideEnoughForTheirLabelsPlusPaddingOnBothSides() throws {
        let shot = try render(width: 600)
        for action in QuickAction.replDefaults {
            let pill = try XCTUnwrap(shot.strip.pill(forActionID: action.id))
            let label = ceil(pill.attributedTitle.size().width)

            XCTAssertGreaterThanOrEqual(pill.frame.width, label + 2 * QuickActionStripView.pillHorizontalPadding - 0.5, action.label)
        }
    }

    // MARK: Disabled look

    func testADisabledPillsLabelIsDimmerThanTheSamePillEnabled() throws {
        let enabled = try render(width: 600)
        let disabled = try render(width: 600, compactEnabled: false)
        let pillOn = try XCTUnwrap(enabled.strip.pill(forActionID: compactID))
        let pillOff = try XCTUnwrap(disabled.strip.pill(forActionID: compactID))

        let on = try ink(in: enabled, pill: pillOn, columns: enabled.pixelRect(of: pillOn).l ..< enabled.pixelRect(of: pillOn).r)
        let off = try ink(in: disabled, pill: pillOff, columns: disabled.pixelRect(of: pillOff).l ..< disabled.pixelRect(of: pillOff).r)

        XCTAssertNotNil(off.rightmost, "a disabled pill is dimmed, not blank")
        XCTAssertLessThan(off.brightestLuminance, on.brightestLuminance - 0.1, "disabled ink is clearly dimmer")
    }

    func testTheEnabledPillNextToADisabledOneKeepsItsFullBrightness() throws {
        let shot = try render(width: 600, compactEnabled: false)
        let clear = try XCTUnwrap(shot.strip.pill(forActionID: clearID))
        let compact = try XCTUnwrap(shot.strip.pill(forActionID: compactID))

        let a = try ink(in: shot, pill: clear, columns: shot.pixelRect(of: clear).l ..< shot.pixelRect(of: clear).r)
        let b = try ink(in: shot, pill: compact, columns: shot.pixelRect(of: compact).l ..< shot.pixelRect(of: compact).r)

        XCTAssertGreaterThan(a.brightestLuminance, b.brightestLuminance + 0.1)
    }

    func testADisabledPillsLabelIsStillAtLeastThreeToOneAgainstTheStripBackgroundInThePixels() throws {
        let shot = try render(width: 600, compactEnabled: false)
        let pill = try XCTUnwrap(shot.strip.pill(forActionID: compactID))
        let r = shot.pixelRect(of: pill)
        let result = try ink(in: shot, pill: pill, columns: r.l ..< r.r)
        let background = try XCTUnwrap(shot.color(x: Int(2 * shot.scale), y: (r.t + r.b) / 2), "the strip background")
        let text = try XCTUnwrap(result.brightest)

        let ratio = modelContrastRatio(modelRelativeLuminance(text), modelRelativeLuminance(background))
        XCTAssertGreaterThanOrEqual(ratio, 3.0, "rendered disabled label \(text) on the strip \(background): \(ratio):1")
    }

    func testTheDisabledLabelColourIsAtLeastThreeToOneAgainstTheStripBackgroundByColour() {
        // The label's alpha composited over the strip's background, the way it is drawn.
        let bg = Theme.bgBar.usingColorSpace(.sRGB)!
        let label = QuickActionStripView.disabledLabelColor.usingColorSpace(.sRGB)!
        let a = label.alphaComponent
        let over = NSColor(srgbRed: label.redComponent * a + bg.redComponent * (1 - a),
                           green: label.greenComponent * a + bg.greenComponent * (1 - a),
                           blue: label.blueComponent * a + bg.blueComponent * (1 - a), alpha: 1)

        let ratio = modelContrastRatio(modelRelativeLuminance(over), modelRelativeLuminance(bg))
        XCTAssertGreaterThanOrEqual(ratio, 3.0, "\(ratio):1")
        XCTAssertLessThan(modelRelativeLuminance(over), modelRelativeLuminance(QuickActionStripView.enabledLabelColor),
                          "and still dimmer than the enabled label")
    }
}
