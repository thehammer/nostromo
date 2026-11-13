import XCTest
import AppKit
import Combine
import NostromoKit

// Typing `/` at the start of the composer opens a picker of the session's commands; the text view keeps
// first responder throughout (the keys reach the picker through the text view, nothing is ever typed into
// the list). Up and Down move (wrapping), Tab and Return COMPLETE the first token to `/<name> ` (Return never
// sends while the picker is open), Esc closes and leaves the text alone, a space after the token closes it,
// and text that does not start with `/`, or a caret past the first token, never opens it. With nothing
// matching, Tab and Return close it, so a command the list does not know can still be sent by pressing
// Return again.
//
// The list comes from `SlashCommandStore`, which asks the daemon at most once per 5 s per session, and never
// of a daemon that did not advertise `slash_commands_v1` (the picker then shows the built-in table).
//
// ReplInputBar, ChatTextView, SlashCommandPicker, SlashCommandPickerView, SlashCommandStore, NostromodClient
// and the NostromoKit types are compiled into this target directly (logic test, no host app). Keys are real
// `NSEvent`s sent to the bar's text view, as `ModelPopoverTests` sends them to its views.

/// What the store asked the daemon, in order.
final class SlashCommandSendRecorder: SlashCommandSending {
    var advertises = true
    private(set) var calls: [(tag: String, requestId: String)] = []
    var daemonAdvertisesSlashCommands: Bool { advertises }
    func sessionCommandsGet(tag: String, requestId: String) { calls.append((tag, requestId)) }
}

final class SlashCommandPickerTests: XCTestCase {

