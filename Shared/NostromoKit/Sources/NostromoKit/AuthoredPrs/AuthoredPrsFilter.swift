import Foundation

// The My open PRs Overview's filter: by org, by repo and by session (the focus that owns the PR), as pure functions of
// the PRs and a selection. It only chooses which PRs show and words the pop-ups; grouping and order stay the
// daemon's. It is not the Mother job list's `From:` filter and shares no state with it, only its wording and
// its name sanitising (`MotherOriginDisplay.clean`: PR owners' names come from agents and GitHub, untrusted).

/// What the `Org:` pop-up can be set to.
public enum AuthoredPrsOrgSelection: Hashable, Sendable {
    case all
    /// The owner part of `owner/name`, lower-cased: GitHub logins are case-insensitive, so `Carefeed/x` and
    /// `carefeed/x` are one org.
    case org(String)
}

/// What the `Repo:` pop-up can be set to.
public enum AuthoredPrsRepoSelection: Hashable, Sendable {
    case all
    /// The repo as the daemon names it (`owner/name`).
    case repo(String)
}

/// What the `Session:` pop-up can be set to.
public enum AuthoredPrsSessionSelection: Hashable, Sendable {
    case all
    /// PRs owned by this focus.
    case focus(tag: String)
    /// PRs with no known owner: the owner is closed, unknown or ambiguous.
    case noSession
}

public struct AuthoredPrsFilterSelection: Equatable, Sendable {
    public var org: AuthoredPrsOrgSelection
    public var repo: AuthoredPrsRepoSelection
    public var session: AuthoredPrsSessionSelection

    public init(org: AuthoredPrsOrgSelection = .all, repo: AuthoredPrsRepoSelection = .all,
                session: AuthoredPrsSessionSelection = .all) {
        self.org = org
        self.repo = repo
        self.session = session
    }

    public static let all = AuthoredPrsFilterSelection()

    /// Anything picked at all.
    public var isActive: Bool { org != .all || repo != .all || session != .all }
}

/// One entry in a pop-up.
public struct AuthoredPrsFilterEntry<Selection: Hashable & Sendable>: Equatable, Sendable {
    public let selection: Selection
    /// Sanitised and capped, without the count.
    public let title: String
    /// PRs in the list that match this entry on its own (`All` is every PR).
    public let count: Int
    /// Sanitised but NOT capped, without the count: what a tooltip shows, so a name the menu truncated can
    /// still be read in full. Equals `title` for a name that fits.
    public let fullTitle: String

    public init(selection: Selection, title: String, count: Int, fullTitle: String? = nil) {
        self.selection = selection
        self.title = title
        self.count = count
        self.fullTitle = fullTitle ?? title
    }

    /// What the menu says: `nostromo (3)`.
    public var menuTitle: String { "\(title) (\(count))" }
}

public enum AuthoredPrsFilterEmptyState: Equatable, Sendable {
    case none
    /// PRs exist, but none match the selection; the view offers `Show all`.
    case noMatch(text: String)
}

public struct AuthoredPrsFilterResult: Equatable, Sendable {
    /// The matching PRs, in the order they came.
    public let prs: [AuthoredPr]
    public let matched: Int
    public let total: Int
    /// All; then each owner in the list, most PRs first then A-Z. The selected one is always there, even with
    /// no PRs. Counts are over the whole list.
    public let orgEntries: [AuthoredPrsFilterEntry<AuthoredPrsOrgSelection>]
    /// All; then each repo inside the selected org A-Z. The selected one is always there, even with no PRs
    /// (or outside the org).
    public let repoEntries: [AuthoredPrsFilterEntry<AuthoredPrsRepoSelection>]
    /// All; then each owning focus A-Z; then `No session`, over the PRs inside the selected org. The selected
    /// one is always there.
    public let sessionEntries: [AuthoredPrsFilterEntry<AuthoredPrsSessionSelection>]
    public let selection: AuthoredPrsFilterSelection
    /// The selected entry's name, for the empty message.
    public let orgTitle: String
    public let repoTitle: String
    public let sessionTitle: String

    public var emptyState: AuthoredPrsFilterEmptyState {
        guard total > 0, matched == 0 else { return .none }
        return .noMatch(text: emptyText)
    }

    private var emptyText: String {
        let inOrg: String? = selection.org == .all ? nil : "in org \(orgTitle)"
        let inRepo: String? = selection.repo == .all ? nil : "in \(repoTitle)"
        let session: String?
        switch selection.session {
        case .all: session = nil
        case .noSession: session = "without a session"
        case .focus: session = "from \(sessionTitle)"
        }
        let parts = [inOrg, inRepo, session].compactMap { $0 }
        return parts.isEmpty ? "No PRs match." : "No PRs \(parts.joined(separator: " "))."
    }
}

