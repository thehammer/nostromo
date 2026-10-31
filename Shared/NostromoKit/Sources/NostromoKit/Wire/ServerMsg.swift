// NostromoKit — ServerMsg.swift
//
// Inbound messages received from the nostromd daemon.
// Mirrors the Rust `ServerMsg` enum in `src/ipc/protocol.rs`.
//
// Ported from macOS/Nostromo/Data/NostromodClient.swift — the decode/encode
// logic and all `Daemon*` wire types are preserved verbatim. Pure value types.

import Foundation

// MARK: - Top-level ServerMsg

/// Decoded form of a daemon → client message.
public enum ServerMsg {
    case welcome(protocolVersion: Int, daemonPid: Int, enabledAgents: EnabledAgents = .all)
    case pong
    case error(String)

    /// Snapshot of all daemon-hosted sessions (response to `session_list`).
    case sessionListResp([SessionInfo])

    /// A session was spawned or was already live.
    case sessionSpawned(tag: String, sessionId: String?)
    /// Session lifecycle state changed.
    case sessionState(tag: String, state: SessionState)
    /// The session's MCP bridge connected to (`true`) or was lost from
    /// (`false`) the daemon.
    case sessionBridge(tag: String, connected: Bool)
    /// The session has been permanently stopped.
    case sessionDown(tag: String, reason: StopReason)
    /// Auto-generated one-line summary for this session.
    case sessionSummaryUpdate(tag: String, summary: String)
    /// Full turn snapshot sent immediately on attach.
    case sessionTurns(tag: String, turns: [DaemonTurn])
    /// Incremental turn update.
    case sessionTurnDelta(tag: String, delta: DaemonTurnDelta)
    /// A permission request surfaced on the stream.
    case sessionPermissionRequest(tag: String, requestId: String, tool: String)
    /// The session's child process exited.
    case sessionExited(tag: String, exitCode: Int?)

    /// Response to `focus_list`.
    case focusListResp([FocusMeta])
    /// Broadcast registry change.
    case focusRegistryUpdated([FocusMeta])

    /// Broadcast snapshot of all Mother jobs.
    case motherJobs([MotherJob])

    /// Live peek snapshot for one active Mother job.
    /// Sent every ~3 s while a job is running or awaiting.
    /// An empty `todos` array signals that the job left the active set (terminal clear).
    case motherPeek(MotherPeekSnapshot)

    /// Broadcast snapshot of one focus's PR review state (W7/W8).
    ///
    /// `queue` is fleet-wide — byte-identical in every frame regardless of
    /// `tag` — because there is one set of open PRs and every focus sees the
    /// same one. `current` is per-focus: the PR **`tag`'s focus** has under
    /// review, or `nil` when it has none. Callers must key `current` by
    /// `tag` and never let one focus's frame overwrite another's.
    case perriState(tag: String, queue: [PrQueueItem], current: PrSnapshot?)

    /// Broadcast snapshot of Fred's mailbox + calendar state.
    case fredState(mailbox: MailboxSnapshot, calendar: CalendarSnapshot)

    /// Broadcast snapshot of Teri's active todos.
    case teriState(TeriTodosSnapshot)

    /// Structural layout update for a focus (create_pane / reset_panes / set_pane_layout).
    case focusLayout(tag: String, tree: PaneTree, focusedPane: String?)

    /// Content update for a single pane (set_pane_content — does not touch geometry).
    /// `freshness` is `nil` for content with no staleness concept (e.g.
    /// agent-authored content) and for frames from a daemon that predates
    /// this field — always decodes successfully either way. `address` (W1 —
    /// curated-agent-views) is likewise `nil` for any push with nothing to
    /// point at, and for frames from a daemon that predates the field.
    case paneContent(tag: String, paneId: String, content: PaneContentWire, freshness: PaneFreshness?, address: PaneAddress?)

    /// A new daemon-hosted focus was spawned via `create_focus`.
    case focusCreated(meta: FocusCreatedMeta)

    /// A daemon-driven decision-modal request (W6). iOS decodes this so the
    /// frame doesn't fall through to `.unknown`, but renders nothing for it —
    /// decision modals are macOS-only in this wedge.
    case decisionRequest(tag: String, requestId: String, prompt: String, detail: String?,
                         choices: [DecisionChoice], contextPaneId: String?)

    /// A decision request was resolved — answered, dismissed, timed out, or
    /// its owning session went away (multi-window decision-sheet fix). Like
    /// `decisionRequest`, iOS decodes this so the frame doesn't fall through
    /// to `.unknown`, but renders nothing for it — decision modals are
    /// macOS-only in this wedge.
    case decisionResolved(tag: String, requestId: String, resolution: String, choiceId: String?)

