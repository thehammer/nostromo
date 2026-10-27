import XCTest

// The terminal wire (`TerminalWire.swift`) against the JSON the daemon's serde produces
// (`src/ipc/protocol.rs`: `terminal_client_messages_round_trip_with_their_wire_names`,
// `terminal_server_messages_round_trip_with_their_wire_names`, `terminal_closed_is_flat_on_the_wire`,
// `a_minimal_open_local_omits_its_optional_fields`, `fn info()`).
//
// The Mac client decodes frames two ways: the Decodable structs, and `NostromodClient.decode`, which
// turns a parsed frame into a `ServerMsg`. Both are covered, because the hot-path frames
// (`terminal_replay`, `terminal_output`) are read from the parsed object instead of being re-decoded.

final class TerminalWireTests: XCTestCase {

    // MARK: Fixtures (the shapes the Rust serde emits)

    private let localInfoJSON = """
    {"terminal_id":"t1","tag":"core-1","pane_id":"terminal-0a1b2c3d","kind":"local","label":"Terminal",
     "cwd":"/tmp","status":"running","cols":80,"rows":24,"requested_by":{"kind":"user"},
     "opened_by_request":"req-1"}
    """

    private let ecsClosedJSON = """
    {"type":"terminal_closed","terminal_id":"t1","tag":"core-1","pane_id":"terminal-0a1b2c3d",
     "label":"Terminal","kind":"ecs","reason":"daemon_stopped",
     "target":{"project":"admin-portal","environment":"production","service":"web","shell_type":"shell"}}
    """

    private func frameJSON(_ type: String, _ fields: String) -> String {
        "{\"type\":\"\(type)\",\(fields)}"
    }

    private func decoded(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ServerMsg {
        let raw = Data(json.utf8)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                                   file: file, line: line)
        let type = try XCTUnwrap(object["type"] as? String, file: file, line: line)
        return NostromodClient(socketPath: "/dev/null").decode(type_: type, json: object, raw: raw)
    }

    private func isUnknown(_ msg: ServerMsg) -> Bool {
        if case .unknown = msg { return true }
        return false
    }

    private func info(_ json: String) throws -> TerminalInfo {
        try JSONDecoder().decode(TerminalInfo.self, from: Data(json.utf8))
    }

