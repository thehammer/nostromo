import XCTest
import AppKit
import NostromoKit

// T3b2: the structure affordances as RENDERED pixels (frame-only tests missed a clipped digit in #456/#457).
// Each case draws the pane with `cacheDisplay` at 260 pt and 600 pt, in a key and a non-key window, under Dark
// Aqua (the app's only look; the sibling tracker appearance tests do the same), and reads ink:
//
//  - the "+ Add item" row: its label is one line of ink, inside the row, and the colour that came out on the
//    screen has at least 4.5:1 against the row's background; the add field, once opened, has its text on the
//    label's baseline (within 1 pt);
//  - the drop indicator (shown through the pane's drag methods, the calls the AppKit drag session makes): the ink
//    it adds lies between the two rows it separates, touches neither row's ink, is as thin as the 2 pt line it
//    is meant to be (so it moved no row), has at least 3:1 against the background, and hiding it takes all of
//    that ink away again;
//  - the remove banner with a 60-character "W" title: the title is cut with an ellipsis, its ink ends at least
//    4 pt left of the Undo button's ink, and the Undo text is inside its button on all four sides.
//
// The contrast cases measure the colour of the pixels actually drawn (the most extreme pixel of the ink against
// the background next to it), so a colour that is too faint fails here even when the theme constant is unchanged
// somewhere else.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Draw the drop indicator by inserting a spacer row or moving a row (`showDropIndicator`): the indicator's
//    changed ink is more than a 2 pt line and `TrackerStructureEditingTests` "frames unchanged during drag" fails.
//  - Let the notice's label run under the Undo button (`TrackerNoticeView.layout`), or stop truncating its title
//    at the tail: the title-clear-of-Undo and ellipsis assertions fail.
//  - Make the add label's colour fainter (`TrackerRowView` add row): the add-row contrast assertion fails.
//  - Shift the add field's frame by a couple of points (`TrackerRowView.layoutSubviews` for `.addItem`): the
//    baseline assertion fails.

// MARK: - Pixels

private struct RGB {
    let r: Int, g: Int, b: Int
    func distance(to other: RGB) -> Int { abs(r - other.r) + abs(g - other.g) + abs(b - other.b) }
    var color: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
}

/// The pane as pixels. Coordinates in and out are the pane's own, in points, y down (the pane is flipped).
private struct Shot {
    let scale: CGFloat
    let bounds: NSRect
    private let pixelsWide: Int
    private let pixelsHigh: Int
    private let data: UnsafeMutablePointer<UInt8>
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let channel: Int
    /// Keeps the bitmap (and so `data`) alive.
    private let rep: NSBitmapImageRep

