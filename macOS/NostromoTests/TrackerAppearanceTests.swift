import XCTest
import AppKit
import NostromoKit

// PRD 16 / design contract 10: the tracker pane must be legible. Rendered to a bitmap under Dark Aqua,
// in a key window and in one that is not key, and measured on the pixels that came out (WCAG contrast,
// (L1 + 0.05) / (L2 + 0.05) over sRGB relative luminance), the way ToolGroupAppearanceTests does it.
//
//   item text (Theme.fg)                                   >= 7:1   on the pane background
//   muted metadata (owner chip, time, counts, notes)       >= 4.5:1
//   status marks (○ ◐ ⊘ ● ✓)                               >= 3:1
//   a needs-you row: text >= 7:1 and muted >= 4.5:1 on its fill
//   the PROD badge text                                    >= 4.5:1 on its fill
//   banner text                                            >= 4.5:1 on the banner fill
//
// Each element is measured against what is actually behind it (the median pixel of its own rectangle:
// the pane background, a chip's fill, the needs-you fill or the banner fill), and the ink is the pixel in
// that rectangle furthest in contrast from it. The bitmap is drawn at 4x so thin glyphs reach their full
// colour; the measurement is of the colours, not of anti-aliasing. Guard tests check the backgrounds
// themselves came out (the pane is Theme.bg, a needs-you row and the banner are visibly filled), so a
// renderer that dropped layer fills cannot turn this into a comparison against black.
//
// Every ratio is printed as `TRACKER-CONTRAST <name> key=<r> nonkey=<r>` for the PR description.

private final class TrackerNotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { false }
}

final class TrackerAppearanceTests: XCTestCase {

    private typealias Fx = TrackerPaneFx

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

    private struct Snapshot {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let bounds: NSRect

        /// Up to ~25k pixels of `rect` (in the view's own coordinates, y down for the flipped pane).
        func samples(in rect: NSRect) -> [NSColor] {
            let r = rect.intersection(bounds)
            guard !r.isEmpty else { return [] }
            let x0 = Int((r.minX * scale).rounded(.down)), x1 = Int((r.maxX * scale).rounded(.up))
            let y0 = Int((r.minY * scale).rounded(.down)), y1 = Int((r.maxY * scale).rounded(.up))
            let stride = max(1, Int((Double(max(x1 - x0, 1) * max(y1 - y0, 1)) / 25_000).squareRoot().rounded(.up)))
            var out: [NSColor] = []
            var y = y0
            while y < y1 {
                var x = x0
                while x < x1 {
                    if x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh,
                       let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { out.append(c) }
                    x += stride
                }
                y += stride
            }
            return out
        }

        var isOpaqueAtTopLeft: Bool {
            (rep.colorAt(x: Int(4 * scale), y: Int(2 * scale))?.alphaComponent ?? 0) > 0.5
        }
    }

    /// The view as pixels, at 4x when AppKit takes a hand-made bitmap and at its own scale otherwise.
    private func snapshot(of view: NSView) -> Snapshot? {
        let bounds = view.bounds
        let scale: CGFloat = 4
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = bounds.size
            view.cacheDisplay(in: bounds, to: rep)
            let snap = Snapshot(rep: rep, scale: scale, bounds: bounds)
            if snap.isOpaqueAtTopLeft { return snap }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return Snapshot(rep: rep, scale: CGFloat(rep.pixelsWide) / bounds.width, bounds: bounds)
    }

    private struct Measurement {
        var ratio: Double
        var base: NSColor
        var ink: NSColor
    }

    // MARK: The rig, once per window kind

    private static var measured: [Bool: [String: Measurement]] = [:]
    private static var problems: [Bool: [String]] = [:]

    private func makeWindow(key: Bool, size: NSSize) -> NSWindow {
        _ = NSApplication.shared
        if key { return makeRigWindow(self, size: size, appearance: NSAppearance(named: .darkAqua)) }
        let window = TrackerNotKeyWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                         backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        addTeardownBlock { window.close() }
        return window
    }

