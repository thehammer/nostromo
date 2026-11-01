import XCTest
import AppKit
import NostromoKit

// BA3: the Background activity popover (PRD "The popover", Phase 1, Phase 7 keyboard and announcements).
//
// A store holds a fixture: two running tasks (a subagent and the shell it started), three ended
// (completed, failed, stopped) and one housekeeping task. The popover is read the way a person sees it:
// the header, the sections in order, the rows' text, colours and indentation, the keyboard (arrows, Return,
// left and right for Housekeeping, Esc), the context menu, Copy Description into an injected pasteboard,
// live updates in place, the one-second elapsed tick (a manual scheduler and an injected store clock),
// the height cap with the list scrolling inside, VoiceOver announcements (captured), and "opened once
// means seen" on the chip.
//
// No wall clock, no real pasteboard or UserDefaults, no daemon. Real `NSPopover`s are shown only in the
// tests that need one (live updates, ticks, announcements, keyboard); the rest read the view controller.

private final class BA3UIActionSpy: BackgroundTaskActions {
    var openable = true
    var stoppable = true
    var transcriptable = true
    private(set) var opened: [String] = []
    private(set) var openedTags: [String] = []
    private(set) var stopped: [String] = []
    private(set) var shown: [String] = []

    func canOpen(_ row: BackgroundTaskRow, tag: String) -> Bool { openable }
    func open(_ row: BackgroundTaskRow, tag: String) {
        opened.append(row.id)
        openedTags.append(tag)
    }
    func canStop(_ row: BackgroundTaskRow, tag: String) -> Bool { stoppable }
    func stop(_ row: BackgroundTaskRow, tag: String) { stopped.append(row.id) }
    func canShowInTranscript(_ row: BackgroundTaskRow, tag: String) -> Bool { transcriptable }
    func showInTranscript(_ row: BackgroundTaskRow, tag: String) { shown.append(row.id) }
}

/// Actions that can show only some rows in the transcript (BA6c: a pane holds some tasks' calls and not others').
private final class BA6cRowActions: BackgroundTaskActions {
    var showable: Set<String> = []
    private(set) var shown: [String] = []
    private(set) var shownTags: [String] = []
    private(set) var asked: [String] = []

    func canShowInTranscript(_ row: BackgroundTaskRow, tag: String) -> Bool {
        asked.append(row.id)
        return showable.contains(row.id)
    }

    func showInTranscript(_ row: BackgroundTaskRow, tag: String) {
        shown.append(row.id)
        shownTags.append(tag)
    }
}

private final class BA3UIFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

final class BackgroundPopoverTests: XCTestCase {

    private let tag = "claudia"
    private var world: BA3UIWorld!
    private var ticks: BA3UITickScheduler!
    private var announcements: [String] = []
    private var pasteboard: NSPasteboard!
    private var popovers: [BackgroundPopover] = []
    private var bars: [ReplInputBar] = []
    private var closeCount = 0
    private var previousAppearance: NSAppearance?

    override func setUp() {
        super.setUp()
        previousAppearance = NSApplication.shared.appearance
        AppAppearance.apply(to: NSApplication.shared)
        world = BA3UIWorld(self)
        ticks = BA3UITickScheduler()
        announcements = []
        popovers = []
        bars = []
        closeCount = 0
        let board = NSPasteboard(name: NSPasteboard.Name("BA3-\(UUID().uuidString)"))
        pasteboard = board
        addTeardownBlock { board.releaseGlobally() }
    }

    override func tearDown() {
        popovers.forEach { $0.close() }
        bars.forEach { $0.backgroundPopover?.close() }
        popovers = []
        bars = []
        NSApplication.shared.appearance = previousAppearance
        world = nil
        ticks = nil
        super.tearDown()
    }

    // MARK: Helpers

    private func ingest(_ tasks: [TaskMetaWire], advance: TimeInterval = 1) {
        world.ingest(tasks, tag: tag, advance: advance)
    }

    /// The fixture, delivered without moving the clock (the agent has run 2 m 05 s).
    private func loadFixture() {
        ingest(world.fixture(), advance: 0)
        world.detail("child", tag: tag, preview: "build: 3/7 jobs passed", advance: 0)
    }

    private func makeController(actions: BackgroundTaskActions = NoBackgroundTaskActions.shared) -> BackgroundPopoverViewController {
        let vc = BackgroundPopoverViewController(tag: tag, displayName: "Claudia", store: world.store, actions: actions,
                                                 pasteboard: pasteboard, announce: { [weak self] in self?.announcements.append($0) })
        _ = vc.view
        return vc
    }

    @discardableResult
    private func press(_ vc: BackgroundPopoverViewController, _ code: UInt16) -> Bool {
        vc.handleKey(BA3UIKey.keyDown(code))
    }

