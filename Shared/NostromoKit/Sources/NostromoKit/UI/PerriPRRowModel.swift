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

    public init(
        id:          String,
        number:      Int,
        title:       String,
        repo:        String,
        author:      String,
        bucket:      String,
        ciState:     CiState,
        newActivity: Bool
    ) {
        self.id          = id
        self.number      = number
        self.title       = title
        self.repo        = repo
        self.author      = author
        self.bucket      = bucket
        self.ciState     = ciState
        self.newActivity = newActivity
    }
}
