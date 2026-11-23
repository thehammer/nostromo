import XCTest
import Combine

// `ChatSession` against a daemon that advertises `session_queue_v1` (message queue S2).
//
// What the person sees: a message sent while the agent is busy is a chip (the daemon's snapshot), never a
// transcript bubble; the bubble appears once, when the daemon delivers it. Several windows show the same
// queue. Messages lost with the session or the daemon leave one notice in the transcript that survives a
// re-attach. A daemon without the feature behaves exactly as before.
//
// Rig: a real `NostromodClient` connected to a scripted `FakeDaemon` (NostromodClientHandshakeTests.swift)
// over a real socket. That is how the test sees the frames the client writes (the `client_ref` of a send,
// the `session_queue_watch`, a take-back request). Server frames are fed straight to `client.messages`,
// the way ChatSessionDetachTests and SlashCommandEchoTests do.
//
// ChatSession, NostromodClient, SessionQueueModel and the turn types are compiled into this target
// directly (logic test, no host app).

final class ChatSessionQueueTests: XCTestCase {

    private let tag = "test"
    private var daemon: FakeDaemon!
    private var client: NostromodClient!
    private var session: ChatSession!
    private var changes: [TurnChange] = []
    private var subscription: AnyCancellable?
    private var bag = Set<AnyCancellable>()

    override func tearDown() {
        closeRig()
        super.tearDown()
    }

    private func closeRig() {
        subscription?.cancel()
        subscription = nil
        bag = []
        session = nil
        client = nil          // the client reconnects only while it is alive
        daemon?.stop()
        daemon = nil
    }

    // MARK: Rig

    /// A connected client and a `ChatSession` for `tag`, once the session has attached.
    private func connect(features: [String]?, nonce: String? = nil, end: FakeDaemon.Script.End = .never,
                         tag: String? = nil) throws {
        daemon = FakeDaemon(scripts: [.init(features: features, end: end, operatorNonce: nonce)])
        try daemon.start()
        client = NostromodClient(socketPath: daemon.path)
        client.start()
        session = ChatSession(tag: tag ?? self.tag, agentName: "cody", displayName: "Cody", workingDirectory: nil, client: client)
        changes = []
        subscription = session.changes.sink { [weak self] in self?.changes.append($0) }
        XCTAssertTrue(pumpUntil { self.client.connected.value && self.session.attachCount >= 1 },
                      "the session never attached to the fake daemon")
    }

    private let queueDaemon = [sessionQueueFeature]

    private func pumpUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    /// Frames of `type` on the first connection once a later frame proves everything before it arrived.
    private func written(_ type: String, connection: Int = 0) -> [FakeDaemon.Frame] {
        let marker = "marker-\(UUID().uuidString.prefix(6))"
        client.sessionAttach(tag: marker)
        XCTAssertTrue(pumpUntil { self.daemon.frames(connection: connection, ofType: "session_attach").contains { $0.tag == marker } },
                      "the marker frame never arrived")
        return daemon.frames(connection: connection, ofType: type)
    }

    private func sends() -> [FakeDaemon.Frame] { written("session_send") }

    private func deliver(_ msg: ServerMsg) {
        client.messages.send(msg)
        modelFlushMain()
    }

    private func feed(_ json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let type = json["type"] as! String
        deliver(client.decode(type_: type, json: json, raw: data))
    }

    private func entry(_ id: String, text: String = "hello", kind: String = "typed", ref: String? = nil,
                       label: String? = nil) -> [String: Any] {
        var e: [String: Any] = ["id": id, "kind": kind, "text": text, "image_count": 0, "command": false,
                                "can_take_back": kind == "typed"]
        if let ref { e["client_ref"] = ref }
        if let label { e["app_label"] = label }
        return e
    }

    private func snapshot(rev: Int, epoch: String = "epoch-a", entries: [[String: Any]] = [],
                          change: (reason: String, ids: [String])? = nil, tag: String? = nil) {
        var json: [String: Any] = ["type": "session_queue", "tag": tag ?? self.tag, "daemon_epoch": epoch,
                                   "rev": rev, "entries": entries]
        if let change { json["change"] = ["reason": change.reason, "ids": change.ids] }
        feed(json)
    }

    private func setRunning(_ running: Bool) {
        deliver(.sessionState(tag: tag, state: running ? .midTurn : .idle))
    }

    private func daemonTurn(_ id: String, _ text: String, second: Int, complete: Bool = true) -> DaemonTurn {
        DaemonTurn(id: id, userInput: text, timestamp: String(format: "2026-11-22T12:00:%02d.000000Z", second),
                   blocks: [], isComplete: complete)
    }

