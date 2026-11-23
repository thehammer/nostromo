import XCTest
@testable import NostromoKit

/// The `/mcp` panel's wire and model: tolerant decode, and what each answer lets the panel offer.
final class McpWireTests: XCTestCase {

    private func result(_ json: String) throws -> SessionMcpResultWire {
        try JSONDecoder().decode(SessionMcpResultWire.self, from: Data(json.utf8))
    }

    private func server(_ name: String, _ status: McpStatusKind, bridge: Bool? = nil) -> McpServerViewWire {
        McpServerViewWire(name: name, status: status, nostromoBridge: bridge)
    }

    // MARK: Decode

    func testAnEntryWithoutANameIsSkippedAndUnknownFieldsAreIgnored() throws {
        let r = try result("""
        {"request_id":"r","tag":"t","action":"status","outcome":"ok","brand_new":1,"servers":[
          {"status":"connected"},
          {"name":"a","status":"weird-new-state","tool_count":3,"transport":"stdio","future":{"x":1}},
          {"name":"b","status":"connected","tool_count":"many"}]}
        """)
        XCTAssertEqual(r.servers?.map(\.name), ["a", "b"])
        XCTAssertEqual(r.servers?[0].status, .unknown("weird-new-state"))
        XCTAssertEqual(r.servers?[0].toolCount, 3)
        XCTAssertNil(r.servers?[1].toolCount, "a wrong-typed field is absent, not fatal")
    }

