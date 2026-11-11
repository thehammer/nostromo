// NostromoKit — TrackerWaitingSourcesTests.swift
//
// "Waiting on you" and the background summary row (T5, PRD 49 and 50): what each source lists,
// the order the strip lists them in, the count and title, the one-line background summary built
// from BA's chip, and the tracker as a producer of the app-wide "needs you" source.
//
// Pure: `now` and the time zone are passed in; nothing reads the clock, the pasteboard or
// UserDefaults. Boards come from the golden frame through `TrackerFixtures.edited`, so every test
// exercises the real wire decoder.

import XCTest
@testable import NostromoKit

private typealias TFx = TrackerFixtures

// MARK: - Fixtures

private enum WaitFx {
    static let tag = "kate-1"

    /// The golden board with nothing waiting: no `needs-you` item, every item a plain item and not
    /// ran. `configure` then makes exactly what a test needs.
    static func quietBoard(_ configure: (inout TFx.Edit) throws -> Void = { _ in }) throws -> TrackerBoardViewWire {
        try TFx.edited { edit in
            edit.nodes = edit.nodes.map { node in
                var copy = node
                if copy["type"] as? String == "item" {
                    if copy["status"] as? String == "needs-you" { copy["status"] = "todo" }
                    copy["kind"] = "item"
                    copy["ran"] = false
                }
                return copy
            }
            try configure(&edit)
        }
    }

    static func makeCommand(_ edit: inout TFx.Edit, _ id: String, ran: Bool = false, status: String? = nil) throws {
        try edit.updateItem(id) { item in
            item["kind"] = "command"
            item["ran"] = ran
            if let status { item["status"] = status }
        }
    }

    /// The board from the PRD: 2 needs-you items, 1 un-run command, 1 ran command.
    static func prdBoard() throws -> TrackerBoardViewWire {
        try quietBoard { edit in
            try edit.setStatus("docum-1740", "needs-you")
            try edit.setStatus("backf-1777", "needs-you")
            try makeCommand(&edit, "retry-1074", ran: false, status: "blocked")
            try makeCommand(&edit, "verif-1481", ran: true)
        }
    }

    static func entries(_ source: TrackerWaitingSource, _ board: TrackerBoardViewWire) -> [TrackerWaitingEntry] {
        source.waitingEntries(board: board)
    }

    static func keys(_ entries: [TrackerWaitingEntry]) -> [String] { entries.map(\.key) }

    static func present(_ board: TrackerBoardViewWire, sources: [TrackerWaitingSource]) -> TrackerPresentation {
        TrackerPresenter.present(board: board, now: TFx.now, sources: sources, timeZone: TFx.utc)
    }

    static func task(_ id: String, _ status: TaskStatusWire, ended: UInt64? = nil, kind: TaskKindWire = .agent,
                     housekeeping: Bool = false, backgrounded: Bool? = nil, parent: String? = nil,
                     description: String? = nil) -> TaskMetaWire {
        TaskMetaWire(id: id, kind: kind, description: description ?? "work \(id)", parentTaskId: parent,
                     isBackgrounded: backgrounded, housekeeping: housekeeping, status: status,
                     startedAtMs: 1_000, endedAtMs: ended)
    }
}

// MARK: - Sources

final class TrackerWaitingSourcesTests: XCTestCase {

    // MARK: Un-run commands

    func testOnlyUnrunOpenCommandsAreListedAndRanCommandsAndPlainItemsAreNot() throws {
        let board = try WaitFx.prdBoard()
        let entries = WaitFx.entries(TrackerUnrunCommandSource(), board)
        XCTAssertEqual(WaitFx.keys(entries), ["item:retry-1074"], "the un-run command only")
        XCTAssertEqual(entries.first?.text, "Retry retry backoff")
        XCTAssertEqual(entries.first?.detail, "Now", "its section's title")
        XCTAssertEqual(entries.first?.target, .boardItem("retry-1074"))
        XCTAssertEqual(entries.first?.weight, 1)
    }

