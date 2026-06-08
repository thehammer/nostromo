// NostromoKit — MotherWireTests.swift
//
// Wire JSON assertions for Mother job types.
// Verifies ClientMotherAction encoding and MotherJob/ServerMsg decoding
// match the Rust daemon's expected protocol format.

import XCTest
@testable import NostromoKit

final class MotherWireTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - ClientMotherAction encoding

    func testMotherActionCancelEncoding() throws {
        let msg = ClientMotherAction(jobId: "job-1", action: "cancel")
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"]   as? String, "mother_action")
        XCTAssertEqual(dict["job_id"] as? String, "job-1")
        XCTAssertEqual(dict["action"] as? String, "cancel")
    }

    func testMotherActionForceStartEncoding() throws {
        let msg = ClientMotherAction(jobId: "job-2", action: "force_start")
        let dict = try encode(msg)
        XCTAssertEqual(dict["type"]   as? String, "mother_action")
        XCTAssertEqual(dict["job_id"] as? String, "job-2")
        XCTAssertEqual(dict["action"] as? String, "force_start")
    }

    func testMotherActionHasExactlyThreeKeys() throws {
        let msg = ClientMotherAction(jobId: "job-3", action: "retry")
        let dict = try encode(msg)
        XCTAssertEqual(dict.keys.count, 3, "Expected exactly type, job_id, action")
    }

    // MARK: - MotherJob decoding

    func testMotherJobDecodesFromSampleJSON() throws {
        let json = """
        {
            "id": "abc123",
            "state": "running",
            "title": "Build the auth flow",
            "repo": "admin-portal",
            "branch": "feature/auth",
            "pr_url": "https://github.com/org/repo/pull/42",
            "created_at": "2026-06-01T10:00:00Z",
            "started_at": "2026-06-01T10:01:00Z",
            "finished_at": null
        }
        """.data(using: .utf8)!
        let job = try JSONDecoder().decode(MotherJob.self, from: json)
        XCTAssertEqual(job.id,     "abc123")
        XCTAssertEqual(job.state,  "running")
        XCTAssertEqual(job.title,  "Build the auth flow")
        XCTAssertEqual(job.repo,   "admin-portal")
        XCTAssertEqual(job.branch, "feature/auth")
        XCTAssertEqual(job.prUrl,  "https://github.com/org/repo/pull/42")
        XCTAssertNotNil(job.createdAt)
        XCTAssertNotNil(job.startedAt)
        XCTAssertNil(job.finishedAt)
    }

    func testMotherJobDecodesWithExtraUnknownFields() throws {
        let json = """
        {
            "id": "xyz",
            "state": "queued",
            "title": "Refactor payment flow",
            "repo": "billing",
            "branch": "feature/payments",
            "base_ref": "main",
            "isolation": "worktree",
            "worker_pid": 12345
        }
        """.data(using: .utf8)!
        let job = try JSONDecoder().decode(MotherJob.self, from: json)
        XCTAssertEqual(job.id,     "xyz")
        XCTAssertEqual(job.state,  "queued")
        XCTAssertEqual(job.title,  "Refactor payment flow")
        XCTAssertEqual(job.repo,   "billing")
        XCTAssertEqual(job.branch, "feature/payments")
    }

    func testMotherJobDecodesWithMissingOptionalFields() throws {
        let json = """
        {
            "id": "min",
            "state": "queued",
            "title": "Minimal job"
        }
        """.data(using: .utf8)!
        let job = try JSONDecoder().decode(MotherJob.self, from: json)
        XCTAssertEqual(job.id,    "min")
        XCTAssertEqual(job.state, "queued")
        XCTAssertNil(job.repo)
        XCTAssertNil(job.branch)
        XCTAssertNil(job.prUrl)
        XCTAssertNil(job.createdAt)
        XCTAssertNil(job.startedAt)
        XCTAssertNil(job.finishedAt)
    }

    // MARK: - ServerMsg.motherJobs decoding

    func testServerMsgDecodesMotherJobs() throws {
        let json = """
        {
            "type": "mother_jobs",
            "jobs": [
                {"id": "a", "state": "running", "title": "t"}
            ]
        }
        """.data(using: .utf8)!
        let msg = ServerMsg.decode(from: json)
        guard case .motherJobs(let jobs) = msg else {
            XCTFail("Expected .motherJobs, got \(msg)")
            return
        }
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].id,    "a")
        XCTAssertEqual(jobs[0].state, "running")
        XCTAssertEqual(jobs[0].title, "t")
    }
}
