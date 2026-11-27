// NostromoKit — HostedContent.swift
//
// What a satellite's Focuses and Perri frames become on the phone (W11 slice 2): per-host state the
// store keeps, and pure builders that turn it into the sections the views draw, under a `HostScope`.
//
//   - Everything is keyed by (host, tag): a satellite's focus tag may equal the primary's.
//   - Nothing here asks whether a host is `work` or `personal`. A row shows the fields its frame
//     carries and a fixed phrase for a field it does not, so when a host's egress profile changes on
//     the daemon the phone follows with no change here.
//   - Everything is read-only. There is no action, and no row opens a transcript, pane or terminal.

import Foundation

// MARK: - Per-host state

/// A satellite's Perri state: the queue and the PR under review per focus tag.
public struct HostedPerriState: Equatable {
    public var queue: [PrQueueItem]
    public var currents: [String: PrSnapshot]

    public init(queue: [PrQueueItem] = [], currents: [String: PrSnapshot] = [:]) {
        self.queue = queue
        self.currents = currents
    }
}

/// A decision a satellite holds for the operator. The phone shows that it exists and answers nothing.
public struct HostedDecision: Equatable, Identifiable {
    public let host: String
    public let tag: String
    public let requestId: String
    /// The question, as the frame carried it (empty when the host sends none).
    public let prompt: String

    public var id: String { "\(host)|\(requestId)" }

    public init(host: String, tag: String, requestId: String, prompt: String) {
        self.host = host
        self.tag = tag
        self.requestId = requestId
        self.prompt = prompt
    }
}

// MARK: - Focuses

/// One Mac's focuses, for the Focuses list.
public struct FocusHostSection: Identifiable {
    public let host: HostEntry
    /// The Mac's name to show above its rows, or `nil` when the list is one Mac and the scope says so.
    public let title: String?
    public let lastKnownLabel: String?
    public let rows: [FocusRow]
    /// The Mac's sessions by tag, for the state badges.
    public let sessions: [String: SessionInfo]

    public var id: String { host.id }
    public var isLastKnown: Bool { !host.connected }
}

public enum HostedFocuses {

    /// The Macs' focus sections, the primary first, narrowed by `scope`. A Mac with no focuses has no
    /// section. `primaryPR` and `hostedPerri` say which PR each focus has under review.
    public static func sections(primaryFocuses: [FocusMeta],
                                primarySessions: [String: SessionInfo],
                                primaryPR: (String) -> (repo: String?, number: Int?),
                                hostedFocuses: [String: [FocusMeta]],
                                hostedSessions: [String: [SessionInfo]],
                                hostedPerri: [String: HostedPerriState],
                                hosts: [HostEntry],
                                scope: HostScope,
                                now: Date = Date()) -> [FocusHostSection] {
        var built: [(host: HostEntry, rows: [FocusRow], sessions: [String: SessionInfo])] = []
        for host in HostScopeOptions.ordered(hosts) where scope.matches(host: host.name, egress: host.egress) {
            if host.isPrimary {
                let rows = buildFocusRows(primaryFocuses, prFor: primaryPR)
                if !rows.isEmpty { built.append((host, rows, primarySessions)) }
                continue
            }
            let focuses = Self.unique(hostedFocuses[host.name] ?? [])
            guard !focuses.isEmpty else { continue }
            let perri = hostedPerri[host.name]
            let rows = withoutInventedOrgs(
                buildFocusRows(focuses) { tag in
                    let pr = perri?.currents[tag]
                    return (pr?.repo, pr?.prNumber)
                }, focuses: focuses)
            let sessions = Dictionary((hostedSessions[host.name] ?? []).map { ($0.tag, $0) },
                                      uniquingKeysWith: { _, last in last })
            built.append((host, rows, sessions))
        }
        let showTitle = built.count > 1 || !scope.isSingleHost
        return built.map {
            FocusHostSection(host: $0.host, title: showTitle ? $0.host.name : nil,
                             lastKnownLabel: HostScopeOptions.lastKnownLabel($0.host, now: now),
                             rows: $0.rows, sessions: $0.sessions)
        }
    }

    /// A focus list carries each tag once; the last entry for a tag wins (as for the primary's list).
    private static func unique(_ focuses: [FocusMeta]) -> [FocusMeta] {
        var seen: [String: FocusMeta] = [:]
        for focus in focuses { seen[focus.tag] = focus }
        return focuses.compactMap { seen.removeValue(forKey: $0.tag) }
    }

