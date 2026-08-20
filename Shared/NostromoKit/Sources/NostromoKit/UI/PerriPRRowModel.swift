// NostromoKit — PerriPRRowModel.swift
//
// Platform-neutral display model for a Perri PR queue row.
// Analogous to MotherJobRowModel — callers map a PrQueueItem into this
// struct before passing it to PerriPRRow.

import Foundation

/// Display-only value type for a single Perri PR queue row.
///
/// Callers map their `PrQueueItem` into this model — the shared view never
/// touches the underlying wire type directly.
public struct PerriPRRowModel: Identifiable, Equatable {
    public let id:          String
    public let number:      Int
    public let title:       String
    public let repo:        String
    public let author:      String
    /// Raw bucket string: `"requested"`, `"needs_review"`, `"changes_req"`.
    public let bucket:      String
    public let ciState:     CiState
    /// `true` when the PR has new activity since last review.
    public let newActivity: Bool
    /// `true` when an agent has pointed at this row — the rendered form of an
    /// `Anchor.queueRow` / `Emphasis.queueRow` on the pane's `PaneAddress`
    /// (W5 — curated-agent-views).
    ///
    /// **Visual only.** It is not selection: it does not change the daemon's
    /// selected index, does not change current-PR state, and does not change
    /// what a subsequent operator action acts on. Marking a row and then
    /// triggering the queue's approve affordance must not approve the marked
    /// PR. A show is the agent pointing, not the agent choosing.
    ///
    /// Defaulted, so every existing caller keeps compiling and keeps rendering
    /// exactly what it rendered before.
    public let marked: Bool

    public init(
        id:          String,
        number:      Int,
        title:       String,
        repo:        String,
        author:      String,
        bucket:      String,
        ciState:     CiState,
        newActivity: Bool,
        marked:      Bool = false
    ) {
        self.id          = id
        self.number      = number
        self.title       = title
        self.repo        = repo
        self.author      = author
        self.bucket      = bucket
        self.ciState     = ciState
        self.newActivity = newActivity
        self.marked      = marked
    }
}