    private func attachSnapshot(_ turns: [DaemonTurn]) {
        deliver(.sessionTurns(tag: tag, turns: turns))
    }

    private func turnStarted(_ turn: DaemonTurn) {
        deliver(.sessionTurnDelta(tag: tag, delta: .turnStarted(turn)))
    }

    private func notSentMarkers() -> [Int] {
        session.turns.compactMap { if case .queuedNotSent(let n)? = $0.marker { return n } else { return nil } }
    }

    private func texts() -> [String] { session.turns.filter { $0.marker == nil }.map(\.userInput) }

    private func clientRef(ofSend index: Int = 0) throws -> String {
        let frames = sends()
        XCTAssertGreaterThan(frames.count, index, "the send never reached the daemon")
        return try XCTUnwrap(frames[index].json["client_ref"] as? String, "the send carries no client_ref")
    }

    private func removedFrom() -> [Int] {
        changes.compactMap { if case .spliced(let from) = $0 { return from } else { return nil } }
    }

    // MARK: C2-1 a message sent while the agent is busy is a chip, not a bubble

    func testSendingWhileTheAgentIsBusyAddsNoTurnAndStillReachesTheDaemonWithAClientRef() throws {
        try connect(features: queueDaemon)
        attachSnapshot([daemonTurn("t0", "first", second: 1, complete: false)])
        setRunning(true)
        changes = []

        session.send("second message")

        XCTAssertEqual(texts(), ["first"], "no echo: the message is a chip, not a transcript bubble")
        XCTAssertTrue(changes.isEmpty, "the transcript did not change: \(changes)")
        let frame = try XCTUnwrap(sends().first)
        XCTAssertEqual(frame.json["text"] as? String, "second message")
        XCTAssertFalse(try clientRef().isEmpty)
        XCTAssertTrue(session.isRunning)
    }

    func testSeveralSendsWhileBusyAddNoTurnsAndEachCarriesItsOwnClientRef() throws {
        try connect(features: queueDaemon)
        setRunning(true)

        session.send("one")
        session.send("two")
        session.send("three")

        XCTAssertTrue(session.turns.isEmpty)
        let refs = try (0..<3).map { try clientRef(ofSend: $0) }
        XCTAssertEqual(Set(refs).count, 3, "refs are unique per send")
        XCTAssertEqual(sends().map { $0.json["text"] as? String }, ["one", "two", "three"])
    }

    func testAnIdleSendShowsTheEchoAtOnceAsToday() throws {
        try connect(features: queueDaemon)

        session.send("hello there")

        XCTAssertEqual(texts(), ["hello there"])
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(changes.contains { if case .appended(index: 0) = $0 { return true } else { return false } })
    }

    func testAnIdleSlashCommandStillGetsItsPendingEcho() throws {
        try connect(features: queueDaemon + [NostromodClient.slashCommandsFeature])

        session.send("/context")

        XCTAssertEqual(session.turns.count, 1)
        XCTAssertTrue(session.turns[0].isPendingCommandEcho)
    }

    func testAnIdleSendThatTheDaemonQueuedAnywayLosesItsEchoWhenTheSnapshotListsItsClientRef() throws {
        try connect(features: queueDaemon)
        session.send("hello there")
        XCTAssertEqual(session.turns.count, 1)
        let ref = try clientRef()
        changes = []

        snapshot(rev: 1, entries: [entry("q-1", text: "hello there", ref: ref)], change: (reason: "queued", ids: ["q-1"]))

        XCTAssertTrue(session.turns.isEmpty, "queued, so a chip: the echo must not stay as a bubble too")
        XCTAssertEqual(session.queue.entries.map(\.text), ["hello there"])
        XCTAssertEqual(removedFrom(), [0], "the view of the echo is released")
    }

    func testASnapshotThatDoesNotListTheSendsClientRefLeavesItsEchoAlone() throws {
        try connect(features: queueDaemon)
        session.send("hello there")

        snapshot(rev: 1, entries: [entry("q-1", text: "from my phone", ref: "phone-ref")])
        snapshot(rev: 2, entries: [])

        XCTAssertEqual(texts(), ["hello there"])
    }

    func testAnEchoThatTheDaemonDeliveredAtOnceIsAdoptedByItsTurnNotDuplicated() throws {
        try connect(features: queueDaemon)
        session.send("hello there")

        turnStarted(daemonTurn("t0", "hello there", second: 1, complete: false))

        XCTAssertEqual(texts(), ["hello there"], "one bubble")
        XCTAssertEqual(session.turns.first?.daemonId, "t0")
    }

