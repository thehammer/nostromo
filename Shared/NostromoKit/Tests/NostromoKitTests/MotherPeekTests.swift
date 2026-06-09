// NostromoKit — MotherPeekTests.swift
//
// Decode/encode assertions for MotherPeekSnapshot and the mother_peek ServerMsg.
// Mirrors the Rust round-trip tests in src/ipc/protocol.rs tests module.

import XCTest
@testable import NostromoKit

final class MotherPeekTests: XCTestCase {

    // MARK: - MotherPeekSnapshot decoding

    func testDecodesAllThreeTodoStatuses() throws {
        let json = """
        {
            "type": "mother_peek",
            "job_id": "job-abc123",
            "todos": [
                {"status": "completed",   "content": "Add Rust protocol variant"},
                {"status": "in_progress", "content": "Add NostromoKit wire types"},
                {"status": "pending",     "content": "Add iOS tab"}
            ],
            "tool_trail": [
                {"tool": "Read",  "brief": "src/ipc/protocol.rs"},
                {"tool": "Edit",  "brief": "add MotherPeek variant"}
            ],
            "last_text": "Implementing the MotherPeek broadcast"
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder().decode(MotherPeekSnapshot.self, from: json)
        XCTAssertEqual(snap.jobId,  "job-abc123")
        XCTAssertEqual(snap.todos.count, 3)
        XCTAssertEqual(snap.todos[0].status,  "completed")
        XCTAssertEqual(snap.todos[0].content, "Add Rust protocol variant")
        XCTAssertEqual(snap.todos[1].status,  "in_progress")
        XCTAssertEqual(snap.todos[1].content, "Add NostromoKit wire types")
        XCTAssertEqual(snap.todos[2].status,  "pending")
        XCTAssertEqual(snap.todos[2].content, "Add iOS tab")
        XCTAssertEqual(snap.toolTrail.count, 2)
        XCTAssertEqual(snap.toolTrail[0].tool,  "Read")
        XCTAssertEqual(snap.toolTrail[0].brief, "src/ipc/protocol.rs")
        XCTAssertEqual(snap.lastText, "Implementing the MotherPeek broadcast")
    }

    func testDecodesEmptyTodosArray() throws {
        let json = """
        {
            "type": "mother_peek",
            "job_id": "job-terminal",
            "todos": [],
            "tool_trail": [],
            "last_text": ""
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder().decode(MotherPeekSnapshot.self, from: json)
        XCTAssertEqual(snap.jobId,  "job-terminal")
        XCTAssertTrue(snap.todos.isEmpty)
        XCTAssertTrue(snap.toolTrail.isEmpty)
        XCTAssertEqual(snap.lastText, "")
    }

    // MARK: - MotherPeekSnapshot encoding (snake_case keys)

    func testEncodesWithSnakeCaseKeys() throws {
        let snap = MotherPeekSnapshot(
            jobId:     "job-encode",
            todos:     [PeekTodo(status: "pending", content: "Do something")],
            toolTrail: [PeekToolCall(tool: "Bash", brief: "cargo test")],
            lastText:  "testing"
        )
        let data = try JSONEncoder().encode(snap)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(dict["job_id"],     "expected snake_case key 'job_id'")
        XCTAssertNotNil(dict["tool_trail"], "expected snake_case key 'tool_trail'")
        XCTAssertNotNil(dict["last_text"],  "expected snake_case key 'last_text'")
        XCTAssertNil(dict["jobId"],         "camelCase key 'jobId' must NOT be present")

        XCTAssertEqual(dict["job_id"] as? String, "job-encode")
    }

    // MARK: - ServerMsg.decode round-trip

    func testServerMsgDecodesMotherPeek() throws {
        let json = """
        {
            "type": "mother_peek",
            "job_id": "job-srv",
            "todos": [
                {"status": "in_progress", "content": "Implement feature"}
            ],
            "tool_trail": [],
            "last_text": "working on it"
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .motherPeek(let snap) = msg else {
            XCTFail("Expected .motherPeek, got \(msg)")
            return
        }
        XCTAssertEqual(snap.jobId,           "job-srv")
        XCTAssertEqual(snap.todos.count,     1)
        XCTAssertEqual(snap.todos[0].status, "in_progress")
        XCTAssertEqual(snap.lastText,        "working on it")
    }

    func testServerMsgDecodesMotherPeekTerminalClear() throws {
        let json = """
        {
            "type": "mother_peek",
            "job_id": "job-done",
            "todos": [],
            "tool_trail": [],
            "last_text": ""
        }
        """.data(using: .utf8)!

        let msg = ServerMsg.decode(from: json)
        guard case .motherPeek(let snap) = msg else {
            XCTFail("Expected .motherPeek, got \(msg)")
            return
        }
        XCTAssertTrue(snap.todos.isEmpty, "Terminal clear should have empty todos")
    }
}
