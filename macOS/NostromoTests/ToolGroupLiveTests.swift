import XCTest
import AppKit
import NostromoKit

// TF3 (transcript tool folds): a group while it runs, and what happens when it stops.
//
// Covers the live row (running title, failures, elapsed time, activity dot, VoiceOver), the
// stuck-turn auto-open and the operator's choice beating it, the settle callback behind the
// VoiceOver announcement, the elapsed-time ticker, and fold resolution with `groupAuto`.
//
// Everything is stated from outside: the strings the row shows, the callbacks the view fires,
// the heights it reports, what the injected `post` closure received. The clock is an injected
// box and the ticker's scheduler is a fake with simulated time: no sleeps, no wall clock.
// Nothing here touches the real pasteboard, UserDefaults or ~/.nostromo.
//
// `ChatTurnView`, `ToolGroupView`, `ElapsedTicker`, `ToolActivityAnnouncer`, `FoldResolver` and
// `TurnInteractionStore` are compiled into this logic-test bundle directly; NostromoKit is linked.

private typealias F = FoldFixtures

// MARK: - Helpers

private let livePaneWidth: CGFloat = 900

/// A clock the test moves by hand. Handed to views as `now: { clock.now }`.
private final class LiveClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func makeLive(_ turn: ChatTurn, _ clock: LiveClock, interaction: TurnInteractionState = TurnInteractionState(),
                      folds: FoldResolver? = nil) -> ChatTurnView {
    let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: interaction, folds: folds,
                            now: { clock.now })
    view.setIslandWidth(livePaneWidth)
    return view
}

private func liveGroupViews(in view: NSView) -> [ToolGroupView] {
    rigAllSubviews(of: view).compactMap { $0 as? ToolGroupView }
}

private func liveTrimmed(_ field: NSTextField) -> String {
    field.stringValue.trimmingCharacters(in: .whitespaces)
}

private func assertDate(_ date: Date?, isSeconds seconds: Double?, _ message: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
    switch (date, seconds) {
    case (nil, nil):
        break
    case (let date?, let seconds?):
        XCTAssertEqual(date.timeIntervalSince(F.epoch), seconds, accuracy: 0.001, message, file: file, line: line)
    default:
        XCTFail("expected \(String(describing: seconds)) s, got \(String(describing: date?.timeIntervalSince(F.epoch))) s. \(message)",
                file: file, line: line)
    }
}

private func errorChip() -> TurnBlock {
    .resultSummary(ResultSummaryData(durationMs: 5, costUSD: 0.01, isError: true))
}

private func stopChip() -> TurnBlock {
    .resultSummary(ResultSummaryData(durationMs: 5, costUSD: 0.01, isError: true, interrupted: true))
}

/// Two calls, the second of which fails: one group, `g:<prefix>0`, with one failure.
private func failingRun(_ prefix: String = "s") -> [TurnBlock] {
    [F.call(id: "\(prefix)0", summary: "make a", start: 0), F.result("ok", id: "\(prefix)0", time: 0.5),
     F.call(id: "\(prefix)1", summary: "make b", start: 1), F.result("exit 2", id: "\(prefix)1", isError: true, time: 1.5)]
}

/// The row text a group should read, derived from NostromoKit (the running title while running).
private func expectedRowText(_ turn: ChatTurn) -> String {
    let g = F.groups(of: turn).last!
    return ToolGroupSummary.runningTitle(for: g) ?? ToolGroupSummary.summary(for: g) ?? ToolGroupSummary.header(for: g.calls[0])
}

/// A turn view fed block by block, with every callback recorded.
private final class LiveStream {
    var turn: ChatTurn
    let view: ChatTurnView
    let clock: LiveClock
    private(set) var autoOpened: [String] = []
    private(set) var settled: [ToolGroup] = []
    private(set) var toggles: [String] = []

    init(_ blocks: [TurnBlock], complete: Bool = false, clock: LiveClock = LiveClock(F.at(0)),
         interaction: TurnInteractionState = TurnInteractionState(), folds: FoldResolver? = nil) {
        let built = F.turn(blocks, complete: complete)
        self.clock = clock
        self.turn = built
        self.view = makeLive(built, clock, interaction: interaction, folds: folds)
        view.onAutoOpen = { [weak self] in self?.autoOpened.append($0) }
        view.onGroupSettled = { [weak self] in self?.settled.append($0) }
        view.onGroupToggle = { [weak self] key, open in self?.toggles.append("\(key)=\(open)") }
    }

    func append(_ blocks: [TurnBlock], complete: Bool = false) {
        turn.blocks.append(contentsOf: blocks)
        if complete { turn.isComplete = true }
        view.update(turn: turn)
    }

    func group(_ index: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> ToolGroupView {
        try XCTUnwrap(liveGroupViews(in: view).dropFirst(index).first, "no group view \(index)", file: file, line: line)
    }
}

// MARK: - The live row

final class ToolGroupLiveRowTests: XCTestCase {

    /// A running group: `done` finished Bash calls (the first `failed` failed), then one call
    /// still waiting for its result, started at `started`.
    private func runningGroup(done: Int = 0, failed: Int = 0, started: Double? = 0, call: String = "cargo test") -> ToolGroup {
        var blocks: [FoldBlock] = []
        for i in 0 ..< done {
            blocks.append(F.foldCall("Bash", id: "d\(i)", summary: "step \(i)", start: Double(i)))
            blocks.append(F.foldResult(id: "d\(i)", isError: i < failed, time: Double(i) + 0.5))
        }
        blocks.append(F.foldCall("Bash", id: "run", summary: call, start: started))
        return F.group(blocks, outcome: .open)
    }

    /// Three calls in a turn the operator stopped: the last has no result. The first `failed` failed.
    private func stoppedGroup(failed: Int = 0) -> ToolGroup {
        var blocks: [FoldBlock] = []
        for i in 0 ..< 3 {
            blocks.append(F.foldCall("Bash", id: "s\(i)", summary: "cmd \(i)", start: Double(i)))
            if i < 2 { blocks.append(F.foldResult(id: "s\(i)", isError: i < failed, time: Double(i) + 0.5)) }
        }
        return F.group(blocks, outcome: .interrupted)
    }

    private func makeRow(_ group: ToolGroup, clock: LiveClock = LiveClock(F.at(0)),
                         reduceMotion: @escaping () -> Bool = { false }) -> (RigWindow, ToolGroupRowView) {
        let window = makeRigWindow(self, size: NSSize(width: 700, height: 200))
        let row = ToolGroupRowView(group: group, isExpanded: false, payloadAvailable: true,
                                   reduceMotion: reduceMotion, now: { clock.now })
        row.frame = NSRect(x: 20, y: 100, width: 600, height: ToolGroupRowView.height)
        window.contentView!.addSubview(row)
        window.contentView!.layoutSubtreeIfNeeded()
        return (window, row)
    }

    // MARK: texts

    func testARunningRowReadsRunningTheDoneCountAndTheRunningCallsHeader() {
        let (_, row) = makeRow(runningGroup(done: 3))

        XCTAssertEqual(row.summaryField.stringValue, "Running · 3 done · Bash · cargo test")
        XCTAssertTrue(row.badgeField.isHidden, "nothing failed")
        XCTAssertTrue(row.stoppedField.isHidden)
    }

    func testARunningRowWithNothingDoneYetOmitsTheDoneCount() {
        let (_, row) = makeRow(runningGroup(done: 0))

        XCTAssertEqual(row.summaryField.stringValue, "Running · Bash · cargo test")
    }

    func testTheFailureBadgeShowsAsSoonAsACallFailsWhileTheGroupIsStillRunning() {
        let (_, row) = makeRow(runningGroup(done: 3, failed: 1))

        XCTAssertFalse(row.badgeField.isHidden)
        XCTAssertEqual(liveTrimmed(row.badgeField), "· 1 failed")
        XCTAssertEqual(row.badgeField.textColor, Theme.foldFailure)
        XCTAssertEqual(row.summaryField.stringValue, "Running · 3 done · Bash · cargo test")
    }

    func testUpdatingARunningRowToASettledGroupRestoresTheOrdinarySummary() {
        let (_, row) = makeRow(runningGroup(done: 2))

        row.update(group: F.plainGroup(calls: 3))

        XCTAssertEqual(row.summaryField.stringValue, "Ran 3 commands")
        XCTAssertFalse(row.isShowingActivity)
    }

    func testTheRowIsTwentyTwoPointsInEveryLiveState() {
        for group in [runningGroup(done: 0), runningGroup(done: 5, failed: 2), stoppedGroup(), F.failingGroup()] {
            let (_, row) = makeRow(group)
            XCTAssertEqual(row.frame.height, ToolGroupRowView.height)
            XCTAssertEqual(ToolGroupRowView.height, 22)
        }
    }

    // MARK: elapsed time

    func testTheElapsedTimeIsHiddenBeforeTenSecondsAndShowsFromTenSeconds() {
        let clock = LiveClock(F.at(9))
        let (_, row) = makeRow(runningGroup(started: 0), clock: clock)

        row.refreshElapsed()
        XCTAssertTrue(row.timeField.isHidden, "9 s")

        clock.now = F.at(9.9)
        row.refreshElapsed()
        XCTAssertTrue(row.timeField.isHidden, "9.9 s floors to 9")

        clock.now = F.at(10)
        row.refreshElapsed()
        XCTAssertFalse(row.timeField.isHidden)
        XCTAssertEqual(liveTrimmed(row.timeField), "· 10 s")

        clock.now = F.at(75)
        row.refreshElapsed()
        XCTAssertEqual(liveTrimmed(row.timeField), "· 1 m 15 s")
    }

    func testRefreshingTheElapsedTimeChangesNothingButTheTimeField() {
        let clock = LiveClock(F.at(12))
        let (_, row) = makeRow(runningGroup(done: 2, failed: 1, started: 0), clock: clock)
        row.refreshElapsed()
        let summary = row.summaryField.stringValue
        let badge = row.badgeField.stringValue

        clock.now = F.at(300)
        row.refreshElapsed()

        XCTAssertEqual(row.summaryField.stringValue, summary)
        XCTAssertEqual(row.badgeField.stringValue, badge)
        XCTAssertEqual(row.frame.height, ToolGroupRowView.height)
        XCTAssertEqual(liveTrimmed(row.timeField), "· 5 m 00 s")
    }

