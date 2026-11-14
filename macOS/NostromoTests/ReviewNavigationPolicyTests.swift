import XCTest

// Perri side pane, slice 2: the navigation policy is the security core of the review side pane. The pane
// shows signed-in GitHub / Jira pages, so what a page may do with a navigation or a window request is
// pinned as a table. Every row names the security requirement it proves:
//
//   SR1  host lock: only https on the allowed hosts is ever shown in the pane (and a window's first
//        document may be about:blank).
//   SR2  a blocked top-level navigation tells the person which host was refused (the notice).
//   SR3  a person's click, never script, takes a link out of the pane to the default browser: the kind is
//        link or form AND a human event reached the view recently.
//   SR8  nothing downloads.
//
// The policy is pure, so no WebKit is involved here. `ReviewWebViewIntegrationTests` proves the same rules
// hold through a real web view.

private typealias Req = ReviewNavigationRequest
private typealias Decision = ReviewNavigationDecision

private func u(_ s: String) -> URL { URL(string: s)! }

private struct Row {
    let name: String
    let sr: String
    let request: ReviewNavigationRequest
    let expected: ReviewNavigationDecision
    /// The configured Jira site for this row, or nil.
    var jira: String? = nil
}

final class ReviewNavigationPolicyTests: XCTestCase {

    private let jira = "carefeed.atlassian.net"

    private func decide(_ request: ReviewNavigationRequest, jira: String?) -> ReviewNavigationDecision {
        ReviewNavigationPolicy(hosts: ReviewPaneHosts(jiraSite: jira)).decide(request)
    }

    // MARK: The table

