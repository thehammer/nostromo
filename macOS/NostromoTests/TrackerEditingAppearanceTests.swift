import XCTest
import AppKit
import NostromoKit

// T3b: the editing affordances as RENDERED pixels (frame-only tests missed a clipped digit in #456/#457).
// Each case draws the pane with `cacheDisplay` at 260 pt and 600 pt, in a key and a non-key window, and
// reads ink: the title is one line that ends clear of the first chip, every chip's text ink is inside its
// fill on all sides, the tick glyph is inside its row and clear of the chevron, the title editor sits in
// the title's place without changing the row, the details editor's last line is inside the row, the
// header chip's last digit is inside the chip. The contrast cases compute WCAG ratios from the colours
// the pane draws with (contract §10).
//
// What the tests are meant to catch, for whoever mutates the implementation to check them:
//  - Shrink the title editor's frame by 2 pt: the descender ink leaves the row, so
//    `testTheTitleEditorSitsInTheTitlesPlaceAndItsInkIsInsideTheRow` fails.
//  - Remove a chip's horizontal padding (`TrackerChipButton.padding`): the inside-the-fill cases fail.
//  - Let the tick and disclosure hit areas overlap (`TrackerRowView.tickRect` / `disclosureRect`): the
//    tick-clear-of-chevron case and `TrackerEditingTests` hit-test case fail.
//  - Lay the details editor out in a frame shorter than its text: the last-line-inside-the-row case fails.

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

// MARK: - Tests

final class TrackerEditingAppearanceTests: XCTestCase {

    private static let widths: [CGFloat] = [260, 600]
    private static let paneHeight: CGFloat = 700
    private let id = "verif-1037"

    private func harness(width: CGFloat, configure: @escaping (inout TrackerBoardScript) throws -> Void = { _ in }) throws -> TrackerEditHarness {
        try TrackerEditHarness(self, size: NSSize(width: width, height: Self.paneHeight),
                               appearance: NSAppearance(named: .darkAqua), configure: configure)
    }