    func testARunningRowShowsNoElapsedTimeWhenTheCallsStartIsUnknown() {
        let clock = LiveClock(F.at(500))
        let (_, row) = makeRow(runningGroup(started: nil), clock: clock)

        row.refreshElapsed()

        XCTAssertTrue(row.timeField.isHidden)
    }

    // MARK: stopped

    func testAStoppedRowSaysStoppedAndIsNotShowingActivity() {
        let (_, row) = makeRow(stoppedGroup())

        XCTAssertFalse(row.stoppedField.isHidden)
        XCTAssertEqual(liveTrimmed(row.stoppedField), "· stopped")
        XCTAssertFalse(row.isShowingActivity)
        XCTAssertEqual(row.summaryField.stringValue, "Ran 3 commands")
        XCTAssertTrue(row.badgeField.isHidden, "a call with no result is not a failure")
    }

    func testAStoppedRowKeepsTheFailuresThatHappenedBeforeTheStop() {
        let (_, row) = makeRow(stoppedGroup(failed: 1))

        XCTAssertEqual(liveTrimmed(row.badgeField), "· 1 failed")
        XCTAssertEqual(liveTrimmed(row.stoppedField), "· stopped")
    }

    func testASettledRowHasNoStoppedLabelAndNoActivity() {
        let (_, row) = makeRow(F.plainGroup(calls: 3))

        XCTAssertTrue(row.stoppedField.isHidden)
        XCTAssertFalse(row.isShowingActivity)
    }

    // MARK: activity dot

    func testARunningRowShowsAnActivityDotThatPulsesItsOpacityOverOnePointTwoSeconds() throws {
        let (_, row) = makeRow(runningGroup(done: 1))

        XCTAssertTrue(row.isShowingActivity)
        let animation = try XCTUnwrap(row.activityLayer.animation(forKey: "pulse") as? CABasicAnimation,
                                      "the dot pulses with a CABasicAnimation under the key \"pulse\"")
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.duration, 1.2, accuracy: 0.001)
        XCTAssertGreaterThan(animation.repeatCount, 100, "it keeps pulsing for as long as the group runs")
    }

    func testTheActivityDotShowsButDoesNotPulseUnderReduceMotion() {
        let (_, row) = makeRow(runningGroup(done: 1), reduceMotion: { true })

        XCTAssertTrue(row.isShowingActivity, "the dot is still the running signal")
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"))
    }

    func testTheActivityDotGoesAwayWhenTheGroupSettlesAndStopsPulsing() {
        let (_, row) = makeRow(runningGroup(done: 1))
        XCTAssertTrue(row.isShowingActivity)

        row.update(group: F.plainGroup(calls: 2))

        XCTAssertFalse(row.isShowingActivity)
        XCTAssertNil(row.activityLayer.animation(forKey: "pulse"), "a settled row must not keep an animation running")
    }

    func testTheActivityDotComesBackWhenASettledRowStartsRunningAgain() {
        let (_, row) = makeRow(F.plainGroup(calls: 2))
        XCTAssertFalse(row.isShowingActivity)

        row.update(group: runningGroup(done: 2))

        XCTAssertTrue(row.isShowingActivity)
        XCTAssertNotNil(row.activityLayer.animation(forKey: "pulse"))
    }

    // MARK: VoiceOver

    func testARunningRowsAccessibilityLabelIsTheLiveText() {
        let clock = LiveClock(F.at(52))
        let group = runningGroup(done: 3, failed: 1, started: 10)
        let (_, row) = makeRow(group, clock: clock)

        XCTAssertEqual(row.accessibilityLabel(), "Running · 3 done · Bash · cargo test, 1 failed call, 42 s")
        XCTAssertEqual(row.accessibilityLabel(), ToolGroupSummary.accessibilityLabel(for: group, now: clock.now))

        clock.now = F.at(70)
        XCTAssertEqual(row.accessibilityLabel(), "Running · 3 done · Bash · cargo test, 1 failed call, 1 m 00 s",
                       "the label reads the clock when asked")
    }

    func testAStoppedRowsAccessibilityLabelEndsWithStopped() {
        let (_, row) = makeRow(stoppedGroup())

        XCTAssertEqual(row.accessibilityLabel(), "Ran 3 commands, stopped")
    }
}

// MARK: - A turn streaming

final class ToolGroupLiveStreamingTests: XCTestCase {

    // MARK: running title, synchronously, without touching the layout

    func testTheRowTextFollowsEveryCallThatStartsOrFinishesAndNothingMovesInTheLayout() throws {
        let clock = LiveClock(F.at(0))
        var turn = F.turn([.text(F.prose), F.call(id: "r0", summary: "cmd r0", start: 0)], complete: false)
        let view = makeLive(turn, clock)
        let group = try XCTUnwrap(liveGroupViews(in: view).first)
        XCTAssertEqual(group.row.summaryField.stringValue, "Running · Bash · cmd r0")
        let baseline = view.islandHeight()
        XCTAssertEqual(group.intrinsicContentSize.height, ToolGroupRowView.height)

        var steps: [TurnBlock] = []
        for i in 0 ..< 8 {
            steps.append(F.result(i == 3 ? "exit 1" : "ok \(i)", id: "r\(i)", isError: i == 3, time: Double(i) + 0.5))
            steps.append(F.call(id: "r\(i + 1)", summary: "cmd r\(i + 1)", start: Double(i + 1)))
        }

        for (n, block) in steps.enumerated() {
            turn.blocks.append(block)
            #if DEBUG
            let measuredBefore = ChatTurnView.measureIslandCount
            #endif

            view.update(turn: turn)

            let g = F.groups(of: turn).last!
            XCTAssertEqual(group.row.summaryField.stringValue, expectedRowText(turn), "step \(n): text, synchronously")
            XCTAssertEqual(group.row.badgeField.isHidden, g.failedCount == 0, "step \(n): badge")
            if g.failedCount > 0 { XCTAssertEqual(liveTrimmed(group.row.badgeField), "· \(g.failedCount) failed", "step \(n)") }
            let expectedTime: String? = g.state == .running ? nil : ToolGroupSummary.durationText(for: g)
            XCTAssertEqual(group.row.timeField.isHidden, expectedTime == nil, "step \(n): time")
            if let expectedTime { XCTAssertEqual(liveTrimmed(group.row.timeField), "· \(expectedTime)", "step \(n)") }

            XCTAssertEqual(view.islandHeight(), baseline, accuracy: 0.001, "step \(n): a collapsed group's island never changes height")
            XCTAssertEqual(group.intrinsicContentSize.height, ToolGroupRowView.height, "step \(n)")
            #if DEBUG
            XCTAssertEqual(ChatTurnView.measureIslandCount, measuredBefore, "step \(n): a row-text update re-measures nothing")
            #endif
            if n == 1 { XCTAssertEqual(group.row.summaryField.stringValue, "Running · 1 done · Bash · cmd r1") }
        }
        XCTAssertEqual(liveGroupViews(in: view).count, 1, "every call joined the one group")
        XCTAssertEqual(group.row.summaryField.stringValue, "Running · 8 done · Bash · cmd r8")
        XCTAssertEqual(liveTrimmed(group.row.badgeField), "· 1 failed")
    }

    func testAnExpandedGroupsRowTextAlsoFollowsTheStream() throws {
        let clock = LiveClock(F.at(0))
        var turn = F.turn([F.call(id: "e0", summary: "cmd e0", start: 0)], complete: false)
        let view = makeLive(turn, clock, folds: FoldResolver(expandedByDefault: true))
        let group = try XCTUnwrap(liveGroupViews(in: view).first)

        for block in [F.result("ok", id: "e0", time: 1), F.call(id: "e1", summary: "cmd e1", start: 1)] {
            turn.blocks.append(block)
            view.update(turn: turn)
        }

        XCTAssertEqual(group.row.summaryField.stringValue, "Running · 1 done · Bash · cmd e1")
        XCTAssertTrue(group.isExpanded)
    }

    // MARK: quiet calls

    /// What `ToolCompletionFolding.apply` does to a quiet `mkdir` result: the call changes in
    /// place and no block is appended.
    private func finishQuietly(_ id: String, at seconds: Double?, in turn: inout ChatTurn) {
        for index in turn.blocks.indices {
            guard case .toolCall(var data) = turn.blocks[index], data.toolUseId == id else { continue }
            data.finishedQuietly = true
            data.finishedAt = seconds.map(F.at)
            turn.blocks[index] = .toolCall(data)
        }
    }

    func testACallThatFinishesQuietlyInPlaceCountsAsDoneWithoutANewBlock() throws {
        let clock = LiveClock(F.at(0))
        var turn = F.turn([.text(F.prose),
                           F.call(id: "q0", summary: "cmd q0", start: 0), F.result("ok", id: "q0", time: 0.5),
                           F.call(id: "q1", summary: "mkdir out", start: 1),
                           F.call(id: "q2", summary: "cargo test", start: 2)], complete: false)
        let view = makeLive(turn, clock)
        let group = try XCTUnwrap(liveGroupViews(in: view).first)
        XCTAssertEqual(group.row.summaryField.stringValue, "Running · 1 done · Bash · cargo test")
        let blockCount = turn.blocks.count
        let baseline = view.islandHeight()

        finishQuietly("q1", at: 2.0, in: &turn)
        view.update(turn: turn)

        XCTAssertEqual(turn.blocks.count, blockCount, "the quiet result added no block")
        XCTAssertEqual(group.row.summaryField.stringValue, "Running · 2 done · Bash · cargo test")
        XCTAssertEqual(view.islandHeight(), baseline, accuracy: 0.001)

        finishQuietly("q2", at: 3.5, in: &turn)
        view.update(turn: turn)

        XCTAssertEqual(group.row.summaryField.stringValue, "Ran 3 commands", "every call finished: the group settled")
        XCTAssertFalse(group.row.isShowingActivity)
        XCTAssertEqual(liveTrimmed(group.row.timeField), "· 3.5 s", "from the first start to the last quiet finish")
    }

    func testAQuietFinishWithoutATimeStillCountsAsDoneButGivesNoGroupTime() throws {
        let clock = LiveClock(F.at(0))
        var turn = F.turn([F.call(id: "q0", summary: "cmd q0", start: 0), F.call(id: "q1", summary: "mkdir out", start: 1)],
                          complete: false)
        let view = makeLive(turn, clock)
        let group = try XCTUnwrap(liveGroupViews(in: view).first)
        XCTAssertEqual(group.row.summaryField.stringValue, "Running · Bash · mkdir out")

        finishQuietly("q0", at: nil, in: &turn)
        view.update(turn: turn)
        XCTAssertEqual(group.row.summaryField.stringValue, "Running · 1 done · Bash · mkdir out")

        finishQuietly("q1", at: nil, in: &turn)
        view.update(turn: turn)
        XCTAssertEqual(group.row.summaryField.stringValue, "Ran 2 commands")
        XCTAssertTrue(group.row.timeField.isHidden, "the end of the group is unknown")
    }

