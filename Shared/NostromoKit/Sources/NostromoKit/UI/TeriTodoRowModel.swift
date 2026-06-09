// NostromoKit — TeriTodoRowModel.swift
//
// Platform-neutral display model for a single Teri todo list row.
// Both iOS (NostromoKit.TeriTodo) and macOS (local TeriTodo) map their
// native types into this struct before passing it to TeriTodoRow.

import Foundation

/// Display-only value type for a single Teri todo row.
///
/// Callers map their platform's `TeriTodo` type into this model —
/// the shared view never touches the underlying wire or AppKit types.
public struct TeriTodoRowModel: Identifiable, Equatable {
    public let id:          Int
    public let title:       String
    public let priority:    Int       // 1...5
    public let jiraKey:     String?
    /// Pre-formatted relative date string (e.g. "in 3 days", "2 weeks ago").
    /// Formatted by the caller from the raw `due_date` string.
    public let relativeDue: String?
    /// Raw due-date string as a fallback when parsing fails.
    public let rawDueDate:  String?

    public init(
        id:          Int,
        title:       String,
        priority:    Int,
        jiraKey:     String? = nil,
        relativeDue: String? = nil,
        rawDueDate:  String? = nil
    ) {
        self.id          = id
        self.title       = title
        self.priority    = priority
        self.jiraKey     = jiraKey
        self.relativeDue = relativeDue
        self.rawDueDate  = rawDueDate
    }
}
