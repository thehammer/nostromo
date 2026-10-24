import XCTest
import NostromoKit

// `nostromo-app tasks list [--all]` and `tasks chip` (BA3): read-only probes whose answers must equal
// what the popover and the chip show at the same moment. `AppControlTasks` is a pure formatter of the
// same `BackgroundTaskList` the popover model reads from `BackgroundTaskStore`, so the tests build one
// store state, read the list the popover would show, and compare the JSON with it row by row.
//
// Unknown values are `null` in the JSON, never zero (PRD "The popover"). Time is a fixed clock.

final class AppControlTasksTests: XCTestCase {

    private typealias Obj = [String: Any]

    private let startMs: UInt64 = 1_760_000_000_000
    private let tag = "kate"

    /// The fifteen keys every task has, and no others.
    private let rowKeys: Set<String> = [
        "id", "section", "kind", "kind_name", "title", "description", "status", "elapsed_ms", "duration_ms",
        "ended_ago_ms", "sign_of_life", "parent_id", "depth", "housekeeping", "stop_offered",
    ]

    // MARK: - Fixture

    private func task(_ id: String,
                      _ kind: TaskKindWire = .shell,
                      status: TaskStatusWire = .running,
                      description: String = "",
                      taskType: String = "",
                      subagentType: String? = nil,
                      parent: String? = nil,
                      background: Bool? = true,
                      housekeeping: Bool = false,
                      started: UInt64? = nil,
                      ended: UInt64? = nil,
                      tokens: UInt64? = nil,
                      tools: UInt64? = nil,
                      lastTool: String? = nil) -> TaskMetaWire {
        TaskMetaWire(id: id, taskType: taskType, kind: kind, description: description, subagentType: subagentType,
                     parentTaskId: parent, isBackgrounded: background, housekeeping: housekeeping, status: status,
                     startedAtMs: started, endedAtMs: ended, totalTokens: tokens, toolUses: tools, lastToolName: lastTool)
    }

    /// A store (private defaults suite, fixed clock) holding one busy focus: four running tasks (a shell, an
    /// agent with a child shell, a task of an unknown kind with no start time), two ended ones, one chore.
    private func makeBusyStore() throws -> BackgroundTaskStore {
        let suite = "AppControlTasksTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = BackgroundTaskStore(now: { now }, schedule: { _, _ in }, defaults: defaults)
        let tasks = [
            task("b1", .shell, description: "npm run dev", taskType: "local_bash", started: startMs - 4_100),
            task("a1", .agent, description: "Write failing tests", taskType: "local_agent", subagentType: "redd",
                 started: startMs - 120_000, tokens: 18_234, tools: 11, lastTool: "Edit"),
            task("c1", .shell, description: "cargo test -p nostromo", taskType: "local_bash", parent: "a1",
                 started: startMs - 10_000),
            task("o1", .other, description: "Review the PR", background: nil, started: nil),
            task("e1", .shell, status: .completed, description: "npm run build", taskType: "local_bash",
                 started: startMs - 300_000, ended: startMs - 240_000),
            task("e2", .agent, status: .failed, description: "Find callers", taskType: "local_agent",
                 subagentType: "explore", started: startMs - 500_000, ended: startMs - 460_000),
            task("h1", .other, description: "ambient watcher", taskType: "dream", background: nil, housekeeping: true,
                 started: startMs - 900_000),
        ]
        store.ingest(.sessionTasks(SessionTasksWire(tag: tag, sessionId: "s1", daemonEpoch: "e1", stopSupported: true,
                                                    tasks: tasks)))
        store.ingest(.sessionTaskDetail(SessionTaskDetailWire(tag: tag, taskId: "b1", preview: "ready on :3000")))
        return store
    }

    // MARK: - Reading the JSON

