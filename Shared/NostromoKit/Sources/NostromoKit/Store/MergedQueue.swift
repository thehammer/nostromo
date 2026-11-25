// NostromoKit — MergedQueue.swift
//
// The one merged list the phone shows across Macs (Q8, PRD AC52, AC53): Mother jobs and sessions
// from the primary and from every satellite host, "needs you" first and then by recency. Pure: it
// takes the store's collections and returns rows.
//
//   - Every row shows its Mac's name when the list holds rows (live or last-known) from more than
//     one Mac; when every row comes from one Mac, none does. `Hosts` is not consulted for that.
//   - A work host's row is metadata only: its text is built from `ReasonPhrases` and nothing else, so
//     a title, question, branch, repository or session name never reaches it.

import Foundation
import CryptoKit

public struct MergedQueueRow: Identifiable, Equatable {
    public enum Kind: Equatable { case job, session }

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

    public static func == (a: MergedQueueRow, b: MergedQueueRow) -> Bool {
        a.id == b.id && a.hostBadge == b.hostBadge && a.text == b.text && a.needsYou == b.needsYou
            && a.isMetadataOnly == b.isMetadataOnly && a.recency == b.recency
    }
}

public enum MergedQueue {

    /// `primaryName` labels the primary's rows when a badge is shown. `egress` is what each host
    /// last reported; a host not in it is treated as `work` (the strict reading).
    public static func rows(primaryJobs: [MotherJob],
                            primarySessions: [SessionInfo],
                            hostedJobs: [String: [MotherJob]],
                            hostedSessions: [String: [SessionInfo]],
                            egress: [String: HostEgress],
                            primaryName: String) -> [MergedQueueRow] {
        var rows: [MergedQueueRow] = []
        func add(host: String?, jobs: [MotherJob], sessions: [SessionInfo]) {
            let metadataOnly = host.map { (egress[$0] ?? .work) == .work } ?? false
            rows += jobs.map { jobRow($0, host: host, metadataOnly: metadataOnly) }
            rows += sessions.map { sessionRow($0, host: host, metadataOnly: metadataOnly) }
        }
        add(host: nil, jobs: primaryJobs, sessions: primarySessions)
        for host in Set(hostedJobs.keys).union(hostedSessions.keys).sorted() {
            add(host: host, jobs: hostedJobs[host] ?? [], sessions: hostedSessions[host] ?? [])
        }

        // A badge on every row exactly when rows come from more than one Mac.
        let macs = Set(rows.map { $0.host ?? "" })
        let showBadge = macs.count > 1
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
                              job: metadataOnly ? nil : job, session: nil)
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
                              job: nil, session: metadataOnly ? nil : session)
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
                       needsYou: needsYou, text: text, recency: recency, job: job, session: session)
    }
}
