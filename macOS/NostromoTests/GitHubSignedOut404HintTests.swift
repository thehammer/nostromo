import XCTest
import AppKit
import WebKit

// Perri side pane, slice 3 (criterion 36): GitHub shows 404 for a private repo while signed out. A main-frame
// 404 on github.com whose page says nobody is signed in (`<meta name="user-login">` empty or missing) gets a
// native hint with **Sign in**, which goes to /login?return_to=<the page's path and query>. A 404 for someone
// who is signed in gets nothing. Pages come from the offline fixture scheme; nothing touches the network.

@MainActor
final class GitHubSignedOut404HintTests: XCTestCase {

    private var world: ReviewFixtureWorld!
    private var model: ReviewPaneModel!
    private var window: ReviewTestWindow!
    private var pane: ReviewSidePaneView!
    /// Paths (on github.com) that answer 404, with the user-login meta they carry (nil: no meta at all).
    private var notFound: [String: String?] = [:]
    private var loggedIn = false

    private let pr = ReviewPR(repo: "acme/secret", number: 7)
    private let filesPath = "/acme/secret/pull/7/files"

    override func setUp() async throws {
        try await super.setUp()
        world = ReviewFixtureWorld()
        notFound = [:]
        loggedIn = false
        world.handler.respond = { [unowned self] url in
            if url.path == "/login" {
                // The fixture "sign-in": goes straight back to where return_to says.
                let back = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "return_to" }?.value ?? "/"
                self.loggedIn = true
                return .init(body: ReviewFixtureHandler.html(
                    "<script>location.replace('\(reviewFixtureScheme)://github.com' + \(Self.jsLiteral(back)))</script>",
                    title: "login"))
            }
            if !self.loggedIn, let meta = self.notFound[url.path] {
                let head = meta.map { "<meta name=\"user-login\" content=\"\($0)\">" } ?? ""
                return .init(body: ReviewFixtureHandler.html("<h1>404</h1>", title: "Page not found", head: head), status: 404)
            }
            return .init(body: ReviewFixtureHandler.html("<h1>found</h1>", title: "found",
                                                         head: "<meta name=\"user-login\" content=\"hammer\">"))
        }
        model = ReviewPaneModel(tag: "perri-404-\(UUID().uuidString)", store: nil)
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
        pane = nil; model = nil; window = nil
        await spinA(0.3)
        await world.removeDataStore()
        world = nil
        try await super.tearDown()
    }

    private static func jsLiteral(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"/\"]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    private func openDiff() -> ReviewTab {
        model.open(pr: pr, target: .diff, url: reviewFixtureURL("github.com\(filesPath)?w=1"))
    }

    private func notice(_ tab: ReviewTab) -> ReviewMessageView? { tab.controller?.contentView.notice }

    private func eventually(_ timeout: TimeInterval = 10, _ check: () -> Bool) async -> Bool {
        await spinUntilA(timeout, check)
    }

    private func hintShown(_ tab: ReviewTab) -> Bool {
        guard let n = notice(tab) else { return false }
        return !n.isHidden && n.message == ReviewTabController.signedOutHint
    }

    func testThePageProbeReadsSignedOutAndSignedInFromTheMeta() async throws {
        notFound[filesPath] = .some(nil)
        let out = openDiff()
        let c = try XCTUnwrap(out.controller)
        await assertTrueA(await eventually(15) { !c.webView.isLoading && c.webView.url?.path == self.filesPath
            && c.contentView.cover.isHidden }, "the 404 page loaded")
        await assertTrueA(await c.isSignedOutOfGitHub(), "no meta: signed out")
        XCTAssertEqual(world.handler.statuses[reviewFixtureURL("github.com\(filesPath)?w=1")], 404)

        let signedIn = model.open(pr: ReviewPR(repo: "acme/secret", number: 8), target: .diff,
                                  url: reviewFixtureURL("github.com/acme/secret/pull/8/files"))
        let c2 = try XCTUnwrap(signedIn.controller)
        await assertTrueA(await eventually(15) { !c2.webView.isLoading && c2.webView.url?.path == "/acme/secret/pull/8/files"
            && c2.contentView.cover.isHidden }, "a found page loaded (it carries user-login=hammer)")
        let signedOut = await c2.isSignedOutOfGitHub()
        XCTAssertFalse(signedOut, "user-login=hammer: signed in")
    }

    func testASignedOut404ShowsTheHintWithSignIn() async throws {
        notFound[filesPath] = .some(nil)        // 404, no user-login meta
        let tab = openDiff()
        await assertTrueA(await eventually { hintShown(tab) }, "the hint is shown; notice: \(notice(tab)?.message ?? "nil")")
        XCTAssertEqual(notice(tab)?.buttonTitle, "Sign in")
    }

    func testAnEmptyUserLoginMetaCountsAsSignedOut() async throws {
        notFound[filesPath] = .some("")
        let tab = openDiff()
        await assertTrueA(await eventually { hintShown(tab) }, "empty content means signed out")
    }

    func testSignInGoesToLoginWithTheEncodedPathAndQueryAndThenBackToThePR() async throws {
        notFound[filesPath] = .some(nil)
        let tab = openDiff()
        await assertTrueA(await eventually { hintShown(tab) }, "hint shown")

        notice(tab)?.press()

        let expectedReturn = "%2Facme%2Fsecret%2Fpull%2F7%2Ffiles%3Fw%3D1"
        await assertTrueA(await eventually {
            world.handler.requested.contains { $0.host == "github.com" && $0.path == "/login"
                && $0.absoluteString.hasSuffix("/login?return_to=\(expectedReturn)") }
        }, "sign-in went to /login?return_to=…: \(world.handler.requested.map(\.absoluteString))")
        // Criterion 36: after the fixture login, GitHub returns to the PR.
        await assertTrueA(await eventually(15) {
            tab.controller?.webView.url?.path == self.filesPath && tab.controller?.webView.isLoading == false
        }, "back on the PR: \(String(describing: tab.controller?.webView.url))")
        XCTAssertEqual(world.handler.requested.filter { $0.path == filesPath }.count, 2, "the PR was requested again after login")
        XCTAssertFalse(hintShown(tab), "the hint went away once the page loaded")
    }

    func testASignedIn404ShowsNoHint() async throws {
        notFound[filesPath] = .some("hammer")
        let tab = openDiff()
        let c = try XCTUnwrap(tab.controller)
        await assertTrueA(await eventually(15) { !c.webView.isLoading && c.webView.url?.path == self.filesPath
            && c.contentView.cover.isHidden }, "the 404 page loaded")
        await spinA(1.0)
        XCTAssertFalse(hintShown(tab), "a signed-in 404 is just a 404")
    }

    func testAPageThatIsFoundShowsNoHint() async throws {
        let tab = openDiff()
        let c = try XCTUnwrap(tab.controller)
        await assertTrueA(await eventually(15) { !c.webView.isLoading && c.webView.url?.path == self.filesPath
            && c.contentView.cover.isHidden }, "the page loaded")
        await spinA(1.0)
        XCTAssertFalse(hintShown(tab))
    }

    func testTheSignInURLKeepsOnlyPathAndQueryOfTheNotFoundPage() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/acme/secret/pull/7/files?w=1&x=a b#frag"))
        let signIn = try XCTUnwrap(ReviewTabController.signInURL(for: url))
        XCTAssertEqual(signIn.absoluteString, "https://github.com/login?return_to=%2Facme%2Fsecret%2Fpull%2F7%2Ffiles%3Fw%3D1%26x%3Da%2520b")
    }
}
