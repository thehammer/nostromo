import XCTest
import AppKit
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

    /// The sixteen keys every task has, and no others (`window_open` is the one BA4 added).
    private let rowKeys: Set<String> = [
        "id", "section", "kind", "kind_name", "title", "description", "status", "elapsed_ms", "duration_ms",
        "ended_ago_ms", "sign_of_life", "parent_id", "depth", "housekeeping", "stop_offered", "window_open",
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

    // MARK: - `--focus TAG` must name a focus the app knows

    func testAKnownFocusIsAccepted() {
        XCTAssertNoThrow(try AppControlTasks.requireKnownFocus("kate", known: ["kate", "cody"]))
        XCTAssertNoThrow(try AppControlTasks.requireKnownFocus("cody", known: ["kate", "cody"]))
        XCTAssertNoThrow(try AppControlTasks.requireKnownFocus("only", known: ["only"]))
    }

    func testAnUnknownFocusIsNotFoundAndNamesTheTagAndTheKnownOnesSorted() {
        XCTAssertThrowsError(try AppControlTasks.requireKnownFocus("kaet", known: ["cody", "kate", "ada"])) { error in
            guard case .notFound(let detail)? = error as? AppControlError else {
                return XCTFail("a typo is `notFound`, not \(error)")
            }
            XCTAssertTrue(detail.contains("kaet"), "the message names the tag that was asked for: \(detail)")
            let message = (error as? AppControlError)?.message ?? ""
            XCTAssertTrue(message.contains("kaet"), "and so does the message the caller reads: \(message)")
            let positions = ["ada", "cody", "kate"].compactMap { detail.range(of: $0)?.lowerBound }
            XCTAssertEqual(positions.count, 3, "every known tag is listed: \(detail)")
            XCTAssertEqual(positions, positions.sorted(), "known tags are listed in sorted order: \(detail)")
        }
    }

    func testAFocusIsMatchedExactlyNotByCaseOrPrefix() {
        for wrong in ["Kate", "kat", "kate ", "", "kate2"] {
            XCTAssertThrowsError(try AppControlTasks.requireKnownFocus(wrong, known: ["kate"]), "`\(wrong)`") { error in
                guard case .notFound? = error as? AppControlError else {
                    return XCTFail("`\(wrong)` is `notFound`, not \(error)")
                }
            }
        }
    }

    func testAnAppWithNoKnownFocusRefusesEveryTagRatherThanAnswerEmpty() {
        XCTAssertThrowsError(try AppControlTasks.requireKnownFocus("kate", known: [])) { error in
            guard case .notFound(let detail)? = error as? AppControlError else {
                return XCTFail("with nothing known the answer is still `notFound`, not \(error)")
            }
            XCTAssertTrue(detail.contains("kate"), detail)
        }
    }

    // MARK: - tasks list: window_open

    func testEveryRowSaysWhetherItsTaskHasAWindowOpenFromTheWindowOpenClosure() throws {
        let store = try makeBusyStore()
        let report = AppControlTasks.list(tag: tag, list: store.list(for: tag), all: true,
                                          windowOpen: { $0 == "b1" || $0 == "e1" })
        let byId = indexed(objects(report["tasks"], "tasks"))

        XCTAssertEqual(byId.count, 7)
        for (id, json) in byId {
            XCTAssertEqual(json["window_open"] as? Bool, id == "b1" || id == "e1", "\(id).window_open")
            XCTAssertEqual(Set(json.keys), rowKeys, id)
        }
        assertValidJSON(report, "tasks list with windows open")
    }

    func testTheWindowOpenClosureIsAskedAboutEachTaskByItsId() throws {
        let store = try makeBusyStore()
        var asked: [String] = []
        let list = store.list(for: tag)
        _ = AppControlTasks.list(tag: tag, list: list, all: true, windowOpen: { id in asked.append(id); return false })

        XCTAssertEqual(asked.sorted(), list.allRows.map(\.id).sorted())
    }

    func testTasksListWithoutAWindowOpenClosureSaysNoWindowIsOpenForEveryTask() throws {
        let store = try makeBusyStore()
        let report = AppControlTasks.list(tag: tag, list: store.list(for: tag), all: true)
        let tasks = objects(report["tasks"], "tasks")

        XCTAssertEqual(tasks.count, 7)
        for json in tasks {
            XCTAssertEqual(json["window_open"] as? Bool, false, "\(json["id"] as? String ?? "?")")
        }
    }

    func testARowReportsWindowOpenAsGiven() throws {
        let store = try makeBusyStore()
        let row = try XCTUnwrap(store.list(for: tag).running.first)
        XCTAssertEqual(AppControlTasks.row(row, windowOpen: true)["window_open"] as? Bool, true)
        XCTAssertEqual(AppControlTasks.row(row, windowOpen: false)["window_open"] as? Bool, false)
        XCTAssertEqual(AppControlTasks.row(row)["window_open"] as? Bool, false, "no window unless told")
    }

    // MARK: - tasks output

    private let outputKeys: Set<String> = ["tag", "task_id", "state", "truncated", "total_bytes", "source", "text"]

    private func visible(_ range: Range<Int>) -> String {
        TaskOutputFakeDaemon.visibleText(range)
    }

    /// A model over the rig's daemon, loaded, and released when the test ends.
    private func loadedModel(_ rig: TaskOutputRig, taskId: String = "b1") -> TaskOutputModel {
        let model = rig.makeModel(tag: tag, taskId: taskId)
        model.acquire()
        rig.drainAnswers()
        rig.flushDeliveries()
        addTeardownBlock { model.release() }
        return model
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    func testTasksOutputReportsTheStateTheSizeTheSourceAndTheText() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(10)
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(Set(payload.keys), outputKeys, "exactly these keys: no `refusal` when the text is returned")
        XCTAssertEqual(payload["tag"] as? String, tag)
        XCTAssertEqual(payload["task_id"] as? String, "b1")
        XCTAssertEqual(payload["state"] as? String, "ready")
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        XCTAssertEqual(number(payload["total_bytes"]), 640)
        XCTAssertEqual(payload["source"] as? String, "file")
        XCTAssertEqual(payload["text"] as? String, visible(0..<10))
        assertValidJSON(payload, "tasks output")
    }

    func testTasksOutputNamesTheCliTailAsItsSource() throws {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        rig.daemon.setLines(20)
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["source"] as? String, "cli_tail")
        XCTAssertEqual(payload["state"] as? String, "ready")
    }

    // MARK: Withheld in the real app

    func testWithheldOutputHasNullTextAndARefusalButStillAnswersStateSizeSourceAndTruncation() throws {
        let rig = TaskOutputRig()
        let secret = "SECRET-OUTPUT-MARKER the command printed this\n"
        rig.daemon.setText(secret)
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: false)

        XCTAssertEqual(Set(payload.keys), outputKeys.union(["refusal"]))
        XCTAssertTrue(isNull(payload["text"]), "the text is null, not an empty string")
        let refusal = try XCTUnwrap(payload["refusal"] as? String)
        XCTAssertFalse(refusal.isEmpty, "and the refusal says why")
        XCTAssertEqual(payload["state"] as? String, "ready")
        XCTAssertEqual(number(payload["total_bytes"]), UInt64(secret.utf8.count))
        XCTAssertEqual(payload["source"] as? String, "file")
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        assertValidJSON(payload, "withheld tasks output")

        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET-OUTPUT-MARKER"),
                       "nothing the task printed leaves in a withheld answer")
    }

    func testWithheldOutputStillSaysTruncatedForALongOutput() throws {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        rig.daemon.setLines(625)
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: false)

        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual(number(payload["total_bytes"]), 40_000)
        XCTAssertTrue(isNull(payload["text"]))
    }

    func testAllowedOutputCarriesNoRefusal() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(3)
        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: loadedModel(rig), allowsText: true)
        XCTAssertNil(payload["refusal"])
        XCTAssertFalse(isNull(payload["text"]))
    }

    // MARK: The one-mebibyte cap

    func testTheTextCapKeepsTheEndOfTheOutputAndSetsTruncated() throws {
        let rig = TaskOutputRig()
        let lines = 3 * 1_048_576 / 64      // 3 MiB: the model holds all of it (it is under the 10 MB window)
        rig.daemon.setLines(lines)
        let model = loadedModel(rig)
        XCTAssertFalse(model.truncatedHead, "the model cut nothing: any cut is the cap's")

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, AppControlTasks.outputTextLimit, "at most 1 MiB")
        XCTAssertGreaterThan(text.utf8.count, AppControlTasks.outputTextLimit - 256, "and not much less: it is the end, not a sliver")
        XCTAssertTrue(text.hasSuffix(TaskOutputFakeDaemon.visibleLine(lines - 1)), "the end is kept")
        XCTAssertFalse(text.contains(TaskOutputFakeDaemon.visibleLine(0)), "the start is not")
        XCTAssertTrue(model.text.hasSuffix("\n" + text), "it is one piece of the end of the output, cut at a line start")
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual(number(payload["total_bytes"]), UInt64(3 * 1_048_576), "the total is the output's, not the cap's")
    }

    func testAnOutputExactlyAtTheCapIsReturnedWholeAndNotTruncated() throws {
        let rig = TaskOutputRig()
        let lines = 1_048_576 / 64
        rig.daemon.setLines(lines)
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual((payload["text"] as? String)?.utf8.count, AppControlTasks.outputTextLimit)
        assertSameLargeText(payload["text"] as? String ?? "", model.text, "text at the cap")
        XCTAssertEqual(payload["truncated"] as? Bool, false)
    }

    func testOneLineOverTheCapIsCutAndFlagged() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(1_048_576 / 64 + 1)
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, AppControlTasks.outputTextLimit)
        XCTAssertTrue(text.hasSuffix(TaskOutputFakeDaemon.visibleLine(1_048_576 / 64)))
        XCTAssertEqual(payload["truncated"] as? Bool, true)
    }

    // MARK: Same model, same answer as the viewer

    func testAViewerOverTheSameModelShowsTheTextTheCommandReturns() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(14_400)                      // 900 KB: under the cap, no head to fetch
        let model = rig.makeModel(tag: tag, taskId: "b1")
        let view = TaskOutputView(focusTag: tag, taskId: "b1", model: model, pasteboard: makePasteboard())
        model.acquire()
        rig.drainAnswers()
        rig.flushDeliveries()
        addTeardownBlock { model.release() }

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        assertSameLargeText(payload["text"] as? String ?? "", view.shownText, "the command's text against the viewer's")
        XCTAssertEqual(payload["truncated"] as? Bool, view.noticeText != nil, "the same truncation flag")
        XCTAssertNil(view.noticeText)
        XCTAssertEqual(number(payload["total_bytes"]), model.totalBytes)
        XCTAssertEqual(number(payload["total_bytes"]), 14_400 * 64)
    }

    func testForALongTailOnlyOutputTheCommandAndTheViewerAgreeOnTextTruncationAndSize() throws {
        let rig = TaskOutputRig()
        rig.daemon.source = .cliTail
        rig.daemon.setLines(625)                          // 40 000 bytes, of which the CLI keeps 8 KiB
        let model = rig.makeModel(tag: tag, taskId: "b1")
        let view = TaskOutputView(focusTag: tag, taskId: "b1", model: model, pasteboard: makePasteboard())
        model.acquire()
        rig.drainAnswers()
        rig.flushDeliveries()
        addTeardownBlock { model.release() }

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["text"] as? String, view.shownText)
        XCTAssertNotNil(view.noticeText, "the viewer says the start is cut")
        XCTAssertEqual(view.noticeText, "Showing the last 8 KB of 39 KB")
        XCTAssertEqual(payload["truncated"] as? Bool, true, "and so does the command")
        XCTAssertEqual(number(payload["total_bytes"]), 40_000)
        XCTAssertEqual(payload["source"] as? String, "cli_tail")
    }

    func testForAnOutputPastTheCapTheCommandReturnsTheEndOfWhatTheViewerShows() throws {
        let rig = TaskOutputRig()
        let lines = 3 * 1_048_576 / 64
        rig.daemon.setLines(lines)
        let model = rig.makeModel(tag: tag, taskId: "b1")
        let view = TaskOutputView(focusTag: tag, taskId: "b1", model: model, pasteboard: makePasteboard())
        model.acquire()
        rig.drainAnswers()
        rig.flushDeliveries()
        addTeardownBlock { model.release() }
        assertSameLargeText(view.shownText, model.text, "the viewer shows what the model holds")

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertTrue(view.shownText.hasSuffix(text), "the command's text is the end of the viewer's")
        XCTAssertEqual(payload["truncated"] as? Bool, true, "the cap cut the start of what the viewer shows")
        XCTAssertEqual(number(payload["total_bytes"]), model.totalBytes)
    }

    func testAnOutputTheModelCutIsTruncatedAndKeepsTheModelsTotal() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(12 * 1_048_576 / 64)
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual(number(payload["total_bytes"]), UInt64(12 * 1_048_576))
        XCTAssertEqual(payload["state"] as? String, "ready")
        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertTrue(text.hasSuffix(TaskOutputFakeDaemon.visibleLine(12 * 1_048_576 / 64 - 1)), "it is the end")
    }

    // MARK: Loading, unavailable, error

    func testWhileTheModelIsStillLoadingTheStateIsLoadingAndTheTotalIsNull() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(10)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel(tag: tag, taskId: "b1")
        model.acquire()
        addTeardownBlock { model.release() }

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["state"] as? String, "loading")
        XCTAssertTrue(isNull(payload["total_bytes"]), "an unknown size is null, never zero")
        XCTAssertTrue(isNull(payload["source"]))
        XCTAssertEqual(payload["truncated"] as? Bool, false)
        assertValidJSON(payload, "loading tasks output")

        rig.drainAnswers()
        let ready = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)
        XCTAssertEqual(ready["state"] as? String, "ready")
        XCTAssertEqual(number(ready["total_bytes"]), 640)
    }

    func testWhileTheHeadOfALongOutputIsStillBeingReadTheStateIsStillLoading() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(3 * 1_048_576 / 64)
        rig.daemon.defersAnswers = true
        let model = rig.makeModel(tag: tag, taskId: "b1")
        model.acquire()
        addTeardownBlock { model.release() }
        rig.daemon.answerNext()      // the tail only

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)
        XCTAssertEqual(payload["state"] as? String, "loading", "ask again: the first lines are not in yet")
        XCTAssertTrue(isNull(payload["total_bytes"]))

        rig.drainAnswers()
        let done = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)
        XCTAssertEqual(done["state"] as? String, "ready")
        XCTAssertEqual(number(done["total_bytes"]), UInt64(3 * 1_048_576))
    }

    func testAnOutputThatIsNotThereIsUnavailableWithANullTotalAndNoSource() throws {
        let rig = TaskOutputRig()
        rig.daemon.content = nil
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["state"] as? String, "unavailable")
        XCTAssertTrue(isNull(payload["total_bytes"]))
        XCTAssertTrue(isNull(payload["source"]))
        XCTAssertEqual(payload["text"] as? String, "", "no output is an empty text, not null: the answer is allowed")
        assertValidJSON(payload, "unavailable tasks output")
    }

    func testADaemonErrorIsReportedAsTheErrorState() throws {
        let rig = TaskOutputRig()
        rig.daemon.failure = ("error", "the output file is not readable")
        let model = loadedModel(rig)

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["state"] as? String, "error")
        XCTAssertTrue(isNull(payload["total_bytes"]))
    }

    // MARK: Asking opens nothing

    func testAskingForOutputOpensNoWindow() throws {
        let store = try makeBusyStore()
        let rig = TaskOutputRig()
        rig.daemon.setLines(5)
        let registry = rig.makeRegistry(store: store)
        let suite = "AppControlTasksTests-windows-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let manager = TaskWindowManager(store: store, registry: registry, focusName: { $0 }, source: { _ in nil },
                                        defaults: defaults, pasteboard: makePasteboard(), visibleScreens: { [] },
                                        keyWindow: { nil }, now: { Date(timeIntervalSince1970: 1_760_000_000) })

        let model = registry.model(tag: tag, taskId: "b1")
        model.acquire()
        addTeardownBlock { model.release() }
        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["state"] as? String, "ready", "the task is real and has output")
        XCTAssertEqual(manager.openCount, 0, "reading a task's output does not open its window")
        XCTAssertFalse(manager.isOpen(tag: tag, taskId: "b1"))
    }
}

