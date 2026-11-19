import Foundation

// The author's open PRs, as the daemon sends them (`authored_prs`, feature `authored_prs_v1`).
//
// Decoding is lenient on purpose: an unknown enum value becomes `.unknown`, a missing optional is nil,
// and a row that cannot be decoded is dropped while the others stay. Everything that came from GitHub is
// trimmed and stripped of control and bidi characters again here (the daemon already did it once).

/// An enum whose unknown values decode to `.unknown` instead of failing the frame (decoded by
/// `KeyedDecodingContainer.lenient`, so the compiler's own raw-value decoding never gets a say).
protocol LenientWireEnum: RawRepresentable where RawValue == String {
    static var unknownCase: Self { get }
}

public enum AuthoredPrsTokenState: String, LenientWireEnum, Sendable {
    case connected, missing, rejected, unknown
    static var unknownCase: Self { .unknown }
}
public enum AuthoredPrsRelayState: String, LenientWireEnum, Sendable {
    case live, catchingUp = "catching_up", offline, notConfigured = "not_configured", unknown
    static var unknownCase: Self { .unknown }
}
public enum AuthoredPrsPollState: String, LenientWireEnum, Sendable {
    case ok, checking, rateLimited = "rate_limited", paused, error, idle, unknown
    static var unknownCase: Self { .unknown }
}
public enum AuthoredPrsRefreshBlocked: String, LenientWireEnum, Sendable {
    case running, rateLimited = "rate_limited", unknown
    static var unknownCase: Self { .unknown }
}
public enum AuthoredPrGroup: String, LenientWireEnum, Sendable {
    case needsYou = "needs_you", ready, waiting, draft, unknown
    static var unknownCase: Self { .unknown }
    /// Display order. An unknown group sorts last, after Drafts.
    public static let displayOrder: [AuthoredPrGroup] = [.needsYou, .ready, .waiting, .draft, .unknown]
}
public enum AuthoredPrLifecycle: String, LenientWireEnum, Sendable {
    case open, merged, closed, unknown
    static var unknownCase: Self { .unknown }
}
public enum AuthoredPrChecksState: String, LenientWireEnum, Sendable {
    case passing, failing, pending, none, unknown
    static var unknownCase: Self { .unknown }
}
public enum AuthoredPrReviewState: String, LenientWireEnum, Sendable {
    case approved, changesRequested = "changes_requested", reviewRequested = "review_requested", none, unknown
    static var unknownCase: Self { .unknown }
}
public enum AuthoredPrOwnerKind: String, LenientWireEnum, Sendable {
    case motherJob = "mother_job", linked, onBranch = "on_branch", ambiguous, closed, unknown
    static var unknownCase: Self { .unknown }
}

/// Perri's verdict on a PR's head commit (`authored_prs_perri_v1`).
public enum AuthoredPrPerriVerdict: String, LenientWireEnum, Sendable {
    case approved, changesRequested = "changes_requested", comment, unknown
    static var unknownCase: Self { .unknown }
}

/// How a focus came to be a candidate owner.
public enum AuthoredPrVia: String, LenientWireEnum, Sendable {
    case motherJob = "mother_job", linked, onBranch = "on_branch", unknown
    static var unknownCase: Self { .unknown }
}

/// The bounds the daemon applies; Kit applies them again.
public enum AuthoredPrsBounds {
    public static let title = 300
    public static let baseRef = 100
    public static let name = 120
    public static let checkName = 100
    public static let failingNames = 20
    public static let logins = 10
    public static let candidates = 8
    public static let hiddenOrgs = 10
    public static let orgName = 60
    public static let newComments: UInt32 = 999
}

/// Display-safe text: control, format (bidi) and line-separator characters removed (a newline or tab
/// becomes a space), trimmed, and cut to `max` characters.
public enum AuthoredPrsText {
    /// Exactly eight lowercase hex digits: the form of `head_sha_short` and `expected_head_sha_short`.
    public static func isShortSha(_ s: String) -> Bool {
        s.utf8.count == 8 && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
    public static func clean(_ raw: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control:
                if scalar == "\n" || scalar == "\t" || scalar == "\r" { out.append(" ") }
            case .format, .lineSeparator, .paragraphSeparator:
                continue
            default:
                out.append(scalar)
            }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespaces)
        return trimmed.count > max ? String(trimmed.prefix(max)) : trimmed
    }
}

