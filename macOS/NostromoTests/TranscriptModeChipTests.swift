import XCTest
import AppKit
import NostromoKit

// FV4: the transcript view chip in the input bar (`Focus` / `All activity`).
//
// What an operator can rely on:
//   - the chip reads the focus's mode, live from the store (a switch in any window, or the default
//     changing, reaches every bar on that focus), and is labelled for VoiceOver as a button;
//   - a click on it asks the pane for the OTHER mode (the pane performs it);
//   - it is reachable with Tab, never takes the keyboard by itself, and never changes the composer's
//     width, whichever mode it shows;
//   - left to right the bar reads [composer ... background slot, mode chip, model chip, Send], and in a
//     narrow pane the parts give way in the order background slot, then mode chip, then model chip,
//     with the composer keeping its 120 pt minimum and no part ever overlapping another.
//
// The give-way order is the input bar's existing rule ("the background slot first"), which this chip
// slots into just before the model chip. The plan proposed the model chip going before the mode
// chip; the existing rule stands, and this file pins it.
//
// Layout is read from real frames after `layoutSubtreeIfNeeded()`: no run-loop timing. Pixels and
// contrast are `TranscriptModeChipAppearanceTests`.

final class TranscriptModeChipTests: XCTestCase {
    private var keepAlive: [AnyObject] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        keepAlive = []
    }

    override func tearDown() {
        keepAlive = []
        super.tearDown()
    }

    // MARK: Helpers

    private func settle(_ bar: ReplInputBar, in window: NSWindow) {
        for _ in 0 ..< 3 {
            window.contentView?.layoutSubtreeIfNeeded()
            bar.layoutSubtreeIfNeeded()
        }
    }

    private func resize(_ rig: LayoutRig, to width: CGFloat) {
        rig.window.setContentSize(NSSize(width: width, height: 60))
        rig.bar.setFrameSize(NSSize(width: width, height: 60))
        settle(rig.bar, in: rig.window)
    }

    private func sendButton(of bar: ReplInputBar) -> NSButton? {
        bar.subviews.compactMap { $0 as? NSButton }.first { $0.attributedTitle.string == "Send" || $0.title == "Send" }
    }

    private func stopButton(of bar: ReplInputBar) -> NSButton? {
        bar.subviews.compactMap { $0 as? NSButton }.first { $0.attributedTitle.string.contains("Stop") || $0.title.contains("Stop") }
    }

    private struct LayoutRig {
        let window: RigWindow
        let bar: ReplInputBar
        let store: TranscriptFoldStore
    }

    /// A real input bar `width` wide, bound to a background store, a fold store (its chip) and, if asked,
    /// a model store showing a model; with Stop up if asked.
    private func makeRig(width: CGFloat, model: Bool, stop: Bool = false, foldStore: TranscriptFoldStore? = nil) -> LayoutRig {
        let window = makeRigWindow(self, size: NSSize(width: width, height: 60))
        let world = BA3UIWorld(self)
        let bar = ba3uiMakeBar(in: window, frame: NSRect(x: 0, y: 0, width: width, height: 60), tag: "gate", store: world.store)
        let store = foldStore ?? scrollRigFoldStore()
        bar.bindMode(tag: "gate", store: store)
        keepAlive.append(world)
        if model {
            let sender = ModelRequestRecorder()
            let modelStore = ModelStore(sender: sender)
            modelStore.connectionChanged(true)
            keepAlive += [sender, modelStore]
            bar.bindModel(tag: "gate", agentName: "claudia", store: modelStore)
            let state = SessionModelStateWire(tag: "gate",
                                              recorded: RecordedModelWire(model: "sonnet", effort: nil, source: .focus),
                                              reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                              running: true)
            modelStore.ingest(.sessionModelState(state))
            modelWaitUntil { !bar.modelChip.isHidden }
        }
        if stop {
            bar.setRunning(true)
            addTeardownBlock { bar.setRunning(false) }
        }
        settle(bar, in: window)
        return LayoutRig(window: window, bar: bar, store: store)
    }

    private struct Frames {
        let composer: NSRect
        let slot: NSRect
        let mode: NSRect
        let model: NSRect
        let send: NSRect
        let stop: NSRect?
    }

    private func frames(of bar: ReplInputBar, file: StaticString = #filePath, line: UInt = #line) throws -> Frames {
        let composer = try XCTUnwrap(bar.textView.enclosingScrollView?.frame, "the composer has a scroll view", file: file, line: line)
        let send = try XCTUnwrap(sendButton(of: bar)?.frame, "the bar has a Send button", file: file, line: line)
        let stop = stopButton(of: bar).flatMap { $0.isHidden ? nil : $0.frame }
        return Frames(composer: composer, slot: bar.backgroundSlot.frame, mode: bar.modeChip.frame,
                      model: bar.modelChip.frame, send: send, stop: stop)
    }

    /// What a narrow bar must never do: widen its window, leave its pane, or put one part on another.
    private func assertTheBarHolds(_ rig: LayoutRig, width: CGFloat, _ name: String,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let bar = rig.bar
        settle(bar, in: rig.window)
        XCTAssertEqual(rig.window.frame.width, width, accuracy: 0.5, "\(name): the window must never widen", file: file, line: line)
        XCTAssertEqual(bar.frame.width, width, accuracy: 0.5, "\(name): the bar keeps the pane's width", file: file, line: line)
        let f = try frames(of: bar, file: file, line: line)
        var parts: [(String, NSRect)] = [("composer", f.composer), ("background slot", f.slot), ("mode chip", f.mode), ("Send", f.send)]
        if !bar.modelChip.isHidden { parts.append(("model chip", f.model)) }
        if let stop = f.stop { parts.append(("Stop", stop)) }

        let barBounds = bar.bounds.insetBy(dx: -0.5, dy: -0.5)
        for (label, frame) in parts {
            XCTAssertTrue(barBounds.contains(frame), "\(name): \(label) \(frame) must stay inside the bar \(bar.bounds)", file: file, line: line)
        }
        for (i, a) in parts.enumerated() {
            for b in parts[(i + 1)...] {
                let overlap = a.1.intersection(b.1)
                let overlaps = !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5
                XCTAssertFalse(overlaps, "\(name): \(a.0) \(a.1) and \(b.0) \(b.1) must not overlap", file: file, line: line)
            }
        }
        XCTAssertEqual(f.mode.height, TranscriptModeChip.height, accuracy: 0.5,
                       "\(name): the chip never grows a second line", file: file, line: line)
        XCTAssertLessThanOrEqual(f.mode.width, TranscriptModeChip.slotWidth + 0.5, "\(name): never wider than its slot", file: file, line: line)
        if f.mode.width > 0.5 {
            XCTAssertLessThanOrEqual(f.composer.maxX, f.mode.minX + 0.5, "\(name): the text view never extends under the chip",
                                     file: file, line: line)
        }
    }

    // MARK: The chip's own text

    func testTheChipReadsFocusOrAllActivityAndIsLabelledForVoiceOver() {
        let chip = TranscriptModeChip()
        XCTAssertEqual(chip.title, "Focus", "a new chip is in Focus")
        XCTAssertEqual(chip.mode, .focus)

        let expected: [(TranscriptViewMode, String)] = [(.allActivity, "All activity"), (.focus, "Focus")]
        for (mode, title) in expected {
            chip.apply(mode)
            XCTAssertEqual(chip.mode, mode)
            XCTAssertEqual(chip.title, title)
            XCTAssertEqual(TranscriptModeChip.title(for: mode), title)
            XCTAssertEqual(chip.accessibilityLabel(), "Transcript view: \(title)")
            XCTAssertEqual(TranscriptModeChip.accessibilityLabel(for: mode), "Transcript view: \(title)")
            XCTAssertEqual(chip.accessibilityRole(), .button)
            XCTAssertTrue((chip.toolTip ?? "").contains("Transcript view: \(title)"), "the tooltip names the view: \(chip.toolTip ?? "nil")")
            XCTAssertTrue((chip.toolTip ?? "").contains("\u{2325}\u{2318}"), "and the shortcut that switches it")
        }
    }

    func testEveryStringTheChipShowsIsAFixedStringThatNeverDependsOnAnythingButTheMode() {
        let allowedTitles: Set<String> = ["Focus", "All activity"]
        XCTAssertEqual(Set(TranscriptViewMode.allCases.map { TranscriptModeChip.title(for: $0) }), allowedTitles)
        let chip = TranscriptModeChip()
        var seen: [TranscriptViewMode: [String]] = [:]
        // The same mode applied again and again, whatever came in between, reads the same.
        for mode in [TranscriptViewMode.allActivity, .focus, .focus, .allActivity, .allActivity, .focus] {
            chip.apply(mode)
            seen[mode, default: []].append("\(chip.title)|\(chip.accessibilityLabel() ?? "")|\(chip.toolTip ?? "")")
        }
        for (mode, readings) in seen {
            XCTAssertEqual(Set(readings).count, 1, "\(mode): title, label and tooltip are fixed strings")
        }
    }

    func testTheSlotIsAsWideAsTheWiderTitleWhateverTheModeAndTheChipIsAsHighAsItsSibling() {
        let chip = TranscriptModeChip()
        let widest = TranscriptViewMode.allCases.map { mode in
            NSAttributedString(string: TranscriptModeChip.title(for: mode), attributes: [.font: TranscriptModeChip.font]).size().width
        }.max() ?? 0
        XCTAssertGreaterThanOrEqual(TranscriptModeChip.slotWidth, widest + 2 * TranscriptModeChip.horizontalPadding - 0.5,
                                    "the slot holds the wider title, padding included")
        for mode in TranscriptViewMode.allCases {
            chip.apply(mode)
            XCTAssertEqual(chip.intrinsicContentSize.width, TranscriptModeChip.slotWidth, accuracy: 0.001, "\(mode): same width")
            XCTAssertEqual(chip.intrinsicContentSize.height, ModelChip.height, accuracy: 0.001, "same height as the model chip")
        }
        XCTAssertEqual(TranscriptModeChip.height, ModelChip.height)
    }

    func testNoViewInTheChipFilesDeclaresATagStringThatWouldCollideWithNSViewTag() throws {
        let root = fv4RepoRoot().appendingPathComponent("macOS/Nostromo/UI")
        let pattern = try NSRegularExpression(pattern: "\\bvar\\s+tag\\s*:\\s*String\\b")
        for relative in ["Model/TranscriptModeChip.swift", "Views/ReplInputBar.swift", "TranscriptViewMenu.swift"] {
            let code = fv4StrippingComments(try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8))
            XCTAssertNil(pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                         "\(relative): `NSView.tag` is an Int; a `tag: String` property is a compile and behaviour trap")
        }
    }

    // MARK: Keyboard

    func testTheChipIsReachableWithTabAndHoldsFocusOnlyWhileItIsTheFirstResponder() {
        let chip = TranscriptModeChip()
        XCTAssertFalse(chip.refusesFirstResponder, "Tab reaches the chip")
        XCTAssertFalse(chip.hasKeyboardFocus)
        XCTAssertTrue(chip.becomeFirstResponder())
        XCTAssertTrue(chip.hasKeyboardFocus)
        XCTAssertTrue(chip.resignFirstResponder())
        XCTAssertFalse(chip.hasKeyboardFocus)
    }

    /// The loop is what ⌃Tab walks, and Tab from another control with Full Keyboard Access on; Tab inside
    /// the composer types a tab, so this does not claim that key. Skips on CI (Full Keyboard Access is off).
    func testTheKeyViewLoopAfterTheComposerReachesTheChipWithFullKeyboardAccessOn() throws {
        try XCTSkipUnless(NSApp.isFullKeyboardAccessEnabled,
                          "a button joins the Tab loop only with Full Keyboard Access on; this Mac has it off")
        let rig = makeRig(width: 600, model: false)
        rig.window.recalculateKeyViewLoop()
        XCTAssertTrue(rig.window.makeFirstResponder(rig.bar.textView))

        var cursor: NSView? = rig.bar.textView
        var reached = false
        for _ in 0 ..< 12 {
            cursor = cursor?.nextValidKeyView
            if cursor === rig.bar.modeChip { reached = true; break }
            if cursor == nil || cursor === rig.bar.textView { break }
        }
        XCTAssertTrue(reached, "the key view loop after the composer arrives at the transcript view chip")
    }

    func testChangingTheModeNeverTakesTheKeyboardOrMovesTheInsertionPoint() {
        let rig = makeRig(width: 600, model: false)
        rig.bar.textView.string = "half a thought"
        XCTAssertTrue(rig.window.makeFirstResponder(rig.bar.textView))
        rig.bar.textView.setSelectedRange(NSRange(location: 2, length: 4))

        for mode in [TranscriptViewMode.allActivity, .focus, .allActivity] {
            rig.store.setMode(tag: "gate", mode)
            XCTAssertEqual(rig.bar.modeChip.mode, mode)
            XCTAssertTrue(rig.window.firstResponder === rig.bar.textView, "\(mode): the composer keeps the keyboard")
            XCTAssertFalse(rig.bar.modeChip.hasKeyboardFocus, "\(mode): the chip has no focus ring")
            XCTAssertEqual(rig.bar.textView.string, "half a thought")
            XCTAssertEqual(rig.bar.textView.selectedRange(), NSRange(location: 2, length: 4))
        }
    }

    // MARK: Binding and clicks

    func testAClickAsksThePaneForTheOtherModeAndSwitchesNothingItself() {
        let rig = makeRig(width: 600, model: false)
        var requested: [TranscriptViewMode] = []
        rig.bar.onSetMode = { requested.append($0) }
        let chip = rig.bar.modeChip

        XCTAssertTrue(chip.sendAction(chip.action, to: chip.target))
        XCTAssertEqual(requested, [.allActivity], "Focus asks for All activity")
        XCTAssertNil(rig.store.explicitMode(tag: "gate"), "the bar does not switch: the pane does")
        XCTAssertEqual(chip.title, "Focus")

        rig.store.setMode(tag: "gate", .allActivity)
        XCTAssertTrue(chip.sendAction(chip.action, to: chip.target))
        XCTAssertEqual(requested, [.allActivity, .focus], "All activity asks for Focus")
    }

    func testTheChipTakesNoSpaceAndIsHiddenUntilTheBarIsBoundThenHasItsFixedSlot() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = ReplInputBar(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView?.addSubview(bar)
        settle(bar, in: window)
        XCTAssertTrue(bar.modeChip.isHidden)
        XCTAssertEqual(bar.modeChip.frame.width, 0, accuracy: 0.5)

        bar.bindMode(tag: "gate", store: scrollRigFoldStore())
        settle(bar, in: window)

        XCTAssertFalse(bar.modeChip.isHidden)
        XCTAssertEqual(bar.modeChip.frame.width, TranscriptModeChip.slotWidth, accuracy: 0.5)
    }

    func testTheChipFollowsTheStoreForItsOwnFocusOnly() {
        // Its own store world: this test changes the default, which a private suite must clean up.
        let storeWorld = FV4StoreWorld(self)
        let rig = makeRig(width: 600, model: false, foldStore: storeWorld.store)
        let store = rig.store

        store.setMode(tag: "gate", .allActivity)
        XCTAssertEqual(rig.bar.modeChip.title, "All activity", "a switch made anywhere reaches this bar")
        store.setMode(tag: "elsewhere", .focus)
        store.setMode(tag: "gate", .focus)
        XCTAssertEqual(rig.bar.modeChip.title, "Focus")

        store.setMode(tag: "elsewhere", .allActivity)
        XCTAssertEqual(rig.bar.modeChip.title, "Focus", "another focus's switch is not this focus's")

        store.clearMode(tag: "gate")
        store.defaultMode = .allActivity
        XCTAssertEqual(rig.bar.modeChip.title, "All activity", "with no choice of its own the chip shows the default")
    }

    func testTheLoadHarnessShowAllOverridesWhatTheChipReads() {
        let window = makeRigWindow(self, size: NSSize(width: 600, height: 60))
        let bar = ReplInputBar(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView?.addSubview(bar)
        let store = scrollRigFoldStore()

        bar.bindMode(tag: "gate", store: store, harnessMode: .allActivity)

        XCTAssertEqual(bar.modeChip.title, "All activity")
        store.setMode(tag: "gate", .focus)
        XCTAssertEqual(bar.modeChip.title, "All activity", "the harness forces every focus to All activity")
    }

    // MARK: Layout

    func testTheChipSitsBetweenTheBackgroundSlotAndTheModelChipThenSend() throws {
        let rig = makeRig(width: 600, model: true)
        XCTAssertFalse(rig.bar.modelChip.isHidden, "precondition: the model chip shows")
        let f = try frames(of: rig.bar)

        XCTAssertLessThanOrEqual(f.composer.maxX, f.slot.minX + 0.5, "composer, then the background slot")
        XCTAssertLessThanOrEqual(f.slot.maxX, f.mode.minX + 0.5, "the slot, then the mode chip")
        XCTAssertLessThanOrEqual(f.mode.maxX, f.model.minX + 0.5, "the mode chip, then the model chip")
        XCTAssertLessThanOrEqual(f.model.maxX, f.send.minX + 0.5, "the model chip, then Send")
        XCTAssertEqual(f.mode.width, TranscriptModeChip.slotWidth, accuracy: 0.5)
        try assertTheBarHolds(rig, width: 600, "600 pt, model chip")
    }

    func testWithoutAModelChipTheChipSitsBetweenTheSlotAndSend() throws {
        let rig = makeRig(width: 600, model: false)
        XCTAssertTrue(rig.bar.modelChip.isHidden, "precondition: no model state")
        let f = try frames(of: rig.bar)

        XCTAssertLessThanOrEqual(f.composer.maxX, f.slot.minX + 0.5)
        XCTAssertLessThanOrEqual(f.slot.maxX, f.mode.minX + 0.5)
        XCTAssertLessThanOrEqual(f.mode.maxX, f.send.minX + 0.5, "the hidden model chip leaves no gap the chip could fall into")
        XCTAssertEqual(f.model.width, 0, accuracy: 0.5)
        try assertTheBarHolds(rig, width: 600, "600 pt, no model chip")
    }

    func testWhileATurnRunsTheChipSitsLeftOfStop() throws {
        let rig = makeRig(width: 600, model: true, stop: true)
        let f = try frames(of: rig.bar)
        let stop = try XCTUnwrap(f.stop, "precondition: Stop shows")

        XCTAssertLessThanOrEqual(f.mode.maxX, f.model.minX + 0.5)
        XCTAssertLessThanOrEqual(f.model.maxX, stop.minX + 0.5)
        XCTAssertLessThanOrEqual(stop.maxX, f.send.minX + 0.5)
        try assertTheBarHolds(rig, width: 600, "600 pt, model chip and Stop")
    }

    func testTogglingTheModeNeverChangesTheComposersWidthTheChipsSlotOrTheBarsHeight() throws {
        for width in [CGFloat(600), 320] {
            let rig = makeRig(width: width, model: true)
            let before = try frames(of: rig.bar)
            let height = rig.bar.frame.height

            for mode in [TranscriptViewMode.allActivity, .focus, .allActivity] {
                rig.store.setMode(tag: "gate", mode)
                settle(rig.bar, in: rig.window)
                let after = try frames(of: rig.bar)
                XCTAssertEqual(rig.bar.modeChip.mode, mode, "precondition")
                XCTAssertEqual(after.composer, before.composer, "\(Int(width)) pt, \(mode): the composer did not move or resize")
                XCTAssertEqual(after.mode, before.mode, "\(Int(width)) pt, \(mode): the chip's slot did not change")
                XCTAssertEqual(after.model, before.model, "\(Int(width)) pt, \(mode): nor the model chip")
                XCTAssertEqual(rig.bar.frame.height, height, accuracy: 0.5)
            }
        }
    }

    func testThePartsGiveWayAsTheBarNarrowsBackgroundSlotFirstThenModeChipThenModelChip() throws {
        let rig = makeRig(width: 800, model: true)
        let fullSlot = BackgroundChip.slotWidth
        let fullMode = TranscriptModeChip.slotWidth
        let fullModel = rig.bar.modelChip.intrinsicContentSize.width
        var samples: [(width: CGFloat, slot: CGFloat, mode: CGFloat, model: CGFloat)] = []

        for width in stride(from: CGFloat(800), through: 200, by: -10) {
            resize(rig, to: width)
            let f = try frames(of: rig.bar)
            samples.append((width, f.slot.width, f.mode.width, f.model.width))
            try assertTheBarHolds(rig, width: width, "\(Int(width)) pt")
            // Where the arithmetic allows it the composer keeps its minimum.
            if width >= 320 {
                let wanted = max(ReplInputBar.composerMinimumWidth, ReplInputBar.composerMinimumFraction * width)
                XCTAssertGreaterThanOrEqual(f.composer.width, wanted - 0.5, "\(Int(width)) pt: the composer keeps at least \(wanted) pt")
            }
        }

        let first = try XCTUnwrap(samples.first)
        XCTAssertEqual(first.slot, fullSlot, accuracy: 0.5, "precondition: at 800 pt nothing has given way")
        XCTAssertEqual(first.mode, fullMode, accuracy: 0.5)
        XCTAssertEqual(first.model, fullModel, accuracy: 0.5)

        let leastSlot = samples.map(\.slot).min() ?? 0
        let leastMode = samples.map(\.mode).min() ?? 0
        for s in samples {
            if s.mode < fullMode - 0.5 {
                XCTAssertLessThanOrEqual(s.slot, leastSlot + 0.5, "\(Int(s.width)) pt: the mode chip squeezes only once the background slot has given all it can")
            }
            if s.model < fullModel - 0.5 {
                XCTAssertLessThanOrEqual(s.mode, leastMode + 0.5, "\(Int(s.width)) pt: the model chip squeezes only after the mode chip")
                XCTAssertLessThanOrEqual(s.slot, leastSlot + 0.5, "\(Int(s.width)) pt: and after the background slot")
            }
        }
        XCTAssertTrue(samples.contains { $0.slot < fullSlot - 0.5 && $0.mode > fullMode - 0.5 },
                      "somewhere the background slot has given way while the mode chip is whole")
        XCTAssertTrue(samples.contains { $0.mode < fullMode - 0.5 && $0.model > fullModel - 0.5 },
                      "somewhere the mode chip has given way while the model chip is whole")
        XCTAssertTrue(samples.contains { $0.model < fullModel - 0.5 }, "and in the narrowest panes the model chip gives way last")
    }

    func testTheChipReturnsToItsFullSlotWhenThePaneWidensAgain() throws {
        let rig = makeRig(width: 260, model: true)
        let narrow = try frames(of: rig.bar)
        XCTAssertLessThan(narrow.mode.width, TranscriptModeChip.slotWidth - 0.5, "precondition: it gave way at 260 pt")

        resize(rig, to: 600)

        let wide = try frames(of: rig.bar)
        XCTAssertEqual(wide.mode.width, TranscriptModeChip.slotWidth, accuracy: 0.5)
        try assertTheBarHolds(rig, width: 600, "widened to 600 pt")
    }

    func testANarrowBarsChipKeepsTheComposerWhereItWasWhateverTheModeSays() throws {
        let rig = makeRig(width: 260, model: true)
        let composer = try frames(of: rig.bar).composer

        rig.store.setMode(tag: "gate", .allActivity)
        settle(rig.bar, in: rig.window)

        XCTAssertEqual(try frames(of: rig.bar).composer, composer, "squeezed or not, a mode change never moves the composer")
        try assertTheBarHolds(rig, width: 260, "260 pt, All activity")
    }
}
