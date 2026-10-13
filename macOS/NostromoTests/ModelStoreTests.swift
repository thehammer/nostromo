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

    // MARK: Leniency (the Mac client's own decode path must match NostromoKit's)

    func testARecordedModelWithoutASourceIsAFocusChoice() throws {
        let json = #"{"type":"session_model_state","tag":"claudia","recorded":{"model":"opus","effort":"high"},"running":false}"#
        guard case let .sessionModelState(s) = try decode(json) else { return XCTFail("expected .sessionModelState") }
        XCTAssertEqual(s.recorded?.source, .focus, "a missing `source` is the daemon's serde default, `focus`")
        XCTAssertEqual(s.recorded?.source.isChosen, true)
    }

    func testTheLastRequestKeepsItsTimestamp() throws {
        let json = #"{"type":"session_model_state","tag":"claudia","last_request":{"actor":"user","to":"opus","status":"failed","ts":"2026-10-12T19:47:03.123456Z","request_id":"r1"}}"#
        guard case let .sessionModelState(s) = try decode(json) else { return XCTFail("expected .sessionModelState") }
        XCTAssertEqual(s.lastRequest?.ts, "2026-10-12T19:47:03.123456Z")
        XCTAssertEqual(s.lastRequest?.requestId, "r1")
    }

    func testACatalogueWithoutAStaleKeyDecodesAsNotStale() throws {
        let json = #"{"type":"model_catalog","families":[{"alias":"opus","display_name":"Opus","efforts":["low"],"rank":3}]}"#
        guard case let .modelCatalog(families, stale, _) = try decode(json) else { return XCTFail("expected .modelCatalog") }
        XCTAssertEqual(families.map(\.alias), ["opus"])
        XCTAssertFalse(stale)
    }

    func testAMalformedCatalogueFamilyIsSkippedAndTheGoodOnesSurvive() throws {
        let json = """
        {"type":"model_catalog","stale":false,"families":[
          {"alias":"haiku","display_name":"Haiku","efforts":[],"rank":1},
          {"display_name":"No alias","efforts":["low"],"rank":2},
          "not an object",
          5,
          null,
          {"alias":"opus","display_name":"Opus","resolved":"claude-opus-5-5","efforts":["low","high"],"rank":3}]}
        """
        guard case let .modelCatalog(families, _, _) = try decode(json) else {
            return XCTFail("a bad family must not turn the whole frame into .unknown")
        }
        XCTAssertEqual(families.map(\.alias), ["haiku", "opus"])
    }

    func testACatalogueWhoseEveryFamilyIsMalformedIsAnEmptyCatalogueNotUnknown() throws {
        let json = #"{"type":"model_catalog","stale":true,"families":[{"display_name":"x"},"y",7]}"#
        guard case let .modelCatalog(families, stale, _) = try decode(json) else {
            return XCTFail("expected .modelCatalog with no families, not .unknown")
        }
        XCTAssertEqual(families.map(\.alias), [])
        XCTAssertTrue(stale)
    }

    func testAMalformedDefaultsEntryIsSkippedAndTheRestKept() throws {
        let json = """
        {"type":"model_defaults","defaults":{
           "claudia":{"model":"opus","effort":"high"},
           "no_model":{"effort":"high"},
           "not_an_object":"opus",
           "wrong_type":{"model":5},
           "cody":{"model":"sonnet"}},
         "declared":{"claudia":"sonnet","bad_number":5,"bad_null":null,"bad_object":{"a":1},"cody":"sonnet"}}
        """
        guard case let .modelDefaults(defaults, declared) = try decode(json) else {
            return XCTFail("a bad entry must not turn the whole frame into .unknown")
        }
        XCTAssertEqual(Set(defaults.keys), ["claudia", "cody"])
        XCTAssertEqual(defaults["claudia"], AgentModelDefaultWire(model: "opus", effort: "high"))
        XCTAssertEqual(declared, ["claudia": "sonnet", "cody": "sonnet"])
    }

    func testDefaultsWhoseEveryEntryIsMalformedAreEmptyNotUnknown() throws {
        let json = #"{"type":"model_defaults","defaults":{"a":{"effort":"x"},"b":3},"declared":{"a":1,"b":null}}"#
        guard case let .modelDefaults(defaults, declared) = try decode(json) else {
            return XCTFail("expected .modelDefaults with empty maps, not .unknown")
        }
        XCTAssertEqual(defaults, [:])
        XCTAssertEqual(declared, [:])
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

// MARK: - (b2) ModelStore: what went wrong, and who is told
//
// A switch that does not happen must not fail silently: a refusal, a failure, a denied or expired
// agent request becomes a short message per focus (`failure(for:)`) that the input bar shows.
// A failure comes from the answer to a request of this store (`model_request_result`), or from a
// focus's `last_request` changing to a failing status (a script's or an agent's request).

final class ModelStoreFailureTests: XCTestCase {

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

    // MARK: Fixtures

    /// The one place that builds a `LastModelRequestWire` (the daemon's `last_request`).
    private func lastRequest(_ status: ModelRequestStatusWire, to: String = "opus", requestId: String? = nil,
                             ts: String? = nil, actor: String = "script") -> LastModelRequestWire {
        LastModelRequestWire(actor: actor, to: to, status: status, requestId: requestId, ts: ts)
    }

    private func state(_ tag: String = "claudia", recorded: String = "sonnet", reported: String? = "claude-sonnet-5-5",
                       running: Bool = true, last: LastModelRequestWire? = nil) -> SessionModelStateWire {
        SessionModelStateWire(tag: tag, recorded: RecordedModelWire(model: recorded, source: .focus),
                              reported: reported.map { ReportedModelWire(model: $0) },
                              running: running, lastRequest: last)
    }

    private func result(_ id: String, _ status: ModelRequestStatusWire, code: String? = nil, message: String? = nil) -> ServerMsg {
        .modelRequestResult(requestId: id, status: status, code: code, message: message, warning: nil)
    }

    /// Ingest a state, ask for a switch and answer it: the failure (if any) the store holds for the tag.
    private func answer(_ status: ModelRequestStatusWire, code: String? = nil, message: String? = nil,
                        tag: String = "claudia", state s: SessionModelStateWire? = nil) -> ModelSwitchFailure? {
        store.ingest(.sessionModelState(s ?? state(tag)))
        let id = store.requestSwitch(tag: tag, model: "opus", effort: nil)
        store.ingest(result(id, status, code: code, message: message))
        return store.failure(for: tag)
    }

    // MARK: Result frames

    func testNothingFailedUntilSomethingDoes() {
        XCTAssertNil(store.failure(for: "claudia"))
        XCTAssertEqual(store.failures, [:])
    }

    func testEachFailingResultBecomesAMessageForTheFocusTheRequestWasMadeFor() {
        let cases: [(ModelRequestStatusWire, String?, String?, String)] = [
            (.refused, "unknown_model", nil, "Couldn't switch: that model isn't available"),
            (.refused, "not_permitted", nil, "Couldn't switch: this session's model can't be changed"),
            (.refused, "unknown_focus", nil, "Couldn't switch: this focus no longer exists"),
            (.refused, nil, "Opus is not available on this plan.", "Couldn't switch: opus is not available on this plan."),
            (.failed, nil, "The CLI would not start.", "Couldn't switch: the CLI would not start."),
            (.failed, nil, nil, "Couldn't switch: something went wrong"),
            (.denied, nil, nil, "Couldn't switch: the request was declined"),
            (.expired, nil, nil, "Couldn't switch: the request expired"),
        ]
        for (status, code, message, expected) in cases {
            let tag = "focus-\(nextId)"
            let failure = answer(status, code: code, message: message, tag: tag)
            XCTAssertEqual(failure?.message, expected, "\(status) code=\(String(describing: code)) message=\(String(describing: message))")
            XCTAssertEqual(store.failures.keys.contains(tag), true)
        }
    }

    func testTheFailureBelongsToTheRequestsFocusOnly() {
        store.ingest(.sessionModelState(state("claudia")))
        store.ingest(.sessionModelState(state("cody")))
        _ = store.requestSwitch(tag: "claudia", model: "opus", effort: nil)       // req-1
        let codyRequest = store.requestSwitch(tag: "cody", model: "opus", effort: nil)   // req-2
        store.ingest(result(codyRequest, .refused, code: "unknown_model"))
        XCTAssertNotNil(store.failure(for: "cody"))
        XCTAssertNil(store.failure(for: "claudia"), "the result answers cody's request, not claudia's")
        XCTAssertEqual(Set(store.failures.keys), ["cody"])
    }

    func testAResultForARequestThisStoreNeverMadeSetsNothing() {
        store.ingest(.sessionModelState(state("claudia")))
        store.ingest(result("someone-elses-request", .refused, code: "unknown_model"))
        store.ingest(result("another", .failed, message: "boom"))
        XCTAssertNil(store.failure(for: "claudia"))
        XCTAssertEqual(store.failures, [:])
    }

    func testResultsThatAreNotFailuresSetNothing() {
        let nonFailures: [ModelRequestStatusWire] = [.applied, .pendingTurnEnd, .awaitingUser, .unknown("teleported")]
        for status in nonFailures {
            XCTAssertNil(answer(status, tag: "t-\(nextId)"), "\(status)")
        }
        XCTAssertEqual(store.failures, [:])
    }

    func testASecondFailureReplacesTheFirstWithANewerId() throws {
        store.ingest(.sessionModelState(state()))
        let first = store.requestSwitch(tag: "claudia", model: "opus", effort: nil)
        store.ingest(result(first, .refused, code: "unknown_model"))
        let one = try XCTUnwrap(store.failure(for: "claudia"))

        let second = store.requestSwitch(tag: "claudia", model: "haiku", effort: nil)
        store.ingest(result(second, .failed, message: "Nope."))
        let two = try XCTUnwrap(store.failure(for: "claudia"))

        XCTAssertEqual(two.message, "Couldn't switch: nope.")
        XCTAssertGreaterThan(two.id, one.id, "ids grow, so a late dismissal of the first cannot clear the second")
        XCTAssertEqual(store.failures.count, 1)
    }

    func testAResultIsAnsweredOnceThenTheRequestIsForgotten() {
        store.ingest(.sessionModelState(state()))
        let id = store.requestSwitch(tag: "claudia", model: "opus", effort: nil)
        store.ingest(result(id, .refused, code: "unknown_model"))
        guard let failure = store.failure(for: "claudia") else { return XCTFail("the first answer must set a failure") }
        store.dismissFailure(tag: "claudia", id: failure.id)
        XCTAssertNil(store.failure(for: "claudia"))

        store.ingest(result(id, .refused, code: "unknown_model"))
        XCTAssertNil(store.failure(for: "claudia"), "the request id is spent after its answer; the store keeps no memory of it")
    }

    func testTheCodeMappingWinsOverTheDaemonsMessage() {
        let failure = answer(.refused, code: "unknown_model", message: "No such model: banana")
        XCTAssertEqual(failure?.message, "Couldn't switch: that model isn't available")
    }

    // MARK: Dismissal and forgetting

    func testDismissingRemovesOnlyAFailureWhoseIdStillMatches() throws {
        let failure = try XCTUnwrap(answer(.refused, code: "unknown_model"))

        store.dismissFailure(tag: "claudia", id: failure.id + 100)
        XCTAssertEqual(store.failure(for: "claudia"), failure, "a stale id (an older failure's) clears nothing")

        store.dismissFailure(tag: "other", id: failure.id)
        XCTAssertEqual(store.failure(for: "claudia"), failure, "another tag's dismissal clears nothing")

        store.dismissFailure(tag: "claudia", id: failure.id)
        XCTAssertNil(store.failure(for: "claudia"))
        XCTAssertEqual(store.failures, [:])
    }

    func testForgettingAFocusAlsoClearsItsFailure() {
        _ = answer(.refused, code: "unknown_model")
        XCTAssertNotNil(store.failure(for: "claudia"))
        store.forget(tag: "claudia")
        XCTAssertNil(store.failure(for: "claudia"))
        XCTAssertNil(store.state(for: "claudia"))
    }

    // MARK: "Unchanged" that is not

    // The daemon answers `unchanged` when the recorded model already is the requested one, even
    // when the running session was substituted by the CLI. That is not "nothing to do".

    func testUnchangedWhileTheSessionRunsAnotherFamilyIsAFailureNamingBoth() {
        let running = state(recorded: "opus", reported: "claude-sonnet-5-5")
        let failure = answer(.unchanged, state: running)
        XCTAssertEqual(failure?.message, "Opus was requested, but this session is running Sonnet")
    }

    func testUnchangedMismatchComparesFamiliesNotSpellings() {
        let pinned = state(recorded: "claude-opus-5-5", reported: "claude-sonnet-5-5")
        XCTAssertEqual(answer(.unchanged, tag: "claudia", state: pinned)?.message,
                       "Opus was requested, but this session is running Sonnet")

        let sameFamily = state("cody", recorded: "claude-opus-5-5", reported: "claude-opus-5-6")
        XCTAssertNil(answer(.unchanged, tag: "cody", state: sameFamily), "a different version of the same family is not a mismatch")

        let alias = state("perri", recorded: "opus", reported: "claude-opus-5-5")
        XCTAssertNil(answer(.unchanged, tag: "perri", state: alias))
    }

    func testUnchangedWithNoMismatchSetsNothing() {
        XCTAssertNil(answer(.unchanged, tag: "a", state: state("a", recorded: "sonnet", reported: "claude-sonnet-5-5")))
        XCTAssertNil(answer(.unchanged, tag: "b", state: state("b", recorded: "sonnet", reported: nil)),
                     "nothing reported yet: nothing to contradict")
        XCTAssertNil(answer(.unchanged, tag: "c", state: state("c", recorded: "opus", reported: "claude-sonnet-5-5", running: false)),
                     "a session that is not running reports nothing current")
        XCTAssertNil(answer(.unchanged, tag: "d", state: SessionModelStateWire(tag: "d", running: true)),
                     "nothing recorded: nothing was requested of record")
    }

    func testUnchangedForAFocusWithNoStateSetsNothing() {
        let id = store.requestSwitch(tag: "ghost", model: "opus", effort: nil)
        store.ingest(result(id, .unchanged))
        XCTAssertNil(store.failure(for: "ghost"))
    }

    // MARK: A failing `last_request` (a script's or an agent's request)

    func testAFailingLastRequestThatChangesAfterTheFirstStateIsAFailure() {
        store.ingest(.sessionModelState(state(last: lastRequest(.applied, requestId: "s-1"))))
        XCTAssertNil(store.failure(for: "claudia"))

        store.ingest(.sessionModelState(state(last: lastRequest(.failed, requestId: "s-2"))))
        XCTAssertEqual(store.failure(for: "claudia")?.message, "Couldn't switch: something went wrong")
    }

    func testEachFailingLastRequestStatusHasItsOwnCopy() {
        let cases: [(ModelRequestStatusWire, String)] = [
            (.refused, "Couldn't switch: something went wrong"),
            (.failed, "Couldn't switch: something went wrong"),
            (.denied, "Couldn't switch: the request was declined"),
            (.expired, "Couldn't switch: the request expired"),
        ]
        for (i, (status, expected)) in cases.enumerated() {
            let tag = "focus-\(i)"
            store.ingest(.sessionModelState(state(tag)))
            store.ingest(.sessionModelState(state(tag, last: lastRequest(status, requestId: "r-\(i)"))))
            XCTAssertEqual(store.failure(for: tag)?.message, expected, "\(status)")
        }
    }

    func testTheFirstStateForATagNeverShowsAnOldFailure() {
        // The `model` subscribe replays every focus's state, with whatever `last_request` it had.
        store.ingest(.sessionModelState(state(last: lastRequest(.failed, requestId: "old"))))
        XCTAssertNil(store.failure(for: "claudia"))
        // The same replay on the next connection changes nothing either.
        store.ingest(.sessionModelState(state(last: lastRequest(.failed, requestId: "old"))))
        XCTAssertNil(store.failure(for: "claudia"))
    }

    func testAFocusForgottenAndSeenAgainStartsOverSoItsReplayShowsNothing() {
        store.ingest(.sessionModelState(state(last: lastRequest(.applied, requestId: "a"))))
        store.forget(tag: "claudia")
        store.ingest(.sessionModelState(state(last: lastRequest(.denied, requestId: "old-denied"))))
        XCTAssertNil(store.failure(for: "claudia"), "after forget the next state is a first state again")
    }

    func testTheSameLastRequestArrivingAgainIsNotANewFailure() {
        store.ingest(.sessionModelState(state(last: lastRequest(.applied, requestId: "a"))))
        store.ingest(.sessionModelState(state(last: lastRequest(.failed, requestId: "f"))))
        guard let first = store.failure(for: "claudia") else { return XCTFail("the change must show a failure") }
        store.dismissFailure(tag: "claudia", id: first.id)

        store.ingest(.sessionModelState(state(recorded: "opus", last: lastRequest(.failed, requestId: "f"))))
        XCTAssertNil(store.failure(for: "claudia"), "every later state carries the same last_request; only a change is news")
    }

    func testAChangedLastRequestThatIsNotAFailureShowsNothing() {
        store.ingest(.sessionModelState(state(last: lastRequest(.failed, requestId: "f"))))
        for status in [ModelRequestStatusWire.applied, .pendingTurnEnd, .unchanged, .awaitingUser, .unknown("x")] {
            store.ingest(.sessionModelState(state(last: lastRequest(status, requestId: "n-\(status)"))))
            XCTAssertNil(store.failure(for: "claudia"), "\(status)")
        }
    }

    func testWithoutARequestIdTheTimestampStatusAndTargetTellRequestsApart() {
        store.ingest(.sessionModelState(state(last: lastRequest(.applied, to: "opus", ts: "2026-10-12T10:00:00Z"))))

        store.ingest(.sessionModelState(state(last: lastRequest(.failed, to: "opus", ts: "2026-10-12T10:05:00Z"))))
        guard let failure = store.failure(for: "claudia") else { return XCTFail("a new request with a failing status is a failure") }
        store.dismissFailure(tag: "claudia", id: failure.id)

        store.ingest(.sessionModelState(state(last: lastRequest(.failed, to: "opus", ts: "2026-10-12T10:05:00Z"))))
        XCTAssertNil(store.failure(for: "claudia"), "the identical request again is not new")

        store.ingest(.sessionModelState(state(last: lastRequest(.failed, to: "haiku", ts: "2026-10-12T10:05:00Z"))))
        XCTAssertNotNil(store.failure(for: "claudia"), "a different target is a different request")
    }

    // The gap in the contract's "compare requestId, else ts+status+to": a request that is first
    // pending and later fails keeps its request id. That is news, and must show.
    func testARequestThatWasPendingAndThenFailsWithTheSameIdIsStillAFailure() {
        store.ingest(.sessionModelState(state(last: lastRequest(.pendingTurnEnd, requestId: "agent-1", actor: "agent:cody"))))
        store.ingest(.sessionModelState(state(last: lastRequest(.failed, requestId: "agent-1", actor: "agent:cody"))))
        XCTAssertEqual(store.failure(for: "claudia")?.message, "Couldn't switch: something went wrong")
    }

    // MARK: One request, one failure

    func testARequestAnsweredByItsResultFrameDoesNotFailAgainWhenTheStateCarriesItAsLastRequest() {
        store.ingest(.sessionModelState(state()))
        let id = store.requestSwitch(tag: "claudia", model: "opus", effort: nil)
        store.ingest(result(id, .refused, code: "unknown_model"))
        guard let failure = store.failure(for: "claudia") else { return XCTFail("the result must show a failure") }

        store.ingest(.sessionModelState(state(last: lastRequest(.refused, requestId: id, actor: "user"))))
        XCTAssertEqual(store.failure(for: "claudia"), failure, "same request, same failure: not replaced, not renumbered")

        store.dismissFailure(tag: "claudia", id: failure.id)
        store.ingest(.sessionModelState(state(recorded: "haiku", last: lastRequest(.refused, requestId: id, actor: "user"))))
        XCTAssertNil(store.failure(for: "claudia"))
    }

    // The daemon may broadcast the refused state before it sends the result frame. The request
    // is one of this store's own, so the result frame (with the code and message) is its report.
    func testARequestOfThisStoreThatShowsUpInTheStateBeforeItsResultFailsOnceWithTheDetailedMessage() {
        store.ingest(.sessionModelState(state()))
        let id = store.requestSwitch(tag: "claudia", model: "opus", effort: nil)
        store.ingest(.sessionModelState(state(last: lastRequest(.refused, requestId: id, actor: "user"))))
        store.ingest(result(id, .refused, code: "unknown_model"))
        XCTAssertEqual(store.failure(for: "claudia")?.message, "Couldn't switch: that model isn't available")
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

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) {
        modelWaitUntil(file: file, line: line, condition)
    }

    /// Let anything already queued on the main run loop land (used to prove something did NOT happen).
    private func settle() {
        modelFlushMain()
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

    // VoiceOver reads the view's own label; the text field inside it must not be read a second time.
    func testANoteBlockViewIsOneStaticTextElementWhoseChildTextIsHiddenFromVoiceOver() {
        let view = NoteBlockView(text: Self.text)
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .staticText)
        XCTAssertEqual(view.accessibilityLabel(), Self.text)
        XCTAssertTrue((view.accessibilityChildren() ?? []).isEmpty, "the note is read once, from the element's own label")
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