    // ── ambient activity (activity-path wedge) ───────────────────────────────
    // iOS decodes these without throwing but renders nothing — no iOS UI in
    // this wedge (see the plan's "Out of scope"). Mirrors the Rust
    // `ServerMsg::Activity`/`ActivitySnapshot`/`ActivityHealth` variants.

    /// One ambient activity event, broadcast live.
    case activity(ActivityEvent)
    /// Full snapshot of one focus's activity streams (response to
    /// `activity_snapshot_request`, and replayed on attach).
    case activitySnapshot(tag: String, streams: [ActivityStreamWire])
    /// Ingestion health verdict for the ambient activity feed.
    case activityHealth(ingesting: Bool, reason: String?, lastEventAt: Date?, hookInstalled: Bool)

    /// The daemon withheld these topics from this (network) connection.
    case withheld(topics: [String], reason: String)

    // ── model switching ───────────────────────────────────────────────────────
    // Delivered only to a client that subscribes to the `model` topic.

    /// The model families the installed CLI offers, cheapest first.
    case modelCatalog(families: [ModelFamilyWire], stale: Bool, fetchedAt: String?)
    /// One focus's model: recorded, reported, any switch in progress.
    case sessionModelState(SessionModelStateWire)
    /// Per-agent defaults, and the model each agent declares. `declared` is
    /// empty for network peers.
    case modelDefaults(defaults: [String: AgentModelDefaultWire], declared: [String: String])
    /// Answer to a `session_model_set` / `model_default_set`, sent to the
    /// requesting connection only.
    case modelRequestResult(requestId: String, status: ModelRequestStatusWire,
                            code: String?, message: String?, warning: String?)

    // ── background tasks ──────────────────────────────────────────────────────

    /// Every background task of a session (full snapshot; replaces the last).
    /// Metadata only; also sent to network peers for non-sensitive focuses.
    case sessionTasks(SessionTasksWire)
    /// The text derived from one task's output or the conversation. Local
    /// clients only: the daemon never sends it to a network peer.
    case sessionTaskDetail(SessionTaskDetailWire)
    /// The answer to a `session_task_stop`. Local clients only.
    case sessionTaskStopResult(SessionTaskStopResultWire)
    /// The answer to a `session_task_output`. Local clients only.
    case sessionTaskOutputResult(SessionTaskOutputResultWire)

    // ── agent tracker ─────────────────────────────────────────────────────────

    /// The whole board the tracker pane shows for a focus (REPLACE snapshot);
    /// `board` is `nil` when the focus has no tracker. Local clients only.
    case trackerBoard(TrackerBoardFrameWire)
    /// Whether a focus has a tracker and its per-status counts. The only
    /// tracker frame a network peer receives (non-sensitive focuses).
    case trackerSummary(TrackerSummaryFrameWire)

    case unknown
}

// MARK: - DecisionChoice

/// One choice offered by a `decision_request` frame.
/// Mirrors `DecisionChoice` in `src/ipc/protocol.rs`.
public struct DecisionChoice: Decodable, Equatable {
    public let id: String
    public let label: String
    public let detail: String?
    /// The choice Return and Escape pick (`is_default`; absent means false).
    public var isDefault: Bool = false
}

extension DecisionChoice {
    private enum Keys: String, CodingKey { case id, label, detail, isDefault = "is_default" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

// MARK: - ActivityEvent / ActivityStreamWire

/// Mirrors the Rust `agent_bus::ActivityEvent`. Every field beyond the
/// original four is optional and `#[serde(default)]` on the Rust side, so an
/// old 4-field line still decodes here too.
public struct ActivityEvent: Decodable {
    public let ts:            Date
    public let agent:         String
    public let kind:          String
    public let summary:       String
    public let focusTag:      String?
    public let sessionId:     String?
    public let agentId:       String?
    public let agentType:     String?
    public let parentAgentId: String?
    public let toolName:      String?
    public let toolUseId:     String?
    public let cwd:           String?
    public let seq:           UInt64?

    enum CodingKeys: String, CodingKey {
        case ts, agent, kind, summary
        case focusTag      = "focus_tag"
        case sessionId     = "session_id"
        case agentId       = "agent_id"
        case agentType     = "agent_type"
        case parentAgentId = "parent_agent_id"
        case toolName      = "tool_name"
        case toolUseId     = "tool_use_id"
        case cwd
        case seq
    }
}

/// Mirrors the Rust `ipc::protocol::ActivityStreamWire` — one focus's main
/// stream (`agentId == nil`) or one subagent's stream.
public struct ActivityStreamWire: Decodable {
    public let agentId:       String?
    public let agentType:     String?
    public let parentAgentId: String?
    public let events:        [ActivityEvent]
    public let finished:      Bool

