import Foundation

/// The Sentry tab. Until its slice lands the source reports "Coming soon" and the
/// surface shows that state; this minimal config lists whatever arrives.
enum TeriSentryTab {
    static let config = TeriTabConfig(
        tab: .sentry,
        sourceName: "Sentry",
        list: .generic(sourceLabel: "Sentry"),
        emptyMessage: "No unresolved Sentry issues.")
}