private enum IsoDate {
    static func parse(_ s: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

private extension KeyedDecodingContainer {
    func date(_ key: Key) -> Date? {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.flatMap(IsoDate.parse)
    }
    func string(_ key: Key, max: Int) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0 }.map { AuthoredPrsText.clean($0, max: max) }
    }
    func strings(_ key: Key, max: Int, count: Int) -> [String] {
        let all = (try? decodeIfPresent([String].self, forKey: key)).flatMap { $0 } ?? []
        return all.prefix(count).map { AuthoredPrsText.clean($0, max: max) }.filter { !$0.isEmpty }
    }
    func int(_ key: Key) -> Int {
        (try? decodeIfPresent(Int.self, forKey: key)).flatMap { $0 } ?? 0
    }
    func flag(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)).flatMap { $0 } ?? false
    }
    func lenient<E: LenientWireEnum>(_ key: Key, _ type: E.Type) -> E {
        let raw = (try? decodeIfPresent(String.self, forKey: key)).flatMap { $0 }
        return raw.flatMap(E.init(rawValue:)) ?? E.unknownCase
    }
}

public struct AuthoredPrsRelay: Equatable, Sendable {
    public var state: AuthoredPrsRelayState
    public var since: Date?
    public var org: String
    public init(state: AuthoredPrsRelayState, since: Date? = nil, org: String = "") {
        self.state = state; self.since = since; self.org = org
    }
}
extension AuthoredPrsRelay: Decodable {
    private enum K: String, CodingKey { case state, since, org }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        state = c.lenient(.state, AuthoredPrsRelayState.self)
        since = c.date(.since)
        org = c.string(.org, max: AuthoredPrsBounds.orgName) ?? ""
    }
}

public struct AuthoredPrsPoll: Equatable, Sendable {
    public var state: AuthoredPrsPollState
    public var checkedAt: Date?
    public var intervalSecs: Int
    public var resumesAt: Date?
    public var retryAt: Date?
    public init(state: AuthoredPrsPollState, checkedAt: Date? = nil, intervalSecs: Int = 60,
                resumesAt: Date? = nil, retryAt: Date? = nil) {
        self.state = state; self.checkedAt = checkedAt; self.intervalSecs = intervalSecs
        self.resumesAt = resumesAt; self.retryAt = retryAt
    }
}
extension AuthoredPrsPoll: Decodable {
    private enum K: String, CodingKey { case state, checkedAt = "checked_at", intervalSecs = "interval_secs", resumesAt = "resumes_at", retryAt = "retry_at" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        state = c.lenient(.state, AuthoredPrsPollState.self)
        checkedAt = c.date(.checkedAt)
        intervalSecs = c.int(.intervalSecs)
        resumesAt = c.date(.resumesAt)
        retryAt = c.date(.retryAt)
    }
}

public struct AuthoredPrChecks: Equatable, Sendable {
    public var state: AuthoredPrChecksState
    public var passed: Int
    public var failed: Int
    public var pending: Int
    public var failingNames: [String]
    public init(state: AuthoredPrChecksState, passed: Int = 0, failed: Int = 0, pending: Int = 0, failingNames: [String] = []) {
        self.state = state; self.passed = passed; self.failed = failed; self.pending = pending; self.failingNames = failingNames
    }
}
extension AuthoredPrChecks: Decodable {
    private enum K: String, CodingKey { case state, passed, failed, pending, failingNames = "failing_names" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        state = c.lenient(.state, AuthoredPrChecksState.self)
        passed = c.int(.passed); failed = c.int(.failed); pending = c.int(.pending)
        failingNames = c.strings(.failingNames, max: AuthoredPrsBounds.checkName, count: AuthoredPrsBounds.failingNames)
    }
}

public struct AuthoredPrReview: Equatable, Sendable {
    public var state: AuthoredPrReviewState
    public var logins: [String]
    public init(state: AuthoredPrReviewState, logins: [String] = []) { self.state = state; self.logins = logins }
}
extension AuthoredPrReview: Decodable {
    private enum K: String, CodingKey { case state, logins }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        state = c.lenient(.state, AuthoredPrReviewState.self)
        logins = c.strings(.logins, max: AuthoredPrsBounds.name, count: AuthoredPrsBounds.logins)
    }
}

public struct AuthoredPrCandidate: Equatable, Sendable {
    public var tag: String
    public var name: String
    public var via: AuthoredPrVia
    public var jobId: String?
    public var closed: Bool
    public init(tag: String, name: String, via: AuthoredPrVia = .unknown, jobId: String? = nil, closed: Bool = false) {
        self.tag = tag; self.name = name; self.via = via; self.jobId = jobId; self.closed = closed
    }
}
extension AuthoredPrCandidate: Decodable {
    private enum K: String, CodingKey { case tag, name, via, jobId = "job_id", closed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        tag = c.string(.tag, max: AuthoredPrsBounds.name) ?? ""
        name = c.string(.name, max: AuthoredPrsBounds.name) ?? ""
        via = c.lenient(.via, AuthoredPrVia.self)
        jobId = c.string(.jobId, max: AuthoredPrsBounds.name)
        closed = c.flag(.closed)
    }
}

