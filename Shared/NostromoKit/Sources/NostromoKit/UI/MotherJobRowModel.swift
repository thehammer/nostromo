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
    /// Mother's progress indicator, e.g. "≈55% · gates 1/3 · ETA ~5-15 min"
    /// (see `MotherProgressLine`). Nil when the job has none.
    public let progressLine: String?
    /// The spoken form of `progressLine` (VoiceOver); falls back to the line itself.
    public let progressAccessibility: String?
    /// The surface draws the progress line (the Mac does; iOS does not yet). Only then do running
    /// and awaiting rows reserve it.
    public let showsProgressLine: Bool
    /// Short attention labels, e.g. "Needs decision" (see `MotherAttentionBadges`).
    public let attentionBadges: [String]

    public init(
        id: String,
        state: String,
        title: String,
        repo: String? = nil,
        branch: String? = nil,
        question: String? = nil,
        relativeTimestamp: String? = nil,
        progressLine: String? = nil,
        attentionBadges: [String] = [],
        progressAccessibility: String? = nil,
        showsProgressLine: Bool = false
    ) {
        self.id               = id
        self.state            = state
        self.title            = title
        self.repo             = repo
        self.branch           = branch
        self.question         = question
        self.relativeTimestamp = relativeTimestamp
        self.progressLine     = progressLine
        self.attentionBadges  = attentionBadges
        self.progressAccessibility = progressAccessibility
        self.showsProgressLine = showsProgressLine
    }

    /// Running and awaiting rows reserve a second line for progress and attention, so a
    /// job gaining progress does not change its row's height.
    public var reservesProgressLine: Bool {
        showsProgressLine && (state == "running" || state == "awaiting")
    }

    /// Terminal states → the row's swipe action is "Archive".
    /// Active states → the row's swipe action is "Cancel".
    public var isDone: Bool {
        state == "succeeded" || state == "failed" || state == "cancelled"
    }
}
