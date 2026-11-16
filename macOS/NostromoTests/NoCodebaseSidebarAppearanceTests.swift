import AppKit
import XCTest

/// What a "No codebase" row actually draws, read back from rendered pixels (frames alone cannot see a glyph
/// that is missing, tinted away, or a second line clipped by a field that is too narrow). A pixel is "ink"
/// when it differs from the row's own background, sampled at a quiet spot on the row.
final class NoCodebaseSidebarAppearanceTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    // MARK: Rig

    private func noCodebaseFocus(label: String? = nil) -> Focus {
        var f = Focus(id: "33333333-0000-0000-0000-000000000003", agentTag: "claudia", projectPath: nil,
                      isBuiltIn: false, org: "Personal")
        f.label = label
        f.noCodebase = true
        f.workingDirectory = "/spaces/AAAA"
        return f
    }

    private func repoFocus() -> Focus {
        Focus(id: "44444444-0000-0000-0000-000000000004", agentTag: "claudia",
              projectPath: "/Users/hammer/Code/nostromo", isBuiltIn: false, org: "Carefeed")
    }

    /// A row hosted pinned as `TabBarView` pins one (required width and height, leading and top to its
    /// container) in an off-screen window, at the real sidebar width unless said otherwise.
    private func makeItem(focus: Focus, label: String, secondary: String,
                          width: CGFloat = Theme.sidebarWidth) -> NavTabItem {
        let item = NavTabItem(focus: focus, label: label, secondary: secondary, indented: false)
        let height = Theme.navItemSubtitleHeight
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        windows.append(window)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 20))
        window.contentView = host
        item.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(item)
        NSLayoutConstraint.activate([
            item.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            item.topAnchor.constraint(equalTo: host.topAnchor),
            item.widthAnchor.constraint(equalToConstant: width),
            item.heightAnchor.constraint(equalToConstant: height),
        ])
        host.layoutSubtreeIfNeeded()
        return item
    }

    private func relayout(_ item: NavTabItem) { (item.superview ?? item).layoutSubtreeIfNeeded() }

    private func ncItem(label: String? = nil) -> NavTabItem {
        let f = noCodebaseFocus(label: label)
        return makeItem(focus: f, label: label ?? f.displayName, secondary: "No codebase")
    }

    private func repoItem() -> NavTabItem {
        makeItem(focus: repoFocus(), label: "Claudia in Nostromo", secondary: "main")
    }

    // MARK: Pixels

    private struct Raster {
        let rep: NSBitmapImageRep
        let item: NavTabItem
        let scale: CGFloat
        let background: NSColor

        init(_ item: NavTabItem) throws {
            self.item = item
            let rep = try XCTUnwrap(item.bitmapImageRepForCachingDisplay(in: item.bounds), "could not render the row")
            item.cacheDisplay(in: item.bounds, to: rep)
            self.rep = rep
            scale = CGFloat(rep.pixelsWide) / item.bounds.width
            // The row's own background, from a quiet spot: the right edge, mid-height (no pills in these rows).
            background = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide - 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }

        private func differs(_ c: NSColor) -> Bool {
            guard let c = c.usingColorSpace(.sRGB) else { return false }
            let d = [abs(c.redComponent - background.redComponent), abs(c.greenComponent - background.greenComponent),
                     abs(c.blueComponent - background.blueComponent), abs(c.alphaComponent - background.alphaComponent)]
            return (d.max() ?? 0) > 0.25
        }

        /// How much ink is in `rect` (this view's coordinates), and the horizontal extent of it in points.
        func ink(in rect: NSRect) -> (count: Int, minX: CGFloat, maxX: CGFloat) {
            let r = rect.intersection(item.bounds)
            guard !r.isNull, r.width > 0, r.height > 0 else { return (0, 0, 0) }
            let top = item.isFlipped ? r.minY : item.bounds.height - r.maxY   // bitmap rows run top-down
            let xs = Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up))
            let ys = Int((top * scale).rounded(.down)) ..< Int(((top + r.height) * scale).rounded(.up))
            var count = 0
            var first = Int.max, last = -1
            for y in ys where y >= 0 && y < rep.pixelsHigh {
                for x in xs where x >= 0 && x < rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y), differs(c) else { continue }
                    count += 1
                    first = min(first, x)
                    last = max(last, x)
                }
            }
            guard count > 0 else { return (0, 0, 0) }
            return (count, CGFloat(first) / scale, CGFloat(last + 1) / scale)
        }
    }

    /// The horizontal extent, in points, of `text` drawn alone and unclipped in `font`.
    private func referenceInkWidth(_ text: String, font: NSFont, scale: CGFloat) -> CGFloat {
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let size = NSSize(width: ceil(str.size().width) + 8, height: 20)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        str.draw(at: NSPoint(x: 4, y: 5))
        NSGraphicsContext.restoreGraphicsState()
        var first = Int.max, last = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                first = min(first, x)
                last = max(last, x)
            }
        }
        return last < 0 ? 0 : CGFloat(last - first + 1) / scale
    }

    // MARK: The speech bubble

    func testTheBubbleIsDrawnInTheActivityMarksSlotInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let item = ncItem()
            item.appearance = try XCTUnwrap(NSAppearance(named: name))
            relayout(item)
            let glyph = try XCTUnwrap(item.noCodebaseGlyphFrame, "a no-codebase row shows its bubble (\(name.rawValue))")
            XCTAssertEqual(glyph, item.activitySlotFrame, "the same slot the activity mark uses")
            XCTAssertEqual(glyph.size, NSSize(width: 8, height: 8), "the same 8 pt")
            let ink = try Raster(item).ink(in: glyph)
            XCTAssertGreaterThanOrEqual(ink.count, 6, "the bubble puts ink on the screen (\(name.rawValue))")
        }
    }

    func testTheBubbleIsDrawnOnTheSelectedRowToo() throws {
        let item = ncItem()
        item.isActive = true
        relayout(item)
        let glyph = try XCTUnwrap(item.noCodebaseGlyphFrame)
        XCTAssertGreaterThanOrEqual(try Raster(item).ink(in: glyph).count, 6)
    }

    func testARepoRowDrawsNoBubbleAndNothingInTheSlot() throws {
        let item = repoItem()
        XCTAssertNil(item.noCodebaseGlyphFrame)
        XCTAssertEqual(try Raster(item).ink(in: item.activitySlotFrame).count, 0, "the slot is empty on a repo row")
    }

    func testARowThatIsNotNoCodebaseNeverGetsTheBubbleWhateverItsWords() throws {
        // A repo focus labelled "No codebase" is still a repo focus.
        var f = repoFocus()
        f.label = "No codebase"
        let item = makeItem(focus: f, label: "No codebase", secondary: "main")
        XCTAssertNil(item.noCodebaseGlyphFrame)
    }

    func testTheBubbleSitsInsideTheRowClearOfTheBarsAndLeftOfTheName() throws {
        let item = ncItem()
        let glyph = try XCTUnwrap(item.noCodebaseGlyphFrame)
        XCTAssertTrue(item.bounds.insetBy(dx: -0.5, dy: -0.5).contains(glyph), "inside the row")
        XCTAssertGreaterThanOrEqual(glyph.minX, 6, "clear of the two 3 pt highlight bars")
        XCTAssertLessThanOrEqual(glyph.maxX, item.nameAlignmentFrame.minX, "it never overlaps the name")
        XCTAssertEqual(glyph.midY, item.labelFrame.midY, accuracy: 1.0, "level with the name")
    }

    func testTheBubbleStepsAsideForAnActivityMarkAndComesBack() throws {
        let item = ncItem()
        XCTAssertNotNil(item.noCodebaseGlyphFrame)

        item.setActivity(.unread(count: 1))
        relayout(item)
        XCTAssertNil(item.noCodebaseGlyphFrame, "one mark in the slot at a time")
        let mark = try XCTUnwrap(item.activityMarkFrame, "the activity mark shows instead")
        XCTAssertGreaterThanOrEqual(try Raster(item).ink(in: mark).count, 6, "and it is the one drawn")

        item.setActivity(.none)
        relayout(item)
        let glyph = try XCTUnwrap(item.noCodebaseGlyphFrame, "the bubble returns when the mark clears")
        XCTAssertGreaterThanOrEqual(try Raster(item).ink(in: glyph).count, 6)
    }

    func testTheBubbleIsNotItsOwnAccessibilityElement() throws {
        let item = ncItem()
        let glyph = try XCTUnwrap(item.noCodebaseGlyphFrame)
        let view = try XCTUnwrap(item.subviews.first { !$0.isHidden && $0.frame == glyph },
                                 "the bubble view is in the row")
        XCTAssertFalse(view.isAccessibilityElement(), "the row's name and second line say it in words")
    }

    // MARK: The second line

    func testTheNoCodebaseSecondLineIsDrawnWholeAndInsideTheRowAtTheRealSidebarWidth() throws {
        let item = ncItem()
        XCTAssertEqual(item.bounds.width, Theme.sidebarWidth, "the real sidebar width")
        XCTAssertEqual(item.secondaryText, "No codebase")
        XCTAssertTrue(item.secondaryVisible)
        let line = try XCTUnwrap(item.secondaryFrame)

        XCTAssertTrue(item.bounds.insetBy(dx: -0.5, dy: -0.5).contains(line), "the field is inside the row: \(line) in \(item.bounds)")
        XCTAssertLessThan(line.intersection(item.labelFrame).height, 1, "and below the name, not over it")
        let textWidth = ("No codebase" as NSString).size(withAttributes: [.font: Theme.navSubFont]).width
        XCTAssertGreaterThanOrEqual(line.width, textWidth, "the field is wide enough for its words")

        let raster = try Raster(item)
        let ink = raster.ink(in: line.insetBy(dx: 0, dy: -1))
        XCTAssertGreaterThan(ink.count, 20, "the words are on the screen")
        XCTAssertGreaterThanOrEqual(ink.minX, line.minX - 1, "not drawn left of its field")
        XCTAssertLessThanOrEqual(ink.maxX, line.maxX + 1, "not drawn past its field")
        XCTAssertLessThanOrEqual(ink.maxX, item.bounds.width, "inside the row")
        let whole = referenceInkWidth("No codebase", font: Theme.navSubFont, scale: raster.scale)
        XCTAssertGreaterThanOrEqual(ink.maxX - ink.minX, whole - 2.5,
                                    "all of \u{201C}No codebase\u{201D} is drawn, not cut or ellipsized (\(ink.maxX - ink.minX) of \(whole) pt)")
    }

    func testTheSecondLineStartsAfterTheBubbleSlotLikeTheName() throws {
        let item = ncItem()
        let line = try XCTUnwrap(item.secondaryFrame)
        let glyph = try XCTUnwrap(item.noCodebaseGlyphFrame)
        XCTAssertGreaterThanOrEqual(line.minX, glyph.maxX, "the words start right of the bubble")
        XCTAssertEqual(line.minX, item.labelFrame.minX, accuracy: 1.0, "aligned with the name")
    }

    func testARepoRowsSecondLineStaysForThePillsAndDrawsNoWords() throws {
        let item = repoItem()
        let line = try XCTUnwrap(item.secondaryFrame)
        XCTAssertEqual(try Raster(item).ink(in: line.insetBy(dx: 0, dy: -1)).count, 0, "nothing drawn there")
    }
}
