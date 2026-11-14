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
        spin(0.3)
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
        XCTAssertTrue(spinUntil(15) { !c.webView.isLoading && c.webView.url == tab.startURL && c.contentView.cover.isHidden },
                      "the fixture page loaded", file: file, line: line)
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
            spin(0.05)
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
        let loaded = spinUntil(20) { !c.webView.isLoading && c.webView.url == tab.startURL }
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
        XCTAssertTrue(spinUntil(15) { self.notice(tab)?.isHidden == false },
                      "the notice appears", file: file, line: line)
        XCTAssertTrue(notice(tab)?.message.contains("evil.example") == true,
                      "SR2: the notice names the host: \(notice(tab)?.message ?? "nil")", file: file, line: line)
        XCTAssertEqual(notice(tab)?.buttonTitle, "Open in Browser", file: file, line: line)
        spin(0.7)       // a stray load would have reached the handler by now
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
        XCTAssertTrue(spinUntil(15) { self.notice(tab)?.isHidden == false })
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

        XCTAssertTrue(spinUntil(10) { !self.world.openedExternally.isEmpty }, "the click reached the page and the link opened")
        spin(0.5)
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")], "exactly once, with the URL")
        assertTabStayedPut(tab)
        assertNoRequestReachedEvil()
    }

    func testTheSameLinkActivatedByScriptDoesNotOpenTheBrowser() async throws {
        serve(mainPath, ReviewFixtureHandler.html(outsideLink))
        let tab = openTab()
        try await waitForLoaded(tab)

        _ = await js(tab, "document.getElementById('out').click(); true")

        XCTAssertTrue(spinUntil(10) { self.notice(tab)?.isHidden == false }, "blocked with a notice instead")
        XCTAssertTrue(notice(tab)?.message.contains("evil.example") == true)
        spin(0.3)
        XCTAssertEqual(world.openedExternally, [], "SR3: script is not a person")
        assertTabStayedPut(tab)
        assertNoRequestReachedEvil()
    }

    func testAScriptClickLongAfterARealClickDoesNotOpenTheBrowser() async throws {
        serve(mainPath, ReviewFixtureHandler.html(outsideLink))
        let tab = openTab()
        try await waitForLoaded(tab)

        try realClick(tab, x: 100, y: 240)          // a real click on empty page: a human event, but not on the link
        spin(ReviewWebView.gestureWindow + 0.5)     // the gesture has gone stale
        _ = await js(tab, "document.getElementById('out').click(); true")

        XCTAssertTrue(spinUntil(10) { self.notice(tab)?.isHidden == false })
        spin(0.3)
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

        XCTAssertTrue(spinUntil(10) { self.notice(tab)?.isHidden == false }, "blocked with a notice")
        spin(0.3)
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

        XCTAssertTrue(spinUntil(10) { tab.currentURL == reviewFixtureURL("github.com/acme/web/pull/7/files") },
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

        XCTAssertTrue(spinUntil(10) { !self.world.openedExternally.isEmpty })
        XCTAssertEqual(world.openedExternally, [reviewFixtureURL("evil.example/landing")])
        spin(0.3)
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

        XCTAssertTrue(spinUntil(10) { self.model.tabs.count == 2 }, "the popup became a pane tab")
        let popup = try XCTUnwrap(model.tabs.first { $0.id != tab.id })
        if case .page = popup.target {} else { XCTFail("a popup is a page tab, not \(popup.target)") }
        XCTAssertEqual(popup.pr, pr, "it belongs to the PR it was opened from")
        XCTAssertTrue(spinUntil(10) { self.world.handler.requestCount(host: "github.com", pathPrefix: "/acme/web/issues/9") >= 1 },
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
        spin(0.6)       // the script's navigation has been tried

        try realClick(tab, x: 100, y: 60)
        spin(0.8)

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
        func obtain(dataStore: WKWebsiteDataStore) -> WKFrameInfo? {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = dataStore
            config.userContentController.add(self, name: "probe")
            let w = WKWebView(frame: .zero, configuration: config)
            web = w
            w.loadHTMLString("<script>window.webkit.messageHandlers.probe.postMessage('x')</script>", baseURL: nil)
            spinUntil(10) { self.frameInfo != nil }
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
        let frame = try XCTUnwrap(probe.obtain(dataStore: world.dataStore), "a real frame to ask about")

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
        let frame = try XCTUnwrap(FrameProbe().obtain(dataStore: world.dataStore))

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

        XCTAssertTrue(spinUntil(15) { self.notice(tab)?.isHidden == false }, "the notice appears")
        XCTAssertEqual(notice(tab)?.message, "Downloads open in your browser.")
        XCTAssertEqual(notice(tab)?.buttonTitle, "Open in Browser")
        XCTAssertEqual(tab.controller?.webView.url, tab.startURL, "the tab stayed on its page")
        XCTAssertEqual(tab.currentURL, tab.startURL)
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

        XCTAssertTrue(spinUntil(10) { self.notice(tab)?.isHidden == false }, "the download notice appears")
        XCTAssertEqual(notice(tab)?.message, "Downloads open in your browser.")
        spin(0.3)
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

        XCTAssertTrue(spinUntil(15) { c.contentView.cover.buttonTitle == "Retry" && !c.contentView.cover.isHidden },
                      "the error cover with a Retry button appears")
        XCTAssertTrue(c.contentView.cover.message.contains("github.com"), "it names the host: \(c.contentView.cover.message)")
        XCTAssertFalse(c.contentView.cover.message.contains("/acme/web"), "and not the path")
        let requestsBefore = world.handler.requestCount(host: "github.com", pathPrefix: mainPath)

        failing = false
        c.contentView.cover.press()
        c.contentView.cover.press()      // a second press while it reloads must not load again

        XCTAssertTrue(spinUntil(15) { c.contentView.cover.isHidden && !c.webView.isLoading && c.webView.url == tab.startURL },
                      "the page loaded and the cover went away")
        spin(0.5)
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
        XCTAssertTrue(spinUntil(15) { c.contentView.cover.isHidden && !c.webView.isLoading }, "Reload brings the page back")
        XCTAssertGreaterThan(world.handler.requestCount(host: "github.com", pathPrefix: mainPath), before)
    }
}