    enum CodingKeys: String, CodingKey {
        case agentId       = "agent_id"
        case agentType     = "agent_type"
        case parentAgentId = "parent_agent_id"
        case events, finished
    }
}

// MARK: - SessionInfo

/// Metadata about a daemon-hosted persistent session.
/// Mirrors `SessionInfo` in `src/ipc/protocol.rs`.
public struct SessionInfo: Decodable {
    public let tag:           String
    public let agentName:     String
    public let viewName:      String
    public let sessionId:     String?
    public let alive:         Bool
    public let remoteControl: Bool
    public let state:         SessionState
    public let stopReason:    StopReason?
    /// Whether the session's `nostromo-mcp-bridge` is connected to the daemon.
    /// `nil` when the daemon does not say (an older daemon, or a session that
    /// never had a bridge): absence is never read as "offline".
    public let mcpBridgeConnected: Bool?

    enum CodingKeys: String, CodingKey {
        case tag
        case agentName     = "agent_name"
        case viewName      = "view_name"
        case sessionId     = "session_id"
        case alive
        case remoteControl = "remote_control"
        case state
        case stopReason    = "stop_reason"
        case mcpBridgeConnected = "mcp_bridge_connected"
    }
}

// MARK: - SessionState

/// Lifecycle state of a daemon-hosted session.
/// Mirrors `stream_json::SessionState` in Rust.
public enum SessionState: String, Decodable, Equatable {
    case idle
    case midTurn            = "mid_turn"
    case awaitingPermission = "awaiting_permission"
    case crashed
}

// MARK: - StopReason

/// Why a session was intentionally stopped.
/// Unknown strings decode safely to `.user` to avoid false alarms on new variants.
public enum StopReason: String, Decodable {
    case user           = "user"
    case crashLoopGuard = "crash_loop_guard"
    case staleId        = "stale_id"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StopReason(rawValue: raw) ?? .user
    }
}

// MARK: - DaemonTurn / DaemonTurnDelta / DaemonTurnBlock

/// Mirrors `stream_json::Turn` in Rust.
public struct DaemonTurn: Decodable {
    public let id:          String
    public let userInput:   String
    public let timestamp:   String?
    public let blocks:      [DaemonTurnBlock]
    public let isComplete:  Bool
    /// What opened the turn when it was not something the user typed (output from a followed
    /// terminal, a follow notice). Nil for an ordinary turn, for an older daemon, and for an
    /// origin kind this client does not know: an unknown kind never costs the whole turn.
    public let origin:      TurnOriginWire?

    public init(id: String, userInput: String, timestamp: String?, blocks: [DaemonTurnBlock],
                isComplete: Bool, origin: TurnOriginWire? = nil) {
        self.id = id
        self.userInput = userInput
        self.timestamp = timestamp
        self.blocks = blocks
        self.isComplete = isComplete
        self.origin = origin
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userInput  = "user_input"
        case timestamp
        case blocks
        case isComplete = "is_complete"
        case origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  userInput: try c.decode(String.self, forKey: .userInput),
                  timestamp: try c.decodeIfPresent(String.self, forKey: .timestamp),
                  blocks: try c.decode([DaemonTurnBlock].self, forKey: .blocks),
                  isComplete: try c.decode(Bool.self, forKey: .isComplete),
                  origin: (try? c.decodeIfPresent(TurnOriginWire.self, forKey: .origin)) ?? nil)
    }
}

extension DaemonTurn {
    /// Return a copy with `block` appended to `blocks`.
    func appending(_ block: DaemonTurnBlock) -> DaemonTurn {
        DaemonTurn(id: id, userInput: userInput, timestamp: timestamp,
                   blocks: blocks + [block], isComplete: isComplete, origin: origin)
    }

    /// Return a copy with `isComplete` set to `true`.
    func completed() -> DaemonTurn {
        DaemonTurn(id: id, userInput: userInput, timestamp: timestamp,
                   blocks: blocks, isComplete: true, origin: origin)
    }
}

/// Mirrors `stream_json::TurnOrigin` — tagged by `type` (`terminal_delivery`,
/// `terminal_follow_notice`, `mother_job_notice`).
///
/// The two terminal kinds carry the same item shape here: a follow notice's items decode with
/// `kind` `"notice"`, as the daemon's own delivery items do for a notice sent with output. A Mother
/// job notice carries `MotherNoticeItemWire`s. Decoding an unknown `type` throws; `DaemonTurn`
/// turns that into a nil origin.
public enum TurnOriginWire: Codable, Equatable {
    /// Output from followed terminals, plus any notices sent with it, in the order the message
    /// has them.
    case terminalDelivery(items: [TerminalOriginItem])
    /// Follow notices only (following started, stopped, paused, resumed).
    case terminalFollowNotice(items: [TerminalOriginItem])
    /// Mother jobs the focus queued that moved, as the daemon told the agent.
    case motherJobNotice(items: [MotherNoticeItemWire])

