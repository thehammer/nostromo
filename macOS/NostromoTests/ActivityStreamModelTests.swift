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

    // MARK: - Bounded retention: per-stream cap
    //
    // src/activity/store.rs's ActivityStore enforces MAX_EVENTS_PER_STREAM /
    // MAX_TOTAL_EVENTS; ActivityStreamModel must mirror the same shape on the
    // client so a daemon snapshot (which is already bounded) never grows the
    // client's in-memory model beyond what the daemon itself would retain.

    func testMainStreamCapsAtMaxEventsPerStreamKeepingTheMostRecentEvents() throws {
        var model = ActivityStreamModel()
        let overshoot = ActivityStreamModel.maxEventsPerStream + 50
        for i in 0..<overshoot {
            model.ingest(makeEvent(summary: "event-\(i)", agentId: nil))
        }

        let main = try XCTUnwrap(model.mainStream)
        XCTAssertEqual(main.events.count, ActivityStreamModel.maxEventsPerStream)
        let expectedSummaries = (50..<overshoot).map { "event-\($0)" }
        XCTAssertEqual(main.events.map(\.summary), expectedSummaries,
                        "must keep exactly the most recent maxEventsPerStream events, in original order")
    }

    func testSubagentStreamCapsAtMaxEventsPerStreamKeepingTheMostRecentEvents() throws {
        var model = ActivityStreamModel()
        let overshoot = ActivityStreamModel.maxEventsPerStream + 50
        for i in 0..<overshoot {
            model.ingest(makeEvent(kind: i == 0 ? "subagent_start" : "tool_use",
                                    summary: "sub-event-\(i)",
                                    agentId: "sub-1"))
        }

        let sub = try XCTUnwrap(model.subagentStreams.first { $0.agentId == "sub-1" })
        XCTAssertEqual(sub.events.count, ActivityStreamModel.maxEventsPerStream)
        let expectedSummaries = (50..<overshoot).map { "sub-event-\($0)" }
        XCTAssertEqual(sub.events.map(\.summary), expectedSummaries,
                        "must keep exactly the most recent maxEventsPerStream events, in original order")
    }

    // MARK: - Bounded retention: total budget across streams

    func testTotalEventCountStaysWithinMaxTotalEventsAcrossManyFinishedSubagentStreams() {
        var model = ActivityStreamModel()
        let streamCount = 30
        let eventsPerStream = 100 // 30 * 100 = 3000, comfortably over both the per-stream and total caps
        for s in 0..<streamCount {
            let agentId = "fanout-\(s)"
            for e in 0..<eventsPerStream {
                model.ingest(makeEvent(kind: e == 0 ? "subagent_start" : "tool_use",
                                        summary: "\(agentId)-\(e)",
                                        agentId: agentId))
            }
            model.ingest(makeEvent(kind: "subagent_stop", summary: "\(agentId)-stop", agentId: agentId))
        }

        XCTAssertLessThanOrEqual(model.totalEventCount, ActivityStreamModel.maxTotalEvents,
                                  "every one of the \(streamCount) subagent streams finished, so all of them are reclaimable — the total budget must hold")
    }

    // MARK: - Bounded retention: reclaim order
    //
    // The most important bounded-retention property: reclaiming to stay
    // within maxTotalEvents must prefer a FINISHED subagent stream over a
    // still-running one, and must prefer any subagent stream over the main
    // stream — mirroring store.rs's `evict_if_over_budget`, which never
    // touches the main stream or a still-running subagent stream.

    // NOTE: the reclaim policy has THREE tiers, in this exact order —
    // finished subagent streams, then running subagent streams, then the
    // main stream last (see `ActivityStreamModel.reclaimIfOverBudget`) —
    // deliberately more thorough than the daemon's own `evict_if_over_budget`
    // (`src/activity/store.rs`), which only ever reclaims whole finished
    // streams and simply accepts staying over budget if that's not enough
    // (each stream is still bounded individually by MAX_EVENTS_PER_STREAM).
    // The client's stricter three-tier policy means a running stream is
    // NOT immune from reclaim in general — it is only untouched here
    // because the finished tier alone has more than enough combined
    // capacity to absorb this test's excess, so tier 2 (running) and tier 3
    // (main) are never reached.
    func testAModerateOverBudgetOverageTrimsOnlyFinishedSubagentStreamsLeavingRunningAndMainUntouched() throws {
        var model = ActivityStreamModel()

        let mainCount = 30
        for i in 0..<mainCount {
            model.ingest(makeEvent(summary: "main-\(i)", agentId: nil))
        }

        let runningCount = 30
        model.ingest(makeEvent(kind: "subagent_start", summary: "sub-run-start", agentId: "sub-run"))
        for i in 0..<(runningCount - 1) {
            model.ingest(makeEvent(summary: "sub-run-\(i)", agentId: "sub-run"))
        }

        // Many FINISHED subagent streams whose COMBINED capacity comfortably
        // exceeds the excess over budget, so tier 1 (finished streams) alone
        // can absorb all of it without ever reaching tier 2 (running) or
        // tier 3 (main). Each stream stays comfortably under
        // maxEventsPerStream so no per-stream cap trimming interferes with
        // the numbers below.
        let finishedStreamCount = 15
        let perFinishedStreamCount = ActivityStreamModel.maxEventsPerStream - 10 // 190
        for s in 0..<finishedStreamCount {
            let agentId = "sub-fin-\(s)"
            model.ingest(makeEvent(kind: "subagent_start", summary: "\(agentId)-start", agentId: agentId))
            for i in 0..<(perFinishedStreamCount - 2) {
                model.ingest(makeEvent(summary: "\(agentId)-\(i)", agentId: agentId))
            }
            model.ingest(makeEvent(kind: "subagent_stop", summary: "\(agentId)-stop", agentId: agentId))
        }
        let finishedTotalBeforeReclaim = finishedStreamCount * perFinishedStreamCount // 2850

        let totalIngested = mainCount + runningCount + finishedTotalBeforeReclaim
        XCTAssertGreaterThan(totalIngested, ActivityStreamModel.maxTotalEvents,
                              "test setup must actually exceed the total budget for reclaim to be exercised")
        let excess = totalIngested - ActivityStreamModel.maxTotalEvents
        XCTAssertLessThan(excess, finishedTotalBeforeReclaim,
                           "the finished tier's combined capacity must exceed the excess, so this test actually exercises 'tier 1 alone is enough' rather than spilling into tier 2/3")

        let finishedAfterTotal = model.subagentStreams
            .filter { $0.agentId?.hasPrefix("sub-fin-") == true }
            .reduce(0) { $0 + $1.events.count }
        let runningAfter = try XCTUnwrap(model.subagentStreams.first { $0.agentId == "sub-run" }).events.count
        let mainAfter = try XCTUnwrap(model.mainStream).events.count

        XCTAssertLessThan(finishedAfterTotal, finishedTotalBeforeReclaim,
                           "the finished tier is reclaim-eligible and must shrink under budget pressure")
        XCTAssertEqual(runningAfter, runningCount,
                        "a still-running subagent stream must never be reclaimed from while any finished stream still has events to give up")
        XCTAssertEqual(mainAfter, mainCount,
                        "the main stream must never be reclaimed from while any finished stream still has events to give up")
    }

    func testAHugeOverBudgetOverageDrainsFinishedSubagentStreamsBeforeEverTouchingMain() throws {
        var model = ActivityStreamModel()

        model.ingest(makeEvent(summary: "main-1", agentId: nil))
        model.ingest(makeEvent(summary: "main-2", agentId: nil))
        model.ingest(makeEvent(summary: "main-survives-final", agentId: nil))

        let finishedStreamCount = 20
        var totalSubagentEventsIngested = 0
        for s in 0..<finishedStreamCount {
            let agentId = "drain-\(s)"
            model.ingest(makeEvent(kind: "subagent_start", summary: "\(agentId)-start", agentId: agentId))
            for i in 0..<(ActivityStreamModel.maxEventsPerStream - 2) {
                model.ingest(makeEvent(summary: "\(agentId)-\(i)", agentId: agentId))
            }
            model.ingest(makeEvent(kind: "subagent_stop", summary: "\(agentId)-stop", agentId: agentId))
            totalSubagentEventsIngested += ActivityStreamModel.maxEventsPerStream
        }
        XCTAssertGreaterThan(totalSubagentEventsIngested + 3, ActivityStreamModel.maxTotalEvents,
                              "test setup must overwhelm the total budget for the drain to be exercised")

        // Every non-main stream here is finished (fully reclaimable), and
        // main is tiny — a correct implementation always has enough
        // reclaimable subagent capacity to satisfy the budget without ever
        // needing to touch main, no matter how extreme the overage.
        XCTAssertLessThanOrEqual(model.totalEventCount, ActivityStreamModel.maxTotalEvents,
                                  "every subagent stream here finished, so all of them are reclaimable — the budget must hold even under an extreme overage")

        let main = try XCTUnwrap(model.mainStream)
        XCTAssertEqual(main.events.map(\.summary), ["main-1", "main-2", "main-survives-final"],
                        "the main stream must survive completely untouched — it is only ever reclaimed once every subagent stream is fully drained, and here that never becomes necessary")
    }

    // MARK: - Bounded retention: the ticker must survive reclamation

    func testTickerSummaryStillShowsTheMostRecentMainEventAfterAReclaimThatDrainsEverySubagentStream() {
        var model = ActivityStreamModel()

        model.ingest(makeEvent(agent: "perri", summary: "warming up", agentId: nil))
        model.ingest(makeEvent(agent: "perri", summary: "ticker-survives-final", agentId: nil))

        let finishedStreamCount = 20
        for s in 0..<finishedStreamCount {
            let agentId = "ticker-drain-\(s)"
            model.ingest(makeEvent(kind: "subagent_start", summary: "\(agentId)-start", agentId: agentId))
            for i in 0..<(ActivityStreamModel.maxEventsPerStream - 2) {
                model.ingest(makeEvent(summary: "\(agentId)-\(i)", agentId: agentId))
            }
            // Every subagent stream finishes, so runningSubagentCount is 0
            // and tickerSummary must take the "most recent main event"
            // branch rather than the "N agents active" branch.
            model.ingest(makeEvent(kind: "subagent_stop", summary: "\(agentId)-stop", agentId: agentId))
        }

        XCTAssertEqual(model.runningSubagentCount, 0)
        XCTAssertTrue(model.tickerSummary.contains("ticker-survives-final"),
                       "a bound that blanks the ticker is worse than no bound at all — the main stream's most recent event must still be visible after reclamation")
    }

    // MARK: - Bounded retention: snapshot rebuild

    func testReplayingMoreThanMaxTotalEventsIntoAFreshModelStaysWithinTheTotalBudget() {
        // Mirrors AppStore rebuilding a model from a daemon snapshot:
        // `var model = ActivityStreamModel(); for event in events { model.ingest(event) }`.
        var events: [ActivityEvent] = []
        let streamCount = 25
        let eventsPerStream = 100 // 25 * 100 = 2500, over maxTotalEvents
        for s in 0..<streamCount {
            let agentId = "replay-\(s)"
            events.append(makeEvent(kind: "subagent_start", summary: "\(agentId)-start", agentId: agentId))
            for i in 0..<(eventsPerStream - 2) {
                events.append(makeEvent(summary: "\(agentId)-\(i)", agentId: agentId))
            }
            events.append(makeEvent(kind: "subagent_stop", summary: "\(agentId)-stop", agentId: agentId))
        }
        XCTAssertGreaterThan(events.count, ActivityStreamModel.maxTotalEvents,
                              "test setup must replay more than the total budget for the bound to be exercised")

        var model = ActivityStreamModel()
        for event in events {
            model.ingest(event)
        }

        XCTAssertLessThanOrEqual(model.totalEventCount, ActivityStreamModel.maxTotalEvents,
                                  "a fresh model rebuilt from an oversized daemon snapshot must still respect the total budget")
    }

    // MARK: - Bounded retention: subagent stream ENTRY cap
    //
    // Distinct from the per-stream EVENT cap above: this bounds the NUMBER of
    // subagent stream entries tracked at all, so a long-lived focus that
    // spawns thousands of short-lived subagents over time doesn't grow
    // `subagentStreams` (and `lastSeqByStreamKey`) without bound even though
    // each individual stream's events are already capped.

    func testSubagentStreamEntryCountCapsAtMaxSubagentStreamsKeepingTheMostRecentlySeenAgentIds() {
        var model = ActivityStreamModel()
        let overshoot = ActivityStreamModel.maxSubagentStreams + 20
        for i in 0..<overshoot {
            let agentId = "sub-\(i)"
            model.ingest(makeEvent(kind: "subagent_start", agentId: agentId))
            model.ingest(makeEvent(kind: "subagent_stop", agentId: agentId))
        }

        XCTAssertEqual(model.subagentStreams.count, ActivityStreamModel.maxSubagentStreams)

        let survivingAgentIds = Set(model.subagentStreams.compactMap(\.agentId))
        let expectedSurvivors = Set((20..<overshoot).map { "sub-\($0)" })
        XCTAssertEqual(survivingAgentIds, expectedSurvivors,
                        "must keep the most-recently-seen maxSubagentStreams agentIds")
    }

    func testSubagentEntryCapNeverEvictsAStillRunningStreamEvenWellOverTheCap() {
        var model = ActivityStreamModel()
        let overshoot = ActivityStreamModel.maxSubagentStreams + 20
        for i in 0..<overshoot {
            model.ingest(makeEvent(kind: "subagent_start", agentId: "sub-\(i)"))
        }

        XCTAssertEqual(model.subagentStreams.count, overshoot,
                        "every one of these subagent streams is still running — none may be evicted, even though the entry cap is exceeded")
        XCTAssertEqual(model.runningSubagentCount, overshoot)
    }

    func testFinishingASubagentStreamDoesNotEagerlyEvictItWhileWellUnderBothCaps() throws {
        var model = ActivityStreamModel()
        model.ingest(makeEvent(kind: "subagent_start", summary: "a-start", agentId: "sub-a"))
        model.ingest(makeEvent(summary: "a-work", agentId: "sub-a"))
        model.ingest(makeEvent(kind: "subagent_start", summary: "b-start", agentId: "sub-b"))

        model.ingest(makeEvent(kind: "subagent_stop", summary: "a-stop", agentId: "sub-a"))

        let streamA = try XCTUnwrap(model.subagentStreams.first { $0.agentId == "sub-a" })
        XCTAssertTrue(streamA.finished)
        XCTAssertEqual(streamA.events.map(\.summary), ["a-start", "a-work", "a-stop"],
                        "the events/entry for a just-finished stream must remain intact immediately after finishing, while comfortably under both caps")
    }

    // MARK: - Bounded retention: seq baseline pruned in lockstep with entry eviction

    func testEvictingASubagentStreamEntryClearsItsSeqBaselineSoARecreatedStreamStartsClean() {
        var model = ActivityStreamModel()
        let overshoot = ActivityStreamModel.maxSubagentStreams + 20
        for i in 0..<overshoot {
            let agentId = "sub-\(i)"
            model.ingest(makeEvent(agentId: agentId, seq: 1))
            model.ingest(makeEvent(kind: "subagent_stop", agentId: agentId, seq: 2))
        }

        // "sub-0" was the first agentId ever seen and must have been evicted
        // by the entry cap (see the entry-cap eviction-order test above).
        XCTAssertFalse(model.subagentStreams.contains { $0.agentId == "sub-0" },
                        "sub-0 must have been evicted for this test to be meaningful")

        // A brand-new event for the now-evicted "sub-0", with an arbitrary
        // seq that would read as a gap against the OLD stream's baseline
        // (which ended at seq 2) — but must NOT be a gap against a freshly
        // recreated stream, because eviction must have cleared the
        // remembered seq baseline along with the rest of the stream's state.
        let gap = model.ingest(makeEvent(agentId: "sub-0", seq: 999))
        XCTAssertFalse(gap,
                        "the evicted stream's seq baseline must be cleared along with its entry — a recreated stream's first event is never a gap")
    }
}

