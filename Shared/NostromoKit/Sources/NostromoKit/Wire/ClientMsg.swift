// NostromoKit — ClientMsg.swift
//
// Outbound messages sent from NostromoKit clients to the daemon.
// Mirrors the Rust `ClientMsg` enum in `src/ipc/protocol.rs`.
// All types are pure value types (Encodable); no import dependencies.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Hello

/// First message sent on every new connection.
struct ClientHello: Encodable {
    let type_           = "hello"
    let clientId:        String
    let protocolVersion: Int
    /// What this client can render beyond the base protocol. `merged_turns_v1`: a turn may answer
    /// several queued messages merged into one frame (`DaemonTurn.userParts`).
    let capabilities:    [String]

    init(clientId: String, protocolVersion: Int, capabilities: [String] = ["merged_turns_v1"]) {
        self.clientId = clientId
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case type_           = "type"
        case clientId        = "client_id"
        case protocolVersion = "protocol_version"
        case capabilities
    }
}

// MARK: - Subscribe

/// Subscribe to one or more broadcast topic streams.
///
/// `rendersDecisions` declares that this client can actually present a
/// decision-modal request to a human and answer it — the fact
/// `nostromo.ask_decision` needs before it will submit a request rather than
/// fail fast with `no_operator`. Naming `"decision"` in `topics` makes the
/// same claim; either is sufficient. Mirrors `ClientMsg::Subscribe` in
/// `src/ipc/protocol.rs`.
///
/// `init` gives `rendersDecisions` no default value deliberately — every
/// construction site must state it explicitly, so a future flip to `true`
/// (once a client can actually render a decision) is a visible, one-word diff
/// rather than an easy-to-miss omission.
///
/// `rendersApprovals` declares that this client shows permission-approval
/// requests (`approval_request`) and can answer them. The daemon honours it only
/// from the verified Mac app. Defaults to `false` on the wire: iOS never
/// presents approvals, and the Mac app does not yet either (AP2a flips it).
struct ClientSubscribe: Encodable {
    let type_:            String = "subscribe"
    let topics:            [String]
    let rendersDecisions:  Bool
    let rendersApprovals:  Bool
    /// The last `seq` seen per topic (W12). Sent only to a daemon that listed `"seq"` in
    /// `Welcome.features`; `nil` (no key on the wire) means "no resume".
    let resume:            [String: UInt64]?

    init(topics: [String], rendersDecisions: Bool, rendersApprovals: Bool = false,
         resume: [String: UInt64] = [:]) {
        self.topics = topics
        self.rendersDecisions = rendersDecisions
        self.rendersApprovals = rendersApprovals
        self.resume = resume.isEmpty ? nil : resume
    }

    enum CodingKeys: String, CodingKey {
        case type_            = "type"
        case topics
        case rendersDecisions = "renders_decisions"
        case rendersApprovals = "renders_approvals"
        case resume
    }
}

// MARK: - Ping

struct ClientPing: Encodable {
    let type_ = "ping"
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

// MARK: - SessionList

/// Request a snapshot of all daemon-hosted sessions.
struct ClientSessionList: Encodable {
    let type_ = "session_list"
    /// W10: ask one satellite host's queue instead of the primary's own. `nil` omits the field.
    var host: String? = nil
    enum CodingKeys: String, CodingKey { case type_ = "type", host }
}

// MARK: - FocusList

/// Request the daemon's focus registry snapshot.
struct ClientFocusList: Encodable {
    let type_ = "focus_list"
    /// W10: see `ClientSessionList.host`.
    var host: String? = nil
    enum CodingKeys: String, CodingKey { case type_ = "type", host }
}

// MARK: - SessionSpawn

struct ClientSessionSpawn: Encodable {
    let type_          = "session_spawn"
    let tag:            String
    let agentName:      String
    let viewName:       String
    let cwd:            String?
    let sessionId:      String?
    let remoteControl:  Bool

    enum CodingKeys: String, CodingKey {
        case type_         = "type"
        case tag
        case agentName     = "agent_name"
        case viewName      = "view_name"
        case cwd
        case sessionId     = "session_id"
        case remoteControl = "remote_control"
    }
}

// MARK: - SessionAttach / Detach / Control

struct ClientSessionAttach: Encodable {
    let type_ = "session_attach"
    let tag:   String
    /// W10: the satellite host that owns `tag`. `nil` omits the field.
    var host:  String? = nil
    enum CodingKeys: String, CodingKey { case type_ = "type", tag, host }
}

struct ClientSessionDetach: Encodable {
    let type_ = "session_detach"
    let tag:   String
    var host:  String? = nil
    enum CodingKeys: String, CodingKey { case type_ = "type", tag, host }
}

/// Close one tab (the tab's × button). The daemon refuses the review queue and
/// the REPL, and answers every client with the new layout.
public struct ClientClosePane: Encodable {
    let type_ = "close_pane"
    public let tag: String
    public let paneId: String
    public init(tag: String, paneId: String) { self.tag = tag; self.paneId = paneId }
    enum CodingKeys: String, CodingKey { case type_ = "type", tag, paneId = "pane_id" }
}

/// Interrupt the turn a session is running (the Stop button) without killing the
/// session. Distinct from `ClientSessionControl`'s `"stop"`, which does kill it.
public struct ClientSessionInterrupt: Encodable {
    let type_ = "session_interrupt"
    public let tag: String
    public init(tag: String) { self.tag = tag }
    enum CodingKeys: String, CodingKey { case type_ = "type", tag }
}

public struct ClientSessionControl: Encodable {
    let type_:  String = "session_control"
    public let tag:    String
    public let action: String

