import XCTest
import AppKit
import WebKit

// Perri side pane, slice 2: the rules of `ReviewNavigationPolicy` hold through a REAL web view, and the
// pane's native overlays and unsent-text guard work against real pages. No network:
//
//   * pages come from `ReviewFixtureHandler` on the `nostromo-fixture:` scheme (see ReviewPaneTestSupport);
//     `nostromo-fixture://github.com/...` is "https://github.com/..." and `nostromo-fixture://evil.example/...`
//     is outside the hosts, because the environment's hosts are built with the DEBUG-only fixture initializer
//   * the data store is a throwaway `WKWebsiteDataStore(forIdentifier:)`, removed afterwards
//   * "a person clicked" is a real NSEvent (mouseDown/mouseUp) sent through a real NSWindow to the web view
//
// Handler requests are the proof that something loaded: a blocked redirect never reaches the handler.

@MainActor
final class ReviewWebViewIntegrationTests: XCTestCase {

    private var world: ReviewFixtureWorld!
    private var model: ReviewPaneModel!
    private var window: ReviewTestWindow!
    private var pane: ReviewSidePaneView!
    private var pages: [String: String] = [:]

    private let pr = ReviewPR(repo: "acme/web", number: 7)
    private let mainPath = "/acme/web/pull/7"

    override func setUp() async throws {
        try await super.setUp()
        world = ReviewFixtureWorld()
        pages = [:]
        world.handler.respond = { [unowned self] url in
            ReviewFixtureHandler.Response(body: self.pages["\(url.host ?? "")\(url.path)"]
                                          ?? ReviewFixtureHandler.html("<p>fixture \(url.path)</p>"))
        }
        model = ReviewPaneModel(tag: "perri-web-\(UUID().uuidString)", store: nil)
        model.environment = world.environment
        window = ReviewTestWindow.make(size: NSSize(width: 900, height: 700))
        pane = ReviewSidePaneView(model: model)
        window.contentView = pane
        window.contentView?.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        for tab in model.tabs { model.close(tab) }
        window.contentView = NSView()
        window.close()
        pane = nil
        model = nil
        window = nil
        await spinA(0.3)
        await world.removeDataStore()
        world = nil
        try await super.tearDown()
    }

    // MARK: Helpers

    private func serve(_ path: String, _ html: String, host: String = "github.com") { pages["\(host)\(path)"] = html }

    @discardableResult
    private func openTab(_ path: String? = nil, target: ReviewTarget = .conversation, of pr: ReviewPR? = nil) -> ReviewTab {
        model.open(pr: pr ?? self.pr, target: target, url: reviewFixtureURL("github.com\(path ?? mainPath)"))
    }

    private func controller(_ tab: ReviewTab, file: StaticString = #filePath, line: UInt = #line) throws -> ReviewTabController {
        try XCTUnwrap(tab.controller, "the tab was shown, so it has a controller", file: file, line: line)
    }

    /// Waits for the tab's start page to have loaded and the page to answer a script.
    private func waitForLoaded(_ tab: ReviewTab, file: StaticString = #filePath, line: UInt = #line) async throws {
        let c = try controller(tab, file: file, line: line)
        await assertTrueA(await spinUntilA(15) { !c.webView.isLoading && c.webView.url == tab.startURL && c.contentView.cover.isHidden },
                      "the fixture page loaded: isLoading \(c.webView.isLoading), url \(String(describing: c.webView.url)) vs \(tab.startURL), "
                      + "cover \"\(c.contentView.cover.message)\" hidden \(c.contentView.cover.isHidden), frame \(c.webView.frame), "
                      + "handler saw \(world.handler.requested.map(\.absoluteString))", file: file, line: line)
        _ = try await c.webView.evaluateJavaScript("1")
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func js(_ tab: ReviewTab, _ source: String) async -> Any? {
        guard let web = tab.controller?.webView else { return nil }
        return try? await web.evaluateJavaScript(source)
    }

    private func eventually(_ timeout: TimeInterval = 10, _ check: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await check() { return true }
            await spinA(0.05)
        }
        return await check()
    }

    private func clickPoint(_ tab: ReviewTab, x: CGFloat, y: CGFloat) throws -> NSPoint {
        try controller(tab).webView.convert(NSPoint(x: x, y: y), to: nil)
    }

    private func realClick(_ tab: ReviewTab, x: CGFloat, y: CGFloat) throws {
        ReviewEvents.click(at: try clickPoint(tab, x: x, y: y), in: window)
    }

    private func notice(_ tab: ReviewTab) -> ReviewMessageView? { tab.controller?.contentView.notice }

    private let outsideLink = """
        <a id="out" href="nostromo-fixture://evil.example/landing" style="position:absolute;left:20px;top:20px;width:300px;height:80px;display:block;background:#ccc">outside</a>
        <div id="blank" style="position:absolute;left:20px;top:200px;width:300px;height:80px;background:#eee"></div>
        """

    private func assertTabStayedPut(_ tab: ReviewTab, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(tab.controller?.webView.url, tab.startURL, "the tab did not navigate", file: file, line: line)
        XCTAssertEqual(tab.currentURL, tab.startURL, file: file, line: line)
        XCTAssertEqual(model.tabs.count, 1, "and no tab was opened", file: file, line: line)
    }

    private func assertNoRequestReachedEvil(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(world.handler.requests(toHost: "evil.example"), [], "the blocked page was never requested", file: file, line: line)
    }

    // MARK: Is WebKit alive in this process? (these name the cause when everything below fails)

    private final class LoadWatcher: NSObject, WKNavigationDelegate {
        var finished = false
        var failure: Error?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    }

    private func diagnose(_ web: WKWebView, _ watcher: LoadWatcher) -> String {
        "finished \(watcher.finished), failure \(String(describing: watcher.failure)), isLoading \(web.isLoading), progress \(web.estimatedProgress), url \(String(describing: web.url))"
    }

