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
    /// Listed only on a request the daemon derived session-rule candidates for.
    case allowSession = "allow_session"
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
    /// An `allow_session` decision that names no candidate of the request, or other text.
    case invalidRule = "invalid_rule"
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
    /// Allow this call and create the session rule the decision's `candidate_id` names.
    case allowSession = "allow_session"
}

/// What a session rule covers (`kind`).
public enum ApprovalSessionRuleKind: String, Codable, Equatable {
    case exact
    case pathPrefix = "path_prefix"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalSessionRuleKind(rawValue: raw) ?? .unknown
    }
}

/// A rule the human may choose "for this session" on one held request. The daemon derives
/// it; the app only shows it and echoes `id` and `ruleText` back.
public struct ApprovalSessionRuleCandidate: Codable, Equatable {
    public let id: String
    /// The rule exactly as the card shows it: `Bash(rm -rf ~/Library/Caches/:*)`.
    public let ruleText: String
    public let summary: String
    public let kind: ApprovalSessionRuleKind
    /// The user's own ask rule this overrides, for an ask-rule request.
    public let overrides: String?

    public init(id: String, ruleText: String, summary: String, kind: ApprovalSessionRuleKind, overrides: String? = nil) {
        self.id = id
        self.ruleText = ruleText
        self.summary = summary
        self.kind = kind
        self.overrides = overrides
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ruleText = "rule_text"
        case summary, kind, overrides
    }
}

/// One active session rule (`approval_session_rules.rules[]`).
public struct ApprovalSessionRule: Decodable, Equatable, Identifiable {
    public let id: String
    public let ruleText: String
    public let summary: String
    public let kind: ApprovalSessionRuleKind
    public let createdAtMs: UInt64
    public let uses: UInt64
    /// The sub-agent the rule is bound to, if any.
    public let agentId: String?

    public init(id: String, ruleText: String, summary: String, kind: ApprovalSessionRuleKind,
                createdAtMs: UInt64, uses: UInt64, agentId: String? = nil) {
        self.id = id
        self.ruleText = ruleText
        self.summary = summary
        self.kind = kind
        self.createdAtMs = createdAtMs
        self.uses = uses
        self.agentId = agentId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case ruleText = "rule_text"
        case summary, kind
        case createdAtMs = "created_at_ms"
        case uses
        case agentId = "agent_id"
    }
}

/// An array whose entries that do not decode are dropped, never guessed.
struct ApprovalLossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) { out.append(e) } else { _ = try? c.decode(Skip.self) }
        }
        elements = out
    }
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
    /// The rules the human may choose "for this session". An entry that does not decode is dropped.
    public let sessionRuleCandidates: [ApprovalSessionRuleCandidate]
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
        sessionRuleCandidates = try c.decodeIfPresent(ApprovalLossyArray<ApprovalSessionRuleCandidate>.self,
                                                      forKey: .sessionRuleCandidates)?.elements ?? []
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
    /// The CLI's tool-use id: lets the row of a call that was never shown (`allowed_by_session_rule`) be marked.
    public let toolUseId: String?

    enum CodingKeys: String, CodingKey {
        case tag
        case requestId = "request_id"
        case outcome
        case byWindow = "by_window"
        case atMs = "at_ms"
        case toolUseId = "tool_use_id"
    }
}

/// `approval_session_rules`: a focus's active session rules as a whole (REPLACE semantics).
public struct ApprovalSessionRulesFrame: Decodable, Equatable {
    public let tag: String
    public let rules: [ApprovalSessionRule]

