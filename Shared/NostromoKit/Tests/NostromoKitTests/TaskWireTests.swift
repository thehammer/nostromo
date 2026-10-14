// NostromoKit — TaskWireTests.swift
//
// Background-activity wire (BA0): the `session_tasks` and `session_task_detail` frames the
// daemon sends. The fixture JSON is the shape the Rust side serialises (`src/ipc/protocol.rs`:
// `TaskMeta`, `ServerMsg::SessionTasks`, `ServerMsg::SessionTaskDetail`): optional fields are
// OMITTED when absent (never null), enums are snake_case strings.
//
// The contract pinned here is version-skew tolerance: a newer daemon may add keys or enum
// values and an older one may omit booleans, and none of that may cost the client the frame.
// The same cases are mirrored against the Mac client's decoder in
// `macOS/NostromoTests/NostromodClientHandshakeTests.swift` (BackgroundTaskWireDecodeTests).

import XCTest
@testable import NostromoKit

final class TaskWireTests: XCTestCase {

    // MARK: - Fixtures

    /// Every `TaskMeta` field present, and every value distinguishable from its default.
    private let fullTask = """
    {"id":"b7k2x9","run_id":"run-0042","task_type":"local_agent","kind":"agent",
     "tool_name":"Agent","description":"Audit the wire types","subagent_type":"general-purpose",
     "workflow_name":"nightly-audit","tool_use_id":"toolu_01ABC","parent_task_id":"a1b2c3",
     "is_backgrounded":true,"housekeeping":true,"status":"stopped","end_reason":"user_stop",
     "started_at_ms":1760000000123,"ended_at_ms":1760000090456,"duration_ms":90333,
     "total_tokens":5000000000,"tool_uses":17,"last_tool_name":"Grep","has_output":true}
    """

    private let minimalTask = """
    {"id":"m1","task_type":"local_bash","kind":"shell","description":"npm run dev",
     "housekeeping":false,"status":"running","has_output":false}
    """

    private func frame(tasks: String, extra: String = "") -> String {
        """
        {"type":"session_tasks","tag":"claudia","daemon_epoch":"epoch-1"\(extra),"tasks":[\(tasks)]}
        """
    }

    private func decode(_ json: String) -> ServerMsg {
        ServerMsg.decode(from: Data(json.utf8))
    }

