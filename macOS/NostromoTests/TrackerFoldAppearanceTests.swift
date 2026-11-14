import XCTest
import AppKit
import NostromoKit

// What the tracker's title line and fold look like once drawn. The pane is rendered to a bitmap under
// Dark Aqua (`cacheDisplay`, at 4x so thin strokes reach full colour) at 260 pt and 600 pt wide, and
// every assertion is about where ink actually came out, not about frames:
//
//  - a 80-character title ("W" x 80, wider than either pane) is one line of ink, as tall as a short
//    item's title, and the row is as tall as a row with a short text;
//  - the title's rightmost ink stays at least 2 px left of the owner chip (when the chip is on the
//    title's line, as at 600 pt) and of the time; where the chip stacks below the title (260 pt) the
//    title's ink ends above the chip's top instead;
//  - the chevron is drawn fully inside its row, clear of the status mark's ink and of the title's;
//  - a collapsed row is exactly as tall as a one-line row even with a 2,000-character note, and
//    opening it makes the row taller;
//  - an open row's rest-of-the-text spans several lines of ink and its last line is inside the row.
//
// The chevron's ink is found by drawing the pane twice, with the row's disclosure button hidden and
// shown, and taking the pixels that differ: the status mark's and title's ink are measured on the
// hidden-button picture, so the three never share a pixel in the measurement.
//
// The boards are the golden frame with in-memory edits; no UserDefaults, no wall clock, no daemon.
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Build the title with `TrackerTextView.make()` instead of `make(singleLine: true)`: the 80-"W"
//    title wraps to several lines, so the one-line-of-ink test, the row-height tests and the
//    title-above-the-chip test fail.
//  - Drop `foldColumnWidth` (the 16 pt column between the mark and the title): the title moves under
//    the chevron, so the chevron-clear-of-title (and, with it, clear-of-mark) assertions fail.
//  - Let the collapsed row lay out its note (or the body): the 2,000-character-note height test fails.
//  - Lay the rest of the text out in a frame too short for it (or past the row's bottom edge): the
//    last-line-inside-the-row assertions fail.

// MARK: - Pixels

private struct RGB {
    let r: Int, g: Int, b: Int
    func distance(to other: RGB) -> Int { abs(r - other.r) + abs(g - other.g) + abs(b - other.b) }
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

// MARK: - Tests

final class TrackerFoldAppearanceTests: XCTestCase {

    private typealias Fx = TrackerPaneFx

    private static let widths: [CGFloat] = [260, 600]
    private static let paneHeight: CGFloat = 700

    /// Todo items of the golden board's last section with owner "redd", short text, no note, no links.
    private let target = "audit-3183"
    private let reference = "close-2961"
    private let owner = "redd"

    /// Wider than either pane at 13 pt, and no longer than the 80 characters a title may be, so the
    /// whole of it is the title.
    private let longTitle = String(repeating: "W", count: 80)

    private struct Scene {
        let rig: TrackerPaneRig
        let script: TrackerBoardScript
        var pane: TrackerPaneView { rig.pane }
    }

    private func scene(width: CGFloat, edit: (inout TrackerBoardScript) throws -> Void = { _ in }) throws -> Scene {
        let size = NSSize(width: width, height: Self.paneHeight)
        let window = makeRigWindow(self, size: NSSize(width: size.width, height: size.height + Fx.hostPadding),
                                   appearance: NSAppearance(named: .darkAqua))
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag, window: window, size: size)
        var script = try TrackerBoardScript(tag: tag)
        try edit(&script)
        rig.push(script)
        return Scene(rig: rig, script: script)
    }

