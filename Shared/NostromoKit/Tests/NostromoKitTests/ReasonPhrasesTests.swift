// NostromoKit — ReasonPhrasesTests.swift
//
// The fixed phrases a work host's row may show (W11-20, Q8, PRD AC53). They are the same words the
// lock-screen push uses: the tables here must equal `tests/fixtures/push-vocab/reason_phrases.json`
// exactly, and the Rust side asserts the same file, so the app and the lock screen cannot drift.

import XCTest
@testable import NostromoKit

final class ReasonPhrasesTests: XCTestCase {

    // MARK: Fixture

    /// `<repo>/tests/fixtures/push-vocab/reason_phrases.json`, found from this file's path
    /// (`<repo>/Shared/NostromoKit/Tests/NostromoKitTests/ReasonPhrasesTests.swift`).
    private func fixture() throws -> [String: Any] {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/push-vocab/reason_phrases.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "fixture not found at \(url.path)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - The tables equal the shared fixture

    func testThePausedReasonTableEqualsTheFixture() throws {
        let expected = try XCTUnwrap(fixture()["mother_paused_reason"] as? [String: String])
        XCTAssertEqual(ReasonPhrases.pausedReason, expected)
    }

    func testTheActivityTableEqualsTheFixture() throws {
        let expected = try XCTUnwrap(fixture()["mother_activity"] as? [String: String])
        XCTAssertEqual(ReasonPhrases.activity, expected)
    }

    func testTheDefaultReasonEqualsTheFixture() throws {
        XCTAssertEqual(ReasonPhrases.defaultReason, try XCTUnwrap(fixture()["mother_reason_default"] as? String))
    }

    func testTheAgentTableAndFallbackEqualTheFixture() throws {
        let fixture = try fixture()
        XCTAssertEqual(ReasonPhrases.agents, try XCTUnwrap(fixture["agent_class"] as? [String: String]))
        XCTAssertEqual(ReasonPhrases.agentFallback, try XCTUnwrap(fixture["agent_fallback"] as? String))
    }

    func testTheFixtureHoldsNothingTheTablesDoNotCover() throws {
        let keys = Set(try fixture().keys).subtracting(["_comment"])
        XCTAssertEqual(keys, ["mother_reason_default", "mother_paused_reason", "mother_activity",
                              "agent_class", "agent_fallback"],
                       "A new fixture section needs a table (and a test) here")
    }

    // MARK: - reason()

    func testThePausedReasonComesFirst() {
        XCTAssertEqual(ReasonPhrases.reason(pausedReason: "user", activity: "pipeline_blocked"), "asked a question")
        XCTAssertEqual(ReasonPhrases.reason(pausedReason: "cost_cap", activity: nil), "paused at its spend cap")
    }

    func testTheActivityIsUsedWhenThePausedReasonIsAbsentOrUnknown() {
        XCTAssertEqual(ReasonPhrases.reason(pausedReason: nil, activity: "pipeline_blocked"), "pipeline blocked")
        XCTAssertEqual(ReasonPhrases.reason(pausedReason: "something_new", activity: "pipeline_blocked"),
                       "pipeline blocked")
    }

    func testAnythingUnknownIsTheDefault() {
        XCTAssertEqual(ReasonPhrases.reason(pausedReason: nil, activity: nil), "needs you")
        XCTAssertEqual(ReasonPhrases.reason(pausedReason: "something_new", activity: "something_else"), "needs you")
    }

    // MARK: - jobRef

    func testAJobRefIsTheEightHexSuffixAfterTheLastDash() {
        XCTAssertEqual(ReasonPhrases.jobRef("20251124T101500Z-3f9a1c2e"), "3f9a1c2e")
    }

    func testAJobRefIsRefusedWhenItIsNotExactlyEightLowercaseHex() {
        XCTAssertNil(ReasonPhrases.jobRef("20251124T101500Z-3f9a1c2"), "7 hex characters")
        XCTAssertNil(ReasonPhrases.jobRef("20251124T101500Z-3f9a1c2e0"), "9 hex characters")
        XCTAssertNil(ReasonPhrases.jobRef("20251124T101500Z-3F9A1C2E"), "uppercase")
        XCTAssertNil(ReasonPhrases.jobRef("20251124T101500Z-3f9a1c2g"), "a non-hex character")
        XCTAssertNil(ReasonPhrases.jobRef("20251124T101500Z-"), "an empty suffix")
        XCTAssertNil(ReasonPhrases.jobRef(""))
    }

    func testAnIdWithNoDashBetweenTheTimestampAndTheSuffixHasNoRef() {
        XCTAssertNil(ReasonPhrases.jobRef("20251124T101500Z3f9a1c2e"))
        XCTAssertNil(ReasonPhrases.jobRef("fix-the-login-bug"), "free text must never be taken for a ref")
    }

    func testABareEightHexIdIsItsOwnRef() {
        // What a work host publishes: the primary has already reduced its job ids to a short ref.
        XCTAssertEqual(ReasonPhrases.jobRef("3f9a1c2e"), "3f9a1c2e")
    }

    // MARK: - Lines

    func testAJobLineNamesTheRefAndTheStatus() {
        XCTAssertEqual(ReasonPhrases.jobLine(id: "20251124T101500Z-3f9a1c2e", status: "asked a question"),
                       "Job 3f9a1c2e · asked a question")
        XCTAssertEqual(ReasonPhrases.jobLine(id: "20251124T101500Z-3f9a1c2e", status: "running"),
                       "Job 3f9a1c2e · running")
    }

    func testAJobLineWithoutARefSaysAJobAndNeverTheId() {
        let line = ReasonPhrases.jobLine(id: "fix-the-login-bug", status: ReasonPhrases.defaultReason)
        XCTAssertEqual(line, "A job needs you")
        XCTAssertFalse(line.contains("login"))
    }

    func testAPRLineHasTheNumberTheSizeAndTheWaitingCount() {
        XCTAssertEqual(ReasonPhrases.prLine(number: 4821, sizeChangedLines: 12, waiting: 3),
                       "PR #4821 · small change · 3 waiting")
    }

    func testThePRSizeBoundaries() {
        func size(_ lines: Int) -> String { ReasonPhrases.prLine(number: 1, sizeChangedLines: lines, waiting: 0) }
        XCTAssertEqual(size(49), "PR #1 · small change · 0 waiting")
        XCTAssertEqual(size(50), "PR #1 · medium change · 0 waiting")
        XCTAssertEqual(size(400), "PR #1 · medium change · 0 waiting")
        XCTAssertEqual(size(401), "PR #1 · large change · 0 waiting")
    }

    func testAPRLineHasNoSizePhraseWhenTheSizeIsUnknown() {
        XCTAssertEqual(ReasonPhrases.prLine(number: 7, sizeChangedLines: nil, waiting: 2), "PR #7 · 2 waiting")
    }

    func testASessionLineUsesTheFixedAgentSetElseASession() {
        XCTAssertEqual(ReasonPhrases.sessionLine(agentName: "perri", state: "running"), "Perri · running")
        XCTAssertEqual(ReasonPhrases.sessionLine(agentName: "mother", state: "idle"), "Mother · idle")
        XCTAssertEqual(ReasonPhrases.sessionLine(agentName: "cody", state: "idle"), "A session · idle",
                       "An agent outside the fixed set is not named")
        XCTAssertEqual(ReasonPhrases.sessionLine(agentName: nil, state: "idle"), "A session · idle")
    }

    func testDetailsStayOnTheHost() {
        XCTAssertEqual(ReasonPhrases.detailsStayOn("kobe"), "Details stay on kobe.")
    }
}
