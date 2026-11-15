import Foundation

/// What a navigation or window request looks like to the policy. A plain value so the rules are
/// table-testable without WebKit.
struct ReviewNavigationRequest: Equatable {
    enum Kind: Equatable { case link, form, backForward, reload, other }

    var url: URL
    var isMainFrame: Bool
    /// The request opens a new window (target=_blank, window.open).
    var opensNewWindow: Bool
    var kind: Kind
    /// A person's click or key reached the web view within `ReviewWebView.gestureWindow`. Decided by
    /// Nostromo from real events, never by the page.
    var recentHumanInput: Bool
    var isDownload: Bool
    /// The initial document of a window the page just opened (`about:blank`).
    var isInitialBlank: Bool = false

    init(url: URL, isMainFrame: Bool = true, opensNewWindow: Bool = false, kind: Kind = .other,
         recentHumanInput: Bool = false, isDownload: Bool = false, isInitialBlank: Bool = false) {
        self.url = url; self.isMainFrame = isMainFrame; self.opensNewWindow = opensNewWindow
        self.kind = kind; self.recentHumanInput = recentHumanInput; self.isDownload = isDownload
        self.isInitialBlank = isInitialBlank
    }
}

enum ReviewNavigationDecision: Equatable {
    case allow
    /// A new window to an allowed host: open it as a side-pane tab.
    case openInPane(newTab: Bool)
    /// SR3: a person clicked out of the allowed hosts. The tab does not navigate.
    case openInDefaultBrowser(URL)
    /// SR2: blocked; the notice bar names `notice` (a host) and offers Open in Browser.
    case block(notice: String)
    /// Blocked without a notice naming a host (non-https schemes).
    case blockSilently
    /// SR8: cancelled; the tab shows the download notice.
    case blockDownload(URL)
}

/// The security core of the review side pane (SR1-SR3, SR8). Pure.
struct ReviewNavigationPolicy {
    let hosts: ReviewPaneHosts

    func decide(_ r: ReviewNavigationRequest) -> ReviewNavigationDecision {
        // SR8: never download.
        if r.isDownload { return .blockDownload(r.url) }

        // Subframes are the page's business, but must be https.
        if !r.isMainFrame && !r.opensNewWindow {
            return hosts.isSecureScheme(r.url) || r.url.absoluteString == "about:blank" ? .allow : .blockSilently
        }

        // SR1: a window's first document may be about:blank; its next navigation is judged again.
        if r.opensNewWindow, r.isInitialBlank, r.url.absoluteString == "about:blank" {
            return .openInPane(newTab: true)
        }
        // Not https: never loads (http, file, data, javascript, blob, custom schemes).
        guard hosts.isSecureScheme(r.url) else { return .blockSilently }

        if hosts.isAllowed(r.url) {
            return r.opensNewWindow ? .openInPane(newTab: true) : .allow
        }

        let host = r.url.host?.lowercased() ?? "unknown host"
        let userGesture = (r.kind == .link || r.kind == .form) && r.recentHumanInput
        if userGesture { return .openInDefaultBrowser(r.url) }
        return .block(notice: host)
    }
}