    func testCommandListingFollowsKindRanAndDoneAsATable() throws {
        // (kind, ran, status, listed)
        let table: [(String, Bool, String, Bool)] = [
            ("command", false, "todo", true),
            ("command", false, "in-progress", true),
            ("command", false, "blocked", true),
            ("command", true, "todo", false),
            ("command", true, "in-progress", false),
            ("command", false, "done", false),
            ("item", false, "todo", false),
            ("item", true, "todo", false),
        ]
        for (kind, ran, status, listed) in table {
            let board = try WaitFx.quietBoard { edit in
                try edit.updateItem("revie-1111") { item in
                    item["kind"] = kind
                    item["ran"] = ran
                    item["status"] = status
                }
            }
            let keys = WaitFx.keys(WaitFx.entries(TrackerUnrunCommandSource(), board))
            XCTAssertEqual(keys.contains("item:revie-1111"), listed, "kind \(kind), ran \(ran), status \(status)")
        }
    }

    func testCommandsAreListedInFileOrder() throws {
        let board = try WaitFx.quietBoard { edit in
            try WaitFx.makeCommand(&edit, "rotat-2702")   // Findings, last in the file
            try WaitFx.makeCommand(&edit, "verif-1481")   // Next
            try WaitFx.makeCommand(&edit, "retry-1074")   // Now, first in the file
        }
        XCTAssertEqual(WaitFx.keys(WaitFx.entries(TrackerUnrunCommandSource(), board)),
                       ["item:retry-1074", "item:verif-1481", "item:rotat-2702"])
    }

    func testNoCommandsMeansNoEntries() throws {
        XCTAssertEqual(WaitFx.entries(TrackerUnrunCommandSource(), try WaitFx.quietBoard()), [])
    }

    // MARK: Needs-you items

    func testNeedsYouItemsAreListedWithTheirBoardItemAsTheTarget() throws {
        let board = try WaitFx.prdBoard()
        let entries = WaitFx.entries(TrackerNeedsYouSource(), board)
        XCTAssertEqual(WaitFx.keys(entries), ["item:docum-1740", "item:backf-1777"])
        XCTAssertEqual(entries.map(\.target), [.boardItem("docum-1740"), .boardItem("backf-1777")])
        XCTAssertEqual(entries.first?.detail, "Waiting on you")
    }

    // MARK: Approvals

    func testApprovalsAreOneEntryWithOnlyACountAndALinkToTheFocus() throws {
        let board = try WaitFx.quietBoard()
        let table: [(pending: Int, text: String)] = [(1, "1 approval waiting"), (2, "2 approvals waiting"),
                                                      (3, "3 approvals waiting"), (12, "12 approvals waiting")]
        for (pending, text) in table {
            let entries = TrackerApprovalsSource(tag: WaitFx.tag, pendingCount: pending).waitingEntries(board: board)
            XCTAssertEqual(entries.count, 1, "\(pending) pending is one row")
            XCTAssertEqual(entries.first?.text, text, "the text is the count and nothing else")
            XCTAssertEqual(entries.first?.target, .approvals(WaitFx.tag))
            XCTAssertEqual(entries.first?.weight, pending, "it stands for as many as are pending, like the sidebar pill")
        }
    }

    func testNoPendingApprovalsMeansNoEntry() throws {
        XCTAssertEqual(TrackerApprovalsSource(tag: WaitFx.tag, pendingCount: 0)
                        .waitingEntries(board: try WaitFx.quietBoard()), [])
    }

    // MARK: Decisions

    func testDecisionsAreListedInTheOrderGivenWithTheirRequestIdAsTheTarget() throws {
        let source = TrackerDecisionSource(decisions: [
            TrackerDecisionSummary(requestId: "r1", text: "Ship it?"),
            TrackerDecisionSummary(requestId: "r2", text: "Which branch?")])
        let entries = WaitFx.entries(source, try WaitFx.quietBoard())
        XCTAssertEqual(WaitFx.keys(entries), ["decision:r1", "decision:r2"])
        XCTAssertEqual(entries.map(\.text), ["Ship it?", "Which branch?"])
        XCTAssertEqual(entries.map(\.target), [.decision("r1"), .decision("r2")])
    }

    // MARK: Failed background tasks

