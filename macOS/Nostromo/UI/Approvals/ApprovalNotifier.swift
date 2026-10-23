import AppKit
import Foundation
import NostromoKit

// AP3: what a click on an approval notification does.
//
// What the notification SAYS is `ApprovalsNeedsYouContentBuilder` (NostromoKit); it is posted and
// removed by the app-wide `NeedsYouNotifier`, with no Approve action. This file is only the
// click: a user act, so the app may come forward (the one place in the approvals code that
// does). It never answers anything: the person still reads the card and presses.
//
// `ApprovalWindowRouting` is injected so a test needs no windows.

/// Where a click lands. The real one drives the app's windows (`LiveApprovalRouter`).
protocol ApprovalWindowRouting: AnyObject {
    /// Bring the app forward. Called only from a click on a notification.
    func bringAppForward()
    /// Select the focus `tag` in the frontmost window, opening it there if no window shows it.
    func showFocus(tag: String)
    /// Put the card of `requestID` in view (expanded) in the windows showing `tag`.
    func showCard(requestID: String, tag: String)
}

final class ApprovalNotifier {

    private let router: ApprovalWindowRouting
    private let store: ApprovalStore

    init(router: ApprovalWindowRouting, store: ApprovalStore) {
        self.router = router
        self.store = store
    }

    /// A click on a notification (`userInfo` is the notification's). Returns false when it is not an
    /// approval notification, or the request is gone (the app still comes forward for a gone one,
    /// on the focus, if the tag is known: the click was a real act).
    @discardableResult
    func handleClick(userInfo: [AnyHashable: Any]) -> Bool {
        guard userInfo["producer"] as? String == ApprovalsNeedsYouProducer.name,
              let tag = userInfo["tag"] as? String, !tag.isEmpty else { return false }
        router.bringAppForward()
        router.showFocus(tag: tag)
        if let requestID = userInfo["requestId"] as? String, let entry = store.entry(id: requestID), !entry.isEnded {
            store.setCollapsed(requestID, false)
            router.showCard(requestID: requestID, tag: tag)
        }
        return true
    }

    /// Whether to show a banner while the app is active: not when the focus's card is already
    /// on screen in the key window.
    static func shouldPresent(userInfo: [AnyHashable: Any], cardIsVisible: (String) -> Bool) -> Bool {
        guard userInfo["producer"] as? String == ApprovalsNeedsYouProducer.name,
              let tag = userInfo["tag"] as? String else { return true }
        return !cardIsVisible(tag)
    }
}

/// Whether a "needs you" notification shows a banner while the app is active. Each producer has its own
/// "already on screen" test; one producer's visible view never hides another producer's notification
/// (an approval for another focus is not swallowed because the Mother view is open).
enum NeedsYouPresentation {
    static func showsBanner(userInfo: [AnyHashable: Any],
                            cardIsVisible: (String) -> Bool,
                            motherViewIsVisible: () -> Bool) -> Bool {
        if userInfo["producer"] as? String == ApprovalsNeedsYouProducer.name {
            return ApprovalNotifier.shouldPresent(userInfo: userInfo, cardIsVisible: cardIsVisible)
        }
        return !motherViewIsVisible()
    }
}

/// The app's windows as the router: the click brings the app forward and selects the focus
/// (the key window's layout switches to it; `focusSelectionRequests` is how the app already
/// asks for that), then shows the card.
final class LiveApprovalRouter: ApprovalWindowRouting {

    func bringAppForward() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func showFocus(tag: String) {
        guard let focus = FocusStore.shared.focuses.first(where: { $0.sessionTag == tag }) else { return }
        AppStore.shared.focusSelectionRequests.send(focus)
    }

    func showCard(requestID: String, tag: String) {
        // The card is an overlay of the focus's transcript pane: once the focus is selected it is in
        // view. The store was already told to expand it.
        ApprovalStore.shared.changes.send(tag)
    }
}

extension ApprovalNotifier {
    /// The app's one notifier, wired to the real windows.
    static let live = ApprovalNotifier(router: LiveApprovalRouter(), store: .shared)
}
