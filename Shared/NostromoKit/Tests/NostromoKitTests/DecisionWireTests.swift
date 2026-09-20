// NostromoKit — DecisionWireTests.swift
//
// Wire-level tests for W3 (iOS decision answering):
//   - `ServerMsg.decode(from:)` for `decision_request` / `decision_resolved`
//     frames — nobody has tested these decode arms before this wedge (grep
//     confirms zero prior coverage), so this verifies today's already-shipped
//     decode logic in `ServerMsg.swift` rather than assuming it works.
//   - `ClientDecisionAnswer`'s encoding, including its `choice_id: null`
//     (present-but-null, not omitted) behavior for a dismiss-without-choosing
//     answer — this already exists and is deliberate per its doc comment in
//     `ClientMsg.swift`.
//   - A source-text tripwire tying iOS's `renders_decisions: true` operator
//     claim (flipped in `NetworkClient.sendHello()` by this same wedge) to
//     the actual existence of a `decisionRequest` handler in `DaemonStore`,
//     so the two can never silently drift apart.
//
// Follows `ClientMsgTests.swift`'s `encode<T: Encodable>(_:) -> [String: Any]`
// helper pattern and its `#filePath`-relative source-text-assertion technique.

import XCTest
@testable import NostromoKit

final class DecisionWireTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func jsonData(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - decision_request: full payload, both choice shapes, detail + context_pane_id present

    func testDecisionRequestDecodesAllFieldsWithBothChoiceShapes() throws {
        let json: [String: Any] = [
            "type": "decision_request",
            "tag": "fred",
            "request_id": "req-1",
            "prompt": "Deploy to prod?",
            "detail": "This will restart the service.",
            "choices": [
                ["id": "approve", "label": "Approve", "detail": "Ship it now"],
                ["id": "deny", "label": "Deny"],
            ],
            "context_pane_id": "pane-42",
        ]
        let msg = ServerMsg.decode(from: try jsonData(json))

        guard case let .decisionRequest(tag, requestId, prompt, detail, choices, contextPaneId) = msg else {
            XCTFail("expected .decisionRequest, got \(msg)")
            return
        }
        XCTAssertEqual(tag, "fred")
        XCTAssertEqual(requestId, "req-1")
        XCTAssertEqual(prompt, "Deploy to prod?")
        XCTAssertEqual(detail, "This will restart the service.")
        XCTAssertEqual(choices, [
            DecisionChoice(id: "approve", label: "Approve", detail: "Ship it now"),
            DecisionChoice(id: "deny", label: "Deny", detail: nil),
        ])
        XCTAssertEqual(contextPaneId, "pane-42")
    }

    // MARK: - decision_request: detail + context_pane_id keys entirely absent

    func testDecisionRequestDecodesWithDetailAndContextPaneIdAbsent() throws {
        let json: [String: Any] = [
            "type": "decision_request",
            "tag": "fred",
            "request_id": "req-2",
            "prompt": "Continue?",
            "choices": [
                ["id": "yes", "label": "Yes"],
            ],
            // "detail" and "context_pane_id" keys are entirely omitted.
        ]
        let msg = ServerMsg.decode(from: try jsonData(json))

        guard case let .decisionRequest(_, _, _, detail, choices, contextPaneId) = msg else {
            XCTFail("expected .decisionRequest, got \(msg)")
            return
        }
        XCTAssertNil(detail, "detail must decode to nil when the key is entirely absent")
        XCTAssertNil(contextPaneId, "context_pane_id must decode to nil when the key is entirely absent")
        XCTAssertEqual(choices, [DecisionChoice(id: "yes", label: "Yes", detail: nil)])
    }

    // MARK: - decision_resolved: "answered" carries choice_id

    func testDecisionResolvedDecodesAnsweredWithChoiceId() throws {
        let json: [String: Any] = [
            "type": "decision_resolved",
            "tag": "fred",
            "request_id": "req-1",
            "resolution": "answered",
            "choice_id": "approve",
        ]
        let msg = ServerMsg.decode(from: try jsonData(json))

        guard case let .decisionResolved(tag, requestId, resolution, choiceId) = msg else {
            XCTFail("expected .decisionResolved, got \(msg)")
            return
        }
        XCTAssertEqual(tag, "fred")
        XCTAssertEqual(requestId, "req-1")
        XCTAssertEqual(resolution, "answered")
        XCTAssertEqual(choiceId, "approve")
    }

    // MARK: - decision_resolved: "dismissed" / "timeout" / "cancelled" omit choice_id entirely

    func testDecisionResolvedDecodesDismissedWithoutChoiceId() throws {
        let json: [String: Any] = [
            "type": "decision_resolved",
            "tag": "fred",
            "request_id": "req-1",
            "resolution": "dismissed",
            // "choice_id" key entirely omitted — never sent as null.
        ]
        let msg = ServerMsg.decode(from: try jsonData(json))

        guard case let .decisionResolved(_, _, resolution, choiceId) = msg else {
            XCTFail("expected .decisionResolved, got \(msg)")
            return
        }
        XCTAssertEqual(resolution, "dismissed")
        XCTAssertNil(choiceId)
    }

    func testDecisionResolvedDecodesTimeoutWithoutChoiceId() throws {
        let json: [String: Any] = [
            "type": "decision_resolved",
            "tag": "fred",
            "request_id": "req-1",
            "resolution": "timeout",
        ]
        let msg = ServerMsg.decode(from: try jsonData(json))

        guard case let .decisionResolved(_, _, resolution, choiceId) = msg else {
            XCTFail("expected .decisionResolved, got \(msg)")
            return
        }
        XCTAssertEqual(resolution, "timeout")
        XCTAssertNil(choiceId)
    }

    func testDecisionResolvedDecodesCancelledWithoutChoiceId() throws {
        let json: [String: Any] = [
            "type": "decision_resolved",
            "tag": "fred",
            "request_id": "req-1",
            "resolution": "cancelled",
        ]
        let msg = ServerMsg.decode(from: try jsonData(json))

        guard case let .decisionResolved(_, _, resolution, choiceId) = msg else {
            XCTFail("expected .decisionResolved, got \(msg)")
            return
        }
        XCTAssertEqual(resolution, "cancelled")
        XCTAssertNil(choiceId)
    }

    // MARK: - ClientDecisionAnswer: exact wire shape with a real choice

    func testClientDecisionAnswerEncodesExactlyThreeKeysWithAChoice() throws {
        let msg = ClientDecisionAnswer(requestId: "r1", choiceId: "approve")
        let dict = try encode(msg)

        XCTAssertEqual(dict["type"] as? String, "decision_answer")
        XCTAssertEqual(dict["request_id"] as? String, "r1")
        XCTAssertEqual(dict["choice_id"] as? String, "approve")
        XCTAssertEqual(dict.keys.count, 3, "expected exactly type, request_id, choice_id")
    }

    // MARK: - ClientDecisionAnswer: nil choiceId encodes as present-but-null, never omitted

    func testClientDecisionAnswerWithNilChoiceIdEncodesPresentNullNotAbsent() throws {
        let msg = ClientDecisionAnswer(requestId: "r1", choiceId: nil)
        let dict = try encode(msg)

        XCTAssertEqual(dict["type"] as? String, "decision_answer")
        XCTAssertEqual(dict["request_id"] as? String, "r1")
        XCTAssertNotNil(dict["choice_id"], "choice_id key must be present in the payload even when nil")
        XCTAssertTrue(
            dict["choice_id"] is NSNull,
            "choice_id must encode as JSON null (dismissed without choosing), not be omitted — " +
            "JSONSerialization decodes a JSON null as NSNull, distinct from a missing key"
        )
    }

    // MARK: - source guard: DaemonStore must actually handle decision_request

    /// Ties iOS's claimed operator status (`renders_decisions: true`, flipped
    /// in `NetworkClient.sendHello()` by this same wedge — see
    /// `ClientMsgTests.testSendHelloExplicitlyPassesRendersDecisionsTrue`) to
    /// the real existence of a handler for the frame that status enables.
    /// Without this, the two claims could silently drift apart — e.g. a
    /// future refactor removing the `.decisionRequest` case while leaving
    /// `rendersDecisions: true` in place, quietly turning iOS back into a
    /// client that claims operator status but drops every decision on the
    /// floor. A plain literal-text check is the simplest thing that fails the
    /// instant that case disappears.
    func testDaemonStoreHandlesDecisionRequestCase() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let daemonStoreURL = testFile
            .deletingLastPathComponent() // .../Tests/NostromoKitTests/DecisionWireTests.swift -> .../Tests/NostromoKitTests/
            .deletingLastPathComponent() // -> .../Tests/
            .deletingLastPathComponent() // -> .../NostromoKit/ (package root)
            .appendingPathComponent("Sources/NostromoKit/Store/DaemonStore.swift")

        let source = try String(contentsOf: daemonStoreURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("case .decisionRequest"),
            "DaemonStore.handle(_:) must have a case for .decisionRequest — iOS claims " +
            "renders_decisions: true, so it must actually handle the frame that status enables."
        )
    }
}
