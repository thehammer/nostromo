import XCTest
import AppKit
import NostromoKit

// ModelPopoverViewController, ModelPopover, ModelStore, ModelPresentation, Theme and AppAppearance
// are compiled into this test target directly (logic test, no host app).
//
// The model popup is driven from the keyboard (PRD "The popup"): arrows move, Return selects, Tab
// moves between the model and effort sections, Escape closes with no change. Keys are sent to the
// content view as real `NSEvent`s. What reaches the daemon is read from a recording sender.

final class ModelPopoverTests: XCTestCase {

    private let tag = "claudia"
    private var sender: ModelRequestRecorder!
    private var store: ModelStore!
    private var closes = 0
    private let windows = WindowBag()
    private var previousAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
        sender = ModelRequestRecorder()
        store = ModelStore(sender: sender, makeRequestId: { "req-1" })
        closes = 0
    }

    override func tearDown() {
        windows.tearDown()
        store = nil
        sender = nil
        NSApplication.shared.appearance = previousAppearance
        super.tearDown()
    }

    // MARK: Fixtures

    private static let allLevels = ["low", "medium", "high", "xhigh", "max"]

    private func family(_ alias: String, rank: Int, efforts: [String], resolved: String) -> ModelFamilyWire {
        ModelFamilyWire(alias: alias, displayName: alias.capitalized, resolved: resolved, efforts: efforts, rank: rank)
    }

    /// Haiku takes no effort; Sonnet takes low..high; Opus and Fable take everything.
    private func standardFamilies() -> [ModelFamilyWire] {
        [
            family("opus", rank: 3, efforts: Self.allLevels, resolved: "claude-opus-5-5"),
            family("haiku", rank: 1, efforts: [], resolved: "claude-haiku-4-5-20251001"),
            family("fable", rank: 4, efforts: Self.allLevels, resolved: "claude-fable-5-1"),
            family("sonnet", rank: 2, efforts: ["low", "medium", "high"], resolved: "claude-sonnet-5-5"),
        ]
    }

    /// A running session recorded on `model` (and `effort`), reporting the matching full name.
    private func runningState(model: String = "sonnet", effort: String? = nil) -> SessionModelStateWire {
        let full = ["sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5", "haiku": "claude-haiku-4-5-20251001",
                    "fable": "claude-fable-5-1"][model] ?? model
        return SessionModelStateWire(tag: tag, recorded: RecordedModelWire(model: model, effort: effort, source: .focus),
                                     reported: ReportedModelWire(model: full, family: model), running: true)
    }

    @discardableResult
    private func openPopup(state: SessionModelStateWire? = nil,
                           families: [ModelFamilyWire]? = nil,
                           stale: Bool = false) -> ModelPopoverViewController {
        store.connectionChanged(true)
        store.ingest(.modelCatalog(families: families ?? standardFamilies(), stale: stale, fetchedAt: nil))
        store.ingest(.sessionModelState(state ?? runningState()))
        let vc = ModelPopoverViewController(tag: tag, agentName: "claudia", store: store) { [unowned self] in self.closes += 1 }
        _ = vc.view
        return vc
    }

    private func press(_ vc: ModelPopoverViewController, _ code: UInt16, _ chars: String,
                       _ flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: 0, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        vc.view.keyDown(with: event)
    }

    private func down(_ vc: ModelPopoverViewController, _ times: Int = 1) {
        for _ in 0..<times { press(vc, 125, "\u{F701}") }
    }
    private func up(_ vc: ModelPopoverViewController, _ times: Int = 1) {
        for _ in 0..<times { press(vc, 126, "\u{F700}") }
    }
    private func returnKey(_ vc: ModelPopoverViewController) { press(vc, 36, "\r") }
    private func escape(_ vc: ModelPopoverViewController) { press(vc, 53, "\u{1B}") }
    private func tab(_ vc: ModelPopoverViewController) { press(vc, 48, "\t") }
    private func shiftTab(_ vc: ModelPopoverViewController) { press(vc, 48, "\t", .shift) }

    private func set(model: String?, effort: String?, asDefault: Bool = false) -> ModelRequestRecorder.Call {
        .set(tag: tag, model: model, effort: effort, setAsAgentDefault: asDefault, requestId: "req-1")
    }

    /// A row by index, as a failure (not a crash of the whole test bundle) when it is missing.
    private func row(_ rows: [ModelPopoverRowView], _ index: Int,
                     file: StaticString = #filePath, line: UInt = #line) throws -> ModelPopoverRowView {
        try XCTUnwrap(rows.indices.contains(index) ? rows[index] : nil, "no row at index \(index) (\(rows.count) rows)", file: file, line: line)
    }

    private func highlighted(_ rows: [ModelPopoverRowView]) -> [Int] {
        rows.enumerated().filter { $0.element.isHighlighted }.map(\.offset)
    }

    // MARK: Content

    func testModelRowsAreTheCatalogueFamiliesInCostOrderWithResolvedNames() {
        let vc = openPopup()
        XCTAssertEqual(vc.modelRowViews.map(\.titleText), ["Haiku", "Sonnet", "Opus", "Fable"])
        XCTAssertEqual(vc.modelRowViews.map(\.secondaryText),
                       ["claude-haiku-4-5-20251001", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"])
    }

    func testEffortRowsAreDefaultThenEachLevel() {
        let vc = openPopup()
        XCTAssertEqual(vc.effortRowViews.map(\.titleText), ["Default", "low", "medium", "high", "xhigh", "max"])
    }

    func testOnlyTheCurrentModelRowIsCheckedAndOnlyTheCurrentEffortRow() {
        let vc = openPopup(state: runningState(model: "opus", effort: "high"))
        XCTAssertEqual(vc.modelRowViews.map(\.showsCheckmark), [false, false, true, false])
        XCTAssertEqual(vc.effortRowViews.map(\.showsCheckmark), [false, false, false, true, false, false])
    }

    func testTheDefaultEffortRowIsCheckedWhenNoEffortIsSet() {
        let vc = openPopup(state: runningState(model: "opus", effort: nil))
        XCTAssertEqual(vc.effortRowViews.map(\.showsCheckmark), [true, false, false, false, false, false])
    }

    func testRowAccessibilityLabelsMatchThePresentationStrings() throws {
        let vc = openPopup(state: runningState(model: "opus", effort: "high"))
        XCTAssertEqual(vc.modelRowViews.map { $0.accessibilityLabel() },
                       ["Haiku, claude-haiku-4-5-20251001", "Sonnet, claude-sonnet-5-5",
                        "Opus, claude-opus-5-5, selected", "Fable, claude-fable-5-1"])
        XCTAssertEqual(try row(vc.effortRowViews, 3).accessibilityLabel(), "high, selected")
        XCTAssertEqual(vc.effortRowViews.map { $0.accessibilityLabel() ?? "" },
                       ModelPresentation.effortRows(state: store.state(for: tag), catalog: store.catalog).map(\.accessibilityLabel))
    }

    func testTheFooterCheckboxAndPostureHintArePresentButHiddenUntilLaterSlices() {
        let vc = openPopup()
        XCTAssertTrue(vc.useForNewFocusesCheckbox.isHidden)
        XCTAssertTrue(vc.postureHintLabel.isHidden)
    }

    func testTheStaleNoticeShowsOnlyWhenTheCatalogueIsStale() {
        let fresh = openPopup(stale: false)
        XCTAssertTrue(fresh.staleNoticeLabel.isHidden)

        let stale = openPopup(stale: true)
        XCTAssertFalse(stale.staleNoticeLabel.isHidden)
        XCTAssertEqual(stale.staleNoticeLabel.stringValue, "Model list may be out of date")
    }

    // MARK: Keyboard focus

    func testTheCurrentModelRowHasTheFocusWhenItOpens() {
        let vc = openPopup(state: runningState(model: "opus"))
        XCTAssertEqual(vc.focusedSection, .model)
        XCTAssertEqual(vc.focusedRowIndex, 2)
        XCTAssertEqual(highlighted(vc.modelRowViews), [2])
    }

    func testDownAndUpMoveTheHighlightAndClampAtTheEnds() {
        let vc = openPopup(state: runningState(model: "sonnet"))   // starts at index 1
        down(vc)
        XCTAssertEqual(vc.focusedRowIndex, 2)
        XCTAssertEqual(highlighted(vc.modelRowViews), [2])
        down(vc, 5)
        XCTAssertEqual(vc.focusedRowIndex, 3, "Down clamps at the last row")
        XCTAssertEqual(highlighted(vc.modelRowViews), [3])
        up(vc, 10)
        XCTAssertEqual(vc.focusedRowIndex, 0, "Up clamps at the first row")
        XCTAssertEqual(highlighted(vc.modelRowViews), [0])
        XCTAssertEqual(vc.focusedSection, .model)
    }

    func testTabMovesToTheEffortSectionOnTheCurrentEffortAndShiftTabGoesBack() {
        let vc = openPopup(state: runningState(model: "opus", effort: "high"))
        tab(vc)
        XCTAssertEqual(vc.focusedSection, .effort)
        XCTAssertEqual(vc.focusedRowIndex, 3, "it lands on the current effort row ('high' after Default, low, medium)")
        XCTAssertEqual(highlighted(vc.effortRowViews), [3])

        shiftTab(vc)
        XCTAssertEqual(vc.focusedSection, .model)
    }

    func testTabLandsOnDefaultWhenNoEffortIsSet() {
        let vc = openPopup(state: runningState(model: "opus", effort: nil))
        tab(vc)
        XCTAssertEqual(vc.focusedSection, .effort)
        XCTAssertEqual(vc.focusedRowIndex, 0)
    }

    func testArrowsInTheEffortSectionClampAtTheEnds() {
        let vc = openPopup(state: runningState(model: "opus", effort: "high"))
        tab(vc)
        up(vc, 10)
        XCTAssertEqual(vc.focusedRowIndex, 0)
        down(vc, 10)
        XCTAssertEqual(vc.focusedRowIndex, 5)
    }

    func testArrowsSkipDisabledEffortRows() {
        // A model that offers low, high and max only: medium and xhigh are disabled.
        var families = standardFamilies()
        families.append(family("gem", rank: 5, efforts: ["low", "high", "max"], resolved: "claude-gem-1"))
        let vc = openPopup(state: runningState(model: "gem", effort: nil), families: families)
        tab(vc)
        XCTAssertEqual(vc.focusedRowIndex, 0, "Default")

        down(vc); XCTAssertEqual(vc.focusedRowIndex, 1, "low")
        down(vc); XCTAssertEqual(vc.focusedRowIndex, 3, "high: medium is skipped")
        down(vc); XCTAssertEqual(vc.focusedRowIndex, 5, "max: xhigh is skipped")
        down(vc); XCTAssertEqual(vc.focusedRowIndex, 5)
        up(vc);   XCTAssertEqual(vc.focusedRowIndex, 3)
        up(vc);   XCTAssertEqual(vc.focusedRowIndex, 1)
        up(vc);   XCTAssertEqual(vc.focusedRowIndex, 0)
    }

    // MARK: Escape

    func testEscapeClosesAndSendsNothing() {
        let vc = openPopup()
        let callsBefore = sender.calls
        down(vc)
        escape(vc)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(sender.sets, [], "Escape closes with no change")
        XCTAssertEqual(sender.calls, callsBefore, "and asks the daemon for nothing")
    }

    func testEscapeFromTheEffortSectionAlsoSendsNothing() {
        let vc = openPopup()
        tab(vc)
        down(vc)
        escape(vc)
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(sender.sets, [])
    }

    // MARK: Choosing a model

    func testDownThenReturnOnAnotherModelSendsOneSwitchAndCloses() {
        let vc = openPopup(state: runningState(model: "sonnet"))
        down(vc)        // Opus
        returnKey(vc)
        XCTAssertEqual(sender.sets, [set(model: "opus", effort: nil)], "exactly one request: the model, no effort change, not the agent default")
        XCTAssertEqual(closes, 1)
    }

    func testReturnOnTheCurrentModelSendsNothingButCloses() {
        let vc = openPopup(state: runningState(model: "sonnet"))
        returnKey(vc)
        XCTAssertEqual(sender.sets, [], "choosing the model already in use does nothing")
        XCTAssertEqual(closes, 1)
    }

    // PRD: choosing the current model while a switch is pending cancels the switch. The daemon reads a
    // set of the model that is already running, with a switch waiting, as "back to what is running".
    func testChoosingTheCurrentModelWhileASwitchIsPendingSendsItSoTheDaemonCancelsTheSwitch() {
        let waiting = SessionModelStateWire(tag: tag, recorded: RecordedModelWire(model: "sonnet", source: .focus),
                                            reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                            pending: PendingModelWire(model: "opus"), phase: .waiting, running: true)
        let vc = openPopup(state: waiting)
        returnKey(vc)   // the highlight starts on the current row, Sonnet
        XCTAssertEqual(sender.sets, [set(model: "sonnet", effort: nil)])
        XCTAssertEqual(closes, 1)
    }

    func testChoosingAnotherModelWhileASwitchIsPendingReplacesTheTarget() {
        let waiting = SessionModelStateWire(tag: tag, recorded: RecordedModelWire(model: "sonnet", source: .focus),
                                            reported: ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"),
                                            pending: PendingModelWire(model: "opus"), phase: .waiting, running: true)
        let vc = openPopup(state: waiting)
        down(vc, 2)   // Sonnet -> Opus -> Fable
        returnKey(vc)
        XCTAssertEqual(sender.sets, [set(model: "fable", effort: nil)])
    }

    func testAModelThatLacksTheCurrentExplicitEffortResetsTheEffortToDefault() {
        let vc = openPopup(state: runningState(model: "opus", effort: "max"))
        up(vc)          // Sonnet: low..high, no max
        returnKey(vc)
        XCTAssertEqual(sender.sets, [set(model: "sonnet", effort: "default")])
        XCTAssertEqual(closes, 1)
    }

    func testAModelWithNoEffortSupportResetsAnExplicitEffortToDefault() {
        let vc = openPopup(state: runningState(model: "opus", effort: "low"))
        up(vc, 2)       // Haiku: no effort levels
        returnKey(vc)
        XCTAssertEqual(sender.sets, [set(model: "haiku", effort: "default")])
    }

    func testAModelThatSupportsTheCurrentEffortKeepsIt() {
        let vc = openPopup(state: runningState(model: "opus", effort: "high"))
        up(vc)          // Sonnet supports high
        returnKey(vc)
        XCTAssertEqual(sender.sets, [set(model: "sonnet", effort: nil)], "nil keeps the current effort")
    }

    // MARK: Choosing an effort

    func testChoosingAnEffortSendsThatLevelWithNoModel() {
        let vc = openPopup(state: runningState(model: "opus", effort: nil))
        tab(vc)
        down(vc, 3)     // Default, low, medium, high
        XCTAssertEqual(vc.focusedRowIndex, 3)
        returnKey(vc)
        XCTAssertEqual(sender.sets, [set(model: nil, effort: "high")])
        XCTAssertEqual(closes, 1)
    }

    func testChoosingTheDefaultEffortSendsDefault() {
        let vc = openPopup(state: runningState(model: "opus", effort: "high"))
        tab(vc)
        up(vc, 3)
        XCTAssertEqual(vc.focusedRowIndex, 0)
        returnKey(vc)
        XCTAssertEqual(sender.sets, [set(model: nil, effort: "default")])
        XCTAssertEqual(closes, 1)
    }

    func testChoosingTheCurrentEffortSendsNothingButCloses() {
        let vc = openPopup(state: runningState(model: "opus", effort: "high"))
        tab(vc)
        returnKey(vc)
        XCTAssertEqual(sender.sets, [])
        XCTAssertEqual(closes, 1)
    }

    // MARK: Disabled effort rows

    func testUnsupportedEffortRowsAreDisabledWithTheReasonInTheTooltip() throws {
        let vc = openPopup(state: runningState(model: "sonnet", effort: nil))   // low, medium, high
        let rows = vc.effortRowViews
        XCTAssertEqual(rows.map(\.isRowEnabled), [true, true, true, true, false, false])
        for row in rows where !row.isRowEnabled {
            let tip = row.toolTip ?? ""
            XCTAssertFalse(tip.isEmpty, "a disabled row says why")
            XCTAssertTrue(tip.contains("Sonnet doesn't support"), "\(row.titleText): \(tip)")
        }
        XCTAssertEqual(try row(rows, 4).toolTip, "Sonnet doesn't support xhigh effort")
    }

    func testActivatingADisabledEffortRowSendsNothing() throws {
        let vc = openPopup(state: runningState(model: "sonnet", effort: nil))
        try row(vc.effortRowViews, 5).activate()
        try row(vc.effortRowViews, 4).activate()
        XCTAssertEqual(sender.sets, [])
    }

    func testReturnOnTheCurrentEffortWhenItIsDisabledSendsNothing() {
        // Recorded effort "max" on a model that no longer offers it: Tab lands there, Return must not send it.
        let vc = openPopup(state: runningState(model: "sonnet", effort: "max"))
        tab(vc)
        XCTAssertEqual(vc.focusedSection, .effort, "precondition: Tab moved to the effort section")
        returnKey(vc)
        XCTAssertEqual(sender.sets, [])
    }

    // MARK: Clicking

    func testClickingAModelRowIsTheSameAsReturnOnIt() throws {
        let vc = openPopup(state: runningState(model: "sonnet"))
        try row(vc.modelRowViews, 2).activate()
        XCTAssertEqual(sender.sets, [set(model: "opus", effort: nil)])
        XCTAssertEqual(closes, 1)
    }

    func testClickingTheCurrentModelRowSendsNothingButCloses() throws {
        let vc = openPopup(state: runningState(model: "sonnet"))
        try row(vc.modelRowViews, 1).activate()
        XCTAssertEqual(sender.sets, [])
        XCTAssertEqual(closes, 1)
    }

    func testClickingAnEffortRowIsTheSameAsReturnOnIt() throws {
        let vc = openPopup(state: runningState(model: "opus", effort: nil))
        try row(vc.effortRowViews, 4).activate()
        XCTAssertEqual(sender.sets, [set(model: nil, effort: "xhigh")])
        XCTAssertEqual(closes, 1)
    }

    // MARK: The NSPopover wrapper

    private func anchorInVisibleWindow() -> NSView {
        let window = windows.make()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView = content
        let anchor = NSView(frame: NSRect(x: 400, y: 14, width: 80, height: 26))
        content.addSubview(anchor)
        window.orderFront(nil)
        return anchor
    }

    private func waitUntilClosed(_ popover: ModelPopover, timeout: TimeInterval = 2) {
        // NSPopover closes with an animation: isShown drops when it finishes.
        let deadline = Date().addingTimeInterval(timeout)
        while popover.isShown && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testShowingAndClosingThePopover() {
        store.connectionChanged(true)
        store.ingest(.modelCatalog(families: standardFamilies(), stale: false, fetchedAt: nil))
        store.ingest(.sessionModelState(runningState()))
        let popover = ModelPopover(tag: tag, agentName: "claudia", store: store)
        let anchor = anchorInVisibleWindow()

        XCTAssertFalse(popover.isShown)
        popover.show(relativeTo: anchor)
        XCTAssertTrue(popover.isShown)

        popover.close()
        waitUntilClosed(popover)
        XCTAssertFalse(popover.isShown)
    }

    func testChoosingARowClosesThePopover() throws {
        store.connectionChanged(true)
        store.ingest(.modelCatalog(families: standardFamilies(), stale: false, fetchedAt: nil))
        store.ingest(.sessionModelState(runningState()))
        let popover = ModelPopover(tag: tag, agentName: "claudia", store: store)
        popover.show(relativeTo: anchorInVisibleWindow())
        XCTAssertTrue(popover.isShown, "precondition")
        _ = popover.viewController.view

        try row(popover.viewController.modelRowViews, 2).activate()
        waitUntilClosed(popover)

        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(sender.sets, [set(model: "opus", effort: nil)])
    }

    func testEscapeClosesThePopoverWithoutSendingAnything() {
        store.connectionChanged(true)
        store.ingest(.modelCatalog(families: standardFamilies(), stale: false, fetchedAt: nil))
        store.ingest(.sessionModelState(runningState()))
        let popover = ModelPopover(tag: tag, agentName: "claudia", store: store)
        popover.show(relativeTo: anchorInVisibleWindow())
        XCTAssertTrue(popover.isShown, "precondition")
        _ = popover.viewController.view

        escape(popover.viewController)
        waitUntilClosed(popover)

        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(sender.sets, [])
    }

    // MARK: Legibility (bitmap)

    /// The popup's content rendered on a dark surface (the popover's own background), in a window
    /// that is NOT key, under the pinned Dark Aqua. Returns each row's measure of its title text.
    private func renderRows(_ rows: (ModelPopoverViewController) -> [ModelPopoverRowView],
                            state: SessionModelStateWire) -> [(title: String, measure: RegionLuminance)] {
        let vc = openPopup(state: state)
        let content = vc.view
        var size = content.fittingSize
        if size.width < 120 || size.height < 120 { size = vc.preferredContentSize }
        if size.width < 120 || size.height < 120 { size = NSSize(width: 280, height: 360) }
        content.frame = NSRect(origin: .zero, size: size)

        let window = windows.makeStateWindow(key: false, width: size.width, height: size.height)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(calibratedWhite: 0.15, alpha: 1).cgColor
        window.contentView = host
        host.addSubview(content)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()

        return rows(vc).map { row in
            let region = row.convert(row.bounds, to: host)
            // Prefer the row's own title label; fall back to the whole row.
            let titleLabel = Self.descendants(of: row).compactMap { $0 as? NSTextField }.first { $0.stringValue == row.titleText }
            let text = titleLabel.map { $0.convert($0.bounds, to: host) } ?? region
            return (row.titleText, measureRegion(of: host, region: region, textArea: text))
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    func testModelRowTitlesAreLegibleOnTheDarkPopupInAnInactiveWindow() {
        let measured = renderRows({ $0.modelRowViews }, state: runningState(model: "opus"))
        XCTAssertEqual(measured.count, 4)
        for (title, m) in measured {
            let ratio = modelContrastRatio(m.brightestText, m.fill)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "model row \(title): text \(m.brightestText) on \(m.fill) = \(ratio):1")
            XCTAssertGreaterThan(m.brightestText, m.fill, "model row \(title): light text on a dark row, not the reverse")
        }
    }

    func testEnabledEffortRowTitlesAreLegibleOnTheDarkPopupInAnInactiveWindow() {
        let measured = renderRows({ $0.effortRowViews.filter(\.isRowEnabled) }, state: runningState(model: "sonnet", effort: "high"))
        XCTAssertEqual(measured.count, 4, "Default, low, medium, high")
        for (title, m) in measured {
            let ratio = modelContrastRatio(m.brightestText, m.fill)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "effort row \(title): text \(m.brightestText) on \(m.fill) = \(ratio):1")
            XCTAssertGreaterThan(m.brightestText, m.fill, "effort row \(title): light text on a dark row")
        }
    }

    func testDisabledEffortRowTitlesAreStillLegibleNotDarkOnDark() {
        let measured = renderRows({ $0.effortRowViews.filter { !$0.isRowEnabled } }, state: runningState(model: "sonnet", effort: nil))
        XCTAssertEqual(measured.count, 2, "xhigh and max are disabled for Sonnet")
        for (title, m) in measured {
            let ratio = modelContrastRatio(m.brightestText, m.fill)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "disabled effort row \(title): text \(m.brightestText) on \(m.fill) = \(ratio):1; the reason is in the tooltip, the row must still be readable")
        }
    }
}