    private func objects(_ value: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> [Obj] {
        guard let list = value as? [Obj] else {
            XCTFail("\(what) is not a list of objects: \(String(describing: value))", file: file, line: line)
            return []
        }
        return list
    }

    private func object(_ value: Any?, _ what: String, file: StaticString = #filePath, line: UInt = #line) -> Obj {
        guard let object = value as? Obj else {
            XCTFail("\(what) is not an object: \(String(describing: value))", file: file, line: line)
            return [:]
        }
        return object
    }

    private func indexed(_ tasks: [Obj]) -> [String: Obj] {
        var out: [String: Obj] = [:]
        for json in tasks {
            if let id = json["id"] as? String { out[id] = json }
        }
        return out
    }

    /// A JSON number as the unsigned value it carries; nil for null or anything else.
    private func number(_ value: Any?) -> UInt64? { (value as? NSNumber)?.uint64Value }

    private func isNull(_ value: Any?) -> Bool { value is NSNull }

    private func assertValidJSON(_ report: Obj, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(report), "\(what) is not valid JSON", file: file, line: line)
        guard let data = try? JSONSerialization.data(withJSONObject: report),
              let back = try? JSONSerialization.jsonObject(with: data) as? Obj
        else { return XCTFail("\(what) does not round-trip through JSON", file: file, line: line) }
        XCTAssertEqual(Set(back.keys), Set(report.keys), file: file, line: line)
    }

    // MARK: - tasks list equals the popover's running section

    func testTasksListReportsTheRunningRowsThePopoverShowsInTheSameOrder() throws {
        let store = try makeBusyStore()
        let list = store.list(for: tag)
        let report = AppControlTasks.list(tag: tag, list: list, all: false)

        XCTAssertEqual(report["tag"] as? String, tag)
        XCTAssertEqual(report["running"] as? Int, list.running.count)
        XCTAssertEqual(list.running.count, 4, "the fixture shows four running rows")
        let tasks = objects(report["tasks"], "tasks")
        XCTAssertEqual(tasks.compactMap { $0["id"] as? String }, list.running.map(\.id))
        XCTAssertEqual(tasks.compactMap { $0["id"] as? String }, ["b1", "a1", "c1", "o1"],
                       "the popover's order: newest first, the child under its parent, an unknown start last")

        for (json, row) in zip(tasks, list.running) {
            XCTAssertEqual(json["id"] as? String, row.id)
            XCTAssertEqual(json["section"] as? String, "running", row.id)
            XCTAssertEqual(json["kind"] as? String, row.kindLabel, row.id)
            XCTAssertEqual(json["title"] as? String, row.title, row.id)
            XCTAssertEqual(json["description"] as? String, row.description, row.id)
            XCTAssertEqual(json["status"] as? String, row.statusLabel, row.id)
            XCTAssertEqual(number(json["elapsed_ms"]), row.elapsedMs, row.id)
            XCTAssertEqual(json["depth"] as? Int, row.depth, row.id)
            XCTAssertEqual(json["housekeeping"] as? Bool, row.isHousekeeping, row.id)
            XCTAssertEqual(json["stop_offered"] as? Bool, row.stopOffered, row.id)
            XCTAssertEqual(json["parent_id"] as? String, row.parentId, row.id)
            XCTAssertEqual(json["sign_of_life"] as? String, row.signOfLife, row.id)
            XCTAssertEqual(json["kind_name"] as? String, row.kindName, row.id)
        }
    }

    func testTheReportedRowsCarryTheFactsTheRowsShow() throws {
        let store = try makeBusyStore()
        let report = AppControlTasks.list(tag: tag, list: store.list(for: tag), all: false)
        let byId = indexed(objects(report["tasks"], "tasks"))

        let shell = object(byId["b1"], "b1")
        XCTAssertEqual(shell["kind"] as? String, "Shell")
        XCTAssertEqual(shell["kind_name"] as? String, "local_bash")
        XCTAssertEqual(shell["title"] as? String, "npm run dev")
        XCTAssertEqual(shell["status"] as? String, "running")
        XCTAssertEqual(number(shell["elapsed_ms"]), 4_100)
        XCTAssertEqual(shell["sign_of_life"] as? String, "last: ready on :3000")
        XCTAssertEqual(shell["depth"] as? Int, 0)
        XCTAssertEqual(shell["stop_offered"] as? Bool, true)
        XCTAssertEqual(shell["housekeeping"] as? Bool, false)

        let agent = object(byId["a1"], "a1")
        XCTAssertEqual(agent["kind"] as? String, "Agent")
        XCTAssertEqual(agent["title"] as? String, "redd \u{00B7} Write failing tests")
        XCTAssertEqual(agent["sign_of_life"] as? String, "18.2k tokens \u{00B7} 11 tools \u{00B7} Edit")

        let child = object(byId["c1"], "c1")
        XCTAssertEqual(child["parent_id"] as? String, "a1")
        XCTAssertEqual(child["depth"] as? Int, 1)
    }

