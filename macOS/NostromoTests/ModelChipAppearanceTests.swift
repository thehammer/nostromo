import XCTest
import AppKit
import NostromoKit

// ModelChip, ModelShortcut, ModelPresentation, ModelStore, ReplInputBar, Theme and AppAppearance
// are compiled into this test target directly (logic test, no host app).
//
// The app is pinned to Dark Aqua (#234): a system-drawn label resolves dark-on-dark on this
// always-dark UI. So the chip draws its own title with explicit colours, and these tests prove it
// the way AppAppearanceTests does: the REAL control is rendered into a bitmap and the pixels are
// measured. The PRD asks for >= 4.5:1 for text in the key window AND in an inactive one.

// MARK: - Shared helpers

// Turn-bounded main-loop helpers shared by every Model* test file. Nothing here reads the clock to
// decide pass or fail: the main run loop is spun a bounded NUMBER of turns, so a test passes or
// fails on the state it reaches, not on how long the machine took (same idea as `flushMain` in
// TeriPicksTabTests).

/// Run everything already queued on the main queue, and whatever that queues in turn (a few
/// generations). Use it before asserting that something did NOT happen.
func modelFlushMain(generations: Int = 3) {
    for _ in 0..<generations {
        var ran = false
        DispatchQueue.main.async { ran = true }
        while !ran { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    }
}

/// Spin the main run loop until `condition` holds (true), giving up after `maxTurns` turns
/// (false, and a test failure unless `failing` is false). The bound counts turns, not seconds.
@discardableResult
func modelWaitUntil(maxTurns: Int = 500, failing: Bool = true, file: StaticString = #filePath, line: UInt = #line,
                    _ condition: () -> Bool) -> Bool {
    for _ in 0..<maxTurns {
        if condition() { return true }
        modelFlushMain(generations: 1)
    }
    if condition() { return true }
    if failing { XCTFail("condition not met within \(maxTurns) run-loop turns", file: file, line: line) }
    return false
}

private func modelTestChannel(_ v: CGFloat) -> Double {
    let c = Double(v)
    return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

/// WCAG relative luminance of an sRGB colour.
func modelRelativeLuminance(_ color: NSColor) -> Double {
    guard let c = color.usingColorSpace(.sRGB) else { return 0 }
    return 0.2126 * modelTestChannel(c.redComponent) + 0.7152 * modelTestChannel(c.greenComponent) + 0.0722 * modelTestChannel(c.blueComponent)
}

func modelContrastRatio(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// What a region of a rendered view looks like: the fill it sits on and its brightest pixel.
struct RegionLuminance {
    /// Median relative luminance of the whole region (the fill the text sits on).
    var fill: Double
    /// Relative luminance of the brightest pixel in the (inset) text area.
    var brightestText: Double
}

/// Render `host` into a bitmap and measure `region` (in `host` coordinates): the median luminance
/// of all of it, and the brightest pixel inside `textArea`.
func measureRegion(of host: NSView, region: NSRect, textArea: NSRect) -> RegionLuminance {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        return RegionLuminance(fill: 0, brightestText: 0)
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / host.bounds.width
    func rows(_ r: NSRect) -> Range<Int> { Int((host.bounds.height - r.maxY) * scale)..<Int((host.bounds.height - r.minY) * scale) }
    func columns(_ r: NSRect) -> Range<Int> { Int(r.minX * scale)..<Int(r.maxX * scale) }
    var fills: [Double] = []
    for x in columns(region) {
        for y in rows(region) {
            if let c = rep.colorAt(x: x, y: y) { fills.append(modelRelativeLuminance(c)) }
        }
    }
    var brightest = 0.0
    for x in columns(textArea) {
        for y in rows(textArea) {
            if let c = rep.colorAt(x: x, y: y) { brightest = max(brightest, modelRelativeLuminance(c)) }
        }
    }
    let sorted = fills.sorted()
    return RegionLuminance(fill: sorted.isEmpty ? 0 : sorted[sorted.count / 2], brightestText: brightest)
}

/// A window whose key state a test dictates. A test process is not the active application, so a
/// real window can never become key here; the same trick `ProseSelectionTests` uses.
final class StateWindow: NSWindow {
    var reportsKey = false
    override var isKeyWindow: Bool { reportsKey }
    override var isMainWindow: Bool { reportsKey }
}

/// Windows made by a test; ordered out in tearDown.
///
/// Every window gets `animationBehavior = .none`. Ordering a window in or out otherwise runs a
/// blocking `NSAnimation` on a GCD worker thread, and in a test process (no display, no running
/// app) that run loop never finishes: each window leaked one worker for good, 64 of them
/// exhausted the pool, and every later test that needs a background queue (the fake brokers, the
/// process runner) timed out.
final class WindowBag {
    private(set) var windows: [NSWindow] = []

    /// A window that reports `key` as its key state.
    func makeStateWindow(key: Bool, width: CGFloat = 300, height: CGFloat = 60, x: CGFloat = 100, y: CGFloat = 300) -> StateWindow {
        let w = StateWindow(contentRect: NSRect(x: x, y: y, width: width, height: height),
                            styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        w.reportsKey = key
        windows.append(w)
        return w
    }

    func make(width: CGFloat = 600, height: CGFloat = 60, x: CGFloat = 100, y: CGFloat = 300) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: x, y: y, width: width, height: height),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none
        windows.append(w)
        return w
    }

    func tearDown() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }
}

/// The chip presentation the appearance tests apply.
private func presentation(style: ModelPresentation.ChipStyle, enabled: Bool = true,
                          title: String = "Opus \u{00B7} high") -> ModelPresentation.Chip {
    ModelPresentation.Chip(title: title,
                           tooltip: "Claude Opus (claude-opus-5-5), effort: high",
                           accessibilityLabel: "Model: Opus, effort high. Change model",
                           accessibilityHint: "\u{21E7}\u{2318}M",
                           style: style, isEnabled: enabled)
}

// MARK: - The chip itself

final class ModelChipAppearanceTests: XCTestCase {
    private var previousAppearance: NSAppearance?
    private let windows = WindowBag()

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
    }

    override func tearDown() {
        windows.tearDown()
        NSApplication.shared.appearance = previousAppearance
        super.tearDown()
    }

    private static let chipFrame = NSRect(x: 12, y: 14, width: 150, height: 26)

    /// The input bar's background, resolved the way the dark UI draws it.
    private func barBackground() -> CGColor {
        var cg = Theme.bgBar.cgColor
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { cg = Theme.bgBar.cgColor }
        return cg
    }

    /// Lay `chip` on the bar background in a window that reports itself key (or inactive), the chip
    /// holding keyboard focus or not.
    private func makeHost(_ chipPresentation: ModelPresentation.Chip, keyWindow: Bool,
                          focused: Bool = false) -> (host: NSView, chip: ModelChip) {
        let window = windows.makeStateWindow(key: keyWindow)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        host.wantsLayer = true
        host.layer?.backgroundColor = barBackground()
        window.contentView = host
        let chip = ModelChip()
        chip.frame = Self.chipFrame
        host.addSubview(chip)
        chip.apply(chipPresentation)
        if focused { _ = chip.becomeFirstResponder() }
        window.orderFront(nil)
        XCTAssertEqual(window.isKeyWindow, keyWindow, "precondition: the host window is \(keyWindow ? "key" : "inactive")")
        return (host, chip)
    }

    /// Draw `chip` on the bar background in a window that reports itself key (or inactive) and
    /// measure it.
    private func render(_ chipPresentation: ModelPresentation.Chip, keyWindow: Bool, focused: Bool = false) -> RegionLuminance {
        let (host, _) = makeHost(chipPresentation, keyWindow: keyWindow, focused: focused)
        return measureRegion(of: host, region: Self.chipFrame, textArea: Self.chipFrame.insetBy(dx: 6, dy: 4))
    }

    /// The best contrast (against `background`, a relative luminance) among the pixels of each side's
    /// outer `band` points of the chip, taken along the middle of the side. A focus ring is on every side.
    private func edgeContrast(host: NSView, background: Double, band: CGFloat = 3) -> [String: Double] {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return [:] }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let chip = Self.chipFrame
        func best(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> Double {
            var result = 0.0
            var px = Int(x.lowerBound * scale)
            while px <= Int(x.upperBound * scale) {
                var py = Int((host.bounds.height - y.upperBound) * scale)
                while py <= Int((host.bounds.height - y.lowerBound) * scale) {
                    if let c = rep.colorAt(x: px, y: py) {
                        result = max(result, modelContrastRatio(modelRelativeLuminance(c), background))
                    }
                    py += 1
                }
                px += 1
            }
            return result
        }
        let midX = chip.midX, midY = chip.midY
        return [
            "left": best(x: chip.minX...(chip.minX + band), y: (midY - 2)...(midY + 2)),
            "right": best(x: (chip.maxX - band - 0.5)...(chip.maxX - 0.5), y: (midY - 2)...(midY + 2)),
            "top": best(x: (midX - 2)...(midX + 2), y: (chip.maxY - band - 0.5)...(chip.maxY - 0.5)),
            "bottom": best(x: (midX - 2)...(midX + 2), y: chip.minY...(chip.minY + band)),
        ]
    }

    private func descriptor(_ style: ModelPresentation.ChipStyle, _ enabled: Bool, _ key: Bool) -> String {
        "style \(style), \(enabled ? "enabled" : "disabled"), \(key ? "key" : "inactive") window"
    }

    // MARK: Legibility

    func testTheTitleMeetsContrastInEveryStyleInTheKeyWindowAndAnInactiveOne() {
        let combos: [(ModelPresentation.ChipStyle, Bool)] = [(.normal, true), (.pending, true), (.normal, false), (.pending, false)]
        for (style, enabled) in combos {
            for key in [true, false] {
                let m = render(presentation(style: style, enabled: enabled), keyWindow: key)
                let ratio = modelContrastRatio(m.brightestText, m.fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5,
                    "\(descriptor(style, enabled, key)): the title must reach 4.5:1 against the chip's fill (text \(m.brightestText), fill \(m.fill), ratio \(ratio))")
            }
        }
    }

    func testTheTitleIsLighterThanTheFillItSitsOn() {
        // Contrast alone would also pass for dark text on a light fill; this UI is light on dark.
        for style in [ModelPresentation.ChipStyle.normal, .pending] {
            let m = render(presentation(style: style), keyWindow: true)
            XCTAssertGreaterThan(m.brightestText, m.fill + 0.2,
                                 "style \(style): the title must be clearly brighter than the fill (text \(m.brightestText), fill \(m.fill))")
        }
    }

    func testThePendingTitleIsDimmerThanTheNormalOne() {
        let normal = render(presentation(style: .normal), keyWindow: true)
        let pending = render(presentation(style: .pending), keyWindow: true)
        XCTAssertGreaterThan(normal.brightestText, pending.brightestText,
                             "a dimmed (pending) chip must read as dimmer than a fact")
    }

    func testTheTitleIsNotSystemDrawnSoTheAppAppearanceDoesNotChangeIt() {
        for style in [ModelPresentation.ChipStyle.normal, .pending] {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            let inAqua = render(presentation(style: style), keyWindow: true)
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            let inDark = render(presentation(style: style), keyWindow: true)

            XCTAssertGreaterThan(inAqua.brightestText, inAqua.fill + 0.2,
                                 "style \(style): even under Aqua the title is drawn, and light on the dark fill")
            XCTAssertGreaterThan(inDark.brightestText, inDark.fill + 0.2, "style \(style): the title is drawn under Dark Aqua")
            XCTAssertEqual(inAqua.brightestText, inDark.brightestText, accuracy: 0.02,
                           "style \(style): the same pixels whatever the app appearance is: no system-drawn title")
        }
    }

    // MARK: Keyboard focus

    func testAChipIsNotFocusedUntilItBecomesTheFirstResponder() {
        let chip = ModelChip()
        XCTAssertFalse(chip.hasKeyboardFocus)
        XCTAssertTrue(chip.becomeFirstResponder())
        XCTAssertTrue(chip.hasKeyboardFocus)
        XCTAssertTrue(chip.resignFirstResponder())
        XCTAssertFalse(chip.hasKeyboardFocus)
    }

    func testAFocusedChipDrawsAFocusRingOnEverySideThatAnUnfocusedOneLacks() {
        let background = modelRelativeLuminance(NSColor(cgColor: barBackground()) ?? .black)
        let plain = makeHost(presentation(style: .normal), keyWindow: true, focused: false).host
        let ringed = makeHost(presentation(style: .normal), keyWindow: true, focused: true).host

        let without = edgeContrast(host: plain, background: background)
        let with = edgeContrast(host: ringed, background: background)

        XCTAssertEqual(Set(with.keys), ["left", "right", "top", "bottom"])
        for (side, ratio) in with {
            XCTAssertGreaterThanOrEqual(ratio, 3.0,
                "the focus ring on the \(side) edge must reach 3:1 against the bar background (got \(ratio):1)")
        }
        for (side, ratio) in without {
            XCTAssertLessThan(ratio, 3.0, "an unfocused chip has no ring on the \(side) edge (got \(ratio):1)")
        }
    }

    func testTheFocusRingFollowsFocusOutAgain() {
        let background = modelRelativeLuminance(NSColor(cgColor: barBackground()) ?? .black)
        let (host, chip) = makeHost(presentation(style: .normal), keyWindow: true, focused: true)
        XCTAssertGreaterThanOrEqual(edgeContrast(host: host, background: background)["left"] ?? 0, 3.0, "precondition: ringed")
        _ = chip.resignFirstResponder()
        chip.displayIfNeeded()
        XCTAssertLessThan(edgeContrast(host: host, background: background)["left"] ?? 0, 3.0, "the ring goes when focus does")
    }

    func testTheTitleStaysLegibleWhileTheChipHasKeyboardFocus() {
        for style in [ModelPresentation.ChipStyle.normal, .pending] {
            for key in [true, false] {
                let m = render(presentation(style: style), keyWindow: key, focused: true)
                let ratio = modelContrastRatio(m.brightestText, m.fill)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "focused, style \(style), \(key ? "key" : "inactive") window: \(ratio):1")
                XCTAssertGreaterThan(m.brightestText, m.fill + 0.2)
            }
        }
    }

    // MARK: Constants and applied presentation

    func testTitleAlphasAreThePrdValues() {
        XCTAssertEqual(ModelChip.normalAlpha, 0.88, accuracy: 0.0001)
        XCTAssertEqual(ModelChip.pendingAlpha, 0.62, accuracy: 0.0001)
    }

    func testApplyingAPresentationSetsTitleAccessibilityAndTooltip() {
        let chip = ModelChip()
        let p = presentation(style: .normal)
        chip.apply(p)
        XCTAssertEqual(chip.title, p.title)
        XCTAssertEqual(chip.accessibilityLabel(), p.accessibilityLabel)
        XCTAssertEqual(chip.accessibilityHelp(), p.accessibilityHint)
        XCTAssertEqual(chip.toolTip, p.tooltip)
        XCTAssertTrue(chip.isEnabled)
    }

    func testApplyingANewPresentationReplacesTheOldOne() {
        let chip = ModelChip()
        chip.apply(presentation(style: .normal))
        let next = ModelPresentation.Chip(title: "Switching\u{2026}", tooltip: "Switching model",
                                          accessibilityLabel: "Model: switching from Opus to Sonnet",
                                          accessibilityHint: "\u{21E7}\u{2318}M", style: .pending, isEnabled: true)
        chip.apply(next)
        XCTAssertEqual(chip.title, "Switching\u{2026}")
        XCTAssertEqual(chip.toolTip, "Switching model")
        XCTAssertEqual(chip.accessibilityLabel(), "Model: switching from Opus to Sonnet")
    }

    func testTheChipIsEnabledOrNotAsThePresentationSays() {
        let chip = ModelChip()
        chip.apply(presentation(style: .pending, enabled: false))
        XCTAssertFalse(chip.isEnabled)
        chip.apply(presentation(style: .normal, enabled: true))
        XCTAssertTrue(chip.isEnabled)
    }
}

