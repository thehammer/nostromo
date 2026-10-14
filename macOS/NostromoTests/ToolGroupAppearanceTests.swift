import XCTest
import AppKit
import NostromoKit

// TF2: the group row must be legible. Rendered to a bitmap under the app's dark appearance, on
// the colour the transcript actually draws, in a key window and in one that is not key, and in
// its hover state. Contrast is the WCAG ratio, (L1 + 0.05) / (L2 + 0.05), over sRGB relative
// luminance of the pixels that came out, not of the colours that went in.
//
// Why `Theme.bg`: `ReplView`'s layer is `Theme.bg`, and the scroll view and its document view
// draw nothing, so that is what shows behind a row. Every colour the row draws with is explicit
// (never a semantic or catalogue colour), so the result cannot depend on the system appearance.

private final class NotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { false }
}

final class ToolGroupAppearanceTests: XCTestCase {

    private typealias F = FoldFixtures

    private static let rowWidth: CGFloat = 520

    private struct Sample {
        var base: NSColor
        var summary: NSColor
        var badge: NSColor
    }

    // MARK: Pixels and contrast

    private func relativeLuminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB) ?? color
        func linear(_ v: CGFloat) -> Double {
            let s = Double(v)
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func name(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "rgb(%.0f,%.0f,%.0f)", s.redComponent * 255, s.greenComponent * 255, s.blueComponent * 255)
    }

    /// Renders a row (a group with a failure and a duration, so summary, badge and time all show)
    /// and reads back the pixels.
    private func render(keyWindow: Bool, hovered: Bool, file: StaticString = #filePath, line: UInt = #line) -> Sample? {
        _ = NSApplication.shared
        let size = NSSize(width: Self.rowWidth, height: ToolGroupRowView.height)
        let window: NSWindow
        if keyWindow {
            window = makeRigWindow(self, size: size, appearance: NSAppearance(named: .darkAqua))
        } else {
            window = NotKeyWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            addTeardownBlock { window.close() }
        }
        XCTAssertEqual(window.isKeyWindow, keyWindow, file: file, line: line)

        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = Theme.bg.cgColor
        window.contentView = host

        let row = ToolGroupRowView(group: F.failingGroup(calls: 4), isExpanded: false, payloadAvailable: true)
        row.frame = host.bounds
        host.addSubview(row)
        row.isHovered = hovered
        host.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not render the row", file: file, line: line)
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width

        func pixels(in rect: NSRect) -> [(x: Int, y: Int, color: NSColor)] {
            let r = rect.intersection(host.bounds)
            let xs = Int((r.minX * scale).rounded(.down)) ..< Int((r.maxX * scale).rounded(.up))
            let ys = Int(((host.bounds.height - r.maxY) * scale).rounded(.down)) ..< Int(((host.bounds.height - r.minY) * scale).rounded(.up))
            var out: [(Int, Int, NSColor)] = []
            for y in ys where y >= 0 && y < rep.pixelsHigh {
                for x in xs where x >= 0 && x < rep.pixelsWide {
                    if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append((x, y, c)) }
                }
            }
            return out
        }
        func brightest(in view: NSView) -> NSColor? {
            let rect = view.convert(view.bounds, to: host)
            return pixels(in: rect).max { relativeLuminance($0.color) < relativeLuminance($1.color) }?.color
        }

        // Base: the median pixel of the row away from the triangle and every text field.
        let fieldRects = [row.summaryField, row.badgeField, row.timeField]
            .filter { !$0.isHidden }.map { $0.convert($0.bounds, to: host).insetBy(dx: -3, dy: -3) }
        let away = pixels(in: host.bounds).filter { p in
            let point = NSPoint(x: CGFloat(p.x) / scale, y: host.bounds.height - CGFloat(p.y) / scale)
            return point.x > 26 && !fieldRects.contains { $0.contains(point) }
        }.map(\.color).sorted { relativeLuminance($0) < relativeLuminance($1) }

        guard let base = away.isEmpty ? nil : away[away.count / 2],
              let summary = brightest(in: row.summaryField),
              let badge = brightest(in: row.badgeField)
        else {
            XCTFail("nothing drawn: base \(away.count) pixels, summary \(row.summaryField.frame), badge \(row.badgeField.frame) hidden=\(row.badgeField.isHidden)",
                    file: file, line: line)
            return nil
        }
        return Sample(base: base, summary: summary, badge: badge)
    }

    private func assertLegible(keyWindow: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let label = keyWindow ? "key window" : "non-key window"
        guard let rest = render(keyWindow: keyWindow, hovered: false, file: file, line: line),
              let hover = render(keyWindow: keyWindow, hovered: true, file: file, line: line)
        else { return }

        let summaryOnBase = contrast(rest.summary, rest.base)
        let summaryOnHover = contrast(hover.summary, hover.base)
        let badgeOnBase = contrast(rest.badge, rest.base)
        let badgeOnHover = contrast(hover.badge, hover.base)
        let hoverVsBase = contrast(hover.base, rest.base)
        print("""
        [ToolGroupAppearance \(label)] base \(name(rest.base)) hover \(name(hover.base)) \
        summary \(name(rest.summary)) badge \(name(rest.badge))
        [ToolGroupAppearance \(label)] summary/base \(String(format: "%.2f", summaryOnBase)) \
        summary/hover \(String(format: "%.2f", summaryOnHover)) badge/base \(String(format: "%.2f", badgeOnBase)) \
        badge/hover \(String(format: "%.2f", badgeOnHover)) hover/base \(String(format: "%.2f", hoverVsBase))
        """)

        XCTAssertGreaterThanOrEqual(summaryOnBase, 4.5, "\(label): summary on the transcript background", file: file, line: line)
        XCTAssertGreaterThanOrEqual(summaryOnHover, 4.5, "\(label): summary on the hover fill", file: file, line: line)
        XCTAssertGreaterThanOrEqual(badgeOnBase, 4.5, "\(label): failure badge on the transcript background", file: file, line: line)
        XCTAssertGreaterThanOrEqual(badgeOnHover, 4.5, "\(label): failure badge on the hover fill", file: file, line: line)
        XCTAssertGreaterThanOrEqual(hoverVsBase, 1.2, "\(label): the hover fill must be visible against the background", file: file, line: line)
    }

    // MARK: Tests

    func testTheRowIsLegibleInTheKeyWindow() { assertLegible(keyWindow: true) }

    func testTheRowIsLegibleInAWindowThatIsNotKey() { assertLegible(keyWindow: false) }

    func testTheRowLooksTheSameWhetherOrNotItsWindowIsKey() throws {
        let key = try XCTUnwrap(render(keyWindow: true, hovered: false))
        let notKey = try XCTUnwrap(render(keyWindow: false, hovered: false))
        XCTAssertEqual(contrast(key.summary, notKey.summary), 1.0, accuracy: 0.05, "the summary does not dim in an inactive window")
        XCTAssertEqual(contrast(key.badge, notKey.badge), 1.0, accuracy: 0.05, "the badge does not dim in an inactive window")
    }

    func testTheBadgeIsReadableAsRedNotJustBright() throws {
        let sample = try XCTUnwrap(render(keyWindow: true, hovered: false))
        let c = try XCTUnwrap(sample.badge.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(c.redComponent, c.greenComponent + 0.15, "the failure badge reads as red")
        XCTAssertGreaterThan(c.redComponent, c.blueComponent + 0.15)
    }

    // MARK: Colours

    func testEveryColourTheRowDrawsWithIsExplicit() {
        XCTAssertFalse(ToolGroupRowView.palette.isEmpty)
        for color in ToolGroupRowView.palette {
            XCTAssertEqual(color.type, .componentBased,
                           "\(color) is a catalogue or pattern colour: it would change with the system appearance")
        }
        XCTAssertEqual(Theme.foldFailure.type, .componentBased)
        XCTAssertEqual(Theme.foldHover.type, .componentBased)
        XCTAssertEqual(Theme.bg.type, .componentBased)
    }

    func testTheRowsTextColoursComeFromItsPalette() {
        let row = ToolGroupRowView(group: F.failingGroup(calls: 3), isExpanded: false, payloadAvailable: true)
        let palette = ToolGroupRowView.palette
        XCTAssertTrue(row.summaryField.textColor.map { color in palette.contains { $0 == color } } ?? false,
                      "summary colour \(String(describing: row.summaryField.textColor)) is not in the palette")
        XCTAssertTrue(row.badgeField.textColor.map { color in palette.contains { $0 == color } } ?? false,
                      "badge colour \(String(describing: row.badgeField.textColor)) is not in the palette")
        XCTAssertEqual(row.badgeField.textColor, Theme.foldFailure)
    }
}