    func testTasksListWithoutAllLeavesOutTheEndedAndHousekeepingRows() throws {
        let store = try makeBusyStore()
        let report = AppControlTasks.list(tag: tag, list: store.list(for: tag), all: false)
        let ids = objects(report["tasks"], "tasks").compactMap { $0["id"] as? String }
        XCTAssertFalse(ids.contains("e1"))
        XCTAssertFalse(ids.contains("e2"))
        XCTAssertFalse(ids.contains("h1"))
    }

    func testTasksListAllAddsEndedThenHousekeepingRowsEachWithItsSection() throws {
        let store = try makeBusyStore()
        let list = store.list(for: tag)
        let report = AppControlTasks.list(tag: tag, list: list, all: true)
        let tasks = objects(report["tasks"], "tasks")

        XCTAssertEqual(tasks.compactMap { $0["id"] as? String }, list.allRows.map(\.id))
        XCTAssertEqual(tasks.compactMap { $0["section"] as? String },
                       ["running", "running", "running", "running", "ended", "ended", "housekeeping"])
        XCTAssertEqual(report["running"] as? Int, 4, "the running count is the running section's, whatever --all adds")

        let ended = tasks.filter { ($0["section"] as? String) == "ended" }
        XCTAssertEqual(ended.compactMap { $0["id"] as? String }, ["e1", "e2"], "most recently ended first")
        XCTAssertEqual(ended.compactMap { $0["status"] as? String }, ["completed", "failed"])
        let chore = try XCTUnwrap(tasks.last)
        XCTAssertEqual(chore["id"] as? String, "h1")
        XCTAssertEqual(chore["housekeeping"] as? Bool, true)
        XCTAssertEqual(chore["status"] as? String, "running")
    }

    // MARK: - Rows: running vs ended, unknown is null

    func testRunningRowsHaveElapsedAndNoDurationAndEndedRowsTheReverse() throws {
        let store = try makeBusyStore()
        let tasks = objects(AppControlTasks.list(tag: tag, list: store.list(for: tag), all: true)["tasks"], "tasks")

        for json in tasks where (json["section"] as? String) == "running" && (json["id"] as? String) != "o1" {
            let id = json["id"] as? String ?? "?"
            XCTAssertNotNil(number(json["elapsed_ms"]), "\(id) has an elapsed time")
            XCTAssertTrue(isNull(json["duration_ms"]), "\(id) has not finished: no duration")
            XCTAssertTrue(isNull(json["ended_ago_ms"]), "\(id) has not ended")
        }
        let byId = indexed(tasks)
        let done = object(byId["e1"], "e1")
        XCTAssertTrue(isNull(done["elapsed_ms"]), "an ended task has a duration, not an elapsed time")
        XCTAssertEqual(number(done["duration_ms"]), 60_000)
        XCTAssertEqual(number(done["ended_ago_ms"]), 240_000)
        let failed = object(byId["e2"], "e2")
        XCTAssertTrue(isNull(failed["elapsed_ms"]))
        XCTAssertEqual(number(failed["duration_ms"]), 40_000)
        XCTAssertEqual(number(failed["ended_ago_ms"]), 460_000)
        XCTAssertEqual(failed["status"] as? String, "failed")
    }

