import XCTest
import AppKit

/// What the Resume row and the sidebar's "resumed" line actually draw, measured in a bitmap (the #457
/// technique): every line has ink, the ink stays inside the row, and short texts are not cut.
final class ResumeTabAppearanceTests: XCTestCase {
    private typealias F = HistoryFixtures
    private let scale: CGFloat = 2

    private func model() -> ConversationHistoryModel {
        var m = ConversationHistoryModel()
        m.now = { F.now }; m.calendar = F.utcCalendar()
        return m
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.layout()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Ink columns (in points, left to right inclusive) with alpha, within `region` (view coordinates).
    private func inkColumns(_ rep: NSBitmapImageRep, region: NSRect, bounds: NSRect, flipped: Bool = false) -> ClosedRange<CGFloat>? {
        var first: Int?, last: Int?
        let scale = CGFloat(rep.pixelsWide) / bounds.width   // 1x or 2x, whatever the machine gave
        let x0 = max(0, Int(region.minX * scale)), x1 = min(rep.pixelsWide - 1, Int(region.maxX * scale))
        let fromTop = flipped ? region.minY : bounds.height - region.maxY
        let y0 = max(0, Int(fromTop * scale)), y1 = min(rep.pixelsHigh - 1, Int((fromTop + region.height) * scale))
        guard x0 <= x1, y0 <= y1 else { return nil }
        for x in x0...x1 {
            for y in y0...y1 {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { first = first ?? x; last = x; break }
            }
        }
        guard let f = first, let l = last else { return nil }
        return (CGFloat(f) / scale)...(CGFloat(l + 1) / scale)
    }

    /// The ink width of `text` drawn alone and unclipped in `font`.
    private func wholeInkWidth(_ text: String, font: NSFont) -> CGFloat {
        let size = (text as NSString).size(withAttributes: [.font: font])
        let w = Int(ceil(size.width) + 8), h = Int(ceil(size.height) + 4)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * Int(scale), pixelsHigh: h * Int(scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (text as NSString).draw(at: NSPoint(x: 2, y: 2), withAttributes: [.font: font, .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        var first = w * Int(scale), last = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
            first = min(first, x); last = max(last, x); break } }
        return CGFloat(last - first + 1) / scale
    }

    private func row(_ e: ConversationEntryWire, width: CGFloat = 560) -> ResumeRowView {
        let v = ResumeRowView(frame: NSRect(x: 0, y: 0, width: width, height: ResumeRowView.height))
        v.appearance = NSAppearance(named: .darkAqua)
        v.configure(model().text(for: e))
        return v
    }

    func testALongRowDrawsEveryLineInsideTheRowAndNothingIsClippedAtTheRightEdge() throws {
        let e = F.entry("a", title: String(repeating: "A very long conversation title ", count: 6), agent: "cody",
                        project: "admin-portal", branch: "feature/a-very-long-branch-name-for-the-resume-tab-work",
                        prs: [456, 457], prompt: String(repeating: "x", count: 80),
                        status: .running(tag: "t", open: true))
        let v = row(e)
        let rep = try render(v)
        for (name, field) in [("title", v.titleField), ("detail", v.detailField), ("prompt", v.promptField), ("status", v.statusField)] {
            XCTAssertTrue(v.bounds.contains(field.frame), "\(name) frame is inside the row: \(field.frame)")
            let ink = try XCTUnwrap(inkColumns(rep, region: field.frame, bounds: v.bounds), "\(name) drew nothing")
            XCTAssertLessThanOrEqual(ink.upperBound, field.frame.maxX + 0.5, "\(name) ink runs past its field")
            XCTAssertLessThanOrEqual(ink.upperBound, v.bounds.width - ResumeRowView.margin + 0.5, "\(name) reaches the row's edge")
        }
        XCTAssertLessThanOrEqual(v.titleField.frame.maxX, v.menuButton.frame.minX, "the title stops before the ⋯ button")
    }

    func testShortStatusAndSensitiveLabelAreDrawnWhole() throws {
        let running = row(F.entry("a", status: .running(tag: "t", open: true)))
        var rep = try render(running)
        var ink = try XCTUnwrap(inkColumns(rep, region: running.statusField.frame, bounds: running.bounds))
        let font = running.statusField.font!
        XCTAssertGreaterThanOrEqual(ink.upperBound - ink.lowerBound, wholeInkWidth("running · switch to", font: font) - 0.5,
                                    "the status text is cut")
        let sensitive = row(F.entry("s", agent: "teri", sensitive: true))
        rep = try render(sensitive)
        ink = try XCTUnwrap(inkColumns(rep, region: sensitive.statusField.frame, bounds: sensitive.bounds), "Sensitive not drawn")
        XCTAssertGreaterThanOrEqual(ink.upperBound - ink.lowerBound, wholeInkWidth("Sensitive", font: sensitive.statusField.font!) - 0.5)
        XCTAssertNil(inkColumns(rep, region: sensitive.promptField.frame, bounds: sensitive.bounds), "a sensitive row shows no prompt")
    }

    func testTheResumedLineInARealSidebarRowIsDrawnAndNotClipped() throws {
        var f = Focus(id: "ABCDEF12-0000", agentTag: "cody", projectPath: "/tmp/nostromo", isBuiltIn: false)
        f.resumedAt = F.now
        let item = NavTabItem(focus: f, label: "Cody in Nostromo", secondary: "main", indented: false)
        item.appearance = NSAppearance(named: .darkAqua)
        item.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        item.layoutSubtreeIfNeeded()
        XCTAssertTrue(item.secondaryText?.hasPrefix("resumed \u{00B7} ") == true, item.secondaryText ?? "nil")
        let frame = try XCTUnwrap(item.secondaryFrame)
        XCTAssertTrue(item.bounds.contains(frame), "second line inside the row: \(frame)")
        let rep = try render(item)
        let ink = try XCTUnwrap(inkColumns(rep, region: frame, bounds: item.bounds, flipped: item.isFlipped), "second line drew nothing")
        let font = Theme.navSubFont
        let whole = wholeInkWidth(item.secondaryText ?? "", font: font)
        XCTAssertGreaterThanOrEqual(ink.upperBound - ink.lowerBound, min(whole, frame.width) - 1, "the line is clipped")
        XCTAssertLessThanOrEqual(ink.upperBound, item.bounds.width - 2)
    }
}