// MARK: - ⇧⌘M

final class ModelShortcutTests: XCTestCase {
    private let windows = WindowBag()
    private var recorders: [ModelRequestRecorder] = []

    override func tearDown() {
        windows.tearDown()
        recorders.removeAll()
        super.tearDown()
    }

    func testTheMenuItemIsModelEllipsisOnShiftCommandM() {
        let item = ModelShortcut.makeMenuItem()
        XCTAssertEqual(item.title, "Model\u{2026}")
        XCTAssertEqual(item.keyEquivalent, "m")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item.action, ModelShortcut.action)
        XCTAssertNil(item.target, "a nil target sends the action down the responder chain from the key window")
    }

    private func runningSonnet(_ tag: String) -> SessionModelStateWire {
        SessionModelStateWire(tag: tag, recorded: RecordedModelWire(model: "sonnet", source: .focus),
                              reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"), running: true)
    }

    private func settle() {
        modelFlushMain()
    }

    private func makeBar(tag: String, in window: NSWindow, store: ModelStore) -> ReplInputBar {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView = content
        let bar = ReplInputBar(frame: content.bounds)
        content.addSubview(bar)
        bar.bindModel(tag: tag, agentName: "claudia", store: store)
        return bar
    }

    private func makeStore(tag: String, withState: Bool = true, connected: Bool = true) -> ModelStore {
        let recorder = ModelRequestRecorder()
        recorders.append(recorder)
        let store = ModelStore(sender: recorder)
        store.connectionChanged(connected)
        store.ingest(.modelCatalog(families: [
            ModelFamilyWire(alias: "sonnet", displayName: "Sonnet", resolved: "claude-sonnet-5-5", efforts: ["low", "medium", "high"], rank: 2),
            ModelFamilyWire(alias: "opus", displayName: "Opus", resolved: "claude-opus-5-5", efforts: ["low", "medium", "high", "xhigh", "max"], rank: 3),
        ], stale: false, fetchedAt: nil))
        if withState { store.ingest(.sessionModelState(runningSonnet(tag))) }
        return store
    }

    /// Two windows, each holding a bar bound to its own tag and store; B is key with its text view focused.
    private func twoWindows() -> (a: ReplInputBar, b: ReplInputBar, windowB: NSWindow) {
        let windowA = windows.make(x: 100, y: 500)
        let windowB = windows.make(x: 100, y: 300)
        let barA = makeBar(tag: "tag-a", in: windowA, store: makeStore(tag: "tag-a"))
        let barB = makeBar(tag: "tag-b", in: windowB, store: makeStore(tag: "tag-b"))
        windowA.contentView?.layoutSubtreeIfNeeded()
        windowB.contentView?.layoutSubtreeIfNeeded()
        windowA.orderFront(nil)
        windowB.makeKeyAndOrderFront(nil)
        settle()
        return (barA, barB, windowB)
    }

    func testTheShortcutReachesTheKeyWindowsBarAndNoOtherWindowsBar() throws {
        let (barA, barB, windowB) = twoWindows()
        XCTAssertTrue(windowB.makeFirstResponder(barB.textView))
        let item = ModelShortcut.makeMenuItem()
        let action = try XCTUnwrap(item.action)

        let handled = try XCTUnwrap(windowB.firstResponder).tryToPerform(action, with: item)

        XCTAssertTrue(handled, "the action must be handled somewhere on the responder chain of B's text view")
        XCTAssertNotNil(barB.modelPopover, "the key window's bar opens its popup")
        XCTAssertTrue(barB.modelPopover?.isShown ?? false)
        XCTAssertNil(barA.modelPopover, "the other window's bar is untouched")
    }

    func testPressingTheShortcutAgainClosesThePopup() throws {
        let (_, barB, windowB) = twoWindows()
        XCTAssertTrue(windowB.makeFirstResponder(barB.textView))
        let item = ModelShortcut.makeMenuItem()
        let action = try XCTUnwrap(item.action)

        _ = windowB.firstResponder?.tryToPerform(action, with: item)
        XCTAssertTrue(barB.modelPopover?.isShown ?? false, "precondition: the first press opens it")

        _ = windowB.firstResponder?.tryToPerform(action, with: item)
        // NSPopover finishes closing on a later run-loop turn: isShown drops then.
        modelWaitUntil(failing: false) { !(barB.modelPopover?.isShown ?? false) }
        XCTAssertFalse(barB.modelPopover?.isShown ?? false, "the second press closes it")
    }

    // MARK: Which bar `ModelShortcut.bar(in:)` picks (the menu's fallback when no bar is above the first responder)

    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// One window, two panes side by side. Each pane holds an input bar and a transcript stand-in.
    private struct Panes {
        let window: NSWindow
        let barA: ReplInputBar
        let barB: ReplInputBar
        let transcriptA: NSView
        let transcriptB: NSView
        /// A view under the content view that sits in no pane (holds no bar).
        let strip: NSView
    }

    private func twoPanes(aHasState: Bool = true, bHasState: Bool = true) -> Panes {
        let window = windows.make(width: 600, height: 150, x: 100, y: 300)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 150))
        window.contentView = content
        func pane(_ x: CGFloat, tag: String, hasState: Bool) -> (ReplInputBar, NSView) {
            let container = NSView(frame: NSRect(x: x, y: 0, width: 300, height: 120))
            content.addSubview(container)
            let bar = ReplInputBar(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
            container.addSubview(bar)
            bar.bindModel(tag: tag, agentName: "claudia", store: makeStore(tag: tag, withState: hasState))
            let transcript = FocusableView(frame: NSRect(x: 0, y: 60, width: 300, height: 60))
            container.addSubview(transcript)
            return (bar, transcript)
        }
        let a = pane(0, tag: "tag-a", hasState: aHasState)
        let b = pane(300, tag: "tag-b", hasState: bHasState)
        let strip = FocusableView(frame: NSRect(x: 0, y: 120, width: 600, height: 30))
        content.addSubview(strip)
        content.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil)
        settle()
        return Panes(window: window, barA: a.0, barB: b.0, transcriptA: a.1, transcriptB: b.1, strip: strip)
    }

    func testTheBarContainingTheFirstResponderIsPicked() {
        let p = twoPanes()
        XCTAssertTrue(p.window.makeFirstResponder(p.barB.textView))
        XCTAssertTrue(ModelShortcut.bar(in: p.window) === p.barB)
        XCTAssertTrue(p.window.makeFirstResponder(p.barA.textView))
        XCTAssertTrue(ModelShortcut.bar(in: p.window) === p.barA, "not simply the last (or the first) bar: the one with the focus")
    }

    func testAFirstResponderInAPaneWithExactlyOneBarPicksThatPanesBar() {
        let p = twoPanes()
        XCTAssertTrue(p.window.makeFirstResponder(p.transcriptB))
        XCTAssertTrue(ModelShortcut.bar(in: p.window) === p.barB, "the transcript sits in pane B, so ⇧⌘M means pane B's model")
        XCTAssertTrue(p.window.makeFirstResponder(p.transcriptA))
        XCTAssertTrue(ModelShortcut.bar(in: p.window) === p.barA)
    }

    func testAFirstResponderInNoPaneFallsBackToTheFirstEligibleBar() {
        let p = twoPanes()
        XCTAssertTrue(p.window.makeFirstResponder(p.strip))
        XCTAssertTrue(ModelShortcut.bar(in: p.window) === p.barA, "the strip sits above both panes: it names neither")
        XCTAssertTrue(p.window.makeFirstResponder(nil))
        XCTAssertTrue(ModelShortcut.bar(in: p.window) === p.barA, "no first responder at all")
    }

    func testBarsWithoutAnOpenableChipAreSkipped() {
        let hiddenA = twoPanes(aHasState: false)
        XCTAssertTrue(hiddenA.barA.modelChip.isHidden, "precondition: pane A has no model state")
        XCTAssertTrue(hiddenA.window.makeFirstResponder(hiddenA.strip))
        XCTAssertTrue(ModelShortcut.bar(in: hiddenA.window) === hiddenA.barB, "the first ELIGIBLE bar")
        XCTAssertTrue(hiddenA.window.makeFirstResponder(hiddenA.barA.textView))
        XCTAssertTrue(ModelShortcut.bar(in: hiddenA.window) === hiddenA.barB, "a focused bar that cannot open a popup is not picked")
    }

    func testNoBarIsPickedWhenNoneCanOpenAPopup() {
        let none = twoPanes(aHasState: false, bHasState: false)
        XCTAssertTrue(none.window.makeFirstResponder(none.barB.textView))
        XCTAssertNil(ModelShortcut.bar(in: none.window))
        XCTAssertNil(ModelShortcut.bar(in: nil))
        XCTAssertNil(ModelShortcut.bar(in: windows.make()), "a window with no content has no bar")
    }

    func testBarsWhoseChipIsDisabledAreSkippedToo() {
        let p = twoPanes()
        // Disconnect pane A's store only: its chip is disabled, B's is not.
        let storeA = makeStore(tag: "tag-a")
        p.barA.bindModel(tag: "tag-a", agentName: "claudia", store: storeA)
        storeA.connectionChanged(false)
        settle()
        XCTAssertFalse(p.barA.modelChip.isEnabled, "precondition")
        XCTAssertTrue(p.window.makeFirstResponder(p.strip))
        XCTAssertTrue(ModelShortcut.bar(in: p.window) === p.barB)
    }

    func testTheBarOfAnotherWindowIsNeverPicked() {
        let one = twoPanes()
        let other = twoPanes()
        XCTAssertTrue(other.window.makeFirstResponder(other.barB.textView))
        let picked = ModelShortcut.bar(in: one.window)
        XCTAssertFalse(picked === other.barA || picked === other.barB)
        XCTAssertTrue(ModelShortcut.bar(in: other.window) === other.barB)
    }

    func testABarWhoseChipIsHiddenOpensNothing() throws {
        let window = windows.make()
        let bar = makeBar(tag: "tag-x", in: window, store: makeStore(tag: "tag-x", withState: false))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(bar.textView))
        settle()
        XCTAssertTrue(bar.modelChip.isHidden, "precondition: no state, no chip")
        let item = ModelShortcut.makeMenuItem()

        _ = window.firstResponder?.tryToPerform(try XCTUnwrap(item.action), with: item)

        XCTAssertNil(bar.modelPopover, "a session with no model state has no model popup")
    }

    func testABarWhoseChipIsDisabledOpensNothing() throws {
        let window = windows.make()
        let store = makeStore(tag: "tag-x")
        let bar = makeBar(tag: "tag-x", in: window, store: store)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(bar.textView))
        store.connectionChanged(false)
        settle()
        XCTAssertFalse(bar.modelChip.isEnabled, "precondition: not connected, chip disabled")
        let item = ModelShortcut.makeMenuItem()

        _ = window.firstResponder?.tryToPerform(try XCTUnwrap(item.action), with: item)

        XCTAssertNil(bar.modelPopover, "nothing can be switched while nostromd is unreachable")
    }
}

