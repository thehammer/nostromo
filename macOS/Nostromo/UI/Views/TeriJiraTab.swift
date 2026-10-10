import Foundation

/// The Jira tab. Until its slice lands the source reports "Coming soon" and the
/// surface shows that state; this minimal config lists whatever arrives.
enum TeriJiraTab {
    static let config = TeriTabConfig(
        tab: .jira,
        sourceName: "Jira",
        list: .generic(sourceLabel: "Jira"),
        emptyMessage: "No Jira issues assigned to you.")
}