// MARK: - ActivityStreamModelDriftGuardTests

/// A fitness function, not a behavioural test — same spirit as
/// `ActivityTickerWiringTests`. `src/activity/store.rs` is the daemon's Rust
/// retention policy; `ActivityStreamModel`'s bounds must never silently
/// drift from it: a client cap BELOW the daemon's would silently discard
/// part of a snapshot the daemon still considers current; a cap ABOVE it
/// could never actually bind, since the daemon already trimmed first.
/// Whoever trips this test must change both constants together, or
/// knowingly diverge with a comment explaining why.
final class ActivityStreamModelDriftGuardTests: XCTestCase {

    func testClientRetentionCapsMatchTheDaemonsRustConstantsExactly() throws {
        let source = try Self.storeRsSource()

        let perStream = try Self.extractIntLiteral(name: "MAX_EVENTS_PER_STREAM", from: source)
        let total = try Self.extractIntLiteral(name: "MAX_TOTAL_EVENTS", from: source)

        XCTAssertEqual(perStream, ActivityStreamModel.maxEventsPerStream, """
            ActivityStreamModel.maxEventsPerStream (\(ActivityStreamModel.maxEventsPerStream)) must equal \
            src/activity/store.rs's MAX_EVENTS_PER_STREAM (\(perStream)). A client cap below the daemon's \
            would silently discard part of a snapshot the daemon still considers current; a cap above it \
            could never bind, since the daemon already trimmed first. Change both constants together, or \
            diverge deliberately with a comment explaining why.
            """)
        XCTAssertEqual(total, ActivityStreamModel.maxTotalEvents, """
            ActivityStreamModel.maxTotalEvents (\(ActivityStreamModel.maxTotalEvents)) must equal \
            src/activity/store.rs's MAX_TOTAL_EVENTS (\(total)). A client cap below the daemon's would \
            silently discard part of a snapshot the daemon still considers current; a cap above it could \
            never bind, since the daemon already trimmed first. Change both constants together, or diverge \
            deliberately with a comment explaining why.
            """)
    }

