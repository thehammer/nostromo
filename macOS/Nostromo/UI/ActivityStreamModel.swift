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

    // MARK: - Retention constants
    //
    // Bounded retention, ported verbatim from
    // Shared/NostromoKit/Sources/NostromoKit/Store/ActivityStreamModel.swift
    // (which added these bounds for iOS; macOS's copy lacked them until now
    // — see the 2026-09-02 "unbounded memory growth" bug doc).

    /// Per-stream retention cap. Mirrors Rust
    /// `activity::store::MAX_EVENTS_PER_STREAM` (`src/activity/store.rs`) —
    /// keep these in sync. A client cap below the daemon's would silently
    /// discard part of a snapshot the daemon still considers current; a cap
    /// above it could never bind, since the daemon already trimmed first.
    static let maxEventsPerStream = 200

    /// Store-wide retention cap across all of a focus's streams combined.
    /// Mirrors Rust `activity::store::MAX_TOTAL_EVENTS` (`src/activity/store.rs`)
    /// — keep these in sync, for the same reason as `maxEventsPerStream`.
    static let maxTotalEvents = 2000

    /// Cap on the number of subagent stream *entries* retained — distinct
    /// from `maxEventsPerStream`, which only bounds the events *within* one
    /// entry. Without this, a long-lived focus that spawns many subagents
    /// over time accumulates one permanent dictionary entry per subagent
    /// forever (RC2 in the retention bug doc), each holding its own
    /// (already-capped) event array. 64 because the consumer is the
    /// expanded panel, which renders one row per stream and is already
    /// unreadable past ~20 rows — this bounds the per-entry metadata cost
    /// without ever being the binding constraint in practice.
    static let maxSubagentStreams = 64

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
    /// Enforces bounded retention on every axis: the per-stream event cap
    /// (`maxEventsPerStream`), the subagent stream *entry* cap
    /// (`maxSubagentStreams`, evicting oldest-finished-first — see
    /// `evictOverEntryCapIfPossible`), and the store-wide event budget
    /// (`maxTotalEvents`, see `reclaimIfOverBudget`).
    ///
    /// Returns `true` exactly when this event's `seq` reveals a gap versus
    /// the last `seq` seen for its stream: `seq` present, a prior `seq` was
    /// already recorded for this stream, and the new value is not exactly
    /// one more than the prior value. A `nil` `seq` (old daemon build, or
    /// the pre-`seq` wire shape) never counts as a gap — treat "can't tell"
    /// as "don't false-alarm". The first event ever ingested into a given
    /// stream never counts as a gap, regardless of its `seq`, because there
    /// is nothing yet to compare it against — this includes a stream that
    /// was just recreated after its prior entry was evicted under entry-cap
    /// pressure: eviction clears its `seq` baseline along with the rest of
    /// its state (see `evictOverEntryCapIfPossible`), so a recreated stream
    /// can never falsely report a gap and trigger a spurious snapshot
    /// request.
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
            if let count = subagentsByAgentId[agentId]?.events.count, count > Self.maxEventsPerStream {
                subagentsByAgentId[agentId]?.events.removeFirst()
            }
            if event.kind == "subagent_stop" {
                subagentsByAgentId[agentId]?.finished = true
            }
            evictOverEntryCapIfPossible()
        } else {
            if main == nil {
                // D4: capture the main stream's agentType (the real named
                // agent, e.g. "perri") on creation, mirroring how subagent
                // streams already do this above — it was previously
                // hardcoded to nil, discarding an identity the wire
                // actually carries and forcing the ticker to fall back to
                // `agent` (a tool_use event's tool name, e.g. "SendMessage"),
                // which produced both a bare "Agent" fallback and a doubled
                // "SendMessage: SendMessage: …" display (see tickerSummary).
                main = ActivityAgentStream(agentId: nil, agentType: event.agentType, parentAgentId: nil, events: [], finished: false)
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

    // MARK: - Bounded retention: subagent stream entry cap (RC2)

    /// If the number of *entries* in `subagentsByAgentId` exceeds
    /// `maxSubagentStreams`, evicts the oldest entry (by `subagentOrder`)
    /// whose `finished` flag is `true` — removing it from
    /// `subagentsByAgentId`, `subagentOrder`, **and** `lastSeqByStreamKey`
    /// together, so a later event for the same `agentId` recreates a clean
    /// stream rather than resurrecting a stale `seq` baseline.
    ///
    /// Deliberately never evicts merely because a stream just finished —
    /// only because the store is over the entry-count budget. If every
    /// retained entry is still running, evicts nothing: a running
    /// subagent's history is exactly what an operator would want to
    /// inspect, and the event-count budget (`maxTotalEvents`) already
    /// bounds memory regardless of how many running entries pile up.
    private mutating func evictOverEntryCapIfPossible() {
        while subagentOrder.count > Self.maxSubagentStreams {
            guard let victimIndex = subagentOrder.firstIndex(where: { subagentsByAgentId[$0]?.finished == true }) else {
                return // every retained entry is still running — evict nothing
            }
            let victim = subagentOrder.remove(at: victimIndex)
            subagentsByAgentId.removeValue(forKey: victim)
            lastSeqByStreamKey.removeValue(forKey: victim)
        }
    }

    // MARK: - Bounded retention: store-wide event budget

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

    /// Total retained events across the main stream and every subagent
    /// stream combined. Internal (not private) so tests can assert the
    /// aggregate bound directly — this type has dual `Sources`/`TestSources`
    /// membership, so internal visibility is all a test needs.
    var totalEventCount: Int {
        (main?.events.count ?? 0) + subagentsByAgentId.values.reduce(0) { $0 + $1.events.count }
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

    /// One recent event paired with the display name of whichever stream
    /// produced it — see `mostRecentRunningActivity`.
    private struct RecentActivity {
        let agentLabel: String
        let event:      ActivityEvent
    }

    /// D3: the most recent event across the main stream and every currently
    /// *running* (unfinished) subagent stream, so `tickerSummary`'s
    /// subagents-running branch can show what's actually happening instead
    /// of a static count. `nil` only when there is nothing to show at all —
    /// in practice unreachable whenever `runningSubagentCount > 0`, since a
    /// subagent stream is only ever created (and only ever counts as
    /// running) once it has logged at least one event, but `tickerSummary`
    /// still handles it defensively rather than assuming the invariant.
    private var mostRecentRunningActivity: RecentActivity? {
        var candidates: [RecentActivity] = []
        if let last = main?.events.last {
            candidates.append(RecentActivity(agentLabel: Self.mainAgentLabel(agentType: main?.agentType, fallback: last.agent), event: last))
        }
        for sub in subagentStreams where !sub.finished {
            guard let last = sub.events.last else { continue }
            candidates.append(RecentActivity(agentLabel: sub.agentType ?? "subagent", event: last))
        }
        return candidates.max { $0.event.ts < $1.event.ts }
    }

    /// D4: the main stream's display name. Prefers `agentType` (the real
    /// named agent, e.g. "perri") — capitalized to match this codebase's
    /// existing display convention for turning a stored-lowercase agent
    /// identifier into display text (`Focus.displayName`'s
    /// `agentTag.capitalized`) — over `fallback` (the raw `agent` field,
    /// which on a `tool_use` event is only ever the tool's name, e.g.
    /// "SendMessage"). Falls back to `fallback` unmodified when `agentType`
    /// is `nil` or empty, rather than blanking out.
    private static func mainAgentLabel(agentType: String?, fallback: String) -> String {
        guard let agentType, !agentType.isEmpty else { return fallback }
        return agentType.capitalized
    }

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
    /// - One or more subagents running → the most recent event across the
    ///   main stream and every running subagent stream (D3), formatted
    ///   `"<agent>: <summary> · N agents active"`, so the longest-running,
    ///   most opaque operation is exactly when the operator learns the most,
    ///   not the least. Falls back to the bare count when there is truly
    ///   nothing yet to show (see `mostRecentRunningActivity`).
    var tickerSummary: String {
        let running = runningSubagentCount
        if running > 0 {
            let suffix = "\(running) agent\(running == 1 ? "" : "s") active"
            guard let recent = mostRecentRunningActivity else { return suffix }
            return "\(recent.agentLabel): \(Self.clip(recent.event.summary)) · \(suffix)"
        }
        guard let lastMainEvent = main?.events.last else {
            return "⚙ —"
        }
        return "⚙ \(Self.mainAgentLabel(agentType: main?.agentType, fallback: lastMainEvent.agent)): \(Self.clip(lastMainEvent.summary))"
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

// MARK: - ActivityStreamStore

/// Tag-keyed layer holding one `ActivityStreamModel` per focus tag (RC3 in
/// the retention bug doc — `AppStore.activityModels`'s entry count was
/// itself unbounded, growing by one entry per focus tag ever seen, forever).
///
/// Bounds the *number of tracked tags*, independent of `ActivityStreamModel`'s
/// own per-tag event bounds above. Eviction is LRU by last ingest, and never
/// evicts the tag just touched nor `unattributedTag` — the operator's own
/// current focus (or the catch-all unattributed bucket) must never be the
/// one that silently goes quiet just because it hasn't ingested recently.
/// An evicted tag isn't gone forever: `model(for:)` returns a fresh, empty
/// model for it, rendering the same neutral "no events yet" state as a tag
/// that's never been seen — never stale text — and it repopulates on that
/// focus's next event.
struct ActivityStreamStore {

    /// Cap on the number of tracked focus tags. 32 is generous headroom
    /// over the sidebar's realistic focus count; the point is a ceiling,
    /// not a tight budget.
    static let maxTrackedFocusTags = 32

    /// Key an event is stored under when the daemon could not attribute it
    /// to a known focus. Mirrors `AppStore.unattributedActivityKey`, which
    /// is defined in terms of this constant (`AppStore.swift` isn't part of
    /// this file's dual `Sources`/`TestSources` membership, so the
    /// canonical value lives here and `AppStore` aliases it).
    static let unattributedTag = "__unattributed__"

    // MARK: - State

    private var modelsByTag: [String: ActivityStreamModel] = [:]
    /// Least-recently-touched first; touching a tag (ingest or replace)
    /// moves it to the end.
    private var tagOrder: [String] = []

    // MARK: - Init

    init() {}

    // MARK: - Ingest

    /// Routes `event` to `tag`'s model (creating an empty one if `tag`
    /// hasn't been seen before), marks `tag` most-recently-touched, and
    /// evicts down to `maxTrackedFocusTags` if this pushed the store over
    /// budget. Returns the underlying model's gap-detection result, exactly
    /// as `ActivityStreamModel.ingest(_:)` would.
    @discardableResult
    mutating func ingest(_ event: ActivityEvent, tag: String) -> Bool {
        var model = modelsByTag[tag] ?? ActivityStreamModel()
        let gap = model.ingest(event)
        modelsByTag[tag] = model
        touch(tag)
        evictIfNeeded(justTouched: tag)
        return gap
    }

    /// Wholesale-replaces `tag`'s model — the shape a daemon snapshot
    /// rebuild needs (replay every event of every stream into a fresh
    /// model, then swap it in for `tag` in one step). Leaves every other
    /// tag's model untouched.
    mutating func replace(tag: String, with model: ActivityStreamModel) {
        modelsByTag[tag] = model
        touch(tag)
        evictIfNeeded(justTouched: tag)
    }

    // MARK: - Queries

    /// The `ActivityStreamModel` for `tag`, or an empty (neutral "waiting")
    /// model if nothing has arrived for it yet — whether `tag` has never
    /// been seen, or its entry was since evicted under tag-count pressure.
    func model(for tag: String) -> ActivityStreamModel {
        modelsByTag[tag] ?? ActivityStreamModel()
    }

    /// Number of focus tags currently tracked. Exposed so tests can assert
    /// the tag-count bound directly.
    var trackedTagCount: Int { modelsByTag.count }

    // MARK: - LRU bookkeeping

    private mutating func touch(_ tag: String) {
        if let index = tagOrder.firstIndex(of: tag) {
            tagOrder.remove(at: index)
        }
        tagOrder.append(tag)
    }

    /// While tracking more tags than `maxTrackedFocusTags`, evicts the
    /// least-recently-touched tag that isn't `tag` (the one just ingested
    /// into / replaced — never evict the tag that caused the overflow) and
    /// isn't `unattributedTag` (never evicted, regardless of recency).
    private mutating func evictIfNeeded(justTouched tag: String) {
        while modelsByTag.count > Self.maxTrackedFocusTags {
            guard let victimIndex = tagOrder.firstIndex(where: { $0 != tag && $0 != Self.unattributedTag }) else {
                return // nothing left that's safe to evict
            }
            let victim = tagOrder.remove(at: victimIndex)
            modelsByTag.removeValue(forKey: victim)
        }
    }
}