    public init(tag: String, action: String) {
        self.tag = tag
        self.action = action
    }

    enum CodingKeys: String, CodingKey { case type_ = "type", tag, action }
}

struct ClientSessionSend: Encodable {
    let type_:  String = "session_send"
    let tag:    String
    let text:   String
    let images: [String]
    enum CodingKeys: String, CodingKey { case type_ = "type", tag, text, images }
}

// MARK: - MotherAction

/// Request a Mother job action (cancel / retry / force_start).
/// Mirrors `ClientMsg::MotherAction` in `src/ipc/protocol.rs`.
public struct ClientMotherAction: Encodable {
    let type_:  String = "mother_action"
    public let jobId:  String
    public let action: String

    public init(jobId: String, action: String) {
        self.jobId  = jobId
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case type_  = "type"
        case jobId  = "job_id"
        case action
    }
}

// MARK: - MotherResume

/// Resume an awaiting Mother job by supplying the operator's answer.
/// Mirrors `ClientMsg::MotherResume` in `src/ipc/protocol.rs`.
public struct ClientMotherResume: Encodable {
    let type_:         String = "mother_resume"
    public let jobId:  String
    public let answer: String

    public init(jobId: String, answer: String) {
        self.jobId  = jobId
        self.answer = answer
    }

    enum CodingKeys: String, CodingKey {
        case type_  = "type"
        case jobId  = "job_id"
        case answer
    }
}

// MARK: - PerriAction

/// Request a Perri action from the daemon.
/// Mirrors `ClientMsg::PerriAction` in `src/ipc/protocol.rs`.
///
/// Supported actions:
///   - `"load_pr"` — load a specific PR; requires `prNumber` + `repo`.
///   - `"clear"`   — clear the current PR; `prNumber`/`repo` are ignored.
///   - `"approve"` — approve a PR; requires `prNumber` + `repo`. The daemon
///     resolves the HEAD sha, posts `gh pr review --approve`, and writes the
///     Phase 1 approval signal for instant queue suppression. Always gate
///     behind a `confirmationDialog` — the first tap should only stage the
///     pending approval; confirmation triggers this send.
public struct ClientPerriAction: Encodable {
    let type_:         String = "perri_action"
    public let action: String
    public let prNumber: Int?
    public let repo:     String?
    /// The focus the action is for (`load_pr` pins the PR for that focus).
    /// Omitted from the JSON when nil, which the daemon reads as "the built-in
    /// Perri focus" — what iOS sends.
    public let tag:      String?

    public init(action: String, prNumber: Int?, repo: String?, tag: String? = nil) {
        self.action   = action
        self.prNumber = prNumber
        self.repo     = repo
        self.tag      = tag
    }

    enum CodingKeys: String, CodingKey {
        case type_    = "type"
        case action
        case prNumber = "pr_number"
        case repo
        case tag
    }
}

// MARK: - DecisionAnswer

/// Answer a `decision_request` (W6 decision modals).
/// Mirrors `ClientMsg::DecisionAnswer` in `src/ipc/protocol.rs`.
///
/// `choiceId: nil` means dismissed without choosing — a distinct, meaningful
/// outcome, not a default choice — so unlike most optional fields on this
/// wire, `choice_id` is always present, as a string or as `null`.
///
/// This is why `encode(to:)` is hand-written rather than synthesized:
/// Swift's compiler-generated `Encodable` conformance encodes an `Optional`
/// property with `encodeIfPresent`, which **omits** the key entirely when
/// `nil` — exactly the ambiguous-with-"an old peer that didn't understand
/// this field" shape this type's own doc comment (and
/// `src/ipc/protocol.rs`'s `ClientMsg::DecisionAnswer`) says `choice_id`
/// must never have.
public struct ClientDecisionAnswer: Encodable {
    let type_: String = "decision_answer"
    public let requestId: String
    public let choiceId: String?

    public init(requestId: String, choiceId: String?) {
        self.requestId = requestId
        self.choiceId = choiceId
    }

