// NostromoKit — BackgroundTaskListTests.swift
//
// Background activity (BA3): what the chip and the popover show for one focus, from the daemon's
// task snapshot. PRD "What counts as a task", "The chip", "The popover" and the Phase 1 criteria;
// design contract §2.7 (listing rule, chip states) and §4 (hostile text).
//
// `BackgroundTaskList.make` is pure: tasks, details, "now" and the seen mark in, rows and chip out.
// Time is always the `nowMs` handed in, never the wall clock.

import XCTest
import NostromoKit

final class BackgroundTaskListTests: XCTestCase {

    // MARK: - Builders

    /// "Now", in ms since 1970 (the daemon's `*_at_ms` clock).
    private let nowMs: UInt64 = 1_760_000_600_000

    /// `seconds` before now, in ms.
    private func ago(_ seconds: UInt64) -> UInt64 { nowMs - seconds * 1000 }

    private func task(_ id: String,
                      _ kind: TaskKindWire = .shell,
                      status: TaskStatusWire = .running,
                      description: String = "",
                      taskType: String = "",
                      subagentType: String? = nil,
                      workflowName: String? = nil,
                      parent: String? = nil,
                      background: Bool? = true,
                      housekeeping: Bool = false,
                      endReason: TaskEndReasonWire? = nil,
                      started: UInt64? = nil,
                      ended: UInt64? = nil,
                      duration: UInt64? = nil,
                      tokens: UInt64? = nil,
                      tools: UInt64? = nil,
                      lastTool: String? = nil) -> TaskMetaWire {
        TaskMetaWire(id: id, taskType: taskType, kind: kind, description: description,
                     subagentType: subagentType, workflowName: workflowName, parentTaskId: parent,
                     isBackgrounded: background, housekeeping: housekeeping, status: status,
                     endReason: endReason, startedAtMs: started, endedAtMs: ended, durationMs: duration,
                     totalTokens: tokens, toolUses: tools, lastToolName: lastTool)
    }

    private func build(_ tasks: [TaskMetaWire],
                       details: [String: SessionTaskDetailWire] = [:],
                       seen: UInt64? = nil,
                       stopSupported: Bool? = nil) -> BackgroundTaskList {
        BackgroundTaskList.make(tasks: tasks, details: details, nowMs: nowMs, seenEndedAtMs: seen,
                                stopSupported: stopSupported)
    }

    private func detail(_ id: String, preview: String? = nil, progress: String? = nil) -> [String: SessionTaskDetailWire] {
        [id: SessionTaskDetailWire(tag: "kate", taskId: id, preview: preview, progressSummary: progress)]
    }

    private func ids(_ rows: [BackgroundTaskRow]) -> [String] { rows.map(\.id) }

    private func runningRow(_ list: BackgroundTaskList, file: StaticString = #filePath, line: UInt = #line) -> BackgroundTaskRow? {
        XCTAssertEqual(list.running.count, 1, "expected exactly one running row", file: file, line: line)
        return list.running.first
    }

    private func endedRow(_ list: BackgroundTaskList, file: StaticString = #filePath, line: UInt = #line) -> BackgroundTaskRow? {
        XCTAssertEqual(list.ended.count, 1, "expected exactly one ended row", file: file, line: line)
        return list.ended.first
    }

    // MARK: - Nothing to show