    // MARK: C2-2 delivery: one bubble, after the previous reply

    func testAQueuedMessageBecomesExactlyOneBubbleAfterThePreviousTurnWhenTheDaemonDeliversIt() throws {
        try connect(features: queueDaemon)
        attachSnapshot([daemonTurn("t0", "first", second: 1, complete: false)])
        setRunning(true)
        session.send("second")
        let ref = try clientRef()
        snapshot(rev: 1, entries: [entry("q-1", text: "second", ref: ref)], change: (reason: "queued", ids: ["q-1"]))
        XCTAssertEqual(texts(), ["first"], "waiting: a chip, no bubble")

        snapshot(rev: 2, entries: [], change: (reason: "delivered", ids: ["q-1"]))
        turnStarted(daemonTurn("t1", "second", second: 2, complete: false))

        XCTAssertEqual(texts(), ["first", "second"], "one bubble, after the reply it waited for")
        XCTAssertTrue(session.queue.entries.isEmpty)
        XCTAssertEqual(session.turns.last?.daemonId, "t1")
    }

    func testTheBubbleOfADeliveredMessageIsNotDuplicatedWhenTheTurnArrivesBeforeTheSnapshot() throws {
        try connect(features: queueDaemon)
        setRunning(true)
        session.send("second")
        let ref = try clientRef()
        snapshot(rev: 1, entries: [entry("q-1", text: "second", ref: ref)])

        turnStarted(daemonTurn("t1", "second", second: 2, complete: false))
        snapshot(rev: 2, entries: [], change: (reason: "delivered", ids: ["q-1"]))

        XCTAssertEqual(texts(), ["second"])
    }

    func testTwoQueuedMessagesAreDeliveredAsTwoBubblesInOrder() throws {
        try connect(features: queueDaemon)
        setRunning(true)
        session.send("alpha")
        session.send("beta")
        let refs = try (0..<2).map { try clientRef(ofSend: $0) }
        snapshot(rev: 1, entries: [entry("q-1", text: "alpha", ref: refs[0]), entry("q-2", text: "beta", ref: refs[1])])

        turnStarted(daemonTurn("t1", "alpha", second: 2))
        snapshot(rev: 2, entries: [entry("q-2", text: "beta", ref: refs[1])], change: (reason: "delivered", ids: ["q-1"]))
        turnStarted(daemonTurn("t2", "beta", second: 3))
        snapshot(rev: 3, entries: [], change: (reason: "delivered", ids: ["q-2"]))

        XCTAssertEqual(texts(), ["alpha", "beta"])
    }

    // MARK: C2-5 every window shows the same queue

    func testTwoSessionsFedTheSameSnapshotsShowIdenticalEntriesWhoeverSentThem() throws {
        try connect(features: queueDaemon)
        let otherClient = NostromodClient(socketPath: "/dev/null")
        otherClient.setAdvertisedFeaturesForTesting(queueDaemon)
        let other = ChatSession(tag: tag, agentName: "cody", displayName: "Cody", workingDirectory: nil, client: otherClient)
        setRunning(true)
        session.send("typed here")
        let ref = try clientRef()
        let frames: [[String: Any]] = [
            ["type": "session_queue", "tag": tag, "daemon_epoch": "epoch-a", "rev": 1,
             "entries": [entry("q-1", text: "typed here", ref: ref),
                         entry("q-2", text: "Mother overview: PR 12", kind: "app", label: "mother_overview"),
                         entry("q-3", text: "from the phone", ref: "phone-ref")]],
            ["type": "session_queue", "tag": tag, "daemon_epoch": "epoch-a", "rev": 2,
             "entries": [entry("q-2", text: "Mother overview: PR 12", kind: "app", label: "mother_overview"),
                         entry("q-3", text: "from the phone", ref: "phone-ref")],
             "change": ["reason": "delivered", "ids": ["q-1"]]],
        ]

        for json in frames {
            let data = try JSONSerialization.data(withJSONObject: json)
            let msg = client.decode(type_: "session_queue", json: json, raw: data)
            client.messages.send(msg)
            otherClient.messages.send(msg)
            modelFlushMain()
        }

        XCTAssertEqual(session.queue.entries, other.queue.entries)
        XCTAssertEqual(session.queue.entries.map(\.id), ["q-2", "q-3"])
        XCTAssertTrue(other.turns.isEmpty, "the window that did not send shows no bubble for it")
    }

