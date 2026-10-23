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
    private let publish: ([NeedsYouItem]) -> Void
    private var subscription: AnyCancellable?

    /// `publish` replaces everything the approvals producer has raised (an empty list withdraws it).
    init(store: ApprovalStore, publish: @escaping ([NeedsYouItem]) -> Void) {
        self.store = store
        self.publish = publish
        subscription = store.changes.sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// Re-read the store and publish what is waiting.
    func refresh() {
        publish(ApprovalsNeedsYouProducer.items(pending: store.pendingRequests()))
    }
}