    // MARK: - Helpers

    /// `src/activity/store.rs` is not compiled into this target, so it has
    /// to be read as text — same idiom as
    /// `ActivityTickerWiringTests.tickerViewSource()`.
    private static func storeRsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/ActivityStreamModelTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .deletingLastPathComponent()                // repo root
            .appendingPathComponent("src/activity/store.rs")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Textual heuristic, not a semantic proof — same caveat the other
    /// fitness functions in this file carry. Extracts the integer literal
    /// from a line shaped like `pub const NAME: usize = 200;`.
    private static func extractIntLiteral(name: String, from source: String) throws -> Int {
        let pattern = "pub const \(name): usize = (\\d+);"
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        let match = try XCTUnwrap(regex.firstMatch(in: source, range: range),
                                   "could not find `pub const \(name): usize = <N>;` in store.rs — did it get renamed or reshaped?")
        let literalRange = try XCTUnwrap(Range(match.range(at: 1), in: source))
        return try XCTUnwrap(Int(source[literalRange]))
    }
}

// MARK: - ActivityStreamStoreTests

/// `ActivityStreamStore` is the tag-keyed layer `AppStore` will use to hold
/// one `ActivityStreamModel` per focus tag (replacing today's plain
/// `[String: ActivityStreamModel]` `activityModels` dictionary — see
/// `AppStore.swift`). It adds its own LRU cap on the NUMBER of tracked tags,
/// independent of `ActivityStreamModel`'s own per-tag event bounds (covered
/// above): a long-lived daemon session that cycles through many focus tags
/// over time must not grow this dictionary without bound either.
final class ActivityStreamStoreTests: XCTestCase {