/// The focus last told about a PR (the user's own notify), and when.
public struct AuthoredPrTold: Equatable, Sendable {
    public var tag: String
    public var name: String
    public var at: Date?
    public init(tag: String, name: String, at: Date?) { self.tag = tag; self.name = name; self.at = at }
}
extension AuthoredPrTold: Decodable {
    private enum K: String, CodingKey { case tag, name, at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        tag = c.string(.tag, max: AuthoredPrsBounds.name) ?? ""
        name = c.string(.name, max: AuthoredPrsBounds.name) ?? ""
        at = c.date(.at)
    }
}

public struct AuthoredPrOwner: Equatable, Sendable {
    public var kind: AuthoredPrOwnerKind
    public var tag: String?
    public var name: String?
    public var jobId: String?
    public var candidates: [AuthoredPrCandidate]
    public init(kind: AuthoredPrOwnerKind, tag: String? = nil, name: String? = nil, jobId: String? = nil,
                candidates: [AuthoredPrCandidate] = []) {
        self.kind = kind; self.tag = tag; self.name = name; self.jobId = jobId; self.candidates = candidates
    }
    public static let unknown = AuthoredPrOwner(kind: .unknown)
}
extension AuthoredPrOwner: Decodable {
    private enum K: String, CodingKey { case kind, tag, name, jobId = "job_id", candidates }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kind = c.lenient(.kind, AuthoredPrOwnerKind.self)
        tag = c.string(.tag, max: AuthoredPrsBounds.name)
        name = c.string(.name, max: AuthoredPrsBounds.name)
        jobId = c.string(.jobId, max: AuthoredPrsBounds.name)
        let all = (try? c.decodeIfPresent([Lossy<AuthoredPrCandidate>].self, forKey: .candidates)).flatMap { $0 } ?? []
        candidates = all.compactMap(\.value).prefix(AuthoredPrsBounds.candidates).map { $0 }
    }
}

/// What Perri said about this PR. `forCurrentHead` is false when the verdict is for an older version of
/// the PR (a push since): it then never counts as approval. The note and the full SHA stay in the daemon.
public struct AuthoredPrPerri: Equatable, Sendable {
    public var verdict: AuthoredPrPerriVerdict
    public var at: Date?
    public var by: String?
    public var forCurrentHead: Bool
    public init(verdict: AuthoredPrPerriVerdict, at: Date? = nil, by: String? = nil, forCurrentHead: Bool) {
        self.verdict = verdict; self.at = at; self.by = by; self.forCurrentHead = forCurrentHead
    }
}
extension AuthoredPrPerri: Decodable {
    private enum K: String, CodingKey { case verdict, at, by, forCurrentHead = "for_current_head" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        verdict = c.lenient(.verdict, AuthoredPrPerriVerdict.self)
        at = c.date(.at)
        by = c.string(.by, max: AuthoredPrsBounds.name).flatMap { $0.isEmpty ? nil : $0 }
        // Absent means "not for the current head": never read as approval of it.
        forCurrentHead = c.flag(.forCurrentHead)
    }
}

public struct AuthoredPr: Equatable, Sendable, Identifiable {
    public var repo: String
    public var number: Int
    public var url: String
    public var title: String
    public var draft: Bool
    public var updatedAt: Date?
    public var group: AuthoredPrGroup
    public var lifecycle: AuthoredPrLifecycle
    public var endedAt: Date?
    public var baseRef: String?
    public var detailsUnavailable: Bool
    public var checks: AuthoredPrChecks
    public var review: AuthoredPrReview
    public var newComments: Int
    public var unresolvedThreads: Int
    public var threadsTruncated: Bool
    public var owner: AuthoredPrOwner
    /// Who was last told about this PR (`authored_prs_notify_v1`); nil when nobody was or the daemon is older.
    public var told: AuthoredPrTold?
    /// The daemon says this PR needs the user and its known, open owner has not been told: one waiting pill.
    public var pill: Bool
    /// The first 8 hex digits of the PR's head commit (`authored_prs_perri_v1`); nil when the daemon does not
    /// know it. What the Merge request echoes back as `expected_head_sha_short`.
    public var headShaShort: String?
    /// Perri's verdict, when one was recorded for this PR (`authored_prs_perri_v1`).
    public var perri: AuthoredPrPerri?

    public var id: String { "\(repo)#\(number)" }

