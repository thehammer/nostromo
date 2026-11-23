import XCTest
import Combine

// A turn that answers several messages the daemon merged into one frame (`merged_turns_v1`): how
// `ChatSession` keeps its parts, removes the idle echoes of each part, and reconciles it across a
// reattach and an epoch change without duplicating it. Same rig as `ChatSessionQueueTests`.

final class ChatSessionMergedTurnTests: XCTestCase {

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


    private let mergedDaemon = [sessionQueueFeature, mergedTurnsFeature]
    private let parts = ["oh and backfill the rows", "use the new column name"]

    private func mergedTurn(_ id: String, second: Int, parts: [String]? = nil, complete: Bool = false) -> DaemonTurn {
        let p = parts ?? self.parts
        return DaemonTurn(id: id, userInput: p.joined(separator: "\n\n"),
                          timestamp: String(format: "2026-11-22T12:00:%02d.000000Z", second),
                          blocks: [], isComplete: complete, userParts: p)
    }

    private func texts() -> [String] { session.turns.filter { $0.marker == nil }.map(\.userInput) }

    // MARK: the turn

    func testAMergedTurnKeepsItsPartsAndTheJoinedText() throws {
        try connect(features: mergedDaemon)

        turnStarted(mergedTurn("t0", second: 1))

        XCTAssertEqual(session.turns.count, 1)
        XCTAssertEqual(session.turns[0].userParts, parts)
        XCTAssertEqual(session.turns[0].userInput, parts.joined(separator: "\n\n"))
        XCTAssertEqual(session.turns[0].daemonId, "t0")
    }

    func testAnOrdinaryTurnHasNoParts() throws {
        try connect(features: mergedDaemon)
        turnStarted(daemonTurn("t0", "hello", second: 1, complete: false))
        XCTAssertTrue(session.turns[0].userParts.isEmpty)
    }

    // MARK: echoes

    func testAnIdleEchoOfEachPartIsRemovedWhenTheMergedTurnStarts() throws {
        try connect(features: mergedDaemon)
        session.send(parts[0])
        setRunning(false)
        session.send(parts[1])
        XCTAssertEqual(texts(), parts, "two echoes before the turn")

        turnStarted(mergedTurn("t0", second: 1))

        XCTAssertEqual(session.turns.count, 1, "no echo is left duplicated")
        XCTAssertEqual(session.turns[0].userParts, parts)
    }

    func testAtMostOneEchoIsRemovedPerPartAndOtherEchoesStay() throws {
        try connect(features: mergedDaemon)
        session.send(parts[0])
        setRunning(false)
        session.send(parts[0])          // the same words sent again
        setRunning(false)
        session.send("something else")
        XCTAssertEqual(texts().count, 3)

        turnStarted(mergedTurn("t0", second: 1))

        // One echo of part 1 went (the newest), part 2 had none, the older twin and the other stay.
        XCTAssertEqual(texts(), [parts[0], "something else", parts.joined(separator: "\n\n")])
    }

    func testABoundEarlierTurnWithTheSameTextIsNeverTakenForAnEcho() throws {
        try connect(features: mergedDaemon)
        turnStarted(daemonTurn("t0", parts[0], second: 1, complete: true))

        turnStarted(mergedTurn("t1", second: 2))

        XCTAssertEqual(session.turns.count, 2)
        XCTAssertEqual(session.turns[0].daemonId, "t0")
    }

    // MARK: identity

    func testAReattachSnapshotOfTheSameMergedTurnDoesNotDuplicateIt() throws {
        try connect(features: mergedDaemon)
        turnStarted(mergedTurn("t0", second: 1, complete: true))
        let before = session.turns[0].id

        attachSnapshot([mergedTurn("t0", second: 1, complete: true)])

        XCTAssertEqual(session.turns.count, 1)
        XCTAssertEqual(session.turns[0].id, before, "view identity carries over")
        XCTAssertEqual(session.turns[0].userParts, parts)
    }

    func testAnEpochChangeRenumberingTheTurnsDoesNotDuplicateTheMergedTurn() throws {
        try connect(features: mergedDaemon)
        attachSnapshot([daemonTurn("t0", "first", second: 1), mergedTurn("t1", second: 2, complete: true)])
        let ids = session.turns.map(\.id)

        // The daemon restarted: its transcript is rebuilt and numbered again from other ids.
        attachSnapshot([daemonTurn("t5", "first", second: 1), mergedTurn("t6", second: 2, complete: true)])

        XCTAssertEqual(session.turns.map(\.id), ids, "same two turns, same view identity")
        XCTAssertEqual(session.turns.map { $0.daemonId ?? "" }, ["t5", "t6"])
        XCTAssertEqual(session.turns[1].userParts, parts)
    }
}