// MARK: - The chip in the real input bar

final class ModelChipInputBarTests: XCTestCase {
    private let windows = WindowBag()
    private var sender: ModelRequestRecorder!
    private var store: ModelStore!

    override func setUp() {
        super.setUp()
        AppAppearance.apply(to: NSApplication.shared)
        sender = ModelRequestRecorder()
        store = ModelStore(sender: sender)
        store.connectionChanged(true)
    }

    override func tearDown() {
        windows.tearDown()
        store = nil
        sender = nil
        super.tearDown()
    }

    private func makeBar(tag: String, store: ModelStore? = nil, x: CGFloat = 100, y: CGFloat = 300) -> (ReplInputBar, NSWindow) {
        let window = windows.make(x: x, y: y)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView = content
        let bar = ReplInputBar(frame: content.bounds)
        content.addSubview(bar)
        bar.bindModel(tag: tag, agentName: "claudia", store: store ?? self.store)
        window.orderFront(nil)
        content.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    private func state(_ tag: String, model: String = "sonnet", reported: String = "claude-sonnet-5-5",
                       family: String = "sonnet", effort: String? = nil, running: Bool = true) -> SessionModelStateWire {
        SessionModelStateWire(tag: tag, recorded: RecordedModelWire(model: model, effort: effort, source: .focus),
                              reported: ReportedModelWire(model: reported, family: family), running: running)
    }

    @discardableResult
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) -> Bool {
        modelWaitUntil(file: file, line: line, condition)
    }

