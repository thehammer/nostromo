// NostromoKit — TaskWire.swift
//
// Background-task frames (`session_tasks`, `session_task_detail`, and the two
// answers `session_task_stop_result` / `session_task_output_result`): what a
// session's Claude Code CLI is running in the background. Mirrors the Rust
// types in `src/ipc/protocol.rs` ("background tasks").
//
// Every decoder here is lenient on purpose: a newer daemon may add keys or enum
// values. Unknown keys are ignored, unknown enum strings decode to an
// `.unknown(String)` case (never a throw), and every field that can be absent
// is optional. A malformed entry in `tasks` is dropped rather than failing the
// frame.
//
// `TaskMetaWire` is metadata only. Free text derived from a task's output or
// from the conversation (preview line, summaries, prompt) arrives in
// `session_task_detail`, which the daemon never sends to a network peer. The
// two answers are local only too: one carries output, the other replies to a
// verb a network peer can never send.

import Foundation

// MARK: - Enums

/// What a task is, as the daemon resolved it (`TaskKind`).
public enum TaskKindWire: Equatable {
    case shell
    case monitor
    case agent
    case workflow
    case other
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "shell": self = .shell
        case "monitor": self = .monitor
        case "agent": self = .agent
        case "workflow": self = .workflow
        case "other": self = .other
        default: self = .unknown(raw)
        }
    }
}

/// A task's state (`TaskStatus`).
public enum TaskStatusWire: Equatable {
    case pending
    case running
    case paused
    case completed
    case failed
    case stopped
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "pending": self = .pending
        case "running": self = .running
        case "paused": self = .paused
        case "completed": self = .completed
        case "failed": self = .failed
        case "stopped": self = .stopped
        default: self = .unknown(raw)
        }
    }

    /// Still able to change state. An unknown status counts as not terminal:
    /// a task the client cannot classify is shown, not hidden.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .stopped: return true
        case .pending, .running, .paused, .unknown: return false
        }
    }
}

/// Why a task ended `stopped` when the CLI did not say (`TaskEndReason`).
public enum TaskEndReasonWire: Equatable {
    case userStop
    case restart
    case sessionEnded
    case vanished
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "user_stop": self = .userStop
        case "restart": self = .restart
        case "session_ended": self = .sessionEnded
        case "vanished": self = .vanished
        default: self = .unknown(raw)
        }
    }
}

/// How a stop request ended (`TaskStopOutcome`).
public enum TaskStopOutcomeWire: Equatable {
    /// The CLI took the stop. The task's status changes when the CLI reports it ended.
    case accepted
    case refused
    case timeout
    /// The CLI predates stopping tasks.
    case unsupported
    /// The task is unknown or already ended.
    case notRunning
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "accepted": self = .accepted
        case "refused": self = .refused
        case "timeout": self = .timeout
        case "unsupported": self = .unsupported
        case "not_running": self = .notRunning
        default: self = .unknown(raw)
        }
    }
}

/// How an output read ended (`TaskOutputOutcome`).
public enum TaskOutputOutcomeWire: Equatable {
    case ok
    case unavailable
    case refused
    case error
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "ok": self = .ok
        case "unavailable": self = .unavailable
        case "refused": self = .refused
        case "error": self = .error
        default: self = .unknown(raw)
        }
    }
}

/// Where an output read's text came from (`TaskOutputSource`).
public enum TaskOutputSourceWire: Equatable {
    /// The task's output file: ranged, up to the whole output.
    case file
    /// The CLI's own tail: at most the last 8 KiB.
    case cliTail
    case unknown(String)

    public init(wire raw: String) {
        switch raw {
        case "file": self = .file
        case "cli_tail": self = .cliTail
        default: self = .unknown(raw)
        }
    }
}

extension TaskStopOutcomeWire: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(wire: raw)
    }
}

extension TaskOutputOutcomeWire: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(wire: raw)
    }
}

extension TaskOutputSourceWire: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(wire: raw)
    }
}

extension TaskKindWire: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(wire: raw)
    }
}

extension TaskStatusWire: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(wire: raw)
    }
}

extension TaskEndReasonWire: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self.init(wire: raw)
    }
}

// MARK: - TaskMeta

