import XCTest
import Combine

// `SessionQueueModel` (message queue S2): the per-focus view of the daemon's queue snapshots and of the
// take-back / remove requests this process has in flight. Pure: every outside thing it needs (the two
// request writers, the timer, the clock, the request id) is injected, so nothing here sleeps or opens a
// socket. Frames are built as the daemon's JSON and decoded, so a snapshot here is what the wire carries.
//
// Acceptance criteria exercised: C2-8 (Stop hands text back to the pressing composer only), C2-9 (lost
// messages are counted, new epoch replaces), C2-13 (one request per entry), C2-15 (Up never digs past an
// app message), and the "answer or 2 s" rule for every request.

final class SessionQueueModelTests: XCTestCase {

    // MARK: Rig

    private final class Rig {
        var takeBacks: [(id: String, requestId: String)] = []
        var removes: [(id: String, requestId: String)] = []
        var writerAccepts = true
        /// Timers the model asked for, in order; `fire` runs them (the injected clock never advances by itself).
        var timers: [(delay: TimeInterval, work: () -> Void)] = []
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        private var counter = 0
        var model: SessionQueueModel!
        var events: [SessionQueueEvent] = []
        var returns: [SessionQueueReturn] = []
        private var bag = Set<AnyCancellable>()

        init() {
            model = SessionQueueModel(
                tag: "cody-1",
                sendTakeBack: { [unowned self] id, request in
                    guard writerAccepts else { return false }
                    takeBacks.append((id, request)); return true
                },
                sendRemove: { [unowned self] id, request in
                    guard writerAccepts else { return false }
                    removes.append((id, request)); return true
                },
                after: { [unowned self] delay, work in timers.append((delay, work)) },
                now: { [unowned self] in date },
                newRequestId: { [unowned self] in counter += 1; return "req-\(counter)" })
            model.events.sink { [unowned self] in events.append($0) }.store(in: &bag)
            model.returned.sink { [unowned self] in returns.append($0); model.claimReturn() }.store(in: &bag)   // a composer that pressed Stop
        }

        func fireTimers() {
            let due = timers
            timers = []
            due.forEach { $0.work() }
        }
    }

    private let epochA = "epoch-a"
    private let epochB = "epoch-b"

    private func decodeFrame<T: Decodable>(_ json: [String: Any], as type: T.Type = T.self) -> T {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(T.self, from: data)
    }

    private func entry(_ id: String, kind: String = "typed", text: String = "hello", images: Int = 0,
                       command: Bool = false, label: String? = nil, ref: String? = nil,
                       canTakeBack: Bool? = nil) -> [String: Any] {
        var e: [String: Any] = ["id": id, "kind": kind, "text": text, "image_count": images, "command": command,
                                "can_take_back": canTakeBack ?? (kind == "typed")]
        if let label { e["app_label"] = label }
        if let ref { e["client_ref"] = ref }
        return e
    }

    private func snapshot(rev: Int, epoch: String? = nil, entries: [[String: Any]] = [],
                          held: (id: String, canTakeBack: Bool)? = nil,
                          change: (reason: String, ids: [String])? = nil) -> SessionQueueWire {
        var json: [String: Any] = ["type": "session_queue", "tag": "cody-1", "daemon_epoch": epoch ?? epochA,
                                   "rev": rev, "entries": entries]
        if let held { json["held"] = ["id": held.id, "hold_id": "hold-1", "can_take_back": held.canTakeBack] }
        if let change { json["change"] = ["reason": change.reason, "ids": change.ids] }
        return decodeFrame(json)
    }

    private func result(_ requestId: String, id: String, code: String, text: String? = nil,
                        images: [String]? = nil) -> SessionQueueResultWire {
        var json: [String: Any] = ["type": "session_queue_result", "tag": "cody-1", "request_id": requestId,
                                   "id": id, "code": code]
        if let text { json["text"] = text }
        if let images { json["images"] = images }
        return decodeFrame(json)
    }