    func testEveryRowHasExactlyTheDocumentedKeys() throws {
        let store = try makeBusyStore()
        let tasks = objects(AppControlTasks.list(tag: tag, list: store.list(for: tag), all: true)["tasks"], "tasks")
        XCTAssertEqual(tasks.count, 7)
        for json in tasks {
            XCTAssertEqual(Set(json.keys), rowKeys, "row \(json["id"] as? String ?? "?")")
        }
        // The same keys from the row formatter itself.
        for row in store.list(for: tag).allRows {
            XCTAssertEqual(Set(AppControlTasks.row(row).keys), rowKeys, row.id)
        }
    }

    func testUnknownValuesAreNullNeverZero() throws {
        let store = try makeBusyStore()
        let tasks = objects(AppControlTasks.list(tag: tag, list: store.list(for: tag), all: true)["tasks"], "tasks")
        let byId = indexed(tasks)

        // A task of another kind with no start time, no kind name, no parent and nothing to say.
        let unknown = object(byId["o1"], "o1")
        XCTAssertEqual(unknown["kind"] as? String, "Other")
        for key in ["kind_name", "elapsed_ms", "duration_ms", "ended_ago_ms", "sign_of_life", "parent_id"] {
            XCTAssertTrue(isNull(unknown[key]), "o1.\(key) is null, not \(String(describing: unknown[key]))")
        }
        // Nothing the CLI did not say shows up as 0.
        XCTAssertTrue(isNull(object(byId["b1"], "b1")["parent_id"]))
        XCTAssertTrue(isNull(object(byId["e1"], "e1")["sign_of_life"]))
        XCTAssertEqual(object(byId["c1"], "c1")["kind_name"] as? String, "local_bash", "a kind name the CLI sent is reported")
    }

    func testAnEndedTaskWithNoTimesAtAllReportsNullDurationAndAgo() throws {
        let list = BackgroundTaskList.make(tasks: [task("e1", .agent, status: .completed, description: "x")], nowMs: startMs)
        let json = AppControlTasks.row(try XCTUnwrap(list.ended.first))
        XCTAssertTrue(isNull(json["duration_ms"]))
        XCTAssertTrue(isNull(json["ended_ago_ms"]))
        XCTAssertTrue(isNull(json["elapsed_ms"]))
    }

    // MARK: - tasks chip

    func testChipReportsTheTextAndStateTheChipShows() throws {
        let store = try makeBusyStore()
        let list = store.list(for: tag)
        let json = AppControlTasks.chip(tag: tag, list: list)
        XCTAssertEqual(json["tag"] as? String, tag)
        XCTAssertEqual(json["text"] as? String, list.chip.text)
        XCTAssertEqual(json["text"] as? String, "\u{25F7} 4 running")
        XCTAssertEqual(json["state"] as? String, "running")
        XCTAssertEqual(Set(json.keys), ["tag", "text", "state"])
        assertValidJSON(json, "the chip")

        let inList = object(AppControlTasks.list(tag: tag, list: list, all: false)["chip"], "chip in list")
        XCTAssertEqual(inList["text"] as? String, json["text"] as? String)
        XCTAssertEqual(inList["state"] as? String, "running")
    }

    func testChipStatesHiddenRunningDoneAndFailed() {
        let completed = task("c", .shell, status: .completed, description: "build", started: startMs - 60_000, ended: startMs - 30_000)
        let failed = task("f", .shell, status: .failed, description: "test", started: startMs - 60_000, ended: startMs - 20_000)
        let live = task("r", .shell, description: "dev", started: startMs - 10_000)
        let cases: [(name: String, tasks: [TaskMetaWire], text: String?, state: String)] = [
            ("nothing", [], nil, "hidden"),
            ("one running", [live], "\u{25F7} 1 running", "running"),
            ("one done", [completed], "\u{2713} 1 done", "done"),
            ("one failed", [failed], "\u{2715} 1 failed", "failed"),
            ("one done and one failed", [completed, failed], "\u{2715} 1 failed", "failed"),
        ]
        for c in cases {
            let list = BackgroundTaskList.make(tasks: c.tasks, nowMs: startMs)
            let json = AppControlTasks.chip(tag: tag, list: list)
            XCTAssertEqual(json["state"] as? String, c.state, c.name)
            if let text = c.text {
                XCTAssertEqual(json["text"] as? String, text, c.name)
            } else {
                XCTAssertTrue(isNull(json["text"]), "\(c.name): a hidden chip has null text")
            }
            XCTAssertEqual(json.keys.count, 3, c.name)
            assertValidJSON(json, c.name)
        }
    }

