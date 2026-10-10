import Foundation

// Wire models for the Teri/Fred work views. Mirrors `src/data/work/model.rs`
// and the frames in `src/ipc/protocol.rs` (design contract §3/§4). Field names
// are snake_case on the wire; every optional field tolerates absence so an
// additive daemon change never breaks an older app. Dates are decoded by
// `NostromodClient`'s decoder (RFC 3339, with or without fractional seconds).

// MARK: - Source + state

/// Where a work item comes from.
enum WorkSource: String, Codable, CaseIterable, Hashable {
    case todos
    case repoDocs = "repo_docs"
    case jira
    case sentry
}

/// Health of one source. Unknown future states decode as `.error` so a newer
/// daemon never blanks the whole frame.
enum SourceState: String, Codable, Hashable {
    case loading
    case fresh
    case stale
    case notConfigured   = "not_configured"
    case unauthenticated
    case rateLimited     = "rate_limited"
    case empty
    case error

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SourceState(rawValue: raw) ?? .error
    }
}

struct GroupError: Codable, Hashable {
    let group: String
    let reason: String
}

struct SourceStatus: Decodable, Hashable {
    let source: WorkSource
    let state: SourceState
    let updatedAt: Date?
    let reason: String?
    let retryAt: Date?
    let count: Int
    let groupErrors: [GroupError]

    enum CodingKeys: String, CodingKey {
        case source, state, reason, count
        case updatedAt   = "updated_at"
        case retryAt     = "retry_at"
        case groupErrors = "group_errors"
    }

    init(source: WorkSource, state: SourceState, updatedAt: Date? = nil, reason: String? = nil,
         retryAt: Date? = nil, count: Int = 0, groupErrors: [GroupError] = []) {
        self.source = source; self.state = state; self.updatedAt = updatedAt
        self.reason = reason; self.retryAt = retryAt; self.count = count
        self.groupErrors = groupErrors
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source      = try c.decode(WorkSource.self, forKey: .source)
        state       = try c.decode(SourceState.self, forKey: .state)
        updatedAt   = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        reason      = try c.decodeIfPresent(String.self, forKey: .reason)
        retryAt     = try c.decodeIfPresent(Date.self, forKey: .retryAt)
        count       = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        groupErrors = try c.decodeIfPresent([GroupError].self, forKey: .groupErrors) ?? []
    }
}

// MARK: - Items

struct WorkPriority: Decodable, Hashable {
    let label: String
    /// 1 = most urgent.
    let rank: Int
}

/// Records that an item was sent to an agent focus or a Mother job.
struct SentMarker: Decodable, Hashable {
    /// `"focus"` or `"mother_job"`.
    let kind: String
    let targetId: String
    let label: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case kind, label
        case targetId  = "target_id"
        case createdAt = "created_at"
    }
}

struct WorkItem: Decodable, Hashable, Identifiable {
    /// `todo:<id>` | `doc:<repo>:<path>` | `jira:<KEY>` | `sentry:<issue id>`.
    let id: String
    let source: WorkSource
    let kind: String
    let title: String
    let repo: String?
    let project: String?
    let status: String?
    /// Jira: `in_progress` | `to_do` | `other`.
    let statusCategory: String?
    let priority: WorkPriority?
    let severity: String?
    let environment: String?
    let createdAt: Date?
    let updatedAt: Date?
    /// Calendar date, `yyyy-MM-dd`, exactly as sent.
    let due: String?
    let url: String?
    let path: String?
    let metrics: [String: Int]
    let linked: [String]
    let searchText: String
    let sent: [SentMarker]

