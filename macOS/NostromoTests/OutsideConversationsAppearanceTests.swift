import XCTest
import AppKit

/// What a "Terminal" row draws, measured in a bitmap (the #457 technique): the label and title are inked
/// whole, inside the row, at the sheet's width.
final class OutsideConversationsAppearanceTests: XCTestCase {
    private typealias F = HistoryFixtures

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.layout()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func inkColumns(_ rep: NSBitmapImageRep, region: NSRect, bounds: NSRect) -> ClosedRange<CGFloat>? {
        let scale = CGFloat(rep.pixelsWide) / bounds.width
        let x0 = max(0, Int(region.minX * scale)), x1 = min(rep.pixelsWide - 1, Int(region.maxX * scale))
        let fromTop = bounds.height - region.maxY
        let y0 = max(0, Int(fromTop * scale)), y1 = min(rep.pixelsHigh - 1, Int((fromTop + region.height) * scale))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var first: Int?, last: Int?
        for x in x0...x1 {
            for y in y0...y1 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                first = first ?? x; last = x; break
            }
        }
        guard let f = first, let l = last else { return nil }
        return (CGFloat(f) / scale)...(CGFloat(l + 1) / scale)
    }

    private func wholeInkWidth(_ text: String, font: NSFont) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let s: CGFloat = 2
        let w = Int(ceil(size.width) + 8), h = Int(ceil(size.height) + 4)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * 2, pixelsHigh: h * 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (text as NSString).draw(at: NSPoint(x: 2, y: 2), withAttributes: [.font: font, .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        var first = rep.pixelsWide, last = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
            first = min(first, x); last = max(last, x); break } }
        return CGFloat(last - first + 1) / s
    }

    private func row(_ e: ConversationEntryWire) -> ResumeRowView {
        var m = ConversationHistoryModel()
        m.now = { F.now }; m.calendar = F.utcCalendar()
        // The Resume tab's row width: the sheet is 600 wide with 8pt scroll insets.
        let v = ResumeRowView(frame: NSRect(x: 0, y: 0, width: CreateFocusSheet.resumeSize.width - 16, height: ResumeRowView.height))
        v.appearance = NSAppearance(named: .darkAqua)
        v.configure(m.text(for: e))
        return v
    }

    func testATerminalRowDrawsItsLabelAndTitleInsideTheRowAtTheSheetsWidth() throws {
        let v = row(F.entry("t", title: "claude", agent: "cody", origin: "terminal"))
        XCTAssertTrue(v.titleField.stringValue.hasPrefix("Terminal \u{00B7} claude"), v.titleField.stringValue)
        XCTAssertTrue(v.bounds.contains(v.titleField.frame), "title frame inside the row: \(v.titleField.frame)")
        let rep = try render(v)
        let ink = try XCTUnwrap(inkColumns(rep, region: v.titleField.frame, bounds: v.bounds), "the title line drew nothing")
        let whole = wholeInkWidth(v.titleField.stringValue, font: v.titleField.font!)
        XCTAssertGreaterThanOrEqual(ink.upperBound - ink.lowerBound, whole - 0.5, "the label or title is cut")
        XCTAssertLessThanOrEqual(ink.upperBound, v.titleField.frame.maxX + 0.5)
        XCTAssertLessThanOrEqual(v.titleField.frame.maxX, v.menuButton.frame.minX, "the title stops before the ⋯ button")
    }

    func testALongTerminalTitleKeepsTheLabelWholeAndTruncatesAfterIt() throws {
        let v = row(F.entry("t", title: String(repeating: "A very long terminal conversation ", count: 8), agent: "cody", origin: "terminal"))
        let rep = try render(v)
        let ink = try XCTUnwrap(inkColumns(rep, region: v.titleField.frame, bounds: v.bounds))
        XCTAssertLessThanOrEqual(ink.upperBound, v.titleField.frame.maxX + 0.5, "ink stays inside the title field")
        // "Terminal" alone is drawn whole at the left edge.
        let label = wholeInkWidth("Terminal", font: v.titleField.font!)
        let labelRegion = NSRect(x: v.titleField.frame.minX, y: v.titleField.frame.minY, width: label, height: v.titleField.frame.height)
        let labelInk = try XCTUnwrap(inkColumns(rep, region: labelRegion, bounds: v.bounds))
        XCTAssertGreaterThanOrEqual(labelInk.upperBound - labelInk.lowerBound, label - 1.5)
    }
}
