// NostromoKit — ClaudeLoginWire.swift
//
// Wire types for a session that is waiting for a Claude sign-in (CL1). The daemon
// broadcasts `claude_login_state` (the whole picture each time: REPLACE semantics) and
// takes `claude_login_action`. The frame names tags and the path of `claude`; it carries
// no message text and no error text. Golden JSON: the Rust tests in `src/ipc/protocol.rs`.

import Foundation

/// `Welcome.features` entry: the daemon sends `claude_login_state` and takes `claude_login_action`.
public let claudeLoginFeature = "claude_login_v1"

/// What a session waiting for a sign-in is doing.
public enum ClaudeLoginPhase: String, Decodable, Equatable {
    /// The failed message is held and goes out again once the login changes.
    case waiting
    /// The held message was written again and its turn has not ended.
    case resending
    /// The failed turn had done real work: only a human resends the message.
    case notResendable = "not_resendable"
    /// Paused, with no message to send again.
    case pausedNoHold = "paused_no_hold"
}

/// Whether the daemon can see the Claude credential change.
public enum ClaudeLoginWatch: String, Decodable, Equatable {
    case keychain
    case unavailable
}

/// One session waiting for a sign-in.
public struct ClaudeLoginSession: Decodable, Equatable {
    public let tag: String
    /// What a `claude_login_action` names; nil when nothing is held.
    public let holdId: String?
    public let phase: ClaudeLoginPhase
    /// Messages sent since, kept in order behind the held one.
    public let queued: Int
    /// When the turn failed (RFC 3339, UTC).
    public let failedAt: String
    /// How many more times the daemon may send the message again by itself.
    public let autoResendsLeft: Int

    enum CodingKeys: String, CodingKey {
        case tag
        case holdId = "hold_id"
        case phase, queued
        case failedAt = "failed_at"
        case autoResendsLeft = "auto_resends_left"
    }
}

/// `claude_login_state`: every session waiting for a sign-in (empty when none is).
public struct ClaudeLoginStateFrame: Decodable, Equatable {
    public let needsLogin: Bool
    /// The `claude` the daemon runs: the one a sign-in must be done with.
    public let claudeBin: String?
    public let watch: ClaudeLoginWatch
    public let sessions: [ClaudeLoginSession]

    enum CodingKeys: String, CodingKey {
        case needsLogin = "needs_login"
        case claudeBin = "claude_bin"
        case watch, sessions
    }
}

// MARK: - Outbound frame (`ClientMsg`)

/// What a `claude_login_action` asks for.
public enum ClaudeLoginActionKind: String, Encodable, Equatable {
    case retry
    case discard
}

/// `claude_login_action`: send the held message again now, or drop it. The daemon applies
/// it only from the verified app, echoing the connection's operator nonce.
public struct ClientClaudeLoginAction: Encodable, Equatable {
    let type_ = "claude_login_action"
    public let action: ClaudeLoginActionKind
    public let tag: String
    public let holdId: String?
    public let operatorNonce: String?

    public init(action: ClaudeLoginActionKind, tag: String, holdId: String?, operatorNonce: String?) {
        self.action = action
        self.tag = tag
        self.holdId = holdId
        self.operatorNonce = operatorNonce
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case action, tag
        case holdId = "hold_id"
        case operatorNonce = "operator_nonce"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encode(action, forKey: .action)
        try c.encode(tag, forKey: .tag)
        try c.encodeIfPresent(holdId, forKey: .holdId)
        try c.encodeIfPresent(operatorNonce, forKey: .operatorNonce)
    }
}
