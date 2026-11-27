// NostromoKit — MergedQueue.swift
//
// The one merged list the phone shows across Macs (Q8, PRD AC52, AC53): Mother jobs and sessions
// from the primary and from every satellite host, "needs you" first and then by recency. Pure: it
// takes the store's collections and returns rows.
//
//   - Every row shows its Mac's name when the list holds rows (live or last-known) from more than
//     one Mac; when every row comes from one Mac, none does. `Hosts` is not consulted for that.
//   - A work host's job and session row is metadata only: its text is built from `ReasonPhrases` and
//     nothing else, so a title, question, branch, repository or session name never reaches it.
//   - A satellite's held decisions and approvals are rows too ("Answer it on your Mac"): the phone
//     answers nothing (B10). Their text is whatever the frame carries, or a fixed phrase when it
//     carries none, so a host's egress profile changing needs no change here.
//   - A scope (`HostScope`) narrows the rows to one kind of Mac or one Mac. Every row then carries
//     its Mac's name unless the scope is a single Mac that is the only one with rows.

import Foundation
import CryptoKit

public struct MergedQueueRow: Identifiable, Equatable {
    public enum Kind: Equatable { case job, session, decision, approval }

    /// `host|kind|id`: a job is identified by `(host, id)`, so two hosts never collide.
    public let id: String
    public let kind: Kind
    /// The satellite's name, or `nil` for the primary's own row.
    public let host: String?
    /// The Mac's name to show on the row, or `nil` when the list is from a single Mac.
    public let hostBadge: String?
    /// A work host's row: fixed phrases only, no drill-in that asks for content.
    public let isMetadataOnly: Bool
    public let needsYou: Bool
    /// The row's main line. For a metadata-only row this is a fixed-vocabulary line.
    public let text: String
    public let recency: Date?
    /// The full job, for a personal-host row that opens the job detail.
    public let job: MotherJob?
    public let session: SessionInfo?
    /// A line under the row's text, for a row that points at the Mac (`Answer it on your Mac`).
    public let footnote: String?
    /// The row's host is not connected: it is what that host last said, shown dimmed.
    public let isLastKnown: Bool
    /// `Last seen 5 minutes ago` for a last-known row.
    public let lastKnownLabel: String?

    public static func == (a: MergedQueueRow, b: MergedQueueRow) -> Bool {
        a.id == b.id && a.hostBadge == b.hostBadge && a.text == b.text && a.needsYou == b.needsYou
            && a.isMetadataOnly == b.isMetadataOnly && a.recency == b.recency
            && a.footnote == b.footnote && a.isLastKnown == b.isLastKnown
            && a.lastKnownLabel == b.lastKnownLabel
    }
}

public enum MergedQueue {

    /// `primaryName` labels the primary's rows when a badge is shown. `egress` is what each host
    /// last reported; a host not in it is treated as `work` (the strict reading).
    ///
    /// `scope` is the phone's host filter; `nil` (the original call) shows every Mac with the plain
    /// Q8 badge rule. `hostedDecisions` and `approvalCounts` (host -> tag -> held requests) are the
    /// satellites' only; the primary's own decisions are not rows here. `hosts` says which Macs are
    /// connected, for the last-known marking.
    public static func rows(primaryJobs: [MotherJob],
                            primarySessions: [SessionInfo],
                            hostedJobs: [String: [MotherJob]],
                            hostedSessions: [String: [SessionInfo]],
                            egress: [String: HostEgress],
                            primaryName: String,
                            hostedDecisions: [String: [HostedDecision]] = [:],
                            approvalCounts: [String: [String: Int]] = [:],
                            scope: HostScope? = nil,
                            hosts: [HostEntry] = [],
                            now: Date = Date()) -> [MergedQueueRow] {
        var rows: [MergedQueueRow] = []
        func entry(_ host: String?) -> HostEntry? { hosts.first { $0.name == (host ?? primaryName) } }
        func add(host: String?, jobs: [MotherJob], sessions: [SessionInfo], decisions: [HostedDecision],
                 approvals: [String: Int]) {
            let hostEgress = host.map { egress[$0] ?? .work } ?? .personal
            if let scope, !scope.matches(host: host ?? primaryName, egress: hostEgress) { return }
            let metadataOnly = host != nil && hostEgress == .work
            var added = jobs.map { jobRow($0, host: host, metadataOnly: metadataOnly) }
            added += sessions.map { sessionRow($0, host: host, metadataOnly: metadataOnly) }
            if let host {
                added += decisions.map { decisionRow($0, host: host) }
                added += approvals.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                    .map { approvalRow(tag: $0.key, count: $0.value, host: host, metadataOnly: metadataOnly) }
            }
            let known = entry(host)
            let lastKnown = known.map { !$0.connected } ?? false
            let label = known.flatMap { HostScopeOptions.lastKnownLabel($0, now: now) }
            rows += added.map { $0.with(lastKnown: lastKnown, label: label) }
        }
        add(host: nil, jobs: primaryJobs, sessions: primarySessions, decisions: [], approvals: [:])
        let satellites = Set(hostedJobs.keys).union(hostedSessions.keys).union(hostedDecisions.keys)
            .union(approvalCounts.keys.filter { !$0.isEmpty })
        for host in satellites.sorted() {
            add(host: host, jobs: hostedJobs[host] ?? [], sessions: hostedSessions[host] ?? [],
                decisions: hostedDecisions[host] ?? [], approvals: approvalCounts[host] ?? [:])
        }

        // A badge on every row exactly when rows come from more than one Mac, and always while the
        // scope is a group of Macs rather than one.
        let macs = Set(rows.map { $0.host ?? "" })
        let showBadge = macs.count > 1 || (scope.map { !$0.isSingleHost } ?? false)
        let badged = rows.map { row in
            row.with(hostBadge: showBadge ? (row.host ?? primaryName) : nil)
        }
        return badged.sorted(by: order)
    }