    private func settle() {
        modelFlushMain()
    }

    // MARK: One bar

    func testTheChipIsHiddenWhenTheStoreHasNoStateForTheFocus() {
        let (bar, _) = makeBar(tag: "focus-a")
        settle()
        XCTAssertTrue(bar.modelChip.isHidden, "a session with no model state (restricted or hidden) shows no chip")
    }

    func testTheChipAppearsWithTheRightTitleOnceTheFrameArrives() {
        let (bar, _) = makeBar(tag: "focus-a")
        store.ingest(.sessionModelState(state("focus-a")))
        waitUntil { !bar.modelChip.isHidden }
        XCTAssertEqual(bar.modelChip.title, "Sonnet")
        XCTAssertTrue(bar.modelChip.isEnabled)
        XCTAssertTrue(bar.modelChip.isDescendant(of: bar), "the chip lives in the input bar")
        XCTAssertEqual(bar.modelChip.accessibilityLabel(), "Model: Sonnet, effort default. Change model")
        XCTAssertEqual(bar.modelChip.toolTip, "Claude Sonnet (claude-sonnet-5-5), effort: default")
    }

    func testABarBoundAfterTheStateArrivedShowsItAtOnce() {
        store.ingest(.sessionModelState(state("focus-a", model: "opus", reported: "claude-opus-5-5", family: "opus", effort: "high")))
        let (bar, _) = makeBar(tag: "focus-a")
        waitUntil { !bar.modelChip.isHidden }
        XCTAssertEqual(bar.modelChip.title, "Opus \u{00B7} high")
    }