    private func label(_ text: String, in view: NSView) -> NSTextField? {
        rigAllSubviews(of: view).compactMap { $0 as? NSTextField }.first { $0.stringValue == text }
    }

    private func results(keyWindow: Bool) -> (measured: [String: Measurement], problems: [String]) {
        if let done = Self.measured[keyWindow] { return (done, Self.problems[keyWindow] ?? []) }
        var problems: [String] = []
        var measured: [String: Measurement] = [:]

        let paneSize = NSSize(width: 360, height: 600)
        let window = makeWindow(key: keyWindow, size: NSSize(width: paneSize.width, height: paneSize.height + Fx.hostPadding))
        if window.isKeyWindow != keyWindow { problems.append("the window is \(window.isKeyWindow ? "" : "not ")key, wanted \(keyWindow ? "key" : "not key")") }
        let tag = Fx.uniqueTag()
        let rig = Fx.makeRig(self, tag: tag, window: window, size: paneSize)
        let pane = rig.pane

        do {
            var script = try TrackerBoardScript(tag: tag)
            rig.push(script)
            rig.pane.toggleDoneGroup(section: "done")   // so a done item (✓) has a row of its own
            rig.settle()

            /// Measure `target` (a view somewhere in the pane) against what is behind it.
            func measure(_ id: String, _ target: NSView?, scrollingTo key: String? = nil) {
                if let key {
                    guard let row = pane.rowViews[key] else { problems.append("\(id): no row \(key)"); return }
                    rig.scroll(to: max(0, row.frame.minY - 10))
                }
                rig.host.layoutSubtreeIfNeeded()
                rig.host.displayIfNeeded()
                guard let target else { problems.append("\(id): the view to measure was not found"); return }
                guard let snap = snapshot(of: pane) else { problems.append("\(id): could not render the pane"); return }
                var rect = pane.convert(target.bounds, from: target)
                if target.isDescendant(of: pane.documentView) {
                    rect = rect.intersection(pane.convert(pane.clipView.bounds, from: pane.clipView))
                }
                let colors = snap.samples(in: rect)
                guard colors.count > 8 else { problems.append("\(id): \(colors.count) pixels in \(rect)"); return }
                let sorted = colors.sorted { relativeLuminance($0) < relativeLuminance($1) }
                let base = sorted[sorted.count / 2]
                guard let ink = colors.max(by: { contrast($0, base) < contrast($1, base) }) else { return }
                measured[id] = Measurement(ratio: contrast(ink, base), base: base, ink: ink)
            }

            // The pane's own background: the header is mostly empty, so its median pixel is the pane's fill.
            measure("pane-background", pane.header)

            // Item text on the pane background (a todo item with an owner).
            let plain = "item:audit-3183"
            measure("item-text", pane.rowViews[plain]?.textViews.first, scrollingTo: plain)
            // Muted metadata: owner chip, time, count, note first line, Done group label.
            measure("muted-owner", pane.rowViews[plain].flatMap { label("redd", in: $0) }, scrollingTo: plain)
            measure("muted-time", pane.rowViews[plain]?.timeLabel, scrollingTo: plain)
            measure("muted-section-count", pane.rowViews["section:now"].flatMap { label("10", in: $0) }, scrollingTo: "section:now")
            let noted = "item:check-1000"
            measure("muted-note-first-line", pane.rowViews[noted].flatMap { $0.textViews.count > 1 ? $0.textViews[1] : nil }, scrollingTo: noted)
            measure("muted-done-group", pane.rowViews["done:done"]?.textViews.first, scrollingTo: "done:done")

            // Status marks.
            measure("mark-todo", pane.rowViews[plain].flatMap { label("○", in: $0) }, scrollingTo: plain)
            measure("mark-in-progress", pane.rowViews["item:verif-1037"].flatMap { label("◐", in: $0) }, scrollingTo: "item:verif-1037")
            measure("mark-blocked", pane.rowViews["item:repro-1222"].flatMap { label("⊘", in: $0) }, scrollingTo: "item:repro-1222")
            measure("mark-done", pane.rowViews["item:repro-2110"].flatMap { label("✓", in: $0) }, scrollingTo: "item:repro-2110")

            // A needs-you row: the fill, the text and the muted metadata on it, and its mark.
            let needs = "item:docum-1740"
            measure("needs-you-text", pane.rowViews[needs]?.textViews.first, scrollingTo: needs)
            measure("needs-you-muted-owner", pane.rowViews[needs].flatMap { label("me", in: $0) }, scrollingTo: needs)
            measure("needs-you-muted-time", pane.rowViews[needs]?.timeLabel, scrollingTo: needs)
            measure("mark-needs-you", pane.rowViews[needs].flatMap { label("●", in: $0) }, scrollingTo: needs)

            // The PROD badge on its hazard fill.
            let prod = "item:retry-1074"
            measure("prod-badge", pane.rowViews[prod].flatMap { label("PROD", in: $0) }, scrollingTo: prod)

            // A banner over the board.
            script.setBanner(["type": "unreadable", "line": 42, "reason": "duplicate_id", "last_good_at": Fx.iso(1_760_547_000)])
            rig.push(script)
            rig.scroll(to: 0)
            measure("banner-text", pane.banner.label)
        } catch {
            problems.append("could not build the board: \(error)")
        }

        Self.measured[keyWindow] = measured
        Self.problems[keyWindow] = problems
        return (measured, problems)
    }