    // MARK: - Private

    private static func order(_ a: MergedQueueRow, _ b: MergedQueueRow) -> Bool {
        if a.needsYou != b.needsYou { return a.needsYou }
        switch (a.recency, b.recency) {
        case let (x?, y?) where x != y: return x > y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.id < b.id
        }
    }

    private static func jobRow(_ job: MotherJob, host: String?, metadataOnly: Bool) -> MergedQueueRow {
        let needs = !MotherNeedsYouProducer.items(from: [job]).isEmpty
        let text: String
        if metadataOnly {
            let status = needs ? ReasonPhrases.reason(pausedReason: job.pausedReason, activity: job.crew.activity)
                               : job.state
            text = ReasonPhrases.jobLine(id: job.id, status: status)
        } else {
            text = job.title.isEmpty ? job.id : job.title
        }
        let when = [job.finishedAt, job.startedAt, job.createdAt].compactMap { $0 }.compactMap(parse).first
        return MergedQueueRow(id: "\(host ?? "")|job|\(job.id)", kind: .job, host: host, hostBadge: nil,
                              isMetadataOnly: metadataOnly, needsYou: needs, text: text, recency: when,
                              job: metadataOnly ? nil : job, session: nil, footnote: nil,
                              isLastKnown: false, lastKnownLabel: nil)
    }

    private static func sessionRow(_ session: SessionInfo, host: String?, metadataOnly: Bool) -> MergedQueueRow {
        let state = session.state.rawValue
        let text = metadataOnly ? ReasonPhrases.sessionLine(agentName: session.agentName, state: state)
                                : "\(session.agentName) · \(state)"
        // A work host's tag is the daemon's pseudonym, but nothing of a work host's is used raw: the id
        // carries a short hash of it.
        let tagPart = metadataOnly ? shortHash(session.tag) : session.tag
        return MergedQueueRow(id: "\(host ?? "")|session|\(tagPart)", kind: .session, host: host, hostBadge: nil,
                              isMetadataOnly: metadataOnly, needsYou: false, text: text, recency: nil,
                              job: nil, session: metadataOnly ? nil : session, footnote: nil,
                              isLastKnown: false, lastKnownLabel: nil)
    }

    /// A decision a satellite is holding. It needs the operator, and the phone cannot answer it.
    private static func decisionRow(_ decision: HostedDecision, host: String) -> MergedQueueRow {
        let text = decision.prompt.isEmpty ? ReasonPhrases.decisionLine : decision.prompt
        return MergedQueueRow(id: "\(host)|decision|\(decision.requestId)", kind: .decision, host: host,
                              hostBadge: nil, isMetadataOnly: false, needsYou: true, text: text, recency: nil,
                              job: nil, session: nil, footnote: ReasonPhrases.answerOnYourMac,
                              isLastKnown: false, lastKnownLabel: nil)
    }

    /// The permission requests a satellite's focus holds: only a count, so only a fixed phrase.
    private static func approvalRow(tag: String, count: Int, host: String, metadataOnly: Bool) -> MergedQueueRow {
        let tagPart = metadataOnly ? shortHash(tag) : tag
        return MergedQueueRow(id: "\(host)|approval|\(tagPart)", kind: .approval, host: host, hostBadge: nil,
                              isMetadataOnly: metadataOnly, needsYou: true,
                              text: ReasonPhrases.approvalLine(count: count), recency: nil,
                              job: nil, session: nil, footnote: ReasonPhrases.answerOnYourMac,
                              isLastKnown: false, lastKnownLabel: nil)
    }

    private static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func parse(_ iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}

extension MergedQueueRow {
    fileprivate func with(hostBadge: String?) -> MergedQueueRow {
        MergedQueueRow(id: id, kind: kind, host: host, hostBadge: hostBadge, isMetadataOnly: isMetadataOnly,
                       needsYou: needsYou, text: text, recency: recency, job: job, session: session,
                       footnote: footnote, isLastKnown: isLastKnown, lastKnownLabel: lastKnownLabel)
    }

    fileprivate func with(lastKnown: Bool, label: String?) -> MergedQueueRow {
        MergedQueueRow(id: id, kind: kind, host: host, hostBadge: hostBadge, isMetadataOnly: isMetadataOnly,
                       needsYou: needsYou, text: text, recency: recency, job: job, session: session,
                       footnote: footnote, isLastKnown: lastKnown, lastKnownLabel: label)
    }
}
