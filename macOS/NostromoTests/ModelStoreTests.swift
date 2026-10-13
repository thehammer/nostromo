import XCTest
import Combine
import NostromoKit

// NostromodClient, ServerMsg, ModelStore, ChatSession and the NostromoKit wire types are
// compiled into this test target directly (logic test, no host app).
//
// Three layers of the model-switching data path on the Mac:
//   (a) the daemon client decodes every new frame (fixture JSON in the shape the Rust side
//       serialises: src/ipc/protocol.rs, src/ipc/stream_json.rs);
//   (b) `ModelStore` keeps per-focus state, catalogue and defaults, and asks the daemon;
//   (c) `ChatSession` turns a `note` delta into a transcript block and an announcement.

/// A `ModelRequestSending` that records what the store asks of the daemon.
final class ModelRequestRecorder: ModelRequestSending {
    enum Call: Equatable {
        case catalogRequest
        case catalogRefresh
        case defaultsRequest
        case get(tag: String)
        case set(tag: String, model: String?, effort: String?, setAsAgentDefault: Bool, requestId: String)
        case defaultSet(agent: String, model: String?, effort: String?, clear: Bool, requestId: String)
    }

    private(set) var calls: [Call] = []

    var sets: [Call] { calls.filter { if case .set = $0 { return true } else { return false } } }

    func modelCatalogRequest() { calls.append(.catalogRequest) }
    func modelCatalogRefresh() { calls.append(.catalogRefresh) }
    func modelDefaultsRequest() { calls.append(.defaultsRequest) }
    func sessionModelGet(tag: String) { calls.append(.get(tag: tag)) }
    func sessionModelSet(tag: String, model: String?, effort: String?, setAsAgentDefault: Bool, requestId: String) {
        calls.append(.set(tag: tag, model: model, effort: effort, setAsAgentDefault: setAsAgentDefault, requestId: requestId))
    }
    func modelDefaultSet(agent: String, model: String?, effort: String?, clear: Bool, requestId: String) {
        calls.append(.defaultSet(agent: agent, model: model, effort: effort, clear: clear, requestId: requestId))
    }
}

// MARK: - (a) Client decode

final class ModelFrameDecodeTests: XCTestCase {

