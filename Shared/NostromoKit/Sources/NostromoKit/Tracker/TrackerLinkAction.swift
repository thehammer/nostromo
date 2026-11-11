import Foundation

/// What clicking an item's link chip does (T6). Pure: the Mac performs it.
public enum TrackerLinkAction: Equatable {
    /// The daemon opens it as a `nostromo.show` would (`tracker_open_link`): a PR's conversation, a
    /// Jira ticket, a repo file at its line. Never moves the transcript.
    case openInPane(index: Int)
    /// The client opens the URL in the browser.
    case openURL(URL)
    /// Nothing to open (a Sentry or run reference with no URL).
    case inert

    public static func action(for link: TrackerLinkWire, index: Int) -> TrackerLinkAction {
        switch link.kind {
        case .pr, .jira, .file:
            return .openInPane(index: index)
        default:
            guard let text = link.url, let url = URL(string: text),
                  let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host?.isEmpty == false
            else { return .inert }
            return .openURL(url)
        }
    }
}

/// The quiet "as of 10:42" under a bound item whose source has gone silent.
public enum TrackerBoundFootnote {
    /// The footnote text, only for a badly stale source that has reported before.
    public static func text(_ bound: TrackerBoundWire?, timeZone: TimeZone) -> String? {
        guard let bound, bound.badlyStale else { return nil }
        guard let asOf = bound.asOf else { return "no report yet" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "as of " + formatter.string(from: asOf)
    }
}
