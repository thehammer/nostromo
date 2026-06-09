// NostromoKit — PrSnapshot.swift
//
// Wire types for the Perri current-PR detail snapshot.
// Mirrors `PrSnapshot` and `CiCheck` from `src/data/perri_pr.rs`.

import Foundation

// MARK: - CiCheck

/// A single CI check-run result attached to a PR snapshot.
/// Mirrors `CiCheck` from `src/data/perri_pr.rs`.
public struct CiCheck: Codable, Equatable {
    /// Check name (e.g. `"build"`, `"test"`).
    public let name: String
    /// Check state.
    public let state: CiState
    /// Truncated failure log; `nil` for passing/pending/unknown checks.
    public let detail: String?

    enum CodingKeys: String, CodingKey { case name, state, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name   = (try? c.decode(String.self,  forKey: .name))   ?? ""
        state  = (try? c.decode(CiState.self, forKey: .state))  ?? .unknown
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
    }

    public init(name: String, state: CiState, detail: String? = nil) {
        self.name   = name
        self.state  = state
        self.detail = detail
    }
}

// MARK: - PrSnapshot

/// Full current-PR detail snapshot received from the daemon.
/// Mirrors `PrSnapshot` from `src/data/perri_pr.rs`.
public struct PrSnapshot: Codable, Equatable {
    /// PR number; `nil` when no PR is currently loaded.
    public let prNumber:      Int?
    public let repo:          String
    public let title:         String
    public let author:        String
    public let url:           String
    /// Raw diff text (may be large).
    public let diff:          String
    public let stale:         Bool
    public let error:         String?
    public let ciChecks:      [CiCheck]
    public let additions:     Int
    public let deletions:     Int
    public let changedFiles:  Int
    public let headSha:       String
    /// `true` when the diff exceeded the render threshold; `diff` is empty.
    public let diffTooLarge:  Bool

    enum CodingKeys: String, CodingKey {
        case prNumber    = "pr_number"
        case repo, title, author, url, diff, stale, error
        case ciChecks    = "ci_checks"
        case additions, deletions
        case changedFiles = "changed_files"
        case headSha      = "head_sha"
        case diffTooLarge = "diff_too_large"
    }

    public init(from decoder: Decoder) throws {
        let c        = try decoder.container(keyedBy: CodingKeys.self)
        prNumber     = try? c.decodeIfPresent(Int.self,       forKey: .prNumber)
        repo         = (try? c.decode(String.self,             forKey: .repo))         ?? ""
        title        = (try? c.decode(String.self,             forKey: .title))        ?? ""
        author       = (try? c.decode(String.self,             forKey: .author))       ?? ""
        url          = (try? c.decode(String.self,             forKey: .url))          ?? ""
        diff         = (try? c.decode(String.self,             forKey: .diff))         ?? ""
        stale        = (try? c.decode(Bool.self,               forKey: .stale))        ?? false
        error        = try? c.decodeIfPresent(String.self,     forKey: .error)
        ciChecks     = (try? c.decode([CiCheck].self,          forKey: .ciChecks))     ?? []
        additions    = (try? c.decode(Int.self,                forKey: .additions))    ?? 0
        deletions    = (try? c.decode(Int.self,                forKey: .deletions))    ?? 0
        changedFiles = (try? c.decode(Int.self,                forKey: .changedFiles)) ?? 0
        headSha      = (try? c.decode(String.self,             forKey: .headSha))      ?? ""
        diffTooLarge = (try? c.decode(Bool.self,               forKey: .diffTooLarge)) ?? false
    }

    public init(
        prNumber:     Int?,
        repo:         String,
        title:        String,
        author:       String,
        url:          String,
        diff:         String,
        stale:        Bool,
        error:        String?,
        ciChecks:     [CiCheck],
        additions:    Int,
        deletions:    Int,
        changedFiles: Int,
        headSha:      String,
        diffTooLarge: Bool
    ) {
        self.prNumber     = prNumber
        self.repo         = repo
        self.title        = title
        self.author       = author
        self.url          = url
        self.diff         = diff
        self.stale        = stale
        self.error        = error
        self.ciChecks     = ciChecks
        self.additions    = additions
        self.deletions    = deletions
        self.changedFiles = changedFiles
        self.headSha      = headSha
        self.diffTooLarge = diffTooLarge
    }
}
