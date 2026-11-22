import XCTest
import AppKit
import Combine

// Composer history through the real `ChatTextView` (message queue S4): Up and Down recall what was sent
// to this focus. The pure rules are `ComposerHistoryNavigatorTests`; this proves the AppKit wiring: real
// key events, the caret rule against AppKit's own caret movement, IME marked text, selection, modifiers,
// the slash picker, the human-only rule, two composers sharing one store, Clear History, and what the
// composer does and does not send anywhere.
//
// ReplInputBar, ChatTextView, ComposerHistoryStore, ComposerHistoryNavigator, FocusSensitivity and
// HumanGesture are compiled into this target directly (logic test, no host app).

final class ReplInputBarHistoryTests: XCTestCase {

    private let tag = "claudia"
    private let windows = WindowBag()
    private var root: URL!
    private var sensitivity: FakeFocusSensitivity!
    private var store: ComposerHistoryStore!
    private var bars: [ReplInputBar] = []
    private var sent: [(text: String, images: [URL])] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repl-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sensitivity = FakeFocusSensitivity()
        store = ComposerHistoryStore(directory: root.appendingPathComponent(".nostromo/composer-history.v1"),
                                     persists: true, sensitivity: sensitivity,
                                     scheduler: WorkScheduler { _, _ in { } })
        sent = []
    }

    override func tearDownWithError() throws {
        bars.forEach { $0.removeFromSuperview() }
        bars = []
        windows.tearDown()
        store = nil
        try? FileManager.default.removeItem(at: root)   // the test's own temp tree
    }

    // MARK: Rig

    private struct Rig {
        let window: NSWindow
        let bar: ReplInputBar
        var textView: ChatTextView { bar.textView }
    }

    private func makeRig(tag: String? = nil, agent: String? = nil) -> Rig {
        let window = windows.make(width: 600, height: 60)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView = content
        let bar = ReplInputBar(frame: content.bounds)
        content.addSubview(bar)
        bar.onSend = { [unowned self] text, images in self.sent.append((text, images)) }
        bar.bindHistory(tag: tag ?? self.tag, agentName: agent, store: store)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(bar.textView), "harness: the text view takes first responder")
        bars.append(bar)
        return Rig(window: window, bar: bar)
    }

    private func event(_ code: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                       timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        let chars = code == 126 ? "\u{F700}" : "\u{F701}"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func up(_ rig: Rig, modifiers: NSEvent.ModifierFlags = [], timestamp: TimeInterval? = nil) {
        rig.textView.keyDown(with: event(126, in: rig.window, modifiers: modifiers,
                                         timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime))
    }

    private func down(_ rig: Rig, modifiers: NSEvent.ModifierFlags = []) {
        rig.textView.keyDown(with: event(125, in: rig.window, modifiers: modifiers))
    }

    /// The text as if typed, with the caret at `caret` (default: the end).
    private func type(_ rig: Rig, _ string: String, caret: Int? = nil) {
        rig.textView.string = string
        rig.textView.setSelectedRange(NSRange(location: caret ?? (string as NSString).length, length: 0))
        rig.bar.textDidChange(Notification(name: NSText.didChangeNotification, object: rig.textView))
    }

    private func send(_ rig: Rig, _ string: String) {
        type(rig, string)
        rig.textView.onSubmit?()
    }

    private func text(_ rig: Rig) -> String { rig.textView.string }
    private func caret(_ rig: Rig) -> Int { rig.textView.selectedRange().location }

    private func writePNG() throws -> URL {
        let url = root.appendingPathComponent("pic-\(UUID().uuidString).png")
        // A 1x1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try png.write(to: url)
        return url
    }

    // MARK: H4-1 / A38

    func testUpFromAnEmptyComposerShowsNewestThenOlderAndDownWalksBackToTheEmptyDraft() {
        let rig = makeRig()
        ["a", "b", "c"].forEach { send(rig, $0) }
        XCTAssertEqual(text(rig), "")
        up(rig); XCTAssertEqual(text(rig), "c")
        up(rig); XCTAssertEqual(text(rig), "b")
        up(rig); XCTAssertEqual(text(rig), "a")
        down(rig); XCTAssertEqual(text(rig), "b")
        down(rig); XCTAssertEqual(text(rig), "c")
        down(rig); XCTAssertEqual(text(rig), "", "the original empty draft")
        XCTAssertEqual(caret(rig), 0)
    }

    func testRecalledTextPutsTheCaretAtTheEnd() {
        let rig = makeRig()
        send(rig, "hello")
        up(rig)
        XCTAssertEqual(caret(rig), 5)
    }

    func testRecallingAMultiLineEntryGrowsTheBar() {
        let rig = makeRig()
        send(rig, "one\ntwo\nthree\nfour")
        var heights: [CGFloat] = []
        rig.bar.onHeightChange = { heights.append($0) }
        up(rig)
        XCTAssertFalse(heights.isEmpty, "onHeightChange fired for the recall")
        XCTAssertGreaterThan(heights.last ?? 0, ReplInputBar.minHeight)
    }

    // MARK: H4-2 / A39

    func testDraftAndImageSurviveANavigationAndDownPastTheNewestRestoresTheDraftExactly() throws {
        let rig = makeRig()
        send(rig, "c")
        sent = []
        type(rig, "draft text", caret: 0)
        rig.bar.addImage(try writePNG())
        up(rig)
        XCTAssertEqual(text(rig), "c")
        down(rig)
        XCTAssertEqual(text(rig), "draft text")
        rig.textView.onSubmit?()
        XCTAssertEqual(sent.map(\.text), ["draft text"])
        XCTAssertEqual(sent.first?.images.count, 1, "the draft's image stayed attached throughout")
    }

    func testUpWithTheCaretNotAtTheStartOfADraftDoesNotRecall() {
        let rig = makeRig()
        send(rig, "old")
        type(rig, "draft", caret: 5)
        up(rig)
        XCTAssertNotEqual(text(rig), "old")
        XCTAssertEqual(text(rig), "draft")
    }

    // MARK: H4-3 / A40

    func testInAThreeLineDraftUpMovesTheCaretLineByLineThenToTheStartAndOnlyTheNextUpRecalls() {
        let rig = makeRig()
        send(rig, "old")
        let draft = "line one\nline two\nline three"
        type(rig, draft)
        var carets: [Int] = [caret(rig)]
        for _ in 0..<3 {
            up(rig)
            carets.append(caret(rig))
            XCTAssertEqual(text(rig), draft, "not recalled yet, caret at \(carets)")
        }
        XCTAssertEqual(carets.last, 0, "line 3 to line 2 to line 1 to the start: \(carets)")
        up(rig)
        XCTAssertEqual(text(rig), "old", "only the next Up recalls")
    }

    func testDownActsOnlyWhileNavigatingAndWithTheCaretAtTheEnd() {
        let rig = makeRig()
        send(rig, "old")
        let draft = "line one\nline two"
        type(rig, draft, caret: 0)
        down(rig)
        XCTAssertEqual(text(rig), draft, "not navigating: Down is just the caret")
        rig.textView.setSelectedRange(NSRange(location: 0, length: 0))   // Down moved it a line
        up(rig)
        XCTAssertEqual(text(rig), "old")
        rig.textView.setSelectedRange(NSRange(location: 1, length: 0))
        down(rig)
        XCTAssertEqual(text(rig), "old", "navigating but the caret is not at the end")
        rig.textView.setSelectedRange(NSRange(location: 3, length: 0))
        down(rig)
        XCTAssertEqual(text(rig), draft, "at the end: the draft is back")
    }

    // MARK: H4-4 / A41

    func testNoRecallWhileTextIsSelected() {
        let rig = makeRig()
        send(rig, "old")
        type(rig, "draft", caret: 0)
        rig.textView.setSelectedRange(NSRange(location: 0, length: 3))
        up(rig)
        XCTAssertEqual(text(rig), "draft")
    }

    func testNoRecallWhileTheSlashPickerIsOpen() {
        let rig = makeRig()
        send(rig, "old")
        type(rig, "/")
        XCTAssertTrue(rig.bar.slashPicker.isOpen, "harness: the picker opens on /")
        up(rig)
        XCTAssertEqual(text(rig), "/")
        down(rig)
        XCTAssertEqual(text(rig), "/")
    }

    func testNoRecallWithAnyModifierHeld() {
        let rig = makeRig()
        send(rig, "old")
        for flag: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            up(rig, modifiers: flag)
            XCTAssertEqual(text(rig), "", "modifier \(flag) recalled")
        }
        up(rig)
        XCTAssertEqual(text(rig), "old")
        for flag: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            down(rig, modifiers: flag)
            XCTAssertEqual(text(rig), "old", "modifier \(flag) walked down")
        }
    }

    func testTheArrowKeysOwnFunctionAndNumericPadFlagsDoNotCountAsModifiers() {
        let rig = makeRig()
        send(rig, "old")
        up(rig, modifiers: [.function, .numericPad])
        XCTAssertEqual(text(rig), "old")
    }

    func testNoRecallWhileAnIMEHasMarkedText() {
        let rig = makeRig()
        send(rig, "old")
        rig.textView.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(rig.textView.hasMarkedText(), "harness: marked text exists")
        rig.textView.setSelectedRange(NSRange(location: 0, length: 0))
        up(rig)
        XCTAssertFalse(text(rig).contains("old"), "Up in an IME candidate list is the IME's")
        XCTAssertTrue(text(rig).contains("にほん"))
        // And while navigating, Down in a candidate list is not history's either.
        rig.textView.unmarkText()
        type(rig, "")
        up(rig)
        XCTAssertEqual(text(rig), "old")
        rig.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: text(rig).utf16.count, length: 0))
        down(rig)
        XCTAssertTrue(text(rig).contains("old"), "Down did not leave the entry: \(text(rig))")
    }

    // MARK: H4-5 / A42

    func testEditingARecalledEntryThenUpThenDownShowsTheEditAndSendingSendsItWithTheStoredEntryUnchanged() {
        let rig = makeRig()
        send(rig, "first")
        send(rig, "second")
        sent = []
        up(rig)                                              // second
        type(rig, "second, edited")
        rig.textView.setSelectedRange(NSRange(location: 0, length: 0))
        up(rig)                                              // first
        XCTAssertEqual(text(rig), "first")
        down(rig)
        XCTAssertEqual(text(rig), "second, edited")
        rig.textView.onSubmit?()
        XCTAssertEqual(sent.map(\.text), ["second, edited"])
        XCTAssertEqual(store.entries(tag: tag), ["second, edited", "second", "first"],
                       "the sent text is a new entry; the stored one is unchanged")
    }

    func testSendingEndsNavigation() {
        let rig = makeRig()
        send(rig, "a")
        send(rig, "b")
        up(rig); up(rig)                                     // b, then a: the walk is at the oldest
        XCTAssertEqual(text(rig), "a")
        rig.textView.onSubmit?()                             // sends "a": history is now a, b, a
        XCTAssertEqual(text(rig), "")
        XCTAssertFalse(rig.bar.historyNavigator.isNavigating)
        up(rig)
        XCTAssertEqual(text(rig), "a", "the next Up starts a fresh walk at the newest")
        up(rig)
        XCTAssertEqual(text(rig), "b")
    }

    func testRecallingASlashCommandDoesNotOpenThePickerSoTheNextUpWalksOn() {
        let rig = makeRig()
        send(rig, "older")
        send(rig, "/clear")
        up(rig)
        XCTAssertEqual(text(rig), "/clear")
        XCTAssertFalse(rig.bar.slashPicker.isOpen)
        up(rig)
        XCTAssertEqual(text(rig), "older")
    }

    // MARK: H4-6 / A43

    func testSlashCommandsAreRecordedAndImageOnlySendsAreNot() throws {
        let rig = makeRig()
        send(rig, "/context")
        type(rig, "")
        rig.bar.addImage(try writePNG())
        rig.textView.onSubmit?()
        XCTAssertEqual(sent.last?.text, ChatSession.imageOnlyText, "harness: the image-only send went out")
        XCTAssertEqual(store.entries(tag: tag), ["/context"])
    }

    func testAnImageWithTypedTextRecordsTheTextOnly() throws {
        let rig = makeRig()
        type(rig, "look at this")
        rig.bar.addImage(try writePNG())
        rig.textView.onSubmit?()
        XCTAssertEqual(store.entries(tag: tag), ["look at this"])
    }

    func testNothingOutsideTheComposerPutsAnythingInHistory() {
        let rig = makeRig()
        // App-composed sends, injected notes and phone messages never pass through the composer.
        rig.bar.onSend?("composed by the app", [])
        XCTAssertEqual(store.entries(tag: tag), [])
    }

    // MARK: H4-8 / A45

    func testTwoFocusesNeverSeeEachOthersEntries() {
        let one = makeRig(tag: "one")
        let two = makeRig(tag: "two")
        send(one, "for one")
        up(two)
        XCTAssertEqual(text(two), "")
        up(one)
        XCTAssertEqual(text(one), "for one")
    }

    func testTwoComposersOnOneFocusShareOneHistoryButNotTheirWalks() {
        let a = makeRig()
        let b = makeRig()
        send(a, "sent in A")
        up(b)
        XCTAssertEqual(text(b), "sent in A", "recallable in the other window")
        type(a, "A's draft", caret: 0)
        up(a)
        XCTAssertEqual(text(a), "sent in A")
        down(b)
        XCTAssertEqual(text(b), "", "B's own walk and draft")
        down(a)
        XCTAssertEqual(text(a), "A's draft")
    }

    func testAWindowOpenedLaterSeesWhatWasSentBefore() {
        let a = makeRig()
        send(a, "before")
        let later = makeRig()   // the same tag: a new window, a new session, a restart
        up(later)
        XCTAssertEqual(text(later), "before")
    }

    func testChangingTheFocusEndsTheWalk() {
        let rig = makeRig()
        send(rig, "a")
        up(rig)
        XCTAssertTrue(rig.bar.historyNavigator.isNavigating, "harness: a walk is in progress")
        rig.bar.bindHistory(tag: "other", agentName: nil, store: store)
        XCTAssertFalse(rig.bar.historyNavigator.isNavigating)
    }

    // MARK: H4-10 / A47

    func testClearHistoryFromTheContextMenuEmptiesEveryComposerAtOnce() throws {
        let a = makeRig()
        let b = makeRig()
        send(a, "one")
        send(a, "two")
        up(b)
        XCTAssertEqual(text(b), "two")

        let menu = try XCTUnwrap(a.textView.menu(for: rightClick(in: a.window)))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Clear History" })
        _ = (item.target as AnyObject).perform(item.action!, with: item)
        XCTAssertEqual(store.entries(tag: tag), [])
        type(a, "")
        up(a)
        XCTAssertEqual(text(a), "", "a recall right afterwards finds nothing")
        XCTAssertFalse(b.bar.historyNavigator.isNavigating, "B's walk ended with the clear")
    }

    func testTheContextMenuHasOneClearHistoryItemHoweverOftenItOpens() throws {
        let rig = makeRig()
        for _ in 0..<3 {
            let menu = try XCTUnwrap(rig.textView.menu(for: rightClick(in: rig.window)))
            XCTAssertEqual(menu.items.filter { $0.title == "Clear History" }.count, 1)
        }
    }

    func testClearComposerHistoryFromThePaneActsOnTheSameStore() {
        let a = makeRig()
        let b = makeRig()
        send(a, "x")
        b.bar.clearHistory()   // what ReplView.clearComposerHistory calls
        XCTAssertEqual(store.entries(tag: tag), [])
        up(a)
        XCTAssertEqual(text(a), "")
    }

    func testThePaneMenuOffersClearComposerHistory() {
        let menu = TranscriptViewMenu.makePaneMenu()
        let item = menu.items.first { $0.title == TranscriptViewMenu.clearComposerHistoryTitle }
        XCTAssertEqual(item?.action, TranscriptViewMenu.clearComposerHistoryAction)
        XCTAssertNil(item?.target, "it acts on the pane the menu is in")
        XCTAssertEqual(menu.items.compactMap { $0.title.isEmpty ? nil : $0.title },
                       ["Focus", "Show All Activity", "Clear Composer History"])
    }

    private func rightClick(in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    // MARK: H4-12 the human-only rule

    func testASynthesisedUpOrDownNeverRecalls() {
        let rig = makeRig()
        send(rig, "old")
        SyntheticInputGate.begin()
        up(rig)
        SyntheticInputGate.end()
        XCTAssertEqual(text(rig), "", "app-control's Up is only caret movement")
        up(rig)
        XCTAssertEqual(text(rig), "old")
        SyntheticInputGate.begin()
        down(rig)
        SyntheticInputGate.end()
        XCTAssertEqual(text(rig), "old", "and so is its Down")
    }

    func testAStaleOrFutureStampedUpNeverRecalls() {
        let rig = makeRig()
        send(rig, "old")
        let now = ProcessInfo.processInfo.systemUptime
        up(rig, timestamp: now - 10)
        XCTAssertEqual(text(rig), "", "stale")
        up(rig, timestamp: now + 10)
        XCTAssertEqual(text(rig), "", "future-stamped")
        up(rig, timestamp: now)
        XCTAssertEqual(text(rig), "old")
    }

    func testAnUpFromAnotherWindowNeverRecalls() {
        let rig = makeRig()
        let other = windows.make(width: 100, height: 100)
        send(rig, "old")
        rig.textView.keyDown(with: event(126, in: other))
        XCTAssertEqual(text(rig), "")
    }

    // MARK: H4-17 / A17

    func testVoiceOverHearsWhereTheWalkStandsAndNeverTheEntryText() {
        let rig = makeRig()
        var spoken: [String] = []
        rig.bar.announceHistory = { spoken.append($0) }
        send(rig, "my secret one")
        send(rig, "my secret two")
        up(rig); up(rig); down(rig)
        XCTAssertEqual(Array(spoken.prefix(3)), ["History 1 of 2", "History 2 of 2", "History 1 of 2"])
        XCTAssertTrue(spoken.allSatisfy { !$0.contains("secret") }, "\(spoken)")
    }

    // MARK: Sensitive focus (SP3)

    func testAFocusThatBecomesSensitiveKeepsRecallingInMemoryAndNothingIsOnDisk() throws {
        let rig = makeRig()
        send(rig, "before")
        store.flush()
        sensitivity.becomeSensitive(tag)
        send(rig, "after")
        store.flush()
        up(rig)
        XCTAssertEqual(text(rig), "after")
        up(rig)
        XCTAssertEqual(text(rig), "before")
        XCTAssertEqual(try allFiles().filter { $0.lastPathComponent.hasSuffix(".json") }.count, 0)
    }

    func testAnAlwaysSensitiveAgentIsNeverWritten() throws {
        sensitivity.sensitiveTags = ["huey"]
        let rig = makeRig(tag: "huey", agent: "huey")
        send(rig, "private note")
        store.flush()
        XCTAssertEqual(try allFiles().filter { $0.lastPathComponent.hasSuffix(".json") }.count, 0)
        up(rig)
        XCTAssertEqual(text(rig), "private note")
    }

    // MARK: H4-13 / SP1 privacy

    private func allFiles() throws -> [URL] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func testACanarySentAndRecalledIsInItsHistoryFileAndNowhereElseAndRecallSendsNothing() throws {
        let canary = "CANARY-\(UUID().uuidString)"
        let rig = makeRig()
        send(rig, canary)
        XCTAssertEqual(sent.map(\.text), [canary], "the message itself went out once, as the user's send")
        let sendsBeforeRecall = sent.count
        up(rig)
        XCTAssertEqual(text(rig), canary)
        down(rig)
        up(rig)
        store.flush()

        XCTAssertEqual(sent.count, sendsBeforeRecall, "recalling sends nothing: onSend is the bar's only way out")
        let holders = try allFiles().filter { (try? Data(contentsOf: $0))?.range(of: Data(canary.utf8)) != nil }
        XCTAssertEqual(holders.count, 1, "the canary is in exactly one file: \(holders.map(\.path))")
        XCTAssertEqual(holders.first?.deletingLastPathComponent().lastPathComponent, "composer-history.v1")
    }

    func testTheHistoryTypesHaveNoPathToTheDaemon() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo")
        for file in ["Data/ComposerHistoryStore.swift", "Data/FocusSensitivity.swift",
                     "UI/Views/ComposerHistoryNavigator.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for forbidden in ["NostromodClient", "sessionSend", "URLSession", "NWConnection", "NSPasteboard"] {
                XCTAssertFalse(source.contains(forbidden), "\(file) mentions \(forbidden)")
            }
        }
    }

    func testTheTranscriptPaneBindsHistoryWithItsAgentNameAndTheSharedStore() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo")
        let pane = try String(contentsOf: sources.appendingPathComponent("UI/Views/ReplView.swift"), encoding: .utf8)
        XCTAssertTrue(pane.contains("inputBar.bindHistory(tag: session.tag, agentName: session.agentName, store: ComposerHistoryStore.shared)"),
                      "a fred, teri or huey focus must reach the store as one")
    }

    func testTheSharedStoreLivesUnderTheHomesDotNostromoFolder() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Nostromo")
        let source = try String(contentsOf: sources.appendingPathComponent("Data/ComposerHistoryStore.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NostromoHome.current.appendingPathComponent(\".nostromo/composer-history.v1\""),
                      "SP2: under NostromoHome.current/.nostromo, not a synced location")
    }
}
