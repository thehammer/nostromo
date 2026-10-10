import Combine
import Foundation

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

/// The badge logic behind `TabBarView`: computes each built-in row's badge from
/// `BadgeInputs`, projects them per tag, and owns the click deep links and the
/// refresh debounce. `TabBarView` only applies the results to its rows.
struct SidebarBadgeModel {
    private var registry = FocusBadgeRegistry()

    /// Recompute and publish the badges for the built-in focuses.
    mutating func update(_ inputs: BadgeInputs, now: Date, calendar: Calendar = BadgeProviders.chicago) {
        let published: [(tag: String, badge: FocusBadge?)] = [
            ("fred", BadgeProviders.fred(mailbox: inputs.fredMailbox, calendar: inputs.fredCalendar, now: now)),
            ("mother", BadgeProviders.mother(inputs.motherStatus)),
            ("perri", BadgeProviders.perri(queueCount: inputs.perriQueueCount, stale: inputs.perriQueueStale,
                                           error: inputs.perriQueueError, loading: inputs.perriQueueLoading)),
            ("teri", BadgeProviders.teri(todos: inputs.teriTodos, now: now, calendar: calendar)),
        ]
        for (tag, badge) in published { registry.publish(tag: tag, sourceKey: tag, badge: badge) }
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