    private enum K: String, CodingKey { case type, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .type) {
        case "terminal_delivery":
            self = .terminalDelivery(items: try c.decode([TerminalOriginItem].self, forKey: .items))
        case "terminal_follow_notice":
            let items = try c.decode([TerminalOriginItem].self, forKey: .items)
            self = .terminalFollowNotice(items: items.map { $0.asNotice })
        case "mother_job_notice":
            // A malformed item is skipped; with none left there is nothing to draw, so the
            // origin is not one (the turn then shows as the plain bubble it is).
            let items = try c.decode([LossyItem].self, forKey: .items).compactMap(\.value)
            guard !items.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .items, in: c,
                    debugDescription: "mother_job_notice without a readable item")
            }
            self = .motherJobNotice(items: items)
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "unknown TurnOrigin type: \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .terminalDelivery(let items):
            try c.encode("terminal_delivery", forKey: .type)
            try c.encode(items, forKey: .items)
        case .terminalFollowNotice(let items):
            try c.encode("terminal_follow_notice", forKey: .type)
            try c.encode(items, forKey: .items)
        case .motherJobNotice(let items):
            try c.encode("mother_job_notice", forKey: .type)
            try c.encode(items, forKey: .items)
        }
    }

    /// The terminal items of a terminal origin; empty for a Mother job notice.
    public var items: [TerminalOriginItem] {
        switch self {
        case .terminalDelivery(let items), .terminalFollowNotice(let items): return items
        case .motherJobNotice: return []
        }
    }

    /// The jobs of a Mother job notice; empty for a terminal origin.
    public var motherNoticeItems: [MotherNoticeItemWire] {
        if case .motherJobNotice(let items) = self { return items }
        return []
    }

    private struct LossyItem: Decodable {
        let value: MotherNoticeItemWire?
        init(from decoder: Decoder) throws { value = try? MotherNoticeItemWire(from: decoder) }
    }
}

/// One element of a terminal delivery message: a `<nostromo-terminal-output>` (kind `lines`,
/// `screen` or `selection`) or a `<nostromo-terminal-follow/>` notice (kind `notice`, with
/// `event` and maybe `reason`). Mirrors `DeliveryItem` / `NoticeItem` in Rust; a count the wire
/// omits is 0.
public struct TerminalOriginItem: Codable, Equatable {
    public let terminalId:  String
    public let pane:        String
    public let kind:        String
    public let lines:       Int
    public let omitted:     Int
    public let redactions:  Int
    public let event:       String?
    public let reason:      String?

    public static let noticeKind = "notice"

    public var isNotice: Bool { kind == Self.noticeKind }

    public init(terminalId: String, pane: String, kind: String, lines: Int = 0, omitted: Int = 0,
                redactions: Int = 0, event: String? = nil, reason: String? = nil) {
        self.terminalId = terminalId
        self.pane = pane
        self.kind = kind
        self.lines = lines
        self.omitted = omitted
        self.redactions = redactions
        self.event = event
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case terminalId = "terminal_id"
        case pane, kind, lines, omitted, redactions, event, reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let event = try c.decodeIfPresent(String.self, forKey: .event)
        self.init(terminalId: try c.decodeIfPresent(String.self, forKey: .terminalId) ?? "",
                  pane: try c.decodeIfPresent(String.self, forKey: .pane) ?? "",
                  // A follow notice's item has an `event` and no `kind`; an output element's
                  // kind defaults to `lines`, as the daemon reads it.
                  kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? (event == nil ? "lines" : Self.noticeKind),
                  lines: try c.decodeIfPresent(Int.self, forKey: .lines) ?? 0,
                  omitted: try c.decodeIfPresent(Int.self, forKey: .omitted) ?? 0,
                  redactions: try c.decodeIfPresent(Int.self, forKey: .redactions) ?? 0,
                  event: event,
                  reason: try c.decodeIfPresent(String.self, forKey: .reason))
    }

    fileprivate var asNotice: TerminalOriginItem {
        TerminalOriginItem(terminalId: terminalId, pane: pane, kind: Self.noticeKind,
                           event: event, reason: reason)
    }
}

public struct DaemonAskOption: Decodable {
    public let label:       String
    public let description: String
}

