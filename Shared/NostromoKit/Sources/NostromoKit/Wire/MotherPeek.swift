// NostromoKit — MotherPeek.swift
//
// Wire types for the `mother_peek` ServerMsg broadcast by nostromd.
// Mirrors the Rust `PeekTodo`, `PeekToolCall` (src/mother/mod.rs) and the
// `ServerMsg::MotherPeek` fields (src/ipc/protocol.rs).

import Foundation

/// One item from the active Cody session's TodoWrite list.
public struct PeekTodo: Codable, Equatable {
    /// One of "pending", "in_progress", or "completed".
    public let status: String
    public let content: String

    public init(status: String, content: String) {
        self.status  = status
        self.content = content
    }
}

/// One entry from the last-3 tool call trail.
public struct PeekToolCall: Codable, Equatable {
    public let tool: String
    public let brief: String

    public init(tool: String, brief: String) {
        self.tool  = tool
        self.brief = brief
    }
}

/// Full live snapshot for one active Mother job.
/// Decoded from a `mother_peek` ServerMsg frame.
public struct MotherPeekSnapshot: Codable, Equatable {
    public let jobId:     String
    public let todos:     [PeekTodo]
    public let toolTrail: [PeekToolCall]
    public let lastText:  String

    enum CodingKeys: String, CodingKey {
        case jobId     = "job_id"
        case todos
        case toolTrail = "tool_trail"
        case lastText  = "last_text"
    }

    public init(jobId: String, todos: [PeekTodo],
                toolTrail: [PeekToolCall], lastText: String) {
        self.jobId     = jobId
        self.todos     = todos
        self.toolTrail = toolTrail
        self.lastText  = lastText
    }
}
