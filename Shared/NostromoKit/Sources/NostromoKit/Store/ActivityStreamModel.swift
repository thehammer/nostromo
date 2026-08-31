// NostromoKit — ActivityStreamModel.swift
//
// Ported from macOS/Nostromo/UI/ActivityStreamModel.swift (ios-curated-view-
// parity W4) so iOS can assemble the same per-focus ambient activity streams
// macOS does — stream nesting/attribution, the ticker's one-line summary,
// health-to-text mapping, and `seq`-gap detection — all verbatim from the
// macOS original. macOS keeps its own copy; deduplicating the two is
// deferred (see the wedge plan's Decision 1 / memo B11).
//
// What macOS's copy lacks and this one adds: bounded retention.
// `maxEventsPerStream`/`maxTotalEvents` mirror the daemon's own
// `activity::store::MAX_EVENTS_PER_STREAM` / `MAX_TOTAL_EVENTS`
// (src/activity/store.rs) — a client-side cap below the daemon's would
// silently discard part of a snapshot the daemon still considers current;
// a cap above it would never bind. On overflow, the oldest events of
// *finished* subagent streams are reclaimed first, then the oldest events
// of *running* subagent streams, and only then the main stream — the main
// stream is what the ticker reads, so it is reclaimed last.

import Foundation

// MARK: - ActivityAgentStream

/// One agent's slice of a focus's ambient activity: the main agent's stream
/// (`agentId == nil`) or one subagent's stream, nested under
/// `parentAgentId`.
public struct ActivityAgentStream {
    public let agentId:       String?
    public let agentType:     String?
    public let parentAgentId: String?
    public var events:        [ActivityEvent]
    public var finished:      Bool
}

// MARK: - ActivityHealthState

/// Operator-facing verdict on whether a focus's activity pipe is alive.
///
/// Unlike macOS's copy, this retains `lastEventAt` (D2) — it is what lets
/// the not-ingesting message say *how long* it has been silent, which on a
/// phone is the difference between "just started" and "this has been
/// broken all evening." Rendering it is optional; dropping it is not.
public struct ActivityHealthState: Equatable {
    public let ingesting:     Bool
    public let reason:        String?
    public let lastEventAt:   Date?
    public let hookInstalled: Bool

    public init(ingesting: Bool, reason: String?, lastEventAt: Date? = nil, hookInstalled: Bool) {
        self.ingesting = ingesting
        self.reason = reason
        self.lastEventAt = lastEventAt
        self.hookInstalled = hookInstalled
    }
}

// MARK: - ActivityStreamModel

/// Assembles one focus's raw per-agent activity streams (as broadcast by the
/// daemon) into what the ticker and its expanded sheet need to render:
/// stream nesting/attribution, the ticker's one-line summary, health-to-text
/// mapping, `seq`-gap detection, and bounded retention.
///
/// Pure logic — no SwiftUI/Combine. `DaemonStore` owns the Combine plumbing
/// and is responsible for re-requesting a daemon snapshot when `ingest(_:)`
/// reports a gap; this type only detects the gap.
public struct ActivityStreamModel {

    // MARK: - Retention constants

    /// Per-stream retention cap. Mirrors `activity::store::MAX_EVENTS_PER_STREAM`
    /// (src/activity/store.rs) — keep these in sync.
    public static let maxEventsPerStream = 200

    /// Store-wide retention cap across all of this focus's streams combined.
    /// Mirrors `activity::store::MAX_TOTAL_EVENTS` (src/activity/store.rs) —
    /// keep these in sync.
    public static let maxTotalEvents = 2000

    // MARK: - State

    private var main: ActivityAgentStream?
    private var subagentsByAgentId: [String: ActivityAgentStream] = [:]
    private var subagentOrder: [String] = []
    private var lastSeqByStreamKey: [String: UInt64] = [:]

    // MARK: - Init

    public init() {}

    // MARK: - Ingest

    /// Files `event` into its stream — the main stream when `event.agentId
    /// == nil`, otherwise the matching subagent stream (created on that
    /// subagent's first event) — enforces both retention caps, and returns
    /// `true` exactly when this event's `seq` reveals a gap versus the last
    /// `seq` seen for its stream.
    ///
    /// A `nil` `seq` never counts as a gap — treat "can't tell" as "don't
    /// false-alarm" — and neither does the first event ever ingested into a
    /// given stream, because there is nothing yet to compare it against.
    @discardableResult
    public mutating func ingest(_ event: ActivityEvent) -> Bool {
        let streamKey = event.agentId ?? ""
        let gap = detectGap(streamKey: streamKey, seq: event.seq)

        if let agentId = event.agentId {
            if subagentsByAgentId[agentId] == nil {
                subagentOrder.append(agentId)
                subagentsByAgentId[agentId] = ActivityAgentStream(
                    agentId: agentId,
                    agentType: event.agentType,
                    parentAgentId: event.parentAgentId,
                    events: [],
                    finished: false)
            }
            subagentsByAgentId[agentId]?.events.append(event)
            if let count = subagentsByAgentId[agentId]?.events.count, count > Self.maxEventsPerStream {
                subagentsByAgentId[agentId]?.events.removeFirst()
            }
            if event.kind == "subagent_stop" {
                subagentsByAgentId[agentId]?.finished = true
            }
        } else {
            if main == nil {
                main = ActivityAgentStream(agentId: nil, agentType: nil, parentAgentId: nil, events: [], finished: false)
            }
            main?.events.append(event)
            if let count = main?.events.count, count > Self.maxEventsPerStream {
                main?.events.removeFirst()
            }
        }

        reclaimIfOverBudget()
        return gap
    }