/// The optional identity, time and subagent facts a daemon attaches to a tool
/// call or tool result (`stream_json::TurnBlock::ToolCall` / `ToolResult`).
/// Every field is absent from an older daemon's wire, so every field is optional.
public struct DaemonToolMeta: Equatable {
    /// The CLI's `tool_use.id` (a call), or the id of the call a result answers.
    public var toolUseId: String?
    /// The Agent/Task call a subagent's block came from; `"?"` when the daemon
    /// knew it was a subagent's but not whose.
    public var parentToolUseId: String?
    /// The file a file tool works on (calls only).
    public var target: String?
    /// When the call was made, or the result arrived. Absent when unknown.
    public var ts: Date?

    public init(toolUseId: String? = nil, parentToolUseId: String? = nil, target: String? = nil, ts: Date? = nil) {
        self.toolUseId = toolUseId
        self.parentToolUseId = parentToolUseId
        self.target = target
        self.ts = ts
    }

    public static let none = DaemonToolMeta()
}

/// Parses the daemon's RFC 3339 timestamps (`chrono`, with or without a
/// fractional part). An unparseable value is `nil`, never a decode failure: a
/// time is decoration and must not cost a client the whole turn.
enum DaemonTimestamp {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return fractional.date(from: raw) ?? whole.date(from: raw)
    }
}

/// Mirrors `stream_json::TurnBlock` — tagged by `kind`.
public enum DaemonTurnBlock: Decodable {
    /// `parentToolUseId`: the Agent/Task call a subagent said this under.
    case text(String, parentToolUseId: String? = nil)
    case toolCall(toolName: String, inputSummary: String, inputFull: String, meta: DaemonToolMeta = .none)
    /// `content` is empty for a quiet success (the daemon keeps those so a client can tell a finished call from a running one).
    case toolResult(content: String, isError: Bool, meta: DaemonToolMeta = .none)
    /// `interrupted`: the operator pressed Stop — the CLI reports that as an error result, which clients render as "Interrupted", not a failure.
    case resultSummary(durationMs: Int, costUsd: Double, isError: Bool, interrupted: Bool = false)
    case errorMessage(String)
    case askQuestion(question: String, header: String, options: [DaemonAskOption], multiSelect: Bool)
    /// A daemon-authored transcript marker ("Model changed to Opus (from
    /// Sonnet) by you."): not a message, never sent to the agent. `kind` is the
    /// raw `note_kind` (`model_changed`, `model_pending`, `model_failed`, ...).
    case note(kind: String, text: String, ts: String?)

    private enum K: String, CodingKey {
        case kind
        case noteKind     = "note_kind"
        case ts
        case text
        case toolName     = "tool_name"
        case inputSummary = "input_summary"
        case inputFull    = "input_full"
        case toolUseId    = "tool_use_id"
        case parentToolUseId = "parent_tool_use_id"
        case target
        case content
        case isError      = "is_error"
        case interrupted
        case durationMs   = "duration_ms"
        case costUsd      = "cost_usd"
        case message
        case question, header, options
        case multiSelect  = "multi_select"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text),
                         parentToolUseId: try c.decodeIfPresent(String.self, forKey: .parentToolUseId))
        case "tool_call":
            self = .toolCall(
                toolName:     try c.decode(String.self, forKey: .toolName),
                inputSummary: try c.decode(String.self, forKey: .inputSummary),
                inputFull:    try c.decode(String.self, forKey: .inputFull),
                meta:         try Self.decodeMeta(c)
            )
        case "tool_result":
            self = .toolResult(
                content: try c.decode(String.self, forKey: .content),
                isError: try c.decode(Bool.self,   forKey: .isError),
                meta:    try Self.decodeMeta(c)
            )
        case "result_summary":
            self = .resultSummary(
                durationMs: try c.decode(Int.self,    forKey: .durationMs),
                costUsd:    try c.decode(Double.self, forKey: .costUsd),
                isError:    try c.decode(Bool.self,   forKey: .isError),
                interrupted: try c.decodeIfPresent(Bool.self, forKey: .interrupted) ?? false
            )
        case "error_message":
            self = .errorMessage(try c.decode(String.self, forKey: .message))
        case "ask_question":
            self = .askQuestion(
                question:    try c.decode(String.self,           forKey: .question),
                header:      try c.decode(String.self,           forKey: .header),
                options:     try c.decode([DaemonAskOption].self, forKey: .options),
                multiSelect: try c.decode(Bool.self,             forKey: .multiSelect)
            )
        case "note":
            // `note_kind`, not `kind`: `kind` is this enum's own tag.
            self = .note(
                kind: try c.decodeIfPresent(String.self, forKey: .noteKind) ?? "",
                text: try c.decode(String.self, forKey: .text),
                ts:   try c.decodeIfPresent(String.self, forKey: .ts)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown TurnBlock kind: \(other)")
        }
    }
}