    func testAnEntryTypedElsewhereIsAnOrdinaryChipThatCanBeTakenBack() throws {
        try connect(features: queueDaemon)
        setRunning(true)

        snapshot(rev: 1, entries: [entry("q-9", text: "typed on my phone", ref: "phone-ref")])

        XCTAssertEqual(session.queue.entries.count, 1)
        let chip = session.queue.entries[0]
        XCTAssertTrue(chip.isTyped)
        XCTAssertTrue(chip.canTakeBack)
        XCTAssertEqual(session.queue.takeBackTarget(), "q-9")
        XCTAssertTrue(session.turns.isEmpty, "nothing of ours to retire, nothing to add")
    }

    func testAFrameForAnotherFocusIsIgnored() throws {
        try connect(features: queueDaemon)

        snapshot(rev: 1, entries: [entry("q-1")], tag: "someone-else")

        XCTAssertTrue(session.queue.entries.isEmpty)
    }

    // MARK: C2-9 messages lost with the session or the daemon

    func testAStoppedSessionDropsTheChipsAndLeavesOneNoticeCountingTheTypedMessages() throws {
        try connect(features: queueDaemon)
        attachSnapshot([daemonTurn("t0", "first", second: 1)])
        snapshot(rev: 1, entries: [entry("q-1"), entry("q-2"), entry("q-3", kind: "app", label: "work_item")])

        snapshot(rev: 2, entries: [], change: (reason: "session_stopped", ids: ["q-1", "q-2"]))

        XCTAssertTrue(session.queue.entries.isEmpty)
        XCTAssertEqual(notSentMarkers(), [2], "exactly one notice, counting the two typed messages")
        XCTAssertEqual(session.turns.last?.marker, .queuedNotSent(count: 2))
        XCTAssertEqual(texts(), ["first"])
    }

    func testTheSameStoppedSnapshotAgainOrAStaleOneAddsNoSecondNotice() throws {
        try connect(features: queueDaemon)
        snapshot(rev: 1, entries: [entry("q-1")])

        snapshot(rev: 2, entries: [], change: (reason: "session_stopped", ids: ["q-1"]))
        snapshot(rev: 2, entries: [], change: (reason: "session_stopped", ids: ["q-1"]))
        snapshot(rev: 1, entries: [entry("q-1")])

        XCTAssertEqual(notSentMarkers(), [1])
        XCTAssertTrue(session.queue.entries.isEmpty, "the stale snapshot did not bring the chip back")
    }

    func testAStoppedSessionWithNoTypedMessagesLeavesNoNotice() throws {
        try connect(features: queueDaemon)
        snapshot(rev: 1, entries: [entry("q-1", kind: "app", label: "agent_seed")])

        snapshot(rev: 2, entries: [], change: (reason: "session_stopped", ids: []))

        XCTAssertTrue(notSentMarkers().isEmpty)
    }

    func testADaemonRestartThatLostQueuedTypedMessagesLeavesOneNoticeWithTheRightCount() throws {
        try connect(features: queueDaemon)
        snapshot(rev: 30, epoch: "epoch-a", entries: [entry("qa-1"), entry("qa-2"), entry("qa-3"),
                                                      entry("qa-4", kind: "app", label: "work_item")])

        snapshot(rev: 1, epoch: "epoch-b", entries: [])

        XCTAssertEqual(notSentMarkers(), [3])
        XCTAssertTrue(session.queue.entries.isEmpty)
    }

    func testADaemonRestartWithNothingTypedQueuedLeavesNoNotice() throws {
        try connect(features: queueDaemon)
        snapshot(rev: 30, epoch: "epoch-a", entries: [])
        snapshot(rev: 1, epoch: "epoch-b", entries: [])
        XCTAssertTrue(notSentMarkers().isEmpty)
    }

    func testTheNoticeSurvivesAReattachOnceWithNoGapMarkerAndNoDuplicatedTurns() throws {
        try connect(features: queueDaemon)
        let history = [daemonTurn("t0", "one", second: 1), daemonTurn("t1", "two", second: 2)]
        attachSnapshot(history)
        snapshot(rev: 1, entries: [entry("q-1")])
        snapshot(rev: 2, entries: [], change: (reason: "session_stopped", ids: ["q-1"]))
        XCTAssertEqual(session.turns.count, 3)

        for round in 1...3 {
            attachSnapshot(history.map { DaemonTurn(id: "r\(round)-\($0.id)", userInput: $0.userInput,
                                                   timestamp: $0.timestamp, blocks: [], isComplete: true) })

            XCTAssertEqual(notSentMarkers(), [1], "round \(round): the notice stays, once")
            XCTAssertEqual(texts(), ["one", "two"], "round \(round): no duplicated turns")
            XCTAssertFalse(session.turns.contains { $0.isGapMarker }, "round \(round): no 'history missing' marker")
            XCTAssertEqual(session.turns.count, 3, "round \(round)")
            XCTAssertEqual(session.turns.last?.marker, .queuedNotSent(count: 1), "round \(round): still after the last turn")
        }
    }

