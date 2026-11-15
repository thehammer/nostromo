import XCTest

// SR1, host lock. Which URLs may be a top-level document in the Perri review side pane: exact host match,
// https only, default port, no userinfo. A look-alike must never pass.

final class ReviewPaneHostsTests: XCTestCase {

    /// A string Foundation cannot parse becomes a URL no rule accepts, so a rejection row can never crash.
    private func url(_ s: String) -> URL { URL(string: s) ?? URL(string: "unparseable:")! }
    private let plain = ReviewPaneHosts(jiraSite: nil)
    private let withJira = ReviewPaneHosts(jiraSite: "carefeed.atlassian.net")

    // MARK: Allowed

    func testGitHubPagesAreAllowed() {
        for s in ["https://github.com/", "https://github.com/acme/web/pull/7", "https://github.com/acme/web/pull/7/files",
                  "https://github.com/acme/web/pull/7?w=1#diff-abc", "https://github.com/login"] {
            XCTAssertTrue(plain.isAllowed(url(s)), s)
        }
    }

    func testTheSignInHostsAreAllowed() {
        for s in ["https://id.atlassian.com/login", "https://auth.atlassian.com/authorize",
                  "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"] {
            XCTAssertTrue(plain.isAllowed(url(s)), s)
        }
    }

    func testAnUppercaseHostIsAccepted() {
        XCTAssertTrue(plain.isAllowed(url("https://GITHUB.COM/acme/web")))
        XCTAssertTrue(plain.isAllowed(url("https://GitHub.Com/")))
        XCTAssertTrue(plain.isAllowed(url("HTTPS://github.com/")), "the scheme's case does not matter either")
    }

    // MARK: Rejected

    func testLookAlikeHostsAreRejected() {
        for s in ["https://github.com.evil.example/", "https://evilgithub.com/", "https://gist.github.com/",
                  "https://api.github.com/", "https://www.github.com/", "https://raw.githubusercontent.com/x",
                  "https://github.com.cn/", "https://notgithub.com/", "https://github.co/", "https://github.com./"] {
            XCTAssertFalse(plain.isAllowed(url(s)), s)
        }
    }

    func testAnExplicitPortIsRejected() {
        XCTAssertFalse(plain.isAllowed(url("https://github.com:8443/x")))
        XCTAssertFalse(plain.isAllowed(url("https://github.com:443/x")), "even the default port, when written out")
        XCTAssertFalse(plain.isAllowed(url("https://id.atlassian.com:444/")))
    }

    func testUserinfoIsRejectedInEitherDirection() {
        XCTAssertFalse(plain.isAllowed(url("https://github.com@evil.example/")), "the real host is evil.example")
        XCTAssertFalse(plain.isAllowed(url("https://evil.example@github.com/")), "userinfo on an allowed host")
        XCTAssertFalse(plain.isAllowed(url("https://user:pass@github.com/")))
        XCTAssertFalse(plain.isAllowed(url("https://:pass@github.com/")))
    }

    func testNonHttpsSchemesAreRejectedOnAnAllowedHost() {
        for s in ["http://github.com/", "ftp://github.com/", "file://github.com/etc/passwd", "ws://github.com/",
                  "wss://github.com/", "javascript://github.com/%0Aalert(1)", "data://github.com/x", "blob://github.com/x"] {
            XCTAssertFalse(plain.isAllowed(url(s)), s)
        }
    }

    func testAURLWithNoHostIsRejected() {
        for s in ["about:blank", "https:///path", "mailto:a@github.com", "data:text/plain,hello"] {
            XCTAssertFalse(plain.isAllowed(url(s)), s)
        }
    }

    // MARK: Jira site

    func testTheJiraSiteIsAllowedOnlyWhenConfigured() {
        let jiraURL = url("https://carefeed.atlassian.net/browse/CORE-1")
        XCTAssertFalse(plain.isAllowed(jiraURL), "no Jira site configured")
        XCTAssertTrue(withJira.isAllowed(jiraURL))
    }

    func testOnlyTheConfiguredJiraSiteIsAllowed() {
        XCTAssertFalse(withJira.isAllowed(url("https://other.atlassian.net/browse/X-1")))
        XCTAssertFalse(withJira.isAllowed(url("https://atlassian.net/")))
        XCTAssertFalse(withJira.isAllowed(url("https://carefeed.atlassian.net.evil.example/")))
        XCTAssertFalse(withJira.isAllowed(url("https://evil-carefeed.atlassian.net/")))
        XCTAssertTrue(withJira.isAllowed(url("https://github.com/")), "configuring Jira does not drop GitHub")
    }

    func testTheJiraSiteIsNotNormalised() {
        XCTAssertNil(ReviewPaneHosts(jiraSite: "  Carefeed.Atlassian.NET ").jiraHost, "the daemon sends a bare lowercase host")
        XCTAssertNil(ReviewPaneHosts(jiraSite: "Carefeed.Atlassian.NET").jiraHost)
        XCTAssertNil(ReviewPaneHosts(jiraSite: "").jiraHost)
        XCTAssertNil(ReviewPaneHosts(jiraSite: "   ").jiraHost)
        XCTAssertNil(ReviewPaneHosts(jiraSite: nil).jiraHost)
    }

    func testAJiraSiteIsAcceptedAsExactlyOneLowercaseLabelOnAtlassianNet() {
        for site in ["carefeed.atlassian.net", "acme-corp2.atlassian.net", "a.atlassian.net"] {
            let hosts = ReviewPaneHosts(jiraSite: site)
            XCTAssertEqual(hosts.jiraHost, site, site)
            XCTAssertTrue(hosts.isAllowed(url("https://\(site)/browse/CORE-1")), site)
        }
    }