    // MARK: elapsed time on the view

    func testRefreshingElapsedTimeShowsTheTimeFromTenSecondsWithoutMeasuringAnything() throws {
        let clock = LiveClock(F.at(9))
        let turn = F.turn([.text(F.prose), F.call(id: "c0", summary: "cargo test", start: 0)], complete: false)
        let view = makeLive(turn, clock)
        let group = try XCTUnwrap(liveGroupViews(in: view).first)
        let baseline = view.islandHeight()
        #if DEBUG
        let measuredBefore = ChatTurnView.measureIslandCount
        #endif

        view.refreshElapsed()
        XCTAssertTrue(group.row.timeField.isHidden, "9 s")

        clock.now = F.at(10)
        view.refreshElapsed()
        XCTAssertEqual(liveTrimmed(group.row.timeField), "· 10 s")

        clock.now = F.at(125)
        view.refreshElapsed()
        XCTAssertEqual(liveTrimmed(group.row.timeField), "· 2 m 05 s")
        XCTAssertEqual(view.islandHeight(), baseline, accuracy: 0.001)
        #if DEBUG
        XCTAssertEqual(ChatTurnView.measureIslandCount, measuredBefore, "an elapsed refresh re-measures nothing")
        #endif
    }

    func testTheNextElapsedTickIsTenSecondsAfterTheCallStartsThenEveryWholeSecond() {
        let turn = F.turn([F.call(id: "c0", summary: "cargo test", start: 100)], complete: false)
        let view = makeLive(turn, LiveClock(F.at(100)))

        assertDate(view.nextElapsedTick(after: F.at(100)), isSeconds: 110, "just started")
        assertDate(view.nextElapsedTick(after: F.at(103)), isSeconds: 110)
        assertDate(view.nextElapsedTick(after: F.at(109.99)), isSeconds: 110, "younger than 10 s")
        assertDate(view.nextElapsedTick(after: F.at(110)), isSeconds: 111, "ten seconds old: the next whole second")
        assertDate(view.nextElapsedTick(after: F.at(142.2)), isSeconds: 143)
        assertDate(view.nextElapsedTick(after: F.at(143)), isSeconds: 144)
    }

    func testThereIsNoNextElapsedTickWithoutARunningCallWithAKnownStart() {
        let settled = makeLive(F.turn(F.run(2), complete: true), LiveClock(F.at(0)))
        let unknownStart = makeLive(F.turn([F.call(id: "c0", summary: "cargo test")], complete: false), LiveClock(F.at(0)))
        let proseOnly = makeLive(F.turn([.text(F.prose)], complete: false), LiveClock(F.at(0)))
        let allFinished = makeLive(F.turn([F.call(id: "c0", summary: "ls", start: 0), F.result("ok", id: "c0")], complete: false),
                                   LiveClock(F.at(0)))

        XCTAssertNil(settled.nextElapsedTick(after: F.at(500)))
        XCTAssertNil(unknownStart.nextElapsedTick(after: F.at(500)))
        XCTAssertNil(proseOnly.nextElapsedTick(after: F.at(500)))
        XCTAssertNil(allFinished.nextElapsedTick(after: F.at(500)))
    }

    func testTheNextElapsedTickGoesAwayOnceTheGroupSettles() {
        let stream = LiveStream([F.call(id: "c0", summary: "cargo test", start: 0)])
        XCTAssertNotNil(stream.view.nextElapsedTick(after: F.at(1)))

        stream.append([F.result("ok", id: "c0", time: 20)])

        XCTAssertNil(stream.view.nextElapsedTick(after: F.at(21)))
    }

    // MARK: interrupted turns

    func testAnInterruptedTurnsUnfinishedGroupSaysStoppedAndCountsNoFailureForTheMissingResult() throws {
        let stream = LiveStream([.text(F.prose), F.call(id: "s0", summary: "make a", start: 0), F.result("ok", id: "s0", time: 0.5),
                                 F.call(id: "s1", summary: "make b", start: 1)])
        let group = try stream.group()
        XCTAssertEqual(group.row.summaryField.stringValue, "Running · 1 done · Bash · make b")

        stream.append([stopChip()], complete: true)

        XCTAssertFalse(group.row.stoppedField.isHidden)
        XCTAssertEqual(liveTrimmed(group.row.stoppedField), "· stopped")
        XCTAssertFalse(group.row.isShowingActivity)
        XCTAssertTrue(group.row.badgeField.isHidden, "the call with no result did not fail")
        XCTAssertEqual(group.row.summaryField.stringValue, "Ran 2 commands")
        XCTAssertFalse(group.isExpanded, "stopping does not open the group")
        XCTAssertEqual(stream.autoOpened, [])
    }

    func testAnInterruptedTurnBuiltFreshShowsTheSameStoppedRow() throws {
        let stream = LiveStream([F.call(id: "s0", summary: "make a", start: 0), F.result("ok", id: "s0", time: 0.5),
                                 F.call(id: "s1", summary: "make b", start: 1), stopChip()], complete: true)
        let group = try stream.group()

        XCTAssertEqual(liveTrimmed(group.row.stoppedField), "· stopped")
        XCTAssertFalse(group.isExpanded)
    }

    func testAnInterruptedTurnWhoseCallsAllFinishedIsNotStopped() throws {
        let stream = LiveStream(F.run(2) + [stopChip()], complete: true)
        let group = try stream.group()

        XCTAssertTrue(group.row.stoppedField.isHidden)
    }

    // MARK: stuck-turn auto-open

