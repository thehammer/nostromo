import XCTest
import AppKit
import Combine

// The composer's side of the message queue (message queue S2): Up with an empty composer takes the newest
// queued message back, a chip's Edit takes its own, Stop puts back what it dropped, and a send the daemon
// refused comes back with a reason. Everything runs through a real `ReplInputBar` and its real text view
// with real key events; the queue is a real `SessionQueueModel` whose request writer and timer are fakes, so
// the daemon's answer (or its silence) is the test's to give and nothing sleeps.
//
// Acceptance criteria exercised: C2-8 (Stop restores only for the composer that pressed it), C2-12 (the
// take-back and what it does to the composer and history), C2-13 (two windows, one request), C2-14 (only
// the newest by Up, any chip by Edit), C2-15 (an app message is never dug past), C2-16 (a person's Up on an
// empty composer, nothing else), C2-17 (an old daemon: Up is history only).
//
// VoiceOver: what a take-back or a Stop restore says goes through `announceQueue` (a seam, recorded as
// `queueSpoken`); where a history walk stands goes through `announceHistory` (recorded as `spoken`). The two
// are kept apart here on purpose. What is NOT asserted is the NSAccessibility post the default seams make.

final class ReplInputBarTakeBackTests: XCTestCase {

    private let tag = "claudia"
    private let windows = WindowBag()
    private var root: URL!
    private var store: ComposerHistoryStore!
    private var bars: [ReplInputBar] = []
    private var sent: [(text: String, images: [URL])] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("repl-takeback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = ComposerHistoryStore(directory: root.appendingPathComponent("composer-history.v1"),
                                     persists: false, sensitivity: FakeFocusSensitivity(),
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

    // MARK: A queue whose daemon is the test

    private final class FakeQueue {
        var takeBacks: [(id: String, requestId: String)] = []
        var removes: [String] = []
        var writerAccepts = true
        var timers: [(delay: TimeInterval, work: () -> Void)] = []
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        private var counter = 0
        private var rev = 0
        var model: SessionQueueModel!

        init() {
            model = SessionQueueModel(
                tag: "claudia",
                sendTakeBack: { [unowned self] id, request in
                    guard writerAccepts else { return false }
                    takeBacks.append((id, request)); return true
                },
                sendRemove: { [unowned self] id, _ in
                    guard writerAccepts else { return false }
                    removes.append(id); return true
                },
                after: { [unowned self] delay, work in timers.append((delay, work)) },
                now: { [unowned self] in date },
                newRequestId: { [unowned self] in counter += 1; return "req-\(counter)" })
        }

        func fireTimers() {
            let due = timers
            timers = []
            due.forEach { $0.work() }
        }

        func decode<T: Decodable>(_ json: [String: Any]) -> T {
            try! JSONDecoder().decode(T.self, from: try! JSONSerialization.data(withJSONObject: json))
        }

        /// The daemon's snapshot of the queue.
        func queued(_ entries: [[String: Any]], held: String? = nil) {
            rev += 1
            var json: [String: Any] = ["type": "session_queue", "tag": "claudia", "daemon_epoch": "epoch-a",
                                       "rev": rev, "entries": entries]
            if let held { json["held"] = ["id": held, "hold_id": "hold-1", "can_take_back": true] }
            model.apply(decode(json) as SessionQueueWire)
        }

        /// The daemon's answer to the latest request.
        func answer(_ code: String, text: String? = nil, images: [String]? = nil) {
            guard let last = takeBacks.last else { return XCTFail("no request was sent to answer") }
            var json: [String: Any] = ["type": "session_queue_result", "tag": "claudia", "request_id": last.requestId,
                                       "id": last.id, "code": code]
            if let text { json["text"] = text }
            if let images { json["images"] = images }
            model.handle(decode(json) as SessionQueueResultWire)
        }

        /// What Stop hands back to the connection that pressed it.
        func returned(_ items: [(text: String, images: [String])]) {
            let entries = items.enumerated().map { i, item -> [String: Any] in
                var e: [String: Any] = ["id": "q-\(i)", "text": item.text]
                if !item.images.isEmpty { e["images"] = item.images }
                return e
            }
            model.handle(decode(["type": "session_queue_returned", "tag": "claudia", "reason": "stopped",
                                 "entries": entries]) as SessionQueueReturnedWire)
        }
    }

    private func typedEntry(_ id: String, _ text: String, command: Bool = false) -> [String: Any] {
        ["id": id, "kind": "typed", "text": text, "image_count": 0, "command": command, "can_take_back": true]
    }

    private func appEntry(_ id: String, _ text: String = "Mother overview: PR 12") -> [String: Any] {
        ["id": id, "kind": "app", "text": text, "image_count": 0, "command": false, "app_label": "mother_overview",
         "can_take_back": false]
    }

    // MARK: Rig

    private struct Rig {
        let window: NSWindow
        let bar: ReplInputBar
        let statuses: Box<[String]>
        let spoken: Box<[String]>
        /// What the take-back and Stop-restore announcements said (`announceQueue`).
        let queueSpoken: Box<[String]>
        let draftStates: Box<[Bool]>
        var textView: ChatTextView { bar.textView }
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private func makeRig(queue: FakeQueue?, tag: String? = nil) -> Rig {
        let window = windows.make(width: 600, height: 60)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView = content
        let bar = ReplInputBar(frame: content.bounds)
        content.addSubview(bar)
        bar.onSend = { [unowned self] text, images in self.sent.append((text, images)) }
        bar.bindHistory(tag: tag ?? self.tag, agentName: nil, store: store)
        if let queue { bar.bindQueue(model: queue.model) }
        let statuses = Box<[String]>([]), spoken = Box<[String]>([]), drafts = Box<[Bool]>([])
        bar.onStatus = { statuses.value.append($0) }
        bar.announceHistory = { spoken.value.append($0) }
        let queueSpoken = Box<[String]>([])
        bar.announceQueue = { queueSpoken.value.append($0) }
        bar.onDraftEmptyChange = { drafts.value.append($0) }
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(bar.textView), "harness: the text view takes first responder")
        bars.append(bar)
        return Rig(window: window, bar: bar, statuses: statuses, spoken: spoken, queueSpoken: queueSpoken, draftStates: drafts)
    }

    private func keyEvent(_ code: UInt16, in window: NSWindow, modifiers: NSEvent.ModifierFlags = [],
                          timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        let chars = code == 126 ? "\u{F700}" : "\u{F701}"
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func up(_ rig: Rig, modifiers: NSEvent.ModifierFlags = [], timestamp: TimeInterval? = nil) {
        rig.textView.keyDown(with: keyEvent(126, in: rig.window, modifiers: modifiers,
                                            timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime))
    }

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

    private func writePNG(_ name: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent("pic-\(name).png")
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try png.write(to: url)
        return url
    }

    /// What pressing Send now would send, without touching the composer's state otherwise.
    private func whatWouldBeSent(_ rig: Rig) -> (text: String, images: [URL])? {
        sent = []
        rig.textView.onSubmit?()
        return sent.last
    }

    // MARK: C2-12 Up takes the newest queued message back

    func testUpOnAnEmptyComposerAsksForTheNewestTypedMessageAndLeavesTheComposerAloneUntilTheAnswer() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "older sent message")
        queue.queued([typedEntry("q-1", "fix the picker")])

        up(rig)

        XCTAssertEqual(queue.takeBacks.map(\.id), ["q-1"], "one request, for the newest queued message")
        XCTAssertEqual(text(rig), "", "the composer is unchanged until the daemon answers")
        XCTAssertTrue(rig.spoken.value.isEmpty, "and history did not run")
        XCTAssertNil(rig.bar.lastStatus)
    }