    func testTheNoticeStaysWhereItWasWhenAReattachBringsNewerTurns() throws {
        try connect(features: queueDaemon)
        attachSnapshot([daemonTurn("t0", "one", second: 1), daemonTurn("t1", "two", second: 2)])
        snapshot(rev: 1, entries: [entry("q-1")])
        snapshot(rev: 2, entries: [], change: (reason: "session_stopped", ids: ["q-1"]))

        attachSnapshot([daemonTurn("t0", "one", second: 1), daemonTurn("t1", "two", second: 2),
                        daemonTurn("t2", "three", second: 3)])

        XCTAssertEqual(session.turns.map { $0.marker == nil ? $0.userInput : "[notice]" }, ["one", "two", "[notice]", "three"])
        XCTAssertFalse(session.turns.contains { $0.isGapMarker })
    }

    func testAReattachDoesNotAnnounceTheNoticeAsAChangeToTheTurnsBeforeIt() throws {
        try connect(features: queueDaemon)
        let history = [daemonTurn("t0", "one", second: 1), daemonTurn("t1", "two", second: 2)]
        attachSnapshot(history)
        snapshot(rev: 1, entries: [entry("q-1")])
        snapshot(rev: 2, entries: [], change: (reason: "session_stopped", ids: ["q-1"]))
        let before = session.turns.map(\.id)
        changes = []

        attachSnapshot(history)

        XCTAssertEqual(session.turns.map(\.id), before, "every turn view, the notice included, keeps its identity")
        XCTAssertFalse(changes.contains { if case .cleared = $0 { return true } else { return false } })
    }

    // MARK: C2-6 the watch follows every attach

    func testTheWatchIsSentOnEveryConnectionTheSessionAttachesOn() throws {
        try connect(features: queueDaemon, end: .afterFirstAttach(delay: 0.1))

        XCTAssertTrue(pumpUntil(10) { self.daemon.connectionCount >= 2 && self.session.attachCount >= 2 },
                      "the client never reconnected and re-attached")
        XCTAssertTrue(pumpUntil { !self.daemon.frames(connection: 1, ofType: "session_queue_watch").isEmpty },
                      "the second connection never got a watch")

        for connection in 0..<2 {
            let watches = daemon.frames(connection: connection, ofType: "session_queue_watch")
            XCTAssertEqual(watches.count, 1, "connection \(connection): one watch per attach")
            XCTAssertEqual(watches.first?.tag, tag, "connection \(connection)")
        }
    }

    // MARK: Review fixes (round 2)

    func testAReconnectToADaemonWithoutTheQueueClearsTheChips() throws {
        daemon = FakeDaemon(scripts: [.init(features: queueDaemon, end: .afterFirstAttach(delay: 0.5)),
                                      .init(features: [], end: .never)])
        try daemon.start()
        client = NostromodClient(socketPath: daemon.path)
        client.start()
        session = ChatSession(tag: tag, agentName: "cody", displayName: "Cody", workingDirectory: nil, client: client)
        XCTAssertTrue(pumpUntil { self.client.connected.value && self.session.attachCount >= 1 })
        snapshot(rev: 1, entries: [entry("q-1", text: "waiting")])
        XCTAssertEqual(session.queue.entries.map(\.text), ["waiting"])

        XCTAssertTrue(pumpUntil(10) { self.daemon.connectionCount >= 2 && self.session.attachCount >= 2 },
                      "the client never reconnected")

        XCTAssertTrue(pumpUntil { self.session.queue.entries.isEmpty },
                      "the old daemon holds no queue: the chips must go")
        XCTAssertNil(session.queue.takeBackTarget(), "Up must not try to take back a message that is gone")
    }

