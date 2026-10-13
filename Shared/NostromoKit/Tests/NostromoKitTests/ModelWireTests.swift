// NostromoKit — ModelWireTests.swift
//
// Model-switching wire (M2): the frames the daemon sends (`ServerMsg`), the `note`
// transcript block and delta, and the client requests that drive a switch. The fixture JSON
// is the shape the Rust side serialises (`src/ipc/protocol.rs`: SessionModelState,
// ModelFamilyWire, LastModelRequest; `src/ipc/stream_json.rs`: TurnBlock::Note with
// `note_kind`, TurnDelta::Note).

import XCTest
@testable import NostromoKit

final class ModelWireTests: XCTestCase {

    // MARK: - Fixtures

    private let catalogJSON = """
    {"type":"model_catalog","stale":true,"fetched_at":"2026-10-12T19:40:00.123456Z","families":[
      {"alias":"haiku","display_name":"Haiku","resolved":"claude-haiku-4-5-20251001","efforts":[],"rank":1},
      {"alias":"sonnet","display_name":"Sonnet","resolved":"claude-sonnet-5-5","efforts":["low","medium","high"],"rank":2},
      {"alias":"opus","display_name":"Opus","resolved":"claude-opus-5-5","efforts":["low","medium","high","xhigh","max"],"rank":3}]}
    """

    private let fullStateJSON = """
    {"type":"session_model_state","tag":"claudia",
     "recorded":{"model":"sonnet","effort":"high","source":"focus"},
     "reported":{"model":"claude-sonnet-5-5","family":"sonnet"},
     "effective_effort":"high",
     "pending":{"model":"opus","effort":"max"},
     "phase":"waiting","running":true,
     "warnings":[{"target":"opus","text":"This conversation is larger than Opus's context window"}],
     "last_request":{"actor":"user","to":"opus","status":"pending_turn_end","ts":"2026-10-12T19:47:03.123456Z","request_id":"req-7"},
     "posture":"normal"}
    """

    private let noteBlockJSON = """
    {"kind":"note","note_kind":"model_changed","text":"Model changed to Opus (from Sonnet) by you.","ts":"2026-10-12T19:47:03.123456Z"}
    """

    private func decode(_ json: String) -> ServerMsg {
        ServerMsg.decode(from: Data(json.utf8))
    }