    private var client: NostromodClient!

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
    }

    override func tearDown() {
        client = nil
        super.tearDown()
    }

    private func decode(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ServerMsg {
        let raw = Data(json.utf8)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], file: file, line: line)
        let type = try XCTUnwrap(obj["type"] as? String, file: file, line: line)
        return client.decode(type_: type, json: obj, raw: raw)
    }

    private let noteBlock = #"{"kind":"note","note_kind":"model_changed","text":"Model changed to Opus (from Sonnet) by you.","ts":"2026-10-12T19:47:03.123456Z"}"#

    func testModelCatalogDecodes() throws {
        let json = """
        {"type":"model_catalog","stale":true,"fetched_at":"2026-10-12T19:40:00.123456Z","families":[
          {"alias":"haiku","display_name":"Haiku","resolved":"claude-haiku-4-5-20251001","efforts":[],"rank":1},
          {"alias":"opus","display_name":"Opus","resolved":"claude-opus-5-5","efforts":["low","medium","high","xhigh","max"],"rank":3}]}
        """
        guard case let .modelCatalog(families, stale, fetchedAt) = try decode(json) else { return XCTFail("expected .modelCatalog") }
        XCTAssertEqual(families.map(\.alias), ["haiku", "opus"])
        guard families.count == 2 else { return }
        XCTAssertEqual(families[1].resolved, "claude-opus-5-5")
        XCTAssertEqual(families[1].efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(families[0].rank, 1)
        XCTAssertTrue(stale)
        XCTAssertEqual(fetchedAt, "2026-10-12T19:40:00.123456Z")
    }

    func testFullSessionModelStateDecodes() throws {
        let json = """
        {"type":"session_model_state","tag":"claudia",
         "recorded":{"model":"sonnet","effort":"high","source":"focus"},
         "reported":{"model":"claude-sonnet-5-5","family":"sonnet"},
         "effective_effort":"high","pending":{"model":"opus","effort":"max"},
         "phase":"waiting","running":true,
         "warnings":[{"target":"opus","text":"Larger than the context window"}],
         "last_request":{"actor":"user","to":"opus","status":"pending_turn_end","ts":"2026-10-12T19:47:03.123456Z","request_id":"req-7"},
         "posture":"normal"}
        """
        guard case let .sessionModelState(s) = try decode(json) else { return XCTFail("expected .sessionModelState") }
        XCTAssertEqual(s.tag, "claudia")
        XCTAssertEqual(s.recorded, RecordedModelWire(model: "sonnet", effort: "high", source: .focus))
        XCTAssertEqual(s.reported, ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"))
        XCTAssertEqual(s.pending, PendingModelWire(model: "opus", effort: "max"))
        XCTAssertEqual(s.phase, .waiting)
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.warnings.count, 1)
        XCTAssertEqual(s.lastRequest?.status, .pendingTurnEnd)
        XCTAssertEqual(s.lastRequest?.requestId, "req-7")
        XCTAssertEqual(s.posture, "normal")
    }

    func testSessionModelStateFromANetworkPeerDecodesWithoutPostureLastRequestOrRecorded() throws {
        let json = #"{"type":"session_model_state","tag":"fred","reported":{"model":"claude-opus-5-5"},"running":true,"phase":"steady","warnings":[]}"#
        guard case let .sessionModelState(s) = try decode(json) else { return XCTFail("expected .sessionModelState") }
        XCTAssertEqual(s.tag, "fred")
        XCTAssertNil(s.recorded)
        XCTAssertNil(s.lastRequest)
        XCTAssertNil(s.posture)
        XCTAssertEqual(s.reported?.model, "claude-opus-5-5")
    }

    func testSessionModelStateIgnoresUnknownExtraKeys() throws {
        let json = """
        {"type":"session_model_state","tag":"claudia","future":{"x":1},
         "recorded":{"model":"opus","source":"focus","future":true},"running":false,"phase":"steady",
         "last_request":{"actor":"script","to":"opus","status":"applied","ts":"2026-10-12T19:47:03Z","extra":1}}
        """
        guard case let .sessionModelState(s) = try decode(json) else { return XCTFail("expected .sessionModelState") }
        XCTAssertEqual(s.recorded?.model, "opus")
        XCTAssertEqual(s.lastRequest?.status, .applied)
    }

    func testUnknownSourceAndPhaseStringsAreTolerated() throws {
        let json = #"{"type":"session_model_state","tag":"claudia","recorded":{"model":"opus","source":"from_the_future"},"phase":"hovering","running":true}"#
        guard case let .sessionModelState(s) = try decode(json) else { return XCTFail("an unknown enum string must not cost the frame") }
        XCTAssertEqual(s.tag, "claudia")
        XCTAssertEqual(s.recorded?.source, .unknown("from_the_future"))
    }

    func testModelDefaultsDecodeWithAndWithoutDeclared() throws {
        let withDeclared = #"{"type":"model_defaults","defaults":{"claudia":{"model":"opus","effort":"high"}},"declared":{"claudia":"sonnet"}}"#
        guard case let .modelDefaults(defaults, declared) = try decode(withDeclared) else { return XCTFail("expected .modelDefaults") }
        XCTAssertEqual(defaults["claudia"], AgentModelDefaultWire(model: "opus", effort: "high"))
        XCTAssertEqual(declared, ["claudia": "sonnet"])

        let without = #"{"type":"model_defaults","defaults":{"claudia":{"model":"opus"}}}"#
        guard case let .modelDefaults(d2, declared2) = try decode(without) else { return XCTFail("expected .modelDefaults") }
        XCTAssertEqual(d2["claudia"]?.model, "opus")
        XCTAssertEqual(declared2, [:])
    }

    func testModelRequestResultDecodesDeniedExpiredAndUnknownStatuses() throws {
        for (raw, expected) in [("denied", ModelRequestStatusWire.denied), ("expired", .expired), ("teleported", .unknown("teleported"))] {
            let json = #"{"type":"model_request_result","request_id":"r1","status":"\#(raw)","code":"c","message":"m"}"#
            guard case let .modelRequestResult(id, status, code, message, warning) = try decode(json) else {
                XCTFail("expected .modelRequestResult for \(raw)"); continue
            }
            XCTAssertEqual(id, "r1")
            XCTAssertEqual(status, expected, raw)
            XCTAssertEqual(code, "c")
            XCTAssertEqual(message, "m")
            XCTAssertNil(warning)
        }
    }

    func testANoteBlockInsideASessionTurnsSnapshotDecodes() throws {
        let json = """
        {"type":"session_turns","tag":"claudia","turns":[
          {"id":"t0","user_input":"hi","timestamp":"2026-10-12T19:46:00Z","is_complete":true,
           "blocks":[\(noteBlock),{"kind":"text","text":"ok"}]}]}
        """
        guard case let .sessionTurns(tag, turns) = try decode(json) else { return XCTFail("expected .sessionTurns") }
        XCTAssertEqual(tag, "claudia")
        XCTAssertEqual(turns.first?.blocks.count, 2)
        guard case let .note(kind, text, ts)? = turns.first?.blocks.first else { return XCTFail("first block should be the note") }
        XCTAssertEqual(kind, "model_changed", "the wire key is `note_kind`")
        XCTAssertEqual(text, "Model changed to Opus (from Sonnet) by you.")
        XCTAssertEqual(ts, "2026-10-12T19:47:03.123456Z")
    }

    func testANoteDeltaDecodesWithAndWithoutATurnId() throws {
        let withTurn = #"{"type":"session_turn_delta","tag":"claudia","delta":{"delta":"note","turn_id":"t3","block":\#(noteBlock)}}"#
        guard case let .sessionTurnDelta(tag, delta) = try decode(withTurn), case let .note(turnId, block) = delta else {
            return XCTFail("expected a note delta")
        }
        XCTAssertEqual(tag, "claudia")
        XCTAssertEqual(turnId, "t3")
        guard case let .note(_, text, _) = block else { return XCTFail("\(block)") }
        XCTAssertEqual(text, "Model changed to Opus (from Sonnet) by you.")

        let noTurn = #"{"type":"session_turn_delta","tag":"claudia","delta":{"delta":"note","turn_id":null,"block":\#(noteBlock)}}"#
        guard case let .sessionTurnDelta(_, delta2) = try decode(noTurn), case let .note(nilId, _) = delta2 else {
            return XCTFail("a note delta with a null turn id must still decode")
        }
        XCTAssertNil(nilId)
    }

    // MARK: Subscriptions

    func testTheClientSubscribesToTheModelTopic() {
        XCTAssertEqual(NostromodClient.featureTopics["model"], "model",
                       "live model state and notes are delivered only to a client subscribed to the `model` topic")
    }

    func testTheBaseTopicsAreUnchanged() {
        XCTAssertEqual(NostromodClient.baseTopics,
                       ["activity", "mother_jobs", "mother_statusline", "mother_peek", "perri", "fred", "teri", "layout", "decision"])
        XCTAssertEqual(NostromodClient.featureTopics["work"], "work")
    }
}