    private var rows: [Row] {
        let gh = "https://github.com/acme/web/pull/7"
        let evil = "https://evil.example/landing"
        return [
            // --- SR1: only https is ever shown -------------------------------------------------------
            Row(name: "http main frame link is blocked", sr: "SR1",
                request: Req(url: u("http://github.com/acme/web/pull/7"), kind: .link, recentHumanInput: true),
                expected: .blockSilently),
            Row(name: "http main frame script navigation is blocked", sr: "SR1",
                request: Req(url: u("http://github.com/acme/web/pull/7"), kind: .other),
                expected: .blockSilently),
            Row(name: "http new window is blocked", sr: "SR1",
                request: Req(url: u("http://github.com/x"), opensNewWindow: true, kind: .link, recentHumanInput: true),
                expected: .blockSilently),
            Row(name: "file: main frame is blocked", sr: "SR1",
                request: Req(url: u("file:///etc/passwd"), kind: .other), expected: .blockSilently),
            Row(name: "file: new window is blocked", sr: "SR1",
                request: Req(url: u("file:///etc/passwd"), opensNewWindow: true, kind: .link, recentHumanInput: true),
                expected: .blockSilently),
            Row(name: "data: main frame is blocked", sr: "SR1",
                request: Req(url: u("data:text/html,hello"), kind: .other), expected: .blockSilently),
            Row(name: "javascript: main frame is blocked", sr: "SR1",
                request: Req(url: u("javascript:alert(1)"), kind: .link, recentHumanInput: true),
                expected: .blockSilently),
            Row(name: "blob: main frame is blocked", sr: "SR1",
                request: Req(url: u("blob:https://github.com/6c1d2e0e-0000-4000-8000-000000000000"), kind: .other),
                expected: .blockSilently),
            Row(name: "a custom scheme is blocked", sr: "SR1",
                request: Req(url: u("nostromo://pane/open"), kind: .link, recentHumanInput: true),
                expected: .blockSilently),
            Row(name: "ftp: is blocked", sr: "SR1",
                request: Req(url: u("ftp://github.com/file"), kind: .link, recentHumanInput: true),
                expected: .blockSilently),
            Row(name: "a scheme the policy was not told is a fixture scheme is blocked (production cannot map it)", sr: "SR1",
                request: Req(url: u("nostromo-fixture://github.com/acme/web/pull/7"), kind: .other),
                expected: .blockSilently),

            // --- SR1: about:blank only as a new window's first document ------------------------------
            Row(name: "about:blank as the first document of a new window opens a tab", sr: "SR1",
                request: Req(url: u("about:blank"), opensNewWindow: true, kind: .other, isInitialBlank: true),
                expected: .openInPane(newTab: true)),
            Row(name: "about:blank navigated to in the main frame is blocked", sr: "SR1",
                request: Req(url: u("about:blank"), kind: .other), expected: .blockSilently),
            Row(name: "about:blank new window that is not an initial document is blocked", sr: "SR1",
                request: Req(url: u("about:blank"), opensNewWindow: true, kind: .other, isInitialBlank: false),
                expected: .blockSilently),

            // --- SR1: an allowed host in the main frame is shown -------------------------------------
            Row(name: "allowed host: link", sr: "SR1",
                request: Req(url: u(gh), kind: .link, recentHumanInput: true), expected: .allow),
            Row(name: "allowed host: link without a human event", sr: "SR1",
                request: Req(url: u(gh), kind: .link), expected: .allow),
            Row(name: "allowed host: back/forward", sr: "SR1",
                request: Req(url: u(gh), kind: .backForward), expected: .allow),
            Row(name: "allowed host: reload", sr: "SR1",
                request: Req(url: u(gh), kind: .reload), expected: .allow),
            Row(name: "allowed host: script (other)", sr: "SR1",
                request: Req(url: u(gh), kind: .other), expected: .allow),
            Row(name: "allowed host: form", sr: "SR1",
                request: Req(url: u("https://github.com/login/session"), kind: .form, recentHumanInput: true),
                expected: .allow),
            Row(name: "sign-in host id.atlassian.com is allowed", sr: "SR1",
                request: Req(url: u("https://id.atlassian.com/login"), kind: .other), expected: .allow),
            Row(name: "sign-in host login.microsoftonline.com is allowed", sr: "SR1",
                request: Req(url: u("https://login.microsoftonline.com/common/oauth2"), kind: .other), expected: .allow),
            Row(name: "an uppercase scheme and host are allowed", sr: "SR1",
                request: Req(url: u("HTTPS://GITHUB.COM/acme/web/pull/7"), kind: .other), expected: .allow),
            Row(name: "the configured Jira site is allowed", sr: "SR1",
                request: Req(url: u("https://carefeed.atlassian.net/browse/CORE-1"), kind: .link, recentHumanInput: true),
                expected: .allow, jira: "carefeed.atlassian.net"),
            Row(name: "a Jira site that is not configured is outside the hosts (script)", sr: "SR2",
                request: Req(url: u("https://carefeed.atlassian.net/browse/CORE-1"), kind: .other),
                expected: .block(notice: "carefeed.atlassian.net")),
            Row(name: "a Jira site that is not configured is outside the hosts (click goes to the browser)", sr: "SR3",
                request: Req(url: u("https://carefeed.atlassian.net/browse/CORE-1"), kind: .link, recentHumanInput: true),
                expected: .openInDefaultBrowser(u("https://carefeed.atlassian.net/browse/CORE-1"))),
            Row(name: "a different Atlassian tenant is outside when another site is configured", sr: "SR2",
                request: Req(url: u("https://other.atlassian.net/browse/X-1"), kind: .other),
                expected: .block(notice: "other.atlassian.net"), jira: "carefeed.atlassian.net"),

            // --- SR2: outside the hosts, no human click: blocked with the host named ----------------
            Row(name: "script navigation outside the hosts is blocked and names the host", sr: "SR2",
                request: Req(url: u(evil), kind: .other), expected: .block(notice: "evil.example")),
            Row(name: "a redirect (other) outside the hosts is blocked even right after a click", sr: "SR3",
                request: Req(url: u(evil), kind: .other, recentHumanInput: true), expected: .block(notice: "evil.example")),
            Row(name: "link outside the hosts without a human event is blocked and names the host", sr: "SR2",
                request: Req(url: u(evil), kind: .link), expected: .block(notice: "evil.example")),
            Row(name: "form outside the hosts without a human event is blocked", sr: "SR2",
                request: Req(url: u(evil), kind: .form), expected: .block(notice: "evil.example")),
            Row(name: "back/forward outside the hosts is blocked even with recent input", sr: "SR3",
                request: Req(url: u(evil), kind: .backForward, recentHumanInput: true), expected: .block(notice: "evil.example")),
            Row(name: "reload outside the hosts is blocked even with recent input", sr: "SR3",
                request: Req(url: u(evil), kind: .reload, recentHumanInput: true), expected: .block(notice: "evil.example")),
            Row(name: "the notice names the host in lower case", sr: "SR2",
                request: Req(url: u("https://EVIL.Example/x"), kind: .other), expected: .block(notice: "evil.example")),
            Row(name: "a look-alike suffix host is outside the hosts", sr: "SR1",
                request: Req(url: u("https://github.com.evil.example/"), kind: .other),
                expected: .block(notice: "github.com.evil.example")),
            Row(name: "a look-alike prefix host is outside the hosts", sr: "SR1",
                request: Req(url: u("https://evilgithub.com/"), kind: .other), expected: .block(notice: "evilgithub.com")),
            Row(name: "an unlisted GitHub subdomain is outside the hosts", sr: "SR1",
                request: Req(url: u("https://gist.github.com/x"), kind: .other), expected: .block(notice: "gist.github.com")),
            Row(name: "userinfo spoof https://github.com@evil.example/ is judged by its real host", sr: "SR1",
                request: Req(url: u("https://github.com@evil.example/"), kind: .other), expected: .block(notice: "evil.example")),
            Row(name: "an allowed host with an explicit port is outside the hosts", sr: "SR1",
                request: Req(url: u("https://github.com:8443/x"), kind: .other), expected: .block(notice: "github.com")),
            Row(name: "an allowed host with userinfo is outside the hosts", sr: "SR1",
                request: Req(url: u("https://evil.example@github.com/"), kind: .other), expected: .block(notice: "github.com")),

            // --- SR3: a person's click takes it out to the default browser ---------------------------
            Row(name: "clicked link outside the hosts opens the default browser", sr: "SR3",
                request: Req(url: u(evil), kind: .link, recentHumanInput: true), expected: .openInDefaultBrowser(u(evil))),
            Row(name: "submitted form outside the hosts opens the default browser", sr: "SR3",
                request: Req(url: u(evil), kind: .form, recentHumanInput: true), expected: .openInDefaultBrowser(u(evil))),

            // --- new windows --------------------------------------------------------------------------
            Row(name: "new window to an allowed host opens a pane tab (link)", sr: "SR1",
                request: Req(url: u(gh), opensNewWindow: true, kind: .link, recentHumanInput: true),
                expected: .openInPane(newTab: true)),
            Row(name: "new window to an allowed host opens a pane tab (script, no click)", sr: "SR1",
                request: Req(url: u(gh), opensNewWindow: true, kind: .other), expected: .openInPane(newTab: true)),
            Row(name: "new window outside the hosts without a gesture is blocked", sr: "SR3",
                request: Req(url: u(evil), opensNewWindow: true, kind: .other), expected: .block(notice: "evil.example")),
            Row(name: "window.open (other) outside the hosts is not a gesture even right after a click", sr: "SR3",
                request: Req(url: u(evil), opensNewWindow: true, kind: .other, recentHumanInput: true),
                expected: .block(notice: "evil.example")),
            Row(name: "target=_blank link outside the hosts without a human event is blocked", sr: "SR3",
                request: Req(url: u(evil), opensNewWindow: true, kind: .link), expected: .block(notice: "evil.example")),
            Row(name: "clicked target=_blank link outside the hosts opens the default browser", sr: "SR3",
                request: Req(url: u(evil), opensNewWindow: true, kind: .link, recentHumanInput: true),
                expected: .openInDefaultBrowser(u(evil))),

            // --- SR8: downloads ------------------------------------------------------------------------
            Row(name: "a download from an allowed host is blocked", sr: "SR8",
                request: Req(url: u("https://github.com/acme/web/archive/main.zip"), kind: .link, recentHumanInput: true, isDownload: true),
                expected: .blockDownload(u("https://github.com/acme/web/archive/main.zip"))),
            Row(name: "a download outside the hosts is blocked, not opened", sr: "SR8",
                request: Req(url: u("https://evil.example/a.zip"), kind: .link, recentHumanInput: true, isDownload: true),
                expected: .blockDownload(u("https://evil.example/a.zip"))),
            Row(name: "a download in a subframe is blocked", sr: "SR8",
                request: Req(url: u("https://github.com/a.zip"), isMainFrame: false, kind: .other, isDownload: true),
                expected: .blockDownload(u("https://github.com/a.zip"))),
            Row(name: "a download in a new window is blocked", sr: "SR8",
                request: Req(url: u("https://github.com/a.zip"), opensNewWindow: true, kind: .link, recentHumanInput: true, isDownload: true),
                expected: .blockDownload(u("https://github.com/a.zip"))),

            // --- subframes -----------------------------------------------------------------------------
            Row(name: "an https subframe is allowed whatever its host", sr: "SR1",
                request: Req(url: u("https://evil.example/embed"), isMainFrame: false, kind: .other), expected: .allow),
            Row(name: "an http subframe is blocked", sr: "SR1",
                request: Req(url: u("http://github.com/embed"), isMainFrame: false, kind: .other), expected: .blockSilently),
            Row(name: "a data: subframe is blocked", sr: "SR1",
                request: Req(url: u("data:text/html,x"), isMainFrame: false, kind: .other), expected: .blockSilently),
            Row(name: "a javascript: subframe is blocked", sr: "SR1",
                request: Req(url: u("javascript:void(0)"), isMainFrame: false, kind: .other), expected: .blockSilently),
            Row(name: "about:blank in a subframe is allowed", sr: "SR1",
                request: Req(url: u("about:blank"), isMainFrame: false, kind: .other), expected: .allow),
        ]
    }