    func testAnAdoptedEchoOfAnotherMessageWithTheSameTextSurvivesOurOwnQueuedSnapshot() throws {
        try connect(features: queueDaemon)
        session.send("yes")                                   // idle: echo, no daemonId
        let ref = try clientRef()
        // A phone's "yes" was delivered first; the echo adopts that turn by its text.
        turnStarted(daemonTurn("t-phone", "yes", second: 1, complete: false))
        XCTAssertEqual(session.turns.first?.daemonId, "t-phone")

        // Our own "yes" was queued behind it: its snapshot must not delete the really delivered turn.
        snapshot(rev: 1, entries: [entry("q-1", text: "yes", ref: ref)], change: (reason: "queued", ids: ["q-1"]))

        XCTAssertEqual(texts(), ["yes"])
        XCTAssertEqual(session.turns.first?.daemonId, "t-phone")
    }

    // MARK: C2-17 an old daemon: today's behaviour

    func testAnOldDaemonGetsNoWatchAndASendWithNoClientRef() throws {
        for features in [nil, [], ["work", "model"]] as [[String]?] {
            try connect(features: features)

            session.send("hello")

            let frame = try XCTUnwrap(sends().first, "features \(String(describing: features))")
            XCTAssertNil(frame.json["client_ref"], "features \(String(describing: features))")
            XCTAssertTrue(written("session_queue_watch").isEmpty, "features \(String(describing: features))")
            closeRig()
        }
    }

    func testAnOldDaemonKeepsTheEchoEvenWhileTheAgentIsBusy() throws {
        try connect(features: ["work", "model"])
        attachSnapshot([daemonTurn("t0", "first", second: 1, complete: false)])
        setRunning(true)

        session.send("second message")

        XCTAssertEqual(texts(), ["first", "second message"], "today: the echo shows at once, busy or not")
        XCTAssertTrue(session.queue.entries.isEmpty)
    }

    func testAnOldDaemonsEchoIsAdoptedByItsTurnNotDuplicated() throws {
        try connect(features: nil)
        setRunning(true)
        session.send("second message")

        turnStarted(daemonTurn("t1", "second message", second: 2, complete: false))

        XCTAssertEqual(texts(), ["second message"])
        XCTAssertEqual(session.turns.first?.daemonId, "t1")
    }

    func testAnIdleSendToAnOldDaemonShowsTheEchoAndMarksTheSessionRunning() throws {
        try connect(features: nil)
        session.send("hello")
        XCTAssertEqual(texts(), ["hello"])
        XCTAssertTrue(session.isRunning)
    }

    // MARK: A send the daemon refuses because the sign-in queue is full

    private func collectRefusals() -> () -> [(text: String, images: [URL])] {
        var refusals: [(text: String, images: [URL])] = []
        session.sendRefused.sink { refusals.append((text: $0.text, images: $0.images)) }.store(in: &bag)
        return { refusals }
    }

    private static let queueFull = "waiting_for_sign_in: queue full"

    func testASendRefusedForAFullSignInQueueComesBackWithItsTextAndImagesAndLosesItsEcho() throws {
        try connect(features: queueDaemon)
        let refusals = collectRefusals()
        let image = URL(fileURLWithPath: "/tmp/refused-shot.png")
        session.send("please fix it", images: [image])
        XCTAssertEqual(texts(), ["please fix it"])

        deliver(.error("session_send refused — \(Self.queueFull) (limit 20)"))

        XCTAssertEqual(refusals().map(\.text), ["please fix it"])
        XCTAssertEqual(refusals().first?.images, [image])
        XCTAssertTrue(session.turns.isEmpty, "the refused message is not a bubble")
    }

    func testARefusalOfASendMadeWhileBusyStillComesBack() throws {
        try connect(features: queueDaemon)
        setRunning(true)
        let refusals = collectRefusals()
        session.send("while busy")

        deliver(.error(Self.queueFull))

        XCTAssertEqual(refusals().map(\.text), ["while busy"])
    }

    func testOneRefusalIsOneRestoreEvenIfTheErrorIsRepeated() throws {
        try connect(features: queueDaemon)
        let refusals = collectRefusals()
        session.send("only once")

        deliver(.error(Self.queueFull))
        deliver(.error(Self.queueFull))

        XCTAssertEqual(refusals().count, 1)
    }

    func testAnUnrelatedErrorRestoresNothingAndKeepsTheEcho() throws {
        try connect(features: queueDaemon)
        let refusals = collectRefusals()
        session.send("keep me")

        deliver(.error("unknown session tag"))
        deliver(.error("rate limited"))

        XCTAssertTrue(refusals().isEmpty)
        XCTAssertEqual(texts(), ["keep me"])
    }