    func testAFailedGroupStaysClosedWhileTheTurnIsStillRunning() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun() + [.text("moving on")])
        let group = try stream.group()

        XCTAssertEqual(group.group.failedCount, 1)
        XCTAssertFalse(group.isExpanded, "never open while running, whatever failed")
        XCTAssertEqual(stream.autoOpened, [])
    }

    func testTheLastGroupOpensByItselfWhenTheTurnEndsWithAnErrorResult() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun())
        let group = try stream.group()
        XCTAssertFalse(group.isExpanded, "before the turn ends")
        let collapsedHeight = stream.view.islandHeight()

        stream.append([errorChip()], complete: true)

        XCTAssertTrue(group.isExpanded)
        XCTAssertTrue(group.row.isExpanded)
        XCTAssertEqual(group.memberViews.count, 4, "its calls and results are built")
        XCTAssertGreaterThan(stream.view.islandHeight(), collapsedHeight + 50)
        XCTAssertEqual(stream.autoOpened, ["g:s0"], "told once, with the group's key")
        XCTAssertEqual(stream.toggles, [], "an automatic open is not the operator's toggle")
    }

    func testTheLastGroupOpensByItselfWhenTheTurnEndsWithAnErrorMessage() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun())
        let group = try stream.group()

        stream.append([.errorMessage("The agent crashed")], complete: true)

        XCTAssertTrue(group.isExpanded)
        XCTAssertEqual(stream.autoOpened, ["g:s0"])
    }

    func testAutoOpenFiresOnceEvenIfTheCompletedTurnIsUpdatedAgain() throws {
        let stream = LiveStream(failingRun())

        stream.append([errorChip()], complete: true)
        stream.view.update(turn: stream.turn)
        stream.view.update(turn: stream.turn)

        XCTAssertEqual(stream.autoOpened, ["g:s0"])
        XCTAssertTrue(try stream.group().isExpanded)
    }

    func testOnlyTheTurnsLastGroupCanOpenAndItOnlyWhenItHasAFailure() throws {
        let stream = LiveStream(failingRun("a") + [.text("between")] + F.run(2, prefix: "z"))

        stream.append([errorChip()], complete: true)

        XCTAssertFalse(try stream.group(0).isExpanded, "an earlier failed group is not the stuck one")
        XCTAssertFalse(try stream.group(1).isExpanded, "the last group failed nothing")
        XCTAssertEqual(stream.autoOpened, [])
    }

    func testAnAutoOpenNeverClosesAnythingTheOperatorOpened() throws {
        let stream = LiveStream(F.run(2, prefix: "a") + [.text("between")] + failingRun("b"))
        try stream.group(0).row.toggle()
        XCTAssertTrue(try stream.group(0).isExpanded)

        stream.append([errorChip()], complete: true)

        XCTAssertTrue(try stream.group(0).isExpanded, "the operator's open group stays open")
        XCTAssertTrue(try stream.group(1).isExpanded, "the stuck group opened")
    }

    func testAStoppedTurnDoesNotOpenAFailedGroup() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun() + [F.call(id: "s2", summary: "make c", start: 2)])

        stream.append([stopChip()], complete: true)

        let group = try stream.group()
        XCTAssertFalse(group.isExpanded)
        XCTAssertEqual(stream.autoOpened, [])
        XCTAssertEqual(liveTrimmed(group.row.stoppedField), "· stopped")
        XCTAssertEqual(liveTrimmed(group.row.badgeField), "· 1 failed")
    }

    func testACompletedOkTurnLeavesFailedAndUntouchedGroupsClosed() throws {
        let stream = LiveStream(failingRun("a") + [.text("between")] + F.run(3, prefix: "z"))

        stream.append([F.chip()], complete: true)

        XCTAssertFalse(try stream.group(0).isExpanded, "a failure in a turn that finished fine is not stuck")
        XCTAssertFalse(try stream.group(1).isExpanded)
        XCTAssertEqual(stream.autoOpened, [])
    }

    func testAGroupTheOperatorOpenedWhileRunningStaysOpenAfterACleanCompletionAndAnUntouchedOneStaysClosed() throws {
        let stream = LiveStream(F.run(2, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"))
        try stream.group(0).row.toggle()

        stream.append([F.chip()], complete: true)

        XCTAssertTrue(try stream.group(0).isExpanded)
        XCTAssertFalse(try stream.group(1).isExpanded)
        XCTAssertEqual(stream.toggles, ["g:a0=true"], "only the operator's own toggle was reported")
    }

    func testAStuckGroupTheOperatorAlreadyOpenedStaysOpenWithoutAnAutoOpenEvent() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun())
        try stream.group().row.toggle()

        stream.append([errorChip()], complete: true)

        XCTAssertTrue(try stream.group().isExpanded)
        XCTAssertEqual(stream.autoOpened, [], "the operator chose a state for it: nothing to open")
    }

    func testAStuckGroupTheOperatorClosedWhileRunningStaysClosed() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun())
        let group = try stream.group()
        group.row.toggle()   // open
        group.row.toggle()   // close again: an explicit choice
        XCTAssertFalse(group.isExpanded)

        stream.append([errorChip()], complete: true)

        XCTAssertFalse(group.isExpanded, "the operator's closed state beats the stuck rule")
        XCTAssertEqual(stream.autoOpened, [])
    }

    func testAnExplicitClosedChoiceHandedToApplyFoldsKeepsAStuckGroupClosed() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun())
        var state = TurnInteractionState()
        state.groupStates["g:s0"] = false
        _ = stream.view.applyFolds(FoldResolver(state: state))

        stream.append([errorChip()], complete: true)

        XCTAssertFalse(try stream.group().isExpanded)
        XCTAssertEqual(stream.autoOpened, [])
    }

    func testACompletedStuckTurnBuiltFreshRendersItsStuckGroupOpen() throws {
        let stream = LiveStream([.text(F.prose)] + failingRun() + [errorChip()], complete: true)

        let group = try stream.group()

        XCTAssertTrue(group.isExpanded)
        XCTAssertEqual(group.memberViews.count, 4)
    }

    func testACompletedStuckTurnBuiltFreshHonoursAnExplicitClosedChoice() throws {
        var state = TurnInteractionState()
        state.groupStates["g:s0"] = false
        let stream = LiveStream([.text(F.prose)] + failingRun() + [errorChip()], complete: true,
                                interaction: state, folds: FoldResolver(state: state))

        XCTAssertFalse(try stream.group().isExpanded)
    }

    func testAGroupTheStuckRuleOpenedBeforeComesBackOpenWhenItsKeyIsRecordedAsAutomatic() throws {
        // What the pane does when it rebuilds an evicted view: the automatic open was recorded.
        var state = TurnInteractionState()
        state.groupAuto = ["g:a0"]
        let stream = LiveStream(F.run(2, prefix: "a") + [F.chip()], complete: true,
                                interaction: state, folds: FoldResolver(state: state))

        XCTAssertTrue(try stream.group().isExpanded)
    }

    // MARK: applyFolds

    func testApplyFoldsReResolvesEveryGroupWithoutCountingAsAToggleAndReportsWhetherAnythingChanged() throws {
        let stream = LiveStream(F.run(3, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"), complete: true)
        let collapsedHeight = stream.view.islandHeight()

        let opened = stream.view.applyFolds(FoldResolver(expandedByDefault: true))

        XCTAssertTrue(opened)
        XCTAssertTrue(try stream.group(0).isExpanded)
        XCTAssertTrue(try stream.group(1).isExpanded)
        XCTAssertGreaterThan(stream.view.islandHeight(), collapsedHeight + 100, "re-measured at once, no pass needed")
        XCTAssertEqual(stream.toggles, [], "an external change is not the operator's toggle")

        XCTAssertFalse(stream.view.applyFolds(FoldResolver(expandedByDefault: true)), "nothing changed the second time")

        XCTAssertTrue(stream.view.applyFolds(FoldResolver(expandedByDefault: false)))
        XCTAssertFalse(try stream.group(0).isExpanded)
        XCTAssertEqual(stream.view.islandHeight(), collapsedHeight, accuracy: 0.5)
        XCTAssertEqual(stream.toggles, [])
    }

    func testApplyFoldsLetsAnExplicitChoiceBeatTheDefault() throws {
        let stream = LiveStream(F.run(2, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"), complete: true)
        var state = TurnInteractionState()
        state.groupStates["g:a0"] = false

        _ = stream.view.applyFolds(FoldResolver(state: state, expandedByDefault: true))

        XCTAssertFalse(try stream.group(0).isExpanded)
        XCTAssertTrue(try stream.group(1).isExpanded)
    }

    func testApplyFoldsOpensAGroupRecordedAsAutomatic() throws {
        let stream = LiveStream(F.run(2, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"), complete: true)
        var state = TurnInteractionState()
        state.groupAuto = ["g:b0"]

        let changed = stream.view.applyFolds(FoldResolver(state: state))

        XCTAssertTrue(changed)
        XCTAssertFalse(try stream.group(0).isExpanded)
        XCTAssertTrue(try stream.group(1).isExpanded)
    }

    // MARK: settling

    func testAGroupSettlesWhenProseFollowsItAndNotBefore() throws {
        let stream = LiveStream([.text(F.prose)])

        stream.append([F.call(id: "a", summary: "ls", start: 0)])
        stream.append([F.result("ok", id: "a", time: 1)])
        stream.append([F.call(id: "b", summary: "pwd", start: 2)])
        stream.append([F.result("ok", id: "b", time: 3)])
        XCTAssertEqual(stream.settled.count, 0, "another call could still join the group")

        stream.append([.text("All done.")])

        XCTAssertEqual(stream.settled.count, 1)
        XCTAssertEqual(stream.settled.first?.key, "g:a")
        XCTAssertEqual(stream.settled.first?.state, .settled)
        XCTAssertEqual(stream.settled.first?.callCount, 2)
        XCTAssertEqual(stream.settled.first?.finishedCount, 2)
    }

    func testAGroupSettlesWhenAnotherKindOfItemFollowsIt() {
        let stream = LiveStream(F.run(2))

        stream.append([F.question()])

        XCTAssertEqual(stream.settled.count, 1)
    }

    func testAGroupSettlesWhenTheTurnEnds() {
        let stream = LiveStream(failingRun())
        XCTAssertEqual(stream.settled.count, 0)

        stream.append([], complete: true)

        XCTAssertEqual(stream.settled.count, 1)
        XCTAssertEqual(stream.settled.first?.failedCount, 1)
        XCTAssertEqual(stream.settled.first?.state, .settled)
    }

    func testAGroupSettlesOnlyOnceHoweverMuchStreamsAfterIt() {
        let stream = LiveStream(F.run(2, prefix: "a"))
        stream.append([.text("one")])
        stream.append([.text("two")])
        stream.append([F.chip()])
        stream.append([], complete: true)
        stream.view.update(turn: stream.turn)

        XCTAssertEqual(stream.settled.count, 1)
    }

    func testEachGroupOfATurnSettlesInItsTurn() {
        let stream = LiveStream(F.run(1, prefix: "a"))

        stream.append([.text("between")])
        stream.append(F.run(2, prefix: "b"))
        XCTAssertEqual(stream.settled.map(\.key), ["g:a0"])
        stream.append([.text("after")])

        XCTAssertEqual(stream.settled.map(\.key), ["g:a0", "g:b0"])
    }

    func testAStoppedGroupIsHandedOverWithItsStoppedState() {
        let stream = LiveStream([F.call(id: "s0", summary: "make a", start: 0)])

        stream.append([stopChip()], complete: true)

        XCTAssertEqual(stream.settled.count, 1)
        XCTAssertEqual(stream.settled.first?.state, .stopped)
    }

    func testGroupsAlreadySettledWhenTheViewWasBuiltAreNeverReported() {
        let stream = LiveStream(failingRun("a") + [.text("between")] + F.run(1, prefix: "b"))

        stream.append([.text("later")])

        XCTAssertEqual(stream.settled.map(\.key), ["g:b0"], "only the group that settled while this view was live")
    }

    func testAViewBuiltFromACompleteTurnReportsNothing() {
        let stream = LiveStream(failingRun() + [errorChip()], complete: true)

        stream.view.update(turn: stream.turn)

        XCTAssertEqual(stream.settled.count, 0)
    }
}

// MARK: - The elapsed-time ticker

/// A scheduler with simulated time. `schedule` returns a cancel closure; `advance` runs due
/// timers in order, moving the shared clock to each one's due time as it fires.
private final class FakeScheduler {
    private struct Timer {
        let id: Int
        let due: Date
        let fire: () -> Void
    }

    private let clock: LiveClock
    private var timers: [Timer] = []
    private var nextID = 0
    private(set) var scheduledDelays: [TimeInterval] = []

    init(_ clock: LiveClock) { self.clock = clock }

    /// One-shots waiting to fire (cancelled ones are gone).
    var pendingCount: Int { timers.count }

    func schedule(_ delay: TimeInterval, _ fire: @escaping () -> Void) -> () -> Void {
        let id = nextID
        nextID += 1
        timers.append(Timer(id: id, due: clock.now.addingTimeInterval(delay), fire: fire))
        scheduledDelays.append(delay)
        return { [weak self] in self?.timers.removeAll { $0.id == id } }
    }

    /// Run time forward to `end`; returns the times the timers fired at.
    @discardableResult
    func advance(to end: Date) -> [Date] {
        var fired: [Date] = []
        while let next = timers.filter({ $0.due <= end }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            clock.now = max(clock.now, next.due)
            fired.append(clock.now)
            next.fire()
        }
        clock.now = max(clock.now, end)
        return fired
    }
}

final class ElapsedTickerTests: XCTestCase {

    private struct Setup {
        let clock: LiveClock
        let scheduler: FakeScheduler
        let ticker: ElapsedTicker
    }

    /// A ticker over `islands`, with one simulated clock shared by the views and the scheduler.
    private func makeTicker(clock: LiveClock, _ islands: @escaping () -> [ElapsedTicking]) -> Setup {
        let scheduler = FakeScheduler(clock)
        let ticker = ElapsedTicker(now: { clock.now }, schedule: { scheduler.schedule($0, $1) })
        ticker.islands = islands
        return Setup(clock: clock, scheduler: scheduler, ticker: ticker)
    }

    /// A turn running a call that started at t=0 (`started`), on a clock reading `now` seconds.
    private func runningStream(now: Double = 2, started: Double? = 0) -> (LiveStream, LiveClock) {
        let clock = LiveClock(F.at(now))
        let stream = LiveStream([.text(F.prose), F.call(id: "c0", summary: "cargo test", start: started)], clock: clock)
        return (stream, clock)
    }

    func testNothingIsScheduledWhileNoCallIsRunning() {
        let clock = LiveClock(F.at(5))
        let proseOnly = LiveStream([.text(F.prose)], clock: clock)
        let settled = LiveStream(F.run(2), complete: true, clock: clock)
        let (unknownStart, _) = runningStream(now: 5, started: nil)
        for stream in [proseOnly, settled, unknownStart] {
            let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }

            setup.ticker.reevaluate()

            XCTAssertFalse(setup.ticker.isScheduled)
            XCTAssertEqual(setup.scheduler.pendingCount, 0)
            XCTAssertTrue(setup.scheduler.scheduledDelays.isEmpty)
        }
    }

    func testNothingIsScheduledForAPaneWithNoTurnViews() {
        let setup = makeTicker(clock: LiveClock(F.at(5))) { () -> [ElapsedTicking] in [] }

        setup.ticker.reevaluate()

        XCTAssertFalse(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 0)
    }

    func testARunningCallSchedulesOneTickForTheMomentItReachesTenSeconds() throws {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }

        setup.ticker.reevaluate()

        XCTAssertTrue(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 1)
        XCTAssertEqual(try XCTUnwrap(setup.scheduler.scheduledDelays.last), 8, accuracy: 0.05)
    }

    func testReevaluatingAgainAndAgainNeverLeavesMoreThanOneTickPending() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }

        for _ in 0 ..< 5 { setup.ticker.reevaluate() }

        XCTAssertEqual(setup.scheduler.pendingCount, 1)
    }

    func testTicksLandOnTheWholeSecondsAndOverAnyFiveSecondsFireAtMostFiveTimes() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.reevaluate()

        let first = setup.scheduler.advance(to: F.at(10))
        XCTAssertEqual(first.count, 1, "the first tick is the moment the call reaches 10 s")

        let fired = setup.scheduler.advance(to: F.at(15))

        XCTAssertLessThanOrEqual(fired.count, 5, "at most one tick per second")
        XCTAssertEqual(fired.map { $0.timeIntervalSince(F.epoch) }, [11, 12, 13, 14, 15])
        XCTAssertEqual(setup.ticker.fireCount, first.count + fired.count)
        XCTAssertEqual(setup.scheduler.pendingCount, 1, "the next one is already waiting")
        XCTAssertTrue(setup.ticker.isScheduled)
    }

    func testEachTickRefreshesTheRunningRowsElapsedTime() throws {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        let row = try stream.group().row
        setup.ticker.reevaluate()
        XCTAssertTrue(row.timeField.isHidden)

        setup.scheduler.advance(to: F.at(10))
        XCTAssertEqual(liveTrimmed(row.timeField), "· 10 s")

        setup.scheduler.advance(to: F.at(13))
        XCTAssertEqual(liveTrimmed(row.timeField), "· 13 s")
    }

    func testNothingStaysScheduledOnceTheGroupSettles() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.reevaluate()
        XCTAssertEqual(setup.scheduler.pendingCount, 1)

        stream.append([F.result("ok", id: "c0", time: 3)])
        setup.ticker.reevaluate()

        XCTAssertFalse(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 0)
    }

    func testATickThatFiresAfterTheGroupSettledSchedulesNothingFurther() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.reevaluate()
        stream.append([F.result("ok", id: "c0", time: 3)])

        setup.scheduler.advance(to: F.at(30))

        XCTAssertEqual(setup.scheduler.pendingCount, 0)
        XCTAssertFalse(setup.ticker.isScheduled)
    }

    func testNothingStaysScheduledOnceTheTurnCompletes() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.reevaluate()

        stream.append([F.chip()], complete: true)
        setup.ticker.reevaluate()

        XCTAssertFalse(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 0)
    }

    func testNothingStaysScheduledOnceTheViewIsEvicted() {
        let (stream, clock) = runningStream()
        var evicted = false
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in evicted ? [] : [stream.view] }
        setup.ticker.reevaluate()
        XCTAssertTrue(setup.ticker.isScheduled)

        evicted = true
        setup.ticker.reevaluate()

        XCTAssertFalse(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 0)
    }

    func testStoppingCancelsTheTickAndNothingFiresAfterwards() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.reevaluate()

        setup.ticker.stop()

        XCTAssertFalse(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 0)
        XCTAssertEqual(setup.scheduler.advance(to: F.at(60)), [])
        XCTAssertEqual(setup.ticker.fireCount, 0)
    }

    func testAShownPaneCanScheduleAgainAfterBeingStopped() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.reevaluate()
        setup.ticker.stop()

        setup.ticker.reevaluate()

        XCTAssertTrue(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 1)
    }
}

