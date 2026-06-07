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
    case welcome(protocolVersion: Int, daemonPid: Int)
    case pong
    case error(String)

    /// Snapshot of all daemon-hosted sessions (response to `session_list`).
    case sessionListResp([SessionInfo])

    /// A session was spawned or was already live.
    case sessionSpawned(tag: String, sessionId: String?)
    /// Session lifecycle state changed.
    case sessionState(tag: String, state: SessionState)
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

    case unknown
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

    enum CodingKeys: String, CodingKey {
        case tag
        case agentName     = "agent_name"
        case viewName      = "view_name"
        case sessionId     = "session_id"
        case alive
        case remoteControl = "remote_control"
        case state
        case stopReason    = "stop_reason"
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

    enum CodingKeys: String, CodingKey {
        case id
        case userInput  = "user_input"
        case timestamp
        case blocks
        case isComplete = "is_complete"
    }
}

extension DaemonTurn {
    /// Return a copy with `block` appended to `blocks`.
    func appending(_ block: DaemonTurnBlock) -> DaemonTurn {
        DaemonTurn(id: id, userInput: userInput, timestamp: timestamp,
                   blocks: blocks + [block], isComplete: isComplete)
    }

    /// Return a copy with `isComplete` set to `true`.
    func completed() -> DaemonTurn {
        DaemonTurn(id: id, userInput: userInput, timestamp: timestamp,
                   blocks: blocks, isComplete: true)
    }
}

public struct DaemonAskOption: Decodable {
    public let label:       String
    public let description: String
}

/// Mirrors `stream_json::TurnBlock` — tagged by `kind`.
public enum DaemonTurnBlock: Decodable {
    case text(String)
    case toolCall(toolName: String, inputSummary: String, inputFull: String)
    case toolResult(content: String, isError: Bool)
    case resultSummary(durationMs: Int, costUsd: Double, isError: Bool)
    case errorMessage(String)
    case askQuestion(question: String, header: String, options: [DaemonAskOption], multiSelect: Bool)

    private enum K: String, CodingKey {
        case kind
        case text
        case toolName     = "tool_name"
        case inputSummary = "input_summary"
        case inputFull    = "input_full"
        case content
        case isError      = "is_error"
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
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_call":
            self = .toolCall(
                toolName:     try c.decode(String.self, forKey: .toolName),
                inputSummary: try c.decode(String.self, forKey: .inputSummary),
                inputFull:    try c.decode(String.self, forKey: .inputFull)
            )
        case "tool_result":
            self = .toolResult(
                content: try c.decode(String.self, forKey: .content),
                isError: try c.decode(Bool.self,   forKey: .isError)
            )
        case "result_summary":
            self = .resultSummary(
                durationMs: try c.decode(Int.self,    forKey: .durationMs),
                costUsd:    try c.decode(Double.self, forKey: .costUsd),
                isError:    try c.decode(Bool.self,   forKey: .isError)
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
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                debugDescription: "unknown TurnBlock kind: \(other)")
        }
    }
}

public struct DaemonResultSummary: Decodable {
    public let durationMs: Int
    public let costUsd:    Double
    public let isError:    Bool

    enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case costUsd    = "cost_usd"
        case isError    = "is_error"
    }
}

/// Mirrors `stream_json::TurnDelta` — tagged by `delta`.
public enum DaemonTurnDelta: Decodable {
    case turnStarted(DaemonTurn)
    case blockAppended(turnId: String, block: DaemonTurnBlock)
    case turnCompleted(turnId: String, summary: DaemonResultSummary)
    case turnErrored(turnId: String, message: String)

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
    private struct SessionListRespWrapper:   Decodable { let sessions: [SessionInfo] }
    private struct SessionSpawnedWrapper:    Decodable { let tag: String; let session_id: String? }
    private struct SessionStateWrapper:      Decodable { let tag: String; let state: SessionState }
    private struct SessionDownWrapper:       Decodable { let tag: String; let reason: StopReason }
    private struct SessionSummaryWrapper:    Decodable { let tag: String; let summary: String }
    private struct SessionTurnsWrapper:      Decodable { let tag: String; let turns: [DaemonTurn] }
    private struct SessionTurnDeltaWrapper:  Decodable { let tag: String; let delta: DaemonTurnDelta }
    private struct SessionPermWrapper:       Decodable { let tag: String; let request_id: String; let tool: String }
    private struct SessionExitedWrapper:     Decodable { let tag: String; let exit_code: Int? }
    private struct FocusListWrapper:         Decodable { let focuses: [FocusMeta] }

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
                daemonPid:       json["daemon_pid"]       as? Int ?? 0
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

        default:
            break
        }

        return .unknown
    }
}
