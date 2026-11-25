// NostromoKit — MergedQueueTests.swift
//
// The one merged list across Macs (Q8, PRD AC52/AC53, W11-20): "needs you" first, then newest; a
// Mac badge on every row exactly when rows come from more than one Mac; and a work host's rows built
// from the fixed phrases ONLY, so no title, question, branch, repository or session name can reach a
// row however the host's frame is shaped.

import XCTest
@testable import NostromoKit

final class MergedQueueTests: XCTestCase {

    // MARK: Helpers

    private func job(_ id: String, state: String = "running", title: String = "A title",
                     repo: String? = nil, branch: String? = nil, question: String? = nil,
                     createdAt: String? = nil, pausedReason: String? = nil,
                     activity: String? = nil) -> MotherJob {
        MotherJob(id: id, state: state, title: title, repo: repo, branch: branch, createdAt: createdAt,
                  question: question, crew: MotherCrewState(activity: activity), pausedReason: pausedReason)
    }

    private func session(_ tag: String, agent: String = "cody", view: String = "view",
                         state: SessionState = .idle) -> SessionInfo {
        SessionInfo(tag: tag, agentName: agent, viewName: view, sessionId: nil, alive: true,
                    remoteControl: false, state: state, stopReason: nil, mcpBridgeConnected: nil)
    }

    private func rows(primaryJobs: [MotherJob] = [], primarySessions: [SessionInfo] = [],
                      hostedJobs: [String: [MotherJob]] = [:], hostedSessions: [String: [SessionInfo]] = [:],
                      egress: [String: HostEgress] = [:]) -> [MergedQueueRow] {
        MergedQueue.rows(primaryJobs: primaryJobs, primarySessions: primarySessions, hostedJobs: hostedJobs,
                         hostedSessions: hostedSessions, egress: egress, primaryName: "Sendai")
    }

    private let ref = "20251124T101500Z-3f9a1c2e"

    // MARK: - Badges