// MARK: - Focus

final class ToolGroupLiveFocusTests: XCTestCase {

    /// The pane the announcer and the focus tests use: a container holding the transcript's
    /// scroll view and a composer, with an unrelated text view outside it.
    private final class LivePane {
        static let width: CGFloat = 700
        let window: NSWindow
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 40, width: 700, height: 460))
        let doc = RigFlippedDoc(frame: NSRect(x: 0, y: 0, width: 700, height: 460))
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 36))
        let outside = NSTextView(frame: NSRect(x: 0, y: 520, width: 200, height: 30))
        let view: ChatTurnView

        init(window: NSWindow, turn: ChatTurn, clock: LiveClock) {
            self.window = window
            self.view = makeLive(turn, clock)
            scroll.documentView = doc
            pane.addSubview(scroll)
            pane.addSubview(composer)
            doc.addSubview(view)
            window.contentView!.addSubview(pane)
            window.contentView!.addSubview(outside)
            relayout()
        }

        func relayout() {
            view.setIslandWidth(Self.width)
            let height = view.islandHeight()
            view.setFrameSize(NSSize(width: Self.width, height: height))
            doc.setFrameSize(NSSize(width: Self.width, height: max(height, 460)))
            window.contentView!.layoutSubtreeIfNeeded()
        }
    }

    func testSixtyLiveCallUpdatesAndAnAutoOpenLeaveTheComposerTheFirstResponder() throws {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        var turn = F.turn([.text(F.prose)], complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.composer))

        let blocks = F.run(59, prefix: "f") + [F.call(id: "f59", summary: "cargo test", start: 59),
                                               F.result("exit 101", id: "f59", isError: true, time: 60)]
        for (n, block) in blocks.enumerated() {
            turn.blocks.append(block)
            live.view.update(turn: turn)
            if n % 10 == 0 { live.relayout() }
        }
        live.relayout()
        rigSettle()

        XCTAssertTrue(window.firstResponder === live.composer, "live updates took focus: \(String(describing: window.firstResponder))")
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: window.firstResponder,
                                                             inputTextView: live.composer, transcript: live.scroll))

        turn.blocks.append(errorChip())
        turn.isComplete = true
        live.view.update(turn: turn)
        live.relayout()
        rigSettle()

        let group = try XCTUnwrap(liveGroupViews(in: live.view).first)
        XCTAssertTrue(group.isExpanded, "the stuck group opened")
        XCTAssertTrue(window.firstResponder === live.composer, "the auto-open took focus: \(String(describing: window.firstResponder))")
        XCTAssertTrue(TranscriptFocusPolicy.shouldFocusInput(currentFirstResponder: window.firstResponder,
                                                             inputTextView: live.composer, transcript: live.scroll))
    }

    // MARK: Announcement (VoiceOver)

    private func makeNonKeyWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        return window
    }

    /// Stream a call that fails, then prose that settles its group, into `live`.
    private func streamFailureThenProse(into live: LivePane, turn: inout ChatTurn) {
        for block in [F.call(id: "f0", summary: "make", start: 0), F.result("exit 1", id: "f0", isError: true, time: 1)] {
            turn.blocks.append(block)
            live.view.update(turn: turn)
        }
        turn.blocks.append(.text("That failed; trying another way."))
        live.view.update(turn: turn)
    }

    func testAFailedGroupSettlingInAFocusedPaneIsAnnouncedExactlyOnce() {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        var turn = F.turn([.text(F.prose)], complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.composer))
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        live.view.onGroupSettled = { announcer.groupSettled($0, in: live.pane) }

        for block in [F.call(id: "f0", summary: "make", start: 0), F.result("exit 1", id: "f0", isError: true, time: 1)] {
            turn.blocks.append(block)
            live.view.update(turn: turn)
            XCTAssertEqual(posted, [], "per-call updates announce nothing")
        }
        turn.blocks.append(.text("That failed; trying another way."))
        live.view.update(turn: turn)

        XCTAssertEqual(posted, ["Tool activity finished, 1 failed call"])

        turn.blocks.append(.text("More prose."))
        live.view.update(turn: turn)
        XCTAssertEqual(posted.count, 1, "once per group")
    }

    func testTheAnnouncementCountsEveryFailedCall() {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        var turn = F.turn([.text(F.prose)], complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.composer))
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        live.view.onGroupSettled = { announcer.groupSettled($0, in: live.pane) }

        for i in 0 ..< 2 {
            turn.blocks.append(F.call(id: "f\(i)", summary: "make \(i)", start: Double(i)))
            turn.blocks.append(F.result("exit 1", id: "f\(i)", isError: true, time: Double(i) + 0.5))
        }
        turn.blocks.append(.text("Both failed."))
        live.view.update(turn: turn)

        XCTAssertEqual(posted, ["Tool activity finished, 2 failed calls"])
    }

    func testAGroupWithNoFailuresIsNotAnnounced() {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        var turn = F.turn(F.run(3), complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.composer))
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        live.view.onGroupSettled = { announcer.groupSettled($0, in: live.pane) }

        turn.blocks.append(.text("All good."))
        live.view.update(turn: turn)

        XCTAssertEqual(posted, [])
    }

    func testAFailedGroupSettlingInAnUnfocusedPaneIsNotAnnounced() {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        var turn = F.turn([.text(F.prose)], complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.outside), "focus is somewhere outside the pane")
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        live.view.onGroupSettled = { announcer.groupSettled($0, in: live.pane) }

        streamFailureThenProse(into: live, turn: &turn)

        XCTAssertEqual(posted, [])
    }

    func testAFailedGroupSettlingInAWindowThatIsNotKeyIsNotAnnounced() {
        let clock = LiveClock(F.at(0))
        let window = makeNonKeyWindow()
        var turn = F.turn([.text(F.prose)], complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        _ = window.makeFirstResponder(live.composer)
        XCTAssertFalse(window.isKeyWindow, "precondition: this window is not key")
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        live.view.onGroupSettled = { announcer.groupSettled($0, in: live.pane) }

        streamFailureThenProse(into: live, turn: &turn)

        XCTAssertEqual(posted, [])
    }

    func testAStoppedGroupWithAFailureIsNotAnnounced() {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        var turn = F.turn([F.call(id: "f0", summary: "make", start: 0), F.result("exit 1", id: "f0", isError: true, time: 1),
                           F.call(id: "f1", summary: "make more", start: 2)], complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.composer))
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        var settledStates: [ToolGroup.State] = []
        live.view.onGroupSettled = { settledStates.append($0.state); announcer.groupSettled($0, in: live.pane) }

        turn.blocks.append(stopChip())
        turn.isComplete = true
        live.view.update(turn: turn)

        XCTAssertEqual(settledStates, [.stopped], "the view reports the stopped group")
        XCTAssertEqual(posted, [])
    }

    func testAViewBuiltFromAnAlreadyCompleteTurnAnnouncesNothing() {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        let turn = F.turn(failingRun() + [errorChip()], complete: true)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.composer))
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        live.view.onGroupSettled = { announcer.groupSettled($0, in: live.pane) }

        live.view.update(turn: turn)
        live.relayout()

        XCTAssertEqual(posted, [])
    }

    func testAGroupThatSettledBeforeTheViewWasBuiltIsNeverAnnounced() {
        let clock = LiveClock(F.at(0))
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        var turn = F.turn(failingRun() + [.text("moving on")], complete: false)
        let live = LivePane(window: window, turn: turn, clock: clock)
        XCTAssertTrue(window.makeFirstResponder(live.composer))
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        live.view.onGroupSettled = { announcer.groupSettled($0, in: live.pane) }

        turn.blocks.append(.text("still going"))
        live.view.update(turn: turn)

        XCTAssertEqual(posted, [])
    }

    // MARK: paneHasFocus

    func testAPaneHasFocusWhenAViewInsideItIsFirstResponderInTheKeyWindow() {
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        let live = LivePane(window: window, turn: F.turn([.text(F.prose)], complete: false), clock: LiveClock(F.at(0)))

        XCTAssertTrue(window.makeFirstResponder(live.composer))
        XCTAssertTrue(ToolActivityAnnouncer.paneHasFocus(live.pane))

        XCTAssertTrue(window.makeFirstResponder(live.outside))
        XCTAssertFalse(ToolActivityAnnouncer.paneHasFocus(live.pane), "focus moved outside the pane")
    }

    func testAFieldEditorCountsThroughItsDelegate() throws {
        let window = makeRigWindow(self, size: NSSize(width: 800, height: 600))
        let live = LivePane(window: window, turn: F.turn([.text(F.prose)], complete: false), clock: LiveClock(F.at(0)))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.isEditable = true
        live.pane.addSubview(field)
        try XCTSkipUnless(window.makeFirstResponder(field), "this process cannot start a field editor")
        try XCTSkipUnless((window.firstResponder as? NSTextView)?.isFieldEditor == true, "no field editor is installed")

        XCTAssertTrue(ToolActivityAnnouncer.paneHasFocus(live.pane), "the editor's delegate is the field, which is in the pane")

        XCTAssertTrue(window.makeFirstResponder(live.outside))
        XCTAssertFalse(ToolActivityAnnouncer.paneHasFocus(live.pane))
    }

    func testAPaneInAWindowThatIsNotKeyHasNoFocus() {
        let window = makeNonKeyWindow()
        let live = LivePane(window: window, turn: F.turn([.text(F.prose)], complete: false), clock: LiveClock(F.at(0)))
        _ = window.makeFirstResponder(live.composer)

        XCTAssertFalse(ToolActivityAnnouncer.paneHasFocus(live.pane))
    }
}

