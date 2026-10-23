// NostromoKit — ApprovalWire.swift
//
// The permission-approval frames (AP0b): what the daemon sends about a request
// it is holding for a human, and what the Mac app answers. Mirrors the Rust
// types in `src/approvals/wire.rs` and the `Approval*` variants of `ServerMsg` /
// `ClientMsg` in `src/ipc/protocol.rs`. Pure value types, no UI.
//
// Every enum here falls back to a catch-all case for a value this build does not
// know (a later slice adds options, line kinds and refusal codes), so a newer
// daemon never makes a frame undecodable. Nothing here ever re-encodes an
// inbound frame: the daemon keeps the real tool input, and an answer names only
// the request id.
//
// Nothing in the app shows any of this yet (AP2a). The Mac still subscribes with
// `renders_approvals: false`, so the daemon holds nothing for it.

import Foundation

// MARK: - Generic JSON (the tool input, exactly as the CLI sent it)

public indirect enum ApprovalJSON: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ApprovalJSON])
    case object([String: ApprovalJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([ApprovalJSON].self) { self = .array(v); return }
        self = .object(try c.decode([String: ApprovalJSON].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Enums (each with a catch-all)

/// What kind of tool the request is for (`tool_kind`).
public enum ApprovalToolKind: String, Codable, Equatable {
    case bash, edit, write, notebookEdit = "notebook_edit", mcp, other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalToolKind(rawValue: raw) ?? .other
    }
}

/// What the card offers (`options`).
public enum ApprovalOption: String, Codable, Equatable {
    case allowOnce = "allow_once"
    case deny
    case denyAndStop = "deny_and_stop"
    case denyWithNote = "deny_with_note"
    /// Listed only on an `AskUserQuestion` request the daemon can take answers for.
    case answerQuestions = "answer_questions"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalOption(rawValue: raw) ?? .unknown
    }
}

/// Why Claude Code asked (`reason.kind`).
public enum ApprovalReasonKind: String, Codable, Equatable {
    case askRule = "ask_rule"
    case safetyCheck = "safety_check"
    case settingsWrite = "settings_write"
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalReasonKind(rawValue: raw) ?? .other
    }
}

/// The kind of a display line.
public enum ApprovalLineKind: String, Codable, Equatable {
    case command
    case heredocBody = "heredoc_body"
    case heredocEnd = "heredoc_end"
    case fileHeader = "file_header"
    case diffAdd = "diff_add"
    case diffDel = "diff_del"
    case diffCtx = "diff_ctx"
    case json
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalLineKind(rawValue: raw) ?? .unknown
    }
}

/// The kind of a run of text inside a display line.
public enum ApprovalSegmentKind: String, Codable, Equatable {
    case plain, separator, invisible
    case nonAscii = "non_ascii"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalSegmentKind(rawValue: raw) ?? .unknown
    }
}

/// Why an `approval_answer` was not applied (`approval_answer_refused.code`).
public enum ApprovalAnswerRefusalCode: String, Codable, Equatable {
    case requiresSecureConnection = "requires_secure_connection"
    case notOperatorApp = "not_operator_app"
    case alreadyResolved = "already_resolved"
    case unknownRequest = "unknown_request"
    /// An `answer_questions` decision that does not fit the request's questions.
    case invalidAnswer = "invalid_answer"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalAnswerRefusalCode(rawValue: raw) ?? .unknown
    }
}

/// What the human decided (`approval_answer.decision.kind`).
public enum ApprovalDecisionKind: String, Codable, Equatable {
    case allowOnce = "allow_once"
    case deny
    case denyAndStop = "deny_and_stop"
    case answerQuestions = "answer_questions"
}

/// How a refused input reached a control (`approval_refusal_report.channel`).
public enum ApprovalRefusalChannel: String, Codable, Equatable {
    case appControl = "app_control"
    case accessibility
    case unknown
}

// MARK: - The request and its display

public struct ApprovalSegment: Codable, Equatable {
    public let text: String
    public let kind: ApprovalSegmentKind
    /// The code point of an `invisible` or `non_ascii` segment.
    public let cp: UInt32?
}

public struct ApprovalDisplayLine: Codable, Equatable {
    public let number: Int
    public let kind: ApprovalLineKind
    /// Continues the previous line after a separator cut (no `\n` between them).
    public let cont: Bool
    public let segments: [ApprovalSegment]

    enum CodingKeys: String, CodingKey { case number, kind, cont, segments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        kind = try c.decode(ApprovalLineKind.self, forKey: .kind)
        cont = try c.decodeIfPresent(Bool.self, forKey: .cont) ?? false
        segments = try c.decode([ApprovalSegment].self, forKey: .segments)
    }
}