// MARK: - (b) ModelStore

final class ModelStoreTests: XCTestCase {

    private var sender: ModelRequestRecorder!
    private var store: ModelStore!
    private var nextId = 0

    override func setUp() {
        super.setUp()
        sender = ModelRequestRecorder()
        nextId = 0
        store = ModelStore(sender: sender, makeRequestId: { [unowned self] in
            self.nextId += 1
            return "req-\(self.nextId)"
        })
    }

    override func tearDown() {
        store = nil
        sender = nil
        super.tearDown()
    }

    private func modelState(_ tag: String, model: String = "sonnet", running: Bool = true) -> SessionModelStateWire {
        SessionModelStateWire(tag: tag, recorded: RecordedModelWire(model: model, source: .focus), running: running)
    }

    private func family(_ alias: String, rank: Int) -> ModelFamilyWire {
        ModelFamilyWire(alias: alias, displayName: alias.capitalized, resolved: "claude-\(alias)-1", efforts: [], rank: rank)
    }

    // MARK: Ingest

    func testASessionModelStateIsStoredByTag() {
        store.ingest(.sessionModelState(modelState("claudia", model: "sonnet")))
        store.ingest(.sessionModelState(modelState("cody", model: "opus")))
        XCTAssertEqual(store.state(for: "claudia")?.recorded?.model, "sonnet")
        XCTAssertEqual(store.state(for: "cody")?.recorded?.model, "opus")
        XCTAssertEqual(store.states.count, 2)
        XCTAssertNil(store.state(for: "perri"))
    }