    enum CodingKeys: String, CodingKey {
        case type_     = "type"
        case requestId = "request_id"
        case choiceId  = "choice_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type_, forKey: .type_)
        try container.encode(requestId, forKey: .requestId)
        // `encode`, not `encodeIfPresent` — a nil choiceId must serialize as
        // an explicit JSON `null`, never as an absent key.
        try container.encode(choiceId, forKey: .choiceId)
    }
}

// MARK: - ActivitySnapshotRequest

/// Request a full ambient-activity snapshot (all streams) for one focus.
/// The daemon replies with a `ServerMsg.activitySnapshot`.
/// Mirrors `ClientMsg::ActivitySnapshotRequest` in `src/ipc/protocol.rs`.
public struct ClientActivitySnapshotRequest: Encodable {
    let type_: String = "activity_snapshot_request"
    public let tag: String
    /// W10: the satellite host that owns `tag`. `nil` omits the field.
    public let host: String?

    public init(tag: String, host: String? = nil) {
        self.tag = tag
        self.host = host
    }

    enum CodingKeys: String, CodingKey { case type_ = "type", tag, host }
}

// MARK: - Background tasks

/// Stop a background task. The daemon answers with
/// `ServerMsg.sessionTaskStopResult`; refused over TCP.
/// Mirrors `ClientMsg::SessionTaskStop` in `src/ipc/protocol.rs`.
public struct ClientSessionTaskStop: Encodable, Equatable {
    let type_: String = "session_task_stop"
    public let requestId: String
    public let tag: String
    public let taskId: String

    public init(requestId: String, tag: String, taskId: String) {
        self.requestId = requestId
        self.tag = tag
        self.taskId = taskId
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", tag
        case requestId = "request_id"
        case taskId = "task_id"
    }
}

/// Read the slash commands a session's CLI reports. Answered with
/// `ServerMsg.sessionCommands`; refused over TCP; sent only to a daemon that advertised
/// `slash_commands_v1`. Mirrors `ClientMsg::SessionCommandsGet` in `src/ipc/protocol.rs`.
public struct ClientSessionCommandsGet: Encodable, Equatable {
    let type_: String = "session_commands_get"
    public let requestId: String
    public let tag: String

    public init(requestId: String, tag: String) {
        self.requestId = requestId
        self.tag = tag
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", tag
        case requestId = "request_id"
    }
}

/// Read a shell or monitor task's output. `offset` is a raw byte offset into the
/// output (`nil`: the tail); the daemon clamps `maxBytes` to 1 MiB. Answered with
/// `ServerMsg.sessionTaskOutputResult`; refused over TCP.
/// Mirrors `ClientMsg::SessionTaskOutput` in `src/ipc/protocol.rs`.
public struct ClientSessionTaskOutput: Encodable, Equatable {
    let type_: String = "session_task_output"
    public let requestId: String
    public let tag: String
    public let taskId: String
    public let offset: UInt64?
    public let maxBytes: UInt32

    public init(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32) {
        self.requestId = requestId
        self.tag = tag
        self.taskId = taskId
        self.offset = offset
        self.maxBytes = maxBytes
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type", tag, offset
        case requestId = "request_id"
        case taskId = "task_id"
        case maxBytes = "max_bytes"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(tag, forKey: .tag)
        try c.encode(taskId, forKey: .taskId)
        // Absent means "the tail"; the daemon reads a missing `offset` as `None`.
        try c.encodeIfPresent(offset, forKey: .offset)
        try c.encode(maxBytes, forKey: .maxBytes)
    }
}

// MARK: - Device pairing (W9, W11)

/// Asks a token-less pairing socket whether `code` is live. With `proof` it also asks whether this
/// server already knows the device (D6). Never uses the code up. Mirrors `ClientMsg::PairCheck`.
public struct ClientPairCheck: Encodable, Equatable {
    let type_ = "pair_check"
    public let code: String
    public let proof: String?
    public init(code: String, proof: String? = nil) { self.code = code; self.proof = proof }
    enum CodingKeys: String, CodingKey { case type_ = "type", code, proof }
}

/// Redeems a code for a token. `replace` asks the server to replace the record the earlier proof
/// matched on this same socket. Mirrors `ClientMsg::Pair`.
public struct ClientPair: Encodable, Equatable {
    let type_ = "pair"
    public let code: String
    public let name: String
    public let kind: DeviceKindWire
    public let replace: Bool
    public init(code: String, name: String, kind: DeviceKindWire, replace: Bool = false) {
        self.code = code; self.name = name; self.kind = kind; self.replace = replace
    }
    enum CodingKeys: String, CodingKey { case type_ = "type", code, name, kind, replace }
}

/// An authenticated device removes its own pairing. Mirrors `ClientMsg::DeviceUnpairSelf`.
public struct ClientDeviceUnpairSelf: Encodable, Equatable {
    let type_ = "device_unpair_self"
    public init() {}
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

/// What kind of device is pairing (`DeviceKind` in `src/ipc/devices.rs`; a phone never sends
/// `satellite`).
public enum DeviceKindWire: String, Codable, Equatable {
    case iphone, ipad

    /// This device's kind. Kept in Kit so no app view reads the device idiom (the iOS policy: the
    /// presentation is chosen by width class alone).
    public static var current: DeviceKindWire {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
        #else
        return .iphone
        #endif
    }
}