    private func rowView(_ vc: BackgroundPopoverViewController, _ id: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> BackgroundTaskRowView {
        try XCTUnwrap(vc.visibleRowViews.first { $0.row.id == id },
                      "no visible row \(id); rows: \(vc.visibleRowViews.map { $0.row.id })", file: file, line: line)
    }

    private func visibleIds(_ vc: BackgroundPopoverViewController) -> [String] {
        vc.visibleRowViews.map { $0.row.id }
    }

    private func makeAnchor() -> (window: RigWindow, anchor: NSView, focus: NSView) {
        let window = ba3uiVisibleWindow(self)
        let content = window.contentView!
        let focus = BA3UIFocusView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        content.addSubview(focus)
        let anchor = NSView(frame: NSRect(x: 400, y: 14, width: 80, height: 26))
        content.addSubview(anchor)
        _ = window.makeFirstResponder(focus)
        return (window, anchor, focus)
    }

    @discardableResult
    private func openPopover(anchor: NSView, takeKeyboard: Bool = false,
                             actions: BackgroundTaskActions = NoBackgroundTaskActions.shared) -> BackgroundPopover {
        let ticks = self.ticks!
        let popover = BackgroundPopover(tag: tag, displayName: "Claudia", store: world.store, actions: actions,
                                        pasteboard: pasteboard,
                                        schedule: { delay, fire in ticks.schedule(delay, fire) },
                                        announce: { [weak self] in self?.announcements.append($0) })
        popover.onDidClose = { [weak self] in self?.closeCount += 1 }
        popovers.append(popover)
        popover.show(relativeTo: anchor, takeKeyboard: takeKeyboard)
        XCTAssertTrue(popover.isShown, "precondition: the popover is on screen")
        return popover
    }

    /// NSPopover finishes closing on a later run-loop turn. A bounded number of turns, never of seconds.
    private func waitForClose(_ times: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        modelWaitUntil(file: file, line: line) { self.closeCount >= times }
    }

    // MARK: Header and sections

    func testTheHeaderNamesTheFocusAndCountsWhatIsRunning() {
        loadFixture()
        let vc = makeController()

        XCTAssertEqual(vc.headerTitle.stringValue, "Background activity: Claudia")
        XCTAssertEqual(vc.headerCount.stringValue, "2 running")
    }

    func testSectionsAreRunningThenEndedThenACollapsedHousekeeping() throws {
        loadFixture()
        let vc = makeController()

        XCTAssertEqual(visibleIds(vc), ["agent", "child", "built", "explore", "dev"], "running (parent, child), then ended newest first; no housekeeping row yet")
        XCTAssertEqual(vc.visibleRowViews.map { $0.row.section }, [.running, .running, .ended, .ended, .ended])

        let ended = try XCTUnwrap(vc.endedHeaderView)
        XCTAssertEqual(ended.text, "Ended")
        let housekeeping = try XCTUnwrap(vc.housekeepingHeaderView)
        XCTAssertEqual(housekeeping.text, "\u{25B8} Housekeeping (1)")

        let child = try rowView(vc, "child"), built = try rowView(vc, "built"), dev = try rowView(vc, "dev")
        XCTAssertGreaterThanOrEqual(ended.frame.minY, child.frame.maxY - 0.5, "`Ended` sits below the running rows")
        XCTAssertLessThanOrEqual(ended.frame.maxY, built.frame.minY + 0.5, "and above the ended rows")
        XCTAssertGreaterThanOrEqual(housekeeping.frame.minY, dev.frame.maxY - 0.5, "Housekeeping is last")
    }

    func testHousekeepingRowsAppearOnRightArrowAndGoOnLeftArrow() throws {
        loadFixture()
        let vc = makeController()
        XCTAssertFalse(vc.housekeepingExpanded)
        XCTAssertFalse(visibleIds(vc).contains("chore"))

        XCTAssertTrue(press(vc, BA3UIKey.right))
        XCTAssertTrue(vc.housekeepingExpanded)
        XCTAssertEqual(visibleIds(vc).last, "chore", "the housekeeping row shows below the rest")
        XCTAssertEqual(vc.housekeepingHeaderView?.text, "\u{25BE} Housekeeping (1)")

        XCTAssertTrue(press(vc, BA3UIKey.left))
        XCTAssertFalse(vc.housekeepingExpanded)
        XCTAssertFalse(visibleIds(vc).contains("chore"))
        XCTAssertEqual(vc.housekeepingHeaderView?.text, "\u{25B8} Housekeeping (1)")
    }

    func testClickingTheHousekeepingHeaderOrReturnOnItTogglesIt() throws {
        loadFixture()
        let vc = makeController()
        let header = try XCTUnwrap(vc.housekeepingHeaderView)

        header.onClick?()
        XCTAssertTrue(vc.housekeepingExpanded)
        XCTAssertTrue(visibleIds(vc).contains("chore"))
        header.onClick?()
        XCTAssertFalse(vc.housekeepingExpanded)

        // Return with the header selected does the same (and never "opens" anything).
        vc.select(vc.selectables.count - 1)
        XCTAssertNil(vc.selectedRow, "the header is selected, not a task")
        press(vc, BA3UIKey.returnKey)
        XCTAssertTrue(vc.housekeepingExpanded)
    }

    func testHousekeepingIsNotCountedInTheHeader() {
        loadFixture()
        let vc = makeController()
        XCTAssertEqual(vc.headerCount.stringValue, "2 running", "the housekeeping task is running too, and is not counted")
        XCTAssertEqual(vc.list.chip, .running(2))
    }

    // MARK: Rows

    func testAChildRowIsIndentedUnderItsParent() throws {
        loadFixture()
        let vc = makeController()
        let agent = try rowView(vc, "agent"), child = try rowView(vc, "child"), built = try rowView(vc, "built")

        XCTAssertEqual(agent.indentation, 0, accuracy: 0.5)
        XCTAssertGreaterThan(child.indentation, agent.indentation, "the shell the subagent started is indented under it")
        XCTAssertEqual(built.indentation, 0, accuracy: 0.5, "ended rows are flat")
        XCTAssertLessThan(agent.frame.minY, child.frame.minY, "the child is directly under its parent")
    }

    func testARowReadsKindTitleStatusTimeAndSignOfLife() throws {
        loadFixture()
        let vc = makeController()
        let agent = try rowView(vc, "agent"), child = try rowView(vc, "child"), built = try rowView(vc, "built")

        XCTAssertEqual(agent.kindText, "Agent")
        XCTAssertEqual(agent.titleText, "redd \u{00B7} Write failing tests for the chip")
        XCTAssertEqual(agent.statusText, "running")
        XCTAssertEqual(agent.timeText, "2 m 05 s")
        XCTAssertTrue(agent.signOfLifeText.contains("tokens") && agent.signOfLifeText.contains("11 tools") && agent.signOfLifeText.contains("Edit"),
                      "tokens, tool uses and the tool in use: \(agent.signOfLifeText)")

        XCTAssertEqual(child.kindText, "Shell")
        XCTAssertEqual(child.signOfLifeText, "last: build: 3/7 jobs passed")

        XCTAssertEqual(built.statusText, "completed")
        XCTAssertEqual(built.timeText, "1 m 12 s", "an ended task shows how long it ran")
        XCTAssertEqual(built.endedAgoText, "\u{00B7} 4 m ago")
        XCTAssertEqual(built.signOfLifeText, "", "no sign of life is not shown as an empty line")
        XCTAssertLessThan(built.frame.height, agent.frame.height, "a row without a second line is one line tall")
    }

    func testOnlyAFailedStatusIsInTheFailureColour() throws {
        loadFixture()
        let vc = makeController()
        let failed = try rowView(vc, "explore")
        XCTAssertEqual(failed.statusText, "failed")
        XCTAssertEqual(failed.iconText, "\u{2715}")
        XCTAssertEqual(failed.statusColor, Theme.foldFailure)

        for id in ["agent", "built", "dev"] {
            let row = try rowView(vc, id)
            XCTAssertNotEqual(row.statusColor, Theme.foldFailure, "\(id) did not fail")
        }
        XCTAssertEqual(try rowView(vc, "dev").statusText, "stopped")
        XCTAssertEqual(try rowView(vc, "dev").iconText, "\u{25A0}")
    }

    func testRowsAreVoiceOverElementsReadingKindDescriptionStatusAndElapsed() throws {
        loadFixture()
        let vc = makeController()

        let agent = try rowView(vc, "agent")
        XCTAssertTrue(agent.isAccessibilityElement())
        let agentLabel = try XCTUnwrap(agent.accessibilityLabel())
        for part in ["Agent", "Write failing tests for the chip", "running", "2 m 05 s"] {
            XCTAssertTrue(agentLabel.contains(part), "`\(agentLabel)` should say `\(part)`")
        }

        let built = try XCTUnwrap(try rowView(vc, "built").accessibilityLabel())
        for part in ["Shell", "npm run build", "completed", "1 m 12 s"] {
            XCTAssertTrue(built.contains(part), "`\(built)` should say `\(part)`")
        }
    }

    func testTheTooltipIsTheFullDescription() throws {
        let long = "Watch CI for PR #251 and report the first failing job together with the last lines of its log output"
        ingest([world.task("mon", kind: .monitor, long, startedAgo: 30)], advance: 0)
        let vc = makeController()
        XCTAssertEqual(try rowView(vc, "mon").toolTip, long)
    }

    func testAnEmptyListSaysSoAndAFullOneDoesNot() {
        let empty = makeController()
        XCTAssertTrue(empty.isShowingEmptyState)
        XCTAssertEqual(empty.headerCount.stringValue, "0 running")
        XCTAssertTrue(empty.visibleRowViews.isEmpty)

        loadFixture()
        empty.reload()
        XCTAssertFalse(empty.isShowingEmptyState)
        XCTAssertEqual(empty.visibleRowViews.count, 5)
    }

    // MARK: Keyboard

    func testDownAndUpMoveTheSelectionAndClampAtTheEnds() {
        loadFixture()
        let vc = makeController()
        XCTAssertNil(vc.selectedIndex, "nothing is selected until the keyboard is used")
        XCTAssertEqual(vc.selectables.count, 6, "five rows and the Housekeeping header")

        XCTAssertTrue(press(vc, BA3UIKey.down))
        XCTAssertEqual(vc.selectedIndex, 0)
        XCTAssertEqual(vc.selectedRow?.id, "agent")
        XCTAssertEqual(vc.visibleRowViews.filter(\.isSelected).map { $0.row.id }, ["agent"])

        press(vc, BA3UIKey.down)
        XCTAssertEqual(vc.selectedRow?.id, "child")

        for _ in 0 ..< 10 { press(vc, BA3UIKey.down) }
        XCTAssertEqual(vc.selectedIndex, vc.selectables.count - 1, "Down clamps at the last item")
        XCTAssertEqual(vc.housekeepingHeaderView?.isSelected, true)

        for _ in 0 ..< 10 { press(vc, BA3UIKey.up) }
        XCTAssertEqual(vc.selectedIndex, 0, "Up clamps at the first item")
        XCTAssertEqual(vc.selectedRow?.id, "agent")
    }

    func testReturnOpensTheSelectedRowOnlyWhenItCanBeOpened() {
        loadFixture()
        let spy = BA3UIActionSpy()
        let vc = makeController(actions: spy)

        press(vc, BA3UIKey.down)
        press(vc, BA3UIKey.returnKey)
        XCTAssertEqual(spy.opened, ["agent"])
        XCTAssertEqual(spy.openedTags, [tag])

        press(vc, BA3UIKey.down); press(vc, BA3UIKey.down)
        press(vc, BA3UIKey.returnKey)
        XCTAssertEqual(spy.opened, ["agent", "built"])

        spy.openable = false
        press(vc, BA3UIKey.returnKey)
        XCTAssertEqual(spy.opened, ["agent", "built"], "a row that cannot be opened is not opened")
    }

    func testReturnWithNoActionsDoesNothingAndKeepsTheSelection() {
        loadFixture()
        let vc = makeController()   // the default, no-op actions
        press(vc, BA3UIKey.down)

        XCTAssertTrue(press(vc, BA3UIKey.returnKey), "the key is still the popover's")
        XCTAssertEqual(vc.selectedRow?.id, "agent")
        XCTAssertFalse(vc.housekeepingExpanded)
    }

    func testClickingARowOpensItOnlyWhenItCanBeOpened() throws {
        loadFixture()
        let spy = BA3UIActionSpy()
        let vc = makeController(actions: spy)
        let built = try rowView(vc, "built")

        built.onClick?(built)
        XCTAssertEqual(spy.opened, ["built"])
        XCTAssertEqual(vc.selectedRow?.id, "built", "the clicked row is the selection")

        spy.openable = false
        let dev = try rowView(vc, "dev")
        dev.onClick?(dev)
        XCTAssertEqual(spy.opened, ["built"])
    }

    // MARK: Context menu and Copy Description

    func testTheContextMenuIsJustCopyDescriptionWhenNothingElseIsAvailable() throws {
        loadFixture()
        let vc = makeController()
        let menu = vc.contextMenu(for: try rowView(vc, "agent").row)
        XCTAssertEqual(menu.items.map(\.title), ["Copy Description"])
    }

    func testOpenStopAndShowInTranscriptAppearOnlyWhenTheActionsEnableThem() throws {
        loadFixture()
        let spy = BA3UIActionSpy()
        let vc = makeController(actions: spy)
        let row = try rowView(vc, "agent").row

        XCTAssertEqual(vc.contextMenu(for: row).items.map(\.title), ["Open", "Stop", "Copy Description", "Show in Transcript"])

        spy.stoppable = false; spy.transcriptable = false
        XCTAssertEqual(vc.contextMenu(for: row).items.map(\.title), ["Open", "Copy Description"])
        spy.openable = false; spy.stoppable = true
        XCTAssertEqual(vc.contextMenu(for: row).items.map(\.title), ["Stop", "Copy Description"])
        spy.stoppable = false; spy.transcriptable = true
        XCTAssertEqual(vc.contextMenu(for: row).items.map(\.title), ["Copy Description", "Show in Transcript"])
    }

    func testChoosingMenuItemsRunsTheActionsOnThatRow() throws {
        loadFixture()
        let spy = BA3UIActionSpy()
        let vc = makeController(actions: spy)
        let menu = vc.contextMenu(for: try rowView(vc, "child").row)

        menu.performActionForItem(at: 0)   // Open
        menu.performActionForItem(at: 1)   // Stop
        menu.performActionForItem(at: 3)   // Show in Transcript

        XCTAssertEqual(spy.opened, ["child"])
        XCTAssertEqual(spy.stopped, ["child"])
        XCTAssertEqual(spy.shown, ["child"])
    }

    // BA6c: Show in Transcript is per row. A pane holds the call that started some tasks and not others
    // (it may be far back, or from an earlier session), so the offer follows the row and is asked again each time.

    func testShowInTranscriptIsOfferedOnlyForTheRowsTheActionsCanShow() throws {
        loadFixture()
        let actions = BA6cRowActions()
        actions.showable = ["built", "child"]
        let vc = makeController(actions: actions)

        for id in ["agent", "child", "built", "explore", "dev"] {
            let titles = vc.contextMenu(for: try rowView(vc, id).row).items.map(\.title)
            XCTAssertEqual(titles.contains("Show in Transcript"), actions.showable.contains(id), "row \(id): \(titles)")
            XCTAssertTrue(titles.contains("Copy Description"), "row \(id) keeps its other items")
        }
    }

    func testChoosingShowInTranscriptRunsTheActionOnThatRowAndTagOnly() throws {
        loadFixture()
        let actions = BA6cRowActions()
        actions.showable = ["built", "child"]
        let vc = makeController(actions: actions)
        let menu = vc.contextMenu(for: try rowView(vc, "built").row)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Show in Transcript" })

        XCTAssertTrue(actions.shown.isEmpty, "building the menu shows nothing")
        menu.performActionForItem(at: index)

        XCTAssertEqual(actions.shown, ["built"])
        XCTAssertEqual(actions.shownTags, [tag])
    }

    func testTheOfferIsAskedAgainEachTimeTheMenuIsBuilt() throws {
        loadFixture()
        let actions = BA6cRowActions()
        let vc = makeController(actions: actions)
        let row = try rowView(vc, "built").row
        XCTAssertFalse(vc.contextMenu(for: row).items.map(\.title).contains("Show in Transcript"), "the pane holds nothing yet")

        actions.showable = ["built"]
        XCTAssertTrue(vc.contextMenu(for: row).items.map(\.title).contains("Show in Transcript"), "now it does")

        actions.showable = []
        XCTAssertFalse(vc.contextMenu(for: row).items.map(\.title).contains("Show in Transcript"), "and now it is gone again")
        XCTAssertEqual(actions.asked.filter { $0 == "built" }.count, 3, "asked once per menu")
    }

    func testRightClickingARowShowsItsContextMenu() throws {
        loadFixture()
        let vc = makeController()
        let row = try rowView(vc, "agent")
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertEqual(row.menu(for: event)?.items.map(\.title), ["Copy Description"])
    }

    func testCopyDescriptionWritesTheRowsFullDescriptionToTheInjectedPasteboard() throws {
        let description = "Watch CI for PR #251 and report the first failing job\nwith the last lines of its log output, however long that is"
        ingest([world.task("mon", kind: .monitor, description, startedAgo: 30)], advance: 0)
        let vc = makeController()
        let row = try rowView(vc, "mon").row
        pasteboard.clearContents()
        pasteboard.setString("something older", forType: .string)

        let menu = vc.contextMenu(for: row)
        let copyIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "Copy Description" })
        menu.performActionForItem(at: copyIndex)

