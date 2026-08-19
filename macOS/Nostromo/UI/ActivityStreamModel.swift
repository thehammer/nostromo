import Foundation

// MARK: - ActivityAgentStream

/// One agent's slice of a focus's ambient activity: the main agent's stream
/// (`agentId == nil`) or one subagent's stream, nested under
/// `parentAgentId`.
///
/// `finished` flips to `true` once a `subagent_stop` event has been seen for
/// this `agentId` — it is what `ActivityStreamModel.runningSubagentCount`
/// counts against.
struct ActivityAgentStream {
    let agentId:       String?
    let agentType:     String?
    let parentAgentId: String?
    var events:        [ActivityEvent]
    var finished:      Bool
}

// MARK: - ActivityHealthState

/// Operator-facing verdict on whether a focus's activity pipe is alive.
///
/// `ingesting == false` means no events are currently arriving for this
/// focus — regardless of how much history is cached — and the ticker must
/// say so rather than silently keep showing the last-known event.
/// `hookInstalled` distinguishes the two different "not ingesting" causes:
/// the hook was never installed (fixed by installing it / `nostromo doctor`)
/// versus the hook is installed but nothing has arrived yet (a different
/// problem, needing different operator guidance).
struct ActivityHealthState {
    let ingesting:     Bool
    let reason:        String?
    let hookInstalled: Bool
}

// MARK: - ActivityStreamModel

/// Assembles one focus's raw per-agent activity streams (as broadcast by the
/// daemon) into what the ticker and its expanded panel need to render:
/// stream nesting/attribution, the ticker's one-line summary, health-to-text
/// mapping, and `seq`-gap detection.
///
/// Pure logic — no AppKit/SwiftUI/Combine. `AppStore` owns the Combine
/// plumbing and is responsible for re-requesting a daemon snapshot when
/// `ingest(_:)` reports a gap; this type only detects the gap.
struct ActivityStreamModel {

    // MARK: - State

    private var main: ActivityAgentStream?
    private var subagentsByAgentId: [String: ActivityAgentStream] = [:]
    /// Insertion order, so `subagentStreams` is stable / predictable.
    private var subagentOrder: [String] = []
    /// Last `seq` seen per stream, keyed by `agentId` (`""` for the main
    /// stream — no real `agentId` is ever empty).
    private var lastSeqByStreamKey: [String: UInt64] = [:]

    // MARK: - Init

    init() {}

    // MARK: - Ingest

    /// Files `event` into its stream — the main stream when `event.agentId
    /// == nil`, otherwise the matching subagent stream (created on that
    /// subagent's first event). Marks a subagent stream `finished` on a
    /// `subagent_stop` event.
    ///
    /// Returns `true` exactly when this event's `seq` reveals a gap versus
    /// the last `seq` seen for its stream: `seq` present, a prior `seq` was
    /// already recorded for this stream, and the new value is not exactly
    /// one more than the prior value. A `nil` `seq` (old daemon build, or
    /// the pre-`seq` wire shape) never counts as a gap — treat "can't tell"
    /// as "don't false-alarm". The first event ever ingested into a given
    /// stream never counts as a gap, regardless of its `seq`, because there
    /// is nothing yet to compare it against.
    @discardableResult
    mutating func ingest(_ event: ActivityEvent) -> Bool {
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
            if event.kind == "subagent_stop" {
                subagentsByAgentId[agentId]?.finished = true
            }
        } else {
            if main == nil {
                main = ActivityAgentStream(agentId: nil, agentType: nil, parentAgentId: nil, events: [], finished: false)
            }
            main?.events.append(event)
        }

        return gap
    }

    /// `true` exactly when `seq` is present, a prior `seq` is already on
    /// record for `streamKey`, and it isn't exactly one more than that.
    ///
    /// An event with no `seq` at all (old daemon build) clears any prior
    /// `seq` on record for this stream rather than leaving it in place —
    /// otherwise the *next* `seq`-carrying event would be compared against a
    /// now-meaningless baseline and could be flagged as a false gap. Once the
    /// baseline is gone, resuming `seq` tracking starts clean, exactly like
    /// the very first event into an empty stream.
    private mutating func detectGap(streamKey: String, seq: UInt64?) -> Bool {
        guard let seq else {
            lastSeqByStreamKey.removeValue(forKey: streamKey)
            return false
        }
        defer { lastSeqByStreamKey[streamKey] = seq }
        guard let previous = lastSeqByStreamKey[streamKey] else { return false }
        return seq != previous + 1
    }

    // MARK: - Queries

    /// The main stream (`agentId == nil`), or `nil` if no event has arrived
    /// for it yet.
    var mainStream: ActivityAgentStream? { main }

    /// All subagent streams seen so far, regardless of `finished`.
    var subagentStreams: [ActivityAgentStream] {
        subagentOrder.compactMap { subagentsByAgentId[$0] }
    }

    /// Count of subagent streams with `finished == false` — i.e. no
    /// `subagent_stop` event has been seen for them yet.
    var runningSubagentCount: Int {
        subagentStreams.filter { !$0.finished }.count
    }

    // MARK: - Ticker summary

    /// The single line the always-visible ticker shows for this focus,
    /// independent of health. Three distinct states:
    ///
    /// - No events at all yet → a neutral "waiting" line (e.g. `"⚙ —"`),
    ///   textually distinct from `ActivityStreamModel.healthText(for:)`'s
    ///   not-ingesting text — nothing observing either string may confuse
    ///   "no events yet" with "the pipe is broken".
    /// - No subagents running → the most recent main-stream event, formatted
    ///   `"⚙ <agent>: <summary>"`, with `summary` truncated to 37 characters
    ///   plus `"…"` when longer than 40 (mirrors the removed
    ///   `StatusBarView.buildLeft()` activity segment's truncation rule).
    /// - One or more subagents running → names the base agent and the
    ///   running count, e.g. `"<agent> · N agents active"`.
    var tickerSummary: String {
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
    /// there is cached last-event text to fall back on — the PRD's hard
    /// requirement that an outage is never silently masked by a stale
    /// event. When `health.ingesting == true`, this is `tickerSummary`.
    func displayText(health: ActivityHealthState) -> String {
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
    static func healthText(for health: ActivityHealthState) -> String {
        if health.hookInstalled {
            return "Not receiving activity — the hook is present but no events have arrived yet."
        }
        return "Not receiving activity — install the hook (run `nostromo doctor --fix`) to enable it."
    }

    // MARK: - Formatting

    /// Mirrors the removed `StatusBarView.buildLeft()` activity segment's
    /// truncation rule: cut to 37 chars + an ellipsis once over 40.
    private static func clip(_ summary: String) -> String {
        guard summary.count > 40 else { return summary }
        return String(summary.prefix(37)) + "…"
    }
}