    // MARK: - Event factory (mirrors ActivityStreamModelTests.makeEvent)

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

    // MARK: - Attribution non-regression

    func testIngestRoutesAnEventToTheModelForItsTag() {
        var store = ActivityStreamStore()
        store.ingest(makeEvent(summary: "perri's event"), tag: "perri")

        XCTAssertEqual(store.model(for: "perri").mainStream?.events.last?.summary, "perri's event")
        XCTAssertNil(store.model(for: "fred").mainStream,
                      "a tag that was never touched must come back as the untouched-empty state")
    }

    // MARK: - Empty model for an unseen tag

    func testModelForAnUnseenTagMatchesAFreshActivityStreamModelsNeutralWaitingState() {
        let store = ActivityStreamStore()
        let model = store.model(for: "never-seen")

        XCTAssertNil(model.mainStream)
        XCTAssertEqual(model.tickerSummary, "⚙ —",
                        "must match AppStore.activityModel(for:)'s existing empty-tag fallback shape exactly")
    }

    // MARK: - `replace` swaps one tag's model wholesale

    func testReplaceSwapsOneTagsModelWholesaleLeavingOtherTagsUntouched() {
        var store = ActivityStreamStore()
        store.ingest(makeEvent(summary: "a-original"), tag: "a")
        store.ingest(makeEvent(summary: "b-original"), tag: "b")

        var replacement = ActivityStreamModel()
        replacement.ingest(makeEvent(summary: "a-replaced"))
        store.replace(tag: "a", with: replacement)

        XCTAssertEqual(store.model(for: "a").mainStream?.events.last?.summary, "a-replaced")
        XCTAssertEqual(store.model(for: "b").mainStream?.events.last?.summary, "b-original",
                        "replacing tag \"a\"'s model must not disturb tag \"b\"'s model")
    }