// MARK: - Fold resolution with automatic opens

final class FoldResolverAutoOpenTests: XCTestCase {

    private func group(stuck: Bool) -> ToolGroup {
        F.group([F.foldCall("Bash", id: "x", summary: "make"), F.foldResult(id: "x", isError: true)],
                outcome: stuck ? .completedError : .completedOk)
    }

    func testTheFixtureGroupsAreStuckAndNotStuckAsNamed() {
        XCTAssertTrue(group(stuck: true).isStuck)
        XCTAssertFalse(group(stuck: false).isStuck)
        XCTAssertEqual(group(stuck: true).key, "g:x")
    }

    func testAStuckGroupOpensByItself() {
        XCTAssertTrue(FoldResolver(state: TurnInteractionState()).isExpanded(group(stuck: true)))
        XCTAssertFalse(FoldResolver(state: TurnInteractionState()).isExpanded(group(stuck: false)))
    }

    func testAGroupRecordedAsAutomaticOpensEvenWhenNotStuck() {
        var state = TurnInteractionState()
        state.groupAuto = ["g:x"]

        XCTAssertTrue(FoldResolver(state: state).isExpanded(group(stuck: false)))
        XCTAssertFalse(FoldResolver(state: state).isExpanded(key: "g:other", isStuck: false))
    }

    func testAnExplicitChoiceBeatsBothAutomaticRules() {
        var state = TurnInteractionState()
        state.groupAuto = ["g:x"]
        state.groupStates["g:x"] = false

        XCTAssertFalse(FoldResolver(state: state).isExpanded(group(stuck: true)))
        XCTAssertFalse(FoldResolver(state: state, expandedByDefault: true).isExpanded(group(stuck: false)))
    }

    func testAnExplicitOpenChoiceOpensAGroupNothingElseWouldOpen() {
        var state = TurnInteractionState()
        state.groupStates["g:x"] = true

        XCTAssertTrue(FoldResolver(state: state).isExpanded(group(stuck: false)))
    }

    func testWithNoChoiceAndNoAutomaticReasonTheDefaultDecides() {
        XCTAssertFalse(FoldResolver(expandedByDefault: false).isExpanded(group(stuck: false)))
        XCTAssertTrue(FoldResolver(expandedByDefault: true).isExpanded(group(stuck: false)))
    }

    func testTheKeyAndStuckFormAgreesWithTheGroupForm() {
        var state = TurnInteractionState()
        let resolver = FoldResolver(state: state)
        XCTAssertTrue(resolver.isExpanded(key: "g:x", isStuck: true))
        XCTAssertFalse(resolver.isExpanded(key: "g:x", isStuck: false))

        state.groupStates["g:x"] = false
        XCTAssertFalse(FoldResolver(state: state).isExpanded(key: "g:x", isStuck: true))
    }

    func testAResolverBuiltFromAStateCarriesItsAutomaticKeys() {
        var state = TurnInteractionState()
        state.groupAuto = ["g:a", "g:b"]

        XCTAssertEqual(FoldResolver(state: state).groupAuto, ["g:a", "g:b"])
    }

    // MARK: state and store

    func testAStateWithOnlyAutomaticKeysIsNotEmpty() {
        var state = TurnInteractionState()
        XCTAssertTrue(state.isEmpty)

        state.groupAuto = ["g:a"]

        XCTAssertFalse(state.isEmpty)
    }

    func testTheStoreRecordsAutomaticOpensPerTurnAndKeepsThemBesideOtherState() {
        let store = TurnInteractionStore()
        let turn = UUID()
        let other = UUID()

        store.recordAuto(turn: turn, key: "g:a")
        store.recordAuto(turn: turn, key: "g:b")
        store.setGroup(turn: turn, key: "g:c", false)
        store.setExpanded(turn: turn, block: 3, true)
        store.setExpanded(turn: turn, block: 3, false)

        XCTAssertEqual(store.state(for: turn).groupAuto, ["g:a", "g:b"])
        XCTAssertEqual(store.state(for: turn).groupStates, ["g:c": false])
        XCTAssertTrue(store.state(for: other).groupAuto.isEmpty)
        XCTAssertEqual(store.trackedTurnCount, 1)
    }

    func testAnAutomaticOpenKeepsATurnTrackedUntilItIsPrunedOrCleared() {
        let store = TurnInteractionStore()
        let turn = UUID()
        store.recordAuto(turn: turn, key: "g:a")
        store.setExpanded(turn: turn, block: 1, true)
        store.setExpanded(turn: turn, block: 1, false)
        XCTAssertEqual(store.trackedTurnCount, 1, "the automatic key is still state")

        store.prune(keeping: [])
        XCTAssertEqual(store.trackedTurnCount, 0)

        store.recordAuto(turn: turn, key: "g:a")
        store.removeAll()
        XCTAssertTrue(store.state(for: turn).groupAuto.isEmpty)
    }

    func testTheFoldDigestChangesWhenAnAutomaticKeyIsRecorded() {
        let turn = F.turn(F.run(3), complete: true)
        let plain = TurnInteractionState()
        var automatic = TurnInteractionState()
        automatic.groupAuto = ["g:t0"]

        XCTAssertNotEqual(ToolFoldAdapter.foldDigest(turn: turn, state: plain, expandedByDefault: false),
                          ToolFoldAdapter.foldDigest(turn: turn, state: automatic, expandedByDefault: false),
                          "a height measured with the group closed must not be reused once it is open")
    }
}

// MARK: - Opening a big group is cheap (TF3 addendum)

/// Collects the closures a `ToolGroupView` hands to `scheduleBatch`, so a test runs the member
/// batches one at a time instead of on the main queue.
private final class BatchCollector {
    private var queue: [() -> Void] = []
    private(set) var batchesRun = 0

    func schedule(_ work: @escaping () -> Void) { queue.append(work) }
    var pendingCount: Int { queue.count }

    @discardableResult
    func runNext() -> Bool {
        guard !queue.isEmpty else { return false }
        queue.removeFirst()()
        batchesRun += 1
        return true
    }

    /// Run batches until none is left (each may schedule the next). Returns how many ran.
    @discardableResult
    func drain(limit: Int = 30) -> Int {
        var ran = 0
        while ran < limit, runNext() { ran += 1 }
        return ran
    }
}

private func liveTextFields(in view: NSView) -> [NSTextField] {
    rigAllSubviews(of: view).compactMap { $0 as? NSTextField }
}

/// Calls the group's members are expected to show, in block order, as the summaries `F.run` writes.
private func callSummaries(of group: ToolGroupView) -> [String] {
    group.memberViews.compactMap { member in
        guard member is ToolCallView else { return nil }
        return liveTextFields(in: member).map(\.stringValue).first { $0.hasPrefix("cmd ") }
    }
}

final class ToolGroupExpandCostTests: XCTestCase {

    private let sixty: [TurnBlock] = [.text(F.prose)] + F.run(60) + [.text("after")]

    /// A completed turn holding one 60-call group (`g:t0`, 120 members), the group's view with its
    /// batches collected, and the collector.
    private func makeFixture(_ blocks: [TurnBlock]? = nil, complete: Bool = true) throws -> (LiveStream, ToolGroupView, BatchCollector) {
        let stream = LiveStream(blocks ?? sixty, complete: complete)
        let group = try XCTUnwrap(stream.view.groupView(forKey: "g:t0"))
        let collector = BatchCollector()
        group.scheduleBatch = { collector.schedule($0) }
        return (stream, group, collector)
    }

