import Foundation

/// The Repo docs tab. Until its slice lands the source reports "Coming soon" and the
/// surface shows that state; this minimal config lists whatever arrives.
enum TeriRepoDocsTab {
    static let config = TeriTabConfig(
        tab: .repoDocs,
        sourceName: "Repo docs",
        list: .generic(sourceLabel: "Repo docs"),
        emptyMessage: "No open bugs, features, ideas or todos in your repos.")
}
