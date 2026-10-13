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
final class WindowBag {
    private(set) var windows: [NSWindow] = []

    /// A window that reports `key` as its key state.
    func makeStateWindow(key: Bool, width: CGFloat = 300, height: CGFloat = 60, x: CGFloat = 100, y: CGFloat = 300) -> StateWindow {
        let w = StateWindow(contentRect: NSRect(x: x, y: y, width: width, height: height),
                            styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.reportsKey = key
        windows.append(w)
        return w
    }

    func make(width: CGFloat = 600, height: CGFloat = 60, x: CGFloat = 100, y: CGFloat = 300) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: x, y: y, width: width, height: height),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
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

    /// Draw `chip` on the bar background in a window that reports itself key (or inactive) and
    /// measure it.
    private func render(_ chipPresentation: ModelPresentation.Chip, keyWindow: Bool) -> RegionLuminance {
        let window = windows.makeStateWindow(key: keyWindow)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        host.wantsLayer = true
        host.layer?.backgroundColor = barBackground()
        window.contentView = host
        let chip = ModelChip()
        chip.frame = Self.chipFrame
        host.addSubview(chip)
        chip.apply(chipPresentation)
        window.orderFront(nil)
        XCTAssertEqual(window.isKeyWindow, keyWindow, "precondition: the host window is \(keyWindow ? "key" : "inactive")")

        return measureRegion(of: host, region: Self.chipFrame, textArea: Self.chipFrame.insetBy(dx: 6, dy: 4))
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

    private func settle(_ interval: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
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
        // NSPopover closes with an animation: isShown drops when it finishes.
        let deadline = Date().addingTimeInterval(2)
        while (barB.modelPopover?.isShown ?? false) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(barB.modelPopover?.isShown ?? false, "the second press closes it")
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
    private func waitUntil(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("condition not met within \(timeout)s", file: file, line: line)
                return false
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func settle(_ interval: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
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