/// The exact-text breakdown of a request (design contract §4.3).
public struct ApprovalDisplay: Codable, Equatable {
    public let lines: [ApprovalDisplayLine]
    public let commandCount: Int?
    public let invisibleCount: Int
    public let nonAsciiCount: Int
    public let unparsed: Bool

    enum CodingKeys: String, CodingKey {
        case lines
        case commandCount = "command_count"
        case invisibleCount = "invisible_count"
        case nonAsciiCount = "non_ascii_count"
        case unparsed
    }
}

public struct ApprovalSubagent: Codable, Equatable {
    public let agentId: String
    public let agentType: String?

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentType = "agent_type"
    }
}

public struct ApprovalAgent: Codable, Equatable {
    public let name: String
    public let subagent: ApprovalSubagent?
}

public struct ApprovalMcpTool: Codable, Equatable {
    public let server: String
    public let tool: String
}

/// The ask rule behind a request, and who found it.
public struct ApprovalFoundRule: Codable, Equatable {
    public let rule: String
    public let sourcePath: String
    /// `"nostromo"` when the daemon matched it against the settings files, `"cli"` when the CLI named it.
    public let foundBy: String

    enum CodingKeys: String, CodingKey {
        case rule
        case sourcePath = "source_path"
        case foundBy = "found_by"
    }
}

public struct ApprovalReason: Codable, Equatable {
    public let kind: ApprovalReasonKind
    public let text: String
    public let rule: ApprovalFoundRule?
}

public struct ApprovalFlags: Codable, Equatable {
    public let defaultToNo: Bool
    public let suppressAlwaysAllowRule: Bool
    public let requiresUserInteraction: Bool
    public let classifierApprovable: Bool

    enum CodingKeys: String, CodingKey {
        case defaultToNo = "default_to_no"
        case suppressAlwaysAllowRule = "suppress_always_allow_rule"
        case requiresUserInteraction = "requires_user_interaction"
        case classifierApprovable = "classifier_approvable"
    }
}

/// A permission request the daemon is holding for a human.
public struct ApprovalRequestWire: Codable, Equatable, Identifiable {
    public var id: String { requestId }

    /// A Nostromo UUID, never the CLI's own request id.
    public let requestId: String
    /// The focus the request belongs to.
    public let tag: String
    public let toolUseId: String
    public let agent: ApprovalAgent
    public let toolName: String
    public let displayName: String
    public let toolKind: ApprovalToolKind
    public let mcp: ApprovalMcpTool?
    /// The tool input exactly as the CLI sent it.
    public let input: ApprovalJSON
    public let display: ApprovalDisplay
    public let cwd: String?
    public let reason: ApprovalReason
    public let flags: ApprovalFlags
    /// The agent's own description of the call: a claim, not a fact.
    public let description: String?
    public let options: [ApprovalOption]
    /// Session-rule candidates (a later slice; empty until then).
    public let sessionRuleCandidates: [ApprovalJSON]
    public let createdAtMs: UInt64
    public let deadlineAtMs: UInt64

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case tag
        case toolUseId = "tool_use_id"
        case agent
        case toolName = "tool_name"
        case displayName = "display_name"
        case toolKind = "tool_kind"
        case mcp, input, display, cwd, reason, flags, description, options
        case sessionRuleCandidates = "session_rule_candidates"
        case createdAtMs = "created_at_ms"
        case deadlineAtMs = "deadline_at_ms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        tag = try c.decode(String.self, forKey: .tag)
        toolUseId = try c.decode(String.self, forKey: .toolUseId)
        agent = try c.decode(ApprovalAgent.self, forKey: .agent)
        toolName = try c.decode(String.self, forKey: .toolName)
        displayName = try c.decode(String.self, forKey: .displayName)
        toolKind = try c.decode(ApprovalToolKind.self, forKey: .toolKind)
        mcp = try c.decodeIfPresent(ApprovalMcpTool.self, forKey: .mcp)
        input = try c.decode(ApprovalJSON.self, forKey: .input)
        display = try c.decode(ApprovalDisplay.self, forKey: .display)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        reason = try c.decode(ApprovalReason.self, forKey: .reason)
        flags = try c.decode(ApprovalFlags.self, forKey: .flags)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        options = try c.decode([ApprovalOption].self, forKey: .options)
        sessionRuleCandidates = try c.decodeIfPresent([ApprovalJSON].self, forKey: .sessionRuleCandidates) ?? []
        createdAtMs = try c.decode(UInt64.self, forKey: .createdAtMs)
        deadlineAtMs = try c.decode(UInt64.self, forKey: .deadlineAtMs)
    }
}

// MARK: - Inbound frames (`ServerMsg`)

/// `approval_request`: a request is being held for a human.
public struct ApprovalRequestFrame: Decodable, Equatable {
    public let tag: String
    public let request: ApprovalRequestWire
}