    private func returned(_ entries: [(text: String, images: [String]?)]) -> SessionQueueReturnedWire {
        decodeFrame(["type": "session_queue_returned", "tag": "cody-1", "reason": "stopped",
                     "entries": entries.enumerated().map { i, e -> [String: Any] in
                         var d: [String: Any] = ["id": "q-\(i)", "text": e.text]
                         if let images = e.images { d["images"] = images }
                         return d
                     }])
    }

    // MARK: Snapshots: the newest of an epoch wins

    func testASnapshotIsAdoptedWholeWithTheTypedAndAppFieldsAChipNeeds() {
        let rig = Rig()
        let applied = rig.model.apply(snapshot(rev: 1, entries: [
            entry("q-1", text: "fix the picker", ref: "c-1"),
            entry("q-2", kind: "app", text: "Mother overview: PR 12", label: "mother_overview"),
            entry("q-3", text: "/compact", command: true),
            entry("q-4", text: "look", images: 2),
        ]))

        XCTAssertTrue(applied.applied)
        XCTAssertEqual(rig.model.entries.map(\.id), ["q-1", "q-2", "q-3", "q-4"])
        XCTAssertEqual(rig.model.entries.map(\.isTyped), [true, false, true, true])
        XCTAssertEqual(rig.model.entries[1].appLabel, "mother_overview")
        XCTAssertFalse(rig.model.entries[1].canTakeBack)
        XCTAssertTrue(rig.model.entries[2].isCommand)
        XCTAssertEqual(rig.model.entries[3].imageCount, 2)
        XCTAssertEqual(rig.model.entries[0].text, "fix the picker")
    }

