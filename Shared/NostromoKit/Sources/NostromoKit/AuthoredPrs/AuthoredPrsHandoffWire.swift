import Foundation

// The hand-off verbs of the PR Overview (feature `authored_prs_notify_v1`): preview the message, send it to a
// focus, start a session with it, link a PR to a focus. The daemon composes the message; the app only shows it
// and echoes its digest. Answers carry a code, never prose: the app words each code.

/// The feature flag in `Welcome.features`.
public let authoredPrsNotifyFeature = "authored_prs_notify_v1"
/// Rows carry `head_sha_short` and Perri's verdict (`perri`).
public let authoredPrsPerriFeature = "authored_prs_perri_v1"
/// The daemon takes `authored_pr_merge` (the Merge button's verb) and answers `authored_pr_merge_result`.
public let authoredPrsMergeFeature = "authored_prs_merge_v1"
/// The Merge verb goes through the base branch's merge queue where one is required: rows carry `merge_via` and
/// `queue`, the merge request may carry `expected_via`, the answer may be `queued` or `already_queued`.
public let authoredPrsMergeQueueFeature = "authored_prs_merge_queue_v1"

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

/// Squash-merge the PR now. The daemon merges only when a human approved, GitHub says it is clean and Perri
/// approved the head the app was showing (`expectedHeadShaShort`, 8 hex digits); it answers with a code only.
/// Send it only after a human gesture.
public struct ClientAuthoredPrMerge: Encodable, Equatable {
    let type_ = "authored_pr_merge"
    public let requestId: String
    public let repo: String
    public let number: Int
    public let expectedHeadShaShort: String
    /// How the confirmation worded it: `.queue` for "add to the merge queue". Absent means a direct merge, so a
    /// direct request is byte-for-byte what an older build sent. The daemon refuses (`via_changed`) when GitHub
    /// says the PR goes in another way now.
    public let expectedVia: AuthoredPrMergeVia?
    public init(requestId: String, repo: String, number: Int, expectedHeadShaShort: String,
                expectedVia: AuthoredPrMergeVia? = nil) {
        self.requestId = requestId; self.repo = repo; self.number = number
        self.expectedHeadShaShort = expectedHeadShaShort
        self.expectedVia = expectedVia == .queue ? .queue : nil
    }
    enum CodingKeys: String, CodingKey {
        case type_ = "type", requestId = "request_id", repo, number, expectedHeadShaShort = "expected_head_sha_short"
        case expectedVia = "expected_via"
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
public struct AuthoredPrDone: Equatable, Sendable {
    /// A merge answered `queued`: the PR is in the merge queue, not merged.
    public var queued: Bool
    public init(queued: Bool = false) { self.queued = queued }
}

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
private struct MergeDoneValue: Decodable {
    /// The string `code`, when there is one.
    let code: String?
    /// The answer carries a `code` key at all (of any type). `{}` is "merged"; a code is only ever `queued`.
    let hasCode: Bool
    private enum K: String, CodingKey { case code }
    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: K.self)
        hasCode = container?.contains(.code) ?? false
        code = container.flatMap { try? $0.decodeIfPresent(String.self, forKey: .code) }.flatMap { $0 }
    }
}

/// One decoded answer frame, by request id.
public enum AuthoredPrAnswerFrame: Equatable, Sendable {
    case preview(requestId: String, AuthoredPrAnswer<AuthoredPrPreviewPayload>)
    case notify(requestId: String, AuthoredPrAnswer<AuthoredPrDone>)
    case startSession(requestId: String, AuthoredPrAnswer<AuthoredPrStarted>)
    case link(requestId: String, AuthoredPrAnswer<AuthoredPrDone>)
    case merge(requestId: String, AuthoredPrAnswer<AuthoredPrDone>)