    func testTheNextFrameForATagReplacesTheLastOne() {
        store.ingest(.sessionModelState(modelState("claudia", model: "sonnet")))
        store.ingest(.sessionModelState(modelState("claudia", model: "opus", running: false)))
        XCTAssertEqual(store.state(for: "claudia")?.recorded?.model, "opus")
        XCTAssertEqual(store.state(for: "claudia")?.running, false)
        XCTAssertEqual(store.states.count, 1)
    }

    func testTheCatalogueIsStoredCheapestFirst() {
        store.ingest(.modelCatalog(families: [family("opus", rank: 3), family("haiku", rank: 1), family("sonnet", rank: 2)],
                                   stale: true, fetchedAt: "2026-10-12T19:40:00Z"))
        XCTAssertEqual(store.catalog?.families.map(\.alias), ["haiku", "sonnet", "opus"])
        XCTAssertEqual(store.catalog?.stale, true)
        XCTAssertEqual(store.catalog?.fetchedAt, "2026-10-12T19:40:00Z")
    }

    func testANewCatalogueReplacesTheOldOne() {
        store.ingest(.modelCatalog(families: [family("opus", rank: 3)], stale: true, fetchedAt: nil))
        store.ingest(.modelCatalog(families: [family("haiku", rank: 1)], stale: false, fetchedAt: nil))
        XCTAssertEqual(store.catalog?.families.map(\.alias), ["haiku"])
        XCTAssertEqual(store.catalog?.stale, false)
    }

    func testDefaultsAreStored() {
        let defaults = ["claudia": AgentModelDefaultWire(model: "opus", effort: "high")]
        store.ingest(.modelDefaults(defaults: defaults, declared: ["claudia": "sonnet"]))
        XCTAssertEqual(store.defaults, ModelDefaultsState(defaults: defaults, declared: ["claudia": "sonnet"]))
    }

    func testARequestResultIsKeptAsTheLastResult() {
        store.ingest(.modelRequestResult(requestId: "r1", status: .applied, code: nil, message: nil, warning: nil))
        XCTAssertEqual(store.lastResult?.requestId, "r1")
        XCTAssertEqual(store.lastResult?.status, .applied)
        store.ingest(.modelRequestResult(requestId: "r2", status: .refused, code: "unsupported", message: "No", warning: "w"))
        XCTAssertEqual(store.lastResult, ModelRequestResultWire(requestId: "r2", status: .refused,
                                                                code: "unsupported", message: "No", warning: "w"))
    }

    func testFramesThatAreNotModelFramesAreIgnored() {
        store.ingest(.sessionModelState(modelState("claudia")))
        store.ingest(.pong)
        store.ingest(.unknown)
        store.ingest(.error("boom"))
        store.ingest(.welcome(protocolVersion: 3, daemonPid: 42))
        store.ingest(.sessionState(tag: "claudia", state: .idle))
        XCTAssertEqual(store.states.count, 1)
        XCTAssertEqual(store.state(for: "claudia")?.recorded?.model, "sonnet")
        XCTAssertNil(store.catalog)
        XCTAssertNil(store.defaults)
        XCTAssertNil(store.lastResult)
        XCTAssertEqual(sender.calls, [], "ingesting never sends anything")
    }

    // MARK: Connection

    func testGoingOnlineAsksForTheCatalogueAndTheDefaultsExactlyOnceEach() {
        XCTAssertFalse(store.isConnected)
        store.connectionChanged(true)
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(sender.calls.filter { $0 == .catalogRequest }.count, 1)
        XCTAssertEqual(sender.calls.filter { $0 == .defaultsRequest }.count, 1)
        XCTAssertEqual(sender.calls.count, 2, "nothing else is asked on connect")
    }

