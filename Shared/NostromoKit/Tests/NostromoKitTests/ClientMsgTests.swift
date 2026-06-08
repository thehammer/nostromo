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
}