    func testEveryRuleOfThePolicyHoldsForItsRow() {
        let table = rows
        for row in table {
            let got = decide(row.request, jira: row.jira)
            XCTAssertEqual(got, row.expected, "[\(row.sr)] \(row.name)")
        }
    }

    func testTheTableCoversEverySecurityRequirementWithEnoughRows() {
        let table = rows
        XCTAssertGreaterThanOrEqual(table.count, 30)
        for sr in ["SR1", "SR2", "SR3", "SR8"] {
            XCTAssertGreaterThanOrEqual(table.filter { $0.sr == sr }.count, 3, "\(sr) needs its own rows")
        }
    }

    // MARK: Properties that hold across the whole input space

    private let allKinds: [ReviewNavigationRequest.Kind] = [.link, .form, .backForward, .reload, .other]

    func testNothingOutsideTheHostsEverLoadsInThePaneWhateverTheKindOrInput() {
        for kind in allKinds {
            for input in [true, false] {
                for newWindow in [true, false] {
                    let d = decide(Req(url: u("https://evil.example/x"), opensNewWindow: newWindow, kind: kind,
                                       recentHumanInput: input), jira: jira)
                    XCTAssertNotEqual(d, .allow, "kind \(kind) input \(input) newWindow \(newWindow)")
                    XCTAssertNotEqual(d, .openInPane(newTab: true), "kind \(kind) input \(input) newWindow \(newWindow)")
                }
            }
        }
    }

