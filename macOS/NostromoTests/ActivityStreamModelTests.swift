import XCTest

/// `ActivityStreamModel` is compiled into this target directly (logic test —
/// pure `Foundation`, no AppKit/SwiftUI/Combine, no host app needed). It
/// assembles a focus's raw per-agent activity streams into what the ticker
/// (`ActivityTickerView`, see `ActivityTickerWiringTests`) needs to render.
///
/// NOTE — RED phase: `ActivityStreamModel`'s method/property bodies are
/// `fatalError` stubs today. Every test below is expected to crash the test
/// process at the first stubbed call it reaches, not report a clean
/// per-test failure — that crash *is* "fails because the behaviour doesn't
/// exist yet" for a value type with no seam to inject a fake through. Cody
/// replaces the stub bodies; these tests then pass or fail normally.
final class ActivityStreamModelTests: XCTestCase {

    // MARK: - Event factory

    private var nextSeq: UInt64 = 1

    private func makeEvent(
        agent: String = "perri",
        kind: String = "tool_use",
        summary: String = "reading a file",
        agentId: String? = nil,
        agentType: String? = nil,
        parentAgentId: String? = nil,
        seq: UInt64? = nil,
        ts: Date = Date()
    ) -> ActivityEvent {
        ActivityEvent(
            ts: ts, agent: agent, kind: kind, summary: summary,
            focusTag: nil, sessionId: nil,
            agentId: agentId, agentType: agentType, parentAgentId: parentAgentId,
            toolName: nil, toolUseId: nil, cwd: nil, seq: seq)
    }

    // MARK: - Stream assembly / subagent nesting

    func testMainStreamIsNilBeforeAnyEventsArrive() {
        let model = ActivityStreamModel()
        XCTAssertNil(model.mainStream)
    }

    func testMainStreamAccumulatesEventsWithNilAgentId() throws {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(summary: "first", agentId: nil))
        model.ingest(makeEvent(summary: "second", agentId: nil))