    enum CodingKeys: String, CodingKey {
        case id, source, kind, title, repo, project, status, priority, severity, environment
        case due, url, path, metrics, linked, sent
        case statusCategory = "status_category"
        case createdAt      = "created_at"
        case updatedAt      = "updated_at"
        case searchText     = "search_text"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(String.self, forKey: .id)
        source         = try c.decode(WorkSource.self, forKey: .source)
        kind           = try c.decode(String.self, forKey: .kind)
        title          = try c.decode(String.self, forKey: .title)
        repo           = try c.decodeIfPresent(String.self, forKey: .repo)
        project        = try c.decodeIfPresent(String.self, forKey: .project)
        status         = try c.decodeIfPresent(String.self, forKey: .status)
        statusCategory = try c.decodeIfPresent(String.self, forKey: .statusCategory)
        priority       = try c.decodeIfPresent(WorkPriority.self, forKey: .priority)
        severity       = try c.decodeIfPresent(String.self, forKey: .severity)
        environment    = try c.decodeIfPresent(String.self, forKey: .environment)
        createdAt      = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt      = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        due            = try c.decodeIfPresent(String.self, forKey: .due)
        url            = try c.decodeIfPresent(String.self, forKey: .url)
        path           = try c.decodeIfPresent(String.self, forKey: .path)
        metrics        = try c.decodeIfPresent([String: Int].self, forKey: .metrics) ?? [:]
        linked         = try c.decodeIfPresent([String].self, forKey: .linked) ?? []
        searchText     = try c.decodeIfPresent(String.self, forKey: .searchText) ?? ""
        sent           = try c.decodeIfPresent([SentMarker].self, forKey: .sent) ?? []
    }
}

// MARK: - Detail

struct WorkLink: Decodable, Hashable {
    let label: String
    let url: String
}

/// One ordered label/value row. Sent as a two-element JSON array.
struct WorkDetailField: Decodable, Hashable {
    let label: String
    let value: String

    init(label: String, value: String) { self.label = label; self.value = value }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        label = try c.decode(String.self)
        value = try c.decode(String.self)
    }
}

/// Detail for one work item, or a Fred mail / event.
struct WorkItemDetail: Decodable, Hashable {
    let itemId: String
    let title: String
    let fields: [WorkDetailField]
    let markdown: String
    let files: [String]
    let links: [WorkLink]

    enum CodingKeys: String, CodingKey {
        case title, fields, markdown, files, links
        case itemId = "item_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId   = try c.decode(String.self, forKey: .itemId)
        title    = try c.decode(String.self, forKey: .title)
        fields   = try c.decodeIfPresent([WorkDetailField].self, forKey: .fields) ?? []
        markdown = try c.decodeIfPresent(String.self, forKey: .markdown) ?? ""
        files    = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        links    = try c.decodeIfPresent([WorkLink].self, forKey: .links) ?? []
    }
}

// MARK: - Picks

struct Pick: Decodable, Hashable {
    let itemId: String
    let source: WorkSource
    let title: String
    let reason: String
    let doneSince: Bool

    enum CodingKeys: String, CodingKey {
        case source, title, reason
        case itemId    = "item_id"
        case doneSince = "done_since"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId    = try c.decode(String.self, forKey: .itemId)
        source    = try c.decode(WorkSource.self, forKey: .source)
        title     = try c.decode(String.self, forKey: .title)
        reason    = try c.decode(String.self, forKey: .reason)
        doneSince = try c.decodeIfPresent(Bool.self, forKey: .doneSince) ?? false
    }
}

struct PicksSnapshot: Decodable, Hashable {
    let generatedAt: Date?
    let generating: Bool
    let unavailableSources: [WorkSource]
    let items: [Pick]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case generating, items, error
        case generatedAt        = "generated_at"
        case unavailableSources = "unavailable_sources"
    }

    init(generatedAt: Date? = nil, generating: Bool = false, unavailableSources: [WorkSource] = [],
         items: [Pick] = [], error: String? = nil) {
        self.generatedAt = generatedAt; self.generating = generating
        self.unavailableSources = unavailableSources; self.items = items; self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt        = try c.decodeIfPresent(Date.self, forKey: .generatedAt)
        generating         = try c.decodeIfPresent(Bool.self, forKey: .generating) ?? false
        unavailableSources = try c.decodeIfPresent([WorkSource].self, forKey: .unavailableSources) ?? []
        items              = try c.decodeIfPresent([Pick].self, forKey: .items) ?? []
        error              = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

// MARK: - Send to agent

/// Defaults shown in the "send to agent" sheet.
struct SendPreview: Decodable, Hashable {
    let itemId: String
    let agent: String
    let workingDirectory: String?
    let label: String
    let context: String
    let existing: [SentMarker]

    enum CodingKeys: String, CodingKey {
        case agent, label, context, existing
        case itemId           = "item_id"
        case workingDirectory = "working_directory"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId           = try c.decode(String.self, forKey: .itemId)
        agent            = try c.decode(String.self, forKey: .agent)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        label            = try c.decode(String.self, forKey: .label)
        context          = try c.decode(String.self, forKey: .context)
        existing         = try c.decodeIfPresent([SentMarker].self, forKey: .existing) ?? []
    }
}

/// Result of a send (or a Fred seed).
struct SendOutcome: Decodable, Hashable {
    /// `"created"` | `"existing"` | `"mother_job"` | `"seeded"`.
    let kind: String
    let focusTag: String?
    let jobId: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case focusTag = "focus_tag"
        case jobId    = "job_id"
    }
}