    public init(repo: String, number: Int, url: String = "", title: String, draft: Bool = false, updatedAt: Date? = nil,
                group: AuthoredPrGroup = .waiting, lifecycle: AuthoredPrLifecycle = .open, endedAt: Date? = nil,
                baseRef: String? = nil, detailsUnavailable: Bool = false,
                checks: AuthoredPrChecks = AuthoredPrChecks(state: .none),
                review: AuthoredPrReview = AuthoredPrReview(state: .none),
                newComments: Int = 0, unresolvedThreads: Int = 0, threadsTruncated: Bool = false,
                owner: AuthoredPrOwner = .unknown, told: AuthoredPrTold? = nil, pill: Bool = false,
                headShaShort: String? = nil, perri: AuthoredPrPerri? = nil) {
        self.told = told; self.pill = pill; self.headShaShort = headShaShort; self.perri = perri
        self.repo = repo; self.number = number; self.url = url; self.title = title; self.draft = draft
        self.updatedAt = updatedAt; self.group = group; self.lifecycle = lifecycle; self.endedAt = endedAt
        self.baseRef = baseRef; self.detailsUnavailable = detailsUnavailable; self.checks = checks
        self.review = review; self.newComments = newComments; self.unresolvedThreads = unresolvedThreads
        self.threadsTruncated = threadsTruncated; self.owner = owner
    }
}
extension AuthoredPr: Decodable {
    private enum K: String, CodingKey {
        case repo, number, url, title, draft, updatedAt = "updated_at", group, lifecycle, endedAt = "ended_at"
        case baseRef = "base_ref", detailsUnavailable = "details_unavailable", checks, review
        case newComments = "new_comments", unresolvedThreads = "unresolved_threads", threadsTruncated = "threads_truncated", owner
        case told, pill, headShaShort = "head_sha_short", perri
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        // A row without these cannot be shown or opened: it fails, and the snapshot drops it.
        repo = AuthoredPrsText.clean(try c.decode(String.self, forKey: .repo), max: AuthoredPrsBounds.name * 2)
        number = try c.decode(Int.self, forKey: .number)
        title = AuthoredPrsText.clean(try c.decode(String.self, forKey: .title), max: AuthoredPrsBounds.title)
        url = (try? c.decodeIfPresent(String.self, forKey: .url)).flatMap { $0 } ?? ""
        draft = c.flag(.draft)
        updatedAt = c.date(.updatedAt)
        group = c.lenient(.group, AuthoredPrGroup.self)
        lifecycle = c.lenient(.lifecycle, AuthoredPrLifecycle.self)
        endedAt = c.date(.endedAt)
        baseRef = c.string(.baseRef, max: AuthoredPrsBounds.baseRef).flatMap { $0.isEmpty ? nil : $0 }
        detailsUnavailable = c.flag(.detailsUnavailable)
        checks = (try? c.decodeIfPresent(AuthoredPrChecks.self, forKey: .checks)).flatMap { $0 } ?? AuthoredPrChecks(state: .none)
        review = (try? c.decodeIfPresent(AuthoredPrReview.self, forKey: .review)).flatMap { $0 } ?? AuthoredPrReview(state: .none)
        newComments = min(c.int(.newComments), Int(AuthoredPrsBounds.newComments))
        unresolvedThreads = c.int(.unresolvedThreads)
        threadsTruncated = c.flag(.threadsTruncated)
        owner = (try? c.decodeIfPresent(AuthoredPrOwner.self, forKey: .owner)).flatMap { $0 } ?? .unknown
        told = (try? c.decodeIfPresent(AuthoredPrTold.self, forKey: .told)).flatMap { $0 }
        pill = c.flag(.pill)
        // Echoed back in a merge request, so only exactly eight lowercase hex digits count.
        headShaShort = (try? c.decodeIfPresent(String.self, forKey: .headShaShort)).flatMap { $0 }
            .flatMap { AuthoredPrsText.isShortSha($0) ? $0 : nil }
        perri = (try? c.decodeIfPresent(AuthoredPrPerri.self, forKey: .perri)).flatMap { $0 }
    }
}

public struct AuthoredPrsUsageCounts: Equatable, Sendable {
    public var charged = 0, notModified = 0, search = 0, graphqlPoints = 0
    public var relayCharged = 0, visibleCharged = 0, hiddenCharged = 0
    public init() {}
}
extension AuthoredPrsUsageCounts: Decodable {
    private enum K: String, CodingKey {
        case charged, notModified = "not_modified", search, graphqlPoints = "graphql_points"
        case relayCharged = "relay_charged", visibleCharged = "visible_charged", hiddenCharged = "hidden_charged"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        charged = c.int(.charged); notModified = c.int(.notModified); search = c.int(.search)
        graphqlPoints = c.int(.graphqlPoints); relayCharged = c.int(.relayCharged)
        visibleCharged = c.int(.visibleCharged); hiddenCharged = c.int(.hiddenCharged)
    }
}