    /// `buildFocusRows` files a focus with no org under "Personal". A host that sent no org and no
    /// project for any focus has told us nothing about orgs, so no org header is invented for it.
    private static func withoutInventedOrgs(_ rows: [FocusRow], focuses: [FocusMeta]) -> [FocusRow] {
        let hasOrgInfo = focuses.contains { ($0.org?.isEmpty == false) || $0.projectName != nil }
        guard !hasOrgInfo else { return rows }
        return rows.filter { if case .orgHeader = $0 { return false } else { return true } }
    }
}

// MARK: - Perri

/// One PR row from a satellite's queue.
public struct HostedPerriRow: Identifiable, Equatable {
    public let id: String
    public let host: String
    public let bucket: String
    /// The title the frame carried, or the fixed `PR #N · …` line when it carried none.
    public let text: String
    /// The repository (a real name, or the host's `r-xxxxxxxx` token) and the author, when present.
    public let secondary: String?
    public let newActivity: Bool
    public let ciState: CiState
    /// The repository is the host's pseudonymous token, not a name.
    public let isPseudonymous: Bool
    /// Where the PR is on GitHub. `nil` for a pseudonymous row, an empty URL or anything but https.
    public let url: URL?
}

/// One Mac's Perri queue.
public struct PerriHostSection: Identifiable, Equatable {
    public let host: HostEntry
    public let title: String?
    public let lastKnownLabel: String?
    public let rows: [HostedPerriRow]

    public var id: String { host.id }
    public var isLastKnown: Bool { !host.connected }
}

public enum HostedPerri {

    /// The review buckets in the order the Perri tab lists them, with their headings.
    public static let buckets: [(key: String, label: String)] = [
        ("requested", "Requested"), ("needs_review", "Needs Review"),
        ("changes_req", "Changes Req"), ("dependabot", "Dependabot"),
    ]

    /// `r-` and eight lower-case hex: the token a `work` host puts where a repository name was.
    public static func isPseudonymousRepo(_ repo: String) -> Bool {
        guard repo.hasPrefix("r-") else { return false }
        let hex = repo.dropFirst(2)
        return hex.count == 8 && hex.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// The satellites' Perri sections narrowed by `scope`, in host order. The primary's own queue is
    /// not part of this: the Perri tab draws it as it always has.
    public static func sections(hostedPerri: [String: HostedPerriState],
                                hosts: [HostEntry],
                                scope: HostScope,
                                includePrimary: Bool,
                                now: Date = Date()) -> [PerriHostSection] {
        let visible = HostScopeOptions.ordered(hosts).filter {
            !$0.isPrimary && scope.matches(host: $0.name, egress: $0.egress)
        }
        let withRows = visible.filter { !(hostedPerri[$0.name]?.queue.isEmpty ?? true) }
        let showTitle = withRows.count + (includePrimary ? 1 : 0) > 1 || !scope.isSingleHost
        return withRows.map { host in
            let queue = hostedPerri[host.name]?.queue ?? []
            return PerriHostSection(host: host, title: showTitle ? host.name : nil,
                                    lastKnownLabel: HostScopeOptions.lastKnownLabel(host, now: now),
                                    rows: rows(host: host.name, queue: queue))
        }
    }

    static func rows(host: String, queue: [PrQueueItem]) -> [HostedPerriRow] {
        var seen = Set<String>()
        let unique = queue.filter { seen.insert("\($0.repo)#\($0.number)#\($0.bucket)").inserted }
        let order = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { ($1.key, $0) })
        let sorted = unique.sorted {
            let a = order[$0.bucket] ?? buckets.count, b = order[$1.bucket] ?? buckets.count
            if a != b { return a < b }
            if $0.number != $1.number { return $0.number < $1.number }
            return $0.repo < $1.repo
        }
        return sorted.map { row($0, host: host, waiting: unique.count) }
    }

    private static func row(_ item: PrQueueItem, host: String, waiting: Int) -> HostedPerriRow {
        let pseudonymous = isPseudonymousRepo(item.repo)
        let text = item.title.isEmpty
            ? ReasonPhrases.prLine(number: item.number, sizeChangedLines: item.changedLines, waiting: waiting)
            : item.title
        let secondary = [item.repo, item.author].filter { !$0.isEmpty }.joined(separator: " · ")
        return HostedPerriRow(id: "\(host)|\(item.bucketScopedId)", host: host, bucket: item.bucket, text: text,
                              secondary: secondary.isEmpty ? nil : secondary, newActivity: item.newActivity,
                              ciState: item.ciState, isPseudonymous: pseudonymous,
                              url: pseudonymous ? nil : httpsURL(item.url))
    }

    private static func httpsURL(_ text: String) -> URL? {
        guard !text.isEmpty, let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}