    func testFailedTaskListingFollowsStatusHousekeepingKindAndTheSeenMarkAsATable() throws {
        typealias Row = (name: String, task: TaskMetaWire, seen: UInt64?, listed: Bool)
        let table: [Row] = [
            ("failed, never seen", WaitFx.task("t", .failed, ended: 100), nil, true),
            ("failed after the seen mark", WaitFx.task("t", .failed, ended: 101), 100, true),
            ("failed at the seen mark", WaitFx.task("t", .failed, ended: 100), 100, false),
            ("failed before the seen mark", WaitFx.task("t", .failed, ended: 50), 100, false),
            ("failed with no end time, never seen", WaitFx.task("t", .failed), nil, true),
            ("failed with no end time, something seen", WaitFx.task("t", .failed), 10, false),
            ("running", WaitFx.task("t", .running), nil, false),
            ("pending", WaitFx.task("t", .pending), nil, false),
            ("paused", WaitFx.task("t", .paused), nil, false),
            ("completed", WaitFx.task("t", .completed, ended: 100), nil, false),
            ("stopped", WaitFx.task("t", .stopped, ended: 100), nil, false),
            ("housekeeping failure", WaitFx.task("t", .failed, ended: 100, housekeeping: true), nil, false),
            ("foreground shell failure (not listed by BA)", WaitFx.task("t", .failed, ended: 100, kind: .shell), nil, false),
            ("background shell failure", WaitFx.task("t", .failed, ended: 100, kind: .shell, backgrounded: true), nil, true),
            ("monitor failure", WaitFx.task("t", .failed, ended: 100, kind: .monitor), nil, true),
            ("workflow failure", WaitFx.task("t", .failed, ended: 100, kind: .workflow), nil, true),
        ]
        let board = try WaitFx.quietBoard()
        for row in table {
            let source = TrackerFailedTaskSource(tasks: [row.task], seenEndedAtMs: row.seen)
            XCTAssertEqual(source.waitingEntries(board: board).count, row.listed ? 1 : 0, row.name)
        }
    }

    func testFailedTasksAreListedNewestFailureFirstWithTheirTitleAndTheTaskAsTheTarget() throws {
        let tasks = [
            WaitFx.task("old", .failed, ended: 100, description: "the old one"),
            WaitFx.task("new", .failed, ended: 300, description: "the new one"),
            WaitFx.task("mid", .failed, ended: 200, description: "the middle one"),
            WaitFx.task("fine", .completed, ended: 400),
            WaitFx.task("busy", .running),
        ]
        let entries = WaitFx.entries(TrackerFailedTaskSource(tasks: tasks, seenEndedAtMs: nil), try WaitFx.quietBoard())
        XCTAssertEqual(WaitFx.keys(entries), ["task:new", "task:mid", "task:old"])
        XCTAssertEqual(entries.first?.text, BackgroundTaskList.title(tasks[1]))
        XCTAssertEqual(entries.first?.target, .backgroundTask("new"))
    }

    func testATaskThatWasFailedAndIsNowRunningAgainIsNotListed() throws {
        // BA's list keeps the later entry for an id; so does this source.
        let tasks = [WaitFx.task("t", .failed, ended: 100), WaitFx.task("t", .running)]
        XCTAssertEqual(TrackerFailedTaskSource(tasks: tasks, seenEndedAtMs: nil)
                        .waitingEntries(board: try WaitFx.quietBoard()), [])
    }

    // MARK: Order, count and title

    func testTheStripListsApprovalsDecisionsCommandsNeedsYouThenFailedTasksAndCountsApprovalsByTheirNumber() throws {
        let board = try WaitFx.prdBoard()
        let sources = TrackerWaitingSources.make(
            tag: WaitFx.tag,
            approvalsPending: 3,
            decisions: [TrackerDecisionSummary(requestId: "d1", text: "Ship it?"),
                        TrackerDecisionSummary(requestId: "d2", text: "Which branch?")],
            tasks: [WaitFx.task("bg", .failed, ended: 100), WaitFx.task("ok", .completed, ended: 100)],
            seenEndedAtMs: nil)
        let strip = WaitFx.present(board, sources: sources).strip
        XCTAssertEqual(WaitFx.keys(strip.entries),
                       ["approvals", "decision:d1", "decision:d2", "item:retry-1074",
                        "item:docum-1740", "item:backf-1777", "task:bg"])
        XCTAssertEqual(strip.count, 9, "3 approvals + 2 decisions + 1 command + 2 needs-you + 1 failed task")
        XCTAssertEqual(strip.title, "Waiting on you (9)")
    }