    func testAnEmptyFocusReportsAHiddenChipAndNoTasks() throws {
        let store = try makeBusyStore()
        let list = store.list(for: "nobody")
        let report = AppControlTasks.list(tag: "nobody", list: list, all: true)
        XCTAssertEqual(report["tag"] as? String, "nobody")
        XCTAssertEqual(report["running"] as? Int, 0)
        XCTAssertEqual(objects(report["tasks"], "tasks").count, 0)
        let chip = object(report["chip"], "chip")
        XCTAssertEqual(chip["state"] as? String, "hidden")
        XCTAssertTrue(isNull(chip["text"]))
        assertValidJSON(report, "the empty report")
    }

    // MARK: - JSON

    func testEveryReportIsValidJSONThatRoundTrips() throws {
        let store = try makeBusyStore()
        let list = store.list(for: tag)
        assertValidJSON(AppControlTasks.list(tag: tag, list: list, all: false), "tasks list")
        assertValidJSON(AppControlTasks.list(tag: tag, list: list, all: true), "tasks list --all")
        assertValidJSON(AppControlTasks.chip(tag: tag, list: list), "tasks chip")
        for row in list.allRows {
            assertValidJSON(AppControlTasks.row(row), "row \(row.id)")
        }

        let data = try JSONSerialization.data(withJSONObject: AppControlTasks.list(tag: tag, list: list, all: true))
        let back = object(try JSONSerialization.jsonObject(with: data), "the decoded report")
        let tasks = objects(back["tasks"], "decoded tasks")
        XCTAssertEqual(tasks.count, 7)
        XCTAssertTrue(tasks.contains { isNull($0["elapsed_ms"]) }, "nulls survive as JSON null")
        XCTAssertEqual(number(tasks.first { ($0["id"] as? String) == "b1" }?["elapsed_ms"]), 4_100)
    }

    func testHostileDescriptionsStillMakeValidJSONAndOneLineTitles() throws {
        let hostile = "first\nsecond\r\nthird\t\u{1B}[31mred\u{1B}[0m \u{202E}evil\u{0}nul " + String(repeating: "x", count: 10_240)
        let list = BackgroundTaskList.make(
            tasks: [task("h1", .shell, description: hostile, started: startMs - 1_000),
                    task("h2", .agent, status: .failed, description: hostile, subagentType: "ex\nplore",
                         started: startMs - 5_000, ended: startMs - 1_000)],
            details: ["h1": SessionTaskDetailWire(tag: tag, taskId: "h1", preview: hostile)],
            nowMs: startMs)
        let report = AppControlTasks.list(tag: tag, list: list, all: true)
        assertValidJSON(report, "the hostile report")
        let tasks = objects(report["tasks"], "tasks")
        XCTAssertEqual(tasks.count, 2)
        for json in tasks {
            let title = json["title"] as? String ?? ""
            XCTAssertNil(title.rangeOfCharacter(from: .newlines), "one-line title")
            XCTAssertEqual(json["description"] as? String, hostile, "the description is reported verbatim")
            if let sign = json["sign_of_life"] as? String {
                XCTAssertNil(sign.rangeOfCharacter(from: .newlines), "one-line sign of life")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report)
        let back = object(try JSONSerialization.jsonObject(with: data), "decoded")
        XCTAssertEqual(objects(back["tasks"], "tasks").first?["description"] as? String, hostile, "and it survives the round trip")
    }
}