    private func decodeBlock(_ json: String) throws -> DaemonTurnBlock {
        try JSONDecoder().decode(DaemonTurnBlock.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func state(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionModelStateWire {
        guard case let .sessionModelState(s) = decode(json) else {
            XCTFail("expected .sessionModelState", file: file, line: line)
            throw XCTSkip("not a session_model_state")
        }
        return s
    }

    // MARK: - model_catalog

    func testModelCatalogDecodesFamiliesStaleFlagAndTimestamp() throws {
        guard case let .modelCatalog(families, stale, fetchedAt) = decode(catalogJSON) else {
            return XCTFail("expected .modelCatalog")
        }
        XCTAssertEqual(families.map(\.alias), ["haiku", "sonnet", "opus"])
        XCTAssertEqual(families.map(\.rank), [1, 2, 3])
        guard families.count == 3 else { return XCTFail("expected three families") }
        XCTAssertEqual(families[2].displayName, "Opus")
        XCTAssertEqual(families[2].resolved, "claude-opus-5-5")
        XCTAssertEqual(families[2].efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(families[0].efforts, [], "an empty list means the model takes no effort levels")
        XCTAssertTrue(stale)
        XCTAssertEqual(fetchedAt, "2026-10-12T19:40:00.123456Z")
    }

    func testModelCatalogWithoutFetchedAtOrResolvedDecodes() {
        let json = #"{"type":"model_catalog","stale":false,"families":[{"alias":"fable","display_name":"Fable","efforts":["low"],"rank":4}]}"#
        guard case let .modelCatalog(families, stale, fetchedAt) = decode(json) else {
            return XCTFail("expected .modelCatalog")
        }
        guard families.count == 1 else { return XCTFail("expected one family") }
        XCTAssertNil(families[0].resolved)
        XCTAssertFalse(stale)
        XCTAssertNil(fetchedAt)
    }

    // MARK: - session_model_state

    func testFullSessionModelStateDecodesEveryField() throws {
        let s = try state(fullStateJSON)
        XCTAssertEqual(s.tag, "claudia")
        XCTAssertEqual(s.recorded, RecordedModelWire(model: "sonnet", effort: "high", source: .focus))
        XCTAssertEqual(s.reported, ReportedModelWire(model: "claude-sonnet-5-5", family: "sonnet"))
        XCTAssertEqual(s.effectiveEffort, "high")
        XCTAssertEqual(s.pending, PendingModelWire(model: "opus", effort: "max"))
        XCTAssertEqual(s.phase, .waiting)
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.warnings, [ModelWarningWire(target: "opus", text: "This conversation is larger than Opus's context window")])
        XCTAssertEqual(s.lastRequest?.actor, "user")
        XCTAssertEqual(s.lastRequest?.to, "opus")
        XCTAssertEqual(s.lastRequest?.status, .pendingTurnEnd)
        XCTAssertEqual(s.lastRequest?.requestId, "req-7")
        XCTAssertEqual(s.posture, "normal")
    }

    func testNetworkPeerShapeWithoutPostureLastRequestOrRecordedDecodes() throws {
        // A network peer is sent the state with `posture` and `last_request` left out.
        let json = #"{"type":"session_model_state","tag":"fred","reported":{"model":"claude-opus-5-5"},"running":true,"phase":"steady"}"#
        let s = try state(json)
        XCTAssertEqual(s.tag, "fred")
        XCTAssertNil(s.recorded)
        XCTAssertNil(s.lastRequest)
        XCTAssertNil(s.posture)
        XCTAssertNil(s.pending)
        XCTAssertEqual(s.warnings, [])
        XCTAssertEqual(s.reported?.model, "claude-opus-5-5")
        XCTAssertNil(s.reported?.family)
    }

    func testUnknownExtraKeysAreIgnored() throws {
        let json = """
        {"type":"session_model_state","tag":"claudia","future_top":{"a":1},
         "recorded":{"model":"opus","source":"focus","future":"x"},
         "running":false,"phase":"steady","warnings":[],
         "last_request":{"actor":"script","to":"opus","status":"applied","ts":"2026-10-12T19:47:03Z","future":[1,2]}}
        """
        let s = try state(json)
        XCTAssertEqual(s.recorded?.model, "opus")
        XCTAssertEqual(s.lastRequest?.status, .applied)
    }

    func testUnknownSourceAndPhaseStringsAreTolerated() throws {
        let json = #"{"type":"session_model_state","tag":"claudia","recorded":{"model":"opus","source":"from_the_future"},"phase":"hovering","running":true}"#
        let s = try state(json)
        XCTAssertEqual(s.tag, "claudia", "a value this build does not know must not cost the whole state")
        XCTAssertEqual(s.recorded?.model, "opus")
        XCTAssertEqual(s.recorded?.source, .unknown("from_the_future"))
        XCTAssertFalse(s.recorded?.source.isChosen ?? true, "an unknown source counts as observed, not chosen")
    }

    func testSourcesDistinguishChosenFromObserved() throws {
        for (raw, chosen) in [("focus", true), ("agent_default", true), ("agent_declared", false), ("cli_default", false)] {
            let json = #"{"type":"session_model_state","tag":"t","recorded":{"model":"opus","source":"\#(raw)"},"running":false}"#
            XCTAssertEqual(try state(json).recorded?.source.isChosen, chosen, raw)
        }
    }

    func testAnUnreadableLastRequestDoesNotCostTheState() throws {
        let json = #"{"type":"session_model_state","tag":"claudia","running":true,"last_request":{"actor":"user"}}"#
        let s = try state(json)
        XCTAssertEqual(s.tag, "claudia")
    }

    // MARK: - model_defaults

    func testModelDefaultsDecodeWithDeclared() {
        let json = #"{"type":"model_defaults","defaults":{"claudia":{"model":"opus","effort":"high"},"cody":{"model":"sonnet"}},"declared":{"claudia":"sonnet","cody":"sonnet"}}"#
        guard case let .modelDefaults(defaults, declared) = decode(json) else { return XCTFail("expected .modelDefaults") }
        XCTAssertEqual(defaults["claudia"], AgentModelDefaultWire(model: "opus", effort: "high"))
        XCTAssertEqual(defaults["cody"], AgentModelDefaultWire(model: "sonnet", effort: nil))
        XCTAssertEqual(declared, ["claudia": "sonnet", "cody": "sonnet"])
    }

    func testModelDefaultsWithoutDeclaredDecodeForNetworkPeers() {
        let json = #"{"type":"model_defaults","defaults":{"claudia":{"model":"opus"}}}"#
        guard case let .modelDefaults(defaults, declared) = decode(json) else { return XCTFail("expected .modelDefaults") }
        XCTAssertEqual(defaults["claudia"]?.model, "opus")
        XCTAssertEqual(declared, [:])
    }

    // MARK: - model_request_result

    func testRequestResultsDecodeDeniedExpiredAndAppliedStatuses() {
        for (raw, expected) in [("denied", ModelRequestStatusWire.denied), ("expired", .expired),
                                ("applied", .applied), ("pending_turn_end", .pendingTurnEnd),
                                ("unchanged", .unchanged), ("refused", .refused),
                                ("failed", .failed), ("awaiting_user", .awaitingUser)] {
            let json = #"{"type":"model_request_result","request_id":"r1","status":"\#(raw)","code":"c","message":"m","warning":"w"}"#
            guard case let .modelRequestResult(id, status, code, message, warning) = decode(json) else {
                XCTFail("expected .modelRequestResult for \(raw)"); continue
            }
            XCTAssertEqual(id, "r1")
            XCTAssertEqual(status, expected, raw)
            XCTAssertEqual(code, "c")
            XCTAssertEqual(message, "m")
            XCTAssertEqual(warning, "w")
        }
    }

    func testAnUnknownRequestStatusDecodesToUnknownInsteadOfDroppingTheFrame() {
        let json = #"{"type":"model_request_result","request_id":"r9","status":"teleported"}"#
        guard case let .modelRequestResult(id, status, code, message, warning) = decode(json) else {
            return XCTFail("an unknown status must still yield the result frame")
        }
        XCTAssertEqual(id, "r9")
        XCTAssertEqual(status, .unknown("teleported"))
        XCTAssertNil(code)
        XCTAssertNil(message)
        XCTAssertNil(warning)
    }

    // MARK: - Wire leniency (serde defaults and one bad entry among good ones)
    //
    // The Rust side defaults `recorded.source` to `focus` (`ModelSource::default`) and a daemon
    // may send a catalogue or defaults list with an entry this build cannot read. One bad entry
    // must cost that entry, never the frame, and never turn a model frame into `.unknown`.

    func testARecordedModelWithoutASourceIsAFocusChoiceLikeTheDaemonsSerdeDefault() throws {
        let json = #"{"type":"session_model_state","tag":"claudia","recorded":{"model":"opus","effort":"high"},"running":false}"#
        let s = try state(json)
        XCTAssertEqual(s.recorded?.model, "opus")
        XCTAssertEqual(s.recorded?.effort, "high")
        XCTAssertEqual(s.recorded?.source, .focus, "a missing `source` is the serde default, `focus`")
        XCTAssertEqual(s.recorded?.source.isChosen, true, "so it counts as chosen")
    }

    func testTheLastRequestKeepsItsTimestamp() throws {
        let s = try state(fullStateJSON)
        XCTAssertEqual(s.lastRequest?.ts, "2026-10-12T19:47:03.123456Z")
        let noTs = try state(#"{"type":"session_model_state","tag":"claudia","last_request":{"actor":"user","to":"opus","status":"applied"}}"#)
        XCTAssertEqual(noTs.lastRequest?.status, .applied)
        XCTAssertNil(noTs.lastRequest?.ts, "the timestamp is optional")
    }

    func testACatalogueWithoutAStaleKeyDecodesAsNotStale() {
        let json = #"{"type":"model_catalog","families":[{"alias":"opus","display_name":"Opus","efforts":["low"],"rank":3}]}"#
        guard case let .modelCatalog(families, stale, _) = decode(json) else { return XCTFail("expected .modelCatalog") }
        XCTAssertEqual(families.map(\.alias), ["opus"])
        XCTAssertFalse(stale)
    }

    func testAMalformedCatalogueFamilyIsSkippedAndTheGoodOnesSurvive() {
        let json = """
        {"type":"model_catalog","stale":false,"families":[
          {"alias":"haiku","display_name":"Haiku","efforts":[],"rank":1},
          {"display_name":"No alias","efforts":["low"],"rank":2},
          "not an object",
          5,
          null,
          {"alias":"opus","display_name":"Opus","resolved":"claude-opus-5-5","efforts":["low","high"],"rank":3}]}
        """
        guard case let .modelCatalog(families, _, _) = decode(json) else {
            return XCTFail("a bad family must not turn the whole frame into .unknown")
        }
        XCTAssertEqual(families.map(\.alias), ["haiku", "opus"])
        XCTAssertEqual(families.last?.resolved, "claude-opus-5-5")
    }

    func testACatalogueWhoseEveryFamilyIsMalformedIsAnEmptyCatalogueNotUnknown() {
        let json = #"{"type":"model_catalog","stale":true,"families":[{"display_name":"x"},"y",7]}"#
        guard case let .modelCatalog(families, stale, _) = decode(json) else {
            return XCTFail("expected .modelCatalog with no families, not .unknown")
        }
        XCTAssertEqual(families.map(\.alias), [])
        XCTAssertTrue(stale)
    }

    func testAMalformedDefaultsEntryIsSkippedAndTheRestKept() {
        let json = """
        {"type":"model_defaults","defaults":{
           "claudia":{"model":"opus","effort":"high"},
           "no_model":{"effort":"high"},
           "not_an_object":"opus",
           "wrong_type":{"model":5},
           "cody":{"model":"sonnet"}},
         "declared":{"claudia":"sonnet","bad_number":5,"bad_null":null,"bad_object":{"a":1},"cody":"sonnet"}}
        """
        guard case let .modelDefaults(defaults, declared) = decode(json) else {
            return XCTFail("a bad entry must not turn the whole frame into .unknown")
        }
        XCTAssertEqual(Set(defaults.keys), ["claudia", "cody"])
        XCTAssertEqual(defaults["claudia"], AgentModelDefaultWire(model: "opus", effort: "high"))
        XCTAssertEqual(defaults["cody"], AgentModelDefaultWire(model: "sonnet", effort: nil))
        XCTAssertEqual(declared, ["claudia": "sonnet", "cody": "sonnet"], "bad `declared` entries are skipped")
    }

    func testDefaultsWhoseEveryEntryIsMalformedAreEmptyNotUnknown() {
        let json = #"{"type":"model_defaults","defaults":{"a":{"effort":"x"},"b":3},"declared":{"a":1,"b":null}}"#
        guard case let .modelDefaults(defaults, declared) = decode(json) else {
            return XCTFail("expected .modelDefaults with empty maps, not .unknown")
        }
        XCTAssertEqual(defaults, [:])
        XCTAssertEqual(declared, [:])
    }

    // MARK: - note blocks and deltas

    func testNoteBlockDecodesItsKindTextAndTimestamp() throws {
        let block = try decodeBlock(noteBlockJSON)
        guard case let .note(kind, text, ts) = block else { return XCTFail("\(block)") }
        XCTAssertEqual(kind, "model_changed", "the wire key is `note_kind`: `kind` is the block's own tag")
        XCTAssertEqual(text, "Model changed to Opus (from Sonnet) by you.")
        XCTAssertEqual(ts, "2026-10-12T19:47:03.123456Z")
    }

    func testANoteKindANewerDaemonAddsStillDecodes() throws {
        let block = try decodeBlock(#"{"kind":"note","note_kind":"model_from_the_future","text":"hello","ts":"2026-10-12T19:47:03Z"}"#)
        guard case let .note(kind, text, _) = block else { return XCTFail("\(block)") }
        XCTAssertEqual(kind, "model_from_the_future")
        XCTAssertEqual(text, "hello")
    }

    func testNoteBlockInsideASessionTurnsSnapshotDecodes() {
        let json = """
        {"type":"session_turns","tag":"claudia","turns":[
          {"id":"t0","user_input":"hi","timestamp":"2026-10-12T19:46:00Z","is_complete":true,
           "blocks":[\(noteBlockJSON),{"kind":"text","text":"ok"}]}]}
        """
        guard case let .sessionTurns(tag, turns) = decode(json) else { return XCTFail("expected .sessionTurns") }
        XCTAssertEqual(tag, "claudia")
        guard let first = turns.first, first.blocks.count == 2 else { return XCTFail("expected one turn with two blocks") }
        guard case let .note(_, text, _) = first.blocks[0] else { return XCTFail("first block should be the note") }
        XCTAssertEqual(text, "Model changed to Opus (from Sonnet) by you.")
    }

    func testNoteDeltaDecodesWithTurnId() {
        let json = #"{"type":"session_turn_delta","tag":"claudia","delta":{"delta":"note","turn_id":"t3","block":\#(noteBlockJSON)}}"#
        guard case let .sessionTurnDelta(tag, delta) = decode(json) else { return XCTFail("expected .sessionTurnDelta") }
        XCTAssertEqual(tag, "claudia")
        guard case let .note(turnId, block) = delta else { return XCTFail("\(delta)") }
        XCTAssertEqual(turnId, "t3")
        guard case let .note(kind, _, _) = block else { return XCTFail("\(block)") }
        XCTAssertEqual(kind, "model_changed")
    }

    func testNoteDeltaDecodesWithNullTurnIdWhenTheSessionHasNoTurnYet() {
        let json = #"{"type":"session_turn_delta","tag":"claudia","delta":{"delta":"note","turn_id":null,"block":\#(noteBlockJSON)}}"#
        guard case let .sessionTurnDelta(_, delta) = decode(json), case let .note(turnId, _) = delta else {
            return XCTFail("expected a note delta")
        }
        XCTAssertNil(turnId)
    }

    // MARK: - Client requests (wire names follow the Rust ClientMsg variants)

    func testSessionModelSetEncodesEveryField() throws {
        let dict = try encode(ClientSessionModelSet(tag: "claudia", model: "opus", effort: "default",
                                                    setAsAgentDefault: false, requestId: "req-1"))
        XCTAssertEqual(dict["type"] as? String, "session_model_set")
        XCTAssertEqual(dict["tag"] as? String, "claudia")
        XCTAssertEqual(dict["model"] as? String, "opus")
        XCTAssertEqual(dict["effort"] as? String, "default", "\"default\" resets the effort; it is not the same as absent")
        XCTAssertEqual(dict["set_as_agent_default"] as? Bool, false)
        XCTAssertEqual(dict["request_id"] as? String, "req-1")
    }

    func testSessionModelSetOmitsModelWhenKeepingTheCurrentOne() throws {
        let dict = try encode(ClientSessionModelSet(tag: "claudia", model: nil, effort: "high", requestId: "req-2"))
        XCTAssertEqual(dict["type"] as? String, "session_model_set")
        XCTAssertTrue(dict["model"] == nil || dict["model"] is NSNull, "a nil model means keep the current one")
        XCTAssertEqual(dict["effort"] as? String, "high")
        XCTAssertEqual(dict["set_as_agent_default"] as? Bool, false, "the flag defaults to false")
    }

    func testSessionModelSetCarriesTheAgentDefaultFlag() throws {
        let dict = try encode(ClientSessionModelSet(tag: "claudia", model: "opus", effort: nil,
                                                    setAsAgentDefault: true, requestId: "req-3"))
        XCTAssertEqual(dict["set_as_agent_default"] as? Bool, true)
    }

    func testSessionModelGetEncodes() throws {
        let dict = try encode(ClientSessionModelGet(tag: "fred"))
        XCTAssertEqual(dict["type"] as? String, "session_model_get")
        XCTAssertEqual(dict["tag"] as? String, "fred")
    }

    func testCatalogAndDefaultsRequestsEncodeJustTheirType() throws {
        XCTAssertEqual(try encode(ClientModelCatalogRequest())["type"] as? String, "model_catalog_request")
        XCTAssertEqual(try encode(ClientModelCatalogRefresh())["type"] as? String, "model_catalog_refresh")
        XCTAssertEqual(try encode(ClientModelDefaultsRequest())["type"] as? String, "model_defaults_request")
    }

    func testModelDefaultSetEncodesAgentModelEffortAndRequestId() throws {
        let dict = try encode(ClientModelDefaultSet(agent: "claudia", model: "opus", effort: "high",
                                                    clear: false, requestId: "req-4"))
        XCTAssertEqual(dict["type"] as? String, "model_default_set")
        XCTAssertEqual(dict["agent"] as? String, "claudia")
        XCTAssertEqual(dict["model"] as? String, "opus")
        XCTAssertEqual(dict["effort"] as? String, "high")
        XCTAssertEqual(dict["clear"] as? Bool, false)
        XCTAssertEqual(dict["request_id"] as? String, "req-4")
    }

    func testModelDefaultSetClearRemovesTheAgentsDefault() throws {
        let dict = try encode(ClientModelDefaultSet(agent: "claudia", model: nil, effort: nil,
                                                    clear: true, requestId: "req-5"))
        XCTAssertEqual(dict["clear"] as? Bool, true)
        XCTAssertTrue(dict["model"] == nil || dict["model"] is NSNull)
    }
}