    func testThePRDFixtureListsFiveRowsInOrderAndTitlesThemWaitingOnYouFive() throws {
        let board = try WaitFx.prdBoard()
        let sources = TrackerWaitingSources.make(
            tag: WaitFx.tag, approvalsPending: 0,
            decisions: [TrackerDecisionSummary(requestId: "d1", text: "Ship it?")],
            tasks: [WaitFx.task("bg", .failed, ended: 100)], seenEndedAtMs: nil)
        let strip = WaitFx.present(board, sources: sources).strip
        XCTAssertEqual(WaitFx.keys(strip.entries),
                       ["decision:d1", "item:retry-1074", "item:docum-1740", "item:backf-1777", "task:bg"])
        XCTAssertEqual(strip.title, "Waiting on you (5)")
    }

    func testAnItemThatIsBothAnUnrunCommandAndNeedsYouIsListedOnce() throws {
        let board = try WaitFx.quietBoard { edit in
            try WaitFx.makeCommand(&edit, "docum-1740", ran: false, status: "needs-you")
            try edit.setStatus("backf-1777", "needs-you")
        }
        let sources = TrackerWaitingSources.make(tag: WaitFx.tag, approvalsPending: 0, decisions: [], tasks: [],
                                                 seenEndedAtMs: nil)
        let strip = WaitFx.present(board, sources: sources).strip
        XCTAssertEqual(WaitFx.keys(strip.entries), ["item:docum-1740", "item:backf-1777"])
        XCTAssertEqual(strip.title, "Waiting on you (2)")
    }

    func testNothingWaitingGivesAnEmptyStrip() throws {
        let sources = TrackerWaitingSources.make(tag: WaitFx.tag, approvalsPending: 0, decisions: [], tasks: [],
                                                 seenEndedAtMs: nil)
        let strip = WaitFx.present(try WaitFx.quietBoard(), sources: sources).strip
        XCTAssertEqual(strip.entries, [])
        XCTAssertEqual(strip.count, 0)
    }
}

// MARK: - The background summary row (PRD 50)

final class TrackerBackgroundSummaryTests: XCTestCase {

    private enum Step {
        case snapshot([TaskMetaWire], chip: String)
        /// The popover was opened: everything that has ended is seen.
        case seen(chip: String)
    }

    private typealias T = WaitFx

    /// 25 snapshots: tasks start, finish, fail, are stopped, are housekeeping, are not listed, and are seen.
    private func script() -> [Step] {
        let a1 = T.task("A", .running), b1 = T.task("B", .running)
        let h = T.task("H", .running, housekeeping: true)
        let c1 = T.task("C", .running, parent: "A")
        let aDone = T.task("A", .completed, ended: 10), bFailed = T.task("B", .failed, ended: 20)
        let cDone = T.task("C", .completed, ended: 30)
        let d1 = T.task("D", .running), dFailed = T.task("D", .failed, ended: 40)
        let dDone = T.task("D", .completed, ended: 40), eFailed = T.task("E", .failed, ended: 50)
        let fStopped = T.task("F", .stopped, ended: 60)
        let g1 = T.task("G", .running), gPaused = T.task("G", .paused), gWeird = T.task("G", .unknown("weird"))
        let gFailed = T.task("G", .failed, ended: 70)
        let shellFg = T.task("S", .failed, ended: 80, kind: .shell)
        let shellBg = T.task("S", .failed, ended: 80, kind: .shell, backgrounded: true)
        let ended1 = [aDone, bFailed, cDone]
        let ended2 = ended1 + [dFailed, eFailed]
        let hundred = (0..<100).map { T.task("W\($0)", .running) }
        return [
            .snapshot([], chip: "hidden"),
            .snapshot([a1], chip: "running"),
            .snapshot([a1, b1], chip: "running"),
            .snapshot([a1, b1, h], chip: "running"),
            .snapshot([a1, b1, c1], chip: "running"),
            .snapshot([aDone, b1, c1], chip: "running"),
            .snapshot([aDone, bFailed, c1], chip: "running"),
            .snapshot(ended1, chip: "failed"),
            .seen(chip: "hidden"),
            .snapshot(ended1 + [d1], chip: "running"),
            .snapshot(ended1 + [dFailed], chip: "failed"),
            .snapshot(ended2, chip: "failed"),
            .snapshot(ended1 + [dDone, eFailed], chip: "failed"),
            .seen(chip: "hidden"),
            .snapshot(ended2 + [fStopped], chip: "done"),
            .snapshot(ended2 + [fStopped, g1], chip: "running"),
            .snapshot(ended2 + [fStopped, gPaused], chip: "running"),
            .snapshot(ended2 + [fStopped, gWeird], chip: "running"),
            .snapshot(ended2 + [fStopped, gFailed, shellFg], chip: "failed"),
            .snapshot(ended2 + [fStopped, gFailed, shellBg], chip: "failed"),
            .seen(chip: "hidden"),
            .snapshot([], chip: "hidden"),
            .snapshot([T.task("X", .running)], chip: "running"),
            .snapshot(hundred, chip: "running"),
            .snapshot([], chip: "hidden"),
        ]
    }

