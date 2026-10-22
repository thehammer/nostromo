// NostromoKit — NeedsYou.swift
//
// One app-wide "needs you" source. Every producer of "the operator has to do
// something" (Mother holds and flags, the W6 decision modal, and later approvals and
// the tracker) publishes content-free items here; the Dock badge, the notifier, the
// sidebar and the Mother counts strip all read the same snapshot.
//
// Pure: no AppKit, no UserNotifications, no free text. An item names WHAT is waiting
// (a typed reason and a source) and never carries a question, a gate name or a title.

import Foundation

// MARK: - Items

/// Where the thing that needs the operator lives.
public enum NeedsYouSource: Equatable, Hashable {
    case motherJob(String)
    case focus(String)
    case app
}

/// Which kind of hold Mother put a job in.
public enum MotherHoldKind: Equatable, Hashable {
    case gatesExhausted
    case reviewHold
    /// An open decision with no gate or review hold activity.
    case decision
}

public enum NeedsYouReason: Equatable {
    case motherHold(MotherHoldKind)
    case motherAwaiting
    case motherAttention(MotherAttentionReason)
    case decisionOpen
    case approvalPending(Int)
    case trackerWaiting
    case other(String)
}

public struct NeedsYouItem: Equatable, Identifiable {
    /// Unique across producers: begins with `<producer>:`.
    public let id: String
    public let source: NeedsYouSource
    public let reason: NeedsYouReason
    public let since: Date?
    /// Derived from work-item text (a "Send to agent" job): a surface shows the reason only.
    public let sensitive: Bool

    public init(
        id: String,
        source: NeedsYouSource,
        reason: NeedsYouReason,
        since: Date? = nil,
        sensitive: Bool = false
    ) {
        self.id = id
        self.source = source
        self.reason = reason
        self.since = since
        self.sensitive = sensitive
    }

    /// The producer that raised the item: the id up to its first `:`.
    public var producer: String {
        id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? id
    }
}

// MARK: - Snapshot

public struct NeedsYouSnapshot: Equatable {
    /// Oldest first (`since` ascending, items without one last), ties by id.
    public let items: [NeedsYouItem]
    public let total: Int
    /// Items per focus tag (`.focus(tag)` sources).
    public let perFocus: [String: Int]
    /// Items about Mother jobs.
    public let mother: Int

    public static let empty = NeedsYouSnapshot(items: [])

    public init(items: [NeedsYouItem]) {
        let sorted = items.sorted { a, b in
            switch (a.since, b.since) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.id < b.id
            }
        }
        self.items = sorted
        total = sorted.count
        var focus: [String: Int] = [:]
        var mother = 0
        for item in sorted {
            switch item.source {
            case .focus(let tag): focus[tag, default: 0] += 1
            case .motherJob: mother += 1
            case .app: break
            }
        }
        perFocus = focus
        self.mother = mother
    }
}

// MARK: - Aggregator

public struct NeedsYouAggregator {
    private var byProducer: [String: [NeedsYouItem]] = [:]

    public init() {}

    /// Replace everything `producer` has raised. An empty list withdraws the producer.
    /// An id that does not start with `<producer>:` gets that prefix, so ids never collide
    /// across producers.
    @discardableResult
    public mutating func set(producer: String, items: [NeedsYouItem]) -> NeedsYouSnapshot {
        if items.isEmpty {
            byProducer.removeValue(forKey: producer)
        } else {
            let prefix = producer + ":"
            byProducer[producer] = items.map { item in
                item.id.hasPrefix(prefix)
                    ? item
                    : NeedsYouItem(id: prefix + item.id, source: item.source, reason: item.reason,
                                   since: item.since, sensitive: item.sensitive)
            }
        }
        return snapshot
    }

    public var snapshot: NeedsYouSnapshot {
        NeedsYouSnapshot(items: byProducer.values.flatMap { $0 })
    }
}

// MARK: - Mother producer

/// What the Mother producer reads from a job: both the Kit `MotherJob` and the Mac app's
/// own `MotherJob` conform.
public protocol MotherJobLike {
    var id: String { get }
    var state: String { get }
    var title: String { get }
    /// The job's `origin.label` (`mother add --label`), if any.
    var originLabel: String? { get }
    var crew: MotherCrewState { get }
}

extension MotherJob: MotherJobLike {}

public enum MotherNeedsYouProducer {
    public static let name = "mother"
    /// The `origin.label` of a job queued from a work item (`WORK_SEND_JOB_LABEL` in the daemon).
    public static let workSendLabel = "teri-send"

    public static func items(from jobs: [any MotherJobLike]) -> [NeedsYouItem] {
        var out: [NeedsYouItem] = []
        for job in jobs {
            let sensitive = job.originLabel == workSendLabel
            let source = NeedsYouSource.motherJob(job.id)
            let attention = job.crew.attention

            if job.state == "awaiting" {
                let decision = job.crew.decision.flatMap { $0.isOpen ? $0 : nil }
                let reason: NeedsYouReason
                switch job.crew.activity {
                case "gate_hold": reason = .motherHold(.gatesExhausted)
                case "review_hold": reason = .motherHold(.reviewHold)
                default: reason = decision == nil ? .motherAwaiting : .motherHold(.decision)
                }
                let since = date(decision?.openedAt)
                    ?? date(attention.first { $0.reason == .decisionAwaiting }?.since)
                out.append(NeedsYouItem(id: "mother:\(job.id):await", source: source, reason: reason,
                                        since: since, sensitive: sensitive))
            }

            // A finished job needs nobody, whatever flags it still carries.
            guard !["succeeded", "failed", "cancelled"].contains(job.state) else { continue }
            var seen = Set<String>()
            for entry in attention where !entry.acked && entry.reason != .decisionAwaiting {
                let raw = entry.reason.raw
                guard !raw.isEmpty, seen.insert(raw).inserted else { continue }
                out.append(NeedsYouItem(id: "mother:\(job.id):\(raw)", source: source,
                                        reason: .motherAttention(entry.reason),
                                        since: date(entry.since), sensitive: sensitive))
            }
        }
        return out
    }

    private static func date(_ iso: String?) -> Date? {
        guard let iso else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}

// MARK: - Decision producer

/// The W6 decision modal raises per-focus attention tags; each is one item.
public enum DecisionNeedsYouProducer {
    public static let name = "decisions"

    public static func items(attentionTags: Set<String>) -> [NeedsYouItem] {
        attentionTags.sorted().map {
            NeedsYouItem(id: "decisions:\($0)", source: .focus($0), reason: .decisionOpen)
        }
    }
}