    func testAFullQueueErrorWithNoSendJustMadeRestoresNothing() throws {
        try connect(features: queueDaemon)
        let refusals = collectRefusals()

        deliver(.error(Self.queueFull))

        XCTAssertTrue(refusals().isEmpty)
    }

    func testAFullQueueErrorLongAfterTheSendIsNotThatSendsRefusal() throws {
        try connect(features: queueDaemon)
        let refusals = collectRefusals()
        session.send("an old send")
        RunLoop.main.run(until: Date().addingTimeInterval(ChatSession.refusalWindow + 0.3))

        deliver(.error(Self.queueFull))

        XCTAssertTrue(refusals().isEmpty, "the frame names no session: only a send in the last few seconds can be meant")
        XCTAssertEqual(texts(), ["an old send"])
    }

    /// Two focuses of one process share the one client, so an `error` frame reaches both of their sessions.
    private func twoSessionsOnOneClient() -> (a: ChatSession, b: ChatSession, refusalsA: () -> [String], refusalsB: () -> [String]) {
        client = NostromodClient(socketPath: "/dev/null")
        client.setAdvertisedFeaturesForTesting(queueDaemon)
        let a = ChatSession(tag: "focus-a", agentName: "cody", displayName: "Cody", workingDirectory: nil, client: client)
        let b = ChatSession(tag: "focus-b", agentName: "cody", displayName: "Cody", workingDirectory: nil, client: client)
        var gotA: [String] = [], gotB: [String] = []
        a.sendRefused.sink { gotA.append($0.text) }.store(in: &bag)
        b.sendRefused.sink { gotB.append($0.text) }.store(in: &bag)
        return (a, b, { gotA }, { gotB })
    }

    private func userTexts(_ session: ChatSession) -> [String] { session.turns.filter { $0.marker == nil }.map(\.userInput) }

    func testOnlyTheFocusThatSentLastClaimsAFullQueueError() throws {
        let rig = twoSessionsOnOneClient()
        rig.a.send("from A")
        rig.b.send("from B")

        deliver(.error(Self.queueFull))

        XCTAssertEqual(rig.refusalsB(), ["from B"], "B sent last: the refusal is B's")
        XCTAssertTrue(rig.refusalsA().isEmpty, "A must not restore its own message for B's refusal")
        XCTAssertEqual(userTexts(rig.a), ["from A"], "A's echo stays")
        XCTAssertEqual(userTexts(rig.b), [], "B's echo goes")
    }

    func testTheOtherOrderGivesTheOtherFocusTheRefusal() throws {
        let rig = twoSessionsOnOneClient()
        rig.b.send("from B")
        rig.a.send("from A")

        deliver(.error(Self.queueFull))

        XCTAssertEqual(rig.refusalsA(), ["from A"])
        XCTAssertTrue(rig.refusalsB().isEmpty)
        XCTAssertEqual(userTexts(rig.b), ["from B"])
        XCTAssertEqual(userTexts(rig.a), [])
    }

    func testAFocusThatSendsAgainTakesTheClaimBack() throws {
        let rig = twoSessionsOnOneClient()
        rig.a.send("A one")
        rig.b.send("B one")
        rig.a.send("A two")

        deliver(.error(Self.queueFull))

        XCTAssertEqual(rig.refusalsA(), ["A two"])
        XCTAssertTrue(rig.refusalsB().isEmpty)
    }

    func testAClaimedRefusalIsNotClaimedAgainByTheOtherFocusOnARepeat() throws {
        let rig = twoSessionsOnOneClient()
        rig.a.send("from A")
        rig.b.send("from B")

        deliver(.error(Self.queueFull))
        deliver(.error(Self.queueFull))

        XCTAssertEqual(rig.refusalsB(), ["from B"])
        XCTAssertTrue(rig.refusalsA().isEmpty, "the repeat is not A's either: it did not send last")
    }

    func testAnOldDaemonsErrorIsNeverTreatedAsARefusal() throws {
        try connect(features: ["work"])
        let refusals = collectRefusals()
        session.send("old behaviour")

        deliver(.error(Self.queueFull))

        XCTAssertTrue(refusals().isEmpty)
        XCTAssertEqual(texts(), ["old behaviour"])
    }

    // MARK: Stop

    private func returnedFrame(_ texts: [String]) -> [String: Any] {
        ["type": "session_queue_returned", "tag": tag, "reason": "stopped",
         "entries": texts.enumerated().map { ["id": "q-\($0.offset)", "text": $0.element] as [String: Any] }]
    }

    private final class Composer {}