    func testGoingOfflineAsksForNothingAndKeepsWhatWasKnown() {
        store.connectionChanged(true)
        store.ingest(.sessionModelState(modelState("claudia")))
        store.ingest(.modelCatalog(families: [family("opus", rank: 3)], stale: false, fetchedAt: nil))
        let before = sender.calls.count

        store.connectionChanged(false)

        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(sender.calls.count, before)
        XCTAssertEqual(store.state(for: "claudia")?.recorded?.model, "sonnet", "the chip keeps its last known title while offline")
        XCTAssertEqual(store.catalog?.families.map(\.alias), ["opus"])
    }

    func testEachNewConnectionAsksAgain() {
        store.connectionChanged(true)
        store.connectionChanged(false)
        store.connectionChanged(true)
        XCTAssertEqual(sender.calls.filter { $0 == .catalogRequest }.count, 2)
        XCTAssertEqual(sender.calls.filter { $0 == .defaultsRequest }.count, 2)
    }

    // MARK: Switching

    func testRequestSwitchSendsExactlyOneSessionModelSetAndReturnsItsRequestId() {
        let id = store.requestSwitch(tag: "claudia", model: "opus", effort: nil)
        XCTAssertEqual(id, "req-1")
        XCTAssertEqual(sender.calls, [.set(tag: "claudia", model: "opus", effort: nil, setAsAgentDefault: false, requestId: "req-1")])
    }

    func testRequestSwitchPassesEffortAndTheAgentDefaultFlagThrough() {
        _ = store.requestSwitch(tag: "claudia", model: nil, effort: "high")
        _ = store.requestSwitch(tag: "cody", model: "sonnet", effort: "default", setAsAgentDefault: true)
        XCTAssertEqual(sender.calls, [
            .set(tag: "claudia", model: nil, effort: "high", setAsAgentDefault: false, requestId: "req-1"),
            .set(tag: "cody", model: "sonnet", effort: "default", setAsAgentDefault: true, requestId: "req-2"),
        ])
    }

    func testTheDefaultRequestIdsAreNonEmptyAndDistinct() {
        let real = ModelStore(sender: sender)
        let a = real.requestSwitch(tag: "claudia", model: "opus", effort: nil)
        let b = real.requestSwitch(tag: "claudia", model: "sonnet", effort: nil)
        XCTAssertFalse(a.isEmpty)
        XCTAssertFalse(b.isEmpty)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(sender.sets.count, 2)
    }

    // MARK: Forget

    func testForgetDropsOnlyThatFocus() {
        store.ingest(.sessionModelState(modelState("claudia")))
        store.ingest(.sessionModelState(modelState("cody")))
        store.forget(tag: "claudia")
        XCTAssertNil(store.state(for: "claudia"))
        XCTAssertNotNil(store.state(for: "cody"))
        XCTAssertEqual(store.states.count, 1)
    }
}

// MARK: - (c) ChatSession and `note` blocks

final class ChatSessionNoteTests: XCTestCase {

    private static let text = "Model changed to Opus (from Sonnet) by you."