    /// The row scrolled to the top of the viewport (or as near as the board's end lets it), drawn, and
    /// its rectangle in the pane's coordinates.
    private func reveal(_ s: Scene, _ id: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> (row: TrackerRowView, rect: NSRect) {
        let row = try XCTUnwrap(s.pane.rowViews["item:\(id)"], "no row for \(id); rows: \(s.pane.displayedRows.map(\.key))",
                                file: file, line: line)
        s.rig.scroll(to: max(0, row.frame.minY - 8))
        s.rig.host.layoutSubtreeIfNeeded()
        s.rig.host.displayIfNeeded()
        let rect = s.pane.convert(row.bounds, from: row)
        let clip = s.pane.convert(s.pane.clipView.bounds, from: s.pane.clipView)
        XCTAssertTrue(clip.insetBy(dx: -0.5, dy: -0.5).contains(rect), "setup: row \(id) is fully on screen: \(rect) in \(clip)",
                      file: file, line: line)
        return (row, rect)
    }

    private func rect(of view: NSView, in s: Scene) -> NSRect {
        s.pane.convert(view.bounds, from: view)
    }

    private func label(_ text: String, in row: TrackerRowView) -> NSTextField? {
        rigAllSubviews(of: row).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    private func shot(_ s: Scene, file: StaticString = #filePath, line: UInt = #line) throws -> Shot {
        s.rig.host.layoutSubtreeIfNeeded()
        s.rig.host.displayIfNeeded()
        return try XCTUnwrap(Shot(of: s.pane), "could not draw the pane", file: file, line: line)
    }

    /// The row's own background: the margin at its right edge, where nothing is drawn.
    private func background(_ shot: Shot, row rect: NSRect) -> RGB {
        shot.color(at: NSPoint(x: rect.maxX - 3, y: rect.midY))
    }

    private func titleView(_ row: TrackerRowView, file: StaticString = #filePath, line: UInt = #line) throws -> TrackerTextView {
        try XCTUnwrap(row.textViews.first, "the row has no title view", file: file, line: line)
    }

    // MARK: - The title is one line

    func testALongTitleIsOneLineOfInkAndTheRowIsAsTallAsAShortOne() throws {
        for width in Self.widths {
            let at = "at \(Int(width)) pt"
            let s = try scene(width: width) { try $0.setText(target, longTitle) }
            let (row, rowRect) = try reveal(s, target)
            let refRow = try XCTUnwrap(s.pane.rowViews["item:\(reference)"])
            XCTAssertEqual(row.textViews.first?.string, longTitle, "\(at): the 80 characters are the title, whole")
            XCTAssertEqual(row.row.item?.isFoldable, false, "\(at): setup: nothing under a fold")

            let title = try titleView(row)
            let shortTitle = try titleView(refRow)
            XCTAssertEqual(title.frame.height, shortTitle.frame.height, accuracy: 0.5, "\(at): the title's view is one line tall")
            XCTAssertEqual(row.frame.height, refRow.frame.height, accuracy: 0.5, "\(at): the row is as tall as a row with a short text")

            let picture = try shot(s)
            let bg = background(picture, row: rowRect)
            let titleRect = rect(of: title, in: s)
            let runs = picture.inkRuns(in: titleRect, against: bg)
            XCTAssertEqual(runs.count, 1, "\(at): the title is one line of ink, not \(runs.count)")
            let ink = try XCTUnwrap(picture.inkBox(in: titleRect, against: bg), "\(at): the title drew nothing")
            XCTAssertGreaterThan(ink.width, titleRect.width * 0.5, "\(at): the title fills its line (cut with an ellipsis, not wrapped)")
            XCTAssertLessThanOrEqual(ink.height, titleRect.height + 1, "\(at): its ink is one line high")
        }
    }

    func testTheTitlesInkStopsShortOfTheOwnerChipAndTheTimeWhereverTheChipSits() throws {
        var chipWasBesideTheTitle = false
        for width in Self.widths {
            let at = "at \(Int(width)) pt"
            let s = try scene(width: width) { try $0.setText(target, longTitle) }
            let (row, rowRect) = try reveal(s, target)
            let picture = try shot(s)
            let bg = background(picture, row: rowRect)

            let titleRect = rect(of: try titleView(row), in: s)
            let titleInk = try XCTUnwrap(picture.inkBox(in: titleRect, against: bg), "\(at): the title drew nothing")
            let chip = try XCTUnwrap(label(owner, in: row), "\(at): the owner chip \(owner) is in the row")
            let chipRect = rect(of: chip, in: s)
            XCTAssertNotNil(picture.inkBox(in: chipRect, against: bg), "\(at): the owner chip drew its text")
            let time = try XCTUnwrap(row.timeLabel, "\(at): the row has its time")
            let timeRect = rect(of: time, in: s)
            XCTAssertNotNil(picture.inkBox(in: timeRect, against: bg), "\(at): the time drew its text")

            XCTAssertLessThanOrEqual(titleInk.maxX + 2, timeRect.minX,
                                     "\(at): the title's ink (to \(titleInk.maxX)) is at least 2 px left of the time (from \(timeRect.minX))")
            if chipRect.minY < titleRect.maxY {
                chipWasBesideTheTitle = true
                XCTAssertLessThanOrEqual(titleInk.maxX + 2, chipRect.minX,
                                         "\(at): the title's ink (to \(titleInk.maxX)) is at least 2 px left of the owner chip (from \(chipRect.minX))")
            } else {
                XCTAssertLessThanOrEqual(titleInk.maxY, chipRect.minY,
                                         "\(at): the chip is on a line below, and the title's ink (to \(titleInk.maxY)) ends above it (\(chipRect.minY))")
            }
        }
        XCTAssertTrue(chipWasBesideTheTitle, "the wide pane keeps the owner chip on the title's line (else the side-by-side check never ran)")
    }

    // MARK: - The chevron

    func testTheChevronIsDrawnInsideItsRowClearOfTheStatusMarkAndTheTitle() throws {
        for width in Self.widths {
            let at = "at \(Int(width)) pt"
            let s = try scene(width: width) {
                try $0.setText(target, longTitle)
                try $0.setNote(target, paragraphs: ["A note, so the item folds"])
            }
            let (row, rowRect) = try reveal(s, target)
            let button = try XCTUnwrap(row.disclosureButton, "\(at): the item has something under its fold")

            button.isHidden = true
            let without = try shot(s)
            button.isHidden = false
            let with = try shot(s)

            let bg = background(without, row: rowRect)
            let chevron = try XCTUnwrap(with.changedBox(from: without, in: rowRect.insetBy(dx: -6, dy: -6)),
                                        "\(at): the disclosure drew no chevron")
            XCTAssertGreaterThanOrEqual(chevron.width, 3, "\(at): a chevron, not a speck: \(chevron)")
            XCTAssertGreaterThanOrEqual(chevron.minX, rowRect.minX + 1, "\(at): the chevron is not clipped at the row's left edge: \(chevron) in \(rowRect)")
            XCTAssertLessThanOrEqual(chevron.maxX, rowRect.maxX - 1, "\(at): nor at its right edge: \(chevron) in \(rowRect)")
            XCTAssertGreaterThanOrEqual(chevron.minY, rowRect.minY, "\(at): nor at its top: \(chevron) in \(rowRect)")
            XCTAssertLessThanOrEqual(chevron.maxY, rowRect.maxY, "\(at): nor at its bottom: \(chevron) in \(rowRect)")

            let mark = try XCTUnwrap(label("○", in: row), "\(at): a todo item shows ○")
            let markInk = try XCTUnwrap(without.inkBox(in: rect(of: mark, in: s), against: bg), "\(at): the status mark drew nothing")
            XCTAssertFalse(chevron.intersects(markInk), "\(at): the chevron \(chevron) overlaps the status mark's ink \(markInk)")
            XCTAssertLessThanOrEqual(markInk.maxX, chevron.minX, "\(at): the mark ends (\(markInk.maxX)) before the chevron starts (\(chevron.minX))")

            let titleInk = try XCTUnwrap(without.inkBox(in: rect(of: try titleView(row), in: s), against: bg),
                                         "\(at): the title drew nothing")
            XCTAssertLessThanOrEqual(chevron.maxX, titleInk.minX,
                                     "\(at): the chevron ends (\(chevron.maxX)) before the title's ink starts (\(titleInk.minX))")
        }
    }

    // MARK: - A collapsed row stays one line tall

    func testACollapsedRowIsAsTallAsAOneLineRowWithA2000CharacterNoteAndGrowsWhenOpened() throws {
        let note = String(String(repeating: "A long note sentence that goes on and on. ", count: 48).prefix(2000))
        XCTAssertEqual(note.count, 2000, "setup")
        for width in Self.widths {
            let at = "at \(Int(width)) pt"
            let s = try scene(width: width)
            let oneLine = try XCTUnwrap(s.pane.rowViews["item:\(target)"]).frame.height
            let refHeight = try XCTUnwrap(s.pane.rowViews["item:\(reference)"]).frame.height
            XCTAssertEqual(oneLine, refHeight, accuracy: 0.5, "\(at): setup: the two rows with short text are alike")

            var noted = s.script
            try noted.setNote(target, paragraphs: [note])
            s.rig.push(noted)
            let (row, _) = try reveal(s, target)
            XCTAssertEqual(row.row.item?.isFoldable, true, "\(at): setup: the note makes it foldable")
            XCTAssertEqual(row.frame.height, oneLine, accuracy: 0.5, "\(at): collapsed with a 2,000-character note, the row is still one line tall")
            XCTAssertFalse(row.visibleText.contains("A long note sentence"), "\(at): none of the note shows while collapsed")

            try XCTUnwrap(row.disclosureButton).performClick(nil)
            s.rig.settle()
            let opened = try XCTUnwrap(s.pane.rowViews["item:\(target)"])
            XCTAssertGreaterThan(opened.frame.height, oneLine + 100, "\(at): opening it makes room for the note")

            try XCTUnwrap(opened.disclosureButton).performClick(nil)
            s.rig.settle()
            XCTAssertEqual(try XCTUnwrap(s.pane.rowViews["item:\(target)"]).frame.height, oneLine, accuracy: 0.5,
                           "\(at): folded again, it is one line tall again")
        }
    }

    // MARK: - An open row

    func testAnOpenRowShowsTheRestOfTheTextOnSeveralLinesAndItsLastLineIsInsideTheRow() throws {
        let title = "Audit pdf renderer"
        let sentence = "The renderer drops the final page when the footer overflows, so every export loses its last page "
            + "and the customer sees a short document without any warning at all. "
        let body = String(String(repeating: sentence, count: 4).dropLast())
        for width in Self.widths {
            let at = "at \(Int(width)) pt"
            let s = try scene(width: width) { try $0.setText(target, "\(title): \(body)") }
            let (closed, _) = try reveal(s, target)
            XCTAssertEqual(closed.textViews.first?.string, title, "\(at): setup: the title is the text before the separator")
            try XCTUnwrap(closed.disclosureButton, "\(at): setup: the rest of the text makes it foldable").performClick(nil)
            s.rig.settle()

            let (row, rowRect) = try reveal(s, target)
            XCTAssertEqual(row.textViews.count, 2, "\(at): the title and the rest of the text")
            let titleRect = rect(of: try titleView(row), in: s)
            let leadView = row.textViews[1]
            XCTAssertEqual(leadView.string, body, "\(at): the rest of the text is the lead, whole")
            let leadRect = rect(of: leadView, in: s)

            let picture = try shot(s)
            let bg = background(picture, row: rowRect)
            XCTAssertEqual(picture.inkRuns(in: titleRect, against: bg).count, 1, "\(at): the title is still one line")

            let runs = picture.inkRuns(in: leadRect, against: bg)
            let lines = Int((leadRect.height / titleRect.height).rounded())
            XCTAssertGreaterThanOrEqual(runs.count, 3, "\(at): the rest of the text spans several lines of ink, not \(runs.count)")
            XCTAssertGreaterThanOrEqual(runs.count, lines - 1,
                                        "\(at): the text view is \(lines) lines tall and paints \(runs.count): ink is missing")
            let leadInk = try XCTUnwrap(picture.inkBox(in: leadRect, against: bg), "\(at): the rest of the text drew nothing")
            XCTAssertGreaterThanOrEqual(leadInk.minY, leadRect.minY, "\(at): the text starts inside its view")
            XCTAssertLessThanOrEqual(leadInk.maxX, rowRect.maxX - 1, "\(at): no line is cut at the row's right edge")

            // The last line is inside the row, with its bottom padding below it.
            let allInk = try XCTUnwrap(picture.inkBox(in: rowRect, against: bg), "\(at): the row drew nothing")
            XCTAssertLessThanOrEqual(leadRect.maxY, rowRect.maxY, "\(at): the text view ends inside the row")
            XCTAssertLessThanOrEqual(allInk.maxY, rowRect.maxY - 1, "\(at): the lowest ink (\(allInk.maxY)) is not cut by the row's bottom (\(rowRect.maxY))")
            XCTAssertLessThanOrEqual(rowRect.maxY - leadInk.maxY, 12, "\(at): the row ends just under the last line, not far below it")
            XCTAssertGreaterThanOrEqual(rowRect.maxY - leadInk.maxY, 2, "\(at): the last line does not touch the row's bottom edge")
        }
    }
}
