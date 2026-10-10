import Foundation

/// Where a deep link into a built-in focus should land. Posted with
/// `Notification.Name.nostromoFocusDeepLink`; the Teri/Fred surfaces observe it.
enum FocusDeepLinkTarget: Equatable {
    /// A Teri tab, by its id (`todos`, `repo_docs`, `jira`, `sentry`, `picks`).
    case teriTab(String)
    case fredInbox
    case fredToday
}

extension Notification.Name {
    /// `object` is a `FocusDeepLinkTarget`.
    static let nostromoFocusDeepLink = Notification.Name("nostromo.focusDeepLink")
}

enum FocusDeepLink {
    /// Post a deep link for the surfaces to pick up.
    static func post(_ target: FocusDeepLinkTarget, center: NotificationCenter = .default) {
        center.post(name: .nostromoFocusDeepLink, object: target)
    }
}