    func testStopHandsTheDroppedMessagesToTheComposerThatPressedItAndToNoOtherAndWritesTheInterrupt() throws {
        try connect(features: queueDaemon)
        setRunning(true)
        let pressed = Composer(), other = Composer()
        var got: [SessionQueueReturn] = []
        session.queue.returned.sink { got.append($0) }.store(in: &bag)

        session.interrupt(requester: ObjectIdentifier(pressed))
        feed(returnedFrame(["queued one", "queued two"]))

        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.requester, ObjectIdentifier(pressed))
        XCTAssertNotEqual(got.first?.requester, ObjectIdentifier(other))
        XCTAssertEqual(got.first?.entries.map(\.text), ["queued one", "queued two"])
        XCTAssertEqual(written("session_interrupt").count, 1)
    }

    func testAReturnedFrameWithoutAStopFromThisWindowIsNotHandedToAnyone() throws {
        try connect(features: queueDaemon)
        setRunning(true)
        var got: [SessionQueueReturn] = []
        session.queue.returned.sink { got.append($0) }.store(in: &bag)

        session.interrupt()   // no requester: not a composer's Stop
        feed(returnedFrame(["x"]))

        XCTAssertTrue(got.isEmpty)
    }

    func testStopWhileTheAgentIsIdleSendsNoInterruptAndClaimsNothing() throws {
        try connect(features: queueDaemon)
        var got: [SessionQueueReturn] = []
        session.queue.returned.sink { got.append($0) }.store(in: &bag)

        session.interrupt(requester: ObjectIdentifier(Composer()))
        feed(returnedFrame(["x"]))

        XCTAssertTrue(got.isEmpty)
        XCTAssertTrue(written("session_interrupt").isEmpty)
    }

    // MARK: Take back and remove through the session's own connection

    func testATakeBackIsWrittenForTheEntryAndItsAnswerReachesTheAsker() throws {
        try connect(features: queueDaemon, nonce: "n-1")
        snapshot(rev: 1, entries: [entry("q-1", text: "fix the picker")])
        var outcomes: [TakeBackOutcome] = []

        XCTAssertEqual(session.queue.takeBack(id: "q-1") { outcomes.append($0) }, .sent)

        let frame = try XCTUnwrap(written("session_queue_take_back").first)
        XCTAssertEqual(frame.json["tag"] as? String, tag)
        XCTAssertEqual(frame.json["id"] as? String, "q-1")
        XCTAssertEqual(frame.json["operator_nonce"] as? String, "n-1")
        let requestId = try XCTUnwrap(frame.json["request_id"] as? String)
        feed(["type": "session_queue_result", "tag": tag, "request_id": requestId, "id": "q-1",
              "code": "taken_back", "text": "fix the picker", "images": ["/tmp/shot-1.png"]])
        XCTAssertEqual(outcomes, [.takenBack(text: "fix the picker", images: ["/tmp/shot-1.png"])])
    }

    func testAResultForAnotherFocusDoesNotCompleteThisFocusRequest() throws {
        try connect(features: queueDaemon, nonce: "n-1")
        var outcomes: [TakeBackOutcome] = []
        _ = session.queue.takeBack(id: "q-1") { outcomes.append($0) }
        let requestId = try XCTUnwrap(written("session_queue_take_back").first?.json["request_id"] as? String)

        feed(["type": "session_queue_result", "tag": "someone-else", "request_id": requestId, "id": "q-1",
              "code": "taken_back", "text": "x"])

        XCTAssertTrue(outcomes.isEmpty)
    }

    func testARemoveIsWrittenAsARemoveAndATakeBackWithoutTheNonceIsUnavailable() throws {
        try connect(features: queueDaemon, nonce: nil)

        XCTAssertEqual(session.queue.takeBack(id: "q-1") { _ in }, .unavailable, "no operator nonce: nothing can be sent")
        XCTAssertEqual(session.queue.remove(id: "q-1"), .unavailable)
        XCTAssertTrue(written("session_queue_take_back").isEmpty)
        XCTAssertTrue(written("session_queue_remove").isEmpty)
    }

    func testRemoveWritesARemoveFrameForTheEntry() throws {
        try connect(features: queueDaemon, nonce: "n-1")

        XCTAssertEqual(session.queue.remove(id: "q-7"), .sent)

        let frame = try XCTUnwrap(written("session_queue_remove").first)
        XCTAssertEqual(frame.json["id"] as? String, "q-7")
        XCTAssertEqual(frame.json["tag"] as? String, tag)
    }
}