extension DaemonTurnBlock {
    private static func decodeMeta(_ c: KeyedDecodingContainer<K>) throws -> DaemonToolMeta {
        DaemonToolMeta(
            toolUseId:       try c.decodeIfPresent(String.self, forKey: .toolUseId),
            parentToolUseId: try c.decodeIfPresent(String.self, forKey: .parentToolUseId),
            target:          try c.decodeIfPresent(String.self, forKey: .target),
            ts:              DaemonTimestamp.parse(try c.decodeIfPresent(String.self, forKey: .ts))
        )
    }
}

public struct DaemonResultSummary: Decodable {
    public let durationMs: Int
    public let costUsd:    Double
    public let isError:    Bool
    /// See `DaemonTurnBlock.resultSummary`'s `interrupted`. Absent from older daemons → `nil`.
    public let interrupted: Bool?

    enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case costUsd    = "cost_usd"
        case isError    = "is_error"
        case interrupted
    }
}

/// Mirrors `stream_json::TurnDelta` — tagged by `delta`.
public enum DaemonTurnDelta: Decodable {
    case turnStarted(DaemonTurn)
    case blockAppended(turnId: String, block: DaemonTurnBlock)
    case turnCompleted(turnId: String, summary: DaemonResultSummary)
    case turnErrored(turnId: String, message: String)
    /// A `note` block was added after turn `turnId`; `nil` means the session
    /// has no turn yet.
    case note(turnId: String?, block: DaemonTurnBlock)

    private enum K: String, CodingKey {
        case delta
        case turn
        case turnId  = "turn_id"
        case block
        case summary
        case message
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .delta) {
        case "turn_started":
            self = .turnStarted(try c.decode(DaemonTurn.self, forKey: .turn))
        case "block_appended":
            self = .blockAppended(
                turnId: try c.decode(String.self,            forKey: .turnId),
                block:  try c.decode(DaemonTurnBlock.self,   forKey: .block)
            )
        case "turn_completed":
            self = .turnCompleted(
                turnId:  try c.decode(String.self,               forKey: .turnId),
                summary: try c.decode(DaemonResultSummary.self,  forKey: .summary)
            )
        case "turn_errored":
            self = .turnErrored(
                turnId:  try c.decode(String.self, forKey: .turnId),
                message: try c.decode(String.self, forKey: .message)
            )
        case "note":
            self = .note(
                turnId: try c.decodeIfPresent(String.self, forKey: .turnId),
                block:  try c.decode(DaemonTurnBlock.self, forKey: .block)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .delta, in: c,
                debugDescription: "unknown TurnDelta: \(other)")
        }
    }
}

// MARK: - Decoder helper (JSON date strategy)

/// JSON decoder configured with a custom date strategy that accepts both
/// `2026-05-30T09:30:56Z` and `2026-05-30T09:30:56.510874Z` (with fractional
/// seconds).  Swift's built-in `.iso8601` strategy rejects fractional seconds.
public extension JSONDecoder {
    static var nostromo: JSONDecoder {
        let d = JSONDecoder()
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmtBasic = ISO8601DateFormatter()
        fmtBasic.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let c   = try decoder.singleValueContainer()
            let str = try c.decode(String.self)
            if let date = fmtFrac.date(from: str)  { return date }
            if let date = fmtBasic.date(from: str) { return date }
            throw DecodingError.dataCorruptedError(in: c,
                debugDescription: "Cannot parse date: \(str)")
        }
        return d
    }
}

// MARK: - ServerMsg decoding