    public init(tag: String, rules: [ApprovalSessionRule]) {
        self.tag = tag
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey { case tag, rules }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        rules = try c.decode(ApprovalLossyArray<ApprovalSessionRule>.self, forKey: .rules).elements
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
    /// `allow_session` only: the id of one of the request's own candidates, and its text as shown.
    public let candidateId: String?
    public let ruleText: String?

    public init(kind: ApprovalDecisionKind, note: String? = nil, answers: [ApprovalQuestionAnswer]? = nil,
                candidateId: String? = nil, ruleText: String? = nil) {
        self.kind = kind
        self.note = note
        self.answers = answers
        self.candidateId = candidateId
        self.ruleText = ruleText
    }

    enum CodingKeys: String, CodingKey {
        case kind, note, answers
        case candidateId = "candidate_id"
        case ruleText = "rule_text"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(answers, forKey: .answers)
        try c.encodeIfPresent(candidateId, forKey: .candidateId)
        try c.encodeIfPresent(ruleText, forKey: .ruleText)
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

/// `approval_revoke_session_rule`: the human revoked one active session rule. `operatorNonce`
/// echoes the nonce this connection's `welcome` carried (the daemon refuses it without).
public struct ClientApprovalRevokeSessionRule: Encodable, Equatable {
    let type_ = "approval_revoke_session_rule"
    public let tag: String
    public let ruleId: String
    public let operatorNonce: String?

    public init(tag: String, ruleId: String, operatorNonce: String?) {
        self.tag = tag
        self.ruleId = ruleId
        self.operatorNonce = operatorNonce
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case tag
        case ruleId = "rule_id"
        case operatorNonce = "operator_nonce"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encode(tag, forKey: .tag)
        try c.encode(ruleId, forKey: .ruleId)
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

// MARK: - The Approvals log (AP5)
//
// Read-only. The app asks with `approvals_log_query` / `approvals_log_entry` (each echoing the connection's
// nonce; the daemon refuses anyone else) and the daemon answers with a targeted `approvals_log_page`,
// `approvals_log_detail` or `approvals_log_refused`. Mirrors `ApprovalsLogRow` / `ApprovalsLogDetail` in
// `src/approvals/wire.rs`. An unknown row kind decodes as `.other`.

public enum ApprovalsLogRowKind: String, Equatable {
    case request, refusal, guardBlocked = "guard_blocked", rule, other
}

extension ApprovalsLogRowKind: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalsLogRowKind(rawValue: raw) ?? .other
    }
}

/// One row of the log: a request merged with its outcome, or one standalone entry. No full input.
public struct ApprovalsLogRow: Decodable, Equatable, Identifiable {
    public let rowId: String
    public let kind: ApprovalsLogRowKind
    /// RFC 3339, as the daemon wrote it. See `date`.
    public let ts: String
    public let tag: String?
    public let sessionId: String?
    public let toolUseId: String?
    public let requestId: String?
    public let entryIds: [String]
    public let agent: String?
    public let subagent: ApprovalSubagent?
    public let toolName: String?
    public let summary: String
    public let outcome: String?
    public let byWindow: String?
    public let latencyMs: UInt64?
    public let refusalCode: String?
    public let ruleLabel: String?
    /// The row's focus is a sensitive (Teri/Fred-derived) one.
    public let sensitive: Bool

    public var id: String { rowId }

    public init(rowId: String, kind: ApprovalsLogRowKind, ts: String, tag: String? = nil, sessionId: String? = nil,
                toolUseId: String? = nil, requestId: String? = nil, entryIds: [String] = [], agent: String? = nil,
                subagent: ApprovalSubagent? = nil, toolName: String? = nil, summary: String = "",
                outcome: String? = nil, byWindow: String? = nil, latencyMs: UInt64? = nil,
                refusalCode: String? = nil, ruleLabel: String? = nil, sensitive: Bool = false) {
        self.rowId = rowId; self.kind = kind; self.ts = ts; self.tag = tag; self.sessionId = sessionId
        self.toolUseId = toolUseId; self.requestId = requestId; self.entryIds = entryIds; self.agent = agent
        self.subagent = subagent; self.toolName = toolName; self.summary = summary; self.outcome = outcome
        self.byWindow = byWindow; self.latencyMs = latencyMs; self.refusalCode = refusalCode
        self.ruleLabel = ruleLabel; self.sensitive = sensitive
    }

    enum CodingKeys: String, CodingKey {
        case rowId = "row_id", kind, ts, tag
        case sessionId = "session_id", toolUseId = "tool_use_id", requestId = "request_id", entryIds = "entry_ids"
        case agent, subagent, toolName = "tool_name", summary, outcome
        case byWindow = "by_window", latencyMs = "latency_ms", refusalCode = "refusal_code", ruleLabel = "rule_label"
        case sensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowId = try c.decode(String.self, forKey: .rowId)
        kind = (try? c.decode(ApprovalsLogRowKind.self, forKey: .kind)) ?? .other
        ts = try c.decode(String.self, forKey: .ts)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        toolUseId = try c.decodeIfPresent(String.self, forKey: .toolUseId)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        entryIds = (try? c.decodeIfPresent([String].self, forKey: .entryIds)) ?? []
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        subagent = (try? c.decodeIfPresent(ApprovalSubagent.self, forKey: .subagent)) ?? nil
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        byWindow = try c.decodeIfPresent(String.self, forKey: .byWindow)
        latencyMs = try c.decodeIfPresent(UInt64.self, forKey: .latencyMs)
        refusalCode = try c.decodeIfPresent(String.self, forKey: .refusalCode)
        ruleLabel = try c.decodeIfPresent(String.self, forKey: .ruleLabel)
        sensitive = (try? c.decodeIfPresent(Bool.self, forKey: .sensitive)) ?? false
    }
}

/// `approvals_log_page`: rows newest first; `nextCursor` is set when more follow.
public struct ApprovalsLogPageFrame: Decodable, Equatable {
    public let rows: [ApprovalsLogRow]
    public let nextCursor: String?
    /// The `request_id` of the query this page answers; nil from a daemon that does not echo it.
    public let requestId: String?

    public init(rows: [ApprovalsLogRow], nextCursor: String?, requestId: String? = nil) {
        self.rows = rows
        self.nextCursor = nextCursor
        self.requestId = requestId
    }

    enum CodingKeys: String, CodingKey {
        case rows
        case nextCursor = "next_cursor"
        case requestId = "request_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = try c.decode(ApprovalLossyArray<ApprovalsLogRow>.self, forKey: .rows).elements
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
    }
}

/// One log entry in full.
public struct ApprovalsLogDetail: Decodable, Equatable {
    public let id: String
    public let event: String
    public let ts: String
    public let tag: String?
    public let requestId: String?
    public let toolName: String?
    /// The full input exactly as recorded (invisible characters are already `⟨U+202E⟩` tokens).
    public let input: ApprovalJSON?
    public let displayText: String?
    public let reason: ApprovalJSON?
    public let flags: ApprovalJSON?
    public let options: ApprovalJSON?
    public let outcome: String?
    public let byWindow: String?
    public let latencyMs: UInt64?
    public let rule: ApprovalJSON?
    public let detail: String?
    public let refusalCode: String?
    public let peer: ApprovalJSON?
    public let channel: String?
    public let control: String?
    public let sensitive: Bool

    public init(id: String, event: String, ts: String, tag: String? = nil, requestId: String? = nil,
                toolName: String? = nil, input: ApprovalJSON? = nil, displayText: String? = nil,
                reason: ApprovalJSON? = nil, flags: ApprovalJSON? = nil, options: ApprovalJSON? = nil,
                outcome: String? = nil, byWindow: String? = nil, latencyMs: UInt64? = nil,
                rule: ApprovalJSON? = nil, detail: String? = nil, refusalCode: String? = nil,
                peer: ApprovalJSON? = nil, channel: String? = nil, control: String? = nil, sensitive: Bool = false) {
        self.id = id; self.event = event; self.ts = ts; self.tag = tag; self.requestId = requestId
        self.toolName = toolName; self.input = input; self.displayText = displayText; self.reason = reason
        self.flags = flags; self.options = options; self.outcome = outcome; self.byWindow = byWindow
        self.latencyMs = latencyMs; self.rule = rule; self.detail = detail; self.refusalCode = refusalCode
        self.peer = peer; self.channel = channel; self.control = control; self.sensitive = sensitive
    }

    enum CodingKeys: String, CodingKey {
        case id, event, ts, tag, requestId = "request_id", toolName = "tool_name", input
        case displayText = "display_text", reason, flags, options, outcome
        case byWindow = "by_window", latencyMs = "latency_ms", rule, detail
        case refusalCode = "refusal_code", peer, channel, control, sensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        event = try c.decode(String.self, forKey: .event)
        ts = try c.decode(String.self, forKey: .ts)
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        input = try c.decodeIfPresent(ApprovalJSON.self, forKey: .input)
        displayText = try c.decodeIfPresent(String.self, forKey: .displayText)
        reason = try c.decodeIfPresent(ApprovalJSON.self, forKey: .reason)
        flags = try c.decodeIfPresent(ApprovalJSON.self, forKey: .flags)
        options = try c.decodeIfPresent(ApprovalJSON.self, forKey: .options)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        byWindow = try c.decodeIfPresent(String.self, forKey: .byWindow)
        latencyMs = try c.decodeIfPresent(UInt64.self, forKey: .latencyMs)
        rule = try c.decodeIfPresent(ApprovalJSON.self, forKey: .rule)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        refusalCode = try c.decodeIfPresent(String.self, forKey: .refusalCode)
        peer = try c.decodeIfPresent(ApprovalJSON.self, forKey: .peer)
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        control = try c.decodeIfPresent(String.self, forKey: .control)
        sensitive = (try? c.decodeIfPresent(Bool.self, forKey: .sensitive)) ?? false
    }
}

/// `approvals_log_detail`: `detail` is nil when no entry has `id`.
public struct ApprovalsLogDetailFrame: Decodable, Equatable {
    public let id: String
    public let detail: ApprovalsLogDetail?

    public init(id: String, detail: ApprovalsLogDetail?) {
        self.id = id
        self.detail = detail
    }
}

/// `approvals_log_refused`: `not_operator_app`, `requires_secure_connection`, `bad_cursor` or `unavailable`.
public struct ApprovalsLogRefusedFrame: Decodable, Equatable {
    public let code: String
    /// The `request_id` of the query this refuses, when it had one.
    public let requestId: String?

    public init(code: String, requestId: String? = nil) { self.code = code; self.requestId = requestId }

    enum CodingKeys: String, CodingKey {
        case code
        case requestId = "request_id"
    }
}

/// `approvals_log_query`: one page, newest first. `operatorNonce` echoes this connection's `welcome` nonce.
public struct ClientApprovalsLogQuery: Encodable, Equatable {
    let type_ = "approvals_log_query"
    public let tag: String?
    public let outcome: String?
    public let sinceMs: Int64?
    public let limit: Int
    public let cursor: String?
    /// Echoed in the page, so a late page for an older query can be told apart.
    public let requestId: String?
    public let operatorNonce: String?

    public init(tag: String?, outcome: String?, sinceMs: Int64?, limit: Int, cursor: String?,
                requestId: String? = nil, operatorNonce: String?) {
        self.tag = tag; self.outcome = outcome; self.sinceMs = sinceMs; self.limit = limit
        self.cursor = cursor; self.requestId = requestId; self.operatorNonce = operatorNonce
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", tag, outcome, sinceMs = "since_ms", limit, cursor
        case requestId = "request_id", operatorNonce = "operator_nonce"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encodeIfPresent(tag, forKey: .tag)
        try c.encodeIfPresent(outcome, forKey: .outcome)
        try c.encodeIfPresent(sinceMs, forKey: .sinceMs)
        try c.encode(limit, forKey: .limit)
        try c.encodeIfPresent(cursor, forKey: .cursor)
        try c.encodeIfPresent(requestId, forKey: .requestId)
        try c.encodeIfPresent(operatorNonce, forKey: .operatorNonce)
    }
}

/// `approvals_log_entry`: one entry in full (`id` is a request id or an entry id).
public struct ClientApprovalsLogEntry: Encodable, Equatable {
    let type_ = "approvals_log_entry"
    public let id: String
    /// The time of the row the entry belongs to, when known: the daemon reads only the days around it.
    public let tsMs: Int64?
    public let operatorNonce: String?

    public init(id: String, tsMs: Int64? = nil, operatorNonce: String?) {
        self.id = id
        self.tsMs = tsMs
        self.operatorNonce = operatorNonce
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", id, tsMs = "ts_ms", operatorNonce = "operator_nonce"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(tsMs, forKey: .tsMs)
        try c.encodeIfPresent(operatorNonce, forKey: .operatorNonce)
    }
}
