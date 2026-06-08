// NostromoKit — MotherJobRowModel.swift
//
// Platform-neutral display model for a Mother job list row.
// Both iOS (NostromoKit.MotherJob) and macOS (local MotherJob) map
// their native types into this struct before passing it to MotherJobRow.

import Foundation

/// Display-only value type for a single Mother job list row.
///
/// Callers map their platform's `MotherJob` type into this model —
/// the shared view never touches the underlying wire or AppKit types.
public struct MotherJobRowModel: Identifiable, Equatable {
    public let id: String
    public let state: String
    public let title: String
    public let repo: String?
    public let branch: String?
    public let question: String?
    /// Pre-formatted relative timestamp string (e.g. "5m ago", "2h30m").
    /// Formatted by the caller from whatever date representation it has.
    public let relativeTimestamp: String?

    public init(
        id: String,
        state: String,
        title: String,
        repo: String? = nil,
        branch: String? = nil,
        question: String? = nil,
        relativeTimestamp: String? = nil
    ) {
        self.id               = id
        self.state            = state
        self.title            = title
        self.repo             = repo
        self.branch           = branch
        self.question         = question
        self.relativeTimestamp = relativeTimestamp
    }

    /// Terminal states → the row's swipe action is "Archive".
    /// Active states → the row's swipe action is "Cancel".
    public var isDone: Bool {
        state == "succeeded" || state == "failed" || state == "cancelled"
    }
}