/// Metadata of one background task (`TaskMeta`).
public struct TaskMetaWire: Decodable, Equatable {
    public let id: String
    public let runId: String?
    /// The CLI's raw `task_type` (`local_bash`, `local_agent`, …); `""` if none.
    public let taskType: String
    public let kind: TaskKindWire
    public let toolName: String?
    public let description: String
    public let subagentType: String?
    public let workflowName: String?
    public let toolUseId: String?
    public let parentTaskId: String?
    public let isBackgrounded: Bool?
    /// Not activity: an ambient watcher or a `skip_transcript` task.
    public let housekeeping: Bool
    public let status: TaskStatusWire
    public let endReason: TaskEndReasonWire?
    public let startedAtMs: UInt64?
    public let endedAtMs: UInt64?
    public let durationMs: UInt64?
    public let totalTokens: UInt64?
    public let toolUses: UInt64?
    public let lastToolName: String?
    /// The daemon can show this task's output (shell and monitor tasks).
    public let hasOutput: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, description, housekeeping, status
        case runId = "run_id"
        case taskType = "task_type"
        case toolName = "tool_name"
        case subagentType = "subagent_type"
        case workflowName = "workflow_name"
        case toolUseId = "tool_use_id"
        case parentTaskId = "parent_task_id"
        case isBackgrounded = "is_backgrounded"
        case endReason = "end_reason"
        case startedAtMs = "started_at_ms"
        case endedAtMs = "ended_at_ms"
        case durationMs = "duration_ms"
        case totalTokens = "total_tokens"
        case toolUses = "tool_uses"
        case lastToolName = "last_tool_name"
        case hasOutput = "has_output"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        runId = try c.decodeIfPresent(String.self, forKey: .runId)
        taskType = try c.decodeIfPresent(String.self, forKey: .taskType) ?? ""
        kind = try c.decodeIfPresent(TaskKindWire.self, forKey: .kind) ?? .other
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        subagentType = try c.decodeIfPresent(String.self, forKey: .subagentType)
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName)
        toolUseId = try c.decodeIfPresent(String.self, forKey: .toolUseId)
        parentTaskId = try c.decodeIfPresent(String.self, forKey: .parentTaskId)
        isBackgrounded = try c.decodeIfPresent(Bool.self, forKey: .isBackgrounded)
        housekeeping = try c.decodeIfPresent(Bool.self, forKey: .housekeeping) ?? false
        status = try c.decodeIfPresent(TaskStatusWire.self, forKey: .status) ?? .unknown("")
        endReason = try c.decodeIfPresent(TaskEndReasonWire.self, forKey: .endReason)
        startedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .startedAtMs)
        endedAtMs = try c.decodeIfPresent(UInt64.self, forKey: .endedAtMs)
        durationMs = try c.decodeIfPresent(UInt64.self, forKey: .durationMs)
        totalTokens = try c.decodeIfPresent(UInt64.self, forKey: .totalTokens)
        toolUses = try c.decodeIfPresent(UInt64.self, forKey: .toolUses)
        lastToolName = try c.decodeIfPresent(String.self, forKey: .lastToolName)
        hasOutput = try c.decodeIfPresent(Bool.self, forKey: .hasOutput) ?? false
    }
}

// MARK: - Frames

/// `session_tasks`: every background task of a session, retained ended ones
/// included. A full snapshot: it replaces the previous one.
public struct SessionTasksWire: Decodable, Equatable {
    public let tag: String
    /// The Claude session id the tasks belong to.
    public let sessionId: String?
    /// Random id of the daemon process that sent this.
    public let daemonEpoch: String
    /// `nil` until the daemon knows whether the CLI can stop a task.
    public let stopSupported: Bool?
    public let tasks: [TaskMetaWire]

    enum CodingKeys: String, CodingKey {
        case tag, tasks
        case sessionId = "session_id"
        case daemonEpoch = "daemon_epoch"
        case stopSupported = "stop_supported"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        daemonEpoch = try c.decodeIfPresent(String.self, forKey: .daemonEpoch) ?? ""
        stopSupported = try c.decodeIfPresent(Bool.self, forKey: .stopSupported)
        // A malformed entry is dropped, not fatal.
        let lossy = try c.decodeIfPresent([LossyTask].self, forKey: .tasks) ?? []
        tasks = lossy.compactMap(\.value)
    }

    /// Decodes to `nil` instead of throwing.
    private struct LossyTask: Decodable {
        let value: TaskMetaWire?
        init(from decoder: Decoder) throws {
            value = try? TaskMetaWire(from: decoder)
        }
    }
}

/// `session_task_detail`: the text derived from one task's output or from the
/// conversation. Sent to local clients only; any field may be absent.
public struct SessionTaskDetailWire: Decodable, Equatable {
    public let tag: String
    public let taskId: String
    /// The task's last output line.
    public let preview: String?
    /// An agent's model-written status line.
    public let progressSummary: String?
    public let completionSummary: String?
    /// The prompt an agent task was given.
    public let prompt: String?

    enum CodingKeys: String, CodingKey {
        case tag, preview, prompt
        case taskId = "task_id"
        case progressSummary = "progress_summary"
        case completionSummary = "completion_summary"
    }
}

/// `session_task_stop_result`: the answer to a `session_task_stop` of this
/// connection. Local clients only.
public struct SessionTaskStopResultWire: Decodable, Equatable {
    public let requestId: String
    public let tag: String
    public let taskId: String
    public let outcome: TaskStopOutcomeWire
    /// The CLI's reason, or why nothing was sent.
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case tag, outcome, message
        case requestId = "request_id"
        case taskId = "task_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        tag = try c.decode(String.self, forKey: .tag)
        taskId = try c.decode(String.self, forKey: .taskId)
        outcome = try c.decode(TaskStopOutcomeWire.self, forKey: .outcome)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}

/// `session_task_output_result`: the answer to a `session_task_output` of this
/// connection. `text` is sanitised output for the raw byte range
/// `[startOffset, endOffset)` of an output of `totalBytes`. Local clients only.
public struct SessionTaskOutputResultWire: Decodable, Equatable {
    public let requestId: String
    public let tag: String
    public let taskId: String
    public let outcome: TaskOutputOutcomeWire
    public let text: String
    public let startOffset: UInt64
    public let endOffset: UInt64
    public let totalBytes: UInt64
    public let source: TaskOutputSourceWire?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case tag, outcome, text, source, message
        case requestId = "request_id"
        case taskId = "task_id"
        case startOffset = "start_offset"
        case endOffset = "end_offset"
        case totalBytes = "total_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        tag = try c.decode(String.self, forKey: .tag)
        taskId = try c.decode(String.self, forKey: .taskId)
        outcome = try c.decode(TaskOutputOutcomeWire.self, forKey: .outcome)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        startOffset = try c.decodeIfPresent(UInt64.self, forKey: .startOffset) ?? 0
        endOffset = try c.decodeIfPresent(UInt64.self, forKey: .endOffset) ?? 0
        totalBytes = try c.decodeIfPresent(UInt64.self, forKey: .totalBytes) ?? 0
        source = try c.decodeIfPresent(TaskOutputSourceWire.self, forKey: .source)
        message = try c.decodeIfPresent(String.self, forKey: .message)
    }
}
