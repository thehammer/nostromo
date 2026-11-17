import Foundation

// The hand-off verbs of the PR Overview (feature `authored_prs_notify_v1`): preview the message, send it to a
// focus, start a session with it, link a PR to a focus. The daemon composes the message; the app only shows it
// and echoes its digest. Answers carry a code, never prose: the app words each code.

/// The feature flag in `Welcome.features`.
public let authoredPrsNotifyFeature = "authored_prs_notify_v1"

/// Who a preview is for: an open focus, or a session that does not exist yet.
public enum AuthoredPrPreviewTarget: Equatable, Sendable {
    case focus(tag: String)
    case newSession
}

// MARK: Requests

public struct ClientAuthoredPrPreviewRequest: Encodable, Equatable {
    let type_ = "authored_pr_preview_request"
    public let requestId: String
    public let repo: String
    public let number: Int
    public let target: AuthoredPrPreviewTarget
    public init(requestId: String, repo: String, number: Int, target: AuthoredPrPreviewTarget) {
        self.requestId = requestId; self.repo = repo; self.number = number; self.target = target
    }
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id", repo, number, target }
    enum TargetKeys: String, CodingKey { case tag, newSession = "new_session" }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(repo, forKey: .repo)
        try c.encode(number, forKey: .number)
        var t = c.nestedContainer(keyedBy: TargetKeys.self, forKey: .target)
        switch target {
        case .focus(let tag): try t.encode(tag, forKey: .tag)
        case .newSession: try t.encode(true, forKey: .newSession)
        }
    }
}

public struct ClientAuthoredPrNotify: Encodable, Equatable {
    let type_ = "authored_pr_notify"
    public let requestId: String
    public let repo: String
    public let number: Int
    public let tag: String
    public let digest: String
    public init(requestId: String, repo: String, number: Int, tag: String, digest: String) {
        self.requestId = requestId; self.repo = repo; self.number = number; self.tag = tag; self.digest = digest
    }
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id", repo, number, tag, digest }
}

public struct ClientAuthoredPrStartSession: Encodable, Equatable {
    let type_ = "authored_pr_start_session"
    public let requestId: String
    public let repo: String
    public let number: Int
    public let folder: String
    public let agent: String
    public let digest: String
    public init(requestId: String, repo: String, number: Int, folder: String, agent: String, digest: String) {
        self.requestId = requestId; self.repo = repo; self.number = number
        self.folder = folder; self.agent = agent; self.digest = digest
    }
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id", repo, number, folder, agent, digest }
}

/// Link the PR to `tag`, or unlink it (`tag` nil).
public struct ClientAuthoredPrLink: Encodable, Equatable {
    let type_ = "authored_pr_link"
    public let requestId: String
    public let repo: String
    public let number: Int
    public let tag: String?
    public init(requestId: String, repo: String, number: Int, tag: String?) {
        self.requestId = requestId; self.repo = repo; self.number = number; self.tag = tag
    }
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id", repo, number, tag }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type_, forKey: .type_)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(repo, forKey: .repo)
        try c.encode(number, forKey: .number)
        try c.encodeIfPresent(tag, forKey: .tag)
    }
}

// MARK: Answers

/// What a verb answered: a value, or a code.
public enum AuthoredPrAnswer<Value: Equatable>: Equatable {
    case ok(Value)
    case failed(code: String)
    /// The daemon never answered (not reachable, or the connection dropped).
    case unreachable
}

// Sendable whenever its payload is, so `AuthoredPrAnswerFrame` (which is `Sendable`) is too:
// without this the Mac build warns, and Swift 6 language mode would make it an error.
extension AuthoredPrAnswer: Sendable where Value: Sendable {}

public struct AuthoredPrLastTold: Equatable, Sendable {
    public var name: String
    public var at: Date?
    public init(name: String, at: Date?) { self.name = name; self.at = at }
}

/// A previewed message and what goes with it.
public struct AuthoredPrPreviewPayload: Equatable, Sendable {
    /// Exactly what will be sent. The app never edits it.
    public var text: String
    public var digest: String
    public var targetName: String
    public var lastTold: AuthoredPrLastTold?
    public var suggestedFolder: String?
    public var suggestedAgent: String?
    public init(text: String, digest: String, targetName: String = "", lastTold: AuthoredPrLastTold? = nil,
                suggestedFolder: String? = nil, suggestedAgent: String? = nil) {
        self.text = text; self.digest = digest; self.targetName = targetName; self.lastTold = lastTold
        self.suggestedFolder = suggestedFolder; self.suggestedAgent = suggestedAgent
    }
}

/// An empty success (`{}`).
public struct AuthoredPrDone: Equatable, Sendable { public init() {} }

public struct AuthoredPrStarted: Equatable, Sendable {
    public var tag: String
    public init(tag: String) { self.tag = tag }
}