        let main = try XCTUnwrap(model.mainStream)
        XCTAssertNil(main.agentId)
        XCTAssertEqual(main.events.map(\.summary), ["first", "second"])
    }

    func testSubagentStreamIsCreatedOnFirstEventForANewAgentId() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(kind: "subagent_start", agentId: "sub-1",
                                agentType: "reviewer", parentAgentId: "main"))

        XCTAssertEqual(model.subagentStreams.count, 1)
        let sub = try? XCTUnwrap(model.subagentStreams.first)
        XCTAssertEqual(sub?.agentId, "sub-1")
        XCTAssertEqual(sub?.agentType, "reviewer")
        XCTAssertEqual(sub?.parentAgentId, "main")
    }

    func testRunningSubagentCountExcludesStreamsThatHaveSeenASubagentStop() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(kind: "subagent_start", agentId: "sub-1"))
        model.ingest(makeEvent(kind: "subagent_start", agentId: "sub-2"))
        XCTAssertEqual(model.runningSubagentCount, 2)

        model.ingest(makeEvent(kind: "subagent_stop", agentId: "sub-1"))
        XCTAssertEqual(model.runningSubagentCount, 1,
                        "sub-1 finished; only sub-2 is still running")
    }

    // MARK: - Ticker one-line summary

    func testTickerSummaryIsANeutralWaitingStateWhenNoEventsHaveArrivedYet() {
        let model = ActivityStreamModel()
        let summary = model.tickerSummary
        XCTAssertFalse(summary.isEmpty)
        XCTAssertFalse(summary.lowercased().contains("not receiving"),
                        "an empty stream is 'nothing yet', not 'the pipe is broken' — those are different states")
    }

    func testWaitingStateTextDiffersFromNotIngestingHealthText() {
        let model = ActivityStreamModel()
        let waiting = model.tickerSummary
        let broken = ActivityStreamModel.healthText(
            for: ActivityHealthState(ingesting: false, reason: nil, hookInstalled: true))

        XCTAssertNotEqual(waiting, broken,
                           "callers must be able to tell 'no events yet' apart from 'the pipe is broken'")
    }

    func testTickerSummaryShowsTheMostRecentMainStreamEventWhenNoSubagentsAreRunning() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(agent: "perri", summary: "reading a file"))
        model.ingest(makeEvent(agent: "perri", summary: "running tests"))

        let summary = model.tickerSummary
        XCTAssertTrue(summary.contains("perri"))
        XCTAssertTrue(summary.contains("running tests"),
                       "the most recent event's summary, not an earlier one")
        XCTAssertFalse(summary.contains("reading a file"))
    }

    func testTickerSummaryTruncatesSummariesOver40CharsTo37PlusEllipsis() {
        // 50 chars, well past the 40-char cutoff.
        let longSummary = String(repeating: "x", count: 50)
        var model = ActivityStreamModel()
        model.ingest(makeEvent(summary: longSummary))

        let expectedTruncated = String(longSummary.prefix(37)) + "…"
        XCTAssertTrue(model.tickerSummary.contains(expectedTruncated),
                       "summaries over 40 chars must be cut to 37 + an ellipsis, mirroring the removed StatusBarView rule")
        XCTAssertFalse(model.tickerSummary.contains(longSummary),
                        "the untruncated summary must not appear")
    }

    func testTickerSummaryDoesNotTruncateSummariesAt40CharsOrShorter() {
        let shortSummary = String(repeating: "y", count: 40)
        var model = ActivityStreamModel()
        model.ingest(makeEvent(summary: shortSummary))

        XCTAssertTrue(model.tickerSummary.contains(shortSummary),
                       "exactly 40 chars is the boundary and must not be truncated")
    }

    func testTickerSummaryNamesTheAgentAndRunningCountWhenSubagentsAreRunning() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(agent: "perri", summary: "reviewing"))
        model.ingest(makeEvent(agent: "perri", kind: "subagent_start", agentId: "sub-1"))
        model.ingest(makeEvent(agent: "perri", kind: "subagent_start", agentId: "sub-2"))

        let summary = model.tickerSummary
        XCTAssertTrue(summary.contains("perri"), "must name the base agent")
        XCTAssertTrue(summary.contains("2"), "must surface the running count")
    }

    // MARK: - Health-to-text mapping

    func testHealthTextNamesTheHookInstallFixWhenHookIsNotInstalled() {
        let text = ActivityStreamModel.healthText(
            for: ActivityHealthState(ingesting: false, reason: nil, hookInstalled: false))
        let lower = text.lowercased()
        XCTAssertTrue(lower.contains("doctor") || lower.contains("install"),
                      "must name a concrete fix: installing the hook or `nostromo doctor`")
    }

    func testHealthTextNamesADifferentFixWhenHookIsInstalledButNothingHasArrived() {
        let text = ActivityStreamModel.healthText(
            for: ActivityHealthState(ingesting: false, reason: nil, hookInstalled: true))
        let lower = text.lowercased()
        XCTAssertFalse(lower.contains("doctor") || lower.contains("install"),
                       "the hook-is-installed case is a different problem and must not repeat the install fix")
    }

    func testTheTwoNotIngestingMessagesAreNotEqual() {
        let notInstalled = ActivityStreamModel.healthText(
            for: ActivityHealthState(ingesting: false, reason: nil, hookInstalled: false))
        let installedButSilent = ActivityStreamModel.healthText(
            for: ActivityHealthState(ingesting: false, reason: nil, hookInstalled: true))

        XCTAssertNotEqual(notInstalled, installedButSilent,
                           "these are different problems and must not collapse to the same operator-facing text")
    }

    func testHealthTextPlainlyStatesEventsAreNotArrivingRegardlessOfHookState() {
        for hookInstalled in [true, false] {
            let text = ActivityStreamModel.healthText(
                for: ActivityHealthState(ingesting: false, reason: nil, hookInstalled: hookInstalled))
            let lower = text.lowercased()
            XCTAssertTrue(
                lower.contains("not") || lower.contains("no event") || lower.contains("stopped"),
                "health text (hookInstalled=\(hookInstalled)) must plainly say events aren't arriving: \(text)")
        }
    }

    func testDisplayTextAlwaysShowsHealthTextWhenNotIngestingEvenWithCachedLastEventText() {
        var model = ActivityStreamModel()
        // A cached, perfectly good-looking last event — this must never leak
        // through once health says the pipe is down. Silently showing a
        // stale event during an outage is the exact bug this test guards.
        model.ingest(makeEvent(agent: "perri", summary: "everything is fine"))

        let health = ActivityHealthState(ingesting: false, reason: "socket closed", hookInstalled: true)
        let shown = model.displayText(health: health)
        let expectedHealthText = ActivityStreamModel.healthText(for: health)

        XCTAssertEqual(shown, expectedHealthText)
        XCTAssertFalse(shown.contains("everything is fine"),
                        "a cached last event must never be shown while health reports not-ingesting")
    }

    func testDisplayTextFallsBackToTickerSummaryWhenIngesting() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(agent: "perri", summary: "reading a file"))

        let health = ActivityHealthState(ingesting: true, reason: nil, hookInstalled: true)
        XCTAssertEqual(model.displayText(health: health), model.tickerSummary)
    }

    // MARK: - Gap detection via seq

    func testNoGapDetectedForConsecutiveSeqValues() {
        var model = ActivityStreamModel()
        XCTAssertFalse(model.ingest(makeEvent(seq: 1)))
        XCTAssertFalse(model.ingest(makeEvent(seq: 2)))
        XCTAssertFalse(model.ingest(makeEvent(seq: 3)))
    }

    func testGapIsDetectedExactlyOnTheSkippedSeq() {
        var model = ActivityStreamModel()
        XCTAssertFalse(model.ingest(makeEvent(seq: 1)))
        XCTAssertFalse(model.ingest(makeEvent(seq: 2)))
        XCTAssertTrue(model.ingest(makeEvent(seq: 5)),
                       "seq jumped from 2 to 5 — a gap must be reported on the event carrying seq 5")
    }

    func testMissingSeqNeverTriggersGapDetection() {
        var model = ActivityStreamModel()
        XCTAssertFalse(model.ingest(makeEvent(seq: 1)))
        XCTAssertFalse(model.ingest(makeEvent(seq: nil)),
                        "an event with no seq (old daemon build) must never be flagged as a gap")
        XCTAssertFalse(model.ingest(makeEvent(seq: 3)),
                        "resuming with seq present after a nil-seq event must not itself be treated as a gap")
    }

    func testFirstEventIntoAnEmptyStreamIsNeverAGapRegardlessOfItsSeqValue() {
        var model = ActivityStreamModel()
        XCTAssertFalse(model.ingest(makeEvent(seq: 999)),
                        "nothing to compare the very first event's seq against")
    }

    func testGapDetectionIsPerStreamNotGlobal() {
        // Main stream and a subagent stream each keep their own seq lineage;
        // an in-order subagent stream must not be flagged just because the
        // main stream's seq counter is somewhere else entirely.
        var model = ActivityStreamModel()
        XCTAssertFalse(model.ingest(makeEvent(agentId: nil, seq: 100)))
        XCTAssertFalse(model.ingest(makeEvent(kind: "subagent_start", agentId: "sub-1", seq: 1)))
        XCTAssertFalse(model.ingest(makeEvent(agentId: "sub-1", seq: 2)))
        XCTAssertFalse(model.ingest(makeEvent(agentId: nil, seq: 101)))
    }

    // MARK: - Two concurrent subagents stay disjoint

    func testTwoConcurrentSubagentsEndUpInSeparateStreams() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(kind: "subagent_start", summary: "A starts", agentId: "agent-a"))
        model.ingest(makeEvent(kind: "subagent_start", summary: "B starts", agentId: "agent-b"))
        model.ingest(makeEvent(summary: "A works", agentId: "agent-a"))
        model.ingest(makeEvent(summary: "B works", agentId: "agent-b"))

        XCTAssertEqual(model.subagentStreams.count, 2)
        let streamA = model.subagentStreams.first { $0.agentId == "agent-a" }
        let streamB = model.subagentStreams.first { $0.agentId == "agent-b" }

        XCTAssertEqual(streamA?.events.map(\.summary), ["A starts", "A works"])
        XCTAssertEqual(streamB?.events.map(\.summary), ["B starts", "B works"])
    }

    func testEventsForOneSubagentNeverAppearInAnotherSubagentsStreamOrTheMainStream() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(summary: "main event", agentId: nil))
        model.ingest(makeEvent(kind: "subagent_start", summary: "A only", agentId: "agent-a"))
        model.ingest(makeEvent(kind: "subagent_start", summary: "B only", agentId: "agent-b"))

        let streamA = model.subagentStreams.first { $0.agentId == "agent-a" }
        let streamB = model.subagentStreams.first { $0.agentId == "agent-b" }
        let main = model.mainStream

        XCTAssertEqual(streamA?.events.map(\.summary), ["A only"])
        XCTAssertEqual(streamB?.events.map(\.summary), ["B only"])
        XCTAssertEqual(main?.events.map(\.summary), ["main event"])
    }

    func testRunningSubagentCountReflectsExactlyTheUnfinishedOnesAmongTwoConcurrentSubagents() {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(kind: "subagent_start", agentId: "agent-a"))
        model.ingest(makeEvent(kind: "subagent_start", agentId: "agent-b"))
        model.ingest(makeEvent(kind: "subagent_stop", agentId: "agent-b"))

        XCTAssertEqual(model.runningSubagentCount, 1)
        XCTAssertEqual(model.subagentStreams.first { $0.agentId == "agent-a" }?.finished, false)
        XCTAssertEqual(model.subagentStreams.first { $0.agentId == "agent-b" }?.finished, true)
    }
}