    // MARK: - Tag cap

    func testTrackedTagCountCapsAtMaxTrackedFocusTags() {
        var store = ActivityStreamStore()
        let overshoot = ActivityStreamStore.maxTrackedFocusTags + 10
        for i in 0..<overshoot {
            store.ingest(makeEvent(summary: "tag-\(i)-event"), tag: "tag-\(i)")
        }

        XCTAssertEqual(store.trackedTagCount, ActivityStreamStore.maxTrackedFocusTags)
    }

    // MARK: - LRU victim is never the live one

    func testTheMostRecentlyIngestedTagSurvivesEvenAfterChurningPastTheCap() {
        var store = ActivityStreamStore()
        let overshoot = ActivityStreamStore.maxTrackedFocusTags + 10
        var lastTag = ""
        for i in 0..<overshoot {
            lastTag = "churn-\(i)"
            store.ingest(makeEvent(summary: "\(lastTag)-event"), tag: lastTag)
        }

        XCTAssertNotNil(store.model(for: lastTag).mainStream,
                         "the tag most recently ingested into must never be the LRU victim")
    }

    // MARK: - `unattributedTag` is never evicted

    func testUnattributedTagSurvivesBeingTheLeastRecentlyTouchedTagInTheStore() {
        var store = ActivityStreamStore()
        store.ingest(makeEvent(summary: "unattributed-event"), tag: ActivityStreamStore.unattributedTag)

        let churnCount = ActivityStreamStore.maxTrackedFocusTags + 20
        for i in 0..<churnCount {
            store.ingest(makeEvent(summary: "churn-\(i)-event"), tag: "churn-\(i)")
        }

        XCTAssertNotNil(store.model(for: ActivityStreamStore.unattributedTag).mainStream,
                         "the unattributed bucket must survive even as the least-recently-touched tag in the whole store")
    }

    // MARK: - Gap flag passes through

    func testIngestReturnsTheUnderlyingModelsGapFlagKeyedByTag() {
        var store = ActivityStreamStore()
        XCTAssertFalse(store.ingest(makeEvent(seq: 1), tag: "x"))
        XCTAssertTrue(store.ingest(makeEvent(seq: 5), tag: "x"),
                      "seq jumped from 1 to 5 for tag \"x\" — same gap semantics as ActivityStreamModel.ingest, proxied through the tag-keyed store")
    }
}