    private func batchesNeeded(members: Int) -> Int {
        let size = ToolGroupView.memberBatchSize
        return Int((Double(max(0, members - size)) / Double(size)).rounded(.up))
    }

    // MARK: the click

    func testClickingASixtyCallGroupOpenBuildsOnlyAFirstBatchOfMembers() throws {
        let (stream, group, collector) = try makeFixture()
        XCTAssertEqual(group.group.memberIndices.count, 120)
        XCTAssertEqual(group.memberViews.count, 0, "nothing is built while collapsed")
        #if DEBUG
        let measuredBefore = ChatTurnView.measureIslandCount
        #endif

        group.row.toggle()

        XCTAssertTrue(group.isExpanded)
        XCTAssertGreaterThan(group.memberViews.count, 0)
        XCTAssertLessThanOrEqual(group.memberViews.count, ToolGroupView.memberBatchSize)
        XCTAssertFalse(group.isFullyBuilt)
        XCTAssertGreaterThanOrEqual(collector.pendingCount, 1, "the rest is queued, not built")
        XCTAssertEqual(stream.toggles, ["g:t0=true"])
        #if DEBUG
        XCTAssertLessThanOrEqual(ChatTurnView.measureIslandCount - measuredBefore, ToolGroupView.memberBatchSize + 2,
                                 "the click measured more than a batch of members")
        #endif
    }

    func testTheBenchmarksSixtyCallGroupOpensWithAtMostABatchOfMembersToo() throws {
        let turn = try F.benchmarkTurns().first { F.groups(of: $0).contains { $0.callCount == 60 } }
        let big = try XCTUnwrap(turn, "the benchmark has no 60-call group")
        let key = try XCTUnwrap(F.groups(of: big).first { $0.callCount == 60 }?.key)
        let view = makeLive(big, LiveClock(F.at(0)))
        let group = try XCTUnwrap(view.groupView(forKey: key))
        let collector = BatchCollector()
        group.scheduleBatch = { collector.schedule($0) }
        XCTAssertGreaterThan(group.group.memberIndices.count, ToolGroupView.memberBatchSize)

        group.row.toggle()

        XCTAssertLessThanOrEqual(group.memberViews.count, ToolGroupView.memberBatchSize)
        XCTAssertFalse(group.isFullyBuilt)
        collector.drain()
        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(collector.pendingCount, 0)
    }

    // MARK: the batches

    func testTheBatchesBuildTheRestInAFewStepsAndThenStop() throws {
        let (stream, group, collector) = try makeFixture()
        group.row.toggle()
        var changes = 0
        stream.view.onIntrinsicHeightChange = { changes += 1 }
        let allowed = batchesNeeded(members: group.group.memberIndices.count)
        var built = group.memberViews.count

        var batches = 0
        while collector.runNext() {
            batches += 1
            XCTAssertLessThanOrEqual(batches, allowed, "more batches than members left to build")
            XCTAssertGreaterThan(group.memberViews.count, built, "batch \(batches) built nothing")
            XCTAssertLessThanOrEqual(group.memberViews.count - built, ToolGroupView.memberBatchSize)
            built = group.memberViews.count
            XCTAssertEqual(changes, batches, "each batch tells the turn its height changed")
        }

        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(group.memberViews.count, group.group.memberIndices.count)
        XCTAssertEqual(collector.pendingCount, 0, "no further batch is scheduled")
        XCTAssertEqual(callSummaries(of: group), (0 ..< 60).map { "cmd t\($0)" }, "members are in block order")
    }

    func testAfterTheLastBatchTheTurnIsTheHeightOfOneBuiltOpenFromTheStart() throws {
        let (stream, group, collector) = try makeFixture()
        var open = TurnInteractionState()
        open.groupStates["g:t0"] = true
        let fresh = makeLive(stream.turn, LiveClock(F.at(0)), interaction: open, folds: FoldResolver(state: open))
        let expected = fresh.islandHeight()
        let collapsed = stream.view.islandHeight()

        group.row.toggle()
        let firstPass = stream.view.islandHeight()
        collector.drain()

        XCTAssertEqual(stream.view.islandHeight(), expected, accuracy: 0.5, "estimates were fully replaced by measurements")
        XCTAssertGreaterThan(firstPass, collapsed + (expected - collapsed) * 0.75,
                             "the first pass was already about the final height (\(firstPass) vs \(expected))")
        XCTAssertLessThan(firstPass, expected + (expected - collapsed) * 0.25)
    }

    func testAGroupExpandedWhenItsViewIsBuiltBuildsEveryMemberAtOnce() throws {
        var open = TurnInteractionState()
        open.groupStates["g:t0"] = true
        let stream = LiveStream(sixty, complete: true, interaction: open, folds: FoldResolver(state: open))

        let group = try stream.group()

        XCTAssertTrue(group.isExpanded)
        XCTAssertTrue(group.isFullyBuilt, "no batching when the group starts open")
        XCTAssertEqual(group.memberViews.count, 120)
    }

    func testAGroupOpenedByTheDefaultIsBuiltWholeToo() throws {
        let stream = LiveStream(sixty, complete: true, folds: FoldResolver(expandedByDefault: true))

        XCTAssertTrue(try stream.group().isFullyBuilt)
        XCTAssertEqual(try stream.group().memberViews.count, 120)
    }

    func testASmallGroupOpensWhole() throws {
        let stream = LiveStream([.text(F.prose)] + F.run(5) + [.text("after")], complete: true)
        let group = try stream.group()
        let collector = BatchCollector()
        group.scheduleBatch = { collector.schedule($0) }

        group.row.toggle()

        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(group.memberViews.count, 10)
        XCTAssertEqual(collector.pendingCount, 0, "nothing was left to batch")
    }

    // MARK: closing and reopening mid-build

    func testClosingWhileABatchIsPendingBuildsNothingMoreAndReopeningCarriesOn() throws {
        let (_, group, collector) = try makeFixture()
        group.row.toggle()
        let firstBatch = group.memberViews
        XCTAssertGreaterThanOrEqual(collector.pendingCount, 1)

        group.row.toggle()   // close
        collector.drain()

        XCTAssertFalse(group.isExpanded)
        XCTAssertEqual(group.memberViews.count, firstBatch.count, "a pending batch must not build into a closed group")
        XCTAssertEqual(collector.pendingCount, 0, "and does not keep itself alive")

        group.row.toggle()   // reopen
        XCTAssertTrue(group.isExpanded)
        XCTAssertGreaterThanOrEqual(group.memberViews.count, firstBatch.count)
        collector.drain()

        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(group.memberViews.count, 120)
        XCTAssertTrue(zip(firstBatch, group.memberViews).allSatisfy { $0 === $1 }, "what was built is kept, not rebuilt")
        XCTAssertEqual(callSummaries(of: group), (0 ..< 60).map { "cmd t\($0)" })
    }

    func testAGroupClosedBeforeItsFirstBatchRunsHoldsNoStrayWork() throws {
        let (_, group, collector) = try makeFixture()
        group.row.toggle()
        group.row.toggle()
        group.row.toggle()   // open again before the first batch ran

        collector.drain()

        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(group.memberViews.count, 120, "no member was built twice")
    }

    // MARK: streaming into a group that is still building

    func testBlocksStreamedIntoAnOpenGroupThatIsStillBuildingAreBuiltInOrderAfterTheDrain() throws {
        let (stream, group, collector) = try makeFixture([.text(F.prose)] + F.run(60), complete: false)
        group.row.toggle()
        XCTAssertFalse(group.isFullyBuilt)
        XCTAssertGreaterThanOrEqual(collector.pendingCount, 1)

        stream.append([F.call(id: "n0", summary: "cmd zz"), F.result("ok", id: "n0")])
        XCTAssertEqual(group.group.memberIndices.count, 122, "the group grew")
        XCTAssertFalse(group.isFullyBuilt, "the arrival did not build ahead of the batches")
        collector.drain()

        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(group.memberViews.count, 122)
        XCTAssertEqual(callSummaries(of: group), (0 ..< 60).map { "cmd t\($0)" } + ["cmd zz"], "in block order")
        let kinds = group.memberViews.map { $0 is ToolCallView ? "call" : ($0 is ToolResultView ? "result" : "other") }
        XCTAssertEqual(kinds, Array(repeating: ["call", "result"], count: 61).flatMap { $0 })
    }

    func testBlocksStreamedIntoAFullyBuiltOpenGroupAreBuiltAtOnce() throws {
        let (stream, group, collector) = try makeFixture([.text(F.prose)] + F.run(10), complete: false)
        group.row.toggle()
        collector.drain()
        XCTAssertTrue(group.isFullyBuilt)

        stream.append([F.call(id: "n0", summary: "cmd zz"), F.result("ok", id: "n0")])

        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(group.memberViews.count, 22)
    }
}

// MARK: - Reading order

/// `ChatTurnView.subviews` is VoiceOver's reading order: the bubble, then the columns in
/// display order. Re-measuring one column must not move it to the end.
final class ChatTurnViewReadingOrderTests: XCTestCase {

    private func order(_ view: ChatTurnView) -> [ObjectIdentifier] { view.subviews.map(ObjectIdentifier.init) }

    func testExpandingAGroupInTheMiddleOfATurnKeepsTheColumnsInDisplayOrder() throws {
        let blocks: [TurnBlock] = [.text("Before. \(F.prose)")] + F.run(3, prefix: "a") + [.text("Between. \(F.prose)")]
            + F.run(2, prefix: "b") + [.text("After. \(F.prose)")]
        let view = makeLive(F.turn(blocks), LiveClock(F.at(0)))
        let before = order(view)
        XCTAssertTrue(view.subviews.first is UserBubbleView)
        let middle = try XCTUnwrap(view.groupView(forKey: "g:a0"))

        middle.row.toggle()

        XCTAssertEqual(order(view), before, "the re-measured column moved within subviews")
        XCTAssertTrue(view.subviews.first is UserBubbleView)
        XCTAssertTrue(view.subviews.last is TextBlockView, "the closing prose is still last")

        middle.row.toggle()
        XCTAssertEqual(order(view), before, "collapsing it again")
    }

