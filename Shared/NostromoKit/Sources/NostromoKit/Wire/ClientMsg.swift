// NostromoKit — ClientMsg.swift
//
// Outbound messages sent from NostromoKit clients to the daemon.
// Mirrors the Rust `ClientMsg` enum in `src/ipc/protocol.rs`.
// All types are pure value types (Encodable); no import dependencies.

import Foundation

// MARK: - Hello

/// First message sent on every new connection.
struct ClientHello: Encodable {
    let type_           = "hello"
    let clientId:        String
    let protocolVersion: Int

    enum CodingKeys: String, CodingKey {
        case type_           = "type"
        case clientId        = "client_id"
        case protocolVersion = "protocol_version"
    }
}

// MARK: - Subscribe

/// Subscribe to one or more broadcast topic streams.
struct ClientSubscribe: Encodable {
    let type_  = "subscribe"
    let topics: [String]

    enum CodingKeys: String, CodingKey {
        case type_  = "type"
        case topics
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
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

// MARK: - FocusList

/// Request the daemon's focus registry snapshot.
struct ClientFocusList: Encodable {
    let type_ = "focus_list"
    enum CodingKeys: String, CodingKey { case type_ = "type" }
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
    enum CodingKeys: String, CodingKey { case type_ = "type", tag }
}

struct ClientSessionDetach: Encodable {
    let type_ = "session_detach"
    let tag:   String
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