    func testRowsFromTwoMacsAreAllBadged() {
        let result = rows(primaryJobs: [job("p1")], primarySessions: [session("cody-1")],
                          hostedJobs: ["kobe": [job("3f9a1c2e")]], egress: ["kobe": .personal])
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.hostBadge != nil }, "Every row is badged when two Macs are present")
        XCTAssertEqual(Set(result.compactMap(\.hostBadge)), ["Sendai", "kobe"])
        XCTAssertEqual(result.filter { $0.host == nil }.map(\.hostBadge), ["Sendai", "Sendai"])
    }

    func testRowsAreBadgedWhenOnlyLastKnownKobeRowsRemainBesideThePrimarysRows() {
        // Kobe is no longer connected, so `hosts` omits it; its last-known rows still count as a Mac.
        let result = rows(primaryJobs: [job("p1")], hostedJobs: ["kobe": [job("3f9a1c2e", state: "queued")]])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.hostBadge != nil })
    }

    func testRowsFromTheOnlyMacCarryNoBadge() {
        let primaryOnly = rows(primaryJobs: [job("p1")], primarySessions: [session("cody-1")])
        XCTAssertEqual(primaryOnly.count, 2)
        XCTAssertTrue(primaryOnly.allSatisfy { $0.hostBadge == nil })

        let kobeOnly = rows(hostedJobs: ["kobe": [job("3f9a1c2e")]], hostedSessions: ["kobe": [session("k1")]])
        XCTAssertEqual(kobeOnly.count, 2)
        XCTAssertTrue(kobeOnly.allSatisfy { $0.hostBadge == nil }, "One Mac, even a satellite, needs no badge")
    }

    func testAnEmptyQueueHasNoRows() {
        XCTAssertTrue(rows().isEmpty)
    }

    // MARK: - Order

    func testNeedsYouRowsComeFirstThenTheNewest() {
        let result = rows(primaryJobs: [
            job("old-running", createdAt: "2026-11-25T08:00:00Z"),
            job("new-running", createdAt: "2026-11-25T12:00:00Z"),
            job("mid-running", createdAt: "2026-11-25T10:00:00Z"),
            job("older-awaiting", state: "awaiting", createdAt: "2026-11-24T08:00:00Z"),
        ])
        XCTAssertEqual(result.map { $0.job?.id }, ["older-awaiting", "new-running", "mid-running", "old-running"])
        XCTAssertEqual(result.map(\.needsYou), [true, false, false, false])
    }

    func testAnAwaitingJobSortsBeforeANewerRunningOneAcrossMacs() {
        let result = rows(
            primaryJobs: [job("newer-running", createdAt: "2026-11-25T12:00:00Z")],
            hostedJobs: ["kobe": [job("3f9a1c2e", state: "awaiting", createdAt: "2026-11-24T08:00:00Z")]],
            egress: ["kobe": .personal])
        XCTAssertEqual(result.map(\.host), ["kobe", nil])
        XCTAssertTrue(result[0].needsYou)
    }

    func testRowsFromTwoMacsInterleaveByRecency() {
        let result = rows(
            primaryJobs: [job("p-old", createdAt: "2026-11-25T08:00:00Z"), job("p-new", createdAt: "2026-11-25T12:00:00Z")],
            hostedJobs: ["kobe": [job("k-mid", createdAt: "2026-11-25T10:00:00Z")]],
            egress: ["kobe": .personal])
        XCTAssertEqual(result.map { $0.job?.id }, ["p-new", "k-mid", "p-old"])
    }

    // MARK: - Work hosts are metadata only

    func testAWorkHostRowIsMetadataOnlyWithNoJobAndFixedPhrases() throws {
        let result = rows(hostedJobs: ["kobe": [
            job(ref, state: "awaiting", pausedReason: "user"),
            job("a1b2c3d4", state: "running"),
        ]], egress: ["kobe": .work])

        XCTAssertEqual(result.count, 2)
        for row in result {
            XCTAssertTrue(row.isMetadataOnly)
            XCTAssertNil(row.job, "A work host's row has no job to drill into")
        }
        let awaiting = try XCTUnwrap(result.first { $0.needsYou })
        XCTAssertEqual(awaiting.text, "Job 3f9a1c2e · asked a question")
        let running = try XCTUnwrap(result.first { !$0.needsYou })
        XCTAssertEqual(running.text, "Job a1b2c3d4 · running")
    }

    func testAHostWithNoEgressOnRecordIsTreatedAsAWorkHost() {
        let result = rows(hostedJobs: ["mystery": [job("a1b2c3d4", state: "running")]], egress: [:])
        XCTAssertTrue(result[0].isMetadataOnly, "Unknown means the strict reading")
        XCTAssertNil(result[0].job)
    }

    func testAWorkHostJobNeedingYouWithNoKnownReasonSaysNeedsYou() throws {
        let result = rows(hostedJobs: ["kobe": [job(ref, state: "awaiting")]], egress: ["kobe": .work])
        XCTAssertEqual(try XCTUnwrap(result.first).text, "Job 3f9a1c2e · needs you")
    }

    func testAWorkHostJobWithoutAValidRefSaysAJobAndNeverItsId() throws {
        let result = rows(hostedJobs: ["kobe": [job("fix-the-login-bug", state: "awaiting", pausedReason: "user")]],
                          egress: ["kobe": .work])
        XCTAssertEqual(try XCTUnwrap(result.first).text, "A job asked a question")
    }

    func testNoFreeTextFromAWorkHostReachesAnyRowField() {
        let markers = ["SECRET-TITLE", "SECRET-QUESTION", "SECRET-BRANCH", "secret/repo",
                       "SECRET-SESSION-NAME", "SECRET-AGENT"]
        let hostile = job(ref, state: "awaiting", title: "SECRET-TITLE", repo: "secret/repo",
                          branch: "SECRET-BRANCH", question: "SECRET-QUESTION", pausedReason: "user")
        let running = job("a1b2c3d4", state: "running", title: "SECRET-TITLE", repo: "secret/repo",
                          branch: "SECRET-BRANCH", question: "SECRET-QUESTION")
        let result = rows(
            primaryJobs: [job("p1")],   // a second Mac, so a badge is shown too
            hostedJobs: ["kobe": [hostile, running]],
            hostedSessions: ["kobe": [session("kobe-1", agent: "SECRET-AGENT", view: "SECRET-SESSION-NAME"),
                                      session("kobe-2", agent: "perri", view: "SECRET-SESSION-NAME", state: .midTurn)]],
            egress: ["kobe": .work])

        let kobeRows = result.filter { $0.host == "kobe" }
        XCTAssertEqual(kobeRows.count, 4)
        for row in kobeRows {
            XCTAssertTrue(row.isMetadataOnly)
            XCTAssertNil(row.job)
            XCTAssertNil(row.session)
            let everything = [row.text, row.id, row.hostBadge ?? "", String(describing: row),
                              String(reflecting: row)].joined(separator: "\n")
            for marker in markers {
                XCTAssertFalse(everything.contains(marker), "\(marker) reached a work host's row: \(row.text)")
            }
        }
        XCTAssertEqual(kobeRows.filter { $0.kind == .session }.map(\.text).sorted(),
                       ["A session · idle", "Perri · mid_turn"])
    }

    func testASessionTagFromAWorkHostDoesNotReachTheRowIdentifier() {
        // The tag is the host's name for a focus. The row id must not carry it for a metadata-only row.
        let result = rows(hostedSessions: ["kobe": [session("SECRET-SESSION-NAME")]], egress: ["kobe": .work])
        let row = result[0]
        XCTAssertTrue(row.isMetadataOnly)
        XCTAssertFalse(row.id.contains("SECRET-SESSION-NAME"), "row id: \(row.id)")
        XCTAssertFalse(String(describing: row).contains("SECRET-SESSION-NAME"))
    }

    // MARK: - Personal hosts show their content

    func testAPersonalHostRowShowsTheTitleAndKeepsTheJob() throws {
        let result = rows(hostedJobs: ["studio": [job("job-1", title: "Refactor the parser")]],
                          hostedSessions: ["studio": [session("studio-1", agent: "cody")]],
                          egress: ["studio": .personal])
        let jobRow = try XCTUnwrap(result.first { $0.kind == .job })
        XCTAssertFalse(jobRow.isMetadataOnly)
        XCTAssertEqual(jobRow.text, "Refactor the parser")
        XCTAssertEqual(jobRow.job?.id, "job-1")
        let sessionRow = try XCTUnwrap(result.first { $0.kind == .session })
        XCTAssertFalse(sessionRow.isMetadataOnly)
        XCTAssertEqual(sessionRow.session?.tag, "studio-1")
    }

    func testThePrimarysRowsShowTheirContent() throws {
        let result = rows(primaryJobs: [job("p1", title: "Primary title")])
        XCTAssertFalse(result[0].isMetadataOnly)
        XCTAssertEqual(result[0].text, "Primary title")
        XCTAssertEqual(result[0].job?.id, "p1")
    }

    // MARK: - Identifiers

    func testRowIdentifiersAreHostKindAndIdSoEqualIdsOnTwoHostsBothAppear() {
        let result = rows(
            primaryJobs: [job("same")],
            hostedJobs: ["kobe": [job("same")], "studio": [job("same")]],
            egress: ["kobe": .personal, "studio": .personal])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set(result.map(\.id)).count, 3, "ids are unique")
        XCTAssertTrue(result.map(\.id).contains("kobe|job|same"))
        XCTAssertTrue(result.map(\.id).contains("studio|job|same"))
        XCTAssertTrue(result.map(\.id).contains("|job|same"), "The primary's host part is empty")
    }

    func testAJobAndASessionWithTheSameNameOnOneHostDoNotCollide() {
        let result = rows(primaryJobs: [job("x")], primarySessions: [session("x")])
        XCTAssertEqual(Set(result.map(\.id)), ["|job|x", "|session|x"])
    }
}
