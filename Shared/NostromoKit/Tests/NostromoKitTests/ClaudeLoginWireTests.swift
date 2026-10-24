// NostromoKit — ClaudeLoginWireTests.swift
//
// Wire-level tests for the Claude sign-in frames (CL1). The golden JSON below is copied
// from the Rust golden strings in `src/ipc/protocol.rs`: if the daemon's wire changes,
// those fail first, and these must be updated to match.

import XCTest
@testable import NostromoKit

final class ClaudeLoginWireTests: XCTestCase {

    // MARK: - Golden JSON (from the Rust tests)

    /// One session, every field present.
    static let fullState = #"""
    {"type":"claude_login_state","needs_login":true,"claude_bin":"/opt/homebrew/bin/claude","watch":"keychain","sessions":[{"tag":"cody-1","hold_id":"7d0a1c2e-0000-4000-8000-000000000001","phase":"waiting","queued":3,"failed_at":"2026-10-18T20:04:09Z","auto_resends_left":3}]}
    """#

    /// Nothing waiting: no `claude_bin` key, no sessions.
    static let emptyState = #"""
    {"type":"claude_login_state","needs_login":false,"watch":"unavailable","sessions":[]}
    """#

    static let retryAction = #"""
    {"type":"claude_login_action","action":"retry","tag":"cody-1","hold_id":"7d0a1c2e-0000-4000-8000-000000000001","operator_nonce":"ab12"}
    """#

    static let discardAction = #"""
    {"type":"claude_login_action","action":"discard","tag":"cody-1"}
    """#

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// A state frame with one session in `phase`, optionally without a `hold_id`.
    private func stateJSON(phase: String, holdId: String?) -> String {
        let hold = holdId.map { #""hold_id":"\#($0)","# } ?? ""
        return #"{"type":"claude_login_state","needs_login":true,"watch":"keychain","sessions":[{"tag":"cody-1",\#(hold)"phase":"\#(phase)","queued":0,"failed_at":"2026-10-18T20:04:09Z","auto_resends_left":2}]}"#
    }

    // MARK: - claude_login_state

    func testTheFeatureNameIsClaudeLoginV1() {
        XCTAssertEqual(claudeLoginFeature, "claude_login_v1")
    }

    func testAFullyPopulatedStateDecodesEveryField() throws {
        let f = try decode(ClaudeLoginStateFrame.self, Self.fullState)
        XCTAssertTrue(f.needsLogin)
        XCTAssertEqual(f.claudeBin, "/opt/homebrew/bin/claude")
        XCTAssertEqual(f.watch, .keychain)
        XCTAssertEqual(f.sessions.count, 1)
        let s = try XCTUnwrap(f.sessions.first)
        XCTAssertEqual(s.tag, "cody-1")
        XCTAssertEqual(s.holdId, "7d0a1c2e-0000-4000-8000-000000000001")
        XCTAssertEqual(s.phase, .waiting)
        XCTAssertEqual(s.queued, 3)
        XCTAssertEqual(s.failedAt, "2026-10-18T20:04:09Z")
        XCTAssertEqual(s.autoResendsLeft, 3)
    }

    func testAStateWithNothingWaitingDecodesWithoutAClaudeBinOrSessions() throws {
        let f = try decode(ClaudeLoginStateFrame.self, Self.emptyState)
        XCTAssertFalse(f.needsLogin)
        XCTAssertNil(f.claudeBin)
        XCTAssertEqual(f.watch, .unavailable)
        XCTAssertEqual(f.sessions, [])
    }

    func testEveryPhaseDecodes() throws {
        let cases: [(String, ClaudeLoginPhase)] = [
            ("waiting", .waiting),
            ("resending", .resending),
            ("not_resendable", .notResendable),
        ]
        for (name, phase) in cases {
            let f = try decode(ClaudeLoginStateFrame.self, stateJSON(phase: name, holdId: "hold-1"))
            XCTAssertEqual(f.sessions.first?.phase, phase, name)
            XCTAssertEqual(f.sessions.first?.holdId, "hold-1", name)
        }
    }

    func testAPausedSessionWithNothingHeldHasNoHoldId() throws {
        let f = try decode(ClaudeLoginStateFrame.self, stateJSON(phase: "paused_no_hold", holdId: nil))
        let s = try XCTUnwrap(f.sessions.first)
        XCTAssertEqual(s.phase, .pausedNoHold)
        XCTAssertNil(s.holdId)
        XCTAssertEqual(s.autoResendsLeft, 2)
    }

    func testPhaseAndWatchRawValuesAreTheDaemonsSnakeCaseNames() {
        XCTAssertEqual(ClaudeLoginPhase.waiting.rawValue, "waiting")
        XCTAssertEqual(ClaudeLoginPhase.resending.rawValue, "resending")
        XCTAssertEqual(ClaudeLoginPhase.notResendable.rawValue, "not_resendable")
        XCTAssertEqual(ClaudeLoginPhase.pausedNoHold.rawValue, "paused_no_hold")
        XCTAssertEqual(ClaudeLoginWatch.keychain.rawValue, "keychain")
        XCTAssertEqual(ClaudeLoginWatch.unavailable.rawValue, "unavailable")
    }

    func testSeveralSessionsKeepTheirOrder() throws {
        let json = #"""
        {"type":"claude_login_state","needs_login":true,"claude_bin":"/x/claude","watch":"keychain","sessions":[
          {"tag":"a","hold_id":"h-a","phase":"waiting","queued":0,"failed_at":"2026-10-18T20:04:09Z","auto_resends_left":3},
          {"tag":"b","phase":"paused_no_hold","queued":2,"failed_at":"2026-10-18T20:04:10Z","auto_resends_left":0},
          {"tag":"c","hold_id":"h-c","phase":"not_resendable","queued":1,"failed_at":"2026-10-18T20:04:11Z","auto_resends_left":0}
        ]}
        """#
        let f = try decode(ClaudeLoginStateFrame.self, json)
        XCTAssertEqual(f.sessions.map(\.tag), ["a", "b", "c"])
        XCTAssertEqual(f.sessions.map(\.phase), [.waiting, .pausedNoHold, .notResendable])
        XCTAssertEqual(f.sessions.map(\.holdId), ["h-a", nil, "h-c"])
        XCTAssertEqual(f.sessions.map(\.queued), [0, 2, 1])
    }

    // MARK: - claude_login_action

    func testRetryEncodesTheDaemonsKeys() throws {
        let frame = ClientClaudeLoginAction(
            action: .retry, tag: "cody-1",
            holdId: "7d0a1c2e-0000-4000-8000-000000000001", operatorNonce: "ab12")
        let encoded = try encode(frame)
        XCTAssertEqual(encoded as NSDictionary, try object(Self.retryAction) as NSDictionary)
        XCTAssertEqual(encoded["type"] as? String, "claude_login_action")
        XCTAssertEqual(encoded["action"] as? String, "retry")
        XCTAssertEqual(encoded["tag"] as? String, "cody-1")
        XCTAssertEqual(encoded["hold_id"] as? String, "7d0a1c2e-0000-4000-8000-000000000001")
        XCTAssertEqual(encoded["operator_nonce"] as? String, "ab12")
    }

    func testDiscardWithoutAHoldIdOrNonceEncodesOnlyTheKeysItHas() throws {
        let frame = ClientClaudeLoginAction(action: .discard, tag: "cody-1", holdId: nil, operatorNonce: nil)
        let encoded = try encode(frame)
        XCTAssertEqual(encoded as NSDictionary, try object(Self.discardAction) as NSDictionary)
        XCTAssertNil(encoded["hold_id"], "no hold, no key")
        XCTAssertNil(encoded["operator_nonce"], "no nonce, no key (the daemon then refuses it)")
        XCTAssertEqual(Set(encoded.keys), ["type", "action", "tag"])
    }

    func testActionKindsEncodeAsTheirDaemonNames() throws {
        XCTAssertEqual(ClaudeLoginActionKind.retry.rawValue, "retry")
        XCTAssertEqual(ClaudeLoginActionKind.discard.rawValue, "discard")
        let discard = try encode(ClientClaudeLoginAction(action: .discard, tag: "t", holdId: "h", operatorNonce: "n"))
        XCTAssertEqual(discard["action"] as? String, "discard")
        XCTAssertEqual(discard["hold_id"] as? String, "h")
    }
}