    private var client: NostromodClient!
    private var session: ChatSession!
    private var announced: [String] = []
    private var cancellables = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
        session = ChatSession(tag: "test", agentName: "claudia", displayName: "Claudia",
                              workingDirectory: nil, client: client)
        announced = []
        session.noteArrived.sink { [weak self] in self?.announced.append($0) }.store(in: &cancellables)
    }

    override func tearDown() {
        cancellables.removeAll()
        session = nil
        client = nil
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return XCTFail("condition not met within \(timeout)s", file: file, line: line) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Let anything already queued on the main run loop land (used to prove something did NOT happen).
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func note(_ text: String = ChatSessionNoteTests.text) -> DaemonTurnBlock {
        .note(kind: "model_changed", text: text, ts: nil)
    }

    private func noteTexts(in turn: ChatTurn) -> [String] {
        turn.blocks.compactMap { if case .note(let t) = $0 { return t } else { return nil } }
    }

    private func startSession(withTurns turns: [DaemonTurn]) {
        client.messages.send(.sessionTurns(tag: "test", turns: turns))
        waitUntil { self.session.turns.count == turns.count }
    }

    func testANoteDeltaAppendsANoteBlockToItsTurnAndAnnouncesItOnce() {
        startSession(withTurns: [DaemonTurn(id: "t0", userInput: "hi", timestamp: nil,
                                            blocks: [.text("ok")], isComplete: true)])
        XCTAssertEqual(announced, [], "a snapshot announces nothing")

        client.messages.send(.sessionTurnDelta(tag: "test", delta: .note(turnId: "t0", block: note())))
        waitUntil { !self.announced.isEmpty }
        settle()

        XCTAssertEqual(announced, [Self.text], "the note is announced exactly once, with its text")
        guard session.turns.count == 1 else { return XCTFail("a note does not start a turn: \(session.turns.count) turns") }
        XCTAssertEqual(noteTexts(in: session.turns[0]), [Self.text])
        guard case .note(let last)? = session.turns[0].blocks.last else { return XCTFail("the note should be the turn's last block") }
        XCTAssertEqual(last, Self.text)
    }

    func testANoteWithNoTurnYetIsShownAsAMarkerAndAnnounced() {
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .note(turnId: nil, block: note())))
        waitUntil { !self.announced.isEmpty }
        settle()

        XCTAssertEqual(announced, [Self.text])
        guard session.turns.count == 1 else { return XCTFail("expected one marker turn, got \(session.turns.count)") }
        XCTAssertEqual(session.turns[0].marker, .note(Self.text))
    }

    func testTheFirstTurnsLeadingCopyOfAMarkerNoteIsNotShownTwice() {
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .note(turnId: nil, block: note())))
        waitUntil { self.session.turns.count == 1 }

        // The daemon leads the next turn's blocks with the same note.
        let first = DaemonTurn(id: "t0", userInput: "hello", timestamp: nil,
                               blocks: [note(), .text("hi there")], isComplete: false)
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .turnStarted(first)))
        waitUntil { self.session.turns.count == 2 }
        settle()

        guard session.turns.count == 2 else { return XCTFail("expected marker + turn, got \(session.turns.count)") }
        XCTAssertEqual(session.turns[0].marker, .note(Self.text), "the standalone marker stays")
        XCTAssertEqual(noteTexts(in: session.turns[1]), [], "the turn's own copy of the note is dropped: the note reads once")
        XCTAssertEqual(session.turns[1].daemonId, "t0")
        XCTAssertEqual(announced, [Self.text], "the leading copy is not a new arrival")
    }

    func testANoteInsideASnapshotDoesNotAnnounce() {
        let turn = DaemonTurn(id: "t0", userInput: "hi", timestamp: nil,
                              blocks: [note(), .text("ok")], isComplete: true)
        startSession(withTurns: [turn])
        settle()

        XCTAssertEqual(announced, [], "notes that come with an attach snapshot are history, not news")
        guard let shown = session.turns.first else { return XCTFail("the snapshot turn is missing") }
        XCTAssertEqual(noteTexts(in: shown), [Self.text], "but they are shown")
    }

    func testASnapshotCarryingTheNoteReplacesTheStandaloneMarkerWithoutAGapMarker() {
        client.messages.send(.sessionTurnDelta(tag: "test", delta: .note(turnId: nil, block: note())))
        waitUntil { self.session.turns.count == 1 }

        // Reconnect: the daemon's snapshot holds the first turn, led by the same note.
        let turn = DaemonTurn(id: "t0", userInput: "hello", timestamp: "2026-10-12T19:47:03.000Z",
                              blocks: [note(), .text("hi there")], isComplete: true)
        client.messages.send(.sessionTurns(tag: "test", turns: [turn]))
        waitUntil { self.session.turns.first?.marker == nil }
        settle()

        XCTAssertEqual(session.turns.count, 1, "the marker is replaced by the snapshot's copy, with no gap marker beside it")
        XCTAssertNil(session.turns.first?.marker)
        XCTAssertEqual(session.turns.first.map(noteTexts(in:)), [Self.text], "the note reads once, inside its turn")
    }
}