    func testASnapshotNotNewerThanTheLastOfTheSameEpochIsDropped() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 5, entries: [entry("q-1")]))

        let equal = rig.model.apply(snapshot(rev: 5, entries: [entry("q-1"), entry("q-2")]))
        let older = rig.model.apply(snapshot(rev: 4, entries: []))

        XCTAssertFalse(equal.applied, "an equal rev is the same snapshot again")
        XCTAssertFalse(older.applied, "an older rev is a late frame")
        XCTAssertEqual(rig.model.entries.map(\.id), ["q-1"], "neither touched what is shown")
        XCTAssertEqual(equal.lostTyped, 0)
        XCTAssertEqual(older.lostTyped, 0)

        let newer = rig.model.apply(snapshot(rev: 6, entries: [entry("q-1"), entry("q-2")]))
        XCTAssertTrue(newer.applied)
        XCTAssertEqual(rig.model.entries.map(\.id), ["q-1", "q-2"])
    }

    func testADroppedStaleSnapshotSaysNothingAloudAndLosesNothing() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 5, entries: [entry("q-1")]))
        rig.events = []

        let stale = rig.model.apply(snapshot(rev: 3, entries: [], change: (reason: "session_stopped", ids: ["q-1"])))

        XCTAssertEqual(stale, SessionQueueApplied(applied: false, lostTyped: 0))
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertEqual(rig.model.entries.map(\.id), ["q-1"])
    }

    func testANewEpochReplacesEverythingEvenWithALowerRev() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 40, epoch: epochA, entries: [entry("qa-1"), entry("qa-2")]))

        let applied = rig.model.apply(snapshot(rev: 1, epoch: epochB, entries: [entry("qb-1")]))

        XCTAssertTrue(applied.applied, "the daemon restarted: its revs start again")
        XCTAssertEqual(rig.model.entries.map(\.id), ["qb-1"])
        XCTAssertEqual(rig.model.epoch, epochB)

        XCTAssertFalse(rig.model.apply(snapshot(rev: 1, epoch: epochB, entries: [])).applied,
                       "and the new epoch's own rev rule holds from then on")
    }

    func testANewEpochCountsTheTypedMessagesItShowedThatAreGone() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 7, epoch: epochA, entries: [
            entry("qa-1"), entry("qa-2", kind: "app", label: "work_item"), entry("qa-3"),
        ]))

        let applied = rig.model.apply(snapshot(rev: 1, epoch: epochB, entries: []))

        XCTAssertEqual(applied.lostTyped, 2, "two typed messages were lost; the app one is not counted")
        XCTAssertTrue(rig.model.entries.isEmpty)
    }

    func testANewEpochDoesNotCountATypedMessageThatIsStillListed() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 7, epoch: epochA, entries: [entry("q-1"), entry("q-2")]))

        let applied = rig.model.apply(snapshot(rev: 1, epoch: epochB, entries: [entry("q-2")]))

        XCTAssertEqual(applied.lostTyped, 1)
    }

    func testTheFirstSnapshotEverSeenLosesNothing() {
        let rig = Rig()
        let applied = rig.model.apply(snapshot(rev: 3, epoch: epochB, entries: [entry("q-1")]))
        XCTAssertEqual(applied, SessionQueueApplied(applied: true, lostTyped: 0))
    }

    func testSessionStoppedCountsTheTypedIdsInItsChangeAndEmptiesTheQueue() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 7, entries: [entry("q-1"), entry("q-2"), entry("q-3")]))

        let applied = rig.model.apply(snapshot(rev: 8, entries: [],
                                               change: (reason: "session_stopped", ids: ["q-1", "q-2", "q-3"])))

        XCTAssertEqual(applied, SessionQueueApplied(applied: true, lostTyped: 3))
        XCTAssertTrue(rig.model.entries.isEmpty)
    }

    func testOtherChangeReasonsLoseNothing() {
        let rig = Rig()
        var rev = 0
        for reason in ["queued", "delivered", "taken_back", "removed", "stopped"] {
            rev += 1
            let applied = rig.model.apply(snapshot(rev: rev, entries: [entry("q-1")], change: (reason: reason, ids: ["q-1"])))
            XCTAssertEqual(applied.lostTyped, 0, reason)
        }
        XCTAssertEqual(rig.model.apply(snapshot(rev: 9, entries: [entry("q-1")])).lostTyped, 0, "no change at all (a restart)")
    }

    func testTheHeldMessageIsKeptApartFromTheEntries() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 1, entries: [entry("q-1")], held: (id: "q-0", canTakeBack: true)))

        XCTAssertEqual(rig.model.held?.id, "q-0")
        XCTAssertEqual(rig.model.entries.map(\.id), ["q-1"])

        rig.model.apply(snapshot(rev: 2, entries: [entry("q-1")]))
        XCTAssertNil(rig.model.held, "a snapshot without a held message clears it")
    }

    // MARK: Events for VoiceOver

    func testQueuedAndDeliveredChangesSayWhatHappenedAndNothingElseDoes() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 1, entries: [entry("q-1")], change: (reason: "queued", ids: ["q-1"])))
        rig.model.apply(snapshot(rev: 2, entries: [entry("q-1"), entry("q-2")], change: (reason: "queued", ids: ["q-2"])))
        rig.model.apply(snapshot(rev: 3, entries: [entry("q-2")], change: (reason: "delivered", ids: ["q-1"])))
        rig.model.apply(snapshot(rev: 4, entries: [], change: (reason: "taken_back", ids: ["q-2"])))
        rig.model.apply(snapshot(rev: 5, entries: [], change: (reason: "removed", ids: [])))
        rig.model.apply(snapshot(rev: 6, entries: [], change: (reason: "stopped", ids: [])))
        rig.model.apply(snapshot(rev: 7, entries: []))

        XCTAssertEqual(rig.events, [.queued(waiting: 1), .queued(waiting: 2), .delivered])
    }

    // MARK: Which entry Up takes back

    func testUpTargetsTheNewestQueuedMessageWhenItIsTyped() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 1, entries: [entry("q-1"), entry("q-2"), entry("q-3")]))
        XCTAssertEqual(rig.model.takeBackTarget(), "q-3")
    }

    func testUpNeverDigsPastANewestAppMessage() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 1, entries: [entry("q-1"), entry("q-2", kind: "app", label: "agent_seed")]))
        XCTAssertNil(rig.model.takeBackTarget(), "the newest is the app's: history recall, not an older typed message")
    }

    func testUpIgnoresAnEntryTheDaemonSaysCannotBeTakenBack() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 1, entries: [entry("q-1", canTakeBack: false)]))
        XCTAssertNil(rig.model.takeBackTarget())
    }

    func testUpTargetsTheHeldMessageOnlyWhenNothingIsQueued() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 1, entries: [], held: (id: "q-0", canTakeBack: true)))
        XCTAssertEqual(rig.model.takeBackTarget(), "q-0")

        rig.model.apply(snapshot(rev: 2, entries: [entry("q-1")], held: (id: "q-0", canTakeBack: true)))
        XCTAssertEqual(rig.model.takeBackTarget(), "q-1", "a queued message is newer than the held one")

        rig.model.apply(snapshot(rev: 3, entries: [entry("q-1", kind: "app", label: "work_item")],
                                 held: (id: "q-0", canTakeBack: true)))
        XCTAssertNil(rig.model.takeBackTarget(), "an app message newest: not the held one either")
    }

    func testUpTargetsNothingWhenNothingIsQueuedOrHeldOrTheHeldCannotBeTakenBack() {
        let rig = Rig()
        XCTAssertNil(rig.model.takeBackTarget(), "before any snapshot")
        rig.model.apply(snapshot(rev: 1, entries: [], held: (id: "q-0", canTakeBack: false)))
        XCTAssertNil(rig.model.takeBackTarget())
        rig.model.apply(snapshot(rev: 2, entries: []))
        XCTAssertNil(rig.model.takeBackTarget())
    }

    func testTheClientRefsAreThoseOfTheTypedEntriesNowQueued() {
        let rig = Rig()
        XCTAssertTrue(rig.model.clientRefs.isEmpty)
        rig.model.apply(snapshot(rev: 1, entries: [entry("q-1", ref: "c-1"), entry("q-2"),
                                                   entry("q-3", kind: "app", label: "work_item"),
                                                   entry("q-4", ref: "c-4")]))
        XCTAssertEqual(rig.model.clientRefs, ["c-1", "c-4"])
        rig.model.apply(snapshot(rev: 2, entries: [entry("q-4", ref: "c-4")]))
        XCTAssertEqual(rig.model.clientRefs, ["c-4"])
    }

    // MARK: Requests: one per entry (C2-13)

    func testATakeBackIsWrittenOnceWithItsRequestIdAndAsksForTheEntry() {
        let rig = Rig()
        let start = rig.model.takeBack(id: "q-1") { _ in }

        XCTAssertEqual(start, .sent)
        XCTAssertEqual(rig.takeBacks.map(\.id), ["q-1"])
        XCTAssertEqual(rig.takeBacks.first?.requestId, "req-1")
        XCTAssertTrue(rig.removes.isEmpty)
    }

    func testASecondTakeBackOfTheSameEntryIsBusyUntilTheFirstIsAnswered() {
        let rig = Rig()
        var first: [TakeBackOutcome] = [], second: [TakeBackOutcome] = []
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { first.append($0) }, .sent)

        XCTAssertEqual(rig.model.takeBack(id: "q-1") { second.append($0) }, .busy)

        XCTAssertEqual(rig.takeBacks.count, 1, "the daemon is asked once")
        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "hi", images: []))
        XCTAssertEqual(first, [.takenBack(text: "hi", images: [])])
        XCTAssertTrue(second.isEmpty, "a busy request never completes: nothing was asked")
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .sent, "answered: the entry may be asked about again")
    }

    func testASecondTakeBackIsBusyUntilTheFirstTimesOut() {
        let rig = Rig()
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .sent)
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .busy)

        rig.fireTimers()

        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .sent)
    }

    func testARemoveAndATakeBackOfTheSameEntryAreAlsoOneRequest() {
        let rig = Rig()
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .sent)
        XCTAssertEqual(rig.model.remove(id: "q-1"), .busy)
        XCTAssertTrue(rig.removes.isEmpty)

        let other = Rig()
        XCTAssertEqual(other.model.remove(id: "q-1"), .sent)
        XCTAssertEqual(other.model.takeBack(id: "q-1") { _ in }, .busy)
        XCTAssertTrue(other.takeBacks.isEmpty)
    }

    func testRequestsForDifferentEntriesDoNotBlockEachOther() {
        let rig = Rig()
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .sent)
        XCTAssertEqual(rig.model.takeBack(id: "q-2") { _ in }, .sent)
        XCTAssertEqual(rig.model.remove(id: "q-3"), .sent)
        XCTAssertEqual(rig.takeBacks.map(\.id), ["q-1", "q-2"])
        XCTAssertEqual(rig.removes.map(\.id), ["q-3"])
    }

    func testARemoveIsWrittenAsARemoveAndNeedsNoCompletion() {
        let rig = Rig()
        XCTAssertEqual(rig.model.remove(id: "q-9"), .sent)
        XCTAssertEqual(rig.removes.map(\.id), ["q-9"])

        rig.model.handle(result("req-1", id: "q-9", code: "removed"))

        XCTAssertEqual(rig.model.remove(id: "q-9"), .sent, "the answer frees the entry")
    }

    // MARK: Results reach the one that asked

    private func outcome(for code: String, text: String? = nil, images: [String]? = nil) -> [TakeBackOutcome] {
        let rig = Rig()
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }
        rig.model.handle(result("req-1", id: "q-1", code: code, text: text, images: images))
        return outcomes
    }

    func testEachResultCodeReachesTheComposerAsItsOwnOutcome() {
        XCTAssertEqual(outcome(for: "taken_back", text: "fix the picker", images: ["/tmp/a.png"]),
                       [.takenBack(text: "fix the picker", images: ["/tmp/a.png"])])
        XCTAssertEqual(outcome(for: "already_delivered"), [.alreadyDelivered])
        XCTAssertEqual(outcome(for: "not_found"), [.notFound])
        XCTAssertEqual(outcome(for: "not_allowed"), [.notAllowed])
    }

    func testATakenBackResultWithoutImagesGivesAnEmptyList() {
        XCTAssertEqual(outcome(for: "taken_back", text: "hi"), [.takenBack(text: "hi", images: [])])
    }

    func testAResultCodeThisAppDoesNotKnowCountsAsNotFound() {
        XCTAssertEqual(outcome(for: "from_the_future"), [.notFound])
    }

    func testTheCompletionRunsExactlyOnceEvenIfTheAnswerIsRepeated() {
        let rig = Rig()
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }

        rig.model.handle(result("req-1", id: "q-1", code: "already_delivered"))
        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "x"))

        XCTAssertEqual(outcomes, [.alreadyDelivered])
    }

    func testAnAnswerForAnotherRequestDoesNotCompleteThisOne() {
        let rig = Rig()
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }

        rig.model.handle(result("someone-elses", id: "q-1", code: "taken_back", text: "x"))

        XCTAssertTrue(outcomes.isEmpty)
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .busy, "still waiting for its own answer")
    }

    func testTwoRequestsAreAnsweredEachToItsOwnCompletion() {
        let rig = Rig()
        var one: [TakeBackOutcome] = [], two: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { one.append($0) }
        _ = rig.model.takeBack(id: "q-2") { two.append($0) }

        rig.model.handle(result("req-2", id: "q-2", code: "not_found"))
        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "one"))

        XCTAssertEqual(one, [.takenBack(text: "one", images: [])])
        XCTAssertEqual(two, [.notFound])
    }

    // MARK: Nothing sent

    func testNothingIsStartedWhenTheRequestCouldNotBeWritten() {
        let rig = Rig()
        rig.writerAccepts = false
        var ran = false

        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in ran = true }, .unavailable)
        XCTAssertEqual(rig.model.remove(id: "q-1"), .unavailable)

        rig.fireTimers()
        XCTAssertFalse(ran, "the completion never runs for a request that never left")
        XCTAssertTrue(rig.timers.isEmpty)

        rig.writerAccepts = true
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .sent, "an unwritten request does not hold the entry")
    }

    // MARK: Timeout

    func testAnUnansweredRequestEndsAsNoAnswerAfterTwoSecondsExactlyOnce() {
        let rig = Rig()
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }

        XCTAssertEqual(rig.timers.map(\.delay), [2], "the limit is two seconds")
        XCTAssertTrue(outcomes.isEmpty, "nothing before the timer")

        rig.fireTimers()
        XCTAssertEqual(outcomes, [.noAnswer])
        rig.fireTimers()
        XCTAssertEqual(outcomes, [.noAnswer], "once")
    }

    func testALateAnswerAfterTheTimeoutIsIgnored() {
        let rig = Rig()
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }
        rig.fireTimers()

        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "late", images: []))

        XCTAssertEqual(outcomes, [.noAnswer], "the composer already moved on: the late text is not put in")
    }

    func testTheTimerOfAnAnsweredRequestDoesNothing() {
        let rig = Rig()
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }
        rig.model.handle(result("req-1", id: "q-1", code: "not_found"))

        rig.fireTimers()

        XCTAssertEqual(outcomes, [.notFound])
    }

    func testATimedOutRemoveFreesItsEntryToo() {
        let rig = Rig()
        XCTAssertEqual(rig.model.remove(id: "q-1"), .sent)
        XCTAssertEqual(rig.model.remove(id: "q-1"), .busy)
        rig.fireTimers()
        XCTAssertEqual(rig.model.remove(id: "q-1"), .sent)
    }

    // MARK: Stop (C2-8)

    private final class Marker {}

    func testStopHandsTheDroppedMessagesToTheComposerThatPressedItInOrder() {
        let rig = Rig()
        let pressed = Marker()
        rig.model.noteStop(requester: ObjectIdentifier(pressed))

        rig.model.handle(returned([("held message", nil), ("fix the picker", ["/tmp/shot-1.png"])]))

        XCTAssertEqual(rig.returns.count, 1)
        XCTAssertEqual(rig.returns.first?.requester, ObjectIdentifier(pressed))
        XCTAssertEqual(rig.returns.first?.entries,
                       [.init(text: "held message", images: []), .init(text: "fix the picker", images: ["/tmp/shot-1.png"])])
    }

    func testAReturnedFrameWithNoStopPressedHereIsNotHandedToAnyone() {
        let rig = Rig()
        rig.model.handle(returned([("orphan", nil)]))
        XCTAssertTrue(rig.returns.isEmpty, "this window did not press Stop: another connection's frame is not ours to show")
    }

    func testTheDroppedMessagesAreHandedBackOnlyOnce() {
        let rig = Rig()
        let pressed = Marker()
        rig.model.noteStop(requester: ObjectIdentifier(pressed))

        rig.model.handle(returned([("a", nil)]))
        rig.model.handle(returned([("b", nil)]))

        XCTAssertEqual(rig.returns.map { $0.entries.map(\.text) }, [["a"]])
    }

    func testAReturnedFrameWithinFiveSecondsOfStopIsHandedBackAndLaterOneIsNot() {
        let early = Rig()
        let pressed = Marker()
        early.model.noteStop(requester: ObjectIdentifier(pressed))
        early.date = early.date.addingTimeInterval(4.9)
        early.model.handle(returned([("a", nil)]))
        XCTAssertEqual(early.returns.count, 1, "4.9 s after Stop")

        let late = Rig()
        late.model.noteStop(requester: ObjectIdentifier(pressed))
        late.date = late.date.addingTimeInterval(5.1)
        late.model.handle(returned([("a", nil)]))
        XCTAssertTrue(late.returns.isEmpty, "5.1 s after Stop: the person has moved on")
    }

    func testAnEmptyReturnedFrameHandsNothingBack() {
        let rig = Rig()
        rig.model.noteStop(requester: ObjectIdentifier(Marker()))
        rig.model.handle(returned([]))
        XCTAssertTrue(rig.returns.isEmpty)
    }

    func testTheLatestStopWinsWhenTwoComposersPressedIt() {
        let rig = Rig()
        let first = Marker(), second = Marker()
        rig.model.noteStop(requester: ObjectIdentifier(first))
        rig.model.noteStop(requester: ObjectIdentifier(second))

        rig.model.handle(returned([("a", nil)]))

        XCTAssertEqual(rig.returns.map(\.requester), [ObjectIdentifier(second)])
    }

    // MARK: Text that comes back after its composer stopped waiting

    private final class Late {
        var batches: [[String]] = []
        var bag = Set<AnyCancellable>()
    }

    private func collectLate(_ rig: Rig) -> Late {
        let late = Late()
        rig.model.recoveredLate.sink { late.batches.append($0) }.store(in: &late.bag)
        return late
    }

    func testATakenBackAnswerAfterTheTimeoutIsRecoveredAndTheCompletionStaysNoAnswer() {
        let rig = Rig()
        let late = collectLate(rig)
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }
        rig.fireTimers()
        XCTAssertTrue(late.batches.isEmpty, "nothing yet: the daemon has not answered")

        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "the only copy", images: []))

        XCTAssertEqual(late.batches, [["the only copy"]])
        XCTAssertEqual(outcomes, [.noAnswer], "the composer already moved on and is not filled")
    }

    func testALateTakenBackAnswerIsRecoveredOnceEvenIfRepeated() {
        let rig = Rig()
        let late = collectLate(rig)
        _ = rig.model.takeBack(id: "q-1") { _ in }
        rig.fireTimers()

        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "x", images: []))
        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "x", images: []))

        XCTAssertEqual(late.batches, [["x"]])
    }

    func testALateAnswerThatCarriesNoTextIsNotRecovered() {
        for code in ["already_delivered", "not_found", "not_allowed", "removed", "from_the_future"] {
            let rig = Rig()
            let late = collectLate(rig)
            _ = rig.model.takeBack(id: "q-1") { _ in }
            rig.fireTimers()

            rig.model.handle(result("req-1", id: "q-1", code: code))

            XCTAssertTrue(late.batches.isEmpty, code)
        }
        let rig = Rig()
        let late = collectLate(rig)
        _ = rig.model.takeBack(id: "q-1") { _ in }
        rig.fireTimers()
        rig.model.handle(result("req-1", id: "q-1", code: "taken_back"))
        XCTAssertTrue(late.batches.isEmpty, "a taken_back with no text has nothing to keep")
        let rig2 = Rig()
        let late2 = collectLate(rig2)
        _ = rig2.model.takeBack(id: "q-1") { _ in }
        rig2.fireTimers()
        rig2.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "", images: []))
        XCTAssertTrue(late2.batches.isEmpty, "nor does an empty one")
    }

    func testALateAnswerThatIsNotATakeBackIsNotRecoveredEvenIfItCarriesText() {
        for code in ["already_delivered", "not_found", "not_allowed", "removed", "from_the_future"] {
            let rig = Rig()
            let late = collectLate(rig)
            _ = rig.model.takeBack(id: "q-1") { _ in }
            rig.fireTimers()

            rig.model.handle(result("req-1", id: "q-1", code: code, text: "text that must not be kept", images: []))

            XCTAssertTrue(late.batches.isEmpty, code)
        }
    }

    func testATakenBackAnswerInTimeIsNotRecoveredLate() {
        let rig = Rig()
        let late = collectLate(rig)
        _ = rig.model.takeBack(id: "q-1") { _ in }

        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "in time", images: []))
        rig.fireTimers()

        XCTAssertTrue(late.batches.isEmpty, "the composer got it")
    }

    func testAnAnswerForARequestThatWasNeverMadeIsNotRecovered() {
        let rig = Rig()
        let late = collectLate(rig)
        rig.model.handle(result("never-sent", id: "q-1", code: "taken_back", text: "stranger", images: []))
        XCTAssertTrue(late.batches.isEmpty)
    }

    func testALateAnswerToATimedOutRemoveIsNotRecovered() {
        let rig = Rig()
        let late = collectLate(rig)
        XCTAssertEqual(rig.model.remove(id: "q-1"), .sent)
        rig.fireTimers()

        rig.model.handle(result("req-1", id: "q-1", code: "removed"))
        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "x", images: []))

        XCTAssertTrue(late.batches.isEmpty, "a remove asked for no text")
    }

    func testAStopFrameAfterTheWindowIsRecoveredAsTextInOrderAndNotHandedToTheComposer() {
        let rig = Rig()
        let late = collectLate(rig)
        rig.model.noteStop(requester: ObjectIdentifier(Marker()))
        rig.date = rig.date.addingTimeInterval(5.1)

        rig.model.handle(returned([("held message", nil), ("fix the picker", ["/tmp/a.png"])]))

        XCTAssertEqual(late.batches, [["held message", "fix the picker"]])
        XCTAssertTrue(rig.returns.isEmpty, "the person has moved on: nothing is put in a composer")
    }

    func testAStopFrameInsideTheWindowIsHandedBackAndNotRecoveredLate() {
        let rig = Rig()
        let late = collectLate(rig)
        rig.model.noteStop(requester: ObjectIdentifier(Marker()))
        rig.date = rig.date.addingTimeInterval(4.9)

        rig.model.handle(returned([("a", nil)]))

        XCTAssertEqual(rig.returns.count, 1)
        XCTAssertTrue(late.batches.isEmpty)
    }

    func testAStopFrameThatThisWindowDidNotAskForIsNotRecovered() {
        let rig = Rig()
        let late = collectLate(rig)
        rig.date = rig.date.addingTimeInterval(60)
        rig.model.handle(returned([("someone else's stop", nil)]))
        XCTAssertTrue(late.batches.isEmpty)
    }

    func testAnEmptyLateStopFrameRecoversNothingAndASecondLateFrameIsNotRecovered() {
        let rig = Rig()
        let late = collectLate(rig)
        rig.model.noteStop(requester: ObjectIdentifier(Marker()))
        rig.date = rig.date.addingTimeInterval(6)

        rig.model.handle(returned([]))
        rig.model.handle(returned([("after", nil)]))

        XCTAssertTrue(late.batches.isEmpty)

        let again = Rig()
        let lateAgain = collectLate(again)
        again.model.noteStop(requester: ObjectIdentifier(Marker()))
        again.date = again.date.addingTimeInterval(6)
        again.model.handle(returned([("first", nil)]))
        again.model.handle(returned([("second", nil)]))
        XCTAssertEqual(lateAgain.batches, [["first"]], "one Stop, one recovery")
    }

    func testAStopFrameNoComposerClaimedIsRecoveredLateAsText() {
        let model = SessionQueueModel(tag: "t", sendTakeBack: { _, _ in true }, sendRemove: { _, _ in true })
        var late: [[String]] = []
        let sub = model.recoveredLate.sink { late.append($0) }
        model.noteStop(requester: ObjectIdentifier(Marker()))   // nobody subscribes to `returned`

        model.handle(returned([("a", nil), ("b", ["/tmp/x.png"])]))

        XCTAssertEqual(late, [["a", "b"]])
        sub.cancel()
    }

    // MARK: Reset (the connection moved to a daemon with no queue)

    func testResetForgetsTheChipsHeldMessageEpochAndRevSoTheNextSnapshotIsAdopted() {
        let rig = Rig()
        rig.model.apply(snapshot(rev: 5, epoch: epochA, entries: [entry("q-1", text: "x")]))
        XCTAssertEqual(rig.model.entries.count, 1)

        rig.model.reset()

        XCTAssertTrue(rig.model.entries.isEmpty)
        XCTAssertNil(rig.model.held)
        XCTAssertNil(rig.model.epoch)
        XCTAssertEqual(rig.model.rev, -1)
        XCTAssertTrue(rig.model.apply(snapshot(rev: 1, epoch: epochA, entries: [entry("q-2", text: "y")])).applied,
                      "a lower rev of the same epoch is adopted after a reset")
    }

    func testResetEndsATakeBackInFlightAsNoAnswerAndAnAnswerAfterItIsIgnored() {
        let rig = Rig()
        let late = collectLate(rig)
        var outcomes: [TakeBackOutcome] = []
        _ = rig.model.takeBack(id: "q-1") { outcomes.append($0) }

        rig.model.reset()
        rig.model.handle(result("req-1", id: "q-1", code: "taken_back", text: "x", images: []))
        rig.fireTimers()

        XCTAssertEqual(outcomes, [.noAnswer], "run exactly once")
        XCTAssertEqual(rig.model.takeBack(id: "q-1") { _ in }, .sent, "the entry is free again")
        XCTAssertTrue(late.batches.isEmpty)
    }

    // MARK: The notice words

    func testTheNotSentNoticeNamesTheCountAndTellsThePersonHowToRecall() {
        XCTAssertEqual(SessionQueueNotice.text(count: 1), "1 queued message was not sent. Press ↑ to recall it.")
        XCTAssertEqual(SessionQueueNotice.text(count: 3), "3 queued messages were not sent. Press ↑ to recall them.")
    }
}