    func testTheSummaryTextIsTheChipTextAtEveryStepOfAScriptedFixture() {
        let steps = script()
        XCTAssertGreaterThanOrEqual(steps.count, 20)
        var tasks: [TaskMetaWire] = []
        var seen: UInt64?
        var visited = Set<String>()
        for (index, step) in steps.enumerated() {
            let expectedChip: String
            switch step {
            case .snapshot(let next, let chip):
                tasks = next
                expectedChip = chip
            case .seen(let chip):
                seen = BackgroundTaskList.seenMark(of: tasks) ?? seen
                expectedChip = chip
            }
            let list = BackgroundTaskList.make(tasks: tasks, nowMs: 5_000, seenEndedAtMs: seen)
            let summary = TrackerBackgroundSummary(list: list)
            XCTAssertEqual(list.chip.name, expectedChip, "step \(index): the fixture is what it says")
            XCTAssertEqual(summary.text, list.chip.text.map { $0 + " in the background" }, "step \(index)")
            XCTAssertEqual(summary.isHidden, list.chip == .hidden, "step \(index): hidden iff the chip is")
            XCTAssertEqual(summary.text == nil, summary.isHidden, "step \(index)")
            XCTAssertEqual(summary, TrackerBackgroundSummary(chip: list.chip), "step \(index): built from the chip alone")
            visited.insert(list.chip.name)
        }
        XCTAssertEqual(visited, ["hidden", "running", "done", "failed"], "the script visits every chip state")
    }

    func testTheSummaryReadsTheChipsOwnWordsAndNothingElse() {
        XCTAssertEqual(TrackerBackgroundSummary(chip: .running(2)).text, "\u{25F7} 2 running in the background")
        XCTAssertEqual(TrackerBackgroundSummary(chip: .done(3)).text, "\u{2713} 3 done in the background")
        XCTAssertEqual(TrackerBackgroundSummary(chip: .failed(1)).text, "\u{2715} 1 failed in the background")
        XCTAssertEqual(TrackerBackgroundSummary(chip: .running(100)).text, "\u{25F7} 99+ running in the background",
                       "BA's own cap")
        XCTAssertNil(TrackerBackgroundSummary(chip: .hidden).text)
        XCTAssertTrue(TrackerBackgroundSummary(chip: .hidden).isHidden)
        XCTAssertFalse(TrackerBackgroundSummary(chip: .running(1)).isHidden)
        XCTAssertEqual(TrackerBackgroundSummary(chip: .failed(2)).accessibilityLabel,
                       BackgroundChipState.failed(2).accessibilityLabel)
    }
}

// MARK: - The tracker as a producer for the app-wide "needs you" source

final class TrackerNeedsYouProducerTests: XCTestCase {

    private let sentinel = "SENTINEL-tracker-text"

    private func board() throws -> TrackerBoardViewWire {
        try WaitFx.quietBoard { edit in
            try edit.setStatus("docum-1740", "needs-you")
            try edit.setStatus("backf-1777", "needs-you")
            try WaitFx.makeCommand(&edit, "retry-1074")
            try WaitFx.makeCommand(&edit, "verif-1481", ran: true)
            for id in ["docum-1740", "backf-1777", "retry-1074", "verif-1481"] {
                try edit.setText(id, "\(sentinel) \(id)")
            }
        }
    }