    func testClosingAndOpeningEveryGroupLeavesTheOrderAlone() throws {
        let blocks: [TurnBlock] = F.run(2, prefix: "a") + [.text("Between. \(F.prose)")] + F.run(2, prefix: "b")
            + [.text("Then. \(F.prose)")] + F.run(2, prefix: "c")
        let view = makeLive(F.turn(blocks), LiveClock(F.at(0)))
        let before = order(view)

        for key in ["g:a0", "g:b0", "g:c0"] { try XCTUnwrap(view.groupView(forKey: key)).row.toggle() }
        XCTAssertEqual(order(view), before)
        _ = view.applyFolds(FoldResolver(expandedByDefault: false))
        XCTAssertEqual(order(view), before)
    }

    func testTogglingATopLevelResultInTheMiddleOfATurnKeepsTheOrder() throws {
        // A result with no call to belong to renders as itself, between two paragraphs.
        let blocks: [TurnBlock] = [.text("Before. \(F.prose)"),
                                   F.result("line one\nline two\nline three", id: "no-such-call"),
                                   .text("After. \(F.prose)")]
        let view = makeLive(F.turn(blocks), LiveClock(F.at(0)))
        let before = order(view)
        let result = try XCTUnwrap(view.subviews.first { $0 is ToolResultView }, "the orphan result renders as itself")
        let button = try XCTUnwrap(rigAllSubviews(of: result).compactMap { $0 as? NSButton }.first)

        button.performClick(nil)

        XCTAssertEqual(order(view), before, "the re-measured result moved within subviews")
        XCTAssertTrue(view.subviews.last is TextBlockView)
    }
}

// MARK: - A batch announces itself before it changes the island

extension ToolGroupExpandCostTests {

    func testTheTurnIsToldBeforeEachBatchChangesItsHeightOnceEach() throws {
        // Commands long enough to wrap: a call row then measures taller than its one-line
        // estimate, so a batch replacing estimates really changes the height.
        let long = String(repeating: "--a-long-argument ", count: 30)
        let blocks = (0 ..< 60).flatMap { i in
            [F.call("Bash", id: "t\(i)", summary: "cmd \(i) \(long)"), F.result("output \(i)", id: "t\(i)")]
        }
        let (stream, group, collector) = try makeFixture(blocks)
        group.row.toggle()
        var heightsSeenInTheCallback: [CGFloat] = []
        stream.view.onWillChangeHeight = { heightsSeenInTheCallback.append(stream.view.islandHeight()) }
        var heightsBefore: [CGFloat] = []
        var heightsAfter: [CGFloat] = []

        while collector.pendingCount > 0, heightsBefore.count < 20 {
            heightsBefore.append(stream.view.islandHeight())
            collector.runNext()
            heightsAfter.append(stream.view.islandHeight())
        }

        XCTAssertGreaterThan(heightsBefore.count, 0)
        XCTAssertEqual(heightsSeenInTheCallback.count, heightsBefore.count, "once per batch")
        for (i, seen) in heightsSeenInTheCallback.enumerated() {
            XCTAssertEqual(seen, heightsBefore[i], accuracy: 0.001, "batch \(i + 1): the turn was told after its height had already changed")
        }
        XCTAssertTrue(zip(heightsBefore, heightsAfter).contains { abs($0 - $1) > 0.001 },
                      "precondition: at least one batch changed the height, or the test proves nothing")
        XCTAssertTrue(group.isFullyBuilt)
    }

    func testTheTurnIsNotToldWhenABatchFindsTheGroupClosed() throws {
        let (stream, group, collector) = try makeFixture()
        group.row.toggle()
        var told = 0
        stream.view.onWillChangeHeight = { told += 1 }
        group.row.toggle()

        collector.drain()

        XCTAssertEqual(told, 0, "nothing was built, so nothing changed")
    }
}

// MARK: - The ticker only ticks while the pane can be seen

extension ElapsedTickerTests {

    func testAnInactivePaneSchedulesNothing() {
        let (stream, clock) = runningStream()
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.isActive = { false }

        setup.ticker.reevaluate()

        XCTAssertFalse(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 0)
        XCTAssertTrue(setup.scheduler.scheduledDelays.isEmpty)
    }

    func testAPaneThatBecomesInactiveCancelsItsPendingTick() {
        let (stream, clock) = runningStream()
        var active = true
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.isActive = { active }
        setup.ticker.reevaluate()
        XCTAssertEqual(setup.scheduler.pendingCount, 1)

        active = false
        setup.ticker.reevaluate()

        XCTAssertFalse(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 0)
        XCTAssertEqual(setup.scheduler.advance(to: F.at(60)), [], "nothing fires while the pane is hidden")
    }

    func testAPaneThatBecomesActiveAgainSchedulesAgain() {
        let (stream, clock) = runningStream()
        var active = false
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.isActive = { active }
        setup.ticker.reevaluate()
        XCTAssertFalse(setup.ticker.isScheduled)

        active = true
        setup.ticker.reevaluate()

        XCTAssertTrue(setup.ticker.isScheduled)
        XCTAssertEqual(setup.scheduler.pendingCount, 1)
    }

    func testATickThatFiresJustAfterThePaneWentInactiveSchedulesNothingFurther() {
        let (stream, clock) = runningStream()
        var active = true
        let setup = makeTicker(clock: clock) { () -> [ElapsedTicking] in [stream.view] }
        setup.ticker.isActive = { active }
        setup.ticker.reevaluate()

        active = false
        setup.scheduler.advance(to: F.at(11))

        XCTAssertEqual(setup.scheduler.pendingCount, 0)
        XCTAssertFalse(setup.ticker.isScheduled)
    }
}

// MARK: - The announcer says each group once

final class ToolActivityAnnouncerDedupeTests: XCTestCase {

    private func failedGroup(id: String = "x") -> ToolGroup {
        F.group([F.foldCall("Bash", id: id, summary: "make"), F.foldResult(id: id, isError: true)], outcome: .completedOk)
    }

    /// A focused pane: the composer inside it is first responder in a key window.
    private func focusedPane() -> NSView {
        let window = makeRigWindow(self, size: NSSize(width: 400, height: 300))
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        pane.addSubview(composer)
        window.contentView!.addSubview(pane)
        XCTAssertTrue(window.makeFirstResponder(composer))
        return pane
    }

    func testTheSameFailedGroupReportedTwiceIsAnnouncedOnce() {
        let pane = focusedPane()
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        let group = failedGroup()

        announcer.groupSettled(group, in: pane)
        announcer.groupSettled(group, in: pane)

        XCTAssertEqual(posted, ["Tool activity finished, 1 failed call"])
    }

    func testDifferentFailedGroupsAreEachAnnounced() {
        let pane = focusedPane()
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })

        announcer.groupSettled(failedGroup(id: "a"), in: pane)
        announcer.groupSettled(failedGroup(id: "b"), in: pane)

        XCTAssertEqual(posted.count, 2)
    }

    func testResetForgetsWhatWasAnnounced() {
        let pane = focusedPane()
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })
        let group = failedGroup()
        announcer.groupSettled(group, in: pane)

        announcer.reset()
        announcer.groupSettled(group, in: pane)

        XCTAssertEqual(posted.count, 2)
    }

    // MARK: the group a turn's newest block just closed

    private func turn(_ blocks: [TurnBlock], complete: Bool = false, parents: [Int: String] = [:]) -> ChatTurn {
        F.turn(blocks, complete: complete, textParents: parents)
    }

    func testProseAfterAFailedGroupClosesThatGroup() throws {
        let t = turn([.text("start")] + failingRun() + [.text("That failed; trying another way.")])

        let group = try XCTUnwrap(ToolActivityAnnouncer.groupClosed(byLastBlockOf: t))

        XCTAssertEqual(group.key, "g:s0")
        XCTAssertEqual(group.state, .settled)
        XCTAssertEqual(group.failedCount, 1)
    }

    func testAnErrorChipThatCompletesTheTurnClosesTheLastGroup() throws {
        let t = turn(failingRun("a") + [.text("between")] + failingRun("b") + [errorChip()], complete: true)

        let group = try XCTUnwrap(ToolActivityAnnouncer.groupClosed(byLastBlockOf: t))

        XCTAssertEqual(group.key, "g:b0")
        XCTAssertEqual(group.state, .settled)
        XCTAssertEqual(group.failedCount, 1)
    }

    func testOtherBoundariesCloseTheGroupBeforeThem() throws {
        for boundary in [TurnBlock.errorMessage("boom"), .note("a note"), F.question(), F.chip()] {
            let t = turn(failingRun() + [boundary])

            XCTAssertEqual(ToolActivityAnnouncer.groupClosed(byLastBlockOf: t)?.key, "g:s0")
        }
    }

    func testAnInterruptedChipClosesTheGroupAsStoppedSoItIsNeverSpoken() throws {
        let t = turn(failingRun() + [F.call(id: "s2", summary: "make c", start: 2), stopChip()], complete: true)
        let pane = focusedPane()
        var posted: [String] = []
        let announcer = ToolActivityAnnouncer(post: { posted.append($0) })

        let group = try XCTUnwrap(ToolActivityAnnouncer.groupClosed(byLastBlockOf: t))
        announcer.groupSettled(group, in: pane)

        XCTAssertEqual(group.state, .stopped)
        XCTAssertEqual(group.failedCount, 1)
        XCTAssertEqual(posted, [])
    }

    func testACallOrAResultAsTheNewestBlockClosesNothing() {
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn([.text("go")] + failingRun() + [F.call(id: "n", summary: "more")])))
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn([.text("go")] + failingRun())))
    }

    func testWhitespaceProseClosesNothing() {
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn(failingRun() + [.text("  \n\t ")])))
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn(failingRun() + [.text("")])))
    }

    func testSubagentProseAttachedToAnAgentCallClosesNothing() {
        // 0 Agent call, 1 subagent call, 2 subagent result, 3 subagent prose (attached to the Agent call).
        let blocks: [TurnBlock] = [F.call("Agent", id: "toolu_agent", summary: "explore"),
                                   F.call("Bash", id: "sub1", summary: "grep", parent: "toolu_agent"),
                                   F.result("hit", id: "sub1", isError: true, parent: "toolu_agent"),
                                   .text("the subagent thinks")]

        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn(blocks, parents: [3: "toolu_agent"])))
    }

    func testAnItemBeforeTheNewestBlockThatIsNotAGroupClosesNothing() {
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn([.text("one"), .text("two")])))
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn([.text("only")])))
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn([F.chip()], complete: true)))
        XCTAssertNil(ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn([])))
    }
}