public enum AuthoredPrsFilter {
    public static let noSessionTitle = "No session"
    public static let repoCap = 60
    public static let orgCap = 60

    /// The org key of a repo named `owner/name`: its lower-cased owner. Nil when there is no owner part.
    public static func orgKey(ofRepo repo: String) -> String? {
        guard let slash = repo.firstIndex(of: "/") else { return nil }
        let owner = repo[..<slash].trimmingCharacters(in: .whitespacesAndNewlines)
        return owner.isEmpty ? nil : owner.lowercased()
    }

    /// The session a PR belongs to: its owning focus, or none when the owner is closed, unknown or ambiguous.
    public static func session(of pr: AuthoredPr) -> AuthoredPrsSessionSelection {
        switch pr.owner.kind {
        case .motherJob, .linked, .onBranch:
            guard let tag = pr.owner.tag, !tag.isEmpty else { return .noSession }
            return .focus(tag: tag)
        case .closed, .unknown, .ambiguous:
            return .noSession
        }
    }

    public static func apply(_ prs: [AuthoredPr], selection: AuthoredPrsFilterSelection) -> AuthoredPrsFilterResult {
        var orgCounts: [String: Int] = [:]
        var orgNames: [String: String] = [:]
        var repoCounts: [String: Int] = [:]
        var sessionCounts: [AuthoredPrsSessionSelection: Int] = [:]
        var focusNames: [String: String] = [:]
        var sessionOf: [String: AuthoredPrsSessionSelection] = [:]
        let orgOf: (AuthoredPr) -> AuthoredPrsOrgSelection? = { pr in orgKey(ofRepo: pr.repo).map { .org($0) } }
        for pr in prs {
            // Org counts are over the whole list; repo and session entries only over the selected org.
            if let key = orgKey(ofRepo: pr.repo) {
                orgCounts[key, default: 0] += 1
                if orgNames[key] == nil, let slash = pr.repo.firstIndex(of: "/") {
                    orgNames[key] = pr.repo[..<slash].trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            let session = session(of: pr)
            // A focus keeps its name even when its PRs are outside the selected org.
            if case .focus(let tag) = session, focusNames[tag] == nil { focusNames[tag] = pr.owner.name }
            guard selection.org == .all || orgOf(pr) == selection.org else { continue }
            repoCounts[pr.repo, default: 0] += 1
            sessionOf[pr.id] = session
            sessionCounts[session, default: 0] += 1
        }

        let matching = prs.filter { pr in
            let orgOK = selection.org == .all || orgOf(pr) == selection.org
            let repoOK: Bool
            switch selection.repo {
            case .all: repoOK = true
            case .repo(let name): repoOK = pr.repo == name
            }
            let sessionOK = selection.session == .all || sessionOf[pr.id] == selection.session
            return orgOK && repoOK && sessionOK
        }

        func orgTitle(_ key: String, cap: Int = orgCap) -> String {
            let title = MotherOriginDisplay.clean(orgNames[key] ?? key, cap: cap)
            return title.isEmpty ? "unnamed org" : title
        }
        func orgSelectionTitle(_ selection: AuthoredPrsOrgSelection) -> String {
            if case .org(let key) = selection { return orgTitle(key) }
            return "All"
        }
        func repoTitle(_ name: String, cap: Int = repoCap) -> String {
            let title = MotherOriginDisplay.clean(name, cap: cap)
            return title.isEmpty ? "unnamed repo" : title
        }
        func sessionTitle(_ selection: AuthoredPrsSessionSelection, cap: Int = MotherOriginDisplay.rowCap) -> String {
            switch selection {
            case .all: return "All"
            case .noSession: return noSessionTitle
            case .focus(let tag):
                let name = MotherOriginDisplay.clean(focusNames[tag], cap: cap)
                if !name.isEmpty { return name }
                let fallback = MotherOriginDisplay.clean(tag, cap: cap)
                return fallback.isEmpty ? "focus" : fallback
            }
        }

        var orgKeys = Set(orgCounts.keys)
        if case .org(let selected) = selection.org { orgKeys.insert(selected) }
        let orgEntries = [AuthoredPrsFilterEntry(selection: AuthoredPrsOrgSelection.all, title: "All", count: prs.count)]
            + orgKeys
                .map { AuthoredPrsFilterEntry(selection: AuthoredPrsOrgSelection.org($0), title: orgTitle($0), count: orgCounts[$0] ?? 0,
                                              fullTitle: orgTitle($0, cap: .max)) }
                .sorted {
                    if $0.count != $1.count { return $0.count > $1.count }
                    return byTitle($0.title, $1.title, tieBreak: "\($0.selection)" < "\($1.selection)")
                }

        let orgScoped = repoCounts.values.reduce(0, +)
        var repoNames = Set(repoCounts.keys)
        if case .repo(let selected) = selection.repo { repoNames.insert(selected) }
        let repoEntries = [AuthoredPrsFilterEntry(selection: AuthoredPrsRepoSelection.all, title: "All", count: orgScoped)]
            + repoNames
                .map { AuthoredPrsFilterEntry(selection: AuthoredPrsRepoSelection.repo($0), title: repoTitle($0), count: repoCounts[$0] ?? 0,
                                                       fullTitle: repoTitle($0, cap: .max)) }
                .sorted { byTitle($0.title, $1.title, tieBreak: "\($0.selection)" < "\($1.selection)") }

        var focusSelections = Set(sessionCounts.keys.filter { $0 != .noSession })
        if case .focus = selection.session { focusSelections.insert(selection.session) }
        var sessionEntries = [AuthoredPrsFilterEntry(selection: AuthoredPrsSessionSelection.all, title: "All", count: orgScoped)]
        sessionEntries += focusSelections
            .map { AuthoredPrsFilterEntry(selection: $0, title: sessionTitle($0), count: sessionCounts[$0] ?? 0,
                                                       fullTitle: sessionTitle($0, cap: .max)) }
            .sorted { byTitle($0.title, $1.title, tieBreak: "\($0.selection)" < "\($1.selection)") }
        if sessionCounts[.noSession] != nil || selection.session == .noSession {
            sessionEntries.append(AuthoredPrsFilterEntry(selection: .noSession, title: noSessionTitle, count: sessionCounts[.noSession] ?? 0))
        }

        return AuthoredPrsFilterResult(
            prs: matching, matched: matching.count, total: prs.count,
            orgEntries: orgEntries, repoEntries: repoEntries, sessionEntries: sessionEntries, selection: selection,
            orgTitle: orgSelectionTitle(selection.org),
            repoTitle: selection.repo == .all ? "All" : repoTitle(repoName(selection.repo)),
            sessionTitle: sessionTitle(selection.session))
    }

    private static func repoName(_ selection: AuthoredPrsRepoSelection) -> String {
        if case .repo(let name) = selection { return name }
        return ""
    }

    private static func byTitle(_ a: String, _ b: String, tieBreak: Bool) -> Bool {
        let c = a.localizedCaseInsensitiveCompare(b)
        return c == .orderedSame ? tieBreak : c == .orderedAscending
    }

    // MARK: Remembering the selection

    /// The longest repo or tag a stored value may carry; anything longer is stale or hand-edited.
    static let storedLimit = 200
    private static let focusPrefix = "focus:"
    private static let noSessionStored = "none"

    /// The stored value for each pop-up; nil for `All`.
    public static func stored(_ selection: AuthoredPrsFilterSelection) -> (org: String?, repo: String?, session: String?) {
        let org: String?
        switch selection.org {
        case .all: org = nil
        case .org(let key): org = key
        }
        let repo: String?
        switch selection.repo {
        case .all: repo = nil
        case .repo(let name): repo = name
        }
        let session: String?
        switch selection.session {
        case .all: session = nil
        case .noSession: session = noSessionStored
        case .focus(let tag): session = focusPrefix + tag
        }
        return (org, repo, session)
    }

    /// The selection a stored pair stands for. Anything that is not a sane string of the shape `stored`
    /// writes (a number, an empty string, an unknown prefix, an overlong value) reads as `All`.
    public static func selection(storedOrg: Any? = nil, storedRepo: Any?, storedSession: Any?) -> AuthoredPrsFilterSelection {
        var selection = AuthoredPrsFilterSelection.all
        // A key is lower-cased, trimmed and non-empty, as `orgKey` writes it; anything else is stale.
        if let org = storedOrg as? String, !org.isEmpty, org.count <= storedLimit,
           org == org.lowercased(), org == org.trimmingCharacters(in: .whitespacesAndNewlines), !org.contains("/") {
            selection.org = .org(org)
        }
        if let repo = storedRepo as? String, !repo.isEmpty, repo.count <= storedLimit {
            selection.repo = .repo(repo)
        }
        if let session = storedSession as? String, session.count <= storedLimit + focusPrefix.count {
            if session == noSessionStored {
                selection.session = .noSession
            } else if session.hasPrefix(focusPrefix), session.count > focusPrefix.count {
                selection.session = .focus(tag: String(session.dropFirst(focusPrefix.count)))
            }
        }
        return selection
    }
}
