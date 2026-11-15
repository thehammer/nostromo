import XCTest

// Perri side pane, slice 2: what a relaunch brings back, and what is never written down (SR4).
//
//   * the pane's width, its tabs and which one was active come back
//   * a tab's last URL is saved only when it is a GitHub or the configured Jira page; anything else
//     (a sign-in page can carry a one-time code) saves the tab's start URL instead
//   * a restored tab has no web view until it is shown: restoring loads nothing
//   * a popup that began as about:blank has nothing worth restoring
//
// Every test uses its own UserDefaults suite, removed afterwards: the real preferences are never touched.

@MainActor
final class ReviewPaneStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var jiraSite: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "ReviewPaneStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        jiraSite = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func makeStore() -> ReviewPaneStore {
        ReviewPaneStore(defaults: defaults, jiraSite: { [unowned self] in self.jiraSite })
    }

    private func url(_ s: String) -> URL { URL(string: s)! }
    private func pr(_ number: Int, _ repo: String = "acme/web") -> ReviewPR { ReviewPR(repo: repo, number: number) }

    private func model(tag: String = "perri-test") -> ReviewPaneModel {
        let m = ReviewPaneModel(tag: tag, store: makeStore())
        m.unsentCheck = { _ in false }
        return m
    }

    /// The URL a tab would come back with after a relaunch, given where it was when the app quit.
    private func restoredURL(whenAt current: String, start: String = "https://github.com/acme/web/pull/7") -> URL? {
        let first = model(tag: "perri-url")
        let tab = first.open(pr: pr(7), target: .conversation, url: url(start))
        tab.currentURL = url(current)
        first.persist()
        return model(tag: "perri-url").tabs.first?.currentURL
    }

    // MARK: Round trip

    func testWidthTabsAndTheActiveTabComeBack() {
        let first = model()
        first.open(pr: pr(7), target: .conversation)
        first.open(pr: pr(7), target: .diff)
        let ticket = first.open(pr: pr(7), target: .ticket("CORE-9"), url: url("https://github.com/acme/web/issues/9"), ticketOrder: 1)
        first.open(pr: pr(8, "acme/api"), target: .conversation)
        first.widthFraction = 0.37
        first.focus(ticket)

        let second = model()

        XCTAssertEqual(second.widthFraction, 0.37, accuracy: 0.0001)
        XCTAssertEqual(second.tabs.map { "\($0.pr.repo)#\($0.pr.number)" }, first.tabs.map { "\($0.pr.repo)#\($0.pr.number)" })
        XCTAssertEqual(second.tabs.map(\.target), first.tabs.map(\.target))
        XCTAssertEqual(second.tabs.map(\.startURL), first.tabs.map(\.startURL))
        XCTAssertEqual(second.tabs.map(\.title), first.tabs.map(\.title))
        XCTAssertEqual(second.activeTab?.target, .ticket("CORE-9"))
        XCTAssertEqual(second.activeTab?.pr, pr(7))
        XCTAssertTrue(second.isVisible)
    }

    func testAPageTabKeepsItsOpenOrderAcrossARestore() {
        let first = model()
        let opener = first.open(pr: pr(7), target: .conversation)
        first.openPage(from: opener, url: url("https://github.com/acme/web/issues/b"))
        first.openPage(from: opener, url: url("https://github.com/acme/web/issues/a"))
        let second = model()
        XCTAssertEqual(second.tabs.map { $0.startURL.lastPathComponent }, ["7", "b", "a"])
        let third = model()
        let more = third.openPage(from: third.tabs[0], url: url("https://github.com/acme/web/issues/c"))
        XCTAssertEqual(third.tabs.last?.id, more.id, "a page opened after the restore sorts after the restored pages")
    }

    func testNothingSavedMeansNoTabsAndTheDefaultWidth() {
        let m = model(tag: "perri-never-saved")
        XCTAssertFalse(m.isVisible)
        XCTAssertEqual(m.widthFraction, ReviewPaneModel.defaultWidthFraction)
    }

    func testTheWidthIsSavedAsSoonAsItChanges() {
        let m = model()
        m.widthFraction = 0.61
        XCTAssertEqual(model().widthFraction, 0.61, accuracy: 0.0001)
    }

    func testClosingTheLastTabSavesAnEmptyPane() {
        let m = model()
        let tab = m.open(pr: pr(7), target: .conversation)
        m.close(tab)
        XCTAssertFalse(model().isVisible, "a closed pane does not come back")
    }

    func testEachFocusTagIsSavedSeparately() {
        let a = model(tag: "perri-aaaa")
        let b = model(tag: "perri-bbbb")
        a.open(pr: pr(1), target: .conversation)
        b.open(pr: pr(2), target: .diff)
        a.widthFraction = 0.3
        XCTAssertEqual(model(tag: "perri-aaaa").tabs.map(\.pr.number), [1])
        XCTAssertEqual(model(tag: "perri-bbbb").tabs.map(\.pr.number), [2])
        XCTAssertEqual(model(tag: "perri-bbbb").widthFraction, ReviewPaneModel.defaultWidthFraction)
    }

    func testTheStoreKeepsEverythingUnderOneKeyPerFocus() {
        let m = model(tag: "perri-keyed")
        m.open(pr: pr(7), target: .conversation)
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("reviewPane.") }
        XCTAssertEqual(Array(keys), ["reviewPane.v1.perri-keyed"])
        XCTAssertNotNil(defaults.dictionary(forKey: "reviewPane.v1.perri-keyed"))
    }

    func testAnEntryWithAnUnreadableTargetIsDroppedAndTheRestComesBack() {
        defaults.set([
            "width": 0.4,
            "tabs": [
                ["repo": "acme/web", "number": 1, "start": "https://github.com/acme/web/pull/1",
                 "last": "https://github.com/acme/web/pull/1", "title": "#1 Conversation", "target": "conversation"],
                ["repo": "acme/web", "number": 2, "start": "https://github.com/acme/web/pull/2",
                 "last": "https://github.com/acme/web/pull/2", "title": "#2 ?", "target": "from-the-future"],
                ["repo": "acme/web", "number": 3],
            ],
        ] as [String: Any], forKey: "reviewPane.v1.perri-garbled")
        let m = model(tag: "perri-garbled")
        XCTAssertEqual(m.tabs.map(\.pr.number), [1])
        XCTAssertEqual(m.widthFraction, 0.4, accuracy: 0.0001)
    }

    func testForgettingAFocusRemovesItsSavedPane() {
        let store = makeStore()
        let m = ReviewPaneModel(tag: "perri-forget", store: store)
        m.open(pr: pr(7), target: .conversation)
        store.remove(tag: "perri-forget")
        XCTAssertNil(store.load(tag: "perri-forget"))
        XCTAssertFalse(model(tag: "perri-forget").isVisible)
    }

    // MARK: Restoring makes no web view

    func testARestoredTabHasNoWebViewUntilItIsShown() {
        let first = model()
        first.open(pr: pr(7), target: .conversation)
        first.open(pr: pr(7), target: .diff)
        first.open(pr: pr(8), target: .conversation)

        let restored = model()

        XCTAssertEqual(restored.tabs.count, 3)
        for tab in restored.tabs {
            XCTAssertNil(tab.controller, "#\(tab.pr.number) \(tab.title) must not have loaded anything")
            XCTAssertFalse(tab.hasWebView)
        }
    }

    // MARK: SR4: what a tab's last URL may be

    func testTheLastURLOnGitHubIsSaved() {
        let page = "https://github.com/acme/web/pull/7/files#diff-abc123"
        XCTAssertEqual(restoredURL(whenAt: page), url(page))
    }

    func testTheLastURLOnTheConfiguredJiraSiteIsSaved() {
        jiraSite = "carefeed.atlassian.net"
        let page = "https://carefeed.atlassian.net/browse/CORE-12"
        XCTAssertEqual(restoredURL(whenAt: page), url(page))
    }

    func testTheLastURLOnAJiraSiteThatIsNotConfiguredIsNotSaved() {
        jiraSite = nil
        let start = "https://github.com/acme/web/pull/7"
        XCTAssertEqual(restoredURL(whenAt: "https://carefeed.atlassian.net/browse/CORE-12", start: start), url(start))
    }

    func testAtlassianSignInURLsAreNeverSavedTheStartURLIsInstead() {
        let start = "https://github.com/acme/web/pull/7"
        for page in ["https://id.atlassian.com/login?continue=https%3A%2F%2Fcarefeed.atlassian.net&code=ONE-TIME",
                     "https://auth.atlassian.com/authorize?state=abc&code=ONE-TIME"] {
            jiraSite = "carefeed.atlassian.net"
            XCTAssertEqual(restoredURL(whenAt: page, start: start), url(start), page)
        }
    }

    func testMicrosoftSignInURLsAreNeverSavedTheStartURLIsInstead() {
        let start = "https://github.com/acme/web/pull/7"
        let page = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?client_id=x&code=ONE-TIME"
        XCTAssertEqual(restoredURL(whenAt: page, start: start), url(start))
    }

    /// The task's rule: a GitHub sign-in URL with a one-time code is never saved. A normal GitHub page is
    /// (see `testTheLastURLOnGitHubIsSaved`), so what tells them apart is the sign-in path.
    func testAGitHubSignInURLWithACodeIsNeverSavedTheStartURLIsInstead() {
        let start = "https://github.com/acme/web/pull/7"
        for page in ["https://github.com/login?return_to=%2Facme%2Fweb&code=ONE-TIME",
                     "https://github.com/login/device?code=ABCD-1234",
                     "https://github.com/login/oauth/authorize?client_id=x&code=ONE-TIME"] {
            XCTAssertEqual(restoredURL(whenAt: page, start: start), url(start), "SR4: \(page)")
        }
    }

    func testAnURLOutsideTheAllowedHostsIsNeverSaved() {
        let start = "https://github.com/acme/web/pull/7"
        for page in ["https://evil.example/landing?code=x", "http://github.com/acme/web/pull/7", "https://github.com:8443/x",
                     "https://github.com@evil.example/", "about:blank"] {
            XCTAssertEqual(restoredURL(whenAt: page, start: start), url(start), page)
        }
    }

    func testNoCookiesOrPageTextAreEverSaved() {
        let m = model(tag: "perri-contents")
        let tab = m.open(pr: pr(7), target: .conversation)
        tab.title = "Secret title"
        m.persist()
        let saved = defaults.dictionary(forKey: "reviewPane.v1.perri-contents") ?? [:]
        XCTAssertTrue(Set(saved.keys).isSubset(of: ["width", "tabs", "active"]), "\(saved.keys.sorted())")
        let tabs = saved["tabs"] as? [[String: Any]] ?? []
        XCTAssertEqual(tabs.count, 1)
        let allowed: Set<String> = ["repo", "number", "start", "last", "title", "target", "ticket", "page"]
        for tab in tabs { XCTAssertTrue(Set(tab.keys).isSubset(of: allowed), "\(tab.keys.sorted())") }
    }

    // MARK: SR4: what a tab's start URL may be

    /// Everything the store wrote for a focus, as one string: what is on disk, whatever its shape.
    private func rawSaved(tag: String) -> String {
        "\(defaults.dictionary(forKey: ReviewPaneStore.key(tag)) ?? [:])"
    }

    private func savedStartStrings(tag: String) -> [String] {
        let tabs = (defaults.dictionary(forKey: ReviewPaneStore.key(tag))?["tabs"] as? [[String: Any]]) ?? []
        return tabs.compactMap { $0["start"] as? String }
    }

    /// A sign-in popup can be opened straight to an identity provider's URL: its START url carries the one-time
    /// code and a fragment token. Neither may reach the disk; the tab comes back on the PR's conversation page.
    func testAPageTabOpenedStraightToASignInURLIsSavedWithoutItsCodeOrToken() {
        let secrets = ["ONE-TIME", "SECRET", "access_token", "code="]
        for (n, start) in ["https://login.microsoftonline.com/x?code=ONE-TIME#access_token=SECRET",
                           "https://evil.example/cb?code=ONE-TIME#access_token=SECRET",
                           "http://github.com/login/oauth/authorize?code=ONE-TIME#access_token=SECRET"].enumerated() {
            let tag = "perri-start-\(n)"
            let first = model(tag: tag)
            let opener = first.open(pr: pr(7), target: .conversation)
            let popup = first.openPage(from: opener, url: url(start))
            XCTAssertEqual(popup.startURL, url(start), "precondition: the tab itself holds the URL")
            first.persist()

            let raw = rawSaved(tag: tag)
            for secret in secrets { XCTAssertFalse(raw.contains(secret), "SR4: \(secret) reached the disk for \(start): \(raw)") }

            let restored = model(tag: tag)
            let page = restored.tabs.first { if case .page = $0.target { return true } else { return false } }
            XCTAssertNotNil(page, "the tab itself is still restored: \(start)")
            XCTAssertEqual(page?.startURL, url("https://github.com/acme/web/pull/7"), "falls back to the PR's conversation page: \(start)")
            XCTAssertEqual(page?.currentURL, url("https://github.com/acme/web/pull/7"), "and so does its last URL: \(start)")
        }
    }

    func testADiffTabWithAnOffListStartURLFallsBackToTheConversationPageOfItsPR() {
        let first = model(tag: "perri-start-diff")
        first.open(pr: pr(7), target: .diff, url: url("https://evil.example/files?code=ONE-TIME"))
        first.persist()

        XCTAssertFalse(rawSaved(tag: "perri-start-diff").contains("ONE-TIME"))
        let restored = model(tag: "perri-start-diff")
        XCTAssertEqual(restored.tabs.first?.target, .diff, "it is still the diff tab")
        XCTAssertEqual(restored.tabs.first?.startURL, url("https://github.com/acme/web/pull/7"))
    }

    func testAJiraStartURLOnASiteThatIsNotConfiguredIsNotSaved() {
        jiraSite = nil
        let first = model(tag: "perri-start-jira")
        first.open(pr: pr(7), target: .ticket("CORE-1"), url: url("https://carefeed.atlassian.net/browse/CORE-1?token=ONE-TIME"))
        first.persist()
        XCTAssertFalse(rawSaved(tag: "perri-start-jira").contains("ONE-TIME"))
        XCTAssertFalse(rawSaved(tag: "perri-start-jira").contains("atlassian.net"), "the host was not on the list either")
    }

    func testAnAllowedGitHubStartURLIsSavedWithoutItsQueryAndWithoutItsFragment() {
        let first = model(tag: "perri-start-gh")
        first.open(pr: pr(7), target: .diff, url: url("https://github.com/acme/web/pull/7/files?code=X#diff-1"))
        first.persist()

        XCTAssertEqual(savedStartStrings(tag: "perri-start-gh"), ["https://github.com/acme/web/pull/7/files"],
                       "neither the query nor the fragment of a START url is kept")
        XCTAssertFalse(rawSaved(tag: "perri-start-gh").contains("code=X"), "the last URL lost its query too: \(rawSaved(tag: "perri-start-gh"))")
        XCTAssertEqual(model(tag: "perri-start-gh").tabs.first?.startURL, url("https://github.com/acme/web/pull/7/files"))
    }

    func testAnAllowedJiraStartURLIsSavedWithoutItsQueryAndWithoutItsFragment() {
        jiraSite = "carefeed.atlassian.net"
        let first = model(tag: "perri-start-jira-ok")
        first.open(pr: pr(7), target: .ticket("CORE-1"), url: url("https://carefeed.atlassian.net/browse/CORE-1?token=ONE-TIME#comment-9"))
        first.persist()

        XCTAssertEqual(savedStartStrings(tag: "perri-start-jira-ok"), ["https://carefeed.atlassian.net/browse/CORE-1"])
        XCTAssertFalse(rawSaved(tag: "perri-start-jira-ok").contains("ONE-TIME"))
    }

    // MARK: Popups

    func testAnAboutBlankPopupTabIsNotSaved() {
        let first = model()
        let opener = first.open(pr: pr(7), target: .conversation)
        let popup = first.openPage(from: opener, url: url("about:blank"))
        XCTAssertEqual(first.activeID, popup.id, "precondition: the popup is the active tab")
        XCTAssertEqual(first.tabs.count, 2)

        let restored = model()

        XCTAssertEqual(restored.tabs.count, 1, "the popup has nothing to restore")
        XCTAssertEqual(restored.tabs.first?.target, .conversation)
        XCTAssertEqual(restored.activeTab?.target, .conversation, "and the active tab is a real one")
    }

    func testAPopupThatNavigatedToASignInPageIsNotSavedAtAll() {
        let first = model()
        let opener = first.open(pr: pr(7), target: .conversation)
        let popup = first.openPage(from: opener, url: url("about:blank"))
        popup.currentURL = url("https://github.com/login/oauth/authorize?code=ONE-TIME")
        first.persist()

        let restored = model()

        XCTAssertEqual(restored.tabs.count, 1)
        for tab in restored.tabs {
            XCTAssertFalse(tab.currentURL.absoluteString.contains("ONE-TIME"), "SR4: \(tab.currentURL)")
            XCTAssertFalse(tab.startURL.absoluteString.contains("ONE-TIME"), "SR4: \(tab.startURL)")
        }
    }
}