/// `{"status":"ok","value":…}` or `{"status":"err","value":{"code":…}}`.
private struct WireResult<V: Decodable>: Decodable {
    let answer: AuthoredPrAnswerRaw<V>
    private enum K: String, CodingKey { case status, value }
    private struct Err: Decodable { let code: String? }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let status = try c.decode(String.self, forKey: .status)
        if status == "ok" {
            answer = .ok(try c.decode(V.self, forKey: .value))
        } else {
            let code = (try? c.decode(Err.self, forKey: .value))?.code ?? "failed"
            answer = .failed(code)
        }
    }
}
private enum AuthoredPrAnswerRaw<V> { case ok(V), failed(String) }

private struct PreviewValue: Decodable {
    let text: String
    let digest: String
    let target_name: String?
    let last_told: LastTold?
    let suggested_folder: String?
    let suggested_agent: String?
    struct LastTold: Decodable { let name: String?; let at: String? }
}
private struct StartedValue: Decodable { let tag: String }
private struct DoneValue: Decodable {}

/// One decoded answer frame, by request id.
public enum AuthoredPrAnswerFrame: Equatable, Sendable {
    case preview(requestId: String, AuthoredPrAnswer<AuthoredPrPreviewPayload>)
    case notify(requestId: String, AuthoredPrAnswer<AuthoredPrDone>)
    case startSession(requestId: String, AuthoredPrAnswer<AuthoredPrStarted>)
    case link(requestId: String, AuthoredPrAnswer<AuthoredPrDone>)

    public var requestId: String {
        switch self {
        case .preview(let id, _), .notify(let id, _), .startSession(let id, _), .link(let id, _): return id
        }
    }

    /// Decode a frame by its `type`; nil for any other frame, or one that does not parse.
    public static func decode(_ data: Data) -> AuthoredPrAnswerFrame? {
        struct Head: Decodable { let type: String; let request_id: String }
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { return nil }
        struct Body<V: Decodable>: Decodable { let result: WireResult<V> }
        func parse<V: Decodable>(_ type: V.Type) -> AuthoredPrAnswerRaw<V>? {
            (try? JSONDecoder().decode(Body<V>.self, from: data))?.result.answer
        }
        switch head.type {
        case "authored_pr_preview":
            guard let raw = parse(PreviewValue.self) else { return nil }
            switch raw {
            case .failed(let code): return .preview(requestId: head.request_id, .failed(code: code))
            case .ok(let v):
                let payload = AuthoredPrPreviewPayload(
                    text: v.text, digest: v.digest, targetName: v.target_name ?? "",
                    lastTold: v.last_told.map { AuthoredPrLastTold(name: $0.name ?? "", at: $0.at.flatMap(parseDate)) },
                    suggestedFolder: v.suggested_folder, suggestedAgent: v.suggested_agent)
                return .preview(requestId: head.request_id, .ok(payload))
            }
        case "authored_pr_notify_result":
            guard let raw = parse(DoneValue.self) else { return nil }
            switch raw {
            case .failed(let code): return .notify(requestId: head.request_id, .failed(code: code))
            case .ok: return .notify(requestId: head.request_id, .ok(AuthoredPrDone()))
            }
        case "authored_pr_start_session_result":
            guard let raw = parse(StartedValue.self) else { return nil }
            switch raw {
            case .failed(let code): return .startSession(requestId: head.request_id, .failed(code: code))
            case .ok(let v): return .startSession(requestId: head.request_id, .ok(AuthoredPrStarted(tag: v.tag)))
            }
        case "authored_pr_link_result":
            guard let raw = parse(DoneValue.self) else { return nil }
            switch raw {
            case .failed(let code): return .link(requestId: head.request_id, .failed(code: code))
            case .ok: return .link(requestId: head.request_id, .ok(AuthoredPrDone()))
            }
        default:
            return nil
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

/// The words for a code. The daemon never sends prose.
public enum AuthoredPrsHandoffWords {
    public static let unreachable = "Couldn't send: Nostromo isn't reachable"
    public static let changed = "The PR changed; check the message again"

    public static func failure(code: String) -> String {
        switch code {
        case "unknown_pr": return "Couldn't send: this PR is no longer in the list"
        case "nothing_to_fix": return "Couldn't send: nothing on this PR needs fixing now"
        case "owner_closed": return "That focus is closed"
        case "unknown_focus": return "Couldn't send: that focus isn't open"
        case "not_running": return "Couldn't send: that focus's session isn't running"
        case "bad_folder": return "Couldn't start: choose an existing folder"
        case "unknown_agent": return "Couldn't start: that agent isn't available"
        case "already_open": return "Couldn't start: a session for this PR is already open"
        case "start_failed": return "Couldn't start the session"
        case "not_operator_app", "requires_secure_connection": return "Couldn't send: Nostromo refused the request"
        case "unavailable": return "Couldn't send: this Nostromo can't hand PRs off"
        case "changed": return changed
        case "already_sent": return "Already sent: that message was delivered"
        default: return "Couldn't send (\(code))"
        }
    }
}
