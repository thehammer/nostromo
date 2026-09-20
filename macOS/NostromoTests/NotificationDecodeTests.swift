import XCTest

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
