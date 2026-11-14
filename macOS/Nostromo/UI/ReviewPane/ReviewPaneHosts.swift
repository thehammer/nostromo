import Foundation

/// Classifies a URL against SR1: which top-level hosts the review side pane may show.
///
/// Exact match on host, `https` only, default port, no userinfo. Subresources and subframes are the
/// page's business and are not classified here (subframes must still be https; see the policy).
struct ReviewPaneHosts: Equatable {

    /// Fixed allowed hosts. Evidence (checked 2026-11-14): the Carefeed GitHub org has no org SAML SSO
    /// (`github.com/orgs/Carefeed/sso` is a 404), so sign-in and two-factor pages are on `github.com`.
    /// `carefeed.atlassian.net/login` redirects to `id.atlassian.com`; `carefeed.com` is a Managed
    /// Entra domain, so an Atlassian hand-off to an IdP goes to `login.microsoftonline.com`.
    /// Adding a host is one line here.
    static let fixedHosts: [String] = [
        "github.com",
        "id.atlassian.com",
        "auth.atlassian.com",
        "login.microsoftonline.com",
    ]

    /// The configured Jira site (bare host), lowercased; nil when none is configured.
    let jiraHost: String?

    /// Fixture scheme counted as `https` (tests only; see `init(jiraSite:fixtureScheme:)`).
    private var fixtureScheme: String?

    init(jiraSite: String?) {
        let trimmed = jiraSite?.trimmingCharacters(in: .whitespaces).lowercased()
        jiraHost = (trimmed?.isEmpty == false) ? trimmed : nil
        fixtureScheme = nil
    }

    #if DEBUG
    /// Test-only: `fixtureScheme://github.com/...` counts as `https://github.com/...`. Compiled out of
    /// release builds, so production cannot enable the mapping.
    init(jiraSite: String?, fixtureScheme: String) {
        self.init(jiraSite: jiraSite)
        self.fixtureScheme = fixtureScheme
    }
    #endif

    /// Whether `url` has a secure scheme (https, or the test fixture scheme).
    func isSecureScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || (fixtureScheme != nil && scheme == fixtureScheme)
    }

    /// Whether `url` may be a top-level document in the pane.
    func isAllowed(_ url: URL) -> Bool {
        guard isSecureScheme(url) else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard url.port == nil else { return false }
        // Reject anything URLComponents would parse differently from URL (host spoofing via userinfo etc.).
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.user == nil, comps.password == nil,
              let host = comps.host, !host.isEmpty else { return false }
        let lower = host.lowercased()
        if Self.fixedHosts.contains(lower) { return true }
        return jiraHost.map { $0 == lower } ?? false
    }
}