    private func object(_ message: TerminalClientMessage) throws -> [String: Any] {
        let data = try XCTUnwrap(message.encoded())
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Client messages

    func testEveryClientMessageCarriesItsWireName() throws {
        let cases: [(TerminalClientMessage, String)] = [
            (.openLocal(tag: "core-1", relativeTo: "repl", position: "split_below", cwd: "/tmp",
                        clientRequestId: "req-1"), "terminal_open_local"),
            (.attach(terminalId: "t1"), "terminal_attach"),
            (.detach(terminalId: "t1"), "terminal_detach"),
            (.input(terminalId: "t1", bytes: Array("ls\n".utf8)), "terminal_input"),
            (.resize(terminalId: "t1", cols: 120, rows: 40), "terminal_resize"),
            (.close(terminalId: "t1"), "terminal_close"),
            (.restart(terminalId: "t1"), "terminal_restart"),
            (.keepAlive(terminalId: "t1"), "terminal_keep_alive"),
            (.refusalReport(terminalId: nil, op: .input, channel: "app_control"), "terminal_refusal_report"),
        ]
        for (message, name) in cases {
            XCTAssertEqual(try object(message)["type"] as? String, name)
            XCTAssertEqual(message.jsonObject["type"] as? String, name)
        }
    }

    func testOpenLocalWithEverythingSetCarriesAllItsFields() throws {
        let o = try object(.openLocal(tag: "core-1", relativeTo: "repl", position: "split_below",
                                      cwd: "/tmp", clientRequestId: "req-1"))
        XCTAssertEqual(o["tag"] as? String, "core-1")
        XCTAssertEqual(o["relative_to"] as? String, "repl")
        XCTAssertEqual(o["position"] as? String, "split_below")
        XCTAssertEqual(o["cwd"] as? String, "/tmp")
        XCTAssertEqual(o["client_request_id"] as? String, "req-1")
    }

    func testAMinimalOpenLocalHasExactlyThreeKeys() throws {
        let o = try object(.openLocal(tag: "core-1", relativeTo: nil, position: nil, cwd: nil,
                                      clientRequestId: "req-1"))
        XCTAssertEqual(Set(o.keys), ["type", "tag", "client_request_id"], "\(o)")
    }

    func testOpenLocalOmitsOnlyTheOptionalFieldsThatAreNil() throws {
        let o = try object(.openLocal(tag: "core-1", relativeTo: nil, position: "split_right", cwd: nil,
                                      clientRequestId: "req-2"))
        XCTAssertEqual(Set(o.keys), ["type", "tag", "client_request_id", "position"], "\(o)")
    }

    func testInputBytesAreBase64OnTheWire() throws {
        let o = try object(.input(terminalId: "t1", bytes: Array("ls\n".utf8)))
        XCTAssertEqual(o["terminal_id"] as? String, "t1")
        XCTAssertEqual(o["bytes"] as? String, "bHMK")
        XCTAssertEqual(Set(o.keys), ["type", "terminal_id", "bytes"])
    }

    func testInputBytesThatAreNotUTF8SurviveBase64() throws {
        let bytes: [UInt8] = [0x1b, 0x5b, 0x41, 0x00, 0xff, 0xfe]
        let o = try object(.input(terminalId: "t1", bytes: bytes))
        let text = try XCTUnwrap(o["bytes"] as? String)
        XCTAssertEqual(Array(try XCTUnwrap(Data(base64Encoded: text))), bytes)
    }

    // MARK: Auto replies

    func testAnOrdinaryInputFrameHasNoAutoReplyKey() throws {
        let o = try object(.input(terminalId: "t1", bytes: Array("ls\n".utf8)))
        XCTAssertNil(o["auto_reply"], "an older daemon must see exactly the frame it always saw: \(o)")
        let explicit = try object(.input(terminalId: "t1", bytes: Array("ls\n".utf8), autoReply: false))
        XCTAssertNil(explicit["auto_reply"], "false is omitted, not sent as false: \(explicit)")
        XCTAssertEqual(Set(explicit.keys), ["type", "terminal_id", "bytes"])
    }

    func testAnAutoReplyInputFrameCarriesAutoReplyTrue() throws {
        let o = try object(.input(terminalId: "t1", bytes: Array("\u{1b}[0;0R".utf8), autoReply: true))
        XCTAssertEqual(o["auto_reply"] as? Bool, true, "\(o)")
        XCTAssertEqual(Set(o.keys), ["type", "terminal_id", "bytes", "auto_reply"])
    }

    func testAnAutoReplyKeepsItsTypeTerminalAndBase64Bytes() throws {
        let message = TerminalClientMessage.input(terminalId: "t1", bytes: Array("ls\n".utf8), autoReply: true)
        let o = try object(message)
        XCTAssertEqual(o["type"] as? String, "terminal_input")
        XCTAssertEqual(message.jsonObject["type"] as? String, "terminal_input")
        XCTAssertEqual(o["terminal_id"] as? String, "t1")
        XCTAssertEqual(o["bytes"] as? String, "bHMK")
        XCTAssertEqual(message.jsonObject["auto_reply"] as? Bool, true)
    }

    func testAnAutoReplyIsNotEqualToTheSameBytesTypedByAPerson() {
        XCTAssertNotEqual(TerminalClientMessage.input(terminalId: "t1", bytes: [0x61], autoReply: true),
                          TerminalClientMessage.input(terminalId: "t1", bytes: [0x61]))
        XCTAssertEqual(TerminalClientMessage.input(terminalId: "t1", bytes: [0x61]),
                       TerminalClientMessage.input(terminalId: "t1", bytes: [0x61], autoReply: false))
    }

    func testResizeCarriesColsAndRowsAsNumbers() throws {
        let o = try object(.resize(terminalId: "t1", cols: 120, rows: 40))
        XCTAssertEqual(o["cols"] as? Int, 120)
        XCTAssertEqual(o["rows"] as? Int, 40)
        XCTAssertEqual(o["terminal_id"] as? String, "t1")
    }

    func testAttachDetachCloseAndRestartNameOnlyTheTerminal() throws {
        let messages: [TerminalClientMessage] = [
            .attach(terminalId: "t9"), .detach(terminalId: "t9"), .close(terminalId: "t9"), .restart(terminalId: "t9"),
            .keepAlive(terminalId: "t9"),
        ]
        for message in messages {
            let o = try object(message)
            XCTAssertEqual(Set(o.keys), ["type", "terminal_id"], "\(o)")
            XCTAssertEqual(o["terminal_id"] as? String, "t9")
        }
    }

    func testARefusalReportWithoutATerminalOmitsTheTerminalId() throws {
        let o = try object(.refusalReport(terminalId: nil, op: .input, channel: "app_control"))
        XCTAssertEqual(Set(o.keys), ["type", "op", "channel"], "\(o)")
        XCTAssertEqual(o["op"] as? String, "input")
        XCTAssertEqual(o["channel"] as? String, "app_control")
    }

    func testARefusalReportForATerminalNamesItAndTheOp() throws {
        let o = try object(.refusalReport(terminalId: "t1", op: .restart, channel: "app_control"))
        XCTAssertEqual(o["terminal_id"] as? String, "t1")
        XCTAssertEqual(o["op"] as? String, "restart")
    }

    func testEveryRefusedOpHasItsWireWord() {
        XCTAssertEqual(TerminalRefusedOp.input.rawValue, "input")
        XCTAssertEqual(TerminalRefusedOp.close.rawValue, "close")
        XCTAssertEqual(TerminalRefusedOp.restart.rawValue, "restart")
        XCTAssertEqual(TerminalRefusedOp.paste.rawValue, "paste")
        XCTAssertEqual(TerminalRefusedOp.resize.rawValue, "resize")
        XCTAssertEqual(TerminalRefusedOp.open.rawValue, "open")
    }

    // MARK: terminal_state / TerminalInfo

    func testTerminalStateDecodesAnInfoWithItsRequiredFields() throws {
        let frame = try JSONDecoder().decode(TerminalStateFrame.self,
                                             from: Data(frameJSON("terminal_state", "\"terminal\":\(localInfoJSON)").utf8))
        let t = frame.terminal
        XCTAssertEqual(t.terminalId, "t1")
        XCTAssertEqual(t.tag, "core-1")
        XCTAssertEqual(t.paneId, "terminal-0a1b2c3d")
        XCTAssertEqual(t.kind, .local)
        XCTAssertEqual(t.label, "Terminal")
        XCTAssertEqual(t.status, .running)
        XCTAssertEqual(t.cols, 80)
        XCTAssertEqual(t.rows, 24)
        XCTAssertEqual(t.requestedBy.kind, "user")
        XCTAssertNil(t.requestedBy.tag)
    }

    func testInfoOptionalFieldsAreNilWhenAbsent() throws {
        let t = try info("""
        {"terminal_id":"t1","tag":"core-1","pane_id":"terminal-0a1b2c3d","kind":"local","label":"Terminal",
         "status":"connecting","cols":80,"rows":24,"requested_by":{"kind":"user"}}
        """)
        XCTAssertNil(t.cwd)
        XCTAssertNil(t.target)
        XCTAssertNil(t.exitCode)
        XCTAssertNil(t.endedReason)
        XCTAssertNil(t.openedByRequest)
        XCTAssertNil(t.follower)
        XCTAssertNil(t.idleClosesAt)
        XCTAssertEqual(t.status, .connecting)
    }

    func testInfoOptionalFieldsDecodeWhenPresent() throws {
        let t = try info("""
        {"terminal_id":"t2","tag":"core-1","pane_id":"terminal-ff","kind":"ecs","label":"admin-portal / production / web",
         "cwd":"/srv","target":{"project":"admin-portal","environment":"production","service":"web","shell_type":"shell"},
         "status":"ended","exit_code":130,"ended_reason":"daemon_stopped","cols":100,"rows":30,
         "requested_by":{"kind":"focus","tag":"cody-1"},"opened_by_request":"req-9",
         "follower":{"tag":"cody-1","paused":true,"pause_reason":"too_much_output"},
         "idle_closes_at":"2026-10-26T20:15:00Z"}
        """)
        XCTAssertEqual(t.kind, .ecs)
        XCTAssertEqual(t.cwd, "/srv")
        XCTAssertEqual(t.target, TerminalTarget(project: "admin-portal", environment: "production",
                                                service: "web", shellType: "shell"))
        XCTAssertEqual(t.status, .ended)
        XCTAssertEqual(t.exitCode, 130)
        XCTAssertEqual(t.endedReason, "daemon_stopped")
        XCTAssertEqual(t.requestedBy.kind, "focus")
        XCTAssertEqual(t.requestedBy.tag, "cody-1")
        XCTAssertEqual(t.openedByRequest, "req-9")
        XCTAssertEqual(t.follower, TerminalFollower(tag: "cody-1", paused: true, pauseReason: "too_much_output"))
        XCTAssertEqual(t.idleClosesAt, "2026-10-26T20:15:00Z")
    }

    func testAFollowerWithoutAPauseReasonDecodes() throws {
        let t = try info("""
        {"terminal_id":"t1","tag":"core-1","pane_id":"p","kind":"local","label":"Terminal","status":"running",
         "cols":80,"rows":24,"requested_by":{"kind":"user"},"follower":{"tag":"cody-1","paused":false}}
        """)
        XCTAssertEqual(t.follower, TerminalFollower(tag: "cody-1", paused: false, pauseReason: nil))
    }

    func testAnUnknownKindOrStatusDecodesAsUnknownInsteadOfFailingTheFrame() throws {
        let t = try info("""
        {"terminal_id":"t1","tag":"core-1","pane_id":"p","kind":"quantum","label":"Terminal","status":"hibernating",
         "cols":80,"rows":24,"requested_by":{"kind":"user"}}
        """)
        XCTAssertEqual(t.kind, .unknown)
        XCTAssertEqual(t.status, .unknown)
    }

    func testAFrameWithAnUnknownKindStillDecodesThroughTheClient() throws {
        let json = frameJSON("terminal_state", """
        "terminal":{"terminal_id":"t1","tag":"core-1","pane_id":"p","kind":"quantum","label":"Terminal",
        "status":"hibernating","cols":80,"rows":24,"requested_by":{"kind":"user"}}
        """)
        guard case .terminalState(let t) = try decoded(json) else { return XCTFail("not a terminalState") }
        XCTAssertEqual(t.kind, .unknown)
        XCTAssertEqual(t.status, .unknown)
    }

    func testEveryKnownKindAndStatusDecodes() throws {
        for (word, kind) in [("local", TerminalKind.local), ("ecs", .ecs)] {
            let k = try JSONDecoder().decode(TerminalKind.self, from: Data("\"\(word)\"".utf8))
            XCTAssertEqual(k, kind)
        }
        for (word, status) in [("connecting", TerminalStatus.connecting), ("running", .running), ("ended", .ended)] {
            let s = try JSONDecoder().decode(TerminalStatus.self, from: Data("\"\(word)\"".utf8))
            XCTAssertEqual(s, status)
        }
    }

    func testTerminalStateDecodesThroughTheClient() throws {
        guard case .terminalState(let t) = try decoded(frameJSON("terminal_state", "\"terminal\":\(localInfoJSON)")) else {
            return XCTFail("not a terminalState")
        }
        XCTAssertEqual(t.terminalId, "t1")
        XCTAssertEqual(t.openedByRequest, "req-1")
        XCTAssertEqual(t.cwd, "/tmp")
    }

    func testAnInfoMissingARequiredFieldDropsTheFrame() throws {
        let json = frameJSON("terminal_state", "\"terminal\":{\"terminal_id\":\"t1\",\"tag\":\"core-1\"}")
        XCTAssertTrue(isUnknown(try decoded(json)))
    }

    // MARK: terminal_list

    func testTerminalListDecodesTerminalsAndClosed() throws {
        let json = frameJSON("terminal_list", """
        "terminals":[\(localInfoJSON)],"closed":[\(ecsClosedJSON)]
        """)
        let frame = try JSONDecoder().decode(TerminalListFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.terminals.map(\.terminalId), ["t1"])
        XCTAssertEqual(frame.closed.map(\.reason), ["daemon_stopped"])
    }

    func testTerminalListWithoutAClosedKeyHasNoClosed() throws {
        let json = frameJSON("terminal_list", "\"terminals\":[\(localInfoJSON)]")
        let frame = try JSONDecoder().decode(TerminalListFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.terminals.count, 1)
        XCTAssertTrue(frame.closed.isEmpty)
    }

    func testTerminalListDecodesThroughTheClientWithAndWithoutClosed() throws {
        guard case .terminalList(let withClosed) = try decoded(frameJSON("terminal_list", """
        "terminals":[\(localInfoJSON)],"closed":[\(ecsClosedJSON)]
        """)) else { return XCTFail("not a terminalList") }
        XCTAssertEqual(withClosed.terminals.count, 1)
        XCTAssertEqual(withClosed.closed.count, 1)

        guard case .terminalList(let without) = try decoded(frameJSON("terminal_list", "\"terminals\":[]")) else {
            return XCTFail("not a terminalList")
        }
        XCTAssertTrue(without.terminals.isEmpty)
        XCTAssertTrue(without.closed.isEmpty)
    }

    // MARK: terminal_closed (flat)

    func testTerminalClosedIsFlatAndDecodesItsTarget() throws {
        let closed = try JSONDecoder().decode(TerminalClosedInfo.self, from: Data(ecsClosedJSON.utf8))
        XCTAssertEqual(closed.terminalId, "t1")
        XCTAssertEqual(closed.tag, "core-1")
        XCTAssertEqual(closed.paneId, "terminal-0a1b2c3d")
        XCTAssertEqual(closed.label, "Terminal")
        XCTAssertEqual(closed.kind, .ecs)
        XCTAssertEqual(closed.reason, "daemon_stopped")
        XCTAssertNil(closed.exitCode)
        XCTAssertEqual(closed.target?.project, "admin-portal")
        XCTAssertEqual(closed.target?.shellType, "shell")
    }

    func testALocalTerminalClosedByExitHasAnExitCodeAndNoTarget() throws {
        let json = """
        {"type":"terminal_closed","terminal_id":"t1","tag":"core-1","pane_id":"terminal-0a1b2c3d",
         "label":"Terminal","kind":"local","reason":"exited","exit_code":0}
        """
        guard case .terminalClosed(let closed) = try decoded(json) else { return XCTFail("not a terminalClosed") }
        XCTAssertEqual(closed.reason, "exited")
        XCTAssertEqual(closed.exitCode, 0)
        XCTAssertEqual(closed.kind, .local)
        XCTAssertNil(closed.target)
    }

    func testTerminalClosedDecodesThroughTheClient() throws {
        guard case .terminalClosed(let closed) = try decoded(ecsClosedJSON) else { return XCTFail("not a terminalClosed") }
        XCTAssertEqual(closed.terminalId, "t1")
        XCTAssertEqual(closed.target?.environment, "production")
    }

    // MARK: terminal_replay / terminal_output (base64)

    func testTerminalReplayDecodesItsSizeAndBytes() throws {
        let json = frameJSON("terminal_replay", "\"terminal_id\":\"t1\",\"cols\":80,\"rows\":24,\"bytes\":\"aGk=\"")
        let frame = try JSONDecoder().decode(TerminalReplayFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.terminalId, "t1")
        XCTAssertEqual(frame.cols, 80)
        XCTAssertEqual(frame.rows, 24)
        XCTAssertEqual(frame.bytes, Array("hi".utf8))
    }

    func testTerminalReplayDecodesThroughTheClient() throws {
        let json = frameJSON("terminal_replay", "\"terminal_id\":\"t1\",\"cols\":132,\"rows\":43,\"bytes\":\"aGk=\"")
        guard case .terminalReplay(let frame) = try decoded(json) else { return XCTFail("not a terminalReplay") }
        XCTAssertEqual(frame.terminalId, "t1")
        XCTAssertEqual(frame.cols, 132)
        XCTAssertEqual(frame.rows, 43)
        XCTAssertEqual(frame.bytes, Array("hi".utf8))
    }

    func testAnEmptyReplayDecodesToNoBytes() throws {
        let json = frameJSON("terminal_replay", "\"terminal_id\":\"t1\",\"cols\":80,\"rows\":24,\"bytes\":\"\"")
        guard case .terminalReplay(let frame) = try decoded(json) else { return XCTFail("not a terminalReplay") }
        XCTAssertTrue(frame.bytes.isEmpty)
    }

    func testTerminalOutputDecodesBase64ToBytes() throws {
        let json = frameJSON("terminal_output", "\"terminal_id\":\"t1\",\"bytes\":\"aGk=\"")
        let frame = try JSONDecoder().decode(TerminalOutputFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.terminalId, "t1")
        XCTAssertEqual(frame.bytes, [0x68, 0x69])
    }

    func testTerminalOutputDecodesThroughTheClientAndKeepsBinaryBytes() throws {
        let raw: [UInt8] = [0x1b, 0x5b, 0x32, 0x4a, 0x00, 0xff]
        let b64 = Data(raw).base64EncodedString()
        guard case .terminalOutput(let frame) = try decoded(frameJSON("terminal_output",
                                                                    "\"terminal_id\":\"t7\",\"bytes\":\"\(b64)\"")) else {
            return XCTFail("not a terminalOutput")
        }
        XCTAssertEqual(frame.terminalId, "t7")
        XCTAssertEqual(frame.bytes, raw)
    }

    func testInvalidBase64FailsTheStructDecode() {
        let output = frameJSON("terminal_output", "\"terminal_id\":\"t1\",\"bytes\":\"!!!not base64!!!\"")
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalOutputFrame.self, from: Data(output.utf8)))
        let replay = frameJSON("terminal_replay", "\"terminal_id\":\"t1\",\"cols\":80,\"rows\":24,\"bytes\":\"%%%\"")
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalReplayFrame.self, from: Data(replay.utf8)))
    }

    func testInvalidBase64MakesTheClientDropTheFrame() throws {
        XCTAssertTrue(isUnknown(try decoded(frameJSON("terminal_output",
                                                      "\"terminal_id\":\"t1\",\"bytes\":\"!!!not base64!!!\""))))
        XCTAssertTrue(isUnknown(try decoded(frameJSON("terminal_replay",
                                                      "\"terminal_id\":\"t1\",\"cols\":80,\"rows\":24,\"bytes\":\"%%%\""))))
    }

    func testAnOutputFrameWithoutBytesOrTerminalIsDropped() throws {
        XCTAssertTrue(isUnknown(try decoded(frameJSON("terminal_output", "\"terminal_id\":\"t1\""))))
        XCTAssertTrue(isUnknown(try decoded(frameJSON("terminal_output", "\"bytes\":\"aGk=\""))))
    }

    // MARK: terminal_refused

    func testTerminalRefusedDecodesItsOpTerminalAndCode() throws {
        let json = frameJSON("terminal_refused",
                             "\"op\":\"input\",\"terminal_id\":\"t1\",\"code\":\"terminal_input_forbidden\"")
        let frame = try JSONDecoder().decode(TerminalRefusedFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.op, "input")
        XCTAssertEqual(frame.terminalId, "t1")
        XCTAssertEqual(frame.code, "terminal_input_forbidden")
    }

    func testTerminalRefusedWithoutATerminalDecodesThroughTheClient() throws {
        guard case .terminalRefused(let frame) = try decoded(frameJSON("terminal_refused",
                                                                     "\"op\":\"open\",\"code\":\"no_such_pane\"")) else {
            return XCTFail("not a terminalRefused")
        }
        XCTAssertEqual(frame.op, "open")
        XCTAssertNil(frame.terminalId)
        XCTAssertEqual(frame.code, "no_such_pane")
    }

    func testTerminalRefusedMissingItsCodeIsDropped() throws {
        XCTAssertTrue(isUnknown(try decoded(frameJSON("terminal_refused", "\"op\":\"input\""))))
    }
}