    // MARK: Assertions

    private func assertAtLeast(_ floor: Double, _ names: [String], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for keyWindow in [true, false] {
            let window = keyWindow ? "key window" : "non-key window"
            let (measured, problems) = results(keyWindow: keyWindow)
            XCTAssertEqual(problems, [], "\(window): the rig had trouble", file: file, line: line)
            for id in names {
                guard let m = measured[id] else { XCTFail("\(window): nothing measured for \(id)", file: file, line: line); continue }
                XCTAssertGreaterThanOrEqual(m.ratio, floor,
                    "\(window): \(what) \(id) is \(String(format: "%.2f", m.ratio)):1 (ink \(name(m.ink)) on \(name(m.base))), needs \(floor):1",
                    file: file, line: line)
            }
        }
    }

    // MARK: Tests

    func testItemTextIsAtLeastSevenToOneOnThePaneBackground() {
        assertAtLeast(7, ["item-text"], "item text")
    }

    func testMutedMetadataIsAtLeastFourPointFiveToOne() {
        assertAtLeast(4.5, ["muted-owner", "muted-time", "muted-section-count", "muted-note-first-line", "muted-done-group"],
                      "muted metadata")
    }

    func testEveryStatusMarkIsAtLeastThreeToOne() {
        assertAtLeast(3, ["mark-todo", "mark-in-progress", "mark-blocked", "mark-needs-you", "mark-done"], "status mark")
    }

    func testANeedsYouRowKeepsItsTextAtSevenToOneAndItsMetadataAtFourPointFiveOnItsFill() {
        assertAtLeast(7, ["needs-you-text"], "needs-you text")
        assertAtLeast(4.5, ["needs-you-muted-owner", "needs-you-muted-time"], "needs-you muted metadata")
    }

    func testTheEnvironmentBadgeTextIsAtLeastFourPointFiveToOneOnItsFill() {
        assertAtLeast(4.5, ["prod-badge"], "PROD badge")
    }

    func testBannerTextIsAtLeastFourPointFiveToOneOnTheBannerFill() {
        assertAtLeast(4.5, ["banner-text"], "banner text")
    }

    // MARK: The backgrounds came out (guards against measuring against black)