    func testOnlyALinkOrFormWithAHumanEventEverReachesTheDefaultBrowser() {
        for kind in allKinds {
            for input in [true, false] {
                let d = decide(Req(url: u("https://evil.example/x"), kind: kind, recentHumanInput: input), jira: jira)
                let reachesBrowser: Bool
                if case .openInDefaultBrowser = d { reachesBrowser = true } else { reachesBrowser = false }
                XCTAssertEqual(reachesBrowser, (kind == .link || kind == .form) && input,
                               "SR3: kind \(kind), human input \(input)")
            }
        }
    }

    func testNoNonHttpsSchemeEverLoadsWhateverTheKindOrFrame() {
        for scheme in ["http", "file", "data", "javascript", "blob", "ftp", "ws", "wss", "nostromo"] {
            for kind in allKinds {
                for main in [true, false] {
                    let d = decide(Req(url: u("\(scheme)://github.com/x"), isMainFrame: main, kind: kind, recentHumanInput: true), jira: jira)
                    XCTAssertEqual(d, .blockSilently, "\(scheme) kind \(kind) mainFrame \(main)")
                }
            }
        }
    }

    func testADownloadIsBlockedForEveryURLKindAndFrame() {
        for url in ["https://github.com/a.zip", "https://evil.example/a.zip", "http://github.com/a.zip", "data:text/plain,x"] {
            for kind in allKinds {
                for main in [true, false] {
                    let d = decide(Req(url: u(url), isMainFrame: main, kind: kind, recentHumanInput: true, isDownload: true), jira: jira)
                    XCTAssertEqual(d, .blockDownload(u(url)), "SR8: \(url) kind \(kind) mainFrame \(main)")
                }
            }
        }
    }

    // MARK: Fixture scheme (DEBUG only)

    #if DEBUG
    func testTheFixtureSchemeIsJudgedLikeHttpsWhenTheTestInitializerIsUsed() {
        let policy = ReviewNavigationPolicy(hosts: ReviewPaneHosts(jiraSite: nil, fixtureScheme: "nostromo-fixture"))
        XCTAssertEqual(policy.decide(Req(url: u("nostromo-fixture://github.com/acme/web/pull/7"), kind: .other)), .allow)
        XCTAssertEqual(policy.decide(Req(url: u("nostromo-fixture://evil.example/x"), kind: .other)),
                       .block(notice: "evil.example"))
        XCTAssertEqual(policy.decide(Req(url: u("nostromo-fixture://evil.example/x"), kind: .link, recentHumanInput: true)),
                       .openInDefaultBrowser(u("nostromo-fixture://evil.example/x")))
        XCTAssertEqual(policy.decide(Req(url: u("http://github.com/x"), kind: .link, recentHumanInput: true)), .blockSilently)
    }
    #endif
}