    func testPlainWebKitLoadsHTMLWithANonPersistentStore() throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let watcher = LoadWatcher()
        web.navigationDelegate = watcher
        web.loadHTMLString("<p>hello</p>", baseURL: nil)
        XCTAssertTrue(spinUntil(20) { watcher.finished || watcher.failure != nil }, "no WebKit load finished at all: \(diagnose(web, watcher))")
        XCTAssertTrue(watcher.finished, diagnose(web, watcher))
    }

    func testPlainWebKitLoadsHTMLWithAThrowawayIdentifierStore() throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = world.dataStore
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let watcher = LoadWatcher()
        web.navigationDelegate = watcher
        web.loadHTMLString("<p>hello</p>", baseURL: nil)
        XCTAssertTrue(spinUntil(20) { watcher.finished || watcher.failure != nil }, "no load finished with the identifier store: \(diagnose(web, watcher))")
        XCTAssertTrue(watcher.finished, diagnose(web, watcher))
    }

    func testPlainWebKitServesTheFixtureSchemeFromTheHandler() throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: world.environment.makeConfiguration())
        let watcher = LoadWatcher()
        web.navigationDelegate = watcher
        web.load(URLRequest(url: reviewFixtureURL("github.com/acme/web/pull/7")))
        XCTAssertTrue(spinUntil(20) { watcher.finished || watcher.failure != nil }, "the fixture page never loaded: \(diagnose(web, watcher)); handler saw \(world.handler.requested)")
        XCTAssertTrue(watcher.finished, diagnose(web, watcher))
        XCTAssertEqual(world.handler.requested.map(\.absoluteString), ["nostromo-fixture://github.com/acme/web/pull/7"])
    }

    func testTheReviewPaneLoadsItsStartPageThroughItsOwnController() async throws {
        let tab = openTab()
        let c = try controller(tab)
        let loaded = await spinUntilA(20) { !c.webView.isLoading && c.webView.url == tab.startURL }
        let diagnostics = "isLoading \(c.webView.isLoading), progress \(c.webView.estimatedProgress), url \(String(describing: c.webView.url)), "
            + "frame \(c.webView.frame), window visible \(String(describing: c.webView.window?.isVisible)), "
            + "occlusion \(String(describing: c.webView.window?.occlusionState.rawValue)), handler saw \(world.handler.requested.count), "
            + "cover \"\(c.contentView.cover.message)\" hidden \(c.contentView.cover.isHidden)"
        XCTAssertTrue(loaded, diagnostics)
        XCTAssertTrue(c.contentView.cover.isHidden, "the loading cover goes away once the page commits: \(diagnostics)")
    }

    // MARK: Criterion 29: redirects and popups without a click

    private func assertRedirectBlocked(_ html: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        serve(mainPath, ReviewFixtureHandler.html(html))
        let tab = openTab()
        await assertTrueA(await spinUntilA(15) { self.notice(tab)?.isHidden == false },
                      "the notice appears", file: file, line: line)
        XCTAssertTrue(notice(tab)?.message.contains("evil.example") == true,
                      "SR2: the notice names the host: \(notice(tab)?.message ?? "nil")", file: file, line: line)
        XCTAssertEqual(notice(tab)?.buttonTitle, "Open in Browser", file: file, line: line)
        await spinA(0.7)       // a stray load would have reached the handler by now
        assertTabStayedPut(tab, file: file, line: line)
        assertNoRequestReachedEvil(file: file, line: line)
        XCTAssertEqual(world.openedExternally, [], "nothing opens the browser without a click", file: file, line: line)
    }

    func testLocationAssignToAnOutsideHostStaysPutAndNamesTheHost() async throws {
        try await assertRedirectBlocked("<script>location.assign('nostromo-fixture://evil.example/landing')</script>")
    }

    func testMetaRefreshToAnOutsideHostStaysPutAndNamesTheHost() async throws {
        try await assertRedirectBlocked("<meta http-equiv=\"refresh\" content=\"0;url=nostromo-fixture://evil.example/landing\">")
    }

    func testWindowOpenWithoutAClickToAnOutsideHostIsBlockedAndNamesTheHost() async throws {
        try await assertRedirectBlocked("<script>window.open('nostromo-fixture://evil.example/landing')</script>")
    }

    func testTheNoticesOpenInBrowserButtonOpensTheBlockedURLOnlyWhenPressed() async throws {
        serve(mainPath, ReviewFixtureHandler.html("<script>location.assign('nostromo-fixture://evil.example/landing')</script>"))
        let tab = openTab()
        await assertTrueA(await spinUntilA(15) { self.notice(tab)?.isHidden == false })
        XCTAssertEqual(world.openedExternally, [])
        notice(tab)?.press()
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")])
    }

    // MARK: Criterion 30: only a real click leaves the pane

    func testARealClickOnAnOutsideLinkOpensTheDefaultBrowserAndTheTabDoesNotNavigate() async throws {
        serve(mainPath, ReviewFixtureHandler.html(outsideLink))
        let tab = openTab()
        try await waitForLoaded(tab)

        try realClick(tab, x: 100, y: 60)

        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty }, "the click reached the page and the link opened")
        await spinA(0.5)
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")], "exactly once, with the URL")
        assertTabStayedPut(tab)
        assertNoRequestReachedEvil()
    }

    func testTheSameLinkActivatedByScriptDoesNotOpenTheBrowser() async throws {
        serve(mainPath, ReviewFixtureHandler.html(outsideLink))
        let tab = openTab()
        try await waitForLoaded(tab)

        _ = await js(tab, "document.getElementById('out').click(); true")

        await assertTrueA(await spinUntilA(10) { self.notice(tab)?.isHidden == false }, "blocked with a notice instead")
        XCTAssertTrue(notice(tab)?.message.contains("evil.example") == true)
        await spinA(0.3)
        XCTAssertEqual(world.openedExternally, [], "SR3: script is not a person")
        assertTabStayedPut(tab)
        assertNoRequestReachedEvil()
    }

    func testAScriptClickLongAfterARealClickDoesNotOpenTheBrowser() async throws {
        serve(mainPath, ReviewFixtureHandler.html(outsideLink))
        let tab = openTab()
        try await waitForLoaded(tab)

        try realClick(tab, x: 100, y: 240)          // a real click on empty page: a human event, but not on the link
        await spinA(ReviewWebView.gestureWindow + 0.5)     // the gesture has gone stale
        _ = await js(tab, "document.getElementById('out').click(); true")

        await assertTrueA(await spinUntilA(10) { self.notice(tab)?.isHidden == false })
        await spinA(0.3)
        XCTAssertEqual(world.openedExternally, [], "SR3: a click from long ago is not a gesture")
        assertTabStayedPut(tab)
    }

    func testAClickAppControlSynthesisedDoesNotOpenTheBrowser() async throws {
        serve(mainPath, ReviewFixtureHandler.html(outsideLink))
        let tab = openTab()
        try await waitForLoaded(tab)
        let point = try clickPoint(tab, x: 100, y: 60)

        SyntheticInputGate.begin()
        ReviewEvents.click(at: point, in: window)
        SyntheticInputGate.end()

        await assertTrueA(await spinUntilA(10) { self.notice(tab)?.isHidden == false }, "blocked with a notice")
        await spinA(0.3)
        XCTAssertEqual(world.openedExternally, [], "an agent driving app-control is not a person")
        assertTabStayedPut(tab)
    }

    func testARealClickOnALinkToAnAllowedHostNavigatesTheTab() async throws {
        serve(mainPath, ReviewFixtureHandler.html("""
            <a href="nostromo-fixture://github.com/acme/web/pull/7/files" style="position:absolute;left:20px;top:20px;width:300px;height:80px;display:block;background:#ccc">diff</a>
            """))
        let tab = openTab()
        try await waitForLoaded(tab)

        try realClick(tab, x: 100, y: 60)

        await assertTrueA(await spinUntilA(10) { tab.currentURL == reviewFixtureURL("github.com/acme/web/pull/7/files") },
                      "an allowed host loads in the pane")
        XCTAssertEqual(world.openedExternally, [])
        XCTAssertEqual(model.tabs.count, 1)
    }

    func testARealClickOnATargetBlankLinkToAnOutsideHostOpensTheBrowserAndNoTab() async throws {
        serve(mainPath, ReviewFixtureHandler.html("""
            <a href="nostromo-fixture://evil.example/landing" target="_blank" style="position:absolute;left:20px;top:20px;width:300px;height:80px;display:block;background:#ccc">blank</a>
            """))
        let tab = openTab()
        try await waitForLoaded(tab)

        try realClick(tab, x: 100, y: 60)

        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty })
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")])
        await spinA(0.3)
        XCTAssertEqual(model.tabs.count, 1)
        assertNoRequestReachedEvil()
    }

    func testARealClickOnATargetBlankLinkToAnAllowedHostOpensAPaneTab() async throws {
        serve(mainPath, ReviewFixtureHandler.html("""
            <a href="nostromo-fixture://github.com/acme/web/issues/9" target="_blank" style="position:absolute;left:20px;top:20px;width:300px;height:80px;display:block;background:#ccc">blank</a>
            """))
        serve("/acme/web/issues/9", ReviewFixtureHandler.html("<p>issue nine</p>", title: "Issue nine"))
        let tab = openTab()
        try await waitForLoaded(tab)

        try realClick(tab, x: 100, y: 60)

        await assertTrueA(await spinUntilA(10) { self.model.tabs.count == 2 }, "the popup became a pane tab")
        let popup = try XCTUnwrap(model.tabs.first { $0.id != tab.id })
        if case .page = popup.target {} else { XCTFail("a popup is a page tab, not \(popup.target)") }
        XCTAssertEqual(popup.pr, pr, "it belongs to the PR it was opened from")
        await assertTrueA(await spinUntilA(10) { self.world.handler.requestCount(host: "github.com", pathPrefix: "/acme/web/issues/9") >= 1 },
                      "and it loaded the allowed page")
        XCTAssertEqual(world.openedExternally, [])
    }

    // MARK: Criterion 31 and SR6

    func testHttpGitHubNeverLoadsByScriptOrByClick() async throws {
        serve(mainPath, ReviewFixtureHandler.html("""
            <a href="http://github.com/acme/web/pull/7" style="position:absolute;left:20px;top:20px;width:300px;height:80px;display:block;background:#ccc">http</a>
            <script>setTimeout(function () { location.assign('http://github.com/acme/web/pull/7/files'); }, 100);</script>
            """))
        let tab = openTab()
        try await waitForLoaded(tab)
        await spinA(0.6)       // the script's navigation has been tried

        try realClick(tab, x: 100, y: 60)
        await spinA(0.8)

        XCTAssertEqual(tab.controller?.webView.url, tab.startURL, "an http page never loads")
        XCTAssertEqual(tab.currentURL, tab.startURL)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(world.openedExternally, [], "and a clicked http link is not handed to the browser either")
    }

    func testThePageWorldHasNoBridgeToTheApp() async throws {
        serve(mainPath, ReviewFixtureHandler.html("<p>page</p>"))
        let tab = openTab()
        try await waitForLoaded(tab)

        let bridge = await js(tab, "typeof window.webkit") as? String
        XCTAssertEqual(bridge, "undefined", "SR6: no message handler")
        let probe = await js(tab, "typeof window.__nostromoSeen") as? String
        XCTAssertEqual(probe, "undefined", "the unsent-input probe lives in its own world, invisible to the page")
        let bare = await js(tab, "typeof webkit") as? String
        XCTAssertEqual(bare, "undefined")
    }

    // MARK: Delegates the pane answers itself

    private final class FrameProbe: NSObject, WKScriptMessageHandler {
        var frameInfo: WKFrameInfo?
        private var web: WKWebView?

        @MainActor
        func obtain(dataStore: WKWebsiteDataStore) async -> WKFrameInfo? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = dataStore
            config.userContentController.add(self, name: "probe")
            let w = WKWebView(frame: .zero, configuration: config)
            web = w
            w.loadHTMLString("<script>window.webkit.messageHandlers.probe.postMessage('x')</script>", baseURL: nil)
            _ = await spinUntilA(10) { self.frameInfo != nil }
            w.configuration.userContentController.removeScriptMessageHandler(forName: "probe")
            web = nil
            return frameInfo
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            frameInfo = message.frameInfo
        }
    }

    func testCameraAndMicrophoneRequestsAreDenied() async throws {
        serve(mainPath, ReviewFixtureHandler.html("<p>page</p>"))
        let tab = openTab()
        try await waitForLoaded(tab)
        let c = try controller(tab)
        let probe = FrameProbe()
        let obtained = await probe.obtain(dataStore: world.dataStore)
        let frame = try XCTUnwrap(obtained, "a real frame to ask about")

        for type: WKMediaCaptureType in [.camera, .microphone, .cameraAndMicrophone] {
            var decision: WKPermissionDecision?
            c.webView(c.webView, requestMediaCapturePermissionFor: frame.securityOrigin, initiatedByFrame: frame, type: type) {
                decision = $0
            }
            XCTAssertEqual(decision, .deny, "capture type \(type.rawValue)")
        }
    }

    func testPageDialogsAreAnsweredWithoutShowingAnything() async throws {
        serve(mainPath, ReviewFixtureHandler.html("<p>page</p>"))
        let tab = openTab()
        try await waitForLoaded(tab)
        let c = try controller(tab)
        let obtained = await FrameProbe().obtain(dataStore: world.dataStore)
        let frame = try XCTUnwrap(obtained)

        var alerted = false
        c.webView(c.webView, runJavaScriptAlertPanelWithMessage: "hi", initiatedByFrame: frame) { alerted = true }
        XCTAssertTrue(alerted, "an alert is dismissed at once")

        var confirmed: Bool?
        c.webView(c.webView, runJavaScriptConfirmPanelWithMessage: "sure?", initiatedByFrame: frame) { confirmed = $0 }
        XCTAssertEqual(confirmed, false, "a confirm answers no")

        var promptAnswered = false
        var promptValue: String? = "unset"
        c.webView(c.webView, runJavaScriptTextInputPanelWithPrompt: "name?", defaultText: "x", initiatedByFrame: frame) {
            promptAnswered = true
            promptValue = $0
        }
        XCTAssertTrue(promptAnswered)
        XCTAssertNil(promptValue, "a prompt answers nothing")
    }

    // MARK: Criterion 34: no downloads

    func testAnAttachmentResponseProducesTheDownloadNoticeAndLeavesTheTabWhereItWas() async throws {
        serve(mainPath, ReviewFixtureHandler.html("<script>setTimeout(function () { location.href = 'nostromo-fixture://github.com/acme/web/archive/main.zip'; }, 50);</script>"))
        let zip = reviewFixtureURL("github.com/acme/web/archive/main.zip")
        let base = world.handler.respond
        world.handler.respond = { url in
            if url.path.hasSuffix("main.zip") {
                return ReviewFixtureHandler.Response(body: "PK", mime: "application/octet-stream",
                                                     headers: ["Content-Disposition": "attachment; filename=main.zip"])
            }
            return base(url)
        }
        let tab = openTab()

        await assertTrueA(await spinUntilA(15) { self.notice(tab)?.isHidden == false }, "the notice appears")
        XCTAssertEqual(notice(tab)?.message, "Downloads open in your browser.")
        XCTAssertEqual(notice(tab)?.buttonTitle, "Open in Browser")
        // WebKit reports the provisional URL until the cancelled load settles: wait for it to go back.
        await assertTrueA(await spinUntilA(5) { tab.controller?.webView.url == tab.startURL && tab.currentURL == tab.startURL },
                          "the tab stayed on its page")
        XCTAssertEqual(world.openedExternally, [], "nothing opened by itself")

        notice(tab)?.press()
        XCTAssertEqual(world.openedExternally, [zip], "the person's click hands the URL to the browser")
    }

    func testADownloadAttributeLinkIsCancelledBeforeAnyRequest() async throws {
        serve(mainPath, ReviewFixtureHandler.html("""
            <a href="nostromo-fixture://github.com/acme/web/archive/file.bin" download="file.bin" style="position:absolute;left:20px;top:20px;width:300px;height:80px;display:block;background:#ccc">download</a>
            """))
        let tab = openTab()
        try await waitForLoaded(tab)

        try realClick(tab, x: 100, y: 60)

        await assertTrueA(await spinUntilA(10) { self.notice(tab)?.isHidden == false }, "the download notice appears")
        XCTAssertEqual(notice(tab)?.message, "Downloads open in your browser.")
        await spinA(0.3)
        XCTAssertEqual(world.handler.requestCount(host: "github.com", pathPrefix: "/acme/web/archive/file.bin"), 0,
                       "SR8: nothing was even requested")
        XCTAssertEqual(tab.controller?.webView.url, tab.startURL)
    }

    // MARK: Criterion 32: the Work profile's cookies stay in its own store

    func testACookieInOneThrowawayStoreIsInNoOtherStoreAndNotInTheDefaultStore() async throws {
        serve(mainPath, ReviewFixtureHandler.html("<p>page</p>"))
        let tab = openTab()
        try await waitForLoaded(tab)
        let name = "nostromo-test-\(UUID().uuidString)"
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "github.com", .path: "/", .name: name,
                                                           .value: "session", .secure: "TRUE"]))
        let tabStore = try controller(tab).webView.configuration.websiteDataStore
        await tabStore.httpCookieStore.setCookie(cookie)

        let inTabStore = await tabStore.httpCookieStore.allCookies().contains { $0.name == name }
        XCTAssertTrue(inTabStore, "precondition: the cookie is in the tab's store")
        XCTAssertTrue(tabStore === world.dataStore, "the tab uses the store its environment made")

        let otherID = UUID()
        let other = WKWebsiteDataStore(forIdentifier: otherID)
        let inOther = await other.httpCookieStore.allCookies().contains { $0.name == name }
        XCTAssertFalse(inOther, "another store never sees it")
        try? await WKWebsiteDataStore.remove(forIdentifier: otherID)

        // Read only: the default store is inspected, never written.
        let inDefault = await WKWebsiteDataStore.default().httpCookieStore.allCookies().contains { $0.name == name }
        XCTAssertFalse(inDefault, "the default store never sees it")
    }

    func testTheFactoryUsesTheStoreItIsGivenNeverTheDefaultOne() {
        let id = UUID()
        let store = WKWebsiteDataStore(forIdentifier: id)
        let config = ReviewWebViewFactory.makeConfiguration(dataStore: store)
        XCTAssertTrue(config.websiteDataStore === store)
        XCTAssertFalse(config.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertTrue(config.websiteDataStore.isPersistent, "the Work profile signs in once")
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
    }

    func testTheWorkProfileKeepsItsStableIdentifier() {
        // Changing it signs everyone out, and the browser pane (BP1a) must reuse it. Not opened here.
        XCTAssertEqual(BrowserProfile.workIdentifier.uuidString, "B4ABA640-B3C9-4174-B335-43BB568F542E")
    }

    // MARK: Criterion 23 (reframed): unsent text

    private let formPage = """
        <textarea id="t" style="position:absolute;left:20px;top:20px;width:400px;height:100px"></textarea>
        <input id="pw" type="password" style="position:absolute;left:20px;top:150px;width:200px">
        <input id="txt" type="text" style="position:absolute;left:20px;top:200px;width:200px">
        <div id="ce" contenteditable="true" style="position:absolute;left:20px;top:250px;width:300px;height:60px;border:1px solid #888"></div>
        """

    private func openFormTab() async throws -> ReviewTab {
        serve(mainPath, ReviewFixtureHandler.html(formPage))
        let tab = openTab()
        try await waitForLoaded(tab)
        return tab
    }

    /// Focuses `id` in the page and types `text` with real key events.
    private func typeInto(_ id: String, _ text: String, tab: ReviewTab, file: StaticString = #filePath, line: UInt = #line) async throws {
        let c = try controller(tab, file: file, line: line)
        _ = await js(tab, "document.getElementById('\(id)').focus(); true")
        window.makeFirstResponder(c.webView)
        ReviewEvents.type(text, in: window)
        let landed = await eventually {
            let value = await self.js(tab, "(function(){var e=document.getElementById('\(id)');return e.value!==undefined?e.value:e.textContent;})()") as? String
            return value == text
        }
        XCTAssertTrue(landed, "the typed text reached #\(id)", file: file, line: line)
    }

    func testTypingInATextareaMakesTheTabUnsent() async throws {
        let tab = try await openFormTab()
        let c = try controller(tab)
        let before = await c.hasUnsentInput()
        XCTAssertFalse(before, "nothing typed yet")

        try await typeInto("t", "hello", tab: tab)

        let after = await c.hasUnsentInput()
        XCTAssertTrue(after, "trusted key events typed text that was not sent")
    }

    func testEmptyingTheTextareaMakesTheTabSendable() async throws {
        let tab = try await openFormTab()
        let c = try controller(tab)
        try await typeInto("t", "hello", tab: tab)
        let typed = await c.hasUnsentInput()
        XCTAssertTrue(typed, "precondition")

        ReviewEvents.backspace(5, in: window)
        let emptied = await eventually { await self.js(tab, "document.getElementById('t').value") as? String == "" }
        XCTAssertTrue(emptied, "precondition: the backspaces landed")

        let after = await c.hasUnsentInput()
        XCTAssertFalse(after)
    }

    func testAnInputEventDispatchedByPageScriptDoesNotCount() async throws {
        let tab = try await openFormTab()
        let c = try controller(tab)

        _ = await js(tab, """
            var t = document.getElementById('t'); t.value = 'pretend'; t.dispatchEvent(new Event('input', {bubbles: true})); true
            """)

        let after = await c.hasUnsentInput()
        XCTAssertFalse(after, "script cannot raise the unsent flag: only trusted events count")
    }

    func testAPasswordOrPlainInputIsNeverRead() async throws {
        let tab = try await openFormTab()
        let c = try controller(tab)

        try await typeInto("pw", "hunter", tab: tab)
        let afterPassword = await c.hasUnsentInput()
        XCTAssertFalse(afterPassword, "a password field is never considered")

        try await typeInto("txt", "query", tab: tab)
        let afterInput = await c.hasUnsentInput()
        XCTAssertFalse(afterInput, "nor is a one-line input")
    }

    func testTypingInAContentEditableMakesTheTabUnsent() async throws {
        let tab = try await openFormTab()
        let c = try controller(tab)
        try await typeInto("ce", "draft", tab: tab)
        let after = await c.hasUnsentInput()
        XCTAssertTrue(after)
    }

    func testAPRChangeKeepsTheTabWithTypedTextAndMarksIt() async throws {
        await model.pinChanged(to: pr)
        let tab = try await openFormTab()
        let plain = model.open(pr: pr, target: .diff, url: reviewFixtureURL("github.com/acme/web/pull/7/files"))
        model.focus(tab)
        try await typeInto("t", "hello", tab: tab)

        await model.pinChanged(to: ReviewPR(repo: "acme/web", number: 8))

        XCTAssertTrue(model.tabs.contains { $0.id == tab.id }, "the tab with unsent text stays")
        XCTAssertTrue(tab.unsent, "marked")
        XCTAssertTrue(tab.fullDescription.contains("unsent text"), "and described so a screen reader says so")
        XCTAssertFalse(model.tabs.contains { $0.id == plain.id }, "a tab with nothing typed closes")
    }

    func testClosingATabWithUnsentTextAsksFirstAndKeepsItOnKeep() async throws {
        let tab = try await openFormTab()
        try await typeInto("t", "hello", tab: tab)
        var asked: [ReviewTab.ID] = []
        pane.confirmDiscard = { tab, _ in asked.append(tab.id); return false }

        await pane.requestClose(tab)

        XCTAssertEqual(asked, [tab.id], "the discard flow was presented once")
        XCTAssertTrue(model.tabs.contains { $0.id == tab.id }, "Keep: the tab stays")
    }

    func testClosingATabWithUnsentTextClosesItOnceDiscardIsConfirmed() async throws {
        let tab = try await openFormTab()
        try await typeInto("t", "hello", tab: tab)
        var asked = 0
        pane.confirmDiscard = { _, _ in asked += 1; return true }

        await pane.requestClose(tab)

        XCTAssertEqual(asked, 1)
        XCTAssertFalse(model.tabs.contains { $0.id == tab.id })
    }

    func testClosingATabWithNothingTypedDoesNotAsk() async throws {
        let tab = try await openFormTab()
        var asked = 0
        pane.confirmDiscard = { _, _ in asked += 1; return false }

        await pane.requestClose(tab)

        XCTAssertEqual(asked, 0)
        XCTAssertFalse(model.tabs.contains { $0.id == tab.id })
    }

    // MARK: Criterion 37: a failed load

    func testALoadFailureCoversTheTabWithTheHostAndARetryThatReloadsExactlyOnce() async throws {
        var failing = true
        world.handler.respond = { [unowned self] url in
            if failing, url.path == self.mainPath {
                return ReviewFixtureHandler.Response(
                    failure: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                     userInfo: [NSURLErrorFailingURLErrorKey: url]))
            }
            return ReviewFixtureHandler.Response(body: ReviewFixtureHandler.html("<p>back online</p>"))
        }
        let tab = openTab()
        let c = try controller(tab)

        await assertTrueA(await spinUntilA(15) { c.contentView.cover.buttonTitle == "Retry" && !c.contentView.cover.isHidden },
                      "the error cover with a Retry button appears")
        XCTAssertTrue(c.contentView.cover.message.contains("github.com"), "it names the host: \(c.contentView.cover.message)")
        XCTAssertFalse(c.contentView.cover.message.contains("/acme/web"), "and not the path")
        let requestsBefore = world.handler.requestCount(host: "github.com", pathPrefix: mainPath)

        failing = false
        c.contentView.cover.press()
        c.contentView.cover.press()      // a second press while it reloads must not load again

        await assertTrueA(await spinUntilA(15) { c.contentView.cover.isHidden && !c.webView.isLoading && c.webView.url == tab.startURL },
                      "the page loaded and the cover went away")
        await spinA(0.5)
        XCTAssertEqual(world.handler.requestCount(host: "github.com", pathPrefix: mainPath), requestsBefore + 1,
                       "Retry reloaded exactly once")
    }

    // MARK: Criterion 38: a crashed page

    func testAStoppedPageCoversThatTabOnlyWithReload() async throws {
        let first = openTab()
        try await waitForLoaded(first)
        let second = model.open(pr: pr, target: .diff, url: reviewFixtureURL("github.com/acme/web/pull/7/files"))
        let secondController = model.ensureController(for: second)
        let c = try controller(first)
        // Opening it shows it, which starts its load: let that finish, so "not covered" means the crash did not cover it.
        await assertTrueA(await spinUntilA(15) { secondController.contentView.cover.isHidden && !secondController.webView.isLoading },
                          "the second tab loaded")

        XCTAssertTrue(c.webView.navigationDelegate === c, "WebKit reports a crash to the tab's own controller")
        XCTAssertTrue(c.webView.uiDelegate === c)
        XCTAssertTrue(secondController.webView.navigationDelegate === secondController)

        c.webViewWebContentProcessDidTerminate(c.webView)

        XCTAssertFalse(c.contentView.cover.isHidden)
        XCTAssertEqual(c.contentView.cover.message, "This page stopped.")
        XCTAssertEqual(c.contentView.cover.buttonTitle, "Reload")
        XCTAssertTrue(secondController.contentView.cover.isHidden, "no other tab is covered")
        XCTAssertTrue(secondController.contentView.notice.isHidden)

        let before = world.handler.requestCount(host: "github.com", pathPrefix: mainPath)
        c.contentView.cover.press()
        await assertTrueA(await spinUntilA(15) { c.contentView.cover.isHidden && !c.webView.isLoading }, "Reload brings the page back")
        XCTAssertGreaterThan(world.handler.requestCount(host: "github.com", pathPrefix: mainPath), before)
    }

    // MARK: A blocked first load never leaves a "Loading…" cover behind

    /// A tab that comes back from a relaunch with `start` as its URL, shown in the window. The saved entry is
    /// written the way an older build, or a hand-edited preference, could have written it: unsanitised.
    private func showRestoredTab(startingAt start: URL, target: ReviewTarget = .conversation) throws -> ReviewTab {
        let suite = "ReviewWebViewIntegrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let store = ReviewPaneStore(defaults: defaults, jiraSite: { nil })
        store.save(tag: "perri-restored", ReviewPaneStore.Saved(
            widthFraction: 0.5,
            tabs: [ReviewPaneStore.SavedTab(repo: pr.repo, number: pr.number, target: target, startURL: start,
                                            lastURL: start, title: "restored")],
            activeIndex: 0))
        let restored = ReviewPaneModel(tag: "perri-restored", store: store)
        restored.environment = world.environment
        restored.unsentCheck = { _ in false }
        model = restored
        pane = ReviewSidePaneView(model: restored)
        window.contentView = pane
        window.contentView?.layoutSubtreeIfNeeded()
        return try XCTUnwrap(restored.tabs.first, "the restored tab")
    }

    /// The end state of a first load that was refused: the cover is gone, a notice says why, no spinner.
    private func assertFirstLoadEndedInANotice(_ tab: ReviewTab, mentioning host: String?, button: String?, opens: URL?,
                                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let c = try controller(tab, file: file, line: line)
        await assertTrueA(await spinUntilA(15) { c.contentView.notice.isHidden == false },
                          "a notice appears: cover \"\(c.contentView.cover.message)\" hidden \(c.contentView.cover.isHidden)",
                          file: file, line: line)
        await spinA(0.3)
        XCTAssertTrue(c.contentView.cover.isHidden, "the Loading cover is gone: \"\(c.contentView.cover.message)\"", file: file, line: line)
        XCTAssertFalse(c.contentView.cover.isLoading, "nothing is still spinning", file: file, line: line)
        XCTAssertFalse(c.contentView.notice.message.isEmpty, "the notice says something", file: file, line: line)
        if let host {
            XCTAssertTrue(c.contentView.notice.message.contains(host), "the notice names the host: \(c.contentView.notice.message)",
                          file: file, line: line)
        }
        XCTAssertEqual(c.contentView.notice.buttonTitle, button, file: file, line: line)
        XCTAssertEqual(world.openedExternally, [], "nothing opens the browser by itself", file: file, line: line)
        if let opens {
            c.contentView.notice.press()
            XCTAssertEqual(world.openedExternally, [opens], "the person's press hands the URL to the browser", file: file, line: line)
        }
    }

    /// A first load that has not answered yet: the "Loading…" cover is up.
    private func openStalledTab() async throws -> ReviewTabController {
        world.handler.stalls = { [unowned self] url in url.host == "github.com" && url.path == self.mainPath }
        let tab = openTab()
        let c = try controller(tab)
        await assertTrueA(await spinUntilA(15) { self.world.handler.requestCount(host: "github.com", pathPrefix: self.mainPath) >= 1 },
                          "the start page was asked for")
        XCTAssertFalse(c.contentView.cover.isHidden, "precondition: still covered")
        XCTAssertTrue(c.contentView.cover.isLoading, "precondition: the cover is the Loading cover")
        return c
    }

    func testARestoredJiraTabWhoseSiteIsNoLongerConfiguredEndsInANoticeNotASpinner() async throws {
        world.jiraSite = nil
        let jira = reviewFixtureURL("carefeed.atlassian.net/browse/CORE-1")
        let tab = try showRestoredTab(startingAt: jira, target: .ticket("CORE-1"))

        try await assertFirstLoadEndedInANotice(tab, mentioning: "carefeed.atlassian.net", button: "Open in Browser", opens: jira)
        XCTAssertEqual(world.handler.requests(toHost: "carefeed.atlassian.net"), [], "the blocked page was never requested")
    }

    func testARestoredJiraTabOnTheConfiguredSiteLoadsNormally() async throws {
        world.jiraSite = "carefeed.atlassian.net"
        let tab = try showRestoredTab(startingAt: reviewFixtureURL("carefeed.atlassian.net/browse/CORE-1"), target: .ticket("CORE-1"))
        try await waitForLoaded(tab)
        let c = try controller(tab)
        XCTAssertTrue(c.contentView.notice.isHidden)
        XCTAssertEqual(world.openedExternally, [])
    }

    func testAHopToAnOffListHostDuringTheFirstLoadEndsInANoticeNotASpinner() async throws {
        // The fixture scheme cannot answer with a 3xx, so the hop is the navigation WebKit would report for a
        // redirect: a main-frame request to another host, arriving while the start page has not committed.
        let c = try await openStalledTab()
        let idp = reviewFixtureURL("login.idp.example/authorize?code=ONE-TIME")

        c.webView.load(URLRequest(url: idp))

        try await assertFirstLoadEndedInANotice(c.tab, mentioning: "login.idp.example", button: "Open in Browser", opens: idp)
        XCTAssertEqual(world.handler.requests(toHost: "login.idp.example"), [], "the IdP was never requested")
    }

    func testAnHTTPStartURLEndsInANoticeNamingTheHostAndOffersTheBrowser() async throws {
        let http = URL(string: "http://github.com/acme/web/pull/7")!
        let tab = try showRestoredTab(startingAt: http)

        try await assertFirstLoadEndedInANotice(tab, mentioning: "github.com", button: "Open in Browser", opens: http)
    }

    func testAnHTTPHopDuringTheFirstLoadEndsInANoticeNotASpinner() async throws {
        let c = try await openStalledTab()
        let http = URL(string: "http://github.com/acme/web/pull/7/files")!

        c.webView.load(URLRequest(url: http))

        try await assertFirstLoadEndedInANotice(c.tab, mentioning: "github.com", button: "Open in Browser", opens: http)
    }

    func testAJavaScriptStartURLEndsInANoticeWithNoSpinnerAndNeverReachesTheBrowser() async throws {
        let script = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        let tab = try showRestoredTab(startingAt: script)

        try await assertFirstLoadEndedInANotice(tab, mentioning: nil, button: nil, opens: nil)
        let c = try controller(tab)
        c.openCurrentInBrowser()
        c.contentView.notice.press()
        XCTAssertEqual(world.openedExternally, [], "a javascript: URL is never handed to the browser")
    }

    func testOpenInBrowserNeverHandsOverAScriptOrDataURL() async throws {
        for text in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/hosts"] {
            let tab = try showRestoredTab(startingAt: try XCTUnwrap(URL(string: text)))
            let c = try controller(tab)
            c.openCurrentInBrowser()
            XCTAssertEqual(world.openedExternally, [], text)
        }
    }

    // MARK: The gesture is on THAT link (SR3)

    private let gesturePage = """
        <textarea id="t" style="position:absolute;left:20px;top:20px;width:400px;height:100px"></textarea>
        <a id="out" href="nostromo-fixture://evil.example/landing" style="position:absolute;left:20px;top:200px;width:300px;height:80px;display:block;background:#ccc">outside</a>
        <a id="other" href="nostromo-fixture://evil.example/other" style="position:absolute;left:20px;top:300px;width:300px;height:80px;display:block;background:#ddd">other</a>
        <div id="blank" style="position:absolute;left:20px;top:420px;width:300px;height:80px;background:#eee"></div>
        """

    private func openGestureTab() async throws -> ReviewTab {
        serve(mainPath, ReviewFixtureHandler.html(gesturePage))
        let tab = openTab()
        try await waitForLoaded(tab)
        return tab
    }

    private func centre(of id: String, in tab: ReviewTab) async throws -> NSPoint {
        let box = await js(tab, "(function(){var b=document.getElementById('\(id)').getBoundingClientRect();return [b.left+b.width/2,b.top+b.height/2];})()") as? [Double]
        let xy = try XCTUnwrap(box, "#\(id) has a box")
        return try clickPoint(tab, x: CGFloat(xy[0]), y: CGFloat(xy[1]))
    }

    private func scriptClick(_ id: String, in tab: ReviewTab) async {
        _ = await js(tab, "document.getElementById('\(id)').click(); true")
    }

    private func assertBlockedWithNotice(_ tab: ReviewTab, file: StaticString = #filePath, line: UInt = #line) async {
        await assertTrueA(await spinUntilA(10) { self.notice(tab)?.isHidden == false }, "blocked with a notice", file: file, line: line)
        XCTAssertTrue(notice(tab)?.message.contains("evil.example") == true, "the notice names the host: \(notice(tab)?.message ?? "nil")",
                      file: file, line: line)
        await spinA(0.4)
        XCTAssertEqual(world.openedExternally, [], "SR3: not a person's gesture on that link", file: file, line: line)
        assertTabStayedPut(tab, file: file, line: line)
        assertNoRequestReachedEvil(file: file, line: line)
    }

    func testTypingInATextareaThenAScriptClickOnAnOutsideLinkDoesNotOpenTheBrowser() async throws {
        let tab = try await openGestureTab()
        try await typeInto("t", "hello", tab: tab)

        await scriptClick("out", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testARealClickOnTheOutsideLinkOpensTheBrowserOnce() async throws {
        let tab = try await openGestureTab()
        let point = try await centre(of: "out", in: tab)

        ReviewEvents.click(at: point, in: window)

        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty }, "the click opened the link")
        await spinA(0.4)
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")])
        assertTabStayedPut(tab)
        assertNoRequestReachedEvil()
    }

    func testARealClickElsewhereThenAScriptClickOnTheLinkDoesNotOpenTheBrowser() async throws {
        let tab = try await openGestureTab()
        let elsewhere = try await centre(of: "blank", in: tab)

        ReviewEvents.click(at: elsewhere, in: window)
        await scriptClick("out", in: tab)          // well inside the one-second window

        await assertBlockedWithNotice(tab)
    }

    func testARealClickInTheTextareaThenAScriptClickOnTheLinkDoesNotOpenTheBrowser() async throws {
        let tab = try await openGestureTab()
        let inside = try await centre(of: "t", in: tab)

        ReviewEvents.click(at: inside, in: window)
        await scriptClick("out", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testARealClickOnOneLinkDoesNotAuthoriseAScriptClickOnAnother() async throws {
        let tab = try await openGestureTab()
        let first = try await centre(of: "out", in: tab)

        ReviewEvents.click(at: first, in: window)
        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty }, "the first link opened")
        await scriptClick("other", in: tab)

        await assertTrueA(await spinUntilA(10) { self.notice(tab)?.isHidden == false }, "the second was blocked")
        await spinA(0.4)
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")], "only the link that was clicked")
    }

    func testReturnOnAFocusedOutsideLinkThenAScriptClickOpensTheBrowser() async throws {
        let tab = try await openGestureTab()
        let c = try controller(tab)
        // The page ignores Return itself, so only the person's key press can account for the click that follows.
        _ = await js(tab, "var l=document.getElementById('out'); l.addEventListener('keydown',function(e){e.preventDefault();}); l.focus(); true")
        window.makeFirstResponder(c.webView)

        ReviewEvents.key(36, characters: "\r", in: window)
        await scriptClick("out", in: tab)

        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty }, "Return with the link focused is a gesture on it")
        await spinA(0.3)
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")])
        assertNoRequestReachedEvil()
    }

    func testReturnOnAFocusedOutsideLinkActivatesItAndOpensTheBrowser() async throws {
        let tab = try await openGestureTab()
        let c = try controller(tab)
        _ = await js(tab, "document.getElementById('out').focus(); true")
        window.makeFirstResponder(c.webView)

        ReviewEvents.key(36, characters: "\r", in: window)

        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty }, "Return on the focused link follows it")
        XCTAssertEqual(world.openedExternally.first, reviewFixtureURL("evil.example/landing"))
        assertTabStayedPut(tab)
    }

    func testReturnInATextareaThenAScriptClickOnTheLinkDoesNotOpenTheBrowser() async throws {
        let tab = try await openGestureTab()
        let c = try controller(tab)
        _ = await js(tab, "document.getElementById('t').focus(); true")
        window.makeFirstResponder(c.webView)

        ReviewEvents.key(36, characters: "\r", in: window)
        await scriptClick("out", in: tab)

        await assertBlockedWithNotice(tab)
    }

    // MARK: A form's submit is the person's only when the gesture was on THAT form

    private let formGesturePage = """
        <textarea id="t" style="position:absolute;left:20px;top:20px;width:400px;height:80px"></textarea>
        <div id="blank" style="position:absolute;left:20px;top:120px;width:300px;height:60px;background:#eee"></div>
        <form id="f" method="post" action="nostromo-fixture://evil.example/submit" style="position:absolute;left:20px;top:200px;width:400px;height:200px">
          <textarea id="ft" name="ft" style="width:300px;height:50px"></textarea>
          <input id="fi" name="fi" style="display:block;width:200px">
          <button id="go" type="submit" style="display:block;width:200px;height:40px">go</button>
        </form>
        <form id="g" method="post" action="nostromo-fixture://evil.example/other" style="position:absolute;left:20px;top:420px;width:400px;height:100px">
          <button id="gogo" type="submit" style="display:block;width:200px;height:40px">go</button>
        </form>
        """

    private func openFormGestureTab() async throws -> ReviewTab {
        serve(mainPath, ReviewFixtureHandler.html(formGesturePage))
        let tab = openTab()
        try await waitForLoaded(tab)
        return tab
    }

    private func scriptSubmit(_ id: String, in tab: ReviewTab) async {
        _ = await js(tab, "document.getElementById('\(id)').submit(); true")
    }

    private func focus(_ id: String, in tab: ReviewTab) async throws {
        let c = try controller(tab)
        _ = await js(tab, "document.getElementById('\(id)').focus(); true")
        window.makeFirstResponder(c.webView)
    }

    func testSpaceTypedInATextareaThenAScriptFormSubmitDoesNotOpenTheBrowser() async throws {
        let tab = try await openFormGestureTab()
        try await focus("t", in: tab)

        ReviewEvents.key(49, characters: " ", in: window)
        await scriptSubmit("f", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testSpaceTypedInATextareaInsideTheFormThenAScriptSubmitDoesNotOpenTheBrowser() async throws {
        let tab = try await openFormGestureTab()
        try await focus("ft", in: tab)

        ReviewEvents.key(49, characters: " ", in: window)
        await scriptSubmit("f", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testAClickOnEmptyPageThenAScriptFormSubmitDoesNotOpenTheBrowser() async throws {
        let tab = try await openFormGestureTab()

        ReviewEvents.click(at: try await centre(of: "blank", in: tab), in: window)
        await scriptSubmit("f", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testAClickOnAnotherFormsSubmitButtonDoesNotAuthoriseAScriptSubmitOfThisOne() async throws {
        let tab = try await openFormGestureTab()
        // The page swallows the click so the real submit of form g does not happen by itself.
        _ = await js(tab, "document.getElementById('g').addEventListener('submit',function(e){e.preventDefault();}); true")

        ReviewEvents.click(at: try await centre(of: "gogo", in: tab), in: window)
        await scriptSubmit("f", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testARealClickOnTheFormsSubmitButtonOpensTheBrowserOnce() async throws {
        let tab = try await openFormGestureTab()

        ReviewEvents.click(at: try await centre(of: "go", in: tab), in: window)

        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty }, "the submit button opened the form's target")
        await spinA(0.4)
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/submit")])
        assertTabStayedPut(tab)
        assertNoRequestReachedEvil()
    }

    func testReturnInTheFormsOwnFieldOpensTheBrowserOnce() async throws {
        let tab = try await openFormGestureTab()
        try await focus("fi", in: tab)

        ReviewEvents.key(36, characters: "\r", in: window)

        await assertTrueA(await spinUntilA(10) { !self.world.openedExternally.isEmpty }, "Return in the form's field submits it")
        await spinA(0.4)
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/submit")])
        assertNoRequestReachedEvil()
    }

    // MARK: The gesture window and which keys count

    func testTheGestureWindowIsOneSecond() {
        XCTAssertEqual(ReviewWebView.gestureWindow, 1, "widening the window widens what a page can ride on")
    }

    func testReturnOnTheLinkThenAScriptClickAfterTheWindowDoesNotOpenTheBrowser() async throws {
        let tab = try await openGestureTab()
        let c = try controller(tab)
        _ = await js(tab, "var l=document.getElementById('out'); l.addEventListener('keydown',function(e){e.preventDefault();}); l.focus(); true")
        window.makeFirstResponder(c.webView)

        ReviewEvents.key(36, characters: "\r", in: window)   // a real gesture on that very link
        await spinA(ReviewWebView.gestureWindow + 0.4)
        await scriptClick("out", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testTabKeyWithTheLinkFocusedIsNotAGesture() async throws {
        let tab = try await openGestureTab()
        let c = try controller(tab)
        _ = await js(tab, "var l=document.getElementById('out'); l.addEventListener('keydown',function(e){e.preventDefault();}); l.focus(); true")
        window.makeFirstResponder(c.webView)

        ReviewEvents.key(48, characters: "\t", in: window)
        await scriptClick("out", in: tab)

        await assertBlockedWithNotice(tab)
    }

    func testTabKeyWithTheFormsSubmitButtonFocusedIsNotAGesture() async throws {
        let tab = try await openFormGestureTab()
        _ = await js(tab, "var b=document.getElementById('go'); b.addEventListener('keydown',function(e){e.preventDefault();}); true")
        try await focus("go", in: tab)

        ReviewEvents.key(48, characters: "\t", in: window)
        await scriptSubmit("f", in: tab)

        await assertBlockedWithNotice(tab)
    }

    // MARK: A first load whose response is an attachment

    func testAFirstLoadThatIsAnAttachmentShowsTheNoticeWithoutALoadingCover() async throws {
        let base = world.handler.respond
        world.handler.respond = { url in
            if url.path == self.mainPath {
                return ReviewFixtureHandler.Response(body: "PK", mime: "application/octet-stream",
                                                     headers: ["Content-Disposition": "attachment; filename=pr.zip"])
            }
            return base(url)
        }
        let tab = openTab()

        await assertTrueA(await spinUntilA(15) { self.notice(tab)?.isHidden == false }, "the download notice appears")
        XCTAssertEqual(notice(tab)?.message, "Downloads open in your browser.")
        let c = try controller(tab)
        await assertTrueA(await spinUntilA(5) { c.contentView.cover.isHidden }, "the Loading… cover is gone: \"\(c.contentView.cover.message)\"")
        XCTAssertFalse(c.contentView.cover.isLoading)
    }

    // MARK: Unsent-text probe is bounded even when the page is busy

    func testTheUnsentProbeReturnsPromptlyAndReportsUnsentWhileThePageIsBusy() async throws {
        let tab = try await openFormTab()
        let c = try controller(tab)
        // The page is stuck in a three second loop when the probe asks.
        _ = await js(tab, "setTimeout(function(){var t=Date.now();while(Date.now()-t<3000);},0); true")
        await spinA(0.15)

        let started = Date()
        let unsent = await c.hasUnsentInput()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(unsent, "no answer in time counts as unsent: the tab is kept")
        XCTAssertLessThan(elapsed, 1.5, "a busy page does not hold the caller up (took \(elapsed) s)")
        XCTAssertGreaterThanOrEqual(elapsed, 0.4, "it did wait for the page for its bound (took \(elapsed) s)")
        _ = try? await c.webView.evaluateJavaScript("1")       // let the page finish its loop before teardown
    }

    func testTheUnsentProbeOnAQuietPageWithNoTextAnswersFalseQuickly() async throws {
        let tab = try await openFormTab()
        let c = try controller(tab)

        let started = Date()
        let unsent = await c.hasUnsentInput()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(unsent)
        XCTAssertLessThan(elapsed, 0.4, "took \(elapsed) s")
    }

    // MARK: Two windows, one pane

    private let otherWindowText = "Side pane is open in another window."

    private func openElsewhereCover(in root: NSView) -> ReviewMessageView? {
        func walk(_ view: NSView) -> [ReviewMessageView] {
            view.subviews.flatMap { sub -> [ReviewMessageView] in
                var found = walk(sub)
                if let cover = sub as? ReviewMessageView { found.append(cover) }
                return found
            }
        }
        return walk(root).first { $0.message == otherWindowText }
    }

    func testASecondWindowTakesThePaneAndHandsItBackWhenItLeaves() async throws {
        let tab = openTab()
        try await waitForLoaded(tab)
        let c = try controller(tab)
        let first = try XCTUnwrap(pane)
        let firstID = ObjectIdentifier(first)
        XCTAssertEqual(model.presenterID, firstID, "precondition: the only window presents")
        XCTAssertEqual(openElsewhereCover(in: first)?.isHidden, true, "and shows no 'other window' cover")

        let secondWindow = ReviewTestWindow.make(size: NSSize(width: 900, height: 700))
        defer { secondWindow.contentView = NSView(); secondWindow.close() }
        let second = ReviewSidePaneView(model: model)
        let secondID = ObjectIdentifier(second)
        secondWindow.contentView = second
        secondWindow.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(model.presenterID, secondID, "the window shown last presents")
        XCTAssertEqual(openElsewhereCover(in: first)?.isHidden, false, "the first window says the pane is open in another window")
        XCTAssertEqual(openElsewhereCover(in: second)?.isHidden, true)
        XCTAssertTrue(c.contentView.isDescendant(of: second), "the web view is in the second window")
        XCTAssertFalse(c.contentView.isDescendant(of: first))

        secondWindow.contentView = NSView()         // the second window's pane leaves its window

        XCTAssertEqual(model.presenterID, firstID, "the first window presents again")
        XCTAssertEqual(openElsewhereCover(in: first)?.isHidden, true, "its cover is gone")
        XCTAssertTrue(c.contentView.isDescendant(of: first), "and it shows the web view again")

        window.contentView = NSView()               // the only presenter leaves
        XCTAssertNil(model.presenterID, "nothing presents")
    }
}