    func testTheTakenBackTextFillsTheComposerWithTheCaretAtTheEnd() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)

        queue.answer("taken_back", text: "fix the picker", images: [])

        XCTAssertEqual(text(rig), "fix the picker")
        XCTAssertEqual(caret(rig), ("fix the picker" as NSString).length)
        XCTAssertFalse(rig.bar.draftIsEmpty)
        XCTAssertEqual(rig.draftStates.value, [false], "the chips are told the composer now holds a draft")
    }

    func testTheTakenBackTextIsExactIncludingNewlinesAndSurroundingSpaces() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "x")])
        up(rig)

        queue.answer("taken_back", text: "line one\n\n  indented line two  \n", images: [])

        XCTAssertEqual(text(rig), "line one\n\n  indented line two  \n")
    }

    func testTheTakenBackImagesComeBackAttachedInOrder() throws {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        let first = try writePNG("one"), second = try writePNG("two")
        queue.queued([typedEntry("q-1", "look at these")])
        up(rig)

        queue.answer("taken_back", text: "look at these", images: [first.path, second.path])

        XCTAssertEqual(text(rig), "look at these")
        let again = try XCTUnwrap(whatWouldBeSent(rig))
        XCTAssertEqual(again.text, "look at these")
        XCTAssertEqual(again.images.map(\.path), [first.path, second.path], "the images are attached again, as sent")
    }

    func testTakingAMessageBackRemovesOnlyTheNewestMatchingHistoryEntry() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "fix the picker")    // an older send of the same words
        send(rig, "something else")
        send(rig, "fix the picker")    // the one now waiting in the queue: the newest entry
        XCTAssertEqual(store.entries(tag: tag), ["fix the picker", "something else", "fix the picker"])
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)

        queue.answer("taken_back", text: "fix the picker", images: [])

        XCTAssertEqual(store.entries(tag: tag), ["something else", "fix the picker"],
                       "it is in the composer now, not in the history it would be duplicated into")
    }

    func testTakingBackTheOnlyHistoryEntryLeavesHistoryEmpty() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "only message")
        queue.queued([typedEntry("q-1", "only message")])
        up(rig)

        queue.answer("taken_back", text: "only message", images: [])

        XCTAssertEqual(store.entries(tag: tag), [])
    }

    func testAnswerArrivingAfterThePersonStartedTypingNeverOverwritesTheDraft() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)

        type(rig, "something new I started typing")
        queue.answer("taken_back", text: "fix the picker", images: [])

        XCTAssertEqual(text(rig), "something new I started typing")
        XCTAssertTrue(store.entries(tag: tag).contains("fix the picker"), "the message is gone from the queue, so it stays recallable")
    }

    func testAQueuedSlashCommandCanBeTakenBackAndDoesNotOpenThePicker() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "/compact", command: true)])
        up(rig)

        XCTAssertEqual(queue.takeBacks.map(\.id), ["q-1"])
        queue.answer("taken_back", text: "/compact", images: [])

        XCTAssertEqual(text(rig), "/compact")
        XCTAssertFalse(rig.bar.slashPicker.isOpen, "a recalled command must not take the next key")
        XCTAssertEqual(caret(rig), 8)
    }

    func testWithNothingQueuedAHeldMessageIsWhatUpTakesBack() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([], held: "q-0")

        up(rig)

        XCTAssertEqual(queue.takeBacks.map(\.id), ["q-0"])
        queue.answer("taken_back", text: "the message the sign-in held", images: [])
        XCTAssertEqual(text(rig), "the message the sign-in held")
    }

    // MARK: C2-12 when the daemon says it is too late, or cannot say

    func testAnAlreadyDeliveredAnswerFallsBackToHistoryAndSaysAlreadySent() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "older")
        send(rig, "fix the picker")
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)
        XCTAssertEqual(text(rig), "")

        queue.answer("already_delivered")

        XCTAssertEqual(text(rig), "fix the picker", "history recall of the newest entry")
        XCTAssertEqual(rig.bar.lastStatus, "Already sent")
        XCTAssertEqual(rig.statuses.value, ["Already sent"])
        XCTAssertEqual(rig.spoken.value, ["History 1 of 2"])
        XCTAssertEqual(caret(rig), ("fix the picker" as NSString).length)
        up(rig)
        XCTAssertEqual(text(rig), "older", "it was a real history step: the next Up walks on")
    }

    func testNotFoundAndNotAllowedFallBackToHistoryWithNoStatus() {
        for code in ["not_found", "not_allowed"] {
            let queue = FakeQueue()
            let rig = makeRig(queue: queue, tag: "tag-\(code)")
            send(rig, "the newest sent")
            queue.queued([typedEntry("q-1", "x")])
            up(rig)

            queue.answer(code)

            XCTAssertEqual(text(rig), "the newest sent", code)
            XCTAssertNil(rig.bar.lastStatus, code)
            XCTAssertTrue(rig.statuses.value.isEmpty, code)
        }
    }

    func testNoAnswerInTwoSecondsLeavesTheComposerAloneAndSaysNostromoCouldNotBeReached() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "history that must not be recalled")
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)

        XCTAssertEqual(queue.timers.map(\.delay), [2])
        queue.fireTimers()

        XCTAssertEqual(text(rig), "")
        XCTAssertEqual(rig.bar.lastStatus, "Couldn't reach Nostromo")
        XCTAssertEqual(rig.statuses.value, ["Couldn't reach Nostromo"])

        queue.answer("taken_back", text: "fix the picker", images: [])
        XCTAssertEqual(text(rig), "", "a late answer is ignored: the person has moved on")
    }

    func testAWriteThatCannotBeMadeFallsBackToHistoryWithNoStatus() {
        let queue = FakeQueue()
        queue.writerAccepts = false
        let rig = makeRig(queue: queue)
        send(rig, "the newest sent")
        queue.queued([typedEntry("q-1", "x")])

        up(rig)

        XCTAssertEqual(text(rig), "the newest sent", "no connection: Up is just history")
        XCTAssertNil(rig.bar.lastStatus)
    }

    // MARK: C2-13 two windows, one request

    func testTwoComposersPressingUpForTheSameEntryMakeOneRequestAndOnlyOneIsFilled() {
        let queue = FakeQueue()
        let a = makeRig(queue: queue)
        let b = makeRig(queue: queue)
        send(a, "fix the picker")
        queue.queued([typedEntry("q-1", "fix the picker")])

        up(a)
        up(b)

        XCTAssertEqual(queue.takeBacks.count, 1, "exactly one request reaches the daemon")
        XCTAssertEqual(text(b), "fix the picker", "the other window does a history recall")
        queue.answer("taken_back", text: "fix the picker", images: [])
        XCTAssertEqual(text(a), "fix the picker", "the asking window is filled")
        XCTAssertEqual(queue.takeBacks.count, 1)
    }

    func testTheSecondWindowWithNoHistoryJustStaysEmpty() {
        let queue = FakeQueue()
        let a = makeRig(queue: queue)
        let b = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "typed on my phone")])

        up(a)
        up(b)

        XCTAssertEqual(queue.takeBacks.count, 1)
        XCTAssertEqual(text(b), "")
        queue.answer("taken_back", text: "typed on my phone", images: [])
        XCTAssertEqual(text(a), "typed on my phone")
        XCTAssertEqual(text(b), "")
    }

    // MARK: C2-14 Up takes only the newest; Edit takes the one chosen

    func testWithThreeQueuedUpTakesBackOnlyTheNewestAndTheNextUpTakesNothing() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "one"), typedEntry("q-2", "two"), typedEntry("q-3", "three")])

        up(rig)
        XCTAssertEqual(queue.takeBacks.map(\.id), ["q-3"])
        queue.answer("taken_back", text: "three", images: [])
        XCTAssertEqual(text(rig), "three")

        up(rig)                                    // the caret is at the end of a non-empty draft
        rig.textView.setSelectedRange(NSRange(location: 0, length: 0))
        up(rig)                                    // and even at the very start

        XCTAssertEqual(queue.takeBacks.map(\.id), ["q-3"], "a non-empty composer never takes another back")
        XCTAssertEqual(queue.model.entries.map(\.id), ["q-1", "q-2", "q-3"], "the model only changes by the daemon's snapshots")
    }

    func testEditTakesTheChosenOlderChipBackIntoAnEmptyComposer() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "one"), typedEntry("q-2", "two"), typedEntry("q-3", "three")])

        XCTAssertTrue(rig.bar.takeBackForEdit(id: "q-1"))

        XCTAssertEqual(queue.takeBacks.map(\.id), ["q-1"], "that one, not the newest")
        XCTAssertEqual(text(rig), "", "unchanged until the answer")
        queue.answer("taken_back", text: "one", images: [])
        XCTAssertEqual(text(rig), "one")
        XCTAssertEqual(caret(rig), 3)
    }

    func testATakeBackEndsAHistoryWalkThatWasLeftOpenSoTheNextUpStartsAFreshWalk() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "older")
        send(rig, "newer")
        up(rig)                                   // history: "newer", a walk is open
        XCTAssertEqual(text(rig), "newer")
        type(rig, "")                             // the person deletes it all; the walk is still open
        queue.queued([typedEntry("q-1", "queued text")])
        XCTAssertTrue(rig.bar.takeBackForEdit(id: "q-1"))
        queue.answer("taken_back", text: "queued text", images: [])
        XCTAssertEqual(text(rig), "queued text")

        rig.textView.setSelectedRange(NSRange(location: 0, length: 0))
        up(rig)

        XCTAssertEqual(text(rig), "newer", "a new walk starts at the newest entry, not one step further from the old walk")
    }

    func testEditDoesNothingWhileTheComposerHasTextAndRequestsNothing() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "one"), typedEntry("q-2", "two")])
        type(rig, "typing")

        XCTAssertFalse(rig.bar.takeBackForEdit(id: "q-1"))

        XCTAssertTrue(queue.takeBacks.isEmpty)
        XCTAssertEqual(text(rig), "typing")
    }

    func testEditDoesNothingWhileTheComposerHoldsOnlyAnImage() throws {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "one")])
        rig.bar.addImage(try writePNG())

        XCTAssertFalse(rig.bar.draftIsEmpty)
        XCTAssertFalse(rig.bar.takeBackForEdit(id: "q-1"))
        XCTAssertTrue(queue.takeBacks.isEmpty)
    }

    func testAnEditThatFindsTheMessageAlreadySentSaysSoAndDoesNotRecallHistory() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "previously sent")
        queue.queued([typedEntry("q-1", "one")])
        XCTAssertTrue(rig.bar.takeBackForEdit(id: "q-1"))

        queue.answer("already_delivered")

        XCTAssertEqual(text(rig), "", "Edit is not Up: no history recall")
        XCTAssertEqual(rig.bar.lastStatus, "Already sent")
    }

    func testAnEditThatGetsNoAnswerSaysNostromodCouldNotBeReached() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "one")])
        XCTAssertTrue(rig.bar.takeBackForEdit(id: "q-1"))

        queue.fireTimers()

        XCTAssertEqual(text(rig), "")
        XCTAssertEqual(rig.bar.lastStatus, "Couldn't reach Nostromo")
    }

    func testAnEditNotFoundLeavesTheComposerEmptyAndSaysNothing() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "history")
        queue.queued([typedEntry("q-1", "one")])
        XCTAssertTrue(rig.bar.takeBackForEdit(id: "q-1"))

        queue.answer("not_found")

        XCTAssertEqual(text(rig), "")
        XCTAssertNil(rig.bar.lastStatus)
    }

    func testEditAskedTwiceForTheSameChipIsOneRequest() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "one")])

        XCTAssertTrue(rig.bar.takeBackForEdit(id: "q-1"))
        XCTAssertFalse(rig.bar.takeBackForEdit(id: "q-1"))

        XCTAssertEqual(queue.takeBacks.count, 1)
    }

    // MARK: C2-15 an app message is never dug past

    func testWhenTheNewestQueuedMessageIsTheAppsUpIsHistoryAndAsksNothing() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "older")
        queue.queued([typedEntry("q-1", "mine, queued earlier"), appEntry("q-2")])

        up(rig)

        XCTAssertTrue(queue.takeBacks.isEmpty, "no request: the typed message under the app's is not Up's to take")
        XCTAssertEqual(text(rig), "older")
    }

    // MARK: C2-16 only a person's Up on an empty composer

    func testASynthesisedUpNeverTakesAMessageBackOrRecallsHistory() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "old")
        queue.queued([typedEntry("q-1", "fix the picker")])

        SyntheticInputGate.begin()
        up(rig)
        SyntheticInputGate.end()

        XCTAssertTrue(queue.takeBacks.isEmpty, "app-control cannot pull a queued message into the composer")
        XCTAssertEqual(text(rig), "")
    }

    func testAStaleOrFutureStampedUpNeverTakesAMessageBack() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        let now = ProcessInfo.processInfo.systemUptime

        up(rig, timestamp: now - 10)
        up(rig, timestamp: now + 10)

        XCTAssertTrue(queue.takeBacks.isEmpty)
    }

    func testAnUpFromAnotherWindowNeverTakesAMessageBack() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        let other = windows.make(width: 100, height: 100)
        queue.queued([typedEntry("q-1", "fix the picker")])

        rig.textView.keyDown(with: keyEvent(126, in: other))

        XCTAssertTrue(queue.takeBacks.isEmpty)
    }

    func testAnUpWithAModifierNeverTakesAMessageBack() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])

        for flag: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            up(rig, modifiers: flag)
        }

        XCTAssertTrue(queue.takeBacks.isEmpty)
    }

    func testANonEmptyComposerNeverTakesAnythingBackNoMatterWhereTheCaretIs() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])

        type(rig, "a draft", caret: 0)
        up(rig)
        type(rig, "a draft", caret: 7)
        up(rig)
        type(rig, " ", caret: 0)       // even a single space is a draft
        up(rig)

        XCTAssertTrue(queue.takeBacks.isEmpty)
    }

    func testAComposerHoldingOnlyAnImageNeverTakesAnythingBack() throws {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        rig.bar.addImage(try writePNG())

        up(rig)

        XCTAssertTrue(queue.takeBacks.isEmpty)
    }

    // MARK: C2-17 an old daemon

    func testWithoutAQueueUpIsHistoryOnly() {
        let rig = makeRig(queue: nil)
        send(rig, "older")
        send(rig, "newest")

        up(rig)
        XCTAssertEqual(text(rig), "newest")
        up(rig)
        XCTAssertEqual(text(rig), "older")
        XCTAssertNil(rig.bar.lastStatus)
    }

    func testWithAQueueThatNeverReceivedASnapshotUpIsHistoryOnly() {
        let queue = FakeQueue()      // an old daemon sends no snapshot, ever
        let rig = makeRig(queue: queue)
        send(rig, "newest")

        up(rig)

        XCTAssertTrue(queue.takeBacks.isEmpty)
        XCTAssertEqual(text(rig), "newest")
    }

    func testWithNothingQueuedUpIsHistory() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "newest")
        queue.queued([])

        up(rig)

        XCTAssertTrue(queue.takeBacks.isEmpty)
        XCTAssertEqual(text(rig), "newest")
    }

    // MARK: C2-8 Stop puts back what it dropped, for the composer that pressed it

    func testStopPutsTheDroppedMessagesBackInOrderOneBlankLineApartWithTheCaretAtTheEnd() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

        queue.returned([("first message", []), ("second message", []), ("third", [])])

        XCTAssertEqual(text(rig), "first message\n\nsecond message\n\nthird")
        XCTAssertEqual(caret(rig), ("first message\n\nsecond message\n\nthird" as NSString).length)
    }

    func testStopPutsASingleDroppedMessageBackAsIs() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

        queue.returned([("only one", [])])

        XCTAssertEqual(text(rig), "only one")
    }

    func testStopPutsTheDroppedImagesBackToo() throws {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        let one = try writePNG("a"), two = try writePNG("b")
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

        queue.returned([("with a picture", [one.path]), ("and another", [two.path])])

        XCTAssertEqual(text(rig), "with a picture\n\nand another")
        let again = whatWouldBeSent(rig)
        XCTAssertEqual(again?.images.map(\.path), [one.path, two.path])
    }

    func testStopLeavesAComposerThatHasTextAloneAndKeepsTheDroppedMessagesInHistory() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        type(rig, "typing something else")
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

        queue.returned([("dropped one", []), ("dropped two", [])])

        XCTAssertEqual(text(rig), "typing something else")
        XCTAssertTrue(store.entries(tag: tag).contains("dropped one"))
        XCTAssertTrue(store.entries(tag: tag).contains("dropped two"))
    }

    func testAfterAStopRestoreIntoABusyComposerUpRecallsTheNewestDroppedMessageFirst() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        send(rig, "an older send")
        type(rig, "typing something else")
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

        queue.returned([("dropped one", []), ("dropped two", []), ("dropped three", [])])

        XCTAssertEqual(store.entries(tag: tag), ["dropped three", "dropped two", "dropped one", "an older send"],
                       "history keeps them in the order they were sent, newest first")
        type(rig, "")
        up(rig)
        XCTAssertEqual(text(rig), "dropped three")
        up(rig)
        XCTAssertEqual(text(rig), "dropped two")
        up(rig)
        XCTAssertEqual(text(rig), "dropped one")
        up(rig)
        XCTAssertEqual(text(rig), "an older send")
    }

    // MARK: VoiceOver: what a take-back and a Stop restore say

    func testATakeBackIntoTheComposerAnnouncesMessageBackInTheComposer() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)
        XCTAssertTrue(rig.queueSpoken.value.isEmpty, "nothing is said while the request is out")

        queue.answer("taken_back", text: "fix the picker", images: [])

        XCTAssertEqual(rig.queueSpoken.value, ["Message back in the composer."])
        XCTAssertTrue(rig.spoken.value.isEmpty, "that is not a history step")
    }

    func testAnEditTakeBackAnnouncesTheSameWords() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "one"), typedEntry("q-2", "two")])
        XCTAssertTrue(rig.bar.takeBackForEdit(id: "q-1"))

        queue.answer("taken_back", text: "one", images: [])

        XCTAssertEqual(rig.queueSpoken.value, ["Message back in the composer."])
    }

    func testATakeBackAnsweredOverADraftAnnouncesHowToRecallIt() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)
        type(rig, "something I started typing")

        queue.answer("taken_back", text: "fix the picker", images: [])

        XCTAssertEqual(rig.queueSpoken.value, ["Message back. Press up to recall it."])
        XCTAssertEqual(text(rig), "something I started typing")
    }

    func testAlreadySentIsAnnouncedForAlreadyDeliveredByUpAndByEdit() {
        let up1 = FakeQueue()
        let viaUp = makeRig(queue: up1, tag: "via-up")
        send(viaUp, "previously sent")
        up1.queued([typedEntry("q-1", "x")])
        up(viaUp)
        up1.answer("already_delivered")
        XCTAssertEqual(viaUp.queueSpoken.value, ["Already sent."])
        XCTAssertEqual(viaUp.spoken.value, ["History 1 of 1"], "the history recall that follows speaks through its own seam")

        let edit1 = FakeQueue()
        let viaEdit = makeRig(queue: edit1, tag: "via-edit")
        edit1.queued([typedEntry("q-1", "x")])
        XCTAssertTrue(viaEdit.bar.takeBackForEdit(id: "q-1"))
        edit1.answer("already_delivered")
        XCTAssertEqual(viaEdit.queueSpoken.value, ["Already sent."])
    }

    func testAlreadySentIsAnnouncedOnlyForAlreadyDelivered() {
        for code in ["not_found", "not_allowed", "taken_back", "removed", "from_the_future"] {
            let queue = FakeQueue()
            let rig = makeRig(queue: queue, tag: "tag-\(code)")
            send(rig, "the newest sent")
            queue.queued([typedEntry("q-1", "the newest sent")])
            up(rig)

            queue.answer(code, text: "the newest sent", images: [])

            XCTAssertFalse(rig.queueSpoken.value.contains("Already sent."), code)
            if code == "not_found" || code == "not_allowed" || code == "removed" || code == "from_the_future" {
                XCTAssertTrue(rig.queueSpoken.value.isEmpty, "\(code): the history recall that follows is not a queue announcement")
            }
        }

        let silent = FakeQueue()
        let rig = makeRig(queue: silent, tag: "tag-timeout")
        silent.queued([typedEntry("q-1", "x")])
        up(rig)
        silent.fireTimers()
        XCTAssertTrue(rig.queueSpoken.value.isEmpty, "no answer: a status, but no announcement")
        XCTAssertEqual(rig.bar.lastStatus, "Couldn't reach Nostromo")
    }

    func testStopRestoreIntoAnEmptyComposerAnnouncesTheCountAndThatTheyAreBack() {
        for (items, words) in [(1, "1 queued message discarded, back in the composer."),
                               (2, "2 queued messages discarded, back in the composer."),
                               (5, "5 queued messages discarded, back in the composer.")] {
            let queue = FakeQueue()
            let rig = makeRig(queue: queue, tag: "tag-\(items)")
            queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

            queue.returned((0..<items).map { ("dropped \($0)", []) })

            XCTAssertEqual(rig.queueSpoken.value, [words], "\(items) dropped")
        }
    }

    func testStopRestoreIntoABusyComposerAnnouncesHowToRecallThem() {
        for (items, words) in [(1, "1 queued message discarded, press up to recall it."),
                               (2, "2 queued messages discarded, press up to recall them."),
                               (4, "4 queued messages discarded, press up to recall them.")] {
            let queue = FakeQueue()
            let rig = makeRig(queue: queue, tag: "tag-\(items)")
            type(rig, "typing")
            queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

            queue.returned((0..<items).map { ("dropped \($0)", []) })

            XCTAssertEqual(rig.queueSpoken.value, [words], "\(items) dropped")
            XCTAssertEqual(text(rig), "typing")
        }
    }

    func testAComposerThatDidNotPressStopAnnouncesNothingAboutIt() {
        let queue = FakeQueue()
        let pressed = makeRig(queue: queue)
        let bystander = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(pressed.bar))

        queue.returned([("dropped", [])])

        XCTAssertEqual(pressed.queueSpoken.value, ["1 queued message discarded, back in the composer."])
        XCTAssertTrue(bystander.queueSpoken.value.isEmpty)
    }

    func testStopLeavesAComposerThatHoldsAnImageAlone() throws {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        rig.bar.addImage(try writePNG())
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))

        queue.returned([("dropped", [])])

        XCTAssertEqual(text(rig), "")
    }

    func testAnotherComposersStopNeverTouchesThisOne() {
        let queue = FakeQueue()
        let pressed = makeRig(queue: queue)
        let bystander = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(pressed.bar))

        queue.returned([("dropped", [])])

        XCTAssertEqual(text(pressed), "dropped")
        XCTAssertEqual(text(bystander), "", "the window that did not press Stop is untouched")
    }

    func testNothingIsPutBackWhenNoStopWasPressedHere() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)

        queue.returned([("dropped", [])])

        XCTAssertEqual(text(rig), "")
    }

    func testNothingIsPutBackAFewSecondsAfterStop() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))
        queue.date = queue.date.addingTimeInterval(6)

        queue.returned([("dropped", [])])

        XCTAssertEqual(text(rig), "")
    }

    func testTheDroppedMessagesAreNotPutBackTwice() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))
        queue.returned([("dropped", [])])
        type(rig, "")
        queue.returned([("dropped", [])])
        XCTAssertEqual(text(rig), "")
    }

    // MARK: A message that comes back after the composer stopped waiting

    private static let lateStatus = "A queued message came back late. Press ↑ to recall it"

    func testATakeBackAnsweredAfterTheTimeoutIsKeptInHistoryAndTheComposerIsNotTouched() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)
        queue.fireTimers()
        XCTAssertEqual(rig.bar.lastStatus, "Couldn't reach Nostromo")
        queue.queued([])                           // the daemon's queue no longer lists it

        queue.answer("taken_back", text: "the only copy", images: [])

        XCTAssertEqual(text(rig), "", "a composer that moved on is not filled")
        XCTAssertEqual(store.entries(tag: tag), ["the only copy"])
        XCTAssertEqual(rig.bar.lastStatus, Self.lateStatus)
        XCTAssertEqual(rig.statuses.value.last, Self.lateStatus)
        up(rig)
        XCTAssertEqual(text(rig), "the only copy", "Up finds it")
    }

    func testALateTakeBackNeverOverwritesWhatThePersonTypedMeanwhile() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)
        queue.fireTimers()
        type(rig, "my new draft")

        queue.answer("taken_back", text: "the only copy", images: [])

        XCTAssertEqual(text(rig), "my new draft")
        XCTAssertTrue(store.entries(tag: tag).contains("the only copy"))
        XCTAssertEqual(caret(rig), ("my new draft" as NSString).length)
    }

    func testAnAnswerInTimeShowsNoLateStatusAndAddsNothingExtraToHistory() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.queued([typedEntry("q-1", "fix the picker")])
        up(rig)

        queue.answer("taken_back", text: "fix the picker", images: [])

        XCTAssertNotEqual(rig.bar.lastStatus, Self.lateStatus)
        XCTAssertTrue(rig.statuses.value.isEmpty)
        XCTAssertEqual(store.entries(tag: tag), [], "it is in the composer, not in history")
    }

    func testALateStopFrameIsKeptInHistoryNewestDroppedFirstAndTheComposerIsNotTouched() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))
        queue.date = queue.date.addingTimeInterval(6)

        queue.returned([("dropped one", []), ("dropped two", [])])

        XCTAssertEqual(text(rig), "")
        XCTAssertEqual(store.entries(tag: tag), ["dropped two", "dropped one"])
        XCTAssertEqual(rig.bar.lastStatus, Self.lateStatus)
        XCTAssertTrue(rig.queueSpoken.value.isEmpty, "this is a status, not a Stop-restore announcement")
        up(rig)
        XCTAssertEqual(text(rig), "dropped two")
        up(rig)
        XCTAssertEqual(text(rig), "dropped one")
    }

    func testAStopFrameInsideTheWindowIsNotAlsoKeptAsLate() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))
        queue.date = queue.date.addingTimeInterval(1)

        queue.returned([("dropped", [])])

        XCTAssertEqual(text(rig), "dropped")
        XCTAssertNotEqual(rig.bar.lastStatus, Self.lateStatus)
        XCTAssertEqual(store.entries(tag: tag), [])
    }

    func testBindingTheQueueTwiceKeepsEachLateMessageOnce() {
        let queue = FakeQueue()
        let rig = makeRig(queue: queue)
        rig.bar.bindQueue(model: queue.model)
        queue.model.noteStop(requester: ObjectIdentifier(rig.bar))
        queue.date = queue.date.addingTimeInterval(6)

        queue.returned([("dropped one", []), ("dropped two", [])])

        XCTAssertEqual(store.entries(tag: tag), ["dropped two", "dropped one"])
    }

    func testALateComposerWithoutHistoryJustStaysQuiet() {
        let queue = FakeQueue()
        let window = windows.make(width: 600, height: 60)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        window.contentView = content
        let bar = ReplInputBar(frame: content.bounds)
        content.addSubview(bar)
        bars.append(bar)
        bar.bindQueue(model: queue.model)
        queue.model.noteStop(requester: ObjectIdentifier(bar))
        queue.date = queue.date.addingTimeInterval(6)

        queue.returned([("dropped", [])])

        XCTAssertEqual(bar.textView.string, "")
    }

    func testTwoWindowsOnOneFocusKeepALateStopFrameInHistoryOnceEach() {
        let queue = FakeQueue()
        let a = makeRig(queue: queue)
        _ = makeRig(queue: queue)
        queue.model.noteStop(requester: ObjectIdentifier(a.bar))
        queue.date = queue.date.addingTimeInterval(6)

        queue.returned([("dropped one", []), ("dropped two", [])])

        XCTAssertEqual(store.entries(tag: tag), ["dropped two", "dropped one"],
                       "the history is shared: two windows must not record the same messages twice")
    }

    // MARK: A send the daemon refused for a full sign-in queue

    func testARefusedSendComesBackIntoAnEmptyComposerWithTheReason() {
        let rig = makeRig(queue: FakeQueue())
        send(rig, "please fix it")
        XCTAssertEqual(text(rig), "")

        rig.bar.restoreRefusedSend(text: "please fix it", images: [])

        XCTAssertEqual(text(rig), "please fix it")
        XCTAssertEqual(caret(rig), ("please fix it" as NSString).length)
        XCTAssertEqual(rig.bar.lastStatus, "Queue full while waiting for sign-in")
        XCTAssertEqual(rig.statuses.value, ["Queue full while waiting for sign-in"])
    }

    func testARefusedSendKeepsItsImages() throws {
        let rig = makeRig(queue: FakeQueue())
        let image = try writePNG()
        type(rig, "look")
        rig.bar.addImage(image)
        rig.textView.onSubmit?()

        rig.bar.restoreRefusedSend(text: "look", images: [image])

        XCTAssertEqual(text(rig), "look")
        XCTAssertEqual(whatWouldBeSent(rig)?.images.map(\.path), [image.path])
    }

    func testARefusedImageOnlySendComesBackAsTheImageAlone() throws {
        let rig = makeRig(queue: FakeQueue())
        let image = try writePNG()
        rig.bar.addImage(image)
        rig.textView.onSubmit?()
        XCTAssertEqual(sent.last?.text, ChatSession.imageOnlyText)

        rig.bar.restoreRefusedSend(text: ChatSession.imageOnlyText, images: [image])

        XCTAssertEqual(text(rig), "", "the stand-in text is not put in the box")
        XCTAssertFalse(rig.bar.draftIsEmpty, "the image is back")
        XCTAssertEqual(rig.bar.lastStatus, "Queue full while waiting for sign-in")
    }

    func testARefusedSendNeverOverwritesWhatThePersonTypedMeanwhileButStillSaysWhy() {
        let rig = makeRig(queue: FakeQueue())
        send(rig, "please fix it")
        type(rig, "the next thing")

        rig.bar.restoreRefusedSend(text: "please fix it", images: [])

        XCTAssertEqual(text(rig), "the next thing")
        XCTAssertEqual(rig.bar.lastStatus, "Queue full while waiting for sign-in")
    }

    func testARefusalOfAnotherWindowsSendDoesNothingHere() {
        let rig = makeRig(queue: FakeQueue())
        send(rig, "mine")

        rig.bar.restoreRefusedSend(text: "sent from the other window", images: [])

        XCTAssertEqual(text(rig), "")
        XCTAssertNil(rig.bar.lastStatus)
    }

    func testARefusalWhenNothingWasSentFromThisComposerDoesNothing() {
        let rig = makeRig(queue: FakeQueue())
        rig.bar.restoreRefusedSend(text: "never sent here", images: [])
        XCTAssertEqual(text(rig), "")
        XCTAssertNil(rig.bar.lastStatus)
    }

    func testOneRefusedSendIsRestoredOnce() {
        let rig = makeRig(queue: FakeQueue())
        send(rig, "please fix it")
        rig.bar.restoreRefusedSend(text: "please fix it", images: [])
        type(rig, "")

        rig.bar.restoreRefusedSend(text: "please fix it", images: [])

        XCTAssertEqual(text(rig), "")
    }

    // MARK: The chips learn whether the composer has a draft

    func testTheComposerReportsWhenItBecomesEmptyOrHoldsADraft() throws {
        let rig = makeRig(queue: FakeQueue())

        type(rig, "x")
        type(rig, "xy")                       // still a draft: no second report
        type(rig, "")
        rig.bar.addImage(try writePNG())
        type(rig, "typed", caret: 5)
        rig.textView.onSubmit?()

        XCTAssertEqual(rig.draftStates.value, [false, true, false, true],
                       "typed, cleared, image attached, sent")
    }
}