/// `approvals_snapshot`: every request still held (sent once on subscribe).
public struct ApprovalsSnapshotFrame: Decodable, Equatable {
    public let requests: [ApprovalRequestWire]
}

/// `approval_resolved`: a held request ended. `outcome` is the audit log's name for
/// it (`allowed_once`, `denied`, `denied_and_stopped`, `timed_out`, `no_app`, `cancelled`, …).
public struct ApprovalResolvedFrame: Decodable, Equatable {
    public let tag: String
    public let requestId: String
    public let outcome: String
    public let byWindow: String?
    public let atMs: UInt64

    enum CodingKeys: String, CodingKey {
        case tag
        case requestId = "request_id"
        case outcome
        case byWindow = "by_window"
        case atMs = "at_ms"
    }
}

/// `approval_pending`: how many requests a focus has held. The count only.
public struct ApprovalPendingFrame: Decodable, Equatable {
    public let tag: String
    public let count: Int
}

/// `approval_guard_blocked`: the production-shell guard blocked a call. `summary`
/// is the tool name and the first command word only.
public struct ApprovalGuardBlockedFrame: Decodable, Equatable {
    public let tag: String
    public let toolUseId: String
    public let entryId: String
    public let atMs: UInt64
    public let summary: String

    enum CodingKeys: String, CodingKey {
        case tag
        case toolUseId = "tool_use_id"
        case entryId = "entry_id"
        case atMs = "at_ms"
        case summary
    }
}

/// `approval_answer_refused`: an `approval_answer` was not applied.
public struct ApprovalAnswerRefusedFrame: Decodable, Equatable {
    public let requestId: String
    public let code: ApprovalAnswerRefusalCode
    /// For `already_resolved`: how the request ended.
    public let outcome: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case code, outcome
    }
}

// MARK: - Outbound frames (`ClientMsg`)

/// The human's answer to one question of an `AskUserQuestion` request: the option
/// labels chosen, and the free-text ("Other") answer if that was chosen.
public struct ApprovalQuestionAnswer: Encodable, Equatable {
    public let question: String
    public let selected: [String]
    public let other: String?

    public init(question: String, selected: [String], other: String? = nil) {
        self.question = question
        self.selected = selected
        self.other = other
    }

    enum CodingKeys: String, CodingKey { case question, selected, other }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(question, forKey: .question)
        try c.encode(selected, forKey: .selected)
        try c.encodeIfPresent(other, forKey: .other)
    }
}

/// What the human decided, a note the agent will read (a denial), and the answers
/// (`answer_questions`).
public struct ApprovalDecisionWire: Encodable, Equatable {
    public let kind: ApprovalDecisionKind
    public let note: String?
    public let answers: [ApprovalQuestionAnswer]?

    public init(kind: ApprovalDecisionKind, note: String? = nil, answers: [ApprovalQuestionAnswer]? = nil) {
        self.kind = kind
        self.note = note
        self.answers = answers
    }

    enum CodingKeys: String, CodingKey { case kind, note, answers }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(answers, forKey: .answers)
    }
}

/// `approval_answer`: the human's answer to a held request. `operatorNonce` echoes
/// the nonce this connection's `welcome` carried (the daemon refuses an answer
/// without it).
public struct ClientApprovalAnswer: Encodable, Equatable {
    let type_ = "approval_answer"
    public let requestId: String
    public let decision: ApprovalDecisionWire
    public let windowId: String
    public let operatorNonce: String?

    public init(requestId: String, decision: ApprovalDecisionWire, windowId: String, operatorNonce: String?) {
        self.requestId = requestId
        self.decision = decision
        self.windowId = windowId
        self.operatorNonce = operatorNonce
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case requestId = "request_id"
        case decision
        case windowId = "window_id"
        case operatorNonce = "operator_nonce"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(decision, forKey: .decision)
        try c.encode(windowId, forKey: .windowId)
        try c.encodeIfPresent(operatorNonce, forKey: .operatorNonce)
    }
}

/// `approval_refusal_report`: the app refused an input that was not a human's (a
/// synthetic click or key aimed at an Allow control) and tells the daemon, which logs it.
public struct ClientApprovalRefusalReport: Encodable, Equatable {
    let type_ = "approval_refusal_report"
    public let requestId: String?
    public let control: String
    public let channel: ApprovalRefusalChannel

    public init(requestId: String?, control: String, channel: ApprovalRefusalChannel) {
        self.requestId = requestId
        self.control = control
        self.channel = channel
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case requestId = "request_id"
        case control, channel
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encodeIfPresent(requestId, forKey: .requestId)
        try c.encode(control, forKey: .control)
        try c.encode(channel, forKey: .channel)
    }
}