    func testTheChipFollowsEachNewFrame() {
        let (bar, _) = makeBar(tag: "focus-a")
        store.ingest(.sessionModelState(state("focus-a")))
        waitUntil { bar.modelChip.title == "Sonnet" }

        store.ingest(.sessionModelState(state("focus-a", model: "opus", reported: "claude-opus-5-5", family: "opus")))
        waitUntil { bar.modelChip.title == "Opus" }

        let switching = SessionModelStateWire(tag: "focus-a", recorded: RecordedModelWire(model: "opus", source: .focus),
                                              reported: ReportedModelWire(model: "claude-opus-5-5", family: "opus"),
                                              pending: PendingModelWire(model: "sonnet"), phase: .waiting, running: true)
        store.ingest(.sessionModelState(switching))
        waitUntil { bar.modelChip.title == "Opus \u{2192} Sonnet" }
        XCTAssertEqual(bar.modelChip.toolTip, "Switching after this turn")
    }

    func testTheChipIsDisabledWithATooltipWhenTheDaemonIsUnreachable() {
        let (bar, _) = makeBar(tag: "focus-a")
        store.ingest(.sessionModelState(state("focus-a")))
        waitUntil { !bar.modelChip.isHidden && bar.modelChip.isEnabled }

        store.connectionChanged(false)
        waitUntil { !bar.modelChip.isEnabled }

        XCTAssertFalse(bar.modelChip.isHidden, "the chip stays, showing the last known model")
        XCTAssertEqual(bar.modelChip.title, "Sonnet")
        XCTAssertEqual(bar.modelChip.toolTip, "Not connected to nostromd")

        store.connectionChanged(true)
        waitUntil { bar.modelChip.isEnabled }
        XCTAssertEqual(bar.modelChip.toolTip, "Claude Sonnet (claude-sonnet-5-5), effort: default")
    }

