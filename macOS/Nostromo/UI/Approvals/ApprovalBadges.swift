import Combine
import Foundation
import NostromoKit

// AP3: approvals as a producer into the app-wide "needs you" source.
//
// Nothing here draws a badge or posts a notification. It tells `NeedsYouCoordinator` (the single
// owner of the Dock badge and the notifier) which requests are waiting, one item per request; the
// coordinator's snapshot then feeds the Dock badge, the sidebar pill (`SidebarBadgeModel`) and the
// notification (`ApprovalsNeedsYouContentBuilder`). Main thread only.

final class ApprovalBadges {

    private let store: ApprovalStore
    private let publish: ([NeedsYouItem], _ baseline: Bool) -> Void
    private var subscriptions: [AnyCancellable] = []

    /// `publish` replaces everything the approvals producer has raised (an empty list withdraws it).
    /// `baseline` is true once the daemon's first snapshot has been applied: that publish (even an empty
    /// one) is the notifier's baseline, so the requests a relaunch finds waiting do not alert. Before the
    /// snapshot the list is not the daemon's truth, and an empty pre-snapshot list must not baseline.
    init(store: ApprovalStore, publish: @escaping ([NeedsYouItem], _ baseline: Bool) -> Void) {
        self.store = store
        self.publish = publish
        subscriptions = [
            store.changes.sink { [weak self] _ in self?.refresh() },
            // A snapshot that touched nothing sends no `changes`; this is what carries the baseline then.
            store.snapshotHandled.sink { [weak self] in self?.refresh() },
        ]
        refresh()
    }

    /// Re-read the store and publish what is waiting.
    func refresh() {
        publish(ApprovalsNeedsYouProducer.items(pending: store.pendingRequests()), store.hasHandledSnapshot)
    }
}
