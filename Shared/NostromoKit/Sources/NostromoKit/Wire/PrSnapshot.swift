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

// MARK: - PrThreadKind / PrComment / PrThread (W3 — curated-agent-views)

/// What kind of GitHub thread a `PrThread` came from. Mirrors `PrThreadKind`
/// from `src/data/perri_pr.rs`. Raw-markdown counterpart of
/// `ConversationThreadKind` (`PaneLayout.swift`) — this type travels on
/// `PrSnapshot`, whose bodies stay unparsed markdown (see that type's doc).
public enum PrThreadKind: String, Codable, Equatable {
    case issue, review, inline
}

/// One raw (still-markdown) comment within a `PrThread`.
/// Mirrors `PrComment` from `src/data/perri_pr.rs`.
public struct PrComment: Codable, Equatable {
    public let id: String
    public let author: String
    public let createdAt: Date
    public let body: String

    enum CodingKeys: String, CodingKey {
        case id, author, body
        case createdAt = "created_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = (try? c.decode(String.self, forKey: .id)) ?? ""
        author    = (try? c.decode(String.self, forKey: .author)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        body      = (try? c.decode(String.self, forKey: .body)) ?? ""
    }

    public init(id: String, author: String, createdAt: Date, body: String) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.body = body
    }
}

/// One comment thread on a PR. Mirrors `PrThread` from `src/data/perri_pr.rs`.
public struct PrThread: Codable, Equatable {
    public let id: String
    public let kind: PrThreadKind
    public let path: String?
    public let line: Int?
    public let diffHunk: String?
    public let resolved: Bool
    public let comments: [PrComment]

    enum CodingKeys: String, CodingKey {
        case id, kind, path, line, resolved, comments
        case diffHunk = "diff_hunk"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = (try? c.decode(String.self, forKey: .id)) ?? ""
        kind     = (try? c.decode(PrThreadKind.self, forKey: .kind)) ?? .issue
        path     = try? c.decodeIfPresent(String.self, forKey: .path)
        line     = try? c.decodeIfPresent(Int.self, forKey: .line)
        diffHunk = try? c.decodeIfPresent(String.self, forKey: .diffHunk)
        resolved = (try? c.decode(Bool.self, forKey: .resolved)) ?? false
        comments = (try? c.decode([PrComment].self, forKey: .comments)) ?? []
    }

    public init(
        id: String,
        kind: PrThreadKind,
        path: String?,
        line: Int?,
        diffHunk: String?,
        resolved: Bool,
        comments: [PrComment]
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.line = line
        self.diffHunk = diffHunk
        self.resolved = resolved
        self.comments = comments
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
    /// The PR description, raw markdown (W3 — curated-agent-views).
    public let body:          String
    /// Comment/review threads (W3 — curated-agent-views).
    public let threads:       [PrThread]
    /// Set when the PR fetch itself succeeded but fetching the conversation
    /// failed. `threads` then carries whatever was retrieved before the
    /// failure (W3 — curated-agent-views).
    public let conversationError: String?

    enum CodingKeys: String, CodingKey {
        case prNumber    = "pr_number"
        case repo, title, author, url, diff, stale, error
        case ciChecks    = "ci_checks"
        case additions, deletions
        case changedFiles = "changed_files"
        case headSha      = "head_sha"
        case diffTooLarge = "diff_too_large"
        case body, threads
        case conversationError = "conversation_error"
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
        body         = (try? c.decode(String.self,             forKey: .body))         ?? ""
        threads      = (try? c.decode([PrThread].self,         forKey: .threads))      ?? []
        conversationError = try? c.decodeIfPresent(String.self, forKey: .conversationError)
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
        diffTooLarge: Bool,
        body:         String = "",
        threads:      [PrThread] = [],
        conversationError: String? = nil
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
        self.body         = body
        self.threads      = threads
        self.conversationError = conversationError
    }
}