    func testTheChipGoesAwayWhenTheFocusIsForgotten() {
        let (bar, _) = makeBar(tag: "focus-a")
        store.ingest(.sessionModelState(state("focus-a")))
        waitUntil { !bar.modelChip.isHidden }
        store.forget(tag: "focus-a")
        waitUntil { bar.modelChip.isHidden }
    }

    // MARK: Two windows

    func testOneFrameUpdatesTheChipInBothWindowsShowingTheSameFocus() {
        let (barA, _) = makeBar(tag: "focus-a", x: 100, y: 500)
        let (barB, _) = makeBar(tag: "focus-a", x: 100, y: 300)
        let (other, _) = makeBar(tag: "focus-b", x: 100, y: 100)
        settle()
        XCTAssertTrue(barA.modelChip.isHidden)
        XCTAssertTrue(barB.modelChip.isHidden)

        store.ingest(.sessionModelState(state("focus-a")))
        waitUntil { !barA.modelChip.isHidden && !barB.modelChip.isHidden }
        XCTAssertEqual(barA.modelChip.title, "Sonnet")
        XCTAssertEqual(barB.modelChip.title, "Sonnet")
        settle()
        XCTAssertTrue(other.modelChip.isHidden, "a bar bound to another focus does not react")

        store.ingest(.sessionModelState(state("focus-a", model: "opus", reported: "claude-opus-5-5", family: "opus", effort: "max")))
        waitUntil { barA.modelChip.title == "Opus \u{00B7} max" && barB.modelChip.title == "Opus \u{00B7} max" }
        XCTAssertTrue(other.modelChip.isHidden)
    }

    func testAFrameForAnotherFocusLeavesABarsChipAlone() {
        let (barA, _) = makeBar(tag: "focus-a")
        store.ingest(.sessionModelState(state("focus-a")))
        waitUntil { barA.modelChip.title == "Sonnet" }

        store.ingest(.sessionModelState(state("focus-b", model: "opus", reported: "claude-opus-5-5", family: "opus")))
        settle()
        XCTAssertEqual(barA.modelChip.title, "Sonnet")
    }

    func testDisconnectingDisablesTheChipInEveryWindow() {
        let (barA, _) = makeBar(tag: "focus-a", x: 100, y: 500)
        let (barB, _) = makeBar(tag: "focus-a", x: 100, y: 300)
        store.ingest(.sessionModelState(state("focus-a")))
        waitUntil { !barA.modelChip.isHidden && !barB.modelChip.isHidden }

        store.connectionChanged(false)
        waitUntil { !barA.modelChip.isEnabled && !barB.modelChip.isEnabled }
        XCTAssertEqual(barA.modelChip.toolTip, "Not connected to nostromd")
        XCTAssertEqual(barB.modelChip.toolTip, "Not connected to nostromd")
    }
}

// MARK: - When a switch does not happen

// A refusal, a failure, a denied or expired agent request must not pass unseen: the bar that owns
// the focus shows a short notice next to the chip and announces it once. The tests drive the real
// `ReplInputBar` from `ModelStore.ingest(...)`, the way the daemon's frames arrive, and reach the
// bar's timing and announcement through its test seams.

final class ModelFailureNoticeTests: XCTestCase {
    private let windows = WindowBag()
    private let tag = "focus-a"
    private var sender: ModelRequestRecorder!
    private var store: ModelStore!
    private var nextId = 0
    private var announced: [String] = []
    private var scheduled: [(duration: TimeInterval, fire: () -> Void)] = []

    override func setUp() {
        super.setUp()
        AppAppearance.apply(to: NSApplication.shared)
        sender = ModelRequestRecorder()
        nextId = 0
        announced = []
        scheduled = []
        store = ModelStore(sender: sender, makeRequestId: { [unowned self] in
            self.nextId += 1
            return "req-\(self.nextId)"
        })
        store.connectionChanged(true)
        store.ingest(.modelCatalog(families: [
            ModelFamilyWire(alias: "sonnet", displayName: "Sonnet", resolved: "claude-sonnet-5-5", efforts: ["low", "medium", "high"], rank: 2),
            ModelFamilyWire(alias: "opus", displayName: "Opus", resolved: "claude-opus-5-5", efforts: ["low", "medium", "high", "xhigh", "max"], rank: 3),
        ], stale: false, fetchedAt: nil))
    }

    override func tearDown() {
        windows.tearDown()
        store = nil
        sender = nil
        super.tearDown()
    }

    // MARK: Fixtures

    private func sonnetRunning(_ tag: String? = nil, recorded: String = "sonnet",
                               last: LastModelRequestWire? = nil) -> SessionModelStateWire {
        SessionModelStateWire(tag: tag ?? self.tag, recorded: RecordedModelWire(model: recorded, source: .focus),
                              reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                              running: true, lastRequest: last)
    }

    private func lastRequest(_ status: ModelRequestStatusWire, requestId: String, to: String = "opus",
                             actor: String = "script") -> LastModelRequestWire {
        LastModelRequestWire(actor: actor, to: to, status: status, requestId: requestId, ts: nil)
    }

