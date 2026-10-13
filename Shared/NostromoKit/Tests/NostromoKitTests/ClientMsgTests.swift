// NostromoKit — ClientMsgTests.swift
//
// Wire JSON assertions for session lifecycle control messages.
// These tests ensure the client's encoding matches the Rust daemon's
// expected protocol format at `src/ipc/protocol.rs`.

import XCTest
@testable import NostromoKit

final class ClientMsgTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - close_pane (the tab × button)

    func testClosePaneEncodesTheTagAndPaneId() throws {
        let dict = try encode(ClientClosePane(tag: "perri", paneId: "detail.1"))
        XCTAssertEqual(dict["type"] as? String, "close_pane")
        XCTAssertEqual(dict["tag"] as? String, "perri")
        XCTAssertEqual(dict["pane_id"] as? String, "detail.1", "the wire key is snake_case, like the daemon's ClosePane")
    }

    // MARK: - session_interrupt (the Stop button)

    func testSessionInterruptEncodesAsSessionInterruptNotControlStop() throws {
        // Stop-the-turn is a different message from `session_control: stop`,
        // which kills the whole session. Mixing them up would make the Stop
        // button end the agent's session instead of just its current turn.
        let dict = try encode(ClientSessionInterrupt(tag: "perri"))
        XCTAssertEqual(dict["type"] as? String, "session_interrupt")
        XCTAssertEqual(dict["tag"] as? String, "perri")
        XCTAssertNil(dict["action"], "an interrupt carries no lifecycle action")
    }

    // MARK: - result_summary: the `interrupted` flag

    private func decodeBlock(_ json: String) throws -> DaemonTurnBlock {
        try JSONDecoder().decode(DaemonTurnBlock.self, from: Data(json.utf8))
    }

    func testAnInterruptedResultSummaryDecodesWithItsFlag() throws {
        let block = try decodeBlock(#"{"kind":"result_summary","duration_ms":3200,"cost_usd":0.1,"is_error":true,"interrupted":true}"#)
        guard case let .resultSummary(_, _, isError, interrupted) = block else { return XCTFail("\(block)") }
        XCTAssertTrue(isError)
        XCTAssertTrue(interrupted, "the daemon's flag must reach the client so it can render 'Interrupted', not a failure")
    }

    func testAResultSummaryFromAnOlderDaemonDefaultsToNotInterrupted() throws {
        let block = try decodeBlock(#"{"kind":"result_summary","duration_ms":10,"cost_usd":0.0,"is_error":false}"#)
        guard case let .resultSummary(_, _, _, interrupted) = block else { return XCTFail("\(block)") }
        XCTAssertFalse(interrupted)
    }

    // MARK: - tool_call / tool_result / text: the optional identity, time and subagent keys (TF1)

    /// 2026-05-30T22:38:55Z, built from calendar components so the expectation does not
    /// lean on the parser under test.
    private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, fraction: Double = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
        return base.addingTimeInterval(fraction)
    }

    private func callMeta(_ block: DaemonTurnBlock, file: StaticString = #filePath, line: UInt = #line) -> (name: String, summary: String, full: String, meta: DaemonToolMeta)? {
        guard case let .toolCall(name, summary, full, meta) = block else { XCTFail("\(block)", file: file, line: line); return nil }
        return (name, summary, full, meta)
    }

    private func resultMeta(_ block: DaemonTurnBlock, file: StaticString = #filePath, line: UInt = #line) -> (content: String, isError: Bool, meta: DaemonToolMeta)? {
        guard case let .toolResult(content, isError, meta) = block else { XCTFail("\(block)", file: file, line: line); return nil }
        return (content, isError, meta)
    }

    func testAToolCallCarriesItsIdTargetParentAndTimestamp() throws {
        let block = try decodeBlock(#"{"kind":"tool_call","tool_name":"Read","input_summary":"a.swift","input_full":"{}","tool_use_id":"toolu_01","parent_tool_use_id":"toolu_agent1","target":"/repo/a.swift","ts":"2026-05-30T22:38:55.755Z"}"#)
        guard let c = callMeta(block) else { return }
        XCTAssertEqual(c.name, "Read")
        XCTAssertEqual(c.summary, "a.swift")
        XCTAssertEqual(c.full, "{}")
        XCTAssertEqual(c.meta.toolUseId, "toolu_01")
        XCTAssertEqual(c.meta.parentToolUseId, "toolu_agent1")
        XCTAssertEqual(c.meta.target, "/repo/a.swift")
        let ts = try XCTUnwrap(c.meta.ts)
        XCTAssertEqual(ts.timeIntervalSince1970, utc(2026, 5, 30, 22, 38, 55, fraction: 0.755).timeIntervalSince1970, accuracy: 0.001)
    }

    func testAToolResultCarriesItsIdParentAndTimestamp() throws {
        let block = try decodeBlock(#"{"kind":"tool_result","content":"","is_error":false,"tool_use_id":"toolu_01","parent_tool_use_id":"toolu_agent1","ts":"2026-05-30T22:38:55.755Z"}"#)
        guard let r = resultMeta(block) else { return }
        XCTAssertEqual(r.content, "", "an empty successful result is kept on the wire")
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.meta.toolUseId, "toolu_01")
        XCTAssertEqual(r.meta.parentToolUseId, "toolu_agent1")
        XCTAssertNil(r.meta.target, "a result has no target")
        let ts = try XCTUnwrap(r.meta.ts)
        XCTAssertEqual(ts.timeIntervalSince1970, utc(2026, 5, 30, 22, 38, 55, fraction: 0.755).timeIntervalSince1970, accuracy: 0.001)
    }

    func testAToolCallFromAnOlderDaemonDecodesWithNoMeta() throws {
        let block = try decodeBlock(#"{"kind":"tool_call","tool_name":"Bash","input_summary":"ls","input_full":"{\"command\":\"ls\"}"}"#)
        guard let c = callMeta(block) else { return }
        XCTAssertEqual(c.name, "Bash")
        XCTAssertEqual(c.meta, DaemonToolMeta.none)
        XCTAssertNil(c.meta.toolUseId)
        XCTAssertNil(c.meta.parentToolUseId)
        XCTAssertNil(c.meta.target)
        XCTAssertNil(c.meta.ts)
    }

    func testAToolResultFromAnOlderDaemonDecodesWithNoMeta() throws {
        let block = try decodeBlock(#"{"kind":"tool_result","content":"boom","is_error":true}"#)
        guard let r = resultMeta(block) else { return }
        XCTAssertEqual(r.content, "boom")
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.meta, DaemonToolMeta.none)
    }

    func testTimestampsDecodeWithWholeMillisecondAndNanosecondPrecision() throws {
        func ts(_ raw: String) throws -> Date? {
            let block = try decodeBlock(#"{"kind":"tool_result","content":"x","is_error":false,"ts":"\#(raw)"}"#)
            return resultMeta(block)?.meta.ts
        }
        let whole = try XCTUnwrap(try ts("2026-05-30T22:38:55Z"), "no fractional part is valid RFC 3339")
        XCTAssertEqual(whole.timeIntervalSince1970, utc(2026, 5, 30, 22, 38, 55).timeIntervalSince1970, accuracy: 0.001)

        let millis = try XCTUnwrap(try ts("2026-05-30T22:38:55.755Z"))
        XCTAssertEqual(millis.timeIntervalSince1970, utc(2026, 5, 30, 22, 38, 55, fraction: 0.755).timeIntervalSince1970, accuracy: 0.001)

        // chrono writes as many digits as the clock had; a stored line can carry nanoseconds.
        let nanos = try XCTUnwrap(try ts("2026-05-30T22:38:55.755123456Z"), "a nanosecond timestamp must not be lost")
        XCTAssertEqual(nanos.timeIntervalSince1970, utc(2026, 5, 30, 22, 38, 55, fraction: 0.755123456).timeIntervalSince1970, accuracy: 0.001)

        let offset = try XCTUnwrap(try ts("2026-05-30T17:38:55.755-05:00"), "a numeric offset is the same instant")
        XCTAssertEqual(offset.timeIntervalSince1970, millis.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAnUnparseableTimestampLeavesTheTimeNilAndTheBlockDecoded() throws {
        let call = try decodeBlock(#"{"kind":"tool_call","tool_name":"Bash","input_summary":"ls","input_full":"{}","tool_use_id":"toolu_9","ts":"yesterday-ish"}"#)
        guard let c = callMeta(call) else { return }
        XCTAssertNil(c.meta.ts, "a time is decoration: garbage must not cost the client the whole turn")
        XCTAssertEqual(c.meta.toolUseId, "toolu_9", "the rest of the block survives a bad time")

        let result = try decodeBlock(#"{"kind":"tool_result","content":"ok","is_error":false,"ts":""}"#)
        XCTAssertNil(resultMeta(result)?.meta.ts)
        XCTAssertEqual(resultMeta(result)?.content, "ok")
    }

    func testTextDecodesWithAndWithoutItsSubagentParent() throws {
        let subagent = try decodeBlock(#"{"kind":"text","text":"found it","parent_tool_use_id":"toolu_agent1"}"#)
        guard case let .text(s, parent) = subagent else { return XCTFail("\(subagent)") }
        XCTAssertEqual(s, "found it")
        XCTAssertEqual(parent, "toolu_agent1")

        let unknownWhose = try decodeBlock(#"{"kind":"text","text":"x","parent_tool_use_id":"?"}"#)
        guard case let .text(_, sentinel) = unknownWhose else { return XCTFail("\(unknownWhose)") }
        XCTAssertEqual(sentinel, "?", "the daemon's 'a subagent, but whose is unknown' sentinel passes through")

        let main = try decodeBlock(#"{"kind":"text","text":"hello"}"#)
        guard case let .text(m, none) = main else { return XCTFail("\(main)") }
        XCTAssertEqual(m, "hello")
        XCTAssertNil(none, "the main agent's prose has no parent")
    }

    // MARK: - session_control: stop

    func testSessionControlStop() throws {
        let msg = ClientSessionControl(tag: "fred", action: "stop")
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"] as? String,   "session_control")
        XCTAssertEqual(dict["tag"] as? String,    "fred")
        XCTAssertEqual(dict["action"] as? String, "stop")
    }

    // MARK: - session_control: restart

    func testSessionControlRestart() throws {
        let msg = ClientSessionControl(tag: "barney", action: "restart")
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"] as? String,   "session_control")
        XCTAssertEqual(dict["tag"] as? String,    "barney")
        XCTAssertEqual(dict["action"] as? String, "restart")
    }

    // MARK: - session_control: new_session

    func testSessionControlNewSession() throws {
        let msg = ClientSessionControl(tag: "fred", action: "new_session")
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"] as? String,   "session_control")
        XCTAssertEqual(dict["tag"] as? String,    "fred")
        XCTAssertEqual(dict["action"] as? String, "new_session")
    }

    // MARK: - No extra fields

    func testSessionControlHasExactlyThreeKeys() throws {
        let msg = ClientSessionControl(tag: "t", action: "stop")
        let dict = try encode(msg)
        XCTAssertEqual(dict.keys.count, 3, "Expected exactly type, tag, action")
    }

    // MARK: - subscribe: renders_decisions (decision-operator-gate fix)
    //
    // `renders_decisions` distinguishes "this client can actually render and
    // answer a decision modal" from merely "this client subscribed to
    // everything" (`topics: []`). The daemon-side fix in
    // `src/ipc/server.rs::handle_client` reads this field directly off the
    // wire to decide operator status, so its exact JSON key/shape here is
    // load-bearing — see `src/ipc/protocol.rs`'s `ClientMsg::Subscribe`.

    func testSubscribeWithRendersDecisionsFalseEncodesFalse() throws {
        let msg = ClientSubscribe(topics: [], rendersDecisions: false)
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"] as? String, "subscribe")
        XCTAssertEqual(dict["topics"] as? [String], [])
        XCTAssertEqual(
            dict["renders_decisions"] as? Bool, false,
            "renders_decisions must be present and false on the wire, not omitted"
        )
    }

    func testSubscribeWithRendersDecisionsTrueEncodesTrue() throws {
        let msg = ClientSubscribe(topics: [], rendersDecisions: true)
        let dict = try encode(msg)
        XCTAssertEqual(
            dict["renders_decisions"] as? Bool, true,
            "renders_decisions must be present and true on the wire when set"
        )
    }

    // MARK: - source guard: sendHello() must explicitly pass rendersDecisions: true
    //
    // `ClientSubscribe.init(topics:rendersDecisions:)` deliberately has no
    // default value for `rendersDecisions` — every construction site must
    // state it explicitly. `NetworkClient.sendHello()` is the one production
    // call site today.
    //
    // This test used to assert `rendersDecisions: false` (written by W1,
    // correctly describing the pre-W3 state: iOS had no code path to render
    // or answer a decision, so it had to disclaim operator status). W3 is the
    // wedge that adds that surface — `PendingDecision`, `DecisionStore`, and
    // `DaemonStore.answerDecision(requestId:choiceId:)` — so iOS can now
    // actually present and answer a `decision_request`, and `sendHello()`
    // flips to `rendersDecisions: true` accordingly: a client that can answer
    // decisions must claim operator status, or `nostromo.ask_decision`'s
    // `no_operator` fail-fast gate (`src/ipc/server.rs::handle_client`) has
    // no way to know it can. This test exists so that flip (or a future
    // accidental revert of it) is visible in the diff and caught by CI,
    // rather than silently changing iOS's operator status.
    //
    // This is a source-text assertion, not a wire/behavior test — there's no
    // existing precedent for reading `NetworkClient.swift`'s source in this
    // target, but a plain literal-text check is the simplest thing that
    // fails the instant the literal changes.
    func testSendHelloExplicitlyPassesRendersDecisionsTrue() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let networkClientURL = testFile
            .deletingLastPathComponent() // .../Tests/NostromoKitTests/ClientMsgTests.swift -> .../Tests/NostromoKitTests/
            .deletingLastPathComponent() // -> .../Tests/
            .deletingLastPathComponent() // -> .../NostromoKit/ (package root)
            .appendingPathComponent("Sources/NostromoKit/Transport/NetworkClient.swift")

        let source = try String(contentsOf: networkClientURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("ClientSubscribe(topics: [], rendersDecisions: true)"),
            "sendHello() must construct ClientSubscribe with rendersDecisions: true " +
            "explicitly — W3 gives iOS a real surface to present and answer a decision, " +
            "so it must count as an operator. If this literal reverted (e.g. back to " +
            "`false`), that's a regression of W3's whole point and this test's " +
            "expectation should only change alongside a deliberate decision to withdraw " +
            "the surface."
        )
    }
}