// MARK: - Review fixes: one huge line, repeat asks

extension AppControlTasksTests {

    func testAnOutputThatIsOneHugeLineIsCutToTheEndOfItNotToAnEmptyText() throws {
        let rig = TaskOutputRig()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        let file = Data((0..<(3 * 1_048_576)).map { alphabet[$0 % 64] })       // 3 MiB, no newline
        rig.daemon.content = file
        let model = loadedModel(rig)
        XCTAssertGreaterThan(model.text.utf8.count, 2 * AppControlTasks.outputTextLimit, "premise: the model holds all of it")
        XCTAssertFalse(model.text.utf8.contains(0x0A), "premise: there is no line to cut at")

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        let text = try XCTUnwrap(payload["text"] as? String)
        XCTAssertFalse(text.isEmpty, "a line with no newline is not cut to nothing")
        XCTAssertLessThanOrEqual(text.utf8.count, AppControlTasks.outputTextLimit)
        XCTAssertGreaterThan(text.utf8.count, AppControlTasks.outputTextLimit - 8, "about 1 MiB of it")
        XCTAssertTrue(text.utf8.elementsEqual(file.suffix(text.utf8.count)), "and it is the end of the output")
        XCTAssertEqual(payload["truncated"] as? Bool, true)
        XCTAssertEqual(number(payload["total_bytes"]), UInt64(3 * 1_048_576))
    }

