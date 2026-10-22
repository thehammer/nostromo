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
    /// The question text set when a Mother worker calls `mother await`.
    /// Non-nil only when `state == "awaiting"`.
    public let question:   String?
    /// The job's `origin.label` (`mother add --label`), when it has one. The only part of
    /// `origin` that is read.
    public let originLabel: String?
    /// Headless-crew data (gates, review wave, decision, attention, progress),
    /// read leniently key by key. Empty for a job with none.
    public let crew:       MotherCrewState

    enum CodingKeys: String, CodingKey {
        case id, state, title, repo, branch, question, origin
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
        finishedAt: String? = nil,
        question: String? = nil,
        originLabel: String? = nil,
        crew: MotherCrewState = MotherCrewState()
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
        self.question   = question
        self.originLabel = originLabel
        self.crew       = crew
    }

    private struct Origin: Codable {
        let label: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id         = try c.decode(String.self, forKey: .id)
        state      = try c.decode(String.self, forKey: .state)
        title      = try c.decode(String.self, forKey: .title)
        repo       = try c.decodeIfPresent(String.self, forKey: .repo)
        branch     = try c.decodeIfPresent(String.self, forKey: .branch)
        // A crew-contract key: a malformed value never costs the job.
        prUrl      = (try? c.decodeIfPresent(String.self, forKey: .prUrl)) ?? nil
        createdAt  = try c.decodeIfPresent(String.self, forKey: .createdAt)
        startedAt  = try c.decodeIfPresent(String.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(String.self, forKey: .finishedAt)
        question   = try c.decodeIfPresent(String.self, forKey: .question)
        originLabel = (try? c.decodeIfPresent(Origin.self, forKey: .origin))?.label
        crew       = (try? MotherCrewState(jobDecoder: decoder)) ?? MotherCrewState()
    }

    /// Writes the crew keys flat, next to the job's own, in the daemon's form.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(state, forKey: .state)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(repo, forKey: .repo)
        try c.encodeIfPresent(branch, forKey: .branch)
        try c.encodeIfPresent(prUrl, forKey: .prUrl)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encodeIfPresent(question, forKey: .question)
        if let originLabel { try c.encode(Origin(label: originLabel), forKey: .origin) }
        try crew.encode(to: encoder)
    }
}
