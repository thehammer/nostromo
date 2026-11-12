import Combine
import Foundation
import NostromoKit

/// A snapshot of the already-held data the built-in rows' badges are computed from.
/// Plain values, so the model needs no `AppStore` and can be tested headlessly.
struct BadgeInputs {
    var fredMailbox: MailboxSnapshot?
    var fredCalendar: CalendarSnapshot?
    var teriTodos: TeriTodosSnapshot?
    var motherStatus: MotherStatus
    var perriQueueCount: Int
    var perriQueueStale: Bool
    var perriQueueError: String?
    var perriQueueLoading: Bool
}

/// Which pill a "needs you" item feeds (see `SidebarBadgeModel.needsYouClass(of:)`).
enum NeedsYouClass: Equatable { case blocking, waiting, excluded }

/// Per-focus-tag counts for the two pills.
struct NeedsYouCounts: Equatable {
    var blocking: [String: Int] = [:]
    var waiting: [String: Int] = [:]
}

/// The badge logic behind `TabBarView`: computes each built-in row's badge from
/// `BadgeInputs`, projects them per tag, and owns the click deep links and the
/// refresh debounce. `TabBarView` only applies the results to its rows.
struct SidebarBadgeModel {
    private var registry = FocusBadgeRegistry()
    /// Tags the needs-you source last published counts for.
    private var needsYouTags: Set<String> = []
    private static let needsYouSource = "needs-you"

    /// Publish what is blocked on, or waiting for, the operator per focus tag (see `NeedsYouClass`).
    /// Tags missing from both maps (or at zero) lose their pills. Any producer's items may feed the
    /// snapshot these come from (approvals, the tracker's "Waiting on you" strip, Mother).
    mutating func setNeedsYou(_ counts: NeedsYouCounts) {
        let blocking = counts.blocking.filter { $0.value > 0 }
        let waiting = counts.waiting.filter { $0.value > 0 }
        let live = Set(blocking.keys).union(waiting.keys)
        for tag in needsYouTags.subtracting(live) {
            registry.clear(tag: tag, sourceKey: Self.needsYouSource)
        }
        for tag in live {
            registry.publish(tag: tag, sourceKey: Self.needsYouSource,
                             badge: .needsYou(blocking: blocking[tag] ?? 0, waiting: waiting[tag] ?? 0))
        }
        needsYouTags = live
    }

    /// Which pill an item feeds. Exhaustive on purpose: a new `NeedsYouReason` has to be classified here.
    /// BLOCKING: an agent is stopped until the operator acts (a pending approval). WAITING: nothing is
    /// stalled, but something wants the operator. EXCLUDED: open decisions already show the purple
    /// attention dot.
    static func needsYouClass(of reason: NeedsYouReason) -> NeedsYouClass {
        switch reason {
        case .approvalPending: return .blocking
        case .decisionOpen: return .excluded
        case .motherHold, .motherAwaiting, .motherAttention, .trackerWaiting, .other: return .waiting
        }
    }

    /// Per-focus blocking and waiting counts from the app-wide "needs you" snapshot. Only items about a
    /// focus count. `approvalPending(n)` counts as n (the approvals producer raises one `(1)` per request).
    static func needsYouCounts(from snapshot: NeedsYouSnapshot) -> NeedsYouCounts {
        var counts = NeedsYouCounts()
        for item in snapshot.items {
            guard case .focus(let tag) = item.source else { continue }
            switch needsYouClass(of: item.reason) {
            case .blocking:
                var weight = 1
                if case .approvalPending(let n) = item.reason { weight = max(1, n) }
                counts.blocking[tag, default: 0] += weight
            case .waiting:
                counts.waiting[tag, default: 0] += 1
            case .excluded:
                break
            }
        }
        return counts
    }

    /// Recompute and publish the badges for the built-in focuses.
    mutating func update(_ inputs: BadgeInputs, now: Date, calendar: Calendar = BadgeProviders.chicago,
                         enabled: EnabledAgents = .all) {
        let published: [(tag: String, badge: FocusBadge?)] = [
            ("fred", BadgeProviders.fred(mailbox: inputs.fredMailbox, calendar: inputs.fredCalendar, now: now)),
            ("mother", BadgeProviders.mother(inputs.motherStatus)),
            ("perri", BadgeProviders.perri(queueCount: inputs.perriQueueCount, stale: inputs.perriQueueStale,
                                           error: inputs.perriQueueError, loading: inputs.perriQueueLoading)),
            ("teri", BadgeProviders.teri(todos: inputs.teriTodos, now: now, calendar: calendar)),
        ]
        // A disabled agent publishes nil, so a hidden row can never raise attention.
        for (tag, badge) in published {
            registry.publish(tag: tag, sourceKey: tag, badge: enabled.isEnabled(tag) ? badge : nil)
        }
    }

    func badge(for tag: String) -> FocusBadge? { registry.badge(for: tag) }

    /// Tags needing the operator because of a badge (e.g. overdue todos, a meeting now).
    var attentionTags: Set<String> { registry.attentionTags }

    /// Attention tags from the store (pending decisions) plus those from badges.
    func combinedAttentionTags(storeTags: Set<String>) -> Set<String> {
        storeTags.union(registry.attentionTags)
    }

    /// Where a click on a focus's count pill should land, beyond switching to the focus.
    static func deepLink(for focus: Focus) -> FocusDeepLinkTarget? {
        guard focus.isBuiltIn else { return nil }
        switch focus.agentTag.lowercased() {
        case "teri": return .teriTab("todos")
        case "fred": return .fredInbox
        default: return nil
        }
    }

    /// Fires once after `interval` of quiet across `sources` (a burst of changes → one refresh).
    static func debouncedRefresh<S: Scheduler>(
        sources: [AnyPublisher<Void, Never>], interval: S.SchedulerTimeType.Stride, scheduler: S
    ) -> AnyPublisher<Void, Never> {
        Publishers.MergeMany(sources).debounce(for: interval, scheduler: scheduler).eraseToAnyPublisher()
    }
}

/// Whether the Perri queue the Mac holds can be trusted for the sidebar badge.
///
/// The daemon's `perri_state` frame carries no stale/error flag, so the honest signals are the
/// connection itself and whether a frame has arrived since it came up: a dropped connection
/// leaves the old queue in memory (stale: never show its count as if fresh), and a fresh
/// connection has not delivered a queue yet (loading). A `perri_state` frame clears both.
struct PerriQueueHealth: Equatable {
    private(set) var stale = false
    private(set) var loading = true

    mutating func connectionChanged(_ connected: Bool) {
        if connected {
            stale = false
            loading = true
        } else {
            stale = true
            loading = false
        }
    }

    mutating func frameArrived() {
        stale = false
        loading = false
    }
}