    func testThePaneBackgroundIsTheThemeBackgroundAndTheFillsAreVisible() {
        for keyWindow in [true, false] {
            let window = keyWindow ? "key window" : "non-key window"
            let (measured, problems) = results(keyWindow: keyWindow)
            XCTAssertEqual(problems, [], window)
            guard let pane = measured["pane-background"], let plainRow = measured["item-text"],
                  let needs = measured["needs-you-text"], let banner = measured["banner-text"], let prod = measured["prod-badge"]
            else { XCTFail("\(window): backgrounds were not measured: \(measured.keys.sorted())"); continue }
            XCTAssertEqual(contrast(pane.base, Theme.bg), 1.0, accuracy: 0.05, "\(window): the pane draws Theme.bg, not \(name(pane.base))")
            XCTAssertEqual(contrast(plainRow.base, Theme.bg), 1.0, accuracy: 0.05, "\(window): an ordinary row sits on Theme.bg, not \(name(plainRow.base))")
            XCTAssertGreaterThanOrEqual(contrast(needs.base, Theme.bg), 1.1, "\(window): the needs-you row is visibly filled (\(name(needs.base)))")
            XCTAssertGreaterThanOrEqual(contrast(banner.base, Theme.bg), 1.15, "\(window): the banner is visibly filled (\(name(banner.base)))")
            XCTAssertGreaterThanOrEqual(contrast(prod.base, Theme.bg), 1.05, "\(window): the PROD badge has a fill (\(name(prod.base)))")
        }
    }

    func testThePaneLooksTheSameWhetherOrNotItsWindowIsKey() {
        let key = results(keyWindow: true).measured
        let notKey = results(keyWindow: false).measured
        XCTAssertFalse(key.isEmpty)
        for (id, k) in key {
            guard let n = notKey[id] else { XCTFail("\(id) was not measured in the non-key window"); continue }
            XCTAssertEqual(k.ratio, n.ratio, accuracy: 0.1, "\(id): the pane does not dim in an inactive window")
        }
    }

    // MARK: Record the numbers

    func testRecordTheMeasuredRatios() {
        let key = results(keyWindow: true).measured
        let notKey = results(keyWindow: false).measured
        XCTAssertFalse(key.isEmpty, "something was measured")
        var lines: [String] = []
        for id in key.keys.sorted() where id != "pane-background" {
            let k = key[id].map { String(format: "%.2f", $0.ratio) } ?? "n/a"
            let n = notKey[id].map { String(format: "%.2f", $0.ratio) } ?? "n/a"
            lines.append("\(id) key=\(k) nonkey=\(n)")
        }
        print(lines.map { "TRACKER-CONTRAST \($0)" }.joined(separator: "\n"))
        // `make mac-test` keeps only lines with "error:", "failed" or a test count, so a print never
        // reaches the CI log. An expected failure does (the scroll-gate self-tests use the same
        // route) and the run stays green: it is how the measured ratios get into the PR.
        XCTExpectFailure("records the measured contrast ratios in the CI log; not a defect") {
            XCTFail("TRACKER-CONTRAST " + lines.joined(separator: " | "))
        }
    }

    // MARK: Explicit colours

    func testEveryColourThePaneDrawsWithIsExplicit() {
        let colors: [NSColor] = [TrackerTheme.background, TrackerTheme.text, TrackerTheme.muted, TrackerTheme.needsYouFill,
                                 TrackerTheme.hazard, TrackerTheme.hazardFill, TrackerTheme.badgeFill, TrackerTheme.bannerFill,
                                 TrackerTheme.stripFill, TrackerTheme.changeHighlight,
                                 TrackerTheme.markColor(.todo), TrackerTheme.markColor(.inProgress), TrackerTheme.markColor(.blocked),
                                 TrackerTheme.markColor(.needsYou), TrackerTheme.markColor(.done)]
        for color in colors {
            XCTAssertEqual(color.type, .componentBased,
                           "\(color) is a catalogue or pattern colour: it would change with the system appearance")
        }
    }
}