extension ServerMsg {
    // Private helpers for decoding the response-wrapper structs below.
    private struct WithheldWrapper: Decodable { let topics: [String]; let reason: String }
    private struct SessionListRespWrapper:   Decodable { let sessions: [SessionInfo] }
    private struct SessionSpawnedWrapper:    Decodable { let tag: String; let session_id: String? }
    private struct SessionStateWrapper:      Decodable { let tag: String; let state: SessionState }
    private struct SessionBridgeWrapper:     Decodable { let tag: String; let connected: Bool }
    private struct SessionDownWrapper:       Decodable { let tag: String; let reason: StopReason }
    private struct SessionSummaryWrapper:    Decodable { let tag: String; let summary: String }
    private struct SessionTurnsWrapper:      Decodable { let tag: String; let turns: [DaemonTurn] }
    private struct SessionTurnDeltaWrapper:  Decodable { let tag: String; let delta: DaemonTurnDelta }
    private struct SessionPermWrapper:       Decodable { let tag: String; let request_id: String; let tool: String }
    private struct SessionExitedWrapper:     Decodable { let tag: String; let exit_code: Int? }
    private struct FocusListWrapper:         Decodable { let focuses: [FocusMeta] }
    private struct MotherJobsWrapper:        Decodable { let jobs: [MotherJob] }
    private struct PerriStateWrapper:        Decodable { let tag: String; let queue: [PrQueueItem]; let current: PrSnapshot? }
    private struct FredStateWrapper:         Decodable { let mailbox: MailboxSnapshot; let calendar: CalendarSnapshot }
    private struct TeriStateWrapper:         Decodable { let todos: TeriTodosSnapshot }
    private struct FocusLayoutWrapper:       Decodable { let tag: String; let tree: PaneTree; let focused_pane: String? }
    private struct PaneContentWrapper:       Decodable { let tag: String; let pane_id: String; let content: PaneContentWire; let freshness: PaneFreshness?; let address: PaneAddress? }
    private struct DecisionRequestWrapper:   Decodable {
        let tag: String
        let request_id: String
        let prompt: String
        let detail: String?
        let choices: [DecisionChoice]
        let context_pane_id: String?
    }
    private struct DecisionResolvedWrapper:  Decodable {
        let tag: String
        let request_id: String
        let resolution: String
        let choice_id: String?
    }
    private struct ActivitySnapshotWrapper:  Decodable { let tag: String; let streams: [ActivityStreamWire] }
    private struct ActivityHealthWrapper:    Decodable {
        let ingesting: Bool
        let reason: String?
        let last_event_at: Date?
        let hook_installed: Bool
    }

    private struct ModelRequestResultWrapper: Decodable {
        let request_id: String
        let status: ModelRequestStatusWire
        let code: String?
        let message: String?
        let warning: String?
    }

