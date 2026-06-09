// NostromoKit — TeriTodo.swift
//
// Wire types for Teri todos received from the daemon via a `teri_state` broadcast.
// Mirrors `TeriTodo` / `TeriTodosSnapshot` in `src/data/teri_todos.rs`.

import Foundation

/// A single Teri todo, decoded from a `teri_state` ServerMsg.
///
/// Fields are a minimal projection of the daemon's SQLite row.
/// Unknown extra fields are silently ignored by the standard `Codable` machinery.
public struct TeriTodo: Codable, Identifiable, Equatable {
    public let id:       Int
    public let title:    String
    public let status:   String          // "open" | "in_progress" | "blocked"
    public let priority: Int             // 1...5
    public let dueDate:  String?         // ISO date string (yyyy-MM-dd)
    public let jiraKey:  String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority
        case dueDate  = "due_date"
        case jiraKey  = "jira_key"
    }

    public init(
        id: Int,
        title: String,
        status: String,
        priority: Int,
        dueDate: String? = nil,
        jiraKey: String? = nil
    ) {
        self.id       = id
        self.title    = title
        self.status   = status
        self.priority = priority
        self.dueDate  = dueDate
        self.jiraKey  = jiraKey
    }
}

/// Snapshot of all active Teri todos, broadcast by the daemon.
public struct TeriTodosSnapshot: Codable, Equatable {
    /// ISO-8601 timestamp from the daemon; kept as `String` to avoid date-strategy coupling.
    public let generatedAt: String?
    public let items:       [TeriTodo]
    public let stale:       Bool
    public let error:       String?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case items, stale, error
    }

    public init(
        generatedAt: String? = nil,
        items: [TeriTodo],
        stale: Bool = false,
        error: String? = nil
    ) {
        self.generatedAt = generatedAt
        self.items       = items
        self.stale       = stale
        self.error       = error
    }
}