    /// A bar bound to `tag`, its seams recording into `announced` and `scheduled`. Set up BEFORE it
    /// binds, so nothing it does at bind time escapes the recording.
    @discardableResult
    private func makeBar(tag: String? = nil, store: ModelStore? = nil, inWindow: Bool = true) -> ReplInputBar {
        let bar = ReplInputBar(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        bar.announceModelNotice = { [weak self] text in self?.announced.append(text) }
        bar.scheduleModelNoticeDismissal = { [weak self] duration, fire in self?.scheduled.append((duration, fire)) }
        if inWindow {
            let window = windows.make(x: 100, y: 300)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
            window.contentView = content
            content.addSubview(bar)
            bar.bindModel(tag: tag ?? self.tag, agentName: "claudia", store: store ?? self.store)
            window.orderFront(nil)
            content.layoutSubtreeIfNeeded()
        } else {
            bar.bindModel(tag: tag ?? self.tag, agentName: "claudia", store: store ?? self.store)
        }
        return bar
    }

    /// Ask for a switch of `tag` and have the daemon answer it with `status`.
    @discardableResult
    private func answerSwitch(_ status: ModelRequestStatusWire, code: String? = nil, message: String? = nil,
                              tag: String? = nil) -> String {
        let id = store.requestSwitch(tag: tag ?? self.tag, model: "opus", effort: nil)
        store.ingest(.modelRequestResult(requestId: id, status: status, code: code, message: message, warning: nil))
        modelFlushMain()
        return id
    }

    /// Show the focus, then have a script's request end in `status`: only `last_request` says so.
    private func scriptRequestEnds(_ status: ModelRequestStatusWire, requestId: String = "script-1", tag: String? = nil) {
        store.ingest(.sessionModelState(sonnetRunning(tag)))
        store.ingest(.sessionModelState(sonnetRunning(tag, last: lastRequest(status, requestId: requestId))))
        modelFlushMain()
    }

    private func assertShown(_ bar: ReplInputBar, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(bar.modelNoticeText, text, file: file, line: line)
        XCTAssertEqual(announced, [text], "announced once, with the same words", file: file, line: line)
        XCTAssertEqual(scheduled.count, 1, "one timed dismissal is scheduled", file: file, line: line)
        XCTAssertGreaterThan(scheduled.first?.duration ?? 0, 0, "the notice stays up for a while", file: file, line: line)
    }

    // MARK: Results that fail

    func testAnUnknownModelRefusalIsShownAndAnnounced() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        assertShown(bar, "Couldn't switch: that model isn't available")
    }

