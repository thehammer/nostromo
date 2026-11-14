import XCTest
import AppKit
import NostromoKit

// The slash-command picker, RENDERED: real pixels, because frames and strings cannot show what the eye sees.
//
// A row is the command's name (monospaced, bright), an optional argument hint and the description (both
// muted), on the picker's own background. The description is the long, variable part: it must tail-truncate
// (end in an ellipsis inside its column), never run clipped mid-glyph to the column's edge or into the
// trailing inset. The selected row has a visible highlight. The muted text keeps WCAG 4.5:1 against the
// background it is actually drawn on.
//
// The views are drawn on `Theme.bgBar` into a bitmap and read back. SlashCommandRowView,
// SlashCommandPickerView, SlashCommandPicker, Theme and the NostromoKit types are compiled into this target
// directly. Reuses the luminance helpers of ModelChipAppearanceTests.swift.

private final class PickerHost: NSView {
    override var isFlipped: Bool { true }
}

final class SlashCommandPickerAppearanceTests: XCTestCase {

    private let widths: [CGFloat] = [320, 600]

    private let longDescription = String(repeating: "The quick brown fox jumps over the lazy dog and keeps going. ", count: 9)
    private let longHint = "<path-to-a-file-or-directory> [--option value] [--another-option value] [--yet-another-option value]"

    private var longEntry: SlashCommandEntryWire {
        SlashCommandEntryWire(name: "security-review", description: longDescription, argumentHint: longHint)
    }

    // MARK: Rendering

    private struct Snapshot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let size: NSSize