    /// Decode a raw JSON frame from the daemon.
    /// Unknown message types decode to `.unknown` rather than throwing.
    public static func decode(from data: Data) -> ServerMsg {
        guard
            let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type_ = json["type"] as? String
        else { return .unknown }

        let dec = JSONDecoder.nostromo

        switch type_ {
        case "welcome":
            return .welcome(
                protocolVersion: json["protocol_version"] as? Int ?? 0,
                daemonPid:       json["daemon_pid"]       as? Int ?? 0,
                enabledAgents:   EnabledAgents(wireValue: json["enabled_agents"])
            )

        case "pong":
            return .pong

        case "error":
            return .error(json["message"] as? String ?? "unknown error")

        case "session_list_resp":
            if let m = try? dec.decode(SessionListRespWrapper.self, from: data) {
                return .sessionListResp(m.sessions)
            }

        case "session_spawned":
            if let m = try? dec.decode(SessionSpawnedWrapper.self, from: data) {
                return .sessionSpawned(tag: m.tag, sessionId: m.session_id)
            }

        case "session_state":
            if let m = try? dec.decode(SessionStateWrapper.self, from: data) {
                return .sessionState(tag: m.tag, state: m.state)
            }

        case "session_bridge":
            if let m = try? dec.decode(SessionBridgeWrapper.self, from: data) {
                return .sessionBridge(tag: m.tag, connected: m.connected)
            }

        case "session_down":
            if let m = try? dec.decode(SessionDownWrapper.self, from: data) {
                return .sessionDown(tag: m.tag, reason: m.reason)
            }

        case "session_summary_update":
            if let m = try? dec.decode(SessionSummaryWrapper.self, from: data) {
                return .sessionSummaryUpdate(tag: m.tag, summary: m.summary)
            }

        case "session_turns":
            if let m = try? dec.decode(SessionTurnsWrapper.self, from: data) {
                return .sessionTurns(tag: m.tag, turns: m.turns)
            }

        case "session_turn_delta":
            if let m = try? dec.decode(SessionTurnDeltaWrapper.self, from: data) {
                return .sessionTurnDelta(tag: m.tag, delta: m.delta)
            }

        case "session_permission_request":
            if let m = try? dec.decode(SessionPermWrapper.self, from: data) {
                return .sessionPermissionRequest(tag: m.tag, requestId: m.request_id, tool: m.tool)
            }

        case "session_exited":
            if let m = try? dec.decode(SessionExitedWrapper.self, from: data) {
                return .sessionExited(tag: m.tag, exitCode: m.exit_code)
            }

        case "focus_list_resp":
            if let m = try? dec.decode(FocusListWrapper.self, from: data) {
                return .focusListResp(m.focuses)
            }

        case "focus_registry_updated":
            if let m = try? dec.decode(FocusListWrapper.self, from: data) {
                return .focusRegistryUpdated(m.focuses)
            }

        case "mother_jobs":
            if let m = try? dec.decode(MotherJobsWrapper.self, from: data) {
                return .motherJobs(m.jobs)
            }

        case "mother_peek":
            if let snap = try? dec.decode(MotherPeekSnapshot.self, from: data) {
                return .motherPeek(snap)
            }

        case "perri_state":
            if let m = try? dec.decode(PerriStateWrapper.self, from: data) {
                return .perriState(tag: m.tag, queue: m.queue, current: m.current)
            }

        case "fred_state":
            if let m = try? dec.decode(FredStateWrapper.self, from: data) {
                return .fredState(mailbox: m.mailbox, calendar: m.calendar)
            }

        case "withheld":
            if let m = try? dec.decode(WithheldWrapper.self, from: data) {
                return .withheld(topics: m.topics, reason: m.reason)
            }

        case "teri_state":
            if let m = try? dec.decode(TeriStateWrapper.self, from: data) {
                return .teriState(m.todos)
            }

        case "focus_layout":
            if let m = try? dec.decode(FocusLayoutWrapper.self, from: data) {
                return .focusLayout(tag: m.tag, tree: m.tree, focusedPane: m.focused_pane)
            }

        case "pane_content":
            if let m = try? dec.decode(PaneContentWrapper.self, from: data) {
                return .paneContent(tag: m.tag, paneId: m.pane_id, content: m.content, freshness: m.freshness, address: m.address)
            }

        case "focus_created":
            if let m = try? dec.decode(FocusCreatedMeta.self, from: data) {
                return .focusCreated(meta: m)
            }

        case "decision_request":
            if let m = try? dec.decode(DecisionRequestWrapper.self, from: data) {
                return .decisionRequest(tag: m.tag, requestId: m.request_id, prompt: m.prompt,
                                        detail: m.detail, choices: m.choices,
                                        contextPaneId: m.context_pane_id)
            }

        case "decision_resolved":
            if let m = try? dec.decode(DecisionResolvedWrapper.self, from: data) {
                return .decisionResolved(tag: m.tag, requestId: m.request_id,
                                         resolution: m.resolution, choiceId: m.choice_id)
            }

        case "activity":
            if let ev = try? dec.decode(ActivityEvent.self, from: data) {
                return .activity(ev)
            }

        case "activity_snapshot":
            if let m = try? dec.decode(ActivitySnapshotWrapper.self, from: data) {
                return .activitySnapshot(tag: m.tag, streams: m.streams)
            }

        case "activity_health":
            if let m = try? dec.decode(ActivityHealthWrapper.self, from: data) {
                return .activityHealth(
                    ingesting: m.ingesting,
                    reason: m.reason,
                    lastEventAt: m.last_event_at,
                    hookInstalled: m.hook_installed
                )
            }

        case "model_catalog":
            if let m = try? dec.decode(ModelCatalogFrame.self, from: data) {
                return .modelCatalog(families: m.families, stale: m.stale, fetchedAt: m.fetchedAt)
            }

        case "session_model_state":
            if let m = try? dec.decode(SessionModelStateWire.self, from: data) {
                return .sessionModelState(m)
            }

        case "model_defaults":
            if let m = try? dec.decode(ModelDefaultsFrame.self, from: data) {
                return .modelDefaults(defaults: m.defaults, declared: m.declared)
            }

        case "model_request_result":
            if let m = try? dec.decode(ModelRequestResultWrapper.self, from: data) {
                return .modelRequestResult(requestId: m.request_id, status: m.status,
                                           code: m.code, message: m.message, warning: m.warning)
            }

        case "session_tasks":
            if let m = try? dec.decode(SessionTasksWire.self, from: data) {
                return .sessionTasks(m)
            }

        case "session_task_detail":
            if let m = try? dec.decode(SessionTaskDetailWire.self, from: data) {
                return .sessionTaskDetail(m)
            }

        case "session_task_stop_result":
            if let m = try? dec.decode(SessionTaskStopResultWire.self, from: data) {
                return .sessionTaskStopResult(m)
            }

        case "session_task_output_result":
            if let m = try? dec.decode(SessionTaskOutputResultWire.self, from: data) {
                return .sessionTaskOutputResult(m)
            }

        case "tracker_board":
            if let m = try? dec.decode(TrackerBoardFrameWire.self, from: data) {
                return .trackerBoard(m)
            }

        case "tracker_summary":
            if let m = try? dec.decode(TrackerSummaryFrameWire.self, from: data) {
                return .trackerSummary(m)
            }

        default:
            break
        }

        return .unknown
    }
}
