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