    func testARepeatAskReportsLoadingUntilTheRefreshLandsAndThenTheNewText() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(10)
        let model = loadedModel(rig)
        model.release()                          // the first ask's hold ran out
        rig.daemon.appendLines(3)                // the file grew in the meantime
        rig.daemon.defersAnswers = true

        model.acquire()                          // the second ask, as the app control server does it
        addTeardownBlock { model.release() }
        let during = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(during["state"] as? String, "loading", "what the model holds may be older than the file: ask again")
        XCTAssertTrue(isNull(during["total_bytes"]), "an unknown size is null, never the old one")
        assertValidJSON(during, "the refreshing answer")

        rig.daemon.answerNext()
        rig.flushDeliveries()
        let after = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(after["state"] as? String, "ready")
        XCTAssertEqual(after["text"] as? String, visible(0..<13), "the lines written since the last ask")
        XCTAssertEqual(number(after["total_bytes"]), 13 * 64)
    }

    func testARefreshTheDaemonNeverAnswersDoesNotLeaveTheOutputLoadingForever() throws {
        let rig = TaskOutputRig()
        rig.daemon.setLines(10)
        let model = loadedModel(rig)
        model.release()
        rig.daemon.appendLines(3)
        rig.daemon.defersAnswers = true

        model.acquire()
        addTeardownBlock { model.release() }
        XCTAssertEqual(AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)["state"] as? String,
                       "loading", "premise: the refresh is out")
        rig.timeouts.fireAll()                   // the daemon never answered

        let payload = AppControlTasks.output(tag: tag, taskId: "b1", model: model, allowsText: true)

        XCTAssertEqual(payload["state"] as? String, "ready", "held text is not turned into a permanent loading")
        XCTAssertEqual(payload["text"] as? String, visible(0..<10))
        XCTAssertEqual(number(payload["total_bytes"]), 640)
    }
}
