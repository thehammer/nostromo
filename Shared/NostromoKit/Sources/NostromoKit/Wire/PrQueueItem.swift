// NostromoKit — PrQueueItem.swift
//
// Wire types for the Perri PR review queue.
// Mirrors `PrQueueItem`, `PrQueueSnapshot`, and `CiState` from
// `src/data/perri_queue.rs` in the Rust daemon.

import Foundation

// MARK: - CiState

/// Four-way CI state. Mirrors `CiState` in Rust (`#[serde(rename_all = "lowercase")]`).
/// Unknown strings fall back to `.unknown` to survive future daemon variants.
public enum CiState: String, Codable, Equatable {
    case unknown
    case pending
    case success
    case failure

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CiState(rawValue: raw) ?? .unknown
    }
}

// MARK: - PrQueueItem

/// One entry in the Perri PR review queue.
/// Mirrors `PrQueueItem` from `src/data/perri_queue.rs`.
public struct PrQueueItem: Codable, Identifiable, Equatable {

    // MARK: Stored properties

    /// Repository in `owner/name` form.
    public let repo: String
    /// PR number.
    public let number: Int
    /// PR title.
    public let title: String
    /// PR author login.
    public let author: String
    /// Review bucket: `"requested"`, `"needs_review"`, `"changes_req"`, or `"dependabot"`.
    public let bucket: String
    /// `true` when the PR has new activity since we last reviewed it.
    public let newActivity: Bool
    /// HTML URL for the PR.
    public let url: String
    /// Rolled-up CI state.
    public let ciState: CiState
    /// HEAD commit SHA — used to validate detail cache freshness.
    public let headSha: String
    /// `true` when this PR was authored by a known bot (dependabot, carefeed-ci).
    /// The daemon is the single source of truth — do not infer from `author`.
    public let isBot: Bool

    // MARK: Identifiable

    /// Stable identity: `"repo#number"`.
    public var id: String { "\(repo)#\(number)" }

    /// SwiftUI row identity only — never a domain identity. Do not use this
    /// anywhere `id` is expected (persistence, addressing, cross-referencing
    /// against `PrListItemModel.id`, etc.) — those must keep using `id` above.
    ///
    /// Folds `bucket` into `id` so that a PR moving between review-queue
    /// buckets (e.g. `requested` -> `needs_review`, see
    /// `src/data/perri_queue.rs` bucket precedence) changes this row's
    /// SwiftUI identity, not just which section it's filtered into. Without
    /// this, `ForEach(items) { … }` keyed on the bare `id` sees a bucket
    /// change as a *move* rather than a content change, and can recycle the
    /// existing row view under the new section header — rendering the PR's
    /// previous bucket's badge.
    public var bucketScopedId: String { "\(id)#\(bucket)" }

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case repo, number, title, author, bucket, url
        case newActivity = "new_activity"
        case ciState     = "ci_state"
        case headSha     = "head_sha"
        case isBot       = "is_bot"
    }

    // MARK: Init

    public init(
        repo: String,
        number: Int,
        title: String,
        author: String,
        bucket: String,
        newActivity: Bool,
        url: String,
        ciState: CiState,
        headSha: String,
        isBot: Bool = false
    ) {
        self.repo        = repo
        self.number      = number
        self.title       = title
        self.author      = author
        self.bucket      = bucket
        self.newActivity = newActivity
        self.url         = url
        self.ciState     = ciState
        self.headSha     = headSha
        self.isBot       = isBot
    }

    // MARK: Decode with defaults

    public init(from decoder: Decoder) throws {
        let c      = try decoder.container(keyedBy: CodingKeys.self)
        repo        = try c.decode(String.self, forKey: .repo)
        number      = try c.decode(Int.self,    forKey: .number)
        title       = try c.decode(String.self, forKey: .title)
        author      = try c.decode(String.self, forKey: .author)
        bucket      = (try? c.decode(String.self, forKey: .bucket)) ?? "needs_review"
        newActivity = (try? c.decode(Bool.self,   forKey: .newActivity)) ?? false
        url         = try c.decode(String.self, forKey: .url)
        ciState     = (try? c.decode(CiState.self, forKey: .ciState)) ?? .unknown
        headSha     = (try? c.decode(String.self, forKey: .headSha)) ?? ""
        isBot       = (try? c.decode(Bool.self,   forKey: .isBot))   ?? false
    }
}
