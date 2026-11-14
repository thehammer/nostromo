import XCTest
import AppKit
import NostromoKit

// What the DEPENDS ON section looks like once drawn: a title that cannot be wrapped or pushed past the
// section's edge, a reason that wraps instead of being cut, and colours that tell blocked from waiting.
// These render the section to pixels and read the ink; the last test lays it out in the real Mother pane.
//
// Window indexes for the real-layout test stay inside 900...989.
final class MotherDependencySectionAppearanceTests: XCTestCase {

    private typealias F = MDepFixtures
    private let dep = "20261113T221332Z-afae98a4"

    // MARK: - Rendering

    private struct Rendered {
        let section: MotherDependencySectionView
        let rep: NSBitmapImageRep
        let scale: CGFloat

        /// Pixel rows (top-down) and columns covered by `view`.
        func pixelRect(of view: NSView) -> (cols: Range<Int>, rows: Range<Int>) {
            let r = section.convert(view.bounds, from: view)
            let top = section.isFlipped ? r.minY : section.bounds.height - r.maxY
            let c0 = max(0, Int((r.minX * scale).rounded(.down))), c1 = min(rep.pixelsWide, Int((r.maxX * scale).rounded(.up)))
            let r0 = max(0, Int((top * scale).rounded(.down))), r1 = min(rep.pixelsHigh, Int(((top + r.height) * scale).rounded(.up)))
            return (c0..<max(c0, c1), r0..<max(r0, r1))
        }

        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }

        /// Inked pixels (alpha over a clear threshold) inside the region.
        func ink(cols: Range<Int>, rows: Range<Int>) -> [(x: Int, y: Int)] {
            var out: [(x: Int, y: Int)] = []
            for y in rows { for x in cols where alpha(x, y) > 0.25 { out.append((x: x, y: y)) } }
            return out
        }