    func testEachWaitingItemIsOneContentFreeItemForTheFocus() throws {
        let items = TrackerNeedsYouProducer.items(tag: WaitFx.tag, board: try board())
        XCTAssertEqual(items.count, 3, "2 needs-you items and 1 un-run command; the ran command is not waiting")
        for item in items {
            XCTAssertTrue(item.id.hasPrefix("tracker:"), item.id)
            XCTAssertEqual(item.reason, .trackerWaiting)
            XCTAssertEqual(item.source, .focus(WaitFx.tag))
            XCTAssertFalse(item.sensitive)
        }
        XCTAssertEqual(Set(items.map(\.id)).count, 3, "ids are unique")
        XCTAssertTrue(items.allSatisfy { $0.producer == TrackerNeedsYouProducer.name })
    }

    func testNoTrackerTextAppearsAnywhereInTheItems() throws {
        let board = try board()
        let strip = WaitFx.present(board, sources: [TrackerNeedsYouSource(), TrackerUnrunCommandSource()]).strip
        XCTAssertTrue(strip.entries.allSatisfy { $0.text.contains(sentinel) }, "setup: the strip does carry the text")

        let items = TrackerNeedsYouProducer.items(tag: WaitFx.tag, board: board)
        XCTAssertFalse(items.isEmpty)
        for item in items {
            let described = String(describing: item)
            XCTAssertFalse(described.contains(sentinel), "item text leaked: \(described)")
            XCTAssertFalse(described.contains("backoff") || described.contains("webhook"),
                           "no words of a board item: \(described)")
        }
    }

    func testAnItemBothNeedsYouAndAnUnrunCommandIsOneItem() throws {
        let board = try WaitFx.quietBoard { edit in
            try WaitFx.makeCommand(&edit, "docum-1740", ran: false, status: "needs-you")
        }
        XCTAssertEqual(TrackerNeedsYouProducer.items(tag: WaitFx.tag, board: board).count, 1)
    }

    func testABoardWithNothingWaitingRaisesNothing() throws {
        XCTAssertEqual(TrackerNeedsYouProducer.items(tag: WaitFx.tag, board: try WaitFx.quietBoard()), [])
    }

    func testTheAggregatorCountsTheFocusAndWithdrawingClearsIt() throws {
        var aggregator = NeedsYouAggregator()
        let items = TrackerNeedsYouProducer.items(tag: WaitFx.tag, board: try board())
        let raised = aggregator.set(producer: TrackerNeedsYouProducer.name, items: items)
        XCTAssertEqual(raised.perFocus[WaitFx.tag], 3)
        XCTAssertEqual(raised.total, 3)

        // Another producer's items for the same focus are counted beside, and survive a withdrawal.
        let other = NeedsYouItem(id: "approvals:\(WaitFx.tag)", source: .focus(WaitFx.tag), reason: .approvalPending(1))
        let both = aggregator.set(producer: "approvals", items: [other])
        XCTAssertEqual(both.perFocus[WaitFx.tag], 4)

        let withdrawn = aggregator.set(producer: TrackerNeedsYouProducer.name, items: [])
        XCTAssertEqual(withdrawn.perFocus[WaitFx.tag], 1, "only the other producer's item is left")
        XCTAssertEqual(withdrawn.total, 1)

        let cleared = aggregator.set(producer: "approvals", items: [])
        XCTAssertEqual(cleared, .empty)
    }

    func testTwoFocusesAreCountedSeparately() throws {
        var aggregator = NeedsYouAggregator()
        let board = try board()
        let items = TrackerNeedsYouProducer.items(tag: "a", board: board)
            + TrackerNeedsYouProducer.items(tag: "b", board: try WaitFx.quietBoard { edit in
                try edit.setStatus("docum-1740", "needs-you")
            })
        let snapshot = aggregator.set(producer: TrackerNeedsYouProducer.name, items: items)
        XCTAssertEqual(snapshot.perFocus, ["a": 3, "b": 1])
        XCTAssertEqual(snapshot.total, 4)
    }
}