// MARK: - Targeted results

/// Machine-readable error plus a human-readable message.
struct WorkError: Decodable, Hashable, Error {
    let code: String
    let message: String

    static let timedOut = WorkError(code: "timed_out", message: "The daemon did not answer in time")
}

/// Outcome of a targeted request: `{"status":"ok","value":…}` or
/// `{"status":"err","value":{code,message}}`.
enum WorkResult<T: Decodable>: Decodable {
    case ok(T)
    case err(WorkError)

    enum CodingKeys: String, CodingKey { case status, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .status) {
        case "ok":
            self = .ok(try c.decode(T.self, forKey: .value))
        default:
            self = .err(try c.decode(WorkError.self, forKey: .value))
        }
    }
}

extension WorkResult: Equatable where T: Equatable {}

// MARK: - Client → daemon frames

/// Parameters of a `work_send` frame.
struct WorkSendRequest: Equatable {
    let requestId: String
    let itemId: String
    /// `"focus"` or `"mother_job"`.
    let destination: String
    let agent: String
    let workingDirectory: String?
    let label: String
    let context: String
    let allowDuplicate: Bool
}

/// Every client → daemon frame added for the work views. Encodes to the wire
/// shape in `src/ipc/protocol.rs`; refused with `requires_secure_connection`
/// over TCP, so only the Unix-socket client sends these.
enum WorkClientMessage: Encodable, Equatable {
    case detailRequest(requestId: String, itemId: String)
    case refresh(source: WorkSource?, fred: Bool)
    case picksRefresh(reason: String)
    case sendPreviewRequest(requestId: String, itemId: String)
    case send(WorkSendRequest)
    case fredSeed(requestId: String, text: String)

    /// The wire `type` discriminator.
    var wireType: String {
        switch self {
        case .detailRequest:      return "work_detail_request"
        case .refresh:            return "work_refresh"
        case .picksRefresh:       return "picks_refresh"
        case .sendPreviewRequest: return "work_send_preview_request"
        case .send:               return "work_send"
        case .fredSeed:           return "fred_seed"
        }
    }

    private enum K: String, CodingKey {
        case type, source, fred, reason, text, destination, agent, label, context
        case requestId        = "request_id"
        case itemId           = "item_id"
        case workingDirectory = "working_directory"
        case allowDuplicate   = "allow_duplicate"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(wireType, forKey: .type)
        switch self {
        case .detailRequest(let requestId, let itemId),
             .sendPreviewRequest(let requestId, let itemId):
            try c.encode(requestId, forKey: .requestId)
            try c.encode(itemId, forKey: .itemId)
        case .refresh(let source, let fred):
            try c.encodeIfPresent(source, forKey: .source)
            try c.encode(fred, forKey: .fred)
        case .picksRefresh(let reason):
            try c.encode(reason, forKey: .reason)
        case .send(let r):
            try c.encode(r.requestId, forKey: .requestId)
            try c.encode(r.itemId, forKey: .itemId)
            try c.encode(r.destination, forKey: .destination)
            try c.encode(r.agent, forKey: .agent)
            try c.encodeIfPresent(r.workingDirectory, forKey: .workingDirectory)
            try c.encode(r.label, forKey: .label)
            try c.encode(r.context, forKey: .context)
            try c.encode(r.allowDuplicate, forKey: .allowDuplicate)
        case .fredSeed(let requestId, let text):
            try c.encode(requestId, forKey: .requestId)
            try c.encode(text, forKey: .text)
        }
    }
}