        func meanColour(cols: Range<Int>, rows: Range<Int>) -> NSColor? {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
            for y in rows { for x in cols {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5,
                      let s = c.usingColorSpace(.sRGB) else { continue }
                r += s.redComponent; g += s.greenComponent; b += s.blueComponent; n += 1
            } }
            return n > 0 ? NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1) : nil
        }
    }

    private func render(_ rows: [MotherDependencyRow], width: CGFloat) throws -> Rendered {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        let window = MDFixedWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil); window.contentView = nil }

        let section = MotherDependencySectionView(frame: .zero)
        section.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(section)
        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: container.topAnchor),
            section.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            section.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        section.update(rows: rows)
        MD.pump(window, seconds: 0.3)
        for _ in 0..<3 { container.layoutSubtreeIfNeeded() }   // wrapping labels settle their width, then their height

        XCTAssertEqual(section.frame.width, width, accuracy: 0.5)
        let rep = try XCTUnwrap(section.bitmapImageRepForCachingDisplay(in: section.bounds))
        section.cacheDisplay(in: section.bounds, to: rep)
        return Rendered(section: section, rep: rep, scale: CGFloat(rep.pixelsWide) / section.bounds.width)
    }

    private var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 11)) }

    private func longTitleRows(wait: MotherDepWait?) -> [MotherDependencyRow] {
        let title = String(repeating: "abcdefghij", count: 30)   // 300 characters, no spaces
        let queue = [F.job(dep, state: "running", title: title)]
        return F.rows(F.job("j", deps: [dep], wait: wait), in: queue)
    }

    // MARK: - Title and reason

    func testALongUnbrokenTitleStaysOnOneLineInsideTheSectionAt240And420() throws {
        for width: CGFloat in [240, 420] {
            let r = try render(longTitleRows(wait: F.wait(dep, "pr_open", url: "https://github.com/o/r/pull/6233")), width: width)
            let row = try XCTUnwrap(r.section.visibleRowViews.first)
            let line = try XCTUnwrap(row.button)
            let region = r.pixelRect(of: line)
            let ink = r.ink(cols: 0..<r.rep.pixelsWide, rows: region.rows)
            XCTAssertFalse(ink.isEmpty, "\(Int(width)) pt: the title row drew nothing")

            let extent = CGFloat(ink.map { $0.y }.max()! - ink.map { $0.y }.min()! + 1) / r.scale
            XCTAssertLessThanOrEqual(extent, lineHeight * 1.3, "\(Int(width)) pt: the title's ink spans more than one text line (\(extent) pt)")

            let rightmost = ink.map { $0.x }.max()!
            XCTAssertLessThanOrEqual(rightmost, r.rep.pixelsWide - 1 - 2,
                                     "\(Int(width)) pt: the title's ink reaches the section's right edge (column \(rightmost) of \(r.rep.pixelsWide))")
            XCTAssertGreaterThan(CGFloat(rightmost) / r.scale, width * 0.5, "\(Int(width)) pt: a long title fills most of the row")
        }
    }

    func testTheReasonWrapsOverSeveralLinesAt240AndStaysAboveTheSectionsBottom() throws {
        let r = try render(longTitleRows(wait: F.wait(dep, "pr_open", url: "https://github.com/o/r/pull/6233")), width: 240)
        let reason = try XCTUnwrap(r.section.visibleRowViews.first?.reasonLabel)
        let region = r.pixelRect(of: reason)
        let ink = r.ink(cols: 0..<r.rep.pixelsWide, rows: region.rows)
        XCTAssertFalse(ink.isEmpty)
        let extent = CGFloat(ink.map { $0.y }.max()! - ink.map { $0.y }.min()! + 1) / r.scale
        XCTAssertGreaterThanOrEqual(extent, lineHeight * 1.5, "at 240 pt the reason needs at least two lines (\(extent) pt of ink)")

        let all = r.ink(cols: 0..<r.rep.pixelsWide, rows: 0..<r.rep.pixelsHigh)
        let lowest = all.map { $0.y }.max()!
        XCTAssertLessThan(lowest, r.rep.pixelsHigh - 1, "the reason's last line is cut off by the section's bottom edge")
        XCTAssertLessThanOrEqual(CGFloat(ink.map { $0.x }.max()!) / r.scale, 240 - 2 / r.scale, "the reason stays inside the section")
    }

    func testTheReasonNeedsFewerLinesWhenTheSectionIsWider() throws {
        let rows = longTitleRows(wait: F.wait(dep, "pr_open", url: "https://github.com/o/r/pull/6233"))
        func reasonHeight(_ width: CGFloat) throws -> CGFloat {
            let r = try render(rows, width: width)
            return try XCTUnwrap(r.section.visibleRowViews.first?.reasonLabel).frame.height
        }
        XCTAssertGreaterThan(try reasonHeight(240), try reasonHeight(900), "the reason reflows with the width instead of keeping one size")
    }

    // MARK: - Colour

    func testABlockedReasonIsAmberAndAWaitingReasonIsMuted() throws {
        func reasonColour(_ wait: MotherDepWait) throws -> NSColor {
            let r = try render(longTitleRows(wait: wait), width: 420)
            let reason = try XCTUnwrap(r.section.visibleRowViews.first?.reasonLabel)
            let region = r.pixelRect(of: reason)
            return try XCTUnwrap(r.meanColour(cols: region.cols, rows: region.rows), "the reason drew no text")
        }
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            let x = a.usingColorSpace(.sRGB)!, y = b.usingColorSpace(.sRGB)!
            return abs(x.redComponent - y.redComponent) + abs(x.greenComponent - y.greenComponent) + abs(x.blueComponent - y.blueComponent)
        }
        let blocked = try reasonColour(F.wait(dep, "dep_failed", blocked: true))
        let waiting = try reasonColour(F.wait(dep, "pr_open", url: "https://github.com/o/r/pull/6233"))
        XCTAssertLessThan(distance(blocked, Theme.amber), distance(blocked, Theme.fgMuted), "blocked reads amber: \(blocked)")
        XCTAssertLessThan(distance(waiting, Theme.fgMuted), distance(waiting, Theme.amber), "waiting reads muted: \(waiting)")
        XCTAssertGreaterThan(distance(blocked, waiting), 0.3, "blocked and waiting are told apart")
    }

    // MARK: - In the real Mother pane

    func testTwelveLongTitledDependenciesFitTheNarrowestDetailWithoutSidewaysScroll() throws {
        let w = try MD.makeWindow(self, index: 900)
        let dir = try MD.makeTemp(self)
        let ids = (0..<12).map { F.id($0) }
        let long = String(repeating: "abcdefghij", count: 30)
        let queue = ids.enumerated().map { F.job($1, state: "running", title: "Dependency \($0) " + long) }
        let job = F.job("j-narrow", deps: ids, wait: F.wait(ids[8], "pr_open", url: "https://github.com/o/r/pull/6233"))

        let detail = MotherJobDetail(host: MDStubHost(), logDirectory: dir)
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.dependencyLookup = { id in queue.first { $0.id == id } }
        w.pane.addTab(TabRegionView.Tab(paneId: "mother_job:\(job.id)", label: "job", view: detail))
        addTeardownBlock { detail.select(nil); w.close() }

        w.motherView.setListWidth(10_000)   // clamps to the widest list, so the narrowest detail
        detail.select(job)
        MD.pump(w.window)
        detail.dependencySection.toggleButton.performClick(nil)   // all twelve rows, the worst case
        MD.pump(w.window)

        let clip = detail.contentScrollView.contentView
        let document = try XCTUnwrap(detail.contentScrollView.documentView)
        XCTAssertEqual(document.frame.width, clip.bounds.width, accuracy: 1, "the Overview's document is as wide as its clip: no sideways scroll")
        XCTAssertLessThanOrEqual(detail.frame.width, MotherListWidth.detailMinimum + 1, "precondition: the narrowest detail")

        let section = detail.dependencySection
        XCTAssertEqual(section.visibleRowViews.count, 12)
        let frame = document.convert(section.bounds, from: section)
        XCTAssertGreaterThanOrEqual(frame.minX, 16 - 0.5, "the section starts inside the left margin")
        XCTAssertLessThanOrEqual(frame.maxX, document.bounds.width - 16 + 0.5, "the section ends inside the right margin")
        for row in section.visibleRowViews {
            let r = section.convert(row.bounds, from: row)
            XCTAssertLessThanOrEqual(r.maxX, section.bounds.width + 0.5, "row \(row.row.shortId) pokes out of the section")
        }
    }
}
