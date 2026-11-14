import XCTest
import AppKit
@testable import Nostromo

/// The Resume tab driven from the keyboard, through a real sheet and a recording sender (no daemon).
final class ResumeTabTests: XCTestCase {
    private typealias F = HistoryFixtures
    private var sender: RecordingHistorySender!
    private var store: ConversationHistoryStore!
    private var sheet: CreateFocusSheet!
    private var created: [Focus] = []

    override func setUp() {
        super.setUp()
        CreateFocusSheet.rememberedTab = .new
        sender = RecordingHistorySender()
        store = ConversationHistoryStore(sender: sender)
        created = []
        sheet = makeSheet()
    }

    override func tearDown() {
        CreateFocusSheet.rememberedTab = .new
        super.tearDown()
    }

    private func makeSheet() -> CreateFocusSheet {
        CreateFocusSheet(orgResolver: RepoOrgResolver(lookup: { _ in .resolved(nil) }),
                         agents: ["claudia"], projects: ["/tmp/alpha"], history: store,
                         onCreate: { [unowned self] in created.append($0) })
    }

    private func show(_ entries: [ConversationEntryWire]) {
        store.ingest(.conversationHistory(F.history(entries)))
        sheet.selectTab(.resume)
        sheet.resumeTab.setNow({ F.now }, calendar: F.utcCalendar())
    }

    private func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: sheet.window!.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func command(_ sel: Selector) -> Bool {
        sheet.resumeTab.control(sheet.resumeTab.searchField, textView: NSTextView(), doCommandBy: sel)
    }

    func testCommandOneAndTwoSwitchTabsAndResumeGrowsTheWindow() {
        XCTAssertEqual(sheet.currentTab, .new)
        XCTAssertTrue(sheet.window!.performKeyEquivalent(with: key("2", code: 19)))
        XCTAssertEqual(sheet.currentTab, .resume)
        XCTAssertEqual(sheet.window!.contentView!.frame.size, CreateFocusSheet.resumeSize)
        XCTAssertTrue(sheet.window!.performKeyEquivalent(with: key("1", code: 18)))
        XCTAssertEqual(sheet.currentTab, .new)
        XCTAssertEqual(sheet.window!.contentView!.frame.size, CreateFocusSheet.newSize)
        XCTAssertFalse(sheet.window!.performKeyEquivalent(with: key("1", code: 18, flags: [.command, .shift])),
                       "only plain ⌘1/⌘2")
    }

    func testTheSheetOpensOnNewAndRemembersResumeWithinARun() {
        XCTAssertEqual(sheet.currentTab, .new)
        sheet.selectTab(.resume)
        XCTAssertEqual(makeSheet().currentTab, .resume)
        CreateFocusSheet.rememberedTab = .new   // a relaunch
        XCTAssertEqual(makeSheet().currentTab, .new)
    }