    /// The site arrives from the daemon's configuration and becomes a host the pane will load and keep
    /// signed in. Anything that is not exactly `<label>.atlassian.net` is no site at all: the pane then
    /// allows no Jira host, for the value as written and for the host it might have been meant to be.
    func testAJiraSiteThatIsNotABareAtlassianNetLabelIsRefusedAndAllowsNoHost() {
        let intended = "https://carefeed.atlassian.net/browse/CORE-1"
        let refused = [
            "evil.example", "github.com.evil.example", "a.b.atlassian.net", "atlassian.net",
            "Carefeed.Atlassian.NET", " carefeed.atlassian.net ", "carefeed.atlassian.net.", "xn--abc.atlassian.net",
            "carefeed.atlassian.net:8443", "carefeed.atlassian.net/path", "user@carefeed.atlassian.net",
            "https://carefeed.atlassian.net", "carefeed.atlassian.net.evil.example",
            "carefeed_x.atlassian.net", "carefeed.atlassian.com", "carefeed.atlassian.net?x=1", "carefeed.atlassian.net#f",
        ]
        for site in refused {
            let hosts = ReviewPaneHosts(jiraSite: site)
            XCTAssertNil(hosts.jiraHost, "refused: \"\(site)\"")
            XCTAssertFalse(hosts.isAllowed(url("https://\(site)/browse/CORE-1")), "no URL on the host as written: \"\(site)\"")
            XCTAssertFalse(hosts.isAllowed(url(intended)), "nor on carefeed.atlassian.net: \"\(site)\"")
        }
        let evil = ReviewPaneHosts(jiraSite: "evil.example")
        XCTAssertFalse(evil.isAllowed(url("https://evil.example/login")), "an off-list site never becomes a host the pane loads")
        XCTAssertTrue(evil.isAllowed(url("https://github.com/")), "GitHub is unaffected")
    }

    /// `$` in an ICU pattern also matches before a trailing line break, so the pattern alone lets
    /// "carefeed.atlassian.net\n" through.
    func testAJiraSiteWithALineBreakAroundItIsRefused() {
        for site in ["carefeed.atlassian.net\n", "carefeed.atlassian.net\r\n", "\ncarefeed.atlassian.net", "carefeed\n.atlassian.net"] {
            XCTAssertNil(ReviewPaneHosts(jiraSite: site).jiraHost, "refused: \(site.debugDescription)")
        }
    }

    func testAnEmptyJiraSiteAllowsNoHost() {
        let empty = ReviewPaneHosts(jiraSite: "")
        XCTAssertFalse(empty.isAllowed(url("https://carefeed.atlassian.net/")))
        XCTAssertFalse(empty.isAllowed(url("https:///x")))
    }

    func testJiraRulesAreTheSameStrictRules() {
        XCTAssertFalse(withJira.isAllowed(url("http://carefeed.atlassian.net/")))
        XCTAssertFalse(withJira.isAllowed(url("https://carefeed.atlassian.net:8443/")))
        XCTAssertFalse(withJira.isAllowed(url("https://x@carefeed.atlassian.net/")))
        XCTAssertTrue(withJira.isAllowed(url("https://CAREFEED.atlassian.net/")))
    }

    // MARK: Scheme

    func testOnlyHttpsIsASecureScheme() {
        XCTAssertTrue(plain.isSecureScheme(url("https://example.com/")))
        XCTAssertTrue(plain.isSecureScheme(url("HTTPS://example.com/")))
        for s in ["http://example.com/", "file:///x", "data:text/plain,x", "javascript:1", "about:blank", "nostromo-fixture://github.com/"] {
            XCTAssertFalse(plain.isSecureScheme(url(s)), s)
        }
    }

    // MARK: Fixture scheme (DEBUG-only initializer)

    #if DEBUG
    func testTheFixtureSchemeCountsAsHttpsOnlyThroughTheTestInitializer() {
        let fixture = url("nostromo-fixture://github.com/acme/web/pull/7")
        XCTAssertFalse(plain.isAllowed(fixture), "production hosts never map a fixture scheme")
        XCTAssertFalse(withJira.isAllowed(fixture))

        let hosts = ReviewPaneHosts(jiraSite: nil, fixtureScheme: "nostromo-fixture")
        XCTAssertTrue(hosts.isAllowed(fixture))
        XCTAssertTrue(hosts.isSecureScheme(fixture))
        XCTAssertTrue(hosts.isAllowed(url("https://github.com/")), "https keeps working")
    }

    func testTheFixtureSchemeKeepsEveryOtherRule() {
        let hosts = ReviewPaneHosts(jiraSite: nil, fixtureScheme: "nostromo-fixture")
        XCTAssertFalse(hosts.isAllowed(url("nostromo-fixture://evil.example/x")))
        XCTAssertFalse(hosts.isAllowed(url("nostromo-fixture://github.com.evil.example/x")))
        XCTAssertFalse(hosts.isAllowed(url("nostromo-fixture://github.com:8443/x")))
        XCTAssertFalse(hosts.isAllowed(url("nostromo-fixture://evil.example@github.com/x")))
        XCTAssertFalse(hosts.isAllowed(url("nostromo-fixture://github.com@evil.example/x")))
        XCTAssertFalse(hosts.isAllowed(url("http://github.com/")), "http is still not secure")
        XCTAssertFalse(hosts.isAllowed(url("other-scheme://github.com/")), "only the named fixture scheme")
    }
    #endif
}