        /// The pixels of `rect` (points from the top-left).
        func pixels(in rect: NSRect) -> [NSColor] {
            let r = rect.intersection(NSRect(origin: .zero, size: size))
            guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
            var out: [NSColor] = []
            for y in Int((r.minY * scale).rounded(.down)) ..< Int((r.maxY * scale).rounded(.up)) where y >= 0 && y < rep.pixelsHigh {
                for x in Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up)) where x >= 0 && x < rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append(c) }
                }
            }
            return out
        }

        func pixel(x: CGFloat, y: CGFloat) -> NSColor? {
            rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }

        /// The ink's extent within `rect`: the smallest rect holding every inked pixel, in points; nil with none.
        func inkBounds(in rect: NSRect, isInk: (NSColor) -> Bool) -> NSRect? {
            let r = rect.intersection(NSRect(origin: .zero, size: size))
            guard !r.isNull else { return nil }
            var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
            for y in Int((r.minY * scale).rounded(.down)) ..< Int((r.maxY * scale).rounded(.up)) where y >= 0 && y < rep.pixelsHigh {
                for x in Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up)) where x >= 0 && x < rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), isInk(c) else { continue }
                    minX = min(minX, CGFloat(x) / scale); maxX = max(maxX, CGFloat(x + 1) / scale)
                    minY = min(minY, CGFloat(y) / scale); maxY = max(maxY, CGFloat(y + 1) / scale)
                }
            }
            return minX.isFinite ? NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : nil
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

    private func snapshot(of host: NSView, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws -> Snapshot {
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), file: file, line: line)
        host.cacheDisplay(in: host.bounds, to: rep)
        return Snapshot(rep: rep, scale: CGFloat(rep.pixelsWide) / host.bounds.width, size: host.bounds.size)
    }

    /// One row on the picker's background at `width`.
    private func renderRow(_ entry: SlashCommandEntryWire, selected: Bool, width: CGFloat) throws -> (row: SlashCommandRowView, shot: Snapshot) {
        let size = NSSize(width: width, height: SlashCommandPickerView.rowHeight)
        let window = makeWindow(size)
        let host = PickerHost(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bgBar.cgColor
        window.contentView = host
        let row = SlashCommandRowView(frame: host.bounds)
        row.configure(entry: entry, selected: selected)
        host.addSubview(row)
        row.layoutSubtreeIfNeeded()
        return (row, try snapshot(of: host, in: window))
    }

    /// Faint enough to count the dots of an ellipsis (a 1 px dot at 1x is a partly covered pixel), above the
    /// selected row's own fill (about 0.014).
    private func isInk(_ c: NSColor) -> Bool { modelRelativeLuminance(c) > 0.025 }

    /// Ink on a row whose own fill is `fill` (the picker's background, or a selected row's highlight): brighter
    /// than that fill by more than the faintest ellipsis dot. The highlight is a fill, not ink.
    private func inkOn(_ fill: NSColor) -> (NSColor) -> Bool {
        let floor = max(0.025, modelRelativeLuminance(fill) + 0.02)
        return { modelRelativeLuminance($0) > floor }
    }

    /// What a row's blank space is drawn as, 8 pt inside its right edge (inside the highlight when selected).
    private func rowFill(_ shot: Snapshot, width: CGFloat, midY: CGFloat) throws -> NSColor {
        try XCTUnwrap(shot.pixel(x: width - 8, y: midY), "row fill sample")
    }

    private func brightest(_ pixels: [NSColor]) -> NSColor? {
        pixels.max { modelRelativeLuminance($0) < modelRelativeLuminance($1) }
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        modelContrastRatio(modelRelativeLuminance(a), modelRelativeLuminance(b))
    }

    /// `color` drawn as this render path draws it, on the picker's background, read back.
    private func renderedSwatch(_ color: NSColor) throws -> NSColor {
        let size = NSSize(width: 40, height: 40)
        let window = makeWindow(size)
        let host = PickerHost(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bgBar.cgColor
        let swatch = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = color.cgColor
        host.addSubview(swatch)
        window.contentView = host
        let shot = try snapshot(of: host, in: window)
        return try XCTUnwrap(shot.pixel(x: 20, y: 20))
    }

    private func isMuted(_ ink: NSColor, swatch: NSColor) -> Bool {
        abs(ink.redComponent - swatch.redComponent) < 0.12 && abs(ink.greenComponent - swatch.greenComponent) < 0.12
            && abs(ink.blueComponent - swatch.blueComponent) < 0.12
            && modelRelativeLuminance(ink) <= modelRelativeLuminance(swatch) + 0.03
    }

    // MARK: The name

    func testTheNamesGlyphsAreFullyDrawnWhateverTheRowsWidth() throws {
        let reference = try renderRow(longEntry, selected: false, width: 1400)
        let referenceBand = NSRect(x: reference.row.nameFrame.minX - 3, y: 0, width: reference.row.nameFrame.width + 6,
                                   height: SlashCommandPickerView.rowHeight)
        let referenceInk = try XCTUnwrap(reference.shot.inkBounds(in: referenceBand, isInk: isInk), "the name drew nothing at 1400 pt")

        for width in widths {
            let (row, shot) = try renderRow(longEntry, selected: false, width: width)
            let frame = row.nameFrame
            XCTAssertEqual(row.shownName, "/security-review")
            let ink = try XCTUnwrap(shot.inkBounds(in: NSRect(x: frame.minX - 3, y: 0, width: frame.width + 6,
                                                              height: SlashCommandPickerView.rowHeight), isInk: isInk),
                                    "the name drew nothing at \(width) pt")

            XCTAssertEqual(ink.width, referenceInk.width, accuracy: 1.01, "width \(width): the name's ink is as wide as when nothing constrains it")
            XCTAssertGreaterThanOrEqual(ink.minX, frame.minX - 1, "width \(width): name ink starts inside its frame")
            XCTAssertLessThanOrEqual(ink.maxX, frame.maxX + 1, "width \(width): name ink ends inside its frame")
        }
    }

    // MARK: The right edge and the description's tail

    func testNoInkReachesTheTrailingInsetOrTheRightEdgeOfAnyRow() throws {
        for width in widths {
            for selected in [false, true] {
                let (_, shot) = try renderRow(longEntry, selected: selected, width: width)
                let inset = SlashCommandRowView.horizontalInset
                let strip = NSRect(x: width - inset + 1, y: 0, width: inset - 1, height: SlashCommandPickerView.rowHeight)
                let isInk = inkOn(try rowFill(shot, width: width, midY: SlashCommandPickerView.rowHeight / 2))

                let ink = try XCTUnwrap(shot.inkBounds(in: NSRect(origin: .zero, size: shot.size), isInk: isInk))

                XCTAssertLessThanOrEqual(ink.maxX, width - 2, "width \(width), selected \(selected): ink within 2 px of the right edge")
                XCTAssertNil(shot.inkBounds(in: strip, isInk: isInk), "width \(width), selected \(selected): ink in the trailing inset")
            }
        }
    }

    func testALongDescriptionEndsInAnEllipsisNotAGlyphCutInHalf() throws {
        for width in widths {
            for selected in [false, true] {
                let (row, shot) = try renderRow(longEntry, selected: selected, width: width)
                XCTAssertGreaterThan(row.shownDescription.count, 500, "the fixture is a very long description")
                let isInk = inkOn(try rowFill(shot, width: width, midY: SlashCommandPickerView.rowHeight / 2))
                let column = row.descriptionFrame
                let ink = try XCTUnwrap(shot.inkBounds(in: column, isInk: isInk), "width \(width): the description drew nothing")

                // The last ~6 pt of ink: an ellipsis is dots on the baseline (a few points tall); a clipped run
                // of text is letters (x-height and up). Truncated text ends before the column's edge, never at it.
                let tail = NSRect(x: ink.maxX - 6, y: column.minY, width: 6, height: column.height)
                let tailInk = try XCTUnwrap(shot.inkBounds(in: tail, isInk: isInk))
                XCTAssertLessThanOrEqual(tailInk.height, 4,
                                         "width \(width), selected \(selected): the description's last glyphs are \(tailInk.height) pt tall, so it was clipped, not tail-truncated")
                XCTAssertLessThanOrEqual(ink.maxX, column.maxX, "width \(width): description ink stays in its column")
            }
        }
    }

    func testTheHintNeverRunsIntoTheDescription() throws {
        for width in widths {
            let (row, shot) = try renderRow(longEntry, selected: false, width: width)
            let column = row.descriptionFrame
            let gap = NSRect(x: column.minX - 6, y: 0, width: 6, height: SlashCommandPickerView.rowHeight)

            XCTAssertNil(shot.inkBounds(in: gap, isInk: isInk), "width \(width): ink in the gap before the description")
            XCTAssertGreaterThan(column.minX, row.nameFrame.maxX, "width \(width): the description starts after the name")
        }
    }

    // MARK: Selection

    func testTheSelectedRowIsVisiblyHighlightedAndTheOtherIsNot() throws {
        for width in widths {
            let plain = try renderRow(longEntry, selected: false, width: width).shot
            let chosen = try renderRow(longEntry, selected: true, width: width).shot
            let y = SlashCommandPickerView.rowHeight / 2

            // Left of the text, inside the highlight's fill: 8 pt in. And the 2 pt accent bar at 5 pt.
            let fillPlain = try XCTUnwrap(plain.pixel(x: 8, y: y)), fillChosen = try XCTUnwrap(chosen.pixel(x: 8, y: y))
            let barPlain = try XCTUnwrap(plain.pixel(x: 5, y: y)), barChosen = try XCTUnwrap(chosen.pixel(x: 5, y: y))

            XCTAssertGreaterThan(fillChosen.redComponent - fillPlain.redComponent, 0.05, "width \(width): highlight fill")
            XCTAssertGreaterThan(fillChosen.greenComponent - fillPlain.greenComponent, 0.05, "width \(width): highlight fill")
            XCTAssertGreaterThan(barChosen.blueComponent - barChosen.redComponent, 0.3, "width \(width): the accent bar is blue")
            XCTAssertLessThan(abs(barPlain.blueComponent - barPlain.redComponent), 0.05, "width \(width): an unselected row has no accent")
            let farRight = try XCTUnwrap(plain.pixel(x: width - 2, y: y))
            XCTAssertLessThan(abs(fillPlain.redComponent - farRight.redComponent), 0.02,
                              "width \(width): an unselected row is the picker's own background")
        }
    }

    // MARK: Contrast

    func testTheMutedDescriptionAndHintAreFgMutedAndReadableOnThePickersBackground() throws {
        let muted = try renderedSwatch(Theme.fgMuted)
        for width in widths {
            let (row, shot) = try renderRow(longEntry, selected: false, width: width)
            let background = try XCTUnwrap(shot.pixel(x: width - 3, y: 2), "background sample")
            let descriptionInk = try XCTUnwrap(brightest(shot.pixels(in: row.descriptionFrame).filter(isInk)), "width \(width): no description ink")

            XCTAssertTrue(isMuted(descriptionInk, swatch: muted), "width \(width): description ink \(descriptionInk) is not Theme.fgMuted (\(muted))")
            XCTAssertGreaterThanOrEqual(contrast(descriptionInk, background), 4.5, "width \(width): description contrast")
            let pickerBackground = try renderedSwatch(Theme.bgBar)
            XCTAssertEqual(contrast(background, pickerBackground), 1, accuracy: 0.05,
                           "width \(width): the sampled background is the picker's")
        }
    }

    func testTheNameIsReadableOnThePickersBackground() throws {
        for width in widths {
            let (row, shot) = try renderRow(longEntry, selected: false, width: width)
            let background = try XCTUnwrap(shot.pixel(x: width - 3, y: 2))
            let ink = try XCTUnwrap(brightest(shot.pixels(in: row.nameFrame).filter(isInk)))

            XCTAssertGreaterThanOrEqual(contrast(ink, background), 7, "width \(width): name contrast")
        }
    }

    func testTheMutedTokenItselfMeetsFourPointFiveToOneOnTheBackground() {
        XCTAssertGreaterThanOrEqual(contrast(Theme.fgMuted, Theme.bgBar), 4.5)
    }

    // MARK: The whole picker

    private func openPicker(entries: [SlashCommandEntryWire], isFallback: Bool) -> SlashCommandPicker {
        let picker = SlashCommandPicker()
        picker.catalog = { SlashCommandCatalog(entries: entries, isFallback: isFallback) }
        picker.update(text: "/", caret: 1)
        return picker
    }

    private func renderPicker(_ picker: SlashCommandPicker, width: CGFloat) throws -> (view: SlashCommandPickerView, shot: Snapshot) {
        let view = SlashCommandPickerView(picker: picker)
        view.reload()
        let size = NSSize(width: width, height: view.preferredHeight)
        let window = makeWindow(size)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        return (view, try snapshot(of: view, in: window))
    }

    func testEveryRowOfTheDrawnPickerKeepsItsTextOutOfTheTrailingInsetAndTheFirstRowIsHighlighted() throws {
        let entries = (0..<12).map {
            SlashCommandEntryWire(name: String(format: "cmd-%02d", $0), description: longDescription, argumentHint: $0 % 2 == 0 ? longHint : nil)
        }
        for width in widths {
            let picker = openPicker(entries: entries, isFallback: false)
            let (view, shot) = try renderPicker(picker, width: width)

            XCTAssertEqual(view.visibleRows.count, SlashCommandPicker.maxVisibleRows, "a long list shows at most eight rows")
            let inset = SlashCommandRowView.horizontalInset
            for (i, row) in view.visibleRows.enumerated() {
                let isInk = inkOn(try rowFill(shot, width: width, midY: row.frame.midY))
                // Inside the picker's 1 pt rounded border (first row's top, last row's bottom), at 1x and 2x alike.
                let strip = NSRect(x: width - inset + 1, y: row.frame.minY + 3, width: inset - 4, height: row.frame.height - 6)
                XCTAssertNil(shot.inkBounds(in: strip, isInk: isInk), "width \(width), row \(i): ink in the trailing inset")
                let column = row.descriptionFrame.offsetBy(dx: row.frame.minX, dy: row.frame.minY)
                let ink = try XCTUnwrap(shot.inkBounds(in: column, isInk: isInk), "width \(width), row \(i): no description")
                let tail = try XCTUnwrap(shot.inkBounds(in: NSRect(x: ink.maxX - 6, y: column.minY, width: 6, height: column.height), isInk: isInk))
                XCTAssertLessThanOrEqual(tail.height, 4, "width \(width), row \(i): the description is clipped, not tail-truncated")
            }
            let first = view.visibleRows[0].frame, second = view.visibleRows[1].frame
            let one = try XCTUnwrap(shot.pixel(x: 8, y: first.midY)), two = try XCTUnwrap(shot.pixel(x: 8, y: second.midY))
            XCTAssertGreaterThan(one.redComponent - two.redComponent, 0.05, "width \(width): the selected row is highlighted, the next is not")
        }
    }

    func testTheFallbackFooterIsMutedReadableAndTailTruncatedAtNarrowWidths() throws {
        let muted = try renderedSwatch(Theme.fgMuted)
        for width in widths {
            let picker = openPicker(entries: BuiltinSlashCommands.fallback, isFallback: true)
            let (view, shot) = try renderPicker(picker, width: width)
            let footer = NSRect(x: 0, y: view.bounds.height - SlashCommandPickerView.footerHeight, width: width,
                                height: SlashCommandPickerView.footerHeight)
            let background = try XCTUnwrap(shot.pixel(x: width / 2, y: 2))

            let ink = try XCTUnwrap(brightest(shot.pixels(in: footer.insetBy(dx: 2, dy: 2)).filter(isInk)), "width \(width): the footer drew nothing")
            XCTAssertTrue(isMuted(ink, swatch: muted), "width \(width): footer ink \(ink)")
            XCTAssertGreaterThanOrEqual(contrast(ink, background), 4.5, "width \(width): footer contrast")
            // Away from the picker's own rounded border, which curves in at the bottom corners.
            let bounds = try XCTUnwrap(shot.inkBounds(in: NSRect(x: 4, y: footer.minY + 3, width: width - 8, height: 18), isInk: isInk))
            XCTAssertLessThanOrEqual(bounds.maxX, width - SlashCommandRowView.horizontalInset + 1, "width \(width): footer text stays out of the inset")
        }
    }
}