    private let tag = "claudia"
    private let windows = WindowBag()
    private var window: NSWindow!
    private var bar: ReplInputBar!
    private var recorder: SlashCommandSendRecorder!
    private var store: SlashCommandStore!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var requestCounter = 0
    private var sent: [String] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        recorder = SlashCommandSendRecorder()
        clock = Date(timeIntervalSince1970: 1_800_000_000)
        requestCounter = 0
        sent = []
        store = SlashCommandStore(sender: recorder, now: { [unowned self] in self.clock },
                                  makeRequestId: { [unowned self] in
                                      self.requestCounter += 1
                                      return "req-\(self.requestCounter)"
                                  })
        window = windows.make(width: 600, height: 60)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView = content
        bar = ReplInputBar(frame: content.bounds)
        content.addSubview(bar)
        bar.onSend = { [unowned self] text, _ in self.sent.append(text) }
        bar.bindSlashCommands(tag: tag, store: store)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(bar.textView), "harness: the text view takes first responder")
    }

    override func tearDown() {
        bar?.removeFromSuperview()
        windows.tearDown()
        bar = nil
        store = nil
        recorder = nil
        window = nil
        super.tearDown()
    }

    // MARK: Helpers

    private var picker: SlashCommandPicker { bar.slashPicker }
    private var text: String { bar.textView.string }

    /// The text as if typed, with the caret at `caret` (default: the end).
    private func typeText(_ string: String, caret: Int? = nil) {
        bar.textView.string = string
        bar.textView.setSelectedRange(NSRange(location: caret ?? (string as NSString).length, length: 0))
        bar.textDidChange(Notification(name: NSText.didChangeNotification, object: bar.textView))
    }

    private func press(_ code: UInt16, _ chars: String) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        bar.textView.keyDown(with: event)
    }

    private func down() { press(125, "\u{F701}") }
    private func up() { press(126, "\u{F700}") }
    private func tab() { press(48, "\t") }
    private func returnKey() { press(36, "\r") }
    private func escape() { press(53, "\u{1B}") }

    private func assertTextViewKeepsFocus(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(window.firstResponder === bar.textView, "the text view stays first responder", file: file, line: line)
    }

    private func ingest(_ source: String, _ names: [String], tag: String? = nil) {
        store.ingest(.sessionCommands(SessionCommandsWire(
            requestId: "r", tag: tag ?? self.tag, source: source,
            commands: names.map { SlashCommandEntryWire(name: $0, description: "About \($0)") })))
    }

    private let fallbackNames = BuiltinSlashCommands.fallback.map(\.name).sorted()

    // MARK: Opening and filtering

    func testTypingASlashOpensThePickerWithEveryCommandSortedByName() {
        typeText("/")

        XCTAssertTrue(picker.isOpen)
        XCTAssertEqual(picker.rows.map(\.name), fallbackNames)
        XCTAssertTrue(picker.isFallback, "no list has arrived: the built-in table, and the picker says so")
        assertTextViewKeepsFocus()
    }

    func testTypingAfterTheSlashFiltersTheList() {
        typeText("/con")

        XCTAssertTrue(picker.isOpen)
        XCTAssertEqual(picker.rows.map(\.name), ["context"])
        XCTAssertEqual(picker.query, "con")

        typeText("/cos")
        XCTAssertEqual(picker.rows.first?.name, "usage", "the `cost` alias finds usage")
    }

    func testTheListFollowsTheCaretWhileItIsInsideTheFirstToken() {
        typeText("/con foo", caret: 4)

        XCTAssertTrue(picker.isOpen)
        XCTAssertEqual(picker.query, "con")
    }

    // MARK: Staying closed

    func testTextThatDoesNotStartWithASlashNeverOpensThePicker() {
        for string in ["", "hello", " /con", "hello /con", "x/", "\n/con"] {
            typeText(string)

            XCTAssertFalse(picker.isOpen, string.debugDescription)
        }
    }

    func testACaretPastTheFirstTokenNeverOpensThePicker() {
        typeText("/con foo", caret: 8)
        XCTAssertFalse(picker.isOpen)

        typeText("/con\nfoo", caret: 8)
        XCTAssertFalse(picker.isOpen)

        typeText("/con foo", caret: 0)
        XCTAssertFalse(picker.isOpen, "a caret before the slash is not in the command token either")
    }

    func testASpaceAfterTheTokenClosesThePicker() {
        typeText("/context")
        XCTAssertTrue(picker.isOpen)

        typeText("/context ")

        XCTAssertFalse(picker.isOpen)
    }

    // MARK: Keys

    func testDownThenTabCompletesTheCommandAndKeepsTheComposerFocused() {
        typeText("/con")

        down()
        tab()

        XCTAssertEqual(text, "/context ", "completed, with the space that ends the token (and no tab character)")
        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(bar.textView.selectedRange().location, ("/context " as NSString).length, "the caret follows the space")
        XCTAssertEqual(sent, [])
        assertTextViewKeepsFocus()
    }

    func testDownMovesToTheNextRowAndTabCompletesThatRow() {
        typeText("/c")
        XCTAssertEqual(Array(picker.rows.map(\.name).prefix(3)), ["clear", "compact", "context"])

        down()
        down()
        XCTAssertEqual(picker.selectedEntry?.name, "context")
        tab()

        XCTAssertEqual(text, "/context ")
    }

    func testReturnWithThePickerOpenCompletesInsteadOfSendingAndASecondReturnSends() {
        typeText("/con")

        returnKey()

        XCTAssertEqual(sent, [], "Return with the picker open never sends")
        XCTAssertEqual(text, "/context ")
        XCTAssertFalse(picker.isOpen)
        assertTextViewKeepsFocus()

        returnKey()

        XCTAssertEqual(sent, ["/context"])
        XCTAssertEqual(text, "")
    }

    func testEscapeClosesThePickerAndKeepsTheText() {
        typeText("/con")

        escape()

        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(text, "/con")
        XCTAssertEqual(sent, [])
        assertTextViewKeepsFocus()
    }

    func testEscapeKeepsThePickerClosedUntilTheTextChanges() {
        typeText("/con")
        escape()

        bar.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: bar.textView))
        XCTAssertFalse(picker.isOpen, "moving the caret does not reopen what Esc closed")

        typeText("/cont")
        XCTAssertTrue(picker.isOpen, "typing does")
    }

    func testAfterEscapeReturnSendsTheTextAsTyped() {
        typeText("/con")
        escape()

        returnKey()

        XCTAssertEqual(sent, ["/con"])
    }

    func testWithNoMatchingCommandReturnClosesThePickerAndASecondReturnSends() {
        typeText("/zzzz")
        XCTAssertTrue(picker.isOpen)
        XCTAssertEqual(picker.rows.count, 0)

        returnKey()

        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(sent, [], "the first Return only closes the picker")
        XCTAssertEqual(text, "/zzzz")

        returnKey()

        XCTAssertEqual(sent, ["/zzzz"], "the command the list does not know goes to the model as an ordinary prompt")
    }

    func testWithNoMatchingCommandTabClosesThePickerAndLeavesTheText() {
        typeText("/zzzz")

        tab()

        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(text, "/zzzz")
        XCTAssertEqual(sent, [])
    }

    func testReturnWithThePickerClosedSendsAsBefore() {
        typeText("hello")

        returnKey()

        XCTAssertEqual(sent, ["hello"])
    }

    func testTabCompletionReplacesOnlyTheFirstTokenAndKeepsTheRest() {
        typeText("/con foo bar", caret: 4)

        tab()

        XCTAssertEqual(text, "/context foo bar")
        XCTAssertEqual(bar.textView.selectedRange().location, ("/context " as NSString).length)
        XCTAssertFalse(picker.isOpen)
    }

    func testSelectionWrapsAroundInBothDirections() {
        typeText("/c")
        let count = picker.rows.count
        XCTAssertGreaterThan(count, 3)
        XCTAssertEqual(picker.selection, 0)

        up()
        XCTAssertEqual(picker.selection, count - 1, "Up from the first row wraps to the last")

        down()
        XCTAssertEqual(picker.selection, 0, "Down from the last row wraps to the first")

        for _ in 0..<count { down() }
        XCTAssertEqual(picker.selection, 0, "a full lap is back where it started")
    }

    func testTheWrappedSelectionIsWhatTabCompletes() {
        typeText("/c")
        let last = picker.rows.last?.name

        up()
        tab()

        XCTAssertEqual(text, "/\(last ?? "?") ")
    }

    func testChoosingARowWithTheMouseCompletesLikeTab() throws {
        typeText("/c")
        let entry = try XCTUnwrap(picker.rows.dropFirst().first)

        picker.onChoose?(entry)

        XCTAssertEqual(text, "/\(entry.name) ")
        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(sent, [])
    }

    func testTheNarrowingQueryResetsTheSelectionToTheFirstRow() {
        typeText("/c")
        down()
        XCTAssertEqual(picker.selection, 1)

        typeText("/co")

        XCTAssertEqual(picker.selection, 0)
    }

    // MARK: Closing

    func testSendingClosesThePicker() {
        typeText("/zzzz")
        returnKey()
        returnKey()

        XCTAssertFalse(picker.isOpen)
        XCTAssertEqual(text, "")
    }

    func testTheComposerLosingFocusClosesThePicker() {
        typeText("/")
        XCTAssertTrue(picker.isOpen)

        bar.textDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: bar.textView))

        XCTAssertFalse(picker.isOpen)
    }

    func testRemovingTheBarFromItsWindowClosesThePicker() {
        typeText("/")
        XCTAssertTrue(picker.isOpen)

        bar.removeFromSuperview()

        XCTAssertFalse(picker.isOpen)
    }

    // MARK: Accessibility

    private func openStandalonePicker() -> SlashCommandPicker {
        let picker = SlashCommandPicker()
        picker.catalog = {
            SlashCommandCatalog(entries: [SlashCommandEntryWire(name: "alpha", description: "First one"),
                                          SlashCommandEntryWire(name: "beta")], isFallback: false)
        }
        return picker
    }

    func testARowsAccessibilityLabelIsTheSlashNameAndItsDescription() {
        let row = SlashCommandRowView(frame: NSRect(x: 0, y: 0, width: 400, height: SlashCommandPickerView.rowHeight))

        row.configure(entry: SlashCommandEntryWire(name: "context", description: "Show current context usage"), selected: false)
        XCTAssertEqual(row.accessibilityLabel(), "/context, Show current context usage")

        row.configure(entry: SlashCommandEntryWire(name: "my-skill"), selected: true)
        XCTAssertEqual(row.accessibilityLabel(), "/my-skill", "no description, no trailing comma")
        XCTAssertEqual(row.accessibilityRole(), .row)
        XCTAssertTrue(row.isAccessibilityElement())
        XCTAssertTrue(row.isAccessibilitySelected())
    }

    func testThePickerIsAListWithARowPerVisibleCommandAndTheSelectedRowIsMarked() throws {
        let picker = openStandalonePicker()
        picker.update(text: "/", caret: 1)
        let view = SlashCommandPickerView(picker: picker)

        XCTAssertEqual(view.accessibilityRole(), .list)
        XCTAssertEqual(view.accessibilityLabel(), "Slash commands, 2 commands")
        XCTAssertTrue(view.isAccessibilityElement())
        let rows = try XCTUnwrap(view.accessibilityChildren() as? [SlashCommandRowView])
        XCTAssertEqual(rows.map { $0.accessibilityLabel() }, ["/alpha, First one", "/beta"])
        XCTAssertEqual(rows.map { $0.accessibilityRole() }, [.row, .row])
        XCTAssertEqual(rows.map { $0.isAccessibilitySelected() }, [true, false])

        picker.move(by: 1)
        view.reload()
        XCTAssertEqual(rows.map { $0.isAccessibilitySelected() }, [false, true])
    }

    func testAOneCommandListSaysSingular() {
        let picker = openStandalonePicker()
        picker.update(text: "/alp", caret: 4)

        XCTAssertEqual(SlashCommandPickerView(picker: picker).accessibilityLabel(), "Slash commands, 1 command")
    }

    func testAClosedPickerIsNotAnAccessibilityElement() {
        let picker = openStandalonePicker()
        picker.update(text: "/", caret: 1)
        let view = SlashCommandPickerView(picker: picker)

        picker.close()
        view.reload()

        XCTAssertFalse(view.isAccessibilityElement())
    }

    func testPressingARowThroughVoiceOverChoosesIt() throws {
        let picker = openStandalonePicker()
        picker.update(text: "/", caret: 1)
        let view = SlashCommandPickerView(picker: picker)
        var chosen: [String] = []
        picker.onChoose = { chosen.append($0.name) }

        XCTAssertTrue(try XCTUnwrap(view.visibleRows.last).accessibilityPerformPress())

        XCTAssertEqual(chosen, ["beta"])
    }

    func testOpeningAndMovingAnnounceTheCountAndTheSelectedCommand() {
        let picker = openStandalonePicker()
        var announced: [String] = []
        picker.onAnnounce = { announced.append($0) }

        picker.update(text: "/", caret: 1)
        picker.move(by: 1)

        XCTAssertEqual(announced, ["2 commands", "/beta"])
    }

    // MARK: Asking the daemon

    func testOpeningThePickerAsksTheDaemonForTheSessionsCommands() {
        typeText("/")

        XCTAssertEqual(recorder.calls.map(\.tag), [tag])
        XCTAssertEqual(recorder.calls.map(\.requestId), ["req-1"])
    }

    func testTheStoreAsksAtMostOncePerFiveSecondsPerSession() {
        typeText("/")
        XCTAssertEqual(recorder.calls.count, 1)

        typeText("")
        typeText("/")
        XCTAssertEqual(recorder.calls.count, 1, "reopened straight away: not asked again")

        clock = clock.addingTimeInterval(4.9)
        typeText("")
        typeText("/")
        XCTAssertEqual(recorder.calls.count, 1, "4.9 s later is still inside the window")

        clock = clock.addingTimeInterval(0.2)
        typeText("")
        typeText("/")
        XCTAssertEqual(recorder.calls.count, 2, "past five seconds it asks again")
    }

    func testTheStoreKeepsItsFiveSecondWindowsPerSession() {
        store.refresh(tag: "a")
        store.refresh(tag: "b")
        store.refresh(tag: "a")
        store.refresh(tag: "b")

        XCTAssertEqual(recorder.calls.map(\.tag), ["a", "b"])

        clock = clock.addingTimeInterval(SlashCommandStore.refreshInterval)
        store.refresh(tag: "a")

        XCTAssertEqual(recorder.calls.map(\.tag), ["a", "b", "a"])
    }

    func testTheStoreNeverAsksADaemonThatDidNotAdvertiseTheFeature() {
        recorder.advertises = false

        typeText("/")
        store.refresh(tag: "other")

        XCTAssertEqual(recorder.calls.count, 0)
        XCTAssertTrue(picker.isOpen)
        XCTAssertEqual(picker.rows.map(\.name), fallbackNames, "an old daemon: the picker shows the built-in table")
        XCTAssertTrue(picker.isFallback)
    }

    func testAStoreWithNoSenderAsksNobodyAndStillAnswersWithTheFallback() {
        let lonely = SlashCommandStore(sender: nil)

        lonely.refresh(tag: tag)

        XCTAssertEqual(lonely.catalog(for: tag), SlashCommandCatalog.fallback)
    }

    // MARK: What arrives

    func testAnIngestedListReplacesTheFallbackForThatSessionOnly() {
        ingest("cli", ["alpha", "beta"])

        XCTAssertEqual(store.catalog(for: tag).entries.map(\.name), ["alpha", "beta"])
        XCTAssertFalse(store.catalog(for: tag).isFallback)
        XCTAssertEqual(store.catalog(for: "someone-else"), SlashCommandCatalog.fallback)
    }

    func testAnIngestedListFiresChangesWithTheTag() {
        var heard: [String] = []
        let subscription = store.changes.sink { heard.append($0) }

        ingest("cli", ["alpha"])
        ingest("none", [], tag: "other")

        XCTAssertEqual(heard, [tag, "other"])
        subscription.cancel()
    }

    func testFramesThatAreNotCommandListsAreIgnored() {
        var heard = 0
        let subscription = store.changes.sink { _ in heard += 1 }

        store.ingest(.unknown)

        XCTAssertEqual(heard, 0)
        XCTAssertEqual(store.catalog(for: tag), SlashCommandCatalog.fallback)
        subscription.cancel()
    }

    func testAListThatArrivesWhileThePickerIsOpenUpdatesIt() {
        typeText("/")
        XCTAssertEqual(picker.rows.count, fallbackNames.count)

        ingest("cli", ["alpha", "beta", "gamma"])

        XCTAssertEqual(picker.rows.map(\.name), ["alpha", "beta", "gamma"])
        XCTAssertFalse(picker.isFallback)
    }

    func testAListForAnotherSessionLeavesThisPickerAlone() {
        typeText("/")

        ingest("cli", ["alpha"], tag: "someone-else")

        XCTAssertEqual(picker.rows.map(\.name), fallbackNames)
    }

    func testTheSelectionStaysPutWhenAListArrivesAndItsRowIsStillThere() {
        ingest("cli", ["alpha", "beta", "gamma"])
        typeText("/")
        down()
        XCTAssertEqual(picker.selectedEntry?.name, "beta")

        ingest("cli", ["alpha", "beta", "gamma", "delta"])

        XCTAssertTrue(picker.isOpen)
        XCTAssertEqual(picker.rows.count, 4)
        XCTAssertTrue((0..<4).contains(picker.selection))
    }

    // MARK: The daemon's side of the seam (the Mac client)

    func testTheMacClientDecodesASessionCommandsFrameAndSkipsABadEntry() throws {
        let client = NostromodClient(socketPath: "/dev/null")
        let json = #"""
        {"type":"session_commands","request_id":"r1","tag":"claudia","source":"cli","commands":[
          {"name":"context","description":"Show current context usage","aliases":["ctx"]},{"description":"no name"},{"name":"x","future":1}]}
        """#
        let raw = Data(json.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])

        guard case .sessionCommands(let wire) = client.decode(type_: "session_commands", json: object, raw: raw) else {
            return XCTFail("not a session_commands frame")
        }

        XCTAssertEqual(wire.tag, "claudia")
        XCTAssertEqual(wire.source, "cli")
        XCTAssertEqual(wire.commands.map(\.name), ["context", "x"])
    }

    func testTheMacClientTreatsASessionCommandsFrameWithoutATagAsUnknown() throws {
        let client = NostromodClient(socketPath: "/dev/null")
        let raw = Data(#"{"type":"session_commands","request_id":"r1","source":"cli","commands":[]}"#.utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])

        guard case .unknown = client.decode(type_: "session_commands", json: object, raw: raw) else {
            return XCTFail("a frame the Mac cannot read must not become a command list")
        }
    }

    func testOnlyADaemonThatAdvertisesSlashCommandsV1SupportsThem() {
        XCTAssertEqual(NostromodClient.slashCommandsFeature, "slash_commands_v1")
        XCTAssertTrue(NostromodClient.supportsSlashCommands(features: ["slash_commands_v1"]))
        XCTAssertTrue(NostromodClient.supportsSlashCommands(features: ["work", "slash_commands_v1", "model"]))
        XCTAssertFalse(NostromodClient.supportsSlashCommands(features: nil), "a welcome with no features key (an old daemon)")
        XCTAssertFalse(NostromodClient.supportsSlashCommands(features: []))
        XCTAssertFalse(NostromodClient.supportsSlashCommands(features: ["work", "model", "approvals_v1"]))
        XCTAssertFalse(NostromodClient.supportsSlashCommands(features: ["slash_commands_v2"]))
        XCTAssertFalse(NostromodClient.supportsSlashCommands(features: ["slash_commands"]))
        XCTAssertFalse(NostromodClient.supportsSlashCommands(features: ["Slash_Commands_V1"]))
    }

    func testAClientReportsWhetherItsLastWelcomeAdvertisedSlashCommands() {
        let client = NostromodClient(socketPath: "/dev/null")
        XCTAssertFalse(client.daemonAdvertisesSlashCommands, "before any welcome")

        client.setAdvertisedFeaturesForTesting(["work"])
        XCTAssertFalse(client.daemonAdvertisesSlashCommands)

        client.setAdvertisedFeaturesForTesting(["work", "slash_commands_v1"])
        XCTAssertTrue(client.daemonAdvertisesSlashCommands)

        client.setAdvertisedFeaturesForTesting([])
        XCTAssertFalse(client.daemonAdvertisesSlashCommands)
    }
}

// MARK: - Wiring

/// `ReplView` and `AppStore` are not compiled into this target, so what connects the picker to the app is
/// read from their source (the way `TaskWindowFitnessTests` reads `AppStore.handle`): without these lines the
/// picker would be drawn from a store that is never fed, or never drawn at all.
final class SlashCommandWiringTests: XCTestCase {

    /// A file's lines with `//` comments dropped.
    private func codeLines(_ relativePath: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)       // …/macOS/NostromoTests/SlashCommandPickerTests.swift
            .deletingLastPathComponent()                  // …/macOS/NostromoTests
            .deletingLastPathComponent()                  // …/macOS
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    func testAppStoreHandsTheDaemonConnectionToTheSharedStore() throws {
        let lines = try codeLines("Nostromo/Data/AppStore.swift")

        XCTAssertTrue(lines.contains { $0.hasPrefix("SlashCommandStore.shared.sender = ") },
                      "without a sender the shared store never asks the daemon for a session's commands")
    }

    func testAppStoreRoutesSessionCommandsFramesToTheSharedStore() throws {
        let lines = try codeLines("Nostromo/Data/AppStore.swift")
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("case ") && $0.contains(".sessionCommands") },
                                  "AppStore.handle has no case for .sessionCommands")
        var arm = ""
        for line in lines[(start + 1)...] {
            if line.hasPrefix("case ") || line.hasPrefix("default") { break }
            arm += line + "\n"
        }

        XCTAssertTrue(arm.contains("SlashCommandStore.shared.ingest"),
                      "a daemon's command list must reach the store the pickers read, or they stay on the built-in table")
    }

    func testTheReplViewBindsItsInputBarToTheSharedStoreAndDrawsThePicker() throws {
        let code = try codeLines("Nostromo/UI/Views/ReplView.swift").joined(separator: "\n")

        XCTAssertTrue(code.contains("bindSlashCommands(tag:") && code.contains("SlashCommandStore.shared"),
                      "the bar must be bound to the shared store for its session's tag")
        XCTAssertTrue(code.contains("SlashCommandPickerView(picker: inputBar.slashPicker)"),
                      "the picker's state must be drawn")
        XCTAssertTrue(code.contains("addSubview(slashPickerView)"), "and the drawn picker must be in the pane")
    }
}