public struct AuthoredPrsUsage: Equatable, Sendable {
    public var windowSecs: Int
    public var window: AuthoredPrsUsageCounts
    public var sinceStart: AuthoredPrsUsageCounts
    public init(windowSecs: Int = 3600, window: AuthoredPrsUsageCounts = .init(), sinceStart: AuthoredPrsUsageCounts = .init()) {
        self.windowSecs = windowSecs; self.window = window; self.sinceStart = sinceStart
    }
}
extension AuthoredPrsUsage: Decodable {
    private enum K: String, CodingKey { case windowSecs = "window_secs", sinceStart = "since_start" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        windowSecs = c.int(.windowSecs)
        // The window's counts sit beside `window_secs` (the daemon flattens them).
        window = (try? AuthoredPrsUsageCounts(from: decoder)) ?? .init()
        sinceStart = (try? c.decodeIfPresent(AuthoredPrsUsageCounts.self, forKey: .sinceStart)).flatMap { $0 } ?? .init()
    }
}

public struct AuthoredPrsSnapshot: Equatable, Sendable {
    public var generatedAt: Date?
    public var token: AuthoredPrsTokenState
    public var relay: AuthoredPrsRelay
    public var poll: AuthoredPrsPoll
    public var refreshBlocked: AuthoredPrsRefreshBlocked?
    public var hiddenOrgs: [String]
    public var totalOpen: Int
    public var shown: Int
    public var prs: [AuthoredPr]
    public var usage: AuthoredPrsUsage

    public init(generatedAt: Date? = nil, token: AuthoredPrsTokenState = .connected,
                relay: AuthoredPrsRelay = AuthoredPrsRelay(state: .notConfigured),
                poll: AuthoredPrsPoll = AuthoredPrsPoll(state: .ok), refreshBlocked: AuthoredPrsRefreshBlocked? = nil,
                hiddenOrgs: [String] = [], totalOpen: Int? = nil, shown: Int? = nil, prs: [AuthoredPr] = [],
                usage: AuthoredPrsUsage = AuthoredPrsUsage()) {
        self.generatedAt = generatedAt; self.token = token; self.relay = relay; self.poll = poll
        self.refreshBlocked = refreshBlocked; self.hiddenOrgs = hiddenOrgs
        self.totalOpen = totalOpen ?? prs.count; self.shown = shown ?? prs.count
        self.prs = prs; self.usage = usage
    }
}
extension AuthoredPrsSnapshot: Decodable {
    private enum K: String, CodingKey {
        case generatedAt = "generated_at", token, relay, poll, refreshBlocked = "refresh_blocked"
        case hiddenOrgs = "hidden_orgs", totalOpen = "total_open", shown, prs, usage
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        generatedAt = c.date(.generatedAt)
        token = c.lenient(.token, AuthoredPrsTokenState.self)
        relay = (try? c.decodeIfPresent(AuthoredPrsRelay.self, forKey: .relay)).flatMap { $0 } ?? AuthoredPrsRelay(state: .unknown)
        poll = (try? c.decodeIfPresent(AuthoredPrsPoll.self, forKey: .poll)).flatMap { $0 } ?? AuthoredPrsPoll(state: .unknown)
        let blocked = (try? c.decodeIfPresent(String.self, forKey: .refreshBlocked)).flatMap { $0 }
        refreshBlocked = blocked.map { AuthoredPrsRefreshBlocked(rawValue: $0) ?? .unknown }
        hiddenOrgs = c.strings(.hiddenOrgs, max: AuthoredPrsBounds.orgName, count: AuthoredPrsBounds.hiddenOrgs)
        let lossy = (try? c.decodeIfPresent([Lossy<AuthoredPr>].self, forKey: .prs)).flatMap { $0 } ?? []
        prs = lossy.compactMap(\.value)
        totalOpen = c.int(.totalOpen)
        shown = c.int(.shown)
        usage = (try? c.decodeIfPresent(AuthoredPrsUsage.self, forKey: .usage)).flatMap { $0 } ?? AuthoredPrsUsage()
    }
}

/// The `authored_prs` frame: `{"type":"authored_prs","snapshot":{…}}`.
public struct AuthoredPrsFrame: Decodable, Sendable {
    public let snapshot: AuthoredPrsSnapshot
}