    func testNoTasksShowsNoChipAndEmptySections() {
        let list = build([])
        XCTAssertEqual(list.chip, .hidden)
        XCTAssertNil(list.chip.text)
        XCTAssertNil(list.chip.accessibilityLabel)
        XCTAssertNil(list.chipTooltip)
        XCTAssertEqual(list.chip.name, "hidden")
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertTrue(list.ended.isEmpty)
        XCTAssertTrue(list.housekeeping.isEmpty)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list, BackgroundTaskList.empty)
    }

    // MARK: - A background shell

    func testABackgroundShellShowsOneRunningOnTheChipAndARowWithItsFacts() throws {
        let list = build([task("b1", .shell, description: "npm run dev", taskType: "local_bash", background: true,
                               started: nowMs - 4_100)])
        XCTAssertEqual(list.chip, .running(1))
        XCTAssertEqual(list.chip.text, "\u{25F7} 1 running")
        XCTAssertEqual(list.chip.name, "running")
        XCTAssertEqual(list.runningCountText, "1 running")

        let row = try XCTUnwrap(runningRow(list))
        XCTAssertEqual(row.id, "b1")
        XCTAssertEqual(row.section, .running)
        XCTAssertEqual(row.kindLabel, "Shell")
        XCTAssertEqual(row.kindName, "local_bash")
        XCTAssertEqual(row.description, "npm run dev")
        XCTAssertEqual(row.title, "npm run dev")
        XCTAssertEqual(row.statusLabel, "running")
        XCTAssertEqual(row.statusIcon, "\u{25F7}")
        XCTAssertFalse(row.isEnded)
        XCTAssertFalse(row.isFailed)
        XCTAssertEqual(row.elapsedMs, 4_100, "elapsed is the injected now minus the start")
        XCTAssertNil(row.durationMs, "a running task has no duration yet")
        XCTAssertNil(row.endedAgoMs)
        XCTAssertNil(row.endedAgoText)
        XCTAssertEqual(row.timeText, ToolGroupSummary.durationText(seconds: 4.1))
        XCTAssertEqual(row.timeText, "4.1 s")
        XCTAssertEqual(row.depth, 0)
        XCTAssertNil(row.parentId)
        XCTAssertFalse(row.isHousekeeping)
    }

    func testElapsedTimeFollowsTheClockHandedIn() throws {
        let tasks = [task("b1", .shell, description: "sleep 600", started: nowMs - 4_100)]
        let early = BackgroundTaskList.make(tasks: tasks, nowMs: nowMs)
        let later = BackgroundTaskList.make(tasks: tasks, nowMs: nowMs + 60_000)
        XCTAssertEqual(early.running.first?.elapsedMs, 4_100)
        XCTAssertEqual(later.running.first?.elapsedMs, 64_100)
        XCTAssertEqual(later.running.first?.timeText, ToolGroupSummary.durationText(seconds: 64.1))
    }

    func testAMonitorIsLabelledMonitorNotShell() throws {
        let list = build([task("m1", .monitor, description: "CI for PR #251", taskType: "monitor_mcp", background: nil,
                               started: ago(840))])
        XCTAssertEqual(list.chip, .running(1))
        let row = try XCTUnwrap(runningRow(list))
        XCTAssertEqual(row.kindLabel, "Monitor")
        XCTAssertEqual(row.description, "CI for PR #251")
        XCTAssertEqual(row.statusLabel, "running")
    }

    // MARK: - What is listed

    func testListingRuleByKindAndBackgrounding() {
        let cases: [(name: String, task: TaskMetaWire, listed: Bool)] = [
            ("background shell", task("t", .shell, background: true), true),
            ("foreground shell", task("t", .shell, background: false), false),
            ("shell whose backgrounding is unknown", task("t", .shell, background: nil), false),
            ("monitor (always background)", task("t", .monitor, background: nil), true),
            ("monitor said to be foreground", task("t", .monitor, background: false), true),
            ("foreground agent", task("t", .agent, background: false), true),
            ("background agent", task("t", .agent, background: true), true),
            ("agent whose backgrounding is unknown", task("t", .agent, background: nil), true),
            ("workflow", task("t", .workflow, background: nil), true),
            ("other kind", task("t", .other, background: nil), true),
            ("unknown kind", task("t", .unknown("remote_agent"), background: nil), true),
        ]
        for c in cases {
            let list = build([c.task])
            XCTAssertEqual(list.running.count, c.listed ? 1 : 0, c.name)
            XCTAssertEqual(list.chip, c.listed ? .running(1) : .hidden, c.name)
            XCTAssertEqual(BackgroundTaskList.isListed(c.task), c.listed, c.name)
        }
    }

    func testAForegroundShellIsNotListedEvenOnceItHasEnded() {
        let foreground = task("f1", .shell, status: .completed, background: false, started: ago(60), ended: ago(30))
        let list = build([foreground])
        XCTAssertTrue(list.ended.isEmpty)
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertEqual(list.chip, .hidden, "a foreground command is the transcript's row, not an ended background task")
    }

    func testAForegroundSubagentIsListed() throws {
        let list = build([task("a1", .agent, description: "Find callers", subagentType: "explore", background: false,
                               started: ago(20))])
        let row = try XCTUnwrap(runningRow(list))
        XCTAssertEqual(row.kindLabel, "Agent")
        XCTAssertEqual(list.chip, .running(1))
    }

    func testAShellThatLaterGoesToTheBackgroundBecomesListed() {
        let before = task("s1", .shell, description: "cargo test", background: false, started: ago(30))
        let after = task("s1", .shell, description: "cargo test", background: true, started: ago(30))
        XCTAssertEqual(build([before]).chip, .hidden)
        let list = build([after])
        XCTAssertEqual(list.chip, .running(1))
        XCTAssertEqual(list.running.first?.id, "s1")
    }

    func testTheSameTaskIdSentTwiceIsOneRowAndTheLastEntryWins() {
        let list = build([task("t1", .agent, status: .running, started: ago(60)),
                          task("t1", .agent, status: .stopped, endReason: .restart, started: ago(60), ended: ago(5))])
        XCTAssertEqual(list.allRows.count, 1)
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertEqual(list.ended.first?.statusLabel, "stopped")
    }

    // MARK: - Housekeeping

    func testHousekeepingIsNotCountedOnTheChipAndOnlyShownUnderHousekeeping() throws {
        let list = build([
            task("w1", .agent, description: "Find callers", subagentType: "explore", started: ago(30)),
            task("h1", .other, description: "ambient watcher", taskType: "dream", housekeeping: true, started: ago(300)),
        ])
        XCTAssertEqual(list.chip, .running(1), "the housekeeping task is not counted")
        XCTAssertEqual(ids(list.running), ["w1"])
        XCTAssertEqual(ids(list.housekeeping), ["h1"])
        let chore = try XCTUnwrap(list.housekeeping.first)
        XCTAssertEqual(chore.section, .housekeeping)
        XCTAssertTrue(chore.isHousekeeping)
        XCTAssertEqual(list.allRows.map(\.id), ["w1", "h1"], "running, then ended, then housekeeping")
    }

    func testAListWithOnlyHousekeepingShowsNoChip() {
        let list = build([task("h1", .other, description: "watcher", housekeeping: true, started: ago(30)),
                          task("h2", .agent, status: .failed, housekeeping: true, started: ago(90), ended: ago(60))])
        XCTAssertEqual(list.chip, .hidden, "neither a running nor a failed chore is news")
        XCTAssertTrue(list.running.isEmpty)
        XCTAssertTrue(list.ended.isEmpty, "an ended chore is housekeeping, not Ended")
        XCTAssertEqual(list.housekeeping.count, 2)
        XCTAssertFalse(list.isEmpty)
    }

    func testHousekeepingListsRunningChoresFirstThenEndedOnesNewestFirst() {
        let list = build([
            task("done-old", .other, status: .completed, housekeeping: true, started: ago(900), ended: ago(800)),
            task("run-old", .other, housekeeping: true, started: ago(500)),
            task("done-new", .other, status: .completed, housekeeping: true, started: ago(400), ended: ago(100)),
            task("run-new", .other, housekeeping: true, started: ago(50)),
        ])
        XCTAssertEqual(ids(list.housekeeping), ["run-new", "run-old", "done-new", "done-old"])
    }

    // MARK: - Nesting

    func testASubagentsBackgroundShellIsNestedRightAfterItAtDepthOne() throws {
        let list = build([
            task("A", .agent, description: "Write failing tests", subagentType: "redd", started: ago(60)),
            task("S", .shell, description: "cargo test -p nostromo", parent: "A", started: ago(10)),
            task("B", .agent, description: "Find callers", subagentType: "explore", started: ago(5)),
        ])
        XCTAssertEqual(ids(list.running), ["B", "A", "S"], "newest root first; the child directly under its parent, not by its own age")
        XCTAssertEqual(list.running.map(\.depth), [0, 0, 1])
        let child = try XCTUnwrap(list.running.last)
        XCTAssertEqual(child.parentId, "A")
        XCTAssertEqual(list.chip, .running(3), "children are counted like any other task")
    }

    func testChildrenOfOneParentAreNewestFirst() {
        let list = build([
            task("A", .agent, started: ago(100)),
            task("old", .shell, parent: "A", started: ago(30)),
            task("new", .shell, parent: "A", started: ago(10)),
            task("mid", .shell, parent: "A", started: ago(20)),
        ])
        XCTAssertEqual(ids(list.running), ["A", "new", "mid", "old"])
        XCTAssertEqual(list.running.map(\.depth), [0, 1, 1, 1])
    }

    func testIndentationStopsAtDepthThreeForADeeperChain() {
        let chain = (0..<5).map { i in
            task("t\(i)", .agent, parent: i == 0 ? nil : "t\(i - 1)", started: ago(100 - UInt64(i)))
        }
        let list = build(chain)
        XCTAssertEqual(ids(list.running), ["t0", "t1", "t2", "t3", "t4"], "nothing is lost past the cap")
        XCTAssertEqual(list.running.map(\.depth), [0, 1, 2, 3, 3])
        XCTAssertEqual(BackgroundTaskList.maxDepth, 3)
        XCTAssertEqual(list.running.last?.parentId, "t3", "the parent id is still the daemon's")
    }

    func testATaskWhoseParentIsUnknownIsTopLevel() throws {
        let list = build([task("c1", .shell, description: "orphan", parent: "no-such-task", started: ago(10))])
        let row = try XCTUnwrap(runningRow(list))
        XCTAssertEqual(row.depth, 0)
        XCTAssertEqual(row.parentId, "no-such-task")
    }

    func testATaskWhoseParentHasEndedIsTopLevelInRunning() throws {
        let list = build([
            task("A", .agent, status: .completed, started: ago(100), ended: ago(50)),
            task("S", .shell, description: "still going", parent: "A", started: ago(80)),
        ])
        let row = try XCTUnwrap(runningRow(list))
        XCTAssertEqual(row.id, "S")
        XCTAssertEqual(row.depth, 0, "its parent is not in the running section")
        XCTAssertEqual(ids(list.ended), ["A"])
    }

    func testAParentCycleDoesNotLoseTasks() {
        let list = build([
            task("a", .agent, parent: "b", started: ago(20)),
            task("b", .agent, parent: "a", started: ago(10)),
            task("self", .agent, parent: "self", started: ago(5)),
        ])
        XCTAssertEqual(Set(ids(list.running)), ["a", "b", "self"])
        XCTAssertEqual(list.running.count, 3, "no task twice")
        XCTAssertEqual(list.chip, .running(3))
        XCTAssertTrue(list.running.allSatisfy { $0.depth <= BackgroundTaskList.maxDepth })
    }

    // MARK: - Running order and states

    func testRunningTasksAreNewestFirst() {
        let list = build([
            task("t30", .shell, started: ago(30)),
            task("t10", .shell, started: ago(10)),
            task("t20", .shell, started: ago(20)),
        ])
        XCTAssertEqual(ids(list.running), ["t10", "t20", "t30"])
    }

    func testPendingPausedAndUnrecognisedStatusesCountAsNotEndedAndKeepTheirOwnWords() {
        let cases: [(TaskStatusWire, String)] = [
            (.pending, "pending"), (.paused, "paused"), (.running, "running"), (.unknown("zombie"), "zombie"),
        ]
        for (status, label) in cases {
            let list = build([task("t", .agent, status: status, started: ago(10))])
            XCTAssertEqual(list.chip, .running(1), label)
            XCTAssertEqual(list.running.first?.statusLabel, label)
            XCTAssertEqual(list.running.first?.statusIcon, "\u{25F7}", label)
            XCTAssertEqual(list.running.first?.isEnded, false, label)
        }
    }

    func testAnUnknownStartTimeLeavesTheElapsedTimeOutRatherThanZero() throws {
        let list = build([task("t1", .shell, description: "no start", started: nil)])
        let row = try XCTUnwrap(runningRow(list))
        XCTAssertNil(row.elapsedMs)
        XCTAssertNil(row.timeText)
        XCTAssertEqual(list.chip, .running(1))
    }

    func testAStartAfterTheClockReadsZeroAndDoesNotCrash() throws {
        let list = build([task("t1", .shell, started: nowMs + 5_000)])
        let row = try XCTUnwrap(runningRow(list))
        XCTAssertEqual(row.elapsedMs, 0)
        XCTAssertNil(row.timeText, "no time shown rather than 0 ms")
    }

    // MARK: - Ended

    func testCompletedFailedAndStoppedTasksMoveToEndedWithTheRightStatusDurationAndAgo() throws {
        let cases: [(status: TaskStatusWire, label: String, icon: String, failed: Bool)] = [
            (.completed, "completed", "\u{2713}", false),
            (.failed, "failed", "\u{2715}", true),
            (.stopped, "stopped", "\u{25A0}", false),
        ]
        for c in cases {
            let list = build([task("e1", .shell, status: c.status, description: "npm run build",
                                   started: ago(300), ended: ago(240))])
            XCTAssertTrue(list.running.isEmpty, c.label)
            let row = try XCTUnwrap(endedRow(list), c.label)
            XCTAssertEqual(row.section, .ended, c.label)
            XCTAssertEqual(row.statusLabel, c.label)
            XCTAssertEqual(row.statusIcon, c.icon, c.label)
            XCTAssertTrue(row.isEnded, c.label)
            XCTAssertEqual(row.isFailed, c.failed, c.label)
            XCTAssertNil(row.elapsedMs, "\(c.label): an ended task has a duration, not an elapsed time")
            XCTAssertEqual(row.durationMs, 60_000, "\(c.label): ended minus started when the CLI sent no duration")
            XCTAssertEqual(row.timeText, ToolGroupSummary.durationText(seconds: 60), c.label)
            XCTAssertEqual(row.endedAgoMs, 240_000, c.label)
            XCTAssertEqual(row.endedAgoText, "4 m ago", c.label)
            XCTAssertFalse(row.stopOffered, "\(c.label): nothing to stop")
        }
    }

    func testTheDurationTheCLISentWinsOverEndedMinusStarted() throws {
        let list = build([task("e1", .agent, status: .completed, started: ago(300), ended: ago(240), duration: 90_333)])
        let row = try XCTUnwrap(endedRow(list))
        XCTAssertEqual(row.durationMs, 90_333)
        XCTAssertEqual(row.timeText, ToolGroupSummary.durationText(seconds: 90.333))
    }

    func testUnknownEndedTimesAreAbsentNotZero() throws {
        let list = build([task("e1", .agent, status: .completed, started: nil, ended: nil, duration: nil)])
        let row = try XCTUnwrap(endedRow(list))
        XCTAssertNil(row.durationMs)
        XCTAssertNil(row.timeText)
        XCTAssertNil(row.endedAgoMs)
        XCTAssertNil(row.endedAgoText)
    }

    func testAnEndedTaskIsAFlatRowEvenWhenItsParentIsStillRunning() throws {
        let list = build([
            task("A", .agent, started: ago(100)),
            task("S", .shell, status: .completed, parent: "A", started: ago(90), ended: ago(30)),
        ])
        let row = try XCTUnwrap(endedRow(list))
        XCTAssertEqual(row.depth, 0)
        XCTAssertEqual(row.parentId, "A")
        XCTAssertEqual(ids(list.running), ["A"])
    }

    func testEndedTasksAreNewestEndedFirst() {
        let list = build([
            task("mid", .shell, status: .completed, started: ago(500), ended: ago(200)),
            task("last", .shell, status: .failed, started: ago(600), ended: ago(100)),
            task("first", .shell, status: .stopped, started: ago(100), ended: ago(300)),
        ])
        XCTAssertEqual(ids(list.ended), ["last", "mid", "first"], "by when it ended, not when it started")
    }

    func testThe21stEndedTaskPushesTheOldestOff() {
        let many = (0..<21).map { i in
            task("e\(i)", .shell, status: .completed, started: ago(2_000), ended: ago(1_000 - UInt64(i)))
        }
        let list = build(many)
        XCTAssertEqual(BackgroundTaskList.endedLimit, 20)
        XCTAssertEqual(list.ended.count, 20)
        XCTAssertEqual(list.ended.first?.id, "e20", "newest first")
        XCTAssertFalse(ids(list.ended).contains("e0"), "the oldest dropped off")
        XCTAssertTrue(ids(list.ended).contains("e1"))

        let exactly20 = build(Array(many.prefix(20)))
        XCTAssertEqual(exactly20.ended.count, 20, "20 ended tasks all fit")
        XCTAssertTrue(ids(exactly20.ended).contains("e0"))
    }

    func testRestartStoppedTasksCarryTheirReason() throws {
        let list = build([task("r1", .agent, status: .stopped, endReason: .restart, started: ago(60), ended: ago(5))])
        let row = try XCTUnwrap(endedRow(list))
        XCTAssertEqual(row.statusLabel, "stopped")
        XCTAssertEqual(row.endReason, .restart)
    }

    func testEndedAgoTextReadsSecondsMinutesHoursAndDays() {
        let cases: [(UInt64, String)] = [
            (0, "0 s ago"), (12_000, "12 s ago"), (59_999, "59 s ago"), (60_000, "1 m ago"),
            (240_000, "4 m ago"), (3_599_000, "59 m ago"), (3_600_000, "1 h ago"),
            (10_800_000, "3 h ago"), (86_400_000, "1 d ago"), (172_800_000, "2 d ago"),
        ]
        for (ms, text) in cases {
            XCTAssertEqual(BackgroundTaskList.agoText(ms: ms), text, "\(ms) ms")
        }
    }

    // MARK: - The chip after tasks end

    func testAfterTheLastTaskEndsWithOneFailureTheChipReadsOneFailed() {
        let list = build([
            task("ok", .shell, status: .completed, started: ago(300), ended: ago(100)),
            task("bad", .agent, status: .failed, started: ago(300), ended: ago(60)),
        ])
        XCTAssertEqual(list.chip, .failed(1))
        XCTAssertEqual(list.chip.text, "\u{2715} 1 failed")
        XCTAssertEqual(list.chip.name, "failed")
        XCTAssertEqual(list.chip.accessibilityLabel, "Background activity: 1 failed")
    }

    func testOpeningThePopoverHidesTheFailedChip() {
        let ended = [task("bad", .agent, status: .failed, started: ago(300), ended: ago(60))]
        XCTAssertEqual(build(ended, seen: nil).chip, .failed(1))
        let mark = BackgroundTaskList.seenMark(of: ended)
        XCTAssertEqual(mark, ago(60))
        XCTAssertEqual(build(ended, seen: mark).chip, .hidden, "seen up to and including the failure's end")
        XCTAssertEqual(build(ended, seen: ago(60) + 1_000).chip, .hidden)
        XCTAssertEqual(build(ended, seen: ago(60) - 1).chip, .failed(1), "one ms short is not seen")
        XCTAssertEqual(build(ended, seen: 0).chip, .failed(1), "a seen mark of zero has seen nothing")
    }

    func testEndedTasksWithoutFailuresReadDoneWithTheCount() {
        let list = build([
            task("a", .shell, status: .completed, started: ago(300), ended: ago(100)),
            task("b", .monitor, status: .completed, background: nil, started: ago(300), ended: ago(90)),
        ])
        XCTAssertEqual(list.chip, .done(2))
        XCTAssertEqual(list.chip.text, "\u{2713} 2 done")
        XCTAssertEqual(list.chip.name, "done")
        XCTAssertEqual(list.chip.accessibilityLabel, "Background activity: 2 done")
    }

    func testAStoppedTaskAloneReadsDone() {
        let list = build([task("s", .shell, status: .stopped, started: ago(300), ended: ago(30))])
        XCTAssertEqual(list.chip, .done(1))
    }

    func testFailureOutranksDoneAndCountsOnlyTheFailures() {
        let list = build([
            task("a", .shell, status: .completed, started: ago(300), ended: ago(100)),
            task("b", .shell, status: .failed, started: ago(300), ended: ago(90)),
            task("c", .agent, status: .failed, started: ago(300), ended: ago(80)),
        ])
        XCTAssertEqual(list.chip, .failed(2))
    }

    func testOnlyTasksThatEndedAfterTheSeenMarkAreNews() {
        let tasks = [
            task("old", .shell, status: .failed, started: ago(900), ended: ago(500)),
            task("new", .shell, status: .completed, started: ago(900), ended: ago(100)),
        ]
        XCTAssertEqual(build(tasks, seen: nil).chip, .failed(1))
        XCTAssertEqual(build(tasks, seen: ago(500)).chip, .done(1), "the failure was seen; the later success was not")
        XCTAssertEqual(build(tasks, seen: ago(100)).chip, .hidden)
    }

    func testARunningTaskOutranksEndedOnesOnTheChip() {
        let list = build([
            task("run", .shell, started: ago(10)),
            task("bad", .shell, status: .failed, started: ago(300), ended: ago(60)),
        ])
        XCTAssertEqual(list.chip, .running(1))
        XCTAssertEqual(ids(list.ended), ["bad"], "the failure is still in the Ended section")
    }

    func testSeenMarkIsTheLatestEndTimeOfAnEndedTask() {
        XCTAssertNil(BackgroundTaskList.seenMark(of: []))
        XCTAssertNil(BackgroundTaskList.seenMark(of: [task("run", .shell, started: ago(10))]), "a running task has not ended")
        let mark = BackgroundTaskList.seenMark(of: [
            task("a", .shell, status: .completed, started: ago(300), ended: ago(200)),
            task("b", .shell, status: .failed, started: ago(300), ended: ago(50)),
            task("run", .shell, started: ago(10)),
        ])
        XCTAssertEqual(mark, ago(50))
    }

    // MARK: - Chip words

    func testChipTooltipListsTheFirstThreeRunningTitlesNewestFirst() {
        let list = build([
            task("t1", .shell, description: "oldest job", started: ago(40)),
            task("t2", .agent, description: "Write failing tests", subagentType: "redd", started: ago(30)),
            task("t3", .monitor, description: "CI for PR #251", background: nil, started: ago(20)),
            task("t4", .shell, description: "newest job", started: ago(10)),
        ])
        XCTAssertEqual(list.chip, .running(4))
        XCTAssertEqual(list.chipTooltip, "newest job\nCI for PR #251\nredd \u{00B7} Write failing tests")
    }

    func testChipTooltipForFewerThanThreeRunningTasks() {
        let list = build([task("t1", .shell, description: "only job", started: ago(10))])
        XCTAssertEqual(list.chipTooltip, "only job")
    }

    func testChipAccessibilityLabelNamesTheRunningCount() {
        let list = build([task("t1", .shell, started: ago(10)), task("t2", .shell, started: ago(20))])
        XCTAssertEqual(list.chip.accessibilityLabel, "Background activity: 2 running")
        XCTAssertEqual(list.chip.text, "\u{25F7} 2 running")
        XCTAssertEqual(list.runningCountText, "2 running")
    }

    func testRowAccessibilityLabelNamesKindDescriptionStatusAndElapsed() throws {
        let list = build([task("b1", .shell, description: "npm run dev", started: nowMs - 4_100)])
        let label = try XCTUnwrap(list.running.first).accessibilityLabel
        for part in ["Shell", "npm run dev", "running", "4.1 s"] {
            XCTAssertTrue(label.contains(part), "\(part) in \"\(label)\"")
        }
    }

    func testEndedRowAccessibilityLabelNamesStatusDurationAndAgo() throws {
        let list = build([task("e1", .agent, status: .failed, description: "Find callers", subagentType: "explore",
                               started: ago(300), ended: ago(240))])
        let label = try XCTUnwrap(list.ended.first).accessibilityLabel
        for part in ["Agent", "Find callers", "failed", "1 m 00 s", "4 m ago"] {
            XCTAssertTrue(label.contains(part), "\(part) in \"\(label)\"")
        }
    }

    // MARK: - Titles and kinds

    func testAnAgentReadsItsSubagentTypeThenItsDescription() throws {
        let typed = build([task("a1", .agent, description: "Write failing tests", subagentType: "redd", started: ago(10))])
        XCTAssertEqual(typed.running.first?.title, "redd \u{00B7} Write failing tests")
        XCTAssertEqual(typed.running.first?.description, "Write failing tests", "the description stays verbatim for the tooltip")

        let untyped = build([task("a2", .agent, description: "Write failing tests", started: ago(10))])
        XCTAssertEqual(untyped.running.first?.title, "Write failing tests")
    }

    func testAWorkflowReadsItsNameElseItsDescription() {
        let named = build([task("w1", .workflow, description: "run the audit", workflowName: "nightly-audit", started: ago(10))])
        XCTAssertEqual(named.running.first?.title, "nightly-audit")
        XCTAssertEqual(named.running.first?.kindLabel, "Workflow")
        let unnamed = build([task("w2", .workflow, description: "run the audit", started: ago(10))])
        XCTAssertEqual(unnamed.running.first?.title, "run the audit")
    }

    func testAnUnknownKindIsOtherWithTheCLIsOwnKindName() throws {
        let cases: [(name: String, kind: TaskKindWire)] = [
            ("an unrecognised kind", .unknown("remote_agent")),
            ("the other kind", .other),
        ]
        for c in cases {
            let list = build([task("o1", c.kind, description: "Review the PR", taskType: "remote_agent", background: nil,
                                   started: ago(10))])
            let row = try XCTUnwrap(runningRow(list), c.name)
            XCTAssertEqual(row.kindLabel, "Other", c.name)
            XCTAssertEqual(row.kindName, "remote_agent", c.name)
            XCTAssertTrue(row.title.contains("remote_agent"), "\(c.name): the title carries the CLI's kind name: \(row.title)")
            XCTAssertTrue(row.title.contains("Review the PR"), c.name)
            XCTAssertEqual(list.chip, .running(1), c.name)
        }
    }

    func testAnUnrecognisedKindWithNoTaskTypeStillShowsItsRawKindName() {
        let list = build([task("o1", .unknown("teammate"), description: "Pair on it", taskType: "", background: nil,
                               started: ago(10))])
        XCTAssertEqual(list.running.first?.kindLabel, "Other")
        XCTAssertEqual(list.running.first?.kindName, "teammate")
        XCTAssertEqual(list.running.first?.title, "teammate · Pair on it")
    }

    func testAKindNameIsAbsentWhenTheCLISentNone() {
        let list = build([task("o1", .other, description: "mystery", taskType: "", background: nil, started: ago(10))])
        XCTAssertNil(list.running.first?.kindName)
        XCTAssertEqual(list.running.first?.kindLabel, "Other")
        XCTAssertEqual(list.running.first?.title, "mystery")
    }

    // MARK: - Latest sign of life

    func testAnAgentShowsTokensToolsAndTheToolInUse() {
        let list = build([task("a1", .agent, subagentType: "redd", started: ago(10), tokens: 18_234, tools: 11, lastTool: "Edit")])
        XCTAssertEqual(list.running.first?.signOfLife, "18.2k tokens \u{00B7} 11 tools \u{00B7} Edit")
    }

    func testUnknownPartsOfAnAgentsSignOfLifeAreLeftOutNeverShownAsZero() {
        let cases: [(name: String, task: TaskMetaWire, expected: String?)] = [
            ("tokens only", task("a", .agent, started: ago(10), tokens: 950), "950 tokens"),
            ("tools only", task("a", .agent, started: ago(10), tools: 11), "11 tools"),
            ("one tool", task("a", .agent, started: ago(10), tools: 1), "1 tool"),
            ("current tool only", task("a", .agent, started: ago(10), lastTool: "Grep"), "Grep"),
            ("tokens and tool, no count", task("a", .agent, started: ago(10), tokens: 950, lastTool: "Edit"),
             "950 tokens \u{00B7} Edit"),
            ("nothing known", task("a", .agent, started: ago(10)), nil),
        ]
        for c in cases {
            let sign = build([c.task]).running.first?.signOfLife
            XCTAssertEqual(sign, c.expected, c.name)
            if let sign { XCTAssertFalse(sign.contains("0 tokens"), c.name) }
        }
    }

    func testAnAgentsProgressSummaryFromTheDetailWinsOverTheCounts() {
        let t = task("a1", .agent, started: ago(10), tokens: 18_234, tools: 11, lastTool: "Edit")
        let list = build([t], details: detail("a1", progress: "Reading the wire types"))
        XCTAssertEqual(list.running.first?.signOfLife, "Reading the wire types")
    }

    func testAnEmptyProgressSummaryFallsBackToTheCounts() {
        let t = task("a1", .agent, started: ago(10), tokens: 950)
        let list = build([t], details: detail("a1", progress: "  "))
        XCTAssertEqual(list.running.first?.signOfLife, "950 tokens")
    }

    func testAShellAndAMonitorShowTheirLastOutputLine() {
        let shell = task("b1", .shell, description: "npm run dev", started: ago(10))
        let monitor = task("m1", .monitor, description: "CI", background: nil, started: ago(20))
        let details = detail("b1", preview: "ready on :3000")
            .merging(detail("m1", preview: "build: 3/7 jobs passed")) { a, _ in a }
        let list = build([shell, monitor], details: details)
        XCTAssertEqual(list.running.first { $0.id == "b1" }?.signOfLife, "last: ready on :3000")
        XCTAssertEqual(list.running.first { $0.id == "m1" }?.signOfLife, "last: build: 3/7 jobs passed")
    }

    func testAShellWithNoOutputYetHasNoSignOfLife() {
        let shell = task("b1", .shell, started: ago(10))
        XCTAssertNil(build([shell]).running.first?.signOfLife)
        XCTAssertNil(build([shell], details: detail("b1", preview: "")).running.first?.signOfLife)
        XCTAssertNil(build([shell], details: detail("b1", progress: "an agent's words")).running.first?.signOfLife,
                     "a shell has no progress summary")
    }

    func testTheDetailOfAnotherTaskIsNotShown() {
        let shell = task("b1", .shell, started: ago(10))
        XCTAssertNil(build([shell], details: detail("someone-else", preview: "not mine")).running.first?.signOfLife)
    }

    func testASignOfLifeIsOneLine() {
        let shell = task("b1", .shell, started: ago(10))
        let sign = build([shell], details: detail("b1", preview: "first\nsecond\r\nthird")).running.first?.signOfLife
        XCTAssertNotNil(sign)
        XCTAssertNil(sign?.rangeOfCharacter(from: .newlines))
        XCTAssertTrue(sign?.hasPrefix("last: first") ?? false)
    }

    // MARK: - Number words

    func testTokensReadAsPlainThousandsAndMillions() {
        let cases: [(UInt64, String)] = [
            (950, "950 tokens"), (999, "999 tokens"), (1_000, "1.0k tokens"), (18_234, "18.2k tokens"),
            (250_000, "250k tokens"), (1_000_000, "1.0M tokens"), (1_300_000, "1.3M tokens"),
        ]
        for (tokens, text) in cases {
            XCTAssertEqual(BackgroundTaskList.tokensText(tokens), text, "\(tokens)")
        }
        XCTAssertFalse(BackgroundTaskList.tokensText(999_999).contains("1000"), "just under a million is not 1000k")
    }

    func testToolCountsAreSingularForOne() {
        XCTAssertEqual(BackgroundTaskList.toolsText(1), "1 tool")
        XCTAssertEqual(BackgroundTaskList.toolsText(2), "2 tools")
        XCTAssertEqual(BackgroundTaskList.toolsText(11), "11 tools")
    }

    // MARK: - Stop

    func testStopIsOfferedOnRunningRowsUnlessTheDaemonSaidTheCLICannotStop() {
        let running = [task("b1", .shell, started: ago(10))]
        XCTAssertEqual(build(running, stopSupported: nil).running.first?.stopOffered, true, "not yet known: offered")
        XCTAssertEqual(build(running, stopSupported: true).running.first?.stopOffered, true)
        XCTAssertEqual(build(running, stopSupported: false).running.first?.stopOffered, false)
    }

    func testStopIsNeverOfferedOnAnEndedRow() {
        let ended = [task("e1", .shell, status: .completed, started: ago(100), ended: ago(10))]
        for support in [nil, true, false] as [Bool?] {
            XCTAssertEqual(build(ended, stopSupported: support).ended.first?.stopOffered, false)
        }
    }

    // MARK: - Hostile text

    func testADescriptionWithNewlinesAndTenKilobytesStillMakesAOneLineTitle() throws {
        let hostile = "first line\nsecond line\r\nthird\t" + String(repeating: "x", count: 10_240)
        let kinds: [(TaskKindWire, String?, String?)] = [
            (.shell, nil, nil), (.monitor, nil, nil), (.agent, "red\nd", nil), (.workflow, nil, "name\nwith\nbreaks"),
            (.other, nil, nil),
        ]
        for (kind, subagent, workflow) in kinds {
            let list = build([task("h1", kind, description: hostile, taskType: "type\nwith break", subagentType: subagent,
                                   workflowName: workflow, background: true, started: ago(10))])
            let row = try XCTUnwrap(runningRow(list), "\(kind)")
            XCTAssertNil(row.title.rangeOfCharacter(from: .newlines), "\(kind): one line")
            XCTAssertFalse(row.title.isEmpty, "\(kind)")
            XCTAssertEqual(row.description, hostile, "\(kind): the description itself stays verbatim")
            XCTAssertNil(row.accessibilityLabel.rangeOfCharacter(from: .newlines), "\(kind)")
            XCTAssertNil(list.chipTooltip?.replacingOccurrences(of: "\n", with: "").rangeOfCharacter(from: .newlines),
                         "\(kind): the tooltip is lines of titles, none broken further")
        }
    }

    func testEveryHostileStringSurvivesAsDescriptionAndPreviewAndStaysOneLine() throws {
        for (index, text) in HostileContent.all.enumerated() {
            let t = task("h\(index)", .shell, description: text, started: ago(10))
            let list = build([t], details: detail("h\(index)", preview: text))
            let row = try XCTUnwrap(runningRow(list), "hostile string #\(index)")
            XCTAssertNil(row.title.rangeOfCharacter(from: .newlines), "title of hostile string #\(index)")
            if let sign = row.signOfLife {
                XCTAssertNil(sign.rangeOfCharacter(from: .newlines), "sign of life of hostile string #\(index)")
            }
        }
    }

    func testAHostileTaskAmongNormalOnesLeavesTheOthersIntact() {
        let list = build([
            task("good", .shell, description: "npm run dev", started: ago(20)),
            task("bad", .shell, description: HostileContent.kitchenSink, started: ago(10)),
        ])
        XCTAssertEqual(ids(list.running), ["bad", "good"])
        XCTAssertEqual(list.running.last?.title, "npm run dev")
        XCTAssertEqual(list.chip, .running(2))
    }
}
