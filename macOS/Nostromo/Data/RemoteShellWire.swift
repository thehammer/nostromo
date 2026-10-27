import Foundation

// Codable mirrors of the remote-shell wire (`src/ipc/protocol.rs`, "remote shells"). Nothing here
// imports AppKit or SwiftTerm: it compiles into the test target too.
//
// `TerminalTarget` (Data/TerminalWire.swift) is the `{project, environment, service, shell_type}`
// record every one of these frames shares.

// MARK: - Daemon -> client frames

/// One environment of a project and the services it has.
struct RemoteShellEnvironment: Codable, Equatable {
    let name: String
    let services: [String]
}

/// One project in `remote_shell_targets`.
struct RemoteShellProject: Codable, Equatable {
    let name: String
    let defaultService: String?
    let environments: [RemoteShellEnvironment]

    enum CodingKeys: String, CodingKey {
        case name, environments
        case defaultService = "default_service"
    }

    init(name: String, defaultService: String? = nil, environments: [RemoteShellEnvironment]) {
        self.name = name
        self.defaultService = defaultService
        self.environments = environments
    }
}

/// `remote_shell_targets`: the vocabulary the picker offers. `configured == false` carries a
/// `problem` and no lists. `repoPaths` (project name to repository directories, `~` as written) lets
/// the picker preselect the project a focus's directory belongs to.
struct RemoteShellTargets: Decodable, Equatable {
    let configured: Bool
    let problem: String?
    let projects: [RemoteShellProject]
    let shellTypes: [String]
    let repoPaths: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case configured, problem, projects
        case shellTypes = "shell_types"
        case repoPaths = "repo_paths"
    }

    init(configured: Bool, problem: String? = nil, projects: [RemoteShellProject] = [],
         shellTypes: [String] = [], repoPaths: [String: [String]] = [:]) {
        self.configured = configured
        self.problem = problem
        self.projects = projects
        self.shellTypes = shellTypes
        self.repoPaths = repoPaths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configured = try c.decode(Bool.self, forKey: .configured)
        problem = try c.decodeIfPresent(String.self, forKey: .problem)
        projects = try c.decodeIfPresent([RemoteShellProject].self, forKey: .projects) ?? []
        shellTypes = try c.decodeIfPresent([String].self, forKey: .shellTypes) ?? []
        repoPaths = try c.decodeIfPresent([String: [String]].self, forKey: .repoPaths) ?? [:]
    }
}

/// Who asked for a remote shell: `user` (the Mac's own menu) or `focus` (an agent in `tag`).
struct RemoteShellRequester: Decodable, Equatable {
    let kind: String
    let tag: String?
    let agent: String?

    init(kind: String, tag: String? = nil, agent: String? = nil) {
        self.kind = kind
        self.tag = tag
        self.agent = agent
    }
}

/// `remote_shell_confirm_request`: show the "Connect to PRODUCTION" sheet. `shellCommand`, `profile`
/// and `cluster` are what will run, pinned by the daemon for this request; the sheet shows all three.
/// They are additive: an older daemon omits them (and then the sheet refuses to offer Connect).
struct RemoteShellConfirmRequest: Decodable, Equatable {
    let requestId: String
    /// The focus the pane would open in.
    let tag: String?
    let target: TerminalTarget
    let requestedBy: RemoteShellRequester
    let reason: String?
    let expiresAt: String
    /// The remote command that will run.
    let shellCommand: String?
    /// The AWS profile; absent when none is configured.
    let profile: String?
    /// The ECS cluster.
    let cluster: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", tag, target
        case requestedBy = "requested_by", reason
        case expiresAt = "expires_at"
        case shellCommand = "shell_command", profile, cluster
    }

    init(requestId: String, tag: String? = nil, target: TerminalTarget, requestedBy: RemoteShellRequester,
         reason: String? = nil, expiresAt: String, shellCommand: String? = nil, profile: String? = nil,
         cluster: String? = nil) {
        self.requestId = requestId
        self.tag = tag
        self.target = target
        self.requestedBy = requestedBy
        self.reason = reason
        self.expiresAt = expiresAt
        self.shellCommand = shellCommand
        self.profile = profile
        self.cluster = cluster
    }
}

/// `remote_shell_resolved`: how a confirm request ended (`connected`, `cancelled`, `dismissed`,
/// `timed_out`, `connect_failed`). On `connect_failed`, `reason` is the failure's code, `remedy` what
/// to do about it and `detail` the first line the AWS CLI printed (for the person at the app only).
struct RemoteShellResolved: Decodable, Equatable {
    let requestId: String
    let outcome: String
    let reason: String?
    let remedy: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", outcome, reason, remedy, detail
    }

    init(requestId: String, outcome: String, reason: String? = nil, remedy: String? = nil,
         detail: String? = nil) {
        self.requestId = requestId
        self.outcome = outcome
        self.reason = reason
        self.remedy = remedy
        self.detail = detail
    }
}

// MARK: - Client -> daemon frames

/// The answer to a confirm request.
enum RemoteShellDecision: String, Equatable {
    case connect, cancel, dismiss
}

/// Every remote-shell frame this app sends. `invite_follow` is always `false` here: the follow box
/// is slice 3c's.
enum RemoteShellClientMessage: Equatable {
    case targetsRequest
    case open(tag: String, target: TerminalTarget)
    case answer(requestId: String, decision: RemoteShellDecision)

    var wireType: String {
        switch self {
        case .targetsRequest: return "remote_shell_targets_request"
        case .open:           return "remote_shell_open"
        case .answer:         return "remote_shell_answer"
        }
    }

    /// The frame body as a JSON object (what is encoded to the socket).
    var jsonObject: [String: Any] {
        var o: [String: Any] = ["type": wireType]
        switch self {
        case .targetsRequest:
            break
        case .open(let tag, let target):
            o["tag"] = tag
            o["project"] = target.project
            o["environment"] = target.environment
            o["service"] = target.service
            o["shell_type"] = target.shellType
        case .answer(let requestId, let decision):
            o["request_id"] = requestId
            o["decision"] = decision.rawValue
            o["invite_follow"] = false
        }
        return o
    }

    func encoded() -> Data? {
        try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }
}