    func testANotPermittedRefusalIsShownAndAnnounced() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "not_permitted")
        assertShown(bar, "Couldn't switch: this session's model can't be changed")
    }

    func testAFailedSwitchShowsTheDaemonsMessage() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.failed, message: "The session did not restart.")
        assertShown(bar, "Couldn't switch: the session did not restart.")
    }

    func testADeniedRequestResultIsShown() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.denied)
        assertShown(bar, "Couldn't switch: the request was declined")
    }

    func testAnExpiredRequestResultIsShown() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.expired)
        assertShown(bar, "Couldn't switch: the request expired")
    }

    func testAnUnchangedAnswerWhileTheCLIRunsAnotherModelSaysSo() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning(recorded: "opus")))
        answerSwitch(.unchanged)
        assertShown(bar, "Opus was requested, but this session is running Sonnet")
    }

    // MARK: Failures that arrive only as the focus's last request

    func testAFailedScriptRequestIsShown() {
        let bar = makeBar()
        scriptRequestEnds(.failed)
        assertShown(bar, "Couldn't switch: something went wrong")
    }

    func testARefusedScriptRequestIsShown() {
        let bar = makeBar()
        scriptRequestEnds(.refused)
        assertShown(bar, "Couldn't switch: something went wrong")
    }

    func testADeniedAgentRequestIsShown() {
        let bar = makeBar()
        scriptRequestEnds(.denied)
        assertShown(bar, "Couldn't switch: the request was declined")
    }

    func testAnExpiredAgentRequestIsShown() {
        let bar = makeBar()
        scriptRequestEnds(.expired)
        assertShown(bar, "Couldn't switch: the request expired")
    }

    // MARK: Nothing to report

    func testNothingIsShownForOutcomesThatAreNotFailures() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.applied)
        answerSwitch(.pendingTurnEnd)
        answerSwitch(.awaitingUser)
        answerSwitch(.unknown("teleported"))
        answerSwitch(.unchanged)   // recorded and running agree: nothing to contradict
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertEqual(announced, [])
        XCTAssertEqual(scheduled.count, 0)
    }

    func testAResultForARequestThisConnectionNeverMadeShowsNothing() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        store.ingest(.modelRequestResult(requestId: "not-ours", status: .refused, code: "unknown_model", message: nil, warning: nil))
        modelFlushMain()
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertEqual(announced, [])
    }

    func testChangesToAnotherLastRequestThatAreNotFailuresShowNothing() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        store.ingest(.sessionModelState(sonnetRunning(last: lastRequest(.applied, requestId: "s-1"))))
        store.ingest(.sessionModelState(sonnetRunning(last: lastRequest(.pendingTurnEnd, requestId: "s-2"))))
        modelFlushMain()
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertEqual(announced, [])
    }

    func testTheFirstStateAfterLaunchOrReconnectNeverShowsAnOldFailure() {
        let bar = makeBar()
        // The `model` subscribe replays the state, with the last request it had.
        store.ingest(.sessionModelState(sonnetRunning(last: lastRequest(.failed, requestId: "yesterday"))))
        modelFlushMain()
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertEqual(announced, [])
        // And so does the replay after a reconnect.
        store.connectionChanged(false)
        store.connectionChanged(true)
        store.ingest(.sessionModelState(sonnetRunning(last: lastRequest(.failed, requestId: "yesterday"))))
        modelFlushMain()
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertEqual(announced, [])
    }

    func testABarBoundWhileAFailureIsAlreadyHeldShowsNothingAtBind() {
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        XCTAssertNotNil(store.failure(for: tag), "precondition: the store holds a failure for the tag")

        let late = makeBar()
        modelFlushMain()
        XCTAssertNil(late.modelNoticeText, "only a failure produced while the bar is watching is news to it")
        XCTAssertEqual(announced, [])
        XCTAssertEqual(scheduled.count, 0)

        answerSwitch(.denied)
        XCTAssertEqual(late.modelNoticeText, "Couldn't switch: the request was declined", "but the next one does show")
    }

    // MARK: Whose notice it is

    func testAFailureForAnotherFocusIsNotShownByThisBar() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        store.ingest(.sessionModelState(sonnetRunning("focus-b")))
        answerSwitch(.refused, code: "unknown_model", tag: "focus-b")
        scriptRequestEnds(.failed, tag: "focus-b")
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertEqual(announced, [])
        XCTAssertEqual(scheduled.count, 0)
    }

    func testOnlyTheBarOfTheFocusThatFailedShowsTheNotice() {
        let barA = makeBar(tag: "focus-a")
        let barB = makeBar(tag: "focus-b")
        store.ingest(.sessionModelState(sonnetRunning("focus-a")))
        store.ingest(.sessionModelState(sonnetRunning("focus-b")))
        answerSwitch(.refused, code: "not_permitted", tag: "focus-b")
        XCTAssertNil(barA.modelNoticeText)
        XCTAssertEqual(barB.modelNoticeText, "Couldn't switch: this session's model can't be changed")
        XCTAssertEqual(announced.count, 1, "announced once, by the bar that owns the focus")
    }

    func testTheNoticeTextIsSetEvenWhenTheBarIsNotInAWindow() {
        let bar = makeBar(inWindow: false)
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        XCTAssertEqual(bar.modelNoticeText, "Couldn't switch: that model isn't available")
    }

    // MARK: Dismissal

    func testTheTimedDismissalClearsTheNoticeAndTheStoresFailure() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        XCTAssertNotNil(store.failure(for: tag))

        scheduled.first?.fire()
        modelFlushMain()

        XCTAssertNil(bar.modelNoticeText)
        XCTAssertNil(store.failure(for: tag))
    }

    func testDismissingTheNoticeByHandClearsItToo() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        bar.dismissModelNotice()
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertNil(store.failure(for: tag))
    }

    func testASecondFailureReplacesTheFirstAndIsAnnouncedToo() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        answerSwitch(.denied)
        XCTAssertEqual(bar.modelNoticeText, "Couldn't switch: the request was declined")
        XCTAssertEqual(announced, ["Couldn't switch: that model isn't available", "Couldn't switch: the request was declined"])
        XCTAssertEqual(scheduled.count, 2)
    }

    func testTheFirstNoticesLateDismissalDoesNotClearTheSecond() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        answerSwitch(.expired)
        guard scheduled.count == 2 else { return XCTFail("expected two scheduled dismissals, got \(scheduled.count)") }

        scheduled[0].fire()   // the first notice's timer, long after it was replaced
        modelFlushMain()
        XCTAssertEqual(bar.modelNoticeText, "Couldn't switch: the request expired", "a stale dismissal clears nothing")
        XCTAssertNotNil(store.failure(for: tag))

        scheduled[1].fire()
        modelFlushMain()
        XCTAssertNil(bar.modelNoticeText)
        XCTAssertNil(store.failure(for: tag))
    }

    // MARK: One failure, one notice

    func testARequestReportedByItsResultIsNotReportedAgainByTheStateThatCarriesIt() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        let id = answerSwitch(.refused, code: "unknown_model")
        store.ingest(.sessionModelState(sonnetRunning(last: lastRequest(.refused, requestId: id, actor: "user"))))
        modelFlushMain()
        XCTAssertEqual(announced, ["Couldn't switch: that model isn't available"], "announced once")
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(bar.modelNoticeText, "Couldn't switch: that model isn't available")
    }

    func testARequestWhoseStateArrivesBeforeItsResultIsStillReportedOnceWithTheDetailedMessage() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        let id = store.requestSwitch(tag: tag, model: "opus", effort: nil)
        store.ingest(.sessionModelState(sonnetRunning(last: lastRequest(.refused, requestId: id, actor: "user"))))
        store.ingest(.modelRequestResult(requestId: id, status: .refused, code: "unknown_model", message: nil, warning: nil))
        modelFlushMain()
        XCTAssertEqual(announced, ["Couldn't switch: that model isn't available"])
        XCTAssertEqual(bar.modelNoticeText, "Couldn't switch: that model isn't available")
    }

    // MARK: The chip stays as it was

    func testARefusalWhileThePopupIsClosedLeavesTheChipUnchangedAndUsable() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        modelFlushMain()
        let title = bar.modelChip.title
        let tooltip = bar.modelChip.toolTip
        XCTAssertEqual(title, "Sonnet", "precondition")

        answerSwitch(.refused, code: "unknown_model")

        XCTAssertNotNil(bar.modelNoticeText, "precondition: the refusal is shown")
        XCTAssertEqual(bar.modelChip.title, title, "the chip still shows what is running")
        XCTAssertEqual(bar.modelChip.toolTip, tooltip)
        XCTAssertFalse(bar.modelChip.isHidden)
        XCTAssertTrue(bar.modelChip.isEnabled)
        XCTAssertTrue(bar.canShowModelPopover)
        XCTAssertNil(bar.modelPopover, "a refusal opens nothing")
    }

    func testThePopupStillOpensWhileANoticeIsShowing() {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        answerSwitch(.refused, code: "unknown_model")
        XCTAssertNotNil(bar.modelNoticeText, "precondition")

        bar.showModelPopover(nil)

        XCTAssertTrue(bar.modelPopover?.isShown ?? false, "the notice does not take the chip's popup away")
        bar.modelPopover?.close()
        modelWaitUntil(failing: false) { !(bar.modelPopover?.isShown ?? false) }
    }

    func testChoosingARowThatTheDaemonRefusesEndsWithANoticeAndAnUnchangedChip() throws {
        let bar = makeBar()
        store.ingest(.sessionModelState(sonnetRunning()))
        modelFlushMain()
        bar.showModelPopover(nil)
        let popover = try XCTUnwrap(bar.modelPopover)
        let rows = popover.viewController.modelRowViews
        XCTAssertEqual(rows.map(\.titleText), ["Sonnet", "Opus"])
        guard rows.count == 2 else { return }

        rows[1].activate()   // Opus
        let request = try XCTUnwrap(sender.sets.first, "choosing Opus asks the daemon")
        guard case let .set(_, model, _, _, requestId) = request else { return XCTFail("not a set: \(request)") }
        XCTAssertEqual(model, "opus")
        store.ingest(.modelRequestResult(requestId: requestId, status: .refused, code: "unknown_model", message: nil, warning: nil))
        modelWaitUntil(failing: false) { !popover.isShown }

        XCTAssertEqual(bar.modelNoticeText, "Couldn't switch: that model isn't available")
        XCTAssertEqual(bar.modelChip.title, "Sonnet")
        XCTAssertTrue(bar.canShowModelPopover)
    }
}
