import Foundation

/// Saves each Perri focus's side pane: width, tabs and active tab, under `reviewPane.v1.<tag>`.
/// Never cookies, never page text. A tab's last URL is kept only when it is on `github.com` or the Jira
/// site (sign-in URLs can carry one-time codes, SR4); otherwise the tab's start URL is kept.
struct ReviewPaneStore {

    struct SavedTab: Equatable {
        let repo: String
        let number: Int
        let target: ReviewTarget
        let startURL: URL
        let lastURL: URL
        let title: String

        init(repo: String, number: Int, target: ReviewTarget, startURL: URL, lastURL: URL, title: String) {
            self.repo = repo; self.number = number; self.target = target
            self.startURL = startURL; self.lastURL = lastURL; self.title = title
        }

        init(tab: ReviewTab, jiraSite: String?) {
            let hosts = ReviewPaneHosts(jiraSite: jiraSite)
            let host = tab.currentURL.host?.lowercased()
            let path = tab.currentURL.path.lowercased()
            let isSignInPath = path == "/login" || path.hasPrefix("/login/") || path.hasPrefix("/session")
                || path.hasPrefix("/authorize")
            let persistable = hosts.isAllowed(tab.currentURL)
                && (host == "github.com" || host == hosts.jiraHost) && !isSignInPath
            // A start URL is judged the same way: a sign-in popup opened straight to an IdP URL carrying
            // a one-time code must not reach the disk. Off-list start URLs fall back to the PR page.
            let startOK = hosts.isAllowed(tab.startURL)
                && (tab.startURL.host?.lowercased() == "github.com" || tab.startURL.host?.lowercased() == hosts.jiraHost)
            let fallback = ReviewPaneModel.defaultURL(pr: tab.pr, target: .conversation)
            let start = startOK ? Self.withoutQueryAndFragment(tab.startURL) : fallback
            self.init(repo: tab.pr.repo, number: tab.pr.number, target: tab.target, startURL: start,
                      lastURL: persistable ? Self.withoutQuery(tab.currentURL) : start, title: tab.title)
        }

        /// Query strings can carry one-time codes (SR4); the fragment (diff anchors) is kept.
        private static func withoutQuery(_ url: URL) -> URL {
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.query != nil else { return url }
            c.query = nil
            return c.url ?? url
        }

        /// A start URL keeps neither query nor fragment (`#access_token=` is as secret as `?code=`).
        private static func withoutQueryAndFragment(_ url: URL) -> URL {
            guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.query != nil || c.fragment != nil else { return url }
            c.query = nil
            c.fragment = nil
            return c.url ?? url
        }
    }

    struct Saved: Equatable {
        var widthFraction: Double
        var tabs: [SavedTab]
        var activeIndex: Int?
    }

    private let defaults: UserDefaults
    /// The configured Jira site, read when a tab's URL is judged for saving.
    let jiraSite: () -> String?

    init(defaults: UserDefaults = .standard, jiraSite: @escaping () -> String? = { AppStore.shared.perriJiraSite }) {
        self.defaults = defaults
        self.jiraSite = jiraSite
    }

    static func key(_ tag: String) -> String { "reviewPane.v1.\(tag)" }

    func save(tag: String, _ saved: Saved) {
        var dict: [String: Any] = ["width": saved.widthFraction]
        dict["tabs"] = saved.tabs.map { t -> [String: Any] in
            var d: [String: Any] = ["repo": t.repo, "number": t.number, "start": t.startURL.absoluteString,
                                    "last": t.lastURL.absoluteString, "title": t.title]
            switch t.target {
            case .conversation: d["target"] = "conversation"
            case .diff: d["target"] = "diff"
            case .ticket(let key): d["target"] = "ticket"; d["ticket"] = key
            case .page(let n): d["target"] = "page"; d["page"] = n
            }
            return d
        }
        if let i = saved.activeIndex { dict["active"] = i }
        defaults.set(dict, forKey: Self.key(tag))
    }

    func load(tag: String) -> Saved? {
        guard let dict = defaults.dictionary(forKey: Self.key(tag)) else { return nil }
        let tabs: [SavedTab] = (dict["tabs"] as? [[String: Any]] ?? []).compactMap { d in
            guard let repo = d["repo"] as? String, let number = d["number"] as? Int,
                  let start = (d["start"] as? String).flatMap(URL.init(string:)),
                  let last = (d["last"] as? String).flatMap(URL.init(string:)),
                  let title = d["title"] as? String else { return nil }
            let target: ReviewTarget
            switch d["target"] as? String {
            case "conversation": target = .conversation
            case "diff": target = .diff
            case "ticket": target = .ticket(d["ticket"] as? String ?? "")
            case "page": target = .page(d["page"] as? Int ?? 0)
            default: return nil
            }
            return SavedTab(repo: repo, number: number, target: target, startURL: start, lastURL: last, title: title)
        }
        return Saved(widthFraction: dict["width"] as? Double ?? ReviewPaneModel.defaultWidthFraction,
                     tabs: tabs, activeIndex: dict["active"] as? Int)
    }

    func remove(tag: String) { defaults.removeObject(forKey: Self.key(tag)) }
}