    private func snapshot(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionTasksWire {
        guard case let .sessionTasks(s) = decode(json) else {
            XCTFail("expected .sessionTasks", file: file, line: line)
            throw XCTSkip("not a session_tasks frame")
        }
        return s
    }

    private func detail(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> SessionTaskDetailWire {
        guard case let .sessionTaskDetail(d) = decode(json) else {
            XCTFail("expected .sessionTaskDetail", file: file, line: line)
            throw XCTSkip("not a session_task_detail frame")
        }
        return d
    }

    private func isUnknownFrame(_ msg: ServerMsg) -> Bool {
        if case .unknown = msg { return true }
        return false
    }

    // MARK: - session_tasks: full frame

    func testFullSessionTasksFrameDecodesEveryField() throws {
        let s = try snapshot(frame(tasks: fullTask, extra: #","session_id":"sess-9","stop_supported":true"#))
        XCTAssertEqual(s.tag, "claudia")
        XCTAssertEqual(s.sessionId, "sess-9")
        XCTAssertEqual(s.daemonEpoch, "epoch-1")
        XCTAssertEqual(s.stopSupported, true)
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }

        XCTAssertEqual(t.id, "b7k2x9")
        XCTAssertEqual(t.runId, "run-0042")
        XCTAssertEqual(t.taskType, "local_agent")
        XCTAssertEqual(t.kind, .agent)
        XCTAssertEqual(t.toolName, "Agent")
        XCTAssertEqual(t.description, "Audit the wire types")
        XCTAssertEqual(t.subagentType, "general-purpose")
        XCTAssertEqual(t.workflowName, "nightly-audit")
        XCTAssertEqual(t.toolUseId, "toolu_01ABC")
        XCTAssertEqual(t.parentTaskId, "a1b2c3")
        XCTAssertEqual(t.isBackgrounded, true)
        XCTAssertTrue(t.housekeeping)
        XCTAssertEqual(t.status, .stopped)
        XCTAssertEqual(t.endReason, .userStop)
        XCTAssertEqual(t.startedAtMs, 1_760_000_000_123 as UInt64)
        XCTAssertEqual(t.endedAtMs, 1_760_000_090_456 as UInt64)
        XCTAssertEqual(t.durationMs, 90_333 as UInt64)
        XCTAssertEqual(t.totalTokens, 5_000_000_000 as UInt64, "token counts exceed 32 bits")
        XCTAssertEqual(t.toolUses, 17 as UInt64)
        XCTAssertEqual(t.lastToolName, "Grep")
        XCTAssertTrue(t.hasOutput)
    }

    func testStopSupportedFalseIsDistinctFromUnknown() throws {
        let s = try snapshot(frame(tasks: minimalTask, extra: #","stop_supported":false"#))
        XCTAssertEqual(s.stopSupported, false)
    }

    func testEveryKnownKindStatusAndEndReasonDecodes() throws {
        let kinds = ["shell", "monitor", "agent", "workflow", "other"]
        let statuses = ["pending", "running", "paused", "completed", "failed", "stopped"]
        let reasons = ["user_stop", "restart", "session_ended", "vanished"]
        var tasks: [String] = []
        for (i, k) in kinds.enumerated() {
            tasks.append(#"{"id":"k\#(i)","task_type":"","kind":"\#(k)","description":"","housekeeping":false,"status":"running","has_output":false}"#)
        }
        for (i, st) in statuses.enumerated() {
            tasks.append(#"{"id":"s\#(i)","task_type":"","kind":"shell","description":"","housekeeping":false,"status":"\#(st)","has_output":false}"#)
        }
        for (i, r) in reasons.enumerated() {
            tasks.append(#"{"id":"r\#(i)","task_type":"","kind":"shell","description":"","housekeeping":false,"status":"stopped","end_reason":"\#(r)","has_output":false}"#)
        }
        let s = try snapshot(frame(tasks: tasks.joined(separator: ",")))
        XCTAssertEqual(s.tasks.count, 15)
        guard s.tasks.count == 15 else { return }
        XCTAssertEqual(s.tasks[0..<5].map(\.kind), [.shell, .monitor, .agent, .workflow, .other])
        XCTAssertEqual(s.tasks[5..<11].map(\.status), [.pending, .running, .paused, .completed, .failed, .stopped])
        XCTAssertEqual(s.tasks[11..<15].map(\.endReason), [.userStop, .restart, .sessionEnded, .vanished])
    }

    // MARK: - session_tasks: minimal frame

    func testMinimalSessionTasksFrameDecodesWithAllOptionalsNil() throws {
        let s = try snapshot(frame(tasks: minimalTask))
        XCTAssertEqual(s.tag, "claudia")
        XCTAssertEqual(s.daemonEpoch, "epoch-1")
        XCTAssertNil(s.sessionId)
        XCTAssertNil(s.stopSupported, "absent means the daemon does not know yet, not false")
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }

        XCTAssertEqual(t.id, "m1")
        XCTAssertEqual(t.taskType, "local_bash")
        XCTAssertEqual(t.kind, .shell)
        XCTAssertEqual(t.description, "npm run dev")
        XCTAssertFalse(t.housekeeping)
        XCTAssertEqual(t.status, .running)
        XCTAssertFalse(t.hasOutput)

        XCTAssertNil(t.runId)
        XCTAssertNil(t.toolName)
        XCTAssertNil(t.subagentType)
        XCTAssertNil(t.workflowName)
        XCTAssertNil(t.toolUseId)
        XCTAssertNil(t.parentTaskId)
        XCTAssertNil(t.isBackgrounded)
        XCTAssertNil(t.endReason)
        XCTAssertNil(t.startedAtMs)
        XCTAssertNil(t.endedAtMs)
        XCTAssertNil(t.durationMs)
        XCTAssertNil(t.totalTokens)
        XCTAssertNil(t.toolUses)
        XCTAssertNil(t.lastToolName)
    }

    func testEmptyTasksArrayDecodesToAnEmptyList() throws {
        let s = try snapshot(frame(tasks: ""))
        XCTAssertEqual(s.tasks, [])
        XCTAssertEqual(s.daemonEpoch, "epoch-1")
    }

    // MARK: - session_tasks: version skew

    func testUnknownKindStatusAndEndReasonDecodeAsUnknownWithoutCostingTheFrame() throws {
        let odd = """
        {"id":"odd","task_type":"remote_thing","kind":"teleporter","description":"from the future",
         "housekeeping":false,"status":"hibernating","end_reason":"cosmic_ray","has_output":false}
        """
        let s = try snapshot(frame(tasks: "\(minimalTask),\(odd),\(fullTask)"))
        XCTAssertEqual(s.tasks.map(\.id), ["m1", "odd", "b7k2x9"], "the neighbours of an unknown-valued task still decode")
        guard s.tasks.count == 3 else { return }
        let t = s.tasks[1]
        XCTAssertEqual(t.kind, .unknown("teleporter"))
        XCTAssertEqual(t.status, .unknown("hibernating"))
        XCTAssertEqual(t.endReason, .unknown("cosmic_ray"))
        XCTAssertEqual(t.description, "from the future", "the rest of the entry is intact")
    }

    func testAnUnknownStatusIsNotTerminalSoTheTaskStaysVisible() {
        XCTAssertFalse(TaskStatusWire.unknown("hibernating").isTerminal)
        XCTAssertFalse(TaskStatusWire.pending.isTerminal)
        XCTAssertFalse(TaskStatusWire.running.isTerminal)
        XCTAssertFalse(TaskStatusWire.paused.isTerminal)
        XCTAssertTrue(TaskStatusWire.completed.isTerminal)
        XCTAssertTrue(TaskStatusWire.failed.isTerminal)
        XCTAssertTrue(TaskStatusWire.stopped.isTerminal)
    }

    func testUnknownFieldsAtFrameAndTaskLevelAreIgnored() throws {
        let task = """
        {"id":"x1","task_type":"local_bash","kind":"shell","description":"d","housekeeping":false,
         "status":"running","has_output":true,"brand_new_field":{"nested":[1,2,3]},"another":"v"}
        """
        let json = """
        {"type":"session_tasks","tag":"claudia","daemon_epoch":"e","future_top_level":42,
         "tasks":[\(task)],"also_new":["a"]}
        """
        let s = try snapshot(json)
        XCTAssertEqual(s.tasks.map(\.id), ["x1"])
        XCTAssertEqual(s.tasks.first?.hasOutput, true)
        XCTAssertEqual(s.daemonEpoch, "e")
    }

    func testAMalformedTaskEntryIsDroppedAndTheOthersStillDecode() throws {
        let noId = #"{"task_type":"local_bash","kind":"shell","description":"no id","housekeeping":false,"status":"running","has_output":false}"#
        let wrongType = #"{"id":123,"task_type":"local_bash","kind":"shell","description":"id is a number","housekeeping":false,"status":"running","has_output":false}"#
        let tasks = [minimalTask, noId, #""just a string""#, "42", "null", wrongType, "[]", fullTask]
        let s = try snapshot(frame(tasks: tasks.joined(separator: ",")))
        XCTAssertEqual(s.tasks.map(\.id), ["m1", "b7k2x9"], "only the well-formed entries survive, in order")
    }

    func testAFrameWhoseEveryTaskIsMalformedDecodesToAnEmptyList() throws {
        let s = try snapshot(frame(tasks: #"{"description":"no id"},7"#))
        XCTAssertEqual(s.tasks, [])
    }

    func testHousekeepingAndHasOutputDefaultToFalseWhenAbsent() throws {
        let task = #"{"id":"d1","task_type":"local_bash","kind":"shell","description":"d","status":"running"}"#
        let s = try snapshot(frame(tasks: task))
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }
        XCTAssertFalse(t.housekeeping)
        XCTAssertFalse(t.hasOutput)
    }

    func testWireKeysAreSnakeCaseAndCamelCaseKeysDoNotPopulateFields() throws {
        let task = """
        {"id":"c1","taskType":"local_agent","task_type":"local_bash","kind":"shell","description":"d",
         "status":"stopped","housekeeping":false,
         "hasOutput":true,"isBackgrounded":true,"endReason":"restart","startedAtMs":1,"endedAtMs":2,
         "durationMs":3,"totalTokens":4,"toolUses":5,"lastToolName":"Edit","toolName":"Bash",
         "runId":"r","subagentType":"s","workflowName":"w","toolUseId":"u","parentTaskId":"p"}
        """
        let json = """
        {"type":"session_tasks","tag":"claudia","daemonEpoch":"camel","sessionId":"camel",
         "stopSupported":true,"tasks":[\(task)]}
        """
        let s = try snapshot(json)
        XCTAssertNil(s.sessionId)
        XCTAssertNil(s.stopSupported)
        XCTAssertNotEqual(s.daemonEpoch, "camel")
        XCTAssertEqual(s.tasks.count, 1)
        guard let t = s.tasks.first else { return }
        XCTAssertEqual(t.taskType, "local_bash", "the snake_case key wins; the camelCase one is ignored")
        XCTAssertFalse(t.hasOutput)
        XCTAssertNil(t.isBackgrounded)
        XCTAssertNil(t.endReason)
        XCTAssertNil(t.startedAtMs)
        XCTAssertNil(t.endedAtMs)
        XCTAssertNil(t.durationMs)
        XCTAssertNil(t.totalTokens)
        XCTAssertNil(t.toolUses)
        XCTAssertNil(t.lastToolName)
        XCTAssertNil(t.toolName)
        XCTAssertNil(t.runId)
        XCTAssertNil(t.subagentType)
        XCTAssertNil(t.workflowName)
        XCTAssertNil(t.toolUseId)
        XCTAssertNil(t.parentTaskId)
    }

    // MARK: - session_task_detail

    func testTaskDetailWithAllFourTextFieldsDecodes() throws {
        let d = try detail("""
        {"type":"session_task_detail","tag":"claudia","task_id":"b7k2x9",
         "preview":"Compiling NostromoKit...","progress_summary":"Reading the wire types",
         "completion_summary":"Found two gaps","prompt":"Audit the wire types"}
        """)
        XCTAssertEqual(d.tag, "claudia")
        XCTAssertEqual(d.taskId, "b7k2x9")
        XCTAssertEqual(d.preview, "Compiling NostromoKit...")
        XCTAssertEqual(d.progressSummary, "Reading the wire types")
        XCTAssertEqual(d.completionSummary, "Found two gaps")
        XCTAssertEqual(d.prompt, "Audit the wire types")
    }

    func testTaskDetailWithOnlyAPreviewDecodes() throws {
        let d = try detail(#"{"type":"session_task_detail","tag":"claudia","task_id":"m1","preview":"listening on :3000"}"#)
        XCTAssertEqual(d.taskId, "m1")
        XCTAssertEqual(d.preview, "listening on :3000")
        XCTAssertNil(d.progressSummary)
        XCTAssertNil(d.completionSummary)
        XCTAssertNil(d.prompt)
    }

    func testTaskDetailWithNoTextFieldsDecodes() throws {
        let d = try detail(#"{"type":"session_task_detail","tag":"claudia","task_id":"m1"}"#)
        XCTAssertEqual(d.tag, "claudia")
        XCTAssertEqual(d.taskId, "m1")
        XCTAssertNil(d.preview)
        XCTAssertNil(d.progressSummary)
        XCTAssertNil(d.completionSummary)
        XCTAssertNil(d.prompt)
    }

    func testTaskDetailIgnoresUnknownKeys() throws {
        let d = try detail(#"{"type":"session_task_detail","tag":"t","task_id":"m1","prompt":"p","new_thing":{"a":1},"tokens":9}"#)
        XCTAssertEqual(d.taskId, "m1")
        XCTAssertEqual(d.prompt, "p")
    }

    func testTaskDetailWithCamelCaseKeysDoesNotPopulateFields() throws {
        let json = #"{"type":"session_task_detail","tag":"t","task_id":"m1","progressSummary":"x","completionSummary":"y"}"#
        let d = try detail(json)
        XCTAssertNil(d.progressSummary)
        XCTAssertNil(d.completionSummary)
    }

    func testTaskDetailWithoutASnakeCaseTaskIdIsNotUsable() {
        XCTAssertTrue(isUnknownFrame(decode(#"{"type":"session_task_detail","tag":"t","taskId":"m1","preview":"p"}"#)),
                      "a detail frame that names no task (camelCase `taskId` is not the wire key) cannot be attributed")
    }

    // MARK: - Neighbouring frame types

    func testAnUnknownFrameTypeStillYieldsUnknown() {
        XCTAssertTrue(isUnknownFrame(decode(#"{"type":"session_tasks_v2","tag":"t","daemon_epoch":"e","tasks":[]}"#)))
        XCTAssertTrue(isUnknownFrame(decode(#"{"type":"session_task_telepathy","tag":"t"}"#)))
    }

    func testTaskFramesDoNotDisturbDecodingOfOtherFrames() {
        guard case let .welcome(version, pid) = decode(#"{"type":"welcome","protocol_version":3,"daemon_pid":77}"#) else {
            return XCTFail("expected .welcome")
        }
        XCTAssertEqual(version, 3)
        XCTAssertEqual(pid, 77)
    }
}
