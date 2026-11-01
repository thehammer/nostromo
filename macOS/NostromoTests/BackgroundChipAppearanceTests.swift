import XCTest
import AppKit
import NostromoKit

// BA3 Phase 7 (PRD "Accessibility and appearance", design contract 2.9): the chip and the popover are
// legible on the always-dark UI, in the key window and in an inactive one.
//
// The app is pinned to Dark Aqua (#234): a system-drawn label resolves dark-on-dark here, so every colour
// in this feature is explicit. These tests render the REAL views (a `BackgroundChip` on the input bar's
// background; `BackgroundTaskRowView`, `BackgroundSectionHeaderView` and the popover's header on the
// popover's background) into a bitmap and measure the pixels, the way `ModelChipAppearanceTests` does:
// the brightest pixel of the text against the median pixel of the surface it sits on, at least 4.5:1.
//
// Every measured ratio is printed as `BA3 contrast <what>: <ratio>:1` and recorded as an XCTest activity of
// the same name, so the numbers can be copied into the PR. Each is also asserted. A second set of tests
// checks the exact colour pairs by arithmetic (no rasterising), and that the colours are explicit values,
// not dynamic system colours.
//
// Helpers are file-private copies with a `bga` prefix.

// MARK: - Helpers

private func bgaChannel(_ v: CGFloat) -> Double {
    let c = Double(v)
    return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

/// WCAG relative luminance of an sRGB colour.
private func bgaLuminance(_ color: NSColor) -> Double {
    guard let c = color.usingColorSpace(.sRGB) else { return 0 }
    return 0.2126 * bgaChannel(c.redComponent) + 0.7152 * bgaChannel(c.greenComponent) + 0.0722 * bgaChannel(c.blueComponent)
}

private func bgaRatio(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// The fill a region sits on (its median luminance) and its brightest pixel.
private struct BGARegion {
    var fill: Double
    var brightest: Double
    var ratio: Double { bgaRatio(brightest, fill) }
}

/// Render `host` into a bitmap and measure `region` and `textArea` (both in `host` coordinates).
private func bgaMeasure(_ host: NSView, region: NSRect, textArea: NSRect) -> BGARegion {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return BGARegion(fill: 0, brightest: 0) }
    host.cacheDisplay(in: host.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / host.bounds.width
    // Clamped to the bitmap: `colorAt` raises for a pixel outside it.
    func clamp(_ lower: Int, _ upper: Int, limit: Int) -> Range<Int> {
        let low = min(max(lower, 0), limit), high = min(max(upper, low), limit)
        return low..<high
    }
    func rows(_ r: NSRect) -> Range<Int> {
        clamp(Int((host.bounds.height - r.maxY) * scale), Int((host.bounds.height - r.minY) * scale), limit: rep.pixelsHigh)
    }
    func columns(_ r: NSRect) -> Range<Int> {
        clamp(Int(r.minX * scale), Int(r.maxX * scale), limit: rep.pixelsWide)
    }
    var fills: [Double] = []
    for x in columns(region) {
        for y in rows(region) {
            if let c = rep.colorAt(x: x, y: y) { fills.append(bgaLuminance(c)) }
        }
    }
    var brightest = 0.0
    for x in columns(textArea) {
        for y in rows(textArea) {
            if let c = rep.colorAt(x: x, y: y) { brightest = max(brightest, bgaLuminance(c)) }
        }
    }
    let sorted = fills.sorted()
    return BGARegion(fill: sorted.isEmpty ? 0 : sorted[sorted.count / 2], brightest: brightest)
}

/// A window whose key state a test dictates (a test process is never the active app).
private final class BGAWindow: NSWindow {
    var reportsKey = false
    override var isKeyWindow: Bool { reportsKey }
    override var isMainWindow: Bool { reportsKey }
}

/// Every text field below `view`, however deep.
private func bgaAllTextFields(in view: NSView) -> [NSTextField] {
    var out: [NSTextField] = []
    for sub in view.subviews {
        if let field = sub as? NSTextField { out.append(field) }
        out += bgaAllTextFields(in: sub)
    }
    return out
}

/// `color` composited over `background`, both resolved to sRGB.
private func bgaOver(_ color: NSColor, _ background: NSColor) -> NSColor {
    let top = color.usingColorSpace(.sRGB) ?? color
    let bottom = background.usingColorSpace(.sRGB) ?? background
    let a = top.alphaComponent
    return NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                   green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                   blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
}

// MARK: - Tests

final class BackgroundChipAppearanceTests: XCTestCase {

    private var previousAppearance: NSAppearance?
    private var windows: [NSWindow] = []
    private var world: BA3UIWorld!
    private let nowMs: UInt64 = 1_800_000_000_000

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
        windows = []
        world = BA3UIWorld(self)
    }

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        NSApplication.shared.appearance = previousAppearance
        world = nil
        super.tearDown()
    }

    /// Print and record a measured ratio (copied into the PR).
    private func record(_ what: String, _ ratio: Double) {
        let text = String(format: "%.2f", ratio)
        print("BA3 contrast \(what): \(text):1")
        XCTContext.runActivity(named: "BA3 contrast \(what): \(text):1") { _ in }
    }

    private func makeWindow(key: Bool, size: NSSize) -> BGAWindow {
        let window = BGAWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 300), size: size),
                               styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.reportsKey = key
        windows.append(window)
        return window
    }

    /// A host view filled with `fill`, in a window that reports itself key (or not), ordered in.
    private func makeHost(fill: CGColor, size: NSSize, key: Bool) -> NSView {
        let window = makeWindow(key: key, size: size)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = fill
        window.contentView = host
        window.orderFront(nil)
        XCTAssertEqual(window.isKeyWindow, key, "precondition: the host window is \(key ? "key" : "inactive")")
        return host
    }

    /// The input bar's background, resolved the way the dark UI draws it.
    private func barBackground() -> CGColor {
        var cg = Theme.bgBar.cgColor
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { cg = Theme.bgBar.cgColor }
        return cg
    }

    private func popoverBackground() -> CGColor {
        var cg = BackgroundPalette.background.cgColor
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { cg = BackgroundPalette.background.cgColor }
        return cg
    }

    // MARK: The chip

    private static let chipFrame = NSRect(x: 12, y: 14, width: BackgroundChip.slotWidth, height: BackgroundChip.height)

    private func renderChip(_ state: BackgroundChipState, key: Bool) -> BGARegion {
        let host = makeHost(fill: barBackground(), size: NSSize(width: 300, height: 60), key: key)
        let chip = BackgroundChip()
        chip.frame = Self.chipFrame
        host.addSubview(chip)
        chip.apply(state, tooltip: nil)
        return bgaMeasure(host, region: Self.chipFrame, textArea: Self.chipFrame.insetBy(dx: 6, dy: 3))
    }

    func testTheRunningAndDoneChipTextMeetsContrastInTheKeyWindowAndAnInactiveOne() {
        for (name, state) in [("running", BackgroundChipState.running(2)), ("done", .done(3))] {
            for key in [true, false] {
                let m = renderChip(state, key: key)
                record("chip \(name) text (\(key ? "key" : "inactive") window)", m.ratio)
                XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "chip \(name), \(key ? "key" : "inactive") window: text \(m.brightest), fill \(m.fill)")
                XCTAssertGreaterThan(m.brightest, m.fill + 0.1, "light text on the dark pill, not the other way round")
            }
        }
    }

    func testTheFailedChipTextMeetsContrastInTheKeyWindowAndAnInactiveOne() {
        for key in [true, false] {
            let m = renderChip(.failed(1), key: key)
            record("chip failed text (\(key ? "key" : "inactive") window)", m.ratio)
            XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "failed chip, \(key ? "key" : "inactive") window: text \(m.brightest), fill \(m.fill)")
        }
    }

    func testTheChipIsDrawnTheSameWhateverTheAppAppearanceIs() {
        for state in [BackgroundChipState.running(2), .failed(1)] {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            let inAqua = renderChip(state, key: true)
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            let inDark = renderChip(state, key: true)

            XCTAssertGreaterThanOrEqual(inAqua.ratio, 4.5, "\(state) under Aqua: the title is drawn, not system-coloured")
            XCTAssertEqual(inAqua.brightest, inDark.brightest, accuracy: 0.02, "\(state): the same pixels in both appearances")
        }
    }

    // MARK: Rows

    private func list(_ tasks: [TaskMetaWire], details: [String: SessionTaskDetailWire] = [:]) -> BackgroundTaskList {
        BackgroundTaskList.make(tasks: tasks, details: details, nowMs: nowMs)
    }

    /// A running agent with a sign of life, a running shell with a `last:` line, a completed shell, a failed
    /// agent, and a housekeeping task.
    private func fixtureList() -> BackgroundTaskList {
        let w = world!
        let tasks = [
            w.task("agent", kind: .agent, "Write failing tests for the chip", startedAgo: 125,
                   subagentType: "redd", tokens: 18_200, toolUses: 11, lastTool: "Edit"),
            w.task("child", "cargo test -p nostromo", startedAgo: 40, parent: "agent"),
            w.task("built", "npm run build", status: .completed, startedAgo: 312, endedAgo: 240, durationMs: 72_000),
            w.task("explore", kind: .agent, "Find callers of the old API", status: .failed, startedAgo: 578,
                   endedAgo: 540, durationMs: 38_000, subagentType: "explore"),
            w.task("chore", "ambient watcher", startedAgo: 900, housekeeping: true),
        ]
        return list(tasks, details: ["child": SessionTaskDetailWire(tag: "gate", taskId: "child", preview: "build: 3/7 jobs passed")])
    }

    private struct RenderedRow {
        let host: NSView
        let view: BackgroundTaskRowView
        let fields: [NSTextField]
    }

    private func renderRow(_ row: BackgroundTaskRow, key: Bool) -> RenderedRow {
        let height = BackgroundTaskRowView.height(for: row)
        let host = makeHost(fill: popoverBackground(), size: NSSize(width: 460, height: height + 8), key: key)
        let view = BackgroundTaskRowView(row: row)
        view.frame = NSRect(x: 4, y: 4, width: 452, height: height)
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        return RenderedRow(host: host, view: view, fields: bgaAllTextFields(in: view))
    }

    /// The contrast of one of the row's fields (found by its text) on the popover background.
    private func contrast(of text: String, in rendered: RenderedRow, file: StaticString = #filePath, line: UInt = #line) -> BGARegion? {
        guard let field = rendered.fields.first(where: { $0.stringValue == text && !$0.isHidden }) else {
            XCTFail("the row has no visible field reading `\(text)`: \(rendered.fields.map(\.stringValue))", file: file, line: line)
            return nil
        }
        let rect = field.convert(field.bounds, to: rendered.host)
        XCTAssertGreaterThan(rect.width, 2, "`\(text)` was laid out", file: file, line: line)
        XCTAssertGreaterThan(rect.height, 2, "`\(text)` was laid out", file: file, line: line)
        return bgaMeasure(rendered.host, region: rect, textArea: rect.insetBy(dx: 0, dy: 1))
    }

    private func assertContrast(_ what: String, text: String, in rendered: RenderedRow, key: Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let m = contrast(of: text, in: rendered, file: file, line: line) else { return }
        record("\(what) (\(key ? "key" : "inactive") window)", m.ratio)
        XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(what), \(key ? "key" : "inactive") window: text \(m.brightest), fill \(m.fill)", file: file, line: line)
    }

    func testRowTextMeetsContrastInTheKeyWindowAndAnInactiveOne() {
        let fixture = fixtureList()
        let running = fixture.running[0]
        XCTAssertEqual(running.id, "agent", "precondition")
        for key in [true, false] {
            let rendered = renderRow(running, key: key)
            assertContrast("popover row kind", text: rendered.view.kindText, in: rendered, key: key)
            assertContrast("popover row title", text: rendered.view.titleText, in: rendered, key: key)
            assertContrast("popover row status", text: rendered.view.statusText, in: rendered, key: key)
            assertContrast("popover row elapsed", text: rendered.view.timeText, in: rendered, key: key)
        }
    }

    func testTheMutedSignOfLifeAndEndedAgoMeetContrastInTheKeyWindowAndAnInactiveOne() {
        let fixture = fixtureList()
        let agent = fixture.running[0]
        let completed = fixture.ended[0]
        XCTAssertEqual(completed.id, "built", "precondition")
        for key in [true, false] {
            let withSign = renderRow(agent, key: key)
            XCTAssertFalse(withSign.view.signOfLifeText.isEmpty, "precondition: the agent row has a sign of life")
            assertContrast("muted sign of life", text: withSign.view.signOfLifeText, in: withSign, key: key)

            let ended = renderRow(completed, key: key)
            XCTAssertFalse(ended.view.endedAgoText.isEmpty, "precondition: an ended row says how long ago")
            assertContrast("muted ended-ago", text: ended.view.endedAgoText, in: ended, key: key)
        }
    }

    func testTheFailedStatusMeetsContrastInTheKeyWindowAndAnInactiveOne() {
        let failed = fixtureList().ended[1]
        XCTAssertEqual(failed.id, "explore", "precondition")
        XCTAssertTrue(failed.isFailed)
        for key in [true, false] {
            let rendered = renderRow(failed, key: key)
            assertContrast("failed status", text: rendered.view.statusText, in: rendered, key: key)
            XCTAssertEqual(rendered.view.statusText, "failed")
        }
    }

    /// BA5: `Couldn't stop: <reason>` is drawn in the failure colour on the popover background.
    func testTheCouldntStopNoticeMeetsContrastInTheKeyWindowAndAnInactiveOne() throws {
        let running = fixtureList().running[0]
        XCTAssertFalse(running.isEnded, "precondition: a running row")
        let display = BackgroundTaskStore.StopDisplay(offered: true, failure: "Task is protected")
        for key in [true, false] {
            let rendered = renderRow(running, key: key)
            rendered.view.applyStop(display)
            rendered.host.layoutSubtreeIfNeeded()
            XCTAssertEqual(rendered.view.stopNoticeText, "Couldn't stop: Task is protected", "precondition: the notice shows")
            assertContrast("couldn't-stop notice", text: rendered.view.stopNoticeText, in: rendered, key: key)
            XCTAssertEqual(rendered.view.stopNoticeColor, BackgroundPalette.failed, "drawn in the failure colour")
        }
    }

    func testTheCouldntStopColourMeetsContrastOnThePopoverBackgroundByArithmetic() {
        let background = bgaOver(NSColor(cgColor: popoverBackground()) ?? .black, .black)
        let ratio = bgaRatio(bgaLuminance(BackgroundPalette.failed), bgaLuminance(background))
        record("couldn't-stop colour pair", ratio)
        XCTAssertGreaterThanOrEqual(ratio, 4.5)
    }

    func testHousekeepingRowsAreDimmedByColourAndStillMeetContrast() throws {
        let chore = try XCTUnwrap(fixtureList().housekeeping.first)
        XCTAssertTrue(chore.isHousekeeping)
        for key in [true, false] {
            let rendered = renderRow(chore, key: key)
            XCTAssertEqual(rendered.view.titleColor, BackgroundPalette.muted, "dimmed by colour, not by alpha")
            assertContrast("housekeeping row kind", text: rendered.view.kindText, in: rendered, key: key)
            assertContrast("housekeeping row title", text: rendered.view.titleText, in: rendered, key: key)
            assertContrast("housekeeping row status", text: rendered.view.statusText, in: rendered, key: key)
        }
    }

    func testRowTextIsDrawnTheSameUnderAquaAsUnderDarkAqua() {
        let running = fixtureList().running[0]
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        let inAqua = renderRow(running, key: true)
        let aqua = contrast(of: inAqua.view.titleText, in: inAqua)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let inDark = renderRow(running, key: true)
        let dark = contrast(of: inDark.view.titleText, in: inDark)

        XCTAssertGreaterThanOrEqual(aqua?.ratio ?? 0, 4.5, "an explicit colour does not follow the system appearance")
        XCTAssertEqual(aqua?.brightest ?? -1, dark?.brightest ?? -2, accuracy: 0.02)
    }

    // MARK: Headers

    private func renderHeader(_ text: String, disclosure: Bool, key: Bool) -> (host: NSView, header: BackgroundSectionHeaderView) {
        let host = makeHost(fill: popoverBackground(), size: NSSize(width: 460, height: BackgroundSectionHeaderView.height + 8), key: key)
        let header = BackgroundSectionHeaderView(text: text, isDisclosure: disclosure)
        header.frame = NSRect(x: 4, y: 4, width: 452, height: BackgroundSectionHeaderView.height)
        host.addSubview(header)
        host.layoutSubtreeIfNeeded()
        return (host, header)
    }

    func testSectionHeadersMeetContrastInTheKeyWindowAndAnInactiveOne() throws {
        for key in [true, false] {
            for (name, text, disclosure) in [("Ended header", "Ended", false),
                                             ("Housekeeping header", "\u{25B8} Housekeeping (1)", true)] {
                let (host, header) = renderHeader(text, disclosure: disclosure, key: key)
                let field = try XCTUnwrap(bgaAllTextFields(in: header).first { $0.stringValue == text })
                let rect = field.convert(field.bounds, to: host)
                XCTAssertGreaterThan(rect.width, 2, "the header was laid out")
                let m = bgaMeasure(host, region: rect, textArea: rect.insetBy(dx: 0, dy: 1))
                record("\(name) (\(key ? "key" : "inactive") window)", m.ratio)
                XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(name), \(key ? "key" : "inactive") window")
                XCTAssertEqual(header.textColor, BackgroundPalette.muted)
            }
        }
    }

    func testThePopoversOwnHeaderAndCountMeetContrastInTheKeyWindowAndAnInactiveOne() throws {
        world.ingest(world.fixture(), advance: 0)
        for key in [true, false] {
            let vc = BackgroundPopoverViewController(tag: "gate", displayName: "Claudia", store: world.store,
                                                     actions: NoBackgroundTaskActions.shared, announce: { _ in })
            _ = vc.view
            let size = vc.preferredContentSize
            let host = makeHost(fill: popoverBackground(), size: size, key: key)
            vc.view.frame = NSRect(origin: .zero, size: size)
            host.addSubview(vc.view)
            host.layoutSubtreeIfNeeded()

            for (name, field) in [("popover header title", vc.headerTitle), ("popover header count", vc.headerCount)] {
                let rect = field.convert(field.bounds, to: host)
                XCTAssertGreaterThan(rect.width, 2, "\(name) was laid out")
                let m = bgaMeasure(host, region: rect, textArea: rect.insetBy(dx: 0, dy: 1))
                record("\(name) (\(key ? "key" : "inactive") window)", m.ratio)
                XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(name), \(key ? "key" : "inactive") window: \(field.stringValue)")
            }
        }
    }

    // MARK: Colour pairs by arithmetic

    func testEveryColourPairReachesFourPointFiveToOneByArithmetic() {
        let bar = Theme.bgBar
        let pill = bgaOver(ModelChip.fillColor, bar)
        let popover = BackgroundPalette.background
        let pairs: [(String, NSColor, NSColor)] = [
            ("chip running/done text on pill", BackgroundChip.textColor, pill),
            ("chip failed text on pill", BackgroundChip.failedTextColor, pill),
            ("popover text", BackgroundPalette.text, popover),
            ("popover muted", BackgroundPalette.muted, popover),
            ("popover failed", BackgroundPalette.failed, popover),
        ]
        for (name, foreground, background) in pairs {
            let ratio = bgaRatio(bgaLuminance(foreground), bgaLuminance(background))
            record("\(name) (colour arithmetic)", ratio)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, name)
        }
    }

    // MARK: Explicit colours

    func testTheColoursAreExplicitValuesNotDynamicSystemColours() {
        let colours: [(String, NSColor)] = [
            ("BackgroundChip.textColor", BackgroundChip.textColor),
            ("BackgroundChip.failedTextColor", BackgroundChip.failedTextColor),
            ("BackgroundChip.fillColor", BackgroundChip.fillColor),
            ("BackgroundPalette.background", BackgroundPalette.background),
            ("BackgroundPalette.text", BackgroundPalette.text),
            ("BackgroundPalette.muted", BackgroundPalette.muted),
            ("BackgroundPalette.failed", BackgroundPalette.failed),
            ("BackgroundPalette.selectionRing", BackgroundPalette.selectionRing),
            ("BackgroundPalette.separator", BackgroundPalette.separator),
        ]
        for (name, colour) in colours {
            XCTAssertNotEqual(colour.type, .catalog, "\(name) must not be a catalog (dynamic system) colour")
            XCTAssertNotNil(colour.usingColorSpace(.sRGB), "\(name) resolves to a fixed sRGB value")
        }
    }

    func testRowsDrawWithThePaletteColours() throws {
        let fixture = fixtureList()
        let agent = BackgroundTaskRowView(row: fixture.running[0])
        XCTAssertEqual(agent.titleColor, BackgroundPalette.text)
        XCTAssertEqual(agent.statusColor, BackgroundPalette.text)
        XCTAssertEqual(agent.signOfLifeColor, BackgroundPalette.muted)

        let completed = BackgroundTaskRowView(row: fixture.ended[0])
        XCTAssertEqual(completed.endedAgoColor, BackgroundPalette.muted)
        XCTAssertEqual(completed.statusColor, BackgroundPalette.text)

        let failed = BackgroundTaskRowView(row: fixture.ended[1])
        XCTAssertEqual(failed.statusColor, BackgroundPalette.failed)
        XCTAssertEqual(BackgroundPalette.failed, Theme.foldFailure, "the transcript's failure colour")

        let chore = BackgroundTaskRowView(row: try XCTUnwrap(fixture.housekeeping.first))
        XCTAssertEqual(chore.titleColor, BackgroundPalette.muted)
    }

    func testTheChipsColoursAreTheDocumentedOnes() {
        XCTAssertEqual(BackgroundChip.failedTextColor, Theme.foldFailure)
        XCTAssertEqual(BackgroundChip.fillColor, ModelChip.fillColor, "the chip matches its sibling, the model chip")
    }
}