    func testSearchOwnsTheKeyboardAndArrowsMoveTheSelection() {
        show([F.entry("a", title: "Alpha"), F.entry("b", title: "Beta", daysAgo: 0.2), F.entry("c", title: "Gamma", daysAgo: 0.3)])
        let tab = sheet.resumeTab
        XCTAssertTrue((sheet.window!.firstResponder as? NSTextView)?.delegate === tab.searchField)
        XCTAssertEqual(tab.selectedEntry?.id, "a")
        XCTAssertTrue(command(#selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(tab.selectedEntry?.id, "b")
        XCTAssertTrue(command(#selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(command(#selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(tab.selectedEntry?.id, "c", "stops at the last row")
        XCTAssertTrue(command(#selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(tab.selectedEntry?.id, "b")
        XCTAssertTrue((sheet.window!.firstResponder as? NSTextView)?.delegate === tab.searchField,
                      "search keeps first responder")
        tab.typeSearch("gam")
        XCTAssertEqual(tab.visibleEntries.map(\.id), ["c"])
    }

    func testReturnResumesTheSelectedRowAndAnUnresumableRowIsIgnored() {
        show([F.entry("a"), F.entry("gone", daysAgo: 0.1, status: .folderGone(worktree: false))])
        XCTAssertTrue(command(#selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(sender.resumes.map(\.id), ["a"])
        sheet.resumeTab.moveSelection(by: 1)
        XCTAssertFalse(sheet.isResumeButtonEnabled)
        _ = command(#selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(sender.resumes.count, 1, "a row with no folder cannot be resumed")
    }

    func testCommandDeleteRemovesAndUndoRestores() {
        show([F.entry("a"), F.entry("b", daysAgo: 0.2)])
        XCTAssertTrue(sheet.window!.performKeyEquivalent(with: key("\u{7F}", code: 51)))
        XCTAssertEqual(sender.removes, ["a"])
        XCTAssertEqual(sheet.resumeTab.visibleEntries.map(\.id), ["b"])
        XCTAssertTrue(sheet.window!.undoManager === sheet.sheetUndoManager, "the sheet's own undo manager")
        XCTAssertTrue(sheet.sheetUndoManager.canUndo)
        sheet.sheetUndoManager.undo()
        XCTAssertEqual(sender.restores, ["a"])
        XCTAssertEqual(Set(sheet.resumeTab.visibleEntries.map(\.id)), ["a", "b"])
    }

    func testEscapeCancelsAndPurgesWhatWasRemoved() {
        show([F.entry("a")])
        XCTAssertTrue(command(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(sender.purges, 1, "closing deletes the removed entries now")
        XCTAssertTrue(created.isEmpty)
    }

    func testNothingGlobalIsBound() {
        // The sheet binds ⌘1/⌘2/⌘⌫ on its own window only; the main menu is not touched.
        let before = NSApp.mainMenu?.items.count
        _ = makeSheet()
        XCTAssertEqual(NSApp.mainMenu?.items.count, before)
    }

    func testRowAccessibilityLabelHasTitleAgentProjectTimeAndStatusInWords() {
        let e = F.entry("a", title: "Fix picker", agent: "cody", project: "nostromo", status: .folderGone(worktree: true))
        show([e])
        let label = ConversationHistoryModel(entries: [e], now: { F.now }, calendar: F.utcCalendar()).text(for: e).accessibilityLabel
        XCTAssertTrue(label.hasPrefix("Fix picker, cody, nostromo, "), label)
        XCTAssertTrue(label.hasSuffix(", worktree gone"), label)
        let row = sheet.resumeTab.tableView.view(atColumn: 0, row: 1, makeIfNecessary: true) as? ResumeRowView
        XCTAssertEqual(row?.accessibilityLabel(), label)
    }

    func testRowMenuOffersResumeRemoveAndShowTranscript() {
        let e = F.entry("a")
        XCTAssertEqual(sheet.resumeTab.menuTitles(for: e), ["Resume", "Remove from History", "Show Transcript in Finder"])
    }

    func testBannersForADegradedFileAndAnOldDaemon() {
        store.ingest(.conversationHistory(F.history([], degraded: 4)))
        sheet.selectTab(.resume)
        XCTAssertEqual(sheet.resumeTab.bannerText, "History couldn\u{2019}t be read (4 entries kept)")
        sender.daemonAdvertisesConversationHistory = false
        store.ingest(.conversationHistory(F.history([])))
        sheet.resumeTab.update(history: nil, supported: store.isSupported)
        XCTAssertEqual(sheet.resumeTab.bannerText, "Needs a newer Nostromo daemon: run make install-daemon.")
    }

    func testTheFirstPromptsSwitchGoesToTheDaemon() {
        show([])
        sheet.resumeTab.promptsCheckbox.state = .off
        sheet.resumeTab.promptsCheckbox.performClick(nil)   // toggles to on, then the action fires
        XCTAssertEqual(sender.settings.count, 1)
    }
}
