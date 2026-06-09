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
    /// Review bucket: `"requested"`, `"needs_review"`, or `"changes_req"`.
    public let bucket: String
    /// `true` when the PR has new activity since we last reviewed it.
    public let newActivity: Bool
    /// HTML URL for the PR.
    public let url: String
    /// Rolled-up CI state.
    public let ciState: CiState
    /// HEAD commit SHA — used to validate detail cache freshness.
    public let headSha: String

    // MARK: Identifiable

    /// Stable identity: `"repo#number"`.
    public var id: String { "\(repo)#\(number)" }

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case repo, number, title, author, bucket, url
        case newActivity = "new_activity"
        case ciState     = "ci_state"
        case headSha     = "head_sha"
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
        headSha: String
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
    }
}