    init?(of view: NSView) {
        let bounds = view.bounds
        var made: NSBitmapImageRep?
        var scale: CGFloat = 4
        if let hand = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            hand.size = bounds.size
            view.cacheDisplay(in: bounds, to: hand)
            if (hand.colorAt(x: Int(4 * scale), y: Int(2 * scale))?.alphaComponent ?? 0) > 0.5 { made = hand }
        }
        if made == nil, let automatic = view.bitmapImageRepForCachingDisplay(in: bounds) {
            view.cacheDisplay(in: bounds, to: automatic)
            made = automatic
            scale = CGFloat(automatic.pixelsWide) / bounds.width
        }
        guard let rep = made, let data = rep.bitmapData, rep.bitsPerSample == 8, rep.bitsPerPixel >= 24 else { return nil }
        self.rep = rep
        self.data = data
        self.scale = scale
        self.bounds = bounds
        pixelsWide = rep.pixelsWide
        pixelsHigh = rep.pixelsHigh
        bytesPerRow = rep.bytesPerRow
        bytesPerPixel = rep.bitsPerPixel / 8
        channel = rep.bitmapFormat.contains(.alphaFirst) ? 1 : 0
    }

    private func rgb(_ x: Int, _ y: Int) -> RGB {
        let p = data + y * bytesPerRow + x * bytesPerPixel + channel
        return RGB(r: Int(p[0]), g: Int(p[1]), b: Int(p[2]))
    }

    /// The pixel columns and rows `rect` covers (clamped to the bitmap); nil when it covers none.
    private func pixels(_ rect: NSRect) -> (xs: Range<Int>, ys: Range<Int>)? {
        let r = rect.intersection(bounds)
        guard !r.isNull, !r.isEmpty else { return nil }
        let x0 = max(0, Int((r.minX * scale).rounded(.down))), x1 = min(pixelsWide, Int((r.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((r.minY * scale).rounded(.down))), y1 = min(pixelsHigh, Int((r.maxY * scale).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return nil }
        return (x0..<x1, y0..<y1)
    }

    /// The colour at a point of the pane.
    func color(at point: NSPoint) -> RGB {
        let x = min(max(Int(point.x * scale), 0), pixelsWide - 1), y = min(max(Int(point.y * scale), 0), pixelsHigh - 1)
        return rgb(x, y)
    }

    private func box(xs: ClosedRange<Int>, ys: ClosedRange<Int>) -> NSRect {
        NSRect(x: CGFloat(xs.lowerBound) / scale, y: CGFloat(ys.lowerBound) / scale,
               width: CGFloat(xs.count) / scale, height: CGFloat(ys.count) / scale)
    }

    /// The smallest rectangle holding every pixel in `rect` that differs from `background`.
    func inkBox(in rect: NSRect, against background: RGB, threshold: Int = 120) -> NSRect? {
        guard let range = pixels(rect) else { return nil }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in range.ys {
            for x in range.xs where rgb(x, y).distance(to: background) > threshold {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return box(xs: minX...maxX, ys: minY...maxY)
    }

    /// The bands of pixel rows in `rect` that hold ink, top to bottom: one per line of text.
    func inkRuns(in rect: NSRect, against background: RGB, threshold: Int = 120) -> [ClosedRange<Int>] {
        guard let range = pixels(rect) else { return [] }
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for y in range.ys {
            let hasInk = range.xs.contains { rgb($0, y).distance(to: background) > threshold }
            if hasInk {
                if start == nil { start = y }
            } else if let s = start {
                runs.append(s...(y - 1))
                start = nil
            }
        }
        if let s = start { runs.append(s...(range.ys.upperBound - 1)) }
        return runs
    }

    /// The pixel in `rect` farthest from `background`: the colour the ink reached on the screen.
    func peak(in rect: NSRect, against background: RGB) -> RGB? {
        guard let range = pixels(rect) else { return nil }
        var best: RGB?
        var bestDistance = 0
        for y in range.ys {
            for x in range.xs {
                let pixel = rgb(x, y)
                let d = pixel.distance(to: background)
                if d > bestDistance { best = pixel; bestDistance = d }
            }
        }
        return best
    }

    /// The smallest rectangle holding every pixel in `rect` that is different in `other` (a picture of
    /// the same pane).
    func changedBox(from other: Shot, in rect: NSRect, threshold: Int = 40) -> NSRect? {
        guard pixelsWide == other.pixelsWide, pixelsHigh == other.pixelsHigh, let range = pixels(rect) else { return nil }
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for y in range.ys {
            for x in range.xs where rgb(x, y).distance(to: other.rgb(x, y)) > threshold {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        return box(xs: minX...maxX, ys: minY...maxY)
    }
}

// MARK: - Contrast

private func luminance(_ color: NSColor) -> Double {
    let c = color.usingColorSpace(.sRGB) ?? color
    func lin(_ v: CGFloat) -> Double {
        let d = Double(v)
        return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
}

private func over(_ fill: NSColor, _ base: NSColor) -> NSColor {
    let f = fill.usingColorSpace(.sRGB) ?? fill, b = base.usingColorSpace(.sRGB) ?? base
    let a = f.alphaComponent
    return NSColor(srgbRed: f.redComponent * a + b.redComponent * (1 - a), green: f.greenComponent * a + b.greenComponent * (1 - a),
                   blue: f.blueComponent * a + b.blueComponent * (1 - a), alpha: 1)
}

private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
    let la = luminance(a), lb = luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func ratio(_ a: RGB, _ b: RGB) -> Double { ratio(a.color, b.color) }

// MARK: - Tests

final class TrackerStructureAppearanceTests: XCTestCase {

    private static let widths: [CGFloat] = [260, 600]
    private static let paneHeight: CGFloat = 700

    private func harness(width: CGFloat, keyWindow: Bool = true,
                         configure: @escaping (inout TrackerBoardScript) throws -> Void = { _ in }) throws -> TrackerEditHarness {
        let h = try TrackerEditHarness(self, size: NSSize(width: width, height: Self.paneHeight),
                                       appearance: NSAppearance(named: .darkAqua), configure: configure)
        if !keyWindow { h.window.resignKey() }
        return h
    }

    private func shot(_ h: TrackerEditHarness, file: StaticString = #filePath, line: UInt = #line) throws -> Shot {
        h.rig.host.layoutSubtreeIfNeeded()
        h.rig.host.displayIfNeeded()
        return try XCTUnwrap(Shot(of: h.pane), "could not draw the pane", file: file, line: line)
    }

    private func paneRect(_ view: NSView, _ h: TrackerEditHarness) -> NSRect { h.pane.convert(view.bounds, from: view) }

    /// Scroll so `key`'s row has some rows above it on screen, and hand back the row and its rectangle in the pane.
    private func reveal(_ h: TrackerEditHarness, _ key: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> (row: TrackerRowView, rect: NSRect) {
        let row = try XCTUnwrap(h.pane.rowViews[key], "no row \(key); rows: \(h.pane.displayedRows.map(\.key))", file: file, line: line)
        h.rig.scroll(to: max(0, row.frame.minY - 120))
        h.rig.host.layoutSubtreeIfNeeded()
        h.rig.host.displayIfNeeded()
        return (row, paneRect(row, h))
    }

    /// Every side of the ink is at least one pixel inside `rect`.
    private func assertInside(_ ink: NSRect?, _ rect: NSRect, scale: CGFloat, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let ink else {
            XCTFail("\(message): no ink at all", file: file, line: line)
            return
        }
        let px = 1 / scale
        XCTAssertGreaterThanOrEqual(ink.minX, rect.minX + px - 0.001, "\(message): left", file: file, line: line)
        XCTAssertLessThanOrEqual(ink.maxX, rect.maxX - px + 0.001, "\(message): right", file: file, line: line)
        XCTAssertGreaterThanOrEqual(ink.minY, rect.minY + px - 0.001, "\(message): top", file: file, line: line)
        XCTAssertLessThanOrEqual(ink.maxY, rect.maxY - px + 0.001, "\(message): bottom", file: file, line: line)
    }

    private func label(_ width: CGFloat, _ keyWindow: Bool) -> String { "width \(Int(width)), \(keyWindow ? "key" : "non-key")" }

    // MARK: The add row

    func testTheAddRowsLabelIsOneLineOfInkInsideItsRowAndHasTheContrastTheContractAsksFor() throws {
        for width in Self.widths {
            for keyWindow in [true, false] {
                let h = try harness(width: width, keyWindow: keyWindow)
                let (row, rowRect) = try reveal(h, TrackerRow.addKey("now"))
                let s = try shot(h)
                let text = label(width, keyWindow)
                let bg = s.color(at: NSPoint(x: rowRect.minX + 4, y: rowRect.maxY - 1))
                let button = try XCTUnwrap(row.addItemButton)
                let buttonRect = paneRect(button, h)

                XCTAssertEqual(s.inkRuns(in: rowRect, against: bg).count, 1, "\(text): the label is one line of ink")
                let ink = s.inkBox(in: rowRect, against: bg)
                assertInside(ink, rowRect, scale: s.scale, "\(text): the label's ink is inside the row")
                assertInside(ink, buttonRect, scale: s.scale, "\(text): and inside the button's frame")
                if let ink {
                    XCTAssertLessThan(ink.height, 16, "\(text): a single short line, not a clipped block")
                    XCTAssertGreaterThan(ink.width, 30, "\(text): the words are all there")
                }
                let peak = try XCTUnwrap(s.peak(in: rowRect, against: bg), "\(text): the label is drawn")
                XCTAssertGreaterThanOrEqual(ratio(peak, bg), 4.5, "\(text): the label's drawn colour against the row")
            }
        }
    }

    func testTheAddFieldsTextSitsOnTheLabelsBaseline() throws {
        for width in Self.widths {
            for keyWindow in [true, false] {
                let h = try harness(width: width, keyWindow: keyWindow)
                let (row, rowRect) = try reveal(h, TrackerRow.addKey("now"))
                let text = label(width, keyWindow)
                // The words "+ Add item" have no descender, so the bottom of their ink is the baseline. Only the
                // first 20 pt are read: the caret, which can be taller, sits at the end of what is typed.
                let start = NSRect(x: rowRect.minX + TrackerRowView.textX - 2, y: rowRect.minY, width: 22, height: rowRect.height)

                let before = try shot(h)
                let bg = before.color(at: NSPoint(x: rowRect.minX + 4, y: rowRect.maxY - 1))
                let labelInk = try XCTUnwrap(before.inkBox(in: start, against: bg), "\(text): the label is drawn")

                let button = try XCTUnwrap(row.addItemButton)
                button.performClick(nil)
                h.rig.settle()
                let field = try XCTUnwrap(row.addField, "\(text): the row became a field")
                if !keyWindow { h.window.resignKey() }
                h.type("+ Add item", into: field)
                let after = try shot(h)
                let fieldBg = after.color(at: NSPoint(x: rowRect.minX + 4, y: rowRect.maxY - 1))
                let fieldInk = try XCTUnwrap(after.inkBox(in: start, against: fieldBg), "\(text): the field shows its text")

                XCTAssertEqual(fieldInk.maxY, labelInk.maxY, accuracy: 1.0, "\(text): the field's baseline is the label's (label \(labelInk), field \(fieldInk))")
                assertInside(fieldInk, rowRect, scale: after.scale, "\(text): the field's ink is inside the row")
            }
        }
    }

    // MARK: The drop indicator

    private func payload(_ h: TrackerEditHarness, _ id: String) -> (id: String, pane: String) {
        (id: id, pane: h.pane.paneIdentity)
    }

    func testTheDropIndicatorsInkLiesBetweenTheTwoRowsItSeparatesAndOverlapsNeitherAndGoesWhenHidden() throws {
        for width in Self.widths {
            for keyWindow in [true, false] {
                let h = try harness(width: width, keyWindow: keyWindow)
                let text = label(width, keyWindow)
                // The line goes above draft-1148, between it and revie-1111.
                let (below, belowRect) = try reveal(h, "item:draft-1148")
                let aboveRow = try XCTUnwrap(h.pane.rowViews["item:revie-1111"])
                let aboveRect = paneRect(aboveRow, h)
                XCTAssertEqual(aboveRect.maxY, belowRect.minY, accuracy: 0.5, "setup: the two rows are neighbours")
                let frames = h.rig.rowFrames

                let plain = try shot(h)
                let bg = plain.color(at: NSPoint(x: belowRect.minX + 4, y: belowRect.maxY - 2))
                let aboveInk = try XCTUnwrap(plain.inkBox(in: aboveRect, against: bg), "\(text): the row above draws something")
                let belowInk = try XCTUnwrap(plain.inkBox(in: belowRect, against: bg), "\(text): the row below draws something")
                let seam = belowRect.minY
                // Only the band around the two rows is compared: enough to see the line and any row it would push.
                let band = NSRect(x: 0, y: aboveRect.minY - 30, width: h.pane.bounds.width, height: belowRect.maxY - aboveRect.minY + 60)

                h.pane.dragBegan()
                XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"),
                                                at: NSPoint(x: below.frame.midX, y: below.frame.minY + 3)), .move, "\(text): setup")
                XCTAssertFalse(h.pane.dropIndicator.isHidden, "\(text): setup: the line is showing")
                let lined = try shot(h)

                let changed = try XCTUnwrap(lined.changedBox(from: plain, in: band), "\(text): the line left ink on the pane")
                XCTAssertGreaterThanOrEqual(changed.minY, aboveInk.maxY, "\(text): the line's ink starts below the row above's ink")
                XCTAssertLessThanOrEqual(changed.maxY, belowInk.minY, "\(text): and ends above the row below's ink")
                XCTAssertGreaterThan(changed.minY, aboveRect.minY, "\(text): it is not inside the row above's own area")
                XCTAssertEqual((changed.minY + changed.maxY) / 2, seam, accuracy: 0.75, "\(text): it is centred on the seam")
                XCTAssertLessThanOrEqual(changed.height, TrackerDropIndicatorView.thickness + 1,
                                         "\(text): it is a thin line: nothing else on the pane moved or changed (\(changed))")
                XCTAssertGreaterThanOrEqual(changed.width, h.pane.documentView.bounds.width - 2, "\(text): it runs the width of the rows")
                XCTAssertEqual(h.rig.rowFrames, frames, "\(text): no row moved to make room")

                let seamPoint = NSPoint(x: belowRect.midX, y: seam)
                XCTAssertGreaterThanOrEqual(ratio(lined.color(at: seamPoint), plain.color(at: seamPoint)), 3.0,
                                            "\(text): the line's drawn colour against what it is drawn on")

                h.pane.dragExited()
                let hidden = try shot(h)
                XCTAssertNil(hidden.changedBox(from: plain, in: band), "\(text): hiding the line takes all its ink away")

                // Over a place that refuses the drop, and at the end of the drag, the line is gone too.
                XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"),
                                                at: NSPoint(x: below.frame.midX, y: below.frame.minY + 3)), .move)
                XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"),
                                                at: NSPoint(x: below.frame.midX, y: -50)), [])
                XCTAssertNil(try shot(h).changedBox(from: plain, in: band), "\(text): a refusing place has no line")
                XCTAssertEqual(h.pane.dragMoved(payload: payload(h, "verif-1037"),
                                                at: NSPoint(x: below.frame.midX, y: below.frame.minY + 3)), .move)
                h.pane.dragEnded()
                XCTAssertNil(try shot(h).changedBox(from: plain, in: band), "\(text): the end of the drag takes it away")
            }
        }
    }

    // MARK: The remove banner

    private let longTitle = String(repeating: "W", count: 60)

    func testTheRemoveBannersLongTitleIsCutWithAnEllipsisEndsClearOfUndoAndUndoIsInsideItsButton() throws {
        for width in Self.widths {
            for keyWindow in [true, false] {
                let h = try harness(width: width, keyWindow: keyWindow) { script in
                    try script.updateItem("verif-1037") {
                        $0["text"] = String(repeating: "W", count: 60)
                        $0["text_spans"] = [["kind": "text", "text": String(repeating: "W", count: 60)]]
                    }
                }
                let text = label(width, keyWindow)
                h.pane.removeItem("verif-1037")
                h.rig.settle()
                let notice = h.pane.notice
                XCTAssertEqual(notice.text, "Removed “\(longTitle)”.", "\(text): setup: the banner names the whole 60-character title")
                let button = try XCTUnwrap(notice.actionButton, "\(text): setup: Undo is offered")
                XCTAssertFalse(notice.isHidden)
                let noticeRect = paneRect(notice, h)
                let buttonRect = paneRect(button, h)
                let labelRect = paneRect(notice.label, h)

                // The title's ink on its own: the button hidden, so nothing it draws is taken for the title.
                button.isHidden = true
                let withoutButton = try shot(h)
                button.isHidden = false
                let withButton = try shot(h)

                let noticeBg = withoutButton.color(at: NSPoint(x: noticeRect.minX + 2, y: noticeRect.midY))
                let titleInk = try XCTUnwrap(withoutButton.inkBox(in: labelRect, against: noticeBg), "\(text): the title is drawn")
                let buttonFill = withButton.color(at: NSPoint(x: buttonRect.minX + 2, y: buttonRect.midY))
                let undoInk = try XCTUnwrap(withButton.inkBox(in: buttonRect, against: buttonFill), "\(text): Undo is drawn")

                XCTAssertEqual(withoutButton.inkRuns(in: labelRect, against: noticeBg).count, 1, "\(text): the title is one line")
                XCTAssertLessThanOrEqual(titleInk.maxX, undoInk.minX - 4, "\(text): the title's ink ends at least 4 pt left of Undo's")
                assertInside(undoInk, buttonRect, scale: withButton.scale, "\(text): Undo's text is inside its button")
                assertInside(titleInk, noticeRect, scale: withoutButton.scale, "\(text): the title is inside the banner")

                // Cut with an ellipsis: the title runs right up to the room it has, and what ends it is a row of
                // dots on the baseline, not a letter cut in half.
                XCTAssertGreaterThanOrEqual(titleInk.maxX, labelRect.maxX - 14, "\(text): the title uses the room it has")
                let tail = try XCTUnwrap(withoutButton.inkBox(in: NSRect(x: titleInk.maxX - 3, y: labelRect.minY, width: 4, height: labelRect.height),
                                                              against: noticeBg), "\(text): the end of the title is drawn")
                XCTAssertLessThan(tail.height, titleInk.height * 0.5, "\(text): the title ends in an ellipsis (dots), not a cut letter")
                XCTAssertEqual(tail.maxY, titleInk.maxY, accuracy: 1.0, "\(text): the dots sit on the baseline")
            }
        }
    }

    // MARK: Contrast of the colours themselves

    func testTheStructureColoursMeetTheContrastTheContractAsksFor() {
        let bg = TrackerTheme.background
        XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.mutedOnFill, bg), 4.5, "the add row's label")
        XCTAssertGreaterThanOrEqual(ratio(Theme.cornflower, bg), 3.0, "the drop indicator against the pane")
        XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.text, over(TrackerTheme.bannerFill, bg)), 4.5, "the banner's text on its fill")
    }
}