        XCTAssertEqual(pasteboard.string(forType: .string), description, "the verbatim description, not the one-line title")
    }

    // MARK: Live updates

    func testANewSnapshotUpdatesTheOpenPopoverInPlaceWithoutReopening() throws {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor)
        let vc = popover.viewController
        let agentView = try rowView(vc, "agent"), childView = try rowView(vc, "child")
        let signBefore = agentView.signOfLifeText
        let reloads = vc.reloadCount

        ingest([
            world.task("agent", kind: .agent, "Write failing tests for the chip", startedAgo: 125,
                       subagentType: "redd", tokens: 25_000, toolUses: 14, lastTool: "Bash"),
            world.task("child", "cargo test -p nostromo", status: .completed, startedAgo: 40, endedAgo: -1, parent: "agent"),
            world.task("extra", "cargo clippy", startedAgo: -0.5),
        ])

        XCTAssertTrue(popover.isShown, "no reopening")
        XCTAssertTrue(popover.viewController === vc)
        XCTAssertGreaterThan(vc.reloadCount, reloads, "the list was refreshed from the store")
        XCTAssertEqual(vc.list.running.map(\.id), ["extra", "agent"])
        XCTAssertEqual(vc.headerCount.stringValue, "2 running")
        XCTAssertTrue(try rowView(vc, "agent") === agentView, "the same row view for the same task")
        XCTAssertTrue(try rowView(vc, "child") === childView, "even when it moved from running to ended")
        XCTAssertNotEqual(agentView.signOfLifeText, signBefore)
        XCTAssertTrue(agentView.signOfLifeText.contains("Bash"), agentView.signOfLifeText)
        XCTAssertEqual(childView.statusText, "completed")
        XCTAssertEqual(childView.row.section, .ended)
        XCTAssertEqual(visibleIds(vc).first, "extra", "the new task is listed, newest running first")
    }

    func testTenSnapshotsInARowNeverGrowThePopoverPastItsMaximumHeightAndTheListScrollsInside() throws {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor)
        let vc = popover.viewController

        for n in 1 ... 10 {
            ingest(world.running(n * 3))
            XCTAssertLessThanOrEqual(vc.preferredContentSize.height, BackgroundPopoverViewController.maxHeight + 0.001,
                                     "snapshot \(n): \(n * 3) tasks")
        }

        XCTAssertEqual(vc.preferredContentSize.height, BackgroundPopoverViewController.maxHeight, accuracy: 0.5,
                       "thirty rows fill the popover to its maximum")
        vc.view.layoutSubtreeIfNeeded()
        let document = try XCTUnwrap(vc.scrollView.documentView)
        let clip = vc.scrollView.contentView
        XCTAssertGreaterThan(document.frame.height, vc.preferredContentSize.height, "the list is taller than the popover, so it scrolls")
        XCTAssertGreaterThan(document.frame.height, clip.bounds.height, "and taller than its own viewport")

        clip.scroll(to: NSPoint(x: 0, y: 120))
        vc.scrollView.reflectScrolledClipView(clip)
        XCTAssertEqual(clip.bounds.origin.y, 120, accuracy: 1, "the list scrolled inside the popover")

        ingest(world.running(31))
        XCTAssertEqual(clip.bounds.origin.y, 120, accuracy: 0.5, "an update does not throw the reader back to the top")
        XCTAssertLessThanOrEqual(vc.preferredContentSize.height, BackgroundPopoverViewController.maxHeight + 0.001)
    }

    func testAShortListIsAsTallAsItsContentAndNoTaller() {
        loadFixture()
        let vc = makeController()
        XCTAssertLessThan(vc.preferredContentSize.height, BackgroundPopoverViewController.maxHeight)
        XCTAssertEqual(vc.preferredContentSize.width, BackgroundPopoverViewController.width)
    }

    // MARK: Ticks

    func testWhileSomethingRunsOneOneSecondTickIsHeldAndFiringItRefreshesTheElapsedText() throws {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor)
        let vc = popover.viewController
        XCTAssertEqual(ticks.pendingCount, 1, "exactly one tick is waiting")
        XCTAssertEqual(ticks.pendingDelays, [1], "one second")
        XCTAssertEqual(try rowView(vc, "agent").timeText, "2 m 05 s")

        world.clock.advance(10)
        XCTAssertTrue(ticks.fireNext())

        XCTAssertEqual(try rowView(vc, "agent").timeText, "2 m 15 s", "the elapsed text moved with the store's clock")
        XCTAssertEqual(try rowView(vc, "child").timeText, "50.0 s")
        XCTAssertEqual(popover.tickCount, 1)
        XCTAssertEqual(ticks.pendingCount, 1, "and the next tick is already waiting")

        world.clock.advance(5)
        XCTAssertTrue(ticks.fireNext())
        XCTAssertEqual(try rowView(vc, "agent").timeText, "2 m 20 s")
        XCTAssertEqual(popover.tickCount, 2)
    }

    func testStoreChangesNeverStackUpTicks() {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        openPopover(anchor: anchor)

        for n in 1 ... 5 { ingest(world.running(n)) }

        XCTAssertEqual(ticks.pendingCount, 1, "one tick waits, however many changes arrived")
    }

    func testNoTickIsScheduledWhenNothingRuns() {
        ingest([world.task("built", "npm run build", status: .completed, startedAgo: 312, endedAgo: 240, durationMs: 72_000)], advance: 0)
        let (_, anchor, _) = makeAnchor()
        openPopover(anchor: anchor)

        XCTAssertEqual(ticks.pendingCount, 0)
        XCTAssertTrue(ticks.requestedDelays.isEmpty)
    }

    func testTheTickStopsWhenTheLastTaskEndsAndResumesWhenOneStarts() {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        openPopover(anchor: anchor)
        XCTAssertEqual(ticks.pendingCount, 1, "precondition")

        ingest([
            world.task("agent", kind: .agent, "Write failing tests for the chip", status: .completed, startedAgo: 125, endedAgo: -1,
                       subagentType: "redd"),
            world.task("child", "cargo test -p nostromo", status: .completed, startedAgo: 40, endedAgo: -1, parent: "agent"),
        ])
        XCTAssertEqual(ticks.pendingCount, 0, "nothing runs, nothing ticks")

        ingest([world.task("again", "cargo test", startedAgo: -2)])
        XCTAssertEqual(ticks.pendingCount, 1)
    }

    func testNoTickIsHeldOrDeliveredAfterTheListCloses() {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor)
        XCTAssertEqual(ticks.pendingCount, 1, "precondition")

        popover.close()
        waitForClose()

        XCTAssertFalse(popover.isShown)
        XCTAssertEqual(ticks.pendingCount, 0)
        XCTAssertFalse(ticks.fireNext())
        let before = popover.tickCount
        ingest(world.running(3))
        XCTAssertEqual(ticks.pendingCount, 0, "a closed popover does not follow the store")
        XCTAssertEqual(popover.tickCount, before)
    }

    // MARK: Announcements

    func testATaskThatFailsWhileTheListIsOpenIsAnnouncedOnceAndNothingElseIs() {
        let build = world.task("build", "npm run build", startedAgo: 60)
        let test = world.task("test", "cargo test", startedAgo: 50)
        ingest([build, test], advance: 0)
        let (_, anchor, _) = makeAnchor()
        openPopover(anchor: anchor)
        XCTAssertTrue(announcements.isEmpty, "opening announces nothing")

        ingest([build, world.task("test", "cargo test", status: .completed, startedAgo: 50, endedAgo: -1)])
        XCTAssertTrue(announcements.isEmpty, "a task completing is not announced")

        ingest([world.task("build", "npm run build", status: .failed, startedAgo: 60, endedAgo: -2),
                world.task("test", "cargo test", status: .completed, startedAgo: 50, endedAgo: -1)])
        XCTAssertEqual(announcements.count, 1, "the failure is announced once: \(announcements)")
        XCTAssertTrue(announcements.first?.contains("npm run build") ?? false, "and says which task: \(announcements)")

        ingest([world.task("build", "npm run build", status: .failed, startedAgo: 60, endedAgo: -2),
                world.task("test", "cargo test", status: .completed, startedAgo: 50, endedAgo: -1),
                world.task("lint", "cargo clippy", startedAgo: -3)])
        XCTAssertEqual(announcements.count, 1, "a task that is still failed is not announced again")

        ingest([world.task("build", "npm run build", status: .failed, startedAgo: 60, endedAgo: -2),
                world.task("test", "cargo test", status: .completed, startedAgo: 50, endedAgo: -1),
                world.task("lint", "cargo clippy", status: .stopped, startedAgo: -3, endedAgo: -4)])
        XCTAssertEqual(announcements.count, 1, "a task being stopped is not announced")
    }

    func testNothingIsAnnouncedOnceTheListIsClosed() {
        let build = world.task("build", "npm run build", startedAgo: 60)
        ingest([build], advance: 0)
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor)
        popover.close()
        waitForClose()

        ingest([world.task("build", "npm run build", status: .failed, startedAgo: 60, endedAgo: -1)])

        XCTAssertTrue(announcements.isEmpty)
    }

    // MARK: Opened means seen

    func testOpeningTheListHidesTheFailedChipAndANewFailureBringsItBack() {
        let window = ba3uiVisibleWindow(self)
        let bar = ba3uiMakeBar(in: window, store: world.store, displayName: "Claudia")
        bars.append(bar)
        world.ingest([world.task("build", "npm run build", status: .failed, startedAgo: 60, endedAgo: 1)])
        XCTAssertEqual(bar.backgroundChip.chipState, .failed(1), "precondition")
        XCTAssertEqual(bar.backgroundChip.title, "\u{2715} 1 failed")

        world.clock.advance(1)
        bar.toggleBackgroundPopover(takeKeyboard: false)

        XCTAssertTrue(bar.backgroundPopover?.isShown ?? false)
        XCTAssertEqual(bar.backgroundChip.chipState, .hidden, "opening the list is looking at it")
        XCTAssertTrue(bar.backgroundChip.isHidden)

        bar.backgroundPopover?.close()
        modelWaitUntil { bar.backgroundPopover == nil }
        XCTAssertTrue(bar.backgroundChip.isHidden, "and it stays hidden")

        world.ingest([world.task("build", "npm run build", status: .failed, startedAgo: 60, endedAgo: 1),
                      world.task("lint", "cargo clippy", status: .failed, startedAgo: 30, endedAgo: -50)])
        XCTAssertEqual(bar.backgroundChip.chipState, .failed(1), "a failure after the last look shows again")
    }

    func testTheListOpensFromAHiddenChipToo() {
        let window = ba3uiVisibleWindow(self)
        let bar = ba3uiMakeBar(in: window, store: world.store, displayName: "Claudia")
        bars.append(bar)
        XCTAssertTrue(bar.backgroundChip.isHidden, "precondition: nothing to report")

        bar.showBackgroundPopover(nil)

        XCTAssertTrue(bar.backgroundPopover?.isShown ?? false, "shift-command-B with nothing running still opens the (empty) list")
        XCTAssertEqual(bar.backgroundPopover?.viewController.isShowingEmptyState, true)
    }

    // MARK: Esc and the keyboard

    func testEscapeThroughTheKeyMonitorClosesTheListAndIsConsumedOtherKeysPassOn() {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor)

        for (name, event) in [("a", BA3UIKey.keyDown(0, "a")), ("down", BA3UIKey.keyDown(BA3UIKey.down)),
                              ("return", BA3UIKey.keyDown(BA3UIKey.returnKey)),
                              ("esc key-up", BA3UIKey.event(.keyUp, BA3UIKey.escape))] {
            XCTAssertTrue(popover.handleMonitoredKey(event) === event, "\(name) goes on unchanged")
            XCTAssertTrue(popover.isShown, "\(name) does not close the list")
        }

        let escape = BA3UIKey.keyDown(BA3UIKey.escape)
        XCTAssertNil(popover.handleMonitoredKey(escape), "Esc is consumed")
        waitForClose()
        XCTAssertFalse(popover.isShown)

        let later = BA3UIKey.keyDown(BA3UIKey.escape)
        XCTAssertTrue(popover.handleMonitoredKey(later) === later, "with the list closed, Esc is nobody's here")
    }

    func testOpenedFromTheKeyboardTakesTheKeyboardAndSelectsTheFirstRow() throws {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor, takeKeyboard: true)
        let vc = popover.viewController

        XCTAssertTrue(popover.tookKeyboard)
        XCTAssertEqual(vc.selectedIndex, 0)
        XCTAssertEqual(vc.selectedRow?.id, "agent")
        let content = vc.contentView
        let window = try XCTUnwrap(content.window, "the popover has a window")
        XCTAssertTrue(window.firstResponder === content, "the list is the first responder of its own window")
    }

    func testOpenedByAClickLeavesTheKeyboardWhereItWas() {
        loadFixture()
        let (window, anchor, focus) = makeAnchor()
        let popover = openPopover(anchor: anchor, takeKeyboard: false)

        XCTAssertFalse(popover.tookKeyboard)
        XCTAssertNil(popover.viewController.selectedIndex, "no keyboard, no selection ring")
        XCTAssertTrue(window.firstResponder === focus, "the responder the window had is the responder it has")
    }

    // MARK: Where the keyboard goes when the list closes

    /// A second place the keyboard can be in the anchor's window (another pane's composer, say).
    private func addOtherResponder(to window: NSWindow) -> NSView {
        let other = BA3UIFocusView(frame: NSRect(x: 150, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(other)
        return other
    }

    func testAClickOpenedListThatClosesAfterTheUserClickedIntoAnotherResponderLeavesTheKeyboardThere() {
        loadFixture()
        let (window, anchor, focus) = makeAnchor()
        let other = addOtherResponder(to: window)
        let popover = openPopover(anchor: anchor, takeKeyboard: false)
        XCTAssertTrue(window.firstResponder === focus, "precondition: the click did not move the keyboard")

        // The click outside that closes the list landed in another responder first.
        XCTAssertTrue(window.makeFirstResponder(other), "precondition")
        popover.close()
        waitForClose()

        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(window.firstResponder === other,
                      "the keyboard stays where the user put it, it is not pulled back to the old composer")
        XCTAssertFalse(window.firstResponder === focus)
    }

    func testAClickOpenedListThatClosesWithNothingElseMovedLeavesTheKeyboardWhereItWas() {
        loadFixture()
        let (window, anchor, focus) = makeAnchor()
        let popover = openPopover(anchor: anchor, takeKeyboard: false)

        popover.close()
        waitForClose()

        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(window.firstResponder === focus, "the composer that had the keyboard has it after the list closes")
    }

    func testAClickOpenedListThatClosesWhenNobodyHoldsTheKeyboardGivesItBackToTheComposer() {
        loadFixture()
        let (window, anchor, focus) = makeAnchor()
        let popover = openPopover(anchor: anchor, takeKeyboard: false)
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(window.firstResponder === focus, "precondition: the composer let go of the keyboard")

        popover.close()
        waitForClose()

        XCTAssertTrue(window.firstResponder === focus, "with nobody holding the keyboard, the composer it came from gets it back")
    }

    func testAKeyboardOpenedListGivesTheKeyboardBackToItsComposerEvenIfAnotherResponderTookItInTheMeantime() {
        loadFixture()
        let (window, anchor, focus) = makeAnchor()
        let other = addOtherResponder(to: window)
        let popover = openPopover(anchor: anchor, takeKeyboard: true)
        XCTAssertTrue(popover.tookKeyboard, "precondition")

        // Something in the opening window took the first responder while the list had the keyboard.
        XCTAssertTrue(window.makeFirstResponder(other), "precondition")
        popover.close()
        waitForClose()

        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(window.firstResponder === focus,
                      "a list opened from the keyboard always hands the keyboard back to where it took it from")
    }

    func testAClickOpenedListOnARealBarLeavesTheKeyboardInTheOtherPaneTheUserClickedInto() {
        let window = ba3uiVisibleWindow(self, size: NSSize(width: 600, height: 140))
        let barA = ba3uiMakeBar(in: window, frame: NSRect(x: 0, y: 0, width: 600, height: 60), tag: "tag-a",
                                store: world.store, displayName: "A")
        let barB = ba3uiMakeBar(in: window, frame: NSRect(x: 0, y: 70, width: 600, height: 60), tag: "tag-b",
                                store: world.store, displayName: "B")
        bars += [barA, barB]
        XCTAssertTrue(window.makeFirstResponder(barA.textView))
        barA.textView.string = "typed in A"
        barA.textView.setSelectedRange(NSRange(location: 3, length: 4))
        barB.textView.string = "typed in B"

        barA.toggleBackgroundPopover(takeKeyboard: false)
        XCTAssertTrue(barA.backgroundPopover?.isShown ?? false, "precondition")
        XCTAssertTrue(window.firstResponder === barA.textView, "precondition: opening by click leaves A's composer as it was")

        // The click outside the list that closes it lands in B's composer.
        XCTAssertTrue(window.makeFirstResponder(barB.textView), "precondition")
        barA.backgroundPopover?.close()
        modelWaitUntil { barA.backgroundPopover == nil }

        XCTAssertTrue(window.firstResponder === barB.textView, "the keyboard stays in B's composer")
        XCTAssertEqual(barA.textView.string, "typed in A")
        XCTAssertEqual(barB.textView.string, "typed in B", "and nothing was typed or lost on the way")
    }

    // MARK: A status this client does not know

    func testARowWithAFiveHundredCharacterUnknownStatusIsBoundedAndStaysInsideANarrowRow() throws {
        let raw = String(repeating: "x", count: 500)
        let list = BackgroundTaskList.make(tasks: [world.task("odd", "build the thing", status: .unknown(raw), startedAgo: 5)],
                                           nowMs: world.stamp(0))
        let row = try XCTUnwrap(list.running.first, "an unrecognised status still counts as running")
        XCTAssertEqual(row.status, .unknown(raw), "precondition: the row still holds what the daemon sent")
        let height = BackgroundTaskRowView.height(for: row)

        let window = makeRigWindow(self, size: NSSize(width: 220, height: height))
        let view = BackgroundTaskRowView(row: row)
        view.frame = NSRect(x: 0, y: 0, width: 220, height: height)
        window.contentView?.addSubview(view)
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        XCTAssertEqual(view.statusText, row.statusLabel, "the row shows the bounded status")
        XCTAssertLessThanOrEqual(view.statusText.count, BackgroundTaskList.statusTextLimit, "`\(view.statusText)`")
        XCTAssertLessThan(view.statusText.count, raw.count)
        XCTAssertEqual(view.frame.height, height, accuracy: 0.5, "the row keeps its height")
        XCTAssertEqual(view.frame.width, 220, accuracy: 0.5, "and the width it was given")
        for sub in rigAllSubviews(of: view) where !sub.isHidden {
            let frame = sub.convert(sub.bounds, to: view)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(type(of: sub)) \(frame) starts left of the row")
            XCTAssertLessThanOrEqual(frame.maxX, view.bounds.width + 0.5,
                                     "\(type(of: sub)) \(frame) extends past the row's \(view.bounds.width) pt")
        }
    }

    func testTheArrowsAndEscapeWorkInsideTheListWhenItHoldsTheKeyboard() {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor, takeKeyboard: true)
        let content = popover.viewController.contentView

        content.keyDown(with: BA3UIKey.keyDown(BA3UIKey.down))
        XCTAssertEqual(popover.viewController.selectedRow?.id, "child")
        content.keyDown(with: BA3UIKey.keyDown(BA3UIKey.up))
        XCTAssertEqual(popover.viewController.selectedRow?.id, "agent")

        content.keyDown(with: BA3UIKey.keyDown(BA3UIKey.escape))
        waitForClose()
        XCTAssertFalse(popover.isShown)
    }

    func testShiftCommandBWhileTheListHoldsTheKeyboardClosesIt() {
        loadFixture()
        let (_, anchor, _) = makeAnchor()
        let popover = openPopover(anchor: anchor, takeKeyboard: true)
        let content = popover.viewController.contentView

        let handled = content.tryToPerform(BackgroundShortcut.action, with: nil)

        XCTAssertTrue(handled, "the list answers the shortcut itself")
        waitForClose()
        XCTAssertFalse(popover.isShown)
    }
}
