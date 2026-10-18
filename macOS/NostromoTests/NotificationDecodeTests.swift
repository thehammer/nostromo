import XCTest
import NostromoKit

// NostromodClient, ServerMsg are compiled into this test target directly
// (see SessionHealthTests.swift's header comment) — no host app needed.

final class NotificationDecodeTests: XCTestCase {
    private var client: NostromodClient!

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
    }

    func testNotificationDecodesAllFields() throws {
        let raw = """
        {"type":"notification","tag":"perri","level":"warning","message":"PR #4526 was reloaded by another session."}
        """.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]

        let msg = client.decode(type_: "notification", json: json, raw: raw)

        guard case .notification(let tag, let level, let message) = msg else {
            XCTFail("expected .notification, got \(msg)")
            return
        }
        XCTAssertEqual(tag, "perri")
        XCTAssertEqual(level, "warning")
        XCTAssertEqual(message, "PR #4526 was reloaded by another session.")
    }

    func testUnrecognizedTypeStillDecodesToUnknownNotCrash() throws {
        // Sanity check the harness itself: an unrelated type must not
        // accidentally match "notification"'s decode arm.
        let raw = """
        {"type":"pong"}
        """.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let msg = client.decode(type_: "pong", json: json, raw: raw)
        guard case .pong = msg else {
            XCTFail("expected .pong, got \(msg)")
            return
        }
    }
}


// The permission-approval frames (AP0b) decode into `ServerMsg` cases. Nothing renders them yet
// (`AppStore.handle` ignores them); the wire types themselves are tested in NostromoKit
// (`ApprovalWireTests`), so this pins only the client's dispatch from frame type to case.
final class ApprovalFrameDecodeTests: XCTestCase {
    private var client: NostromodClient!

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
    }

    private func decode(_ type: String, _ text: String) throws -> ServerMsg {
        let raw = text.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return client.decode(type_: type, json: json, raw: raw)
    }

    private let request = """
    {"request_id":"r1","tag":"cody-1","tool_use_id":"toolu_1","agent":{"name":"cody"},
     "tool_name":"Bash","display_name":"Bash","tool_kind":"bash","input":{"command":"rm -rf /tmp/x"},
     "display":{"lines":[],"invisible_count":0,"non_ascii_count":0,"unparsed":false},
     "reason":{"kind":"other","text":"Claude Code asked for approval"},
     "flags":{"default_to_no":false,"suppress_always_allow_rule":false,"requires_user_interaction":false,"classifier_approvable":false},
     "options":["allow_once","deny"],"session_rule_candidates":[],"created_at_ms":1,"deadline_at_ms":2}
    """

    func testApprovalRequestDecodes() throws {
        let msg = try decode("approval_request", #"{"type":"approval_request","tag":"cody-1","request":\#(request)}"#)
        guard case .approvalRequest(let tag, let r) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(tag, "cody-1")
        XCTAssertEqual(r.requestId, "r1")
        XCTAssertEqual(r.input, .object(["command": .string("rm -rf /tmp/x")]))
    }

    func testApprovalsSnapshotDecodes() throws {
        let msg = try decode("approvals_snapshot", #"{"type":"approvals_snapshot","requests":[\#(request)]}"#)
        guard case .approvalsSnapshot(let requests) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(requests.map(\.requestId), ["r1"])
    }

    func testTheSmallFramesDecode() throws {
        guard case .approvalResolved(let resolved) = try decode("approval_resolved",
            #"{"type":"approval_resolved","tag":"t","request_id":"r1","outcome":"timed_out","at_ms":7}"#)
        else { return XCTFail("approval_resolved") }
        XCTAssertEqual(resolved.outcome, "timed_out")

        guard case .approvalPending(let tag, let count) = try decode("approval_pending",
            #"{"type":"approval_pending","tag":"t","count":3}"#)
        else { return XCTFail("approval_pending") }
        XCTAssertEqual(tag, "t")
        XCTAssertEqual(count, 3)

        guard case .approvalGuardBlocked(let blocked) = try decode("approval_guard_blocked",
            #"{"type":"approval_guard_blocked","tag":"t","tool_use_id":"u","entry_id":"e","at_ms":1,"summary":"Bash tmux"}"#)
        else { return XCTFail("approval_guard_blocked") }
        XCTAssertEqual(blocked.summary, "Bash tmux")

        guard case .approvalAnswerRefused(let refused) = try decode("approval_answer_refused",
            #"{"type":"approval_answer_refused","request_id":"r1","code":"already_resolved","outcome":"denied"}"#)
        else { return XCTFail("approval_answer_refused") }
        XCTAssertEqual(refused.code, .alreadyResolved)
        XCTAssertEqual(refused.outcome, "denied")
    }

    func testAnUndecodableApprovalFrameIsUnknownNotACrash() throws {
        let msg = try decode("approval_request", #"{"type":"approval_request","tag":"t"}"#)
        guard case .unknown = msg else { return XCTFail("got \(msg)") }
    }
}
