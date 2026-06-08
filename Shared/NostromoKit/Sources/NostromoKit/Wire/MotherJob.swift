// NostromoKit — MotherJob.swift
//
// Wire type for a Mother job record received from the daemon.
// Mirrors the Rust `MotherJob` struct in `src/mother/mod.rs`.

import Foundation

/// A Mother job record, decoded from a `mother_jobs` ServerMsg.
///
/// Fields are a minimal projection of what the daemon broadcasts —
/// optional fields are `nil` when absent in the JSON.  Unknown extra
/// fields are silently ignored by the standard `Codable` machinery.
public struct MotherJob: Codable, Identifiable, Equatable {
    public let id:         String
    public let state:      String
    public let title:      String
    public let repo:       String?
    public let branch:     String?
    public let prUrl:      String?
    public let createdAt:  String?
    public let startedAt:  String?
    public let finishedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, state, title, repo, branch
        case prUrl      = "pr_url"
        case createdAt  = "created_at"
        case startedAt  = "started_at"
        case finishedAt = "finished_at"
    }

    public init(
        id: String,
        state: String,
        title: String,
        repo: String? = nil,
        branch: String? = nil,
        prUrl: String? = nil,
        createdAt: String? = nil,
        startedAt: String? = nil,
        finishedAt: String? = nil
    ) {
        self.id         = id
        self.state      = state
        self.title      = title
        self.repo       = repo
        self.branch     = branch
        self.prUrl      = prUrl
        self.createdAt  = createdAt
        self.startedAt  = startedAt
        self.finishedAt = finishedAt
    }
}