    func testAnUnknownOutcomeDecodesAsUnknown() throws {
        let r = try result(#"{"request_id":"r","tag":"t","action":"status","outcome":"brand_new"}"#)
        XCTAssertEqual(r.outcome, .unknown("brand_new"))
        XCTAssertNil(r.servers)
    }

    func testTheKnownStatusWordsMap() {
        XCTAssertEqual(McpStatusKind(raw: "connected"), .connected)
        XCTAssertEqual(McpStatusKind(raw: "needs-auth"), .needsAuth)
        XCTAssertEqual(McpStatusKind(raw: "failed"), .failed)
        XCTAssertEqual(McpStatusKind(raw: "disabled"), .disabled)
        XCTAssertEqual(McpStatusKind(raw: "pending"), .pending)
        XCTAssertEqual(McpStatusKind(raw: "zzz"), .unknown("zzz"))
    }

    func testTheServerMsgDecodesAMcpResult() {
        let data = Data(#"{"type":"session_mcp_result","request_id":"r","tag":"t","action":"status","outcome":"ok","servers":[]}"#.utf8)
        guard case .sessionMcpResult(let wire) = ServerMsg.decode(from: data) else { return XCTFail("not decoded") }
        XCTAssertEqual(wire.outcome, .ok)
    }

    func testTheRequestEncodesItsFields() throws {
        let data = try JSONEncoder().encode(ClientSessionMcp(requestId: "r", tag: "t", action: "toggle", server: "gh", enabled: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "session_mcp")
        XCTAssertEqual(json["request_id"] as? String, "r")
        XCTAssertEqual(json["server"] as? String, "gh")
        XCTAssertEqual(json["enabled"] as? Bool, false)
    }

    // MARK: Rows and buttons

    func testNostromoCannotBeDisabledButCanBeEnabled() {
        XCTAssertFalse(McpPanelModel.row(server("nostromo", .connected)).canToggle)
        let off = McpPanelModel.row(server("nostromo", .disabled))
        XCTAssertTrue(off.canToggle)
        XCTAssertEqual(off.toggleTitle, "Enable")
        XCTAssertTrue(McpPanelModel.row(server("other", .connected)).canToggle)
    }

    func testADisabledRowCannotBeReconnected() {
        XCTAssertFalse(McpPanelModel.row(server("a", .disabled)).canReconnect)
        XCTAssertTrue(McpPanelModel.row(server("a", .failed)).canReconnect)
        XCTAssertTrue(McpPanelModel.row(server("a", .unknown("x"))).canReconnect)
    }

    func testStatusWordsAndLabels() {
        let row = McpPanelModel.row(McpServerViewWire(name: "claude.ai Metabase", status: .needsAuth, transport: "http", toolCount: nil))
        XCTAssertEqual(row.statusWord, "Needs sign-in")
        XCTAssertEqual(row.toolCountText, "—")
        XCTAssertEqual(row.reconnectLabel, "Reconnect claude.ai Metabase")
        XCTAssertEqual(row.toggleLabel, "Disable claude.ai Metabase")
        XCTAssertTrue(row.rowLabel.contains("Needs sign-in"))
        XCTAssertEqual(McpPanelModel.statusWord(.unknown("weird-new-state")), "weird-new-state")
        XCTAssertEqual(McpPanelModel.statusWord(.pending), "Starting")
    }

    func testNostromoWithItsBridgeDownSaysSo() {
        let row = McpPanelModel.row(server("nostromo", .connected, bridge: false))
        XCTAssertEqual(row.bridgeNote, "Claude says connected · Nostromo bridge offline")
        XCTAssertNil(McpPanelModel.row(server("nostromo", .connected, bridge: true)).bridgeNote)
        XCTAssertNil(McpPanelModel.row(server("other", .connected, bridge: false)).bridgeNote)
    }

    // MARK: Phases and messages

    func testNotRunningGivesNoRowsAndTheMessage() throws {
        let r = try result(#"{"request_id":"r","tag":"t","action":"status","outcome":"not_running","message":"the session is not running"}"#)
        XCTAssertEqual(McpPanelModel.phase(for: r), .notRunning)
        XCTAssertTrue(McpPanelModel.notRunningMessage.contains("isn't running"))
    }

    func testUnsupportedClosesTheActions() throws {
        let r = try result(#"{"request_id":"r","tag":"t","action":"status","outcome":"unsupported","message":"too old"}"#)
        XCTAssertEqual(McpPanelModel.phase(for: r), .unsupported("too old"))
    }

    func testAFailedStatusReadIsAPanelStateAndAFailedActionIsARowMessage() throws {
        let status = try result(#"{"request_id":"r","tag":"t","action":"status","outcome":"timeout"}"#)
        guard case .failed = McpPanelModel.phase(for: status) else { return XCTFail("status timeout") }
        let action = try result(#"{"request_id":"r","tag":"t","action":"reconnect","outcome":"refused","message":"Server not found: x"}"#)
        XCTAssertNil(McpPanelModel.phase(for: action), "the list stays as it was")
        XCTAssertEqual(McpPanelModel.failureText(action), "Server not found: x")
    }

    func testRateLimitedMessagesAreShownVerbatim() throws {
        let r = try result(#"{"request_id":"r","tag":"t","action":"reconnect","outcome":"rate_limited","message":"wait 3 s before trying a again"}"#)
        XCTAssertEqual(McpPanelModel.failureText(r), "wait 3 s before trying a again")
    }

    func testAnUnknownOutcomeIsShownAsAnError() throws {
        let r = try result(#"{"request_id":"r","tag":"t","action":"reconnect","outcome":"brand_new"}"#)
        XCTAssertTrue(McpPanelModel.failureText(r).contains("does not understand"))
    }

    func testAnOkResultWithServersIsAList() throws {
        let r = try result(#"{"request_id":"r","tag":"t","action":"reconnect","outcome":"ok","servers":[{"name":"a","status":"connected"}]}"#)
        guard case .list(let rows)? = McpPanelModel.phase(for: r) else { return XCTFail("not a list") }
        XCTAssertEqual(rows.map(\.name), ["a"])
    }

    func testTheDisableConfirmationNamesTheFolderAndThePersistence() {
        let text = McpPanelModel.disableConfirmation(server: "gh", folder: "/Users/me/code/app")
        XCTAssertTrue(text.hasPrefix("Disable gh for /Users/me/code/app?"))
        XCTAssertTrue(text.contains("every session in that folder, including terminal sessions"))
        XCTAssertTrue(text.contains("until you enable it again"))
        XCTAssertTrue(McpPanelModel.disableConfirmation(server: "gh", folder: nil).contains("this session's folder"))
    }
}