    private func conflictJSON() -> [[String: Any]] {
        [["conflict_id": "7.1", "field": "status", "losing": "todo", "losing_by": "agent claudia",
          "winning_by": "pane (you)", "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 4), "index": 0]]
    }

    private func shot(_ h: TrackerEditHarness, file: StaticString = #filePath, line: UInt = #line) throws -> Shot {
        h.rig.host.layoutSubtreeIfNeeded()
        h.rig.host.displayIfNeeded()
        return try XCTUnwrap(Shot(of: h.pane), "could not draw the pane", file: file, line: line)
    }

    private func reveal(_ h: TrackerEditHarness, _ id: String) throws -> (row: TrackerRowView, rect: NSRect) {
        let row = try h.row(id)
        h.rig.scroll(to: max(0, row.frame.minY - 8))
        h.rig.host.layoutSubtreeIfNeeded()
        h.rig.host.displayIfNeeded()
        return (row, h.pane.convert(row.bounds, from: row))
    }

    private func paneRect(_ view: NSView, _ h: TrackerEditHarness) -> NSRect { h.pane.convert(view.bounds, from: view) }

    private func fill(_ shot: Shot, _ rect: NSRect) -> RGB {
        shot.color(at: NSPoint(x: rect.minX + 2, y: rect.midY))
    }

    /// Every side of the text ink is at least one pixel inside `rect`.
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

    // MARK: A collapsed row with every affordance

    func testACollapsedRowWithTheMarkChipsAndATimeKeepsItsTitleOnOneLineAndEveryChipsInkInsideItsFill() throws {
        for width in Self.widths {
            for keyWindow in [true, false] {
                let h = try harness(width: width) { script in
                    try script.updateItem("verif-1037") {
                        $0["text"] = String(repeating: "W", count: 80)
                        $0["text_spans"] = [["kind": "text", "text": String(repeating: "W", count: 80)]]
                        $0["conflicts"] = self.conflictJSON()
                        $0["sensitive"] = ["classes": ["phone"]]
                    }
                }
                if !keyWindow { h.window.resignKey() }
                let (row, rowRect) = try reveal(h, id)
                let s = try shot(h)
                let label = "width \(width), \(keyWindow ? "key" : "non-key")"
                let bg = s.color(at: NSPoint(x: rowRect.minX + 4, y: rowRect.maxY - 2))

                let title = try XCTUnwrap(row.textViews.first)
                let titleRect = paneRect(title, h)
                XCTAssertEqual(s.inkRuns(in: titleRect, against: bg).count, 1, "\(label): the title is one line of ink")

                let conflict = try XCTUnwrap(row.conflictButton), sensitive = try XCTUnwrap(row.sensitiveButton)
                for chip in [conflict, sensitive] {
                    let chipRect = paneRect(chip, h)
                    let chipFill = fill(s, chipRect)
                    assertInside(s.inkBox(in: chipRect, against: chipFill), chipRect, scale: s.scale, "\(label): \(chip.title)")
                }
                let firstChip = [conflict, sensitive].map { paneRect($0, h) }.min { $0.minX < $1.minX }!
                if let titleInk = s.inkBox(in: titleRect, against: bg) {
                    if firstChip.minY < titleRect.maxY {
                        XCTAssertLessThanOrEqual(titleInk.maxX, firstChip.minX - 2, "\(label): the title ink ends clear of the first chip")
                    } else {
                        // The chips took their own line under the title (a narrow pane): clear of its ink vertically.
                        XCTAssertLessThanOrEqual(titleInk.maxY, firstChip.minY - 1, "\(label): the chips sit under the title's ink")
                    }
                }
                assertInside(s.inkBox(in: paneRect(row, h), against: bg), rowRect, scale: s.scale, "\(label): all the row's ink")
            }
        }
    }

    func testTheTickGlyphIsInsideItsRowAndClearOfTheChevron() throws {
        for width in Self.widths {
            let h = try harness(width: width) { try $0.setNote("check-1000", paragraphs: ["a note"]) }
            let (row, rowRect) = try reveal(h, "check-1000")
            let s = try shot(h)
            let bg = s.color(at: NSPoint(x: rowRect.minX + 4, y: rowRect.maxY - 2))
            let tick = try XCTUnwrap(row.tickButton), chevron = try XCTUnwrap(row.disclosureButton)
            let tickInk = try XCTUnwrap(s.inkBox(in: paneRect(tick, h), against: bg), "the tick glyph is drawn")
            let chevronInk = try XCTUnwrap(s.inkBox(in: paneRect(chevron, h), against: bg), "the chevron is drawn")
            assertInside(tickInk, rowRect, scale: s.scale, "width \(width): the tick glyph")
            XCTAssertLessThan(tickInk.maxX, chevronInk.minX, "width \(width): the tick does not touch the chevron")
        }
    }

    // MARK: The editors

    func testTheTitleEditorSitsInTheTitlesPlaceAndItsInkIsInsideTheRow() throws {
        for width in Self.widths {
            let h = try harness(width: width) { script in
                try script.updateItem("verif-1037") {
                    $0["text"] = "HHHH gypsy jug"
                    $0["text_spans"] = [["kind": "text", "text": "HHHH gypsy jug"]]
                }
            }
            let (row, rowRect) = try reveal(h, id)
            let before = row.frame.height
            let beforeShot = try shot(h)
            let bg = beforeShot.color(at: NSPoint(x: rowRect.minX + 4, y: rowRect.maxY - 2))
            let titleRect = paneRect(try XCTUnwrap(row.textViews.first), h)
            let titleInk = try XCTUnwrap(beforeShot.inkBox(in: titleRect, against: bg))

            h.pane.beginEdit(item: id, kind: .title)
            h.rig.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(row.frame.height, before, accuracy: 0.01, "width \(width): the row's height does not change")
            let editor = try XCTUnwrap(row.titleEditor)
            let editorRect = paneRect(editor, h)
            let afterShot = try shot(h)
            let editorBg = afterShot.color(at: NSPoint(x: editorRect.maxX - 2, y: editorRect.midY))
            let editorInk = try XCTUnwrap(afterShot.inkBox(in: editorRect, against: editorBg), "the editor shows its text")
            assertInside(editorInk, rowRect, scale: afterShot.scale, "width \(width): the editor's ink is inside the row")
            XCTAssertEqual(editorInk.minY, titleInk.minY, accuracy: 1.0, "width \(width): the cap line is where the title's was")
        }
    }

    func testTheDetailsEditorWithSixLinesHasItsLastLineInsideTheRowAndTheActionsAreNotClipped() throws {
        for width in Self.widths {
            let h = try harness(width: width) { try $0.setNote("check-1000", paragraphs: ["a note"]) }
            h.pane.beginEdit(item: "check-1000", kind: .details)
            let editor = try XCTUnwrap(try h.row("check-1000").detailsEditor)
            editor.string = (1...6).map { "line \($0) of the details" }.joined(separator: "\n")
            editor.didChangeText()
            let (row, rowRect) = try reveal(h, "check-1000")
            let s = try shot(h)
            let bg = s.color(at: NSPoint(x: rowRect.minX + 4, y: rowRect.maxY - 2))
            let editorRect = paneRect(editor, h)
            let editorBg = s.color(at: NSPoint(x: editorRect.maxX - 2, y: editorRect.midY))
            XCTAssertEqual(s.inkRuns(in: editorRect, against: editorBg).count, 6, "width \(width): six lines of ink")
            assertInside(s.inkBox(in: editorRect, against: editorBg), rowRect, scale: s.scale, "width \(width): the editor's ink")
            XCTAssertLessThanOrEqual(editorRect.maxY, rowRect.maxY, "width \(width): the editor is inside the row")
            for button in [row.editTitleButton, row.editDetailsButton].compactMap({ $0 }) {
                let r = paneRect(button, h)
                assertInside(s.inkBox(in: r, against: bg), r.insetBy(dx: -0.5, dy: 0), scale: s.scale,
                             "width \(width): \(button.title)")
            }
        }
    }

    // MARK: The header chip

    func testTheHeaderChipsLastDigitIsInsideTheChip() throws {
        for count in [1, 12] {
            for width in Self.widths {
                let h = try harness(width: width) { script in
                    script.setRemovedConflicts((0..<count).map { n in
                        ["conflict_id": "9.\(n)", "item_id": "gone-\(n)", "title": "Removed \(n)", "losing_by": "pane (you)",
                         "winning_by": "agent cody", "at": TrackerPaneFx.iso(TrackerPaneFx.now.timeIntervalSince1970 - 3),
                         "source": "- [ ] Removed \(n)\n"]
                    })
                }
                let chip = try XCTUnwrap(h.pane.header.conflictChip)
                XCTAssertEqual(chip.title, count == 1 ? "1 conflict" : "12 conflicts")
                let s = try shot(h)
                let rect = paneRect(chip, h)
                assertInside(s.inkBox(in: rect, against: fill(s, rect)), rect, scale: s.scale, "\(chip.title) at \(width)")
                XCTAssertLessThanOrEqual(rect.maxX, paneRect(h.pane.header, h).maxX - TrackerRowView.hPad + 0.5)
            }
        }
    }

    // MARK: Dropped-conflict marker and the dimmed pending editor (ink)

    func testTheOlderConflictsWereDroppedMarkersInkIsInsideItsFillAndItsLabelIsNotClipped() throws {
        for width in Self.widths {
            let h = try harness(width: width) { script in
                try script.updateItem("verif-1037") { $0["dropped_conflicts"] = 3 }
            }
            let (row, rowRect) = try reveal(h, id)
            let s = try shot(h)
            let mark = try XCTUnwrap(row.badges.first { $0.accessibilityLabel() == "Older conflicts were dropped" },
                                     "width \(width): the marker is drawn")
            let rect = paneRect(mark, h)
            XCTAssertGreaterThan(rect.width, 20, "width \(width): the marker has room for its words")
            assertInside(s.inkBox(in: rect, against: fill(s, rect)), rect, scale: s.scale, "width \(width): the marker's words")
            assertInside(s.inkBox(in: rect, against: fill(s, rect)), rowRect, scale: s.scale, "width \(width): the marker is inside the row")
        }
    }

    func testAPendingEditorIsDimmedButItsTextStaysReadable() throws {
        for width in Self.widths {
            let h = try harness(width: width) { script in
                try script.updateItem("verif-1037") {
                    $0["text"] = "HHHH gypsy jug"
                    $0["text_spans"] = [["kind": "text", "text": "HHHH gypsy jug"]]
                }
            }
            let (row, _) = try reveal(h, id)
            h.pane.beginEdit(item: id, kind: .title)
            h.rig.host.layoutSubtreeIfNeeded()
            let editor = try XCTUnwrap(row.titleEditor)
            // Change the text: an unchanged title closes without a save, and only a save dims the editor.
            h.type("HHHH gypsy jug, renamed", into: editor)
            let editorRect = paneRect(editor, h)
            let live = try shot(h)
            let bg = live.color(at: NSPoint(x: editorRect.maxX - 2, y: editorRect.midY))
            XCTAssertNotNil(live.inkBox(in: editorRect, against: bg), "width \(width): the live editor shows its text")
            h.pressReturn(in: editor)          // the save is now pending: the editor is dimmed
            XCTAssertEqual(editor.alphaValue, 0.5, accuracy: 0.01)
            let dimmed = try shot(h)
            XCTAssertNotNil(dimmed.changedBox(from: live, in: editorRect), "width \(width): the pending editor looks different")
            XCTAssertNotNil(dimmed.inkBox(in: editorRect, against: bg, threshold: 30),
                            "width \(width): the dimmed text is still there to read")
        }
    }

    // MARK: Contrast (contract §10)

    func testTheEditingColoursMeetTheContrastTheContractAsksFor() {
        let bg = TrackerTheme.background
        let chipFill = over(TrackerTheme.badgeFill, bg)
        let needsFill = over(TrackerTheme.needsYouFill, bg)
        let statuses: [TrackerStatusWire] = [.todo, .inProgress, .blocked, .needsYou, .done]
        for status in statuses {
            XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.markColor(status), bg), 3.0, "tick glyph \(status.wireName) on the pane")
            XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.markColor(status), needsFill), 3.0, "tick glyph \(status.wireName) on a needs-you row")
        }
        XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.mutedOnFill, bg), 4.5, "actions-line text")
        XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.mutedOnFill, needsFill), 4.5, "actions-line text on a needs-you row")
        XCTAssertGreaterThanOrEqual(ratio(Theme.amber, chipFill), 4.5, "conflict mark and sensitive chip text on their fill")
        XCTAssertGreaterThanOrEqual(ratio(Theme.amber, over(TrackerTheme.badgeFill, needsFill)), 4.5, "chips on a needs-you row")
        XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.text, over(TrackerTheme.bannerFill, bg)), 4.5, "notice text")
        XCTAssertGreaterThanOrEqual(ratio(TrackerTheme.text, over(TrackerTheme.badgeFill, bg)), 4.5, "editor text on its fill")
    }
}