    public var requestId: String {
        switch self {
        case .preview(let id, _), .notify(let id, _), .startSession(let id, _), .link(let id, _), .merge(let id, _):
            return id
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
        case "authored_pr_merge_result":
            guard let raw = parse(MergeDoneValue.self) else { return nil }
            switch raw {
            case .failed(let code): return .merge(requestId: head.request_id, .failed(code: code))
            // `{}` is a merge and the exact word `queued` is a queue. Any other code is an answer this build does
            // not know: never shown as "Merged" (the action may already have happened), a generic failure.
            case .ok(let v):
                if !v.hasCode { return .merge(requestId: head.request_id, .ok(AuthoredPrDone(queued: false))) }
                if v.code == "queued" { return .merge(requestId: head.request_id, .ok(AuthoredPrDone(queued: true))) }
                return .merge(requestId: head.request_id, .failed(code: "unexpected_answer"))
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

/// Why a merge did not happen, from the answer's code. A code this build does not know is `.unknown`, a
/// generic failure: the app never shows the daemon's string and never treats an unknown one as success.
public enum AuthoredPrMergeCode: Equatable, Sendable {
    case notFound, notOpen, draft, notApproved, checksNotGreen, notMergeable, blocked, behind, headChanged
    case perriNotApproved, perriStale, tokenCannotMerge, rateLimited, unreachable, busy, notPermitted
    /// The merge queue: the PR is already in it, GitHub declined to enqueue it, GitHub could not say whether there
    /// is a queue, or the PR goes in another way than the confirmation said.
    case alreadyQueued, queueRefused, queueUnknown, viaChanged
    /// Not from the daemon (no wire spelling maps to it): the PR was in the merge queue and a later snapshot shows
    /// it is not, and it is not merged.
    case droppedFromQueue
    /// Not from the daemon (no wire spelling maps to it): this app declined the press because no person's gesture
    /// was behind it, so nothing was sent.
    case gestureRefused
    /// Not a daemon code: a success answer carrying a code this build does not know (the decoder's own spelling is
    /// `unexpected_answer`). The action may already have happened, so it is never shown as a merge.
    case unexpectedAnswer
    case unknown

    public init(wire code: String) {
        switch code {
        case "not_found": self = .notFound
        case "not_open": self = .notOpen
        case "draft": self = .draft
        case "not_approved": self = .notApproved
        case "checks_not_green": self = .checksNotGreen
        case "not_mergeable": self = .notMergeable
        case "blocked": self = .blocked
        case "behind": self = .behind
        case "head_changed": self = .headChanged
        case "perri_not_approved": self = .perriNotApproved
        case "perri_stale": self = .perriStale
        case "token_cannot_merge": self = .tokenCannotMerge
        case "rate_limited": self = .rateLimited
        case "unreachable": self = .unreachable
        case "busy": self = .busy
        case "already_queued": self = .alreadyQueued
        case "queue_refused": self = .queueRefused
        case "queue_unknown": self = .queueUnknown
        case "via_changed": self = .viaChanged
        case "unexpected_answer": self = .unexpectedAnswer
        // A refusal of the peer, however the daemon spelled it: this app is not allowed to merge.
        case "not_permitted", "not_operator_app", "requires_secure_connection": self = .notPermitted
        default: self = .unknown
        }
    }
}

extension AuthoredPrAnswer where Value == AuthoredPrDone {
    /// The merge answered `queued`: it went into the merge queue, nothing is merged yet.
    public var mergeQueued: Bool {
        if case .ok(let done) = self { return done.queued }
        return false
    }

    /// The merge code of a failed answer; `.unreachable` when the daemon never answered; nil for success.
    public var mergeFailure: AuthoredPrMergeCode? {
        switch self {
        case .ok: return nil
        case .unreachable: return .unreachable
        case .failed(let code): return AuthoredPrMergeCode(wire: code)
        }
    }
}

/// The words for a merge code, as one sentence a notice on the row can carry. The daemon never sends prose.
public enum AuthoredPrsMergeWords {
    public static func failure(_ code: AuthoredPrMergeCode) -> String {
        switch code {
        case .notFound: return "This PR is no longer in your list, so it wasn't merged"
        case .notOpen: return "This PR is no longer open, so it wasn't merged"
        case .draft: return "This PR is a draft, so it wasn't merged"
        case .notApproved: return "No human reviewer has approved it, so it wasn't merged"
        case .checksNotGreen: return "Checks aren't green, so it wasn't merged"
        case .notMergeable: return "GitHub says it can't be merged (conflicts?)"
        case .blocked: return "GitHub's branch protection blocked it"
        case .behind: return "The branch is behind its base: update it first"
        case .headChanged: return "The PR changed since you looked: review it again"
        case .perriNotApproved: return "Perri hasn't approved this version"
        case .perriStale: return "Perri approved an older version: it needs a new review"
        case .tokenCannotMerge: return "Your GitHub token cannot merge"
        case .rateLimited: return "GitHub is rate limiting: try again later"
        // The request may have gone through before the connection or GitHub failed to answer.
        case .unreachable: return "GitHub or Nostromo isn't reachable: check the PR before trying again"
        case .busy: return "A merge of this PR is already running"
        case .alreadyQueued: return "This PR is already in the merge queue"
        case .queueRefused: return "GitHub wouldn't add it to the merge queue (conflicts, or not ready?)"
        case .queueUnknown: return "GitHub didn't say whether there is a merge queue, so nothing was sent"
        case .viaChanged: return "How this PR merges changed since you looked: review it again"
        case .droppedFromQueue: return "Dropped from the merge queue"
        case .notPermitted: return "Nostromo refused the request"
        case .gestureRefused: return "Merge was refused: use the button"
        // A success whose code this build does not know: the action may already have happened.
        case .unexpectedAnswer: return "Unexpected answer: check GitHub"
        case .unknown: return "The merge failed"
        }
    }
}