    /// `true` exactly when `seq` is present, a prior `seq` is already on
    /// record for `streamKey`, and it isn't exactly one more than that.
    ///
    /// An event with no `seq` at all clears any prior `seq` on record for
    /// this stream rather than leaving it in place — otherwise the *next*
    /// `seq`-carrying event would be compared against a now-meaningless
    /// baseline and could be flagged as a false gap.
    private mutating func detectGap(streamKey: String, seq: UInt64?) -> Bool {
        guard let seq else {
            lastSeqByStreamKey.removeValue(forKey: streamKey)
            return false
        }
        defer { lastSeqByStreamKey[streamKey] = seq }
        guard let previous = lastSeqByStreamKey[streamKey] else { return false }
        return seq != previous + 1
    }

    /// While the total event count across every stream (main + all
    /// subagents) exceeds `maxTotalEvents`, reclaim the oldest events first
    /// from *finished* subagent streams, then from *running* subagent
    /// streams, and only then from the main stream — the main stream is
    /// what the ticker reads, so it's reclaimed last. `total` is tracked
    /// locally (rather than recomputed via `totalEventCount` at each step)
    /// so each tier below is a cheap no-op once an earlier tier has already
    /// brought the aggregate back within budget.
    private mutating func reclaimIfOverBudget() {
        var total = totalEventCount
        guard total > Self.maxTotalEvents else { return }

        reclaimSubagentTier(finished: true, total: &total)
        reclaimSubagentTier(finished: false, total: &total)
        reclaimMainStream(total: &total)
    }

    /// Reclaims the oldest events from subagent streams whose `finished`
    /// flag matches `finished`, oldest-stream-first per `subagentOrder`
    /// (the order streams were first seen stands in for "oldest" among
    /// peers in the same tier), stopping the moment `total` is back within
    /// `maxTotalEvents`.
    private mutating func reclaimSubagentTier(finished: Bool, total: inout Int) {
        for agentId in subagentOrder {
            guard total > Self.maxTotalEvents else { return }
            guard subagentsByAgentId[agentId]?.finished == finished else { continue }
            while total > Self.maxTotalEvents, !(subagentsByAgentId[agentId]?.events.isEmpty ?? true) {
                subagentsByAgentId[agentId]?.events.removeFirst()
                total -= 1
            }
        }
    }

    /// Reclaims the oldest main-stream events. Only ever removes anything
    /// once both subagent tiers above have already been drained and the
    /// budget is still exceeded.
    private mutating func reclaimMainStream(total: inout Int) {
        while total > Self.maxTotalEvents, !(main?.events.isEmpty ?? true) {
            main?.events.removeFirst()
            total -= 1
        }
    }

    private var totalEventCount: Int {
        (main?.events.count ?? 0) + subagentsByAgentId.values.reduce(0) { $0 + $1.events.count }
    }

    // MARK: - Queries

    /// The main stream (`agentId == nil`), or `nil` if no event has arrived
    /// for it yet.
    public var mainStream: ActivityAgentStream? { main }

    /// All subagent streams seen so far, regardless of `finished`, in the
    /// order they were first seen.
    public var subagentStreams: [ActivityAgentStream] {
        subagentOrder.compactMap { subagentsByAgentId[$0] }
    }

    /// Count of subagent streams with `finished == false` — i.e. no
    /// `subagent_stop` event has been seen for them yet.
    public var runningSubagentCount: Int {
        subagentStreams.filter { !$0.finished }.count
    }

    // MARK: - Ticker summary

    /// The single line the always-visible ticker shows for this focus,
    /// independent of health. Three distinct states:
    ///
    /// - No events at all yet → a neutral "waiting" line, textually
    ///   distinct from `healthText(for:)`'s not-ingesting text.
    /// - No subagents running → the most recent main-stream event,
    ///   formatted `"⚙ <agent>: <summary>"`, with `summary` truncated to 37
    ///   characters plus `"…"` when longer than 40.
    /// - One or more subagents running → names the base agent and the
    ///   running count, e.g. `"<agent> · N agents active"`.
    public var tickerSummary: String {
        let running = runningSubagentCount
        if running > 0 {
            let agentName = main?.events.last?.agent ?? subagentStreams.first?.agentType ?? "Agent"
            return "\(agentName) · \(running) agent\(running == 1 ? "" : "s") active"
        }
        guard let lastMainEvent = main?.events.last else {
            return "⚙ —"
        }
        return "⚙ \(lastMainEvent.agent): \(Self.clip(lastMainEvent.summary))"
    }

    /// The exact text the ticker shows once health is folded in. A
    /// non-ingesting `health` always wins over `tickerSummary`, even when
    /// there is cached last-event text to fall back on — an outage must
    /// never be silently masked by a stale event. When `health.ingesting ==
    /// true`, this is `tickerSummary`.
    public func displayText(health: ActivityHealthState) -> String {
        guard health.ingesting else {
            return Self.healthText(for: health)
        }
        return tickerSummary
    }

    // MARK: - Health text

    /// Operator-facing text for a non-ingesting health verdict. Never
    /// called when `health.ingesting == true`. Produces two distinct
    /// messages depending on `health.hookInstalled`: one naming the
    /// install-the-hook / `nostromo doctor` fix, the other — for the
    /// installed-but-silent case — naming a different, non-install fix.
    public static func healthText(for health: ActivityHealthState) -> String {
        if health.hookInstalled {
            return "Not receiving activity — the hook is present but no events have arrived yet."
        }
        return "Not receiving activity — install the hook (run `nostromo doctor --fix`) to enable it."
    }

    // MARK: - Formatting

    /// Cut to 37 chars + an ellipsis once over 40.
    private static func clip(_ summary: String) -> String {
        guard summary.count > 40 else { return summary }
        return String(summary.prefix(37)) + "…"
    }
}
