import AppKit
import WebKit
import Combine
import os

/// What a tab needs from the outside. Tests replace the pieces (fixture scheme, a spy opener).
struct ReviewPaneEnvironment {
    var hosts: () -> ReviewPaneHosts = { ReviewPaneHosts(jiraSite: AppStore.shared.perriJiraSite) }
    var openExternal: (URL) -> Void = ReviewPaneEnvironment.openInDefaultBrowser
    var makeConfiguration: () -> WKWebViewConfiguration = {
        ReviewWebViewFactory.makeConfiguration(dataStore: BrowserProfile.work())
    }

    /// The audited production opener.
    static func openInDefaultBrowser(_ url: URL) {
        ActivationAudit.note("review-pane:open-external-url")
        NSWorkspace.shared.open(url)
    }
}

/// A message laid over a tab by Nostromo (never HTML in the page): loading, error, crash, blocked host,
/// download and upload notices. Native AppKit with an optional button.
final class ReviewMessageView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)
    private var action: (() -> Void)?
    let spinner = NSProgressIndicator()
    /// Whether the message is a "Loading…" cover (as opposed to an error or crash message).
    private(set) var isLoading = false

    init(opaque: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = (opaque ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.16, alpha: 1)).cgColor
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.font = .systemFont(ofSize: 12)
        label.alignment = opaque ? .center : .left
        label.maximumNumberOfLines = 0
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(pressed)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = NSStackView(views: [spinner, label, button])
        stack.orientation = opaque ? .vertical : .horizontal
        stack.alignment = opaque ? .centerX : .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        if opaque {
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
                stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            ])
        } else {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            ])
        }
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The text shown (read by tests).
    var message: String { label.stringValue }
    var buttonTitle: String? { button.isHidden ? nil : button.title }

    func show(_ text: String, button title: String? = nil, spinning: Bool = false, action: (() -> Void)? = nil) {
        label.stringValue = text
        self.action = action
        button.isHidden = title == nil
        button.title = title ?? ""
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        isLoading = spinning
        isHidden = false
        setAccessibilityLabel(text)
    }

    func dismiss() { isHidden = true; isLoading = false; spinner.stopAnimation(nil) }

    func press() { action?() }
    @objc private func pressed() { action?() }
}

/// Holds one tab's web view and the overlays over it.
final class ReviewTabContentView: NSView {
    let webView: ReviewWebView
    let notice = ReviewMessageView(opaque: false)     // top bar: blocked host, download, upload
    let cover = ReviewMessageView(opaque: true)       // full cover: loading, error, crash

    init(webView: ReviewWebView) {
        self.webView = webView
        super.init(frame: .zero)
        for sub in [webView, notice, cover] as [NSView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
        }
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            notice.leadingAnchor.constraint(equalTo: leadingAnchor), notice.trailingAnchor.constraint(equalTo: trailingAnchor),
            notice.topAnchor.constraint(equalTo: topAnchor),
            cover.leadingAnchor.constraint(equalTo: leadingAnchor), cover.trailingAnchor.constraint(equalTo: trailingAnchor),
            cover.topAnchor.constraint(equalTo: topAnchor), cover.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// One tab's web view, adapting WebKit's callbacks to `ReviewNavigationPolicy` and showing the tab's
/// native overlays. Logs at most the host and an event name (SR7).
final class ReviewTabController: NSObject, WKNavigationDelegate, WKUIDelegate {

    private static let log = Logger(subsystem: "com.hammer.nostromo.mac", category: "ReviewPane")

    let tab: ReviewTab
    let webView: ReviewWebView
    let contentView: ReviewTabContentView
    private let env: ReviewPaneEnvironment
    private var observers: [NSKeyValueObservation] = []
    /// Where a retry after an error goes, once.
    private var failedURL: URL?
    /// A window the page opened that starts at about:blank is judged on its next navigation.
    private var isPopup = false
    private var loadStarted = false
    /// The URL of a main-frame GitHub 404 response, until that page finishes loading (then it is checked
    /// for a signed-out session).
    private var githubNotFoundURL: URL?
    /// Whether the notice bar currently shows the signed-out hint.
    private var signedOutHintShown = false

    static let signedOutHint = "GitHub shows 404 for private repos when you're signed out."
    static let signInButton = "Sign in"

    /// Called when the tab should close itself (`window.close()`).
    var onClose: (() -> Void)?
    /// Called when a page asks for a new window to an allowed host: returns the web view to use.
    var onNewWindow: ((WKWebViewConfiguration, URL?) -> ReviewTabController?)?
    /// Called whenever the URL or title changed (so the model can save).
    var onStateChange: (() -> Void)?

    init(tab: ReviewTab, env: ReviewPaneEnvironment, configuration: WKWebViewConfiguration? = nil, isPopup: Bool = false) {
        self.tab = tab
        self.env = env
        self.isPopup = isPopup
        webView = ReviewWebViewFactory.makeWebView(configuration: configuration ?? env.makeConfiguration())
        contentView = ReviewTabContentView(webView: webView)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.setAccessibilityLabel("Page: \(tab.title)")
        observe()
    }

    deinit { observers.removeAll() }

    // MARK: Loading and state

    /// Loads the tab's last URL. Called once, when the tab is first shown. A popup already has its request.
    func loadInitial() {
        guard !isPopup, !loadStarted, webView.url == nil else { return }
        loadStarted = true
        // WebKit never consults the policy for a `javascript:` load and never commits it: a start URL
        // that is not https gets its notice here instead of a "Loading…" cover that nothing would dismiss.
        guard env.hosts().isSecureScheme(tab.currentURL) else {
            Self.log.info("review-pane event=blocked-scheme")
            showInsecureNotice(url: tab.currentURL)
            return
        }
        contentView.cover.show("Loading…", spinning: true)
        // Handing the request to WebKit takes tens of milliseconds: after the pane has appeared, not before.
        let request = URLRequest(url: tab.currentURL)
        DispatchQueue.main.async { [weak self] in self?.webView.load(request) }
    }

    func teardown() {
        observers.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        contentView.removeFromSuperview()
    }

    func hasUnsentInput() async -> Bool { await UnsentInputProbe.hasUnsentInput(in: webView) }

    func focusWebView() { webView.window?.makeFirstResponder(webView) }

    /// Only an http(s) page goes to the browser (a `javascript:` or `data:` start URL never does).
    func openCurrentInBrowser() {
        let url = webView.url ?? tab.currentURL
        guard Self.isWebURL(url) else { return }
        env.openExternal(url)
    }

    private static func isWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    private func observe() {
        observers.append(webView.observe(\.url, options: [.new]) { [weak self] web, _ in
            guard let self, let url = web.url, url.absoluteString != "about:blank" else { return }
            self.tab.currentURL = url
            self.onStateChange?()
        })
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] web, _ in
            guard let self, case .page = self.tab.target, let title = web.title, !title.isEmpty else { return }
            self.tab.title = title
            self.onStateChange?()
        })
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Only judge main-frame and new-window navigations by host; subframes must still be https.
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let blankPopup = isPopup && url.absoluteString == "about:blank"
        if blankPopup { decisionHandler(.allow); return }
        let request = ReviewNavigationRequest(
            url: url, isMainFrame: isMain, opensNewWindow: navigationAction.targetFrame == nil,
            kind: Self.kind(of: navigationAction.navigationType),
            recentHumanInput: false,
            isDownload: navigationAction.shouldPerformDownload)
        let decision = ReviewNavigationPolicy(hosts: env.hosts()).decide(request)
        if case .block = decision, resolveWithGesture(request) {
            decisionHandler(.cancel)
            return
        }
        switch decision {
        case .allow, .openInPane:
            if !isMain && !request.isDownload { decisionHandler(.allow); return }
            isPopup = false
            decisionHandler(.allow)
        case .openInDefaultBrowser(let external):
            Self.log.info("review-pane event=open-external host=\(external.host ?? "", privacy: .public)")
            env.openExternal(external)
            dismissLoadingCover(ifMainFrame: isMain)
            decisionHandler(.cancel)
        case .block(let host):
            Self.log.info("review-pane event=blocked host=\(host, privacy: .public)")
            showBlockedNotice(host: host, url: url)
            dismissLoadingCover(ifMainFrame: isMain)
            decisionHandler(.cancel)
        case .blockSilently:
            Self.log.info("review-pane event=blocked-scheme")
            if isMain { showInsecureNotice(url: url) }
            dismissLoadingCover(ifMainFrame: isMain)
            decisionHandler(.cancel)
        case .blockDownload(let download):
            showDownloadNotice(url: download)
            dismissLoadingCover(ifMainFrame: isMain)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame {
            let http = navigationResponse.response as? HTTPURLResponse
            let isGitHub = http?.url?.host?.lowercased() == "github.com"
            githubNotFoundURL = (isGitHub && http?.statusCode == 404) ? http?.url : nil
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            showDownloadNotice(url: navigationResponse.response.url)
            // Nothing commits, so a "Loading…" cover would stay over the notice.
            dismissLoadingCover(ifMainFrame: navigationResponse.isForMainFrame)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        contentView.cover.dismiss()
        failedURL = nil
        if signedOutHintShown { contentView.notice.dismiss(); signedOutHintShown = false }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let notFound = githubNotFoundURL else { return }
        githubNotFoundURL = nil
        Task { @MainActor [weak self] in
            guard let self, await self.isSignedOutOfGitHub() else { return }
            self.showSignedOutHint(for: notFound)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showError(error)
    }

    /// Never a "continue anyway": challenges get the system's default handling.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("review-pane event=content-process-terminated")
        contentView.cover.show("This page stopped.", button: "Reload") { [weak self] in
            guard let self else { return }
            self.contentView.cover.show("Loading…", spinning: true)
            self.webView.reload()
        }
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = navigationAction.request.url
        let blank = url == nil || url?.absoluteString == "about:blank" || url?.absoluteString.isEmpty == true
        let request = ReviewNavigationRequest(
            url: url ?? URL(string: "about:blank")!, isMainFrame: true, opensNewWindow: true,
            kind: Self.kind(of: navigationAction.navigationType),
            recentHumanInput: false,
            isDownload: navigationAction.shouldPerformDownload, isInitialBlank: blank)
        let decision = ReviewNavigationPolicy(hosts: env.hosts()).decide(request)
        if case .block = decision, resolveWithGesture(request) { return nil }
        switch decision {
        case .openInPane, .allow:
            return onNewWindow?(configuration, blank ? nil : url)?.webView
        case .openInDefaultBrowser(let external):
            env.openExternal(external)
            return nil
        case .block(let host):
            if let url { showBlockedNotice(host: host, url: url) }
            return nil
        case .blockSilently:
            return nil
        case .blockDownload(let download):
            showDownloadNotice(url: download)
            return nil
        }
    }

    func webViewDidClose(_ webView: WKWebView) { onClose?() }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        completionHandler(nil)
        contentView.notice.show("Uploads aren't available here.")
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    // MARK: User gesture

    /// SR3: a link or form to a host off the list goes to the default browser only when a person clicked
    /// THAT link (mouse-up on it) or pressed Return/Space with it focused, or a person used a submit control of THAT form. The page cannot tell us; the
    /// check runs after the navigation was cancelled. When a gesture is plausible the answer arrives
    /// later (returns true: the caller cancels now); with none, the caller blocks at once (returns false).
    private func resolveWithGesture(_ request: ReviewNavigationRequest) -> Bool {
        guard request.kind == .link || request.kind == .form, webView.recentHumanInput else { return false }
        let url = request.url
        let isMain = request.isMainFrame
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The gesture must be on THIS link, or on a control of THIS form.
            let confirmed = request.kind == .form
                ? await self.webView.gestureConfirms(form: url)
                : await self.webView.gestureConfirms(link: url)
            if confirmed {
                Self.log.info("review-pane event=open-external host=\(url.host ?? "", privacy: .public)")
                self.env.openExternal(url)
            } else {
                Self.log.info("review-pane event=blocked host=\(url.host ?? "", privacy: .public)")
                self.showBlockedNotice(host: url.host?.lowercased() ?? "unknown host", url: url)
            }
            self.dismissLoadingCover(ifMainFrame: isMain)
        }
        return true
    }

    // MARK: Signed-out 404

    /// True only when the page answered that no one is signed in (`<meta name="user-login">` missing or
    /// empty). Read in the isolated world; only a boolean leaves the page. No answer counts as "not known",
    /// so no hint.
    @MainActor
    private func isSignedOutOfGitHub() async -> Bool {
        let script = "(function(){const m=document.querySelector('meta[name=\"user-login\"]');"
            + "return !(m && m.content && m.content.trim().length>0);})();"
        return await UnsentInputProbe.boundedBool(timeout: 0.5, onTimeout: false) { [weak self] in
            guard let self else { return false }
            return (try? await self.webView.evaluateJavaScript(script, in: nil, contentWorld: UnsentInputProbe.world)) as? Bool ?? false
        }
    }

    /// `/login?return_to=<path and query of the 404 page>` on the same host, so GitHub returns to the page.
    static func signInURL(for notFound: URL) -> URL? {
        guard var comps = URLComponents(url: notFound, resolvingAgainstBaseURL: false) else { return nil }
        var target = comps.percentEncodedPath
        if let query = comps.percentEncodedQuery { target += "?" + query }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        comps.percentEncodedPath = "/login"
        comps.percentEncodedQuery = "return_to=" + encoded
        comps.fragment = nil
        return comps.url
    }

    private func showSignedOutHint(for notFound: URL) {
        guard let signIn = Self.signInURL(for: notFound) else { return }
        signedOutHintShown = true
        contentView.notice.show(Self.signedOutHint, button: Self.signInButton) { [weak self] in
            self?.webView.load(URLRequest(url: signIn))
        }
    }

    // MARK: Overlays

    private func showBlockedNotice(host: String, url: URL) {
        contentView.notice.show("Blocked a redirect to \(host).", button: "Open in Browser") { [weak self] in
            self?.env.openExternal(url)
        }
    }

    /// A blocked main-frame navigation that is not https: the notice replaces the cover, so the person is
    /// never left looking at a spinner. The button is only offered for a web URL.
    private func showInsecureNotice(url: URL) {
        let host = url.host
        let text = host.map { "Blocked a page on \($0) that isn't secure (https)." } ?? "Blocked a page that isn't secure (https)."
        let button: String? = Self.isWebURL(url) ? "Open in Browser" : nil
        contentView.notice.show(text, button: button, action: button == nil ? nil : { [weak self] in self?.env.openExternal(url) })
    }

    /// A blocked navigation produces no `didCommit`, so a "Loading…" cover would stay over the notice.
    private func dismissLoadingCover(ifMainFrame isMain: Bool) {
        if isMain, contentView.cover.isLoading { contentView.cover.dismiss() }
    }

    private func showDownloadNotice(url: URL?) {
        contentView.notice.show("Downloads open in your browser.", button: url == nil ? nil : "Open in Browser") { [weak self] in
            if let url { self?.env.openExternal(url) }
        }
    }

    private func showError(_ error: Error) {
        let ns = error as NSError
        guard ns.domain != NSURLErrorDomain || ns.code != NSURLErrorCancelled else { return }
        // 102: "Frame load interrupted", what WebKit reports after we cancel a policy decision.
        guard !(ns.domain == "WebKitErrorDomain" && ns.code == 102) else { return }
        let failing = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url ?? tab.currentURL
        failedURL = failing
        let host = failing.host ?? "this page"
        Self.log.info("review-pane event=load-failed host=\(host, privacy: .public) code=\(ns.code, privacy: .public)")
        contentView.cover.show("Can't open \(host). \(Self.cause(of: ns))", button: "Retry") { [weak self] in
            guard let self, let url = self.failedURL else { return }
            self.failedURL = nil
            self.contentView.cover.show("Loading…", spinning: true)
            self.webView.load(URLRequest(url: url))
        }
    }

    /// Plain words for the failure, no URL or response text.
    static func cause(of error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return "The page couldn't be loaded." }
        switch error.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
            return "You appear to be offline."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "The address couldn't be found."
        case NSURLErrorTimedOut:
            return "The connection timed out."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return "The secure connection failed."
        default:
            return "The page couldn't be loaded."
        }
    }

    static func kind(of type: WKNavigationType) -> ReviewNavigationRequest.Kind {
        switch type {
        case .linkActivated: return .link
        case .formSubmitted, .formResubmitted: return .form
        case .backForward: return .backForward
        case .reload: return .reload
        default: return .other
        }
    }
}

// MARK: - Controllers for tabs

extension ReviewPaneModel {

    /// The tab's controller, created the first time the tab is shown (never at restore).
    @discardableResult
    func ensureController(for tab: ReviewTab) -> ReviewTabController {
        if let existing = tab.controller { return existing }
        let controller = ReviewTabController(tab: tab, env: environment)
        wire(controller, for: tab)
        tab.controller = controller
        return controller
    }

    /// A popup from `opener` (SSO windows need `window.opener`, so WebKit's configuration is used).
    func makePopup(from opener: ReviewTab, configuration: WKWebViewConfiguration, url: URL?) -> ReviewTabController {
        var made: ReviewTabController?
        openPage(from: opener, url: url ?? URL(string: "about:blank")!) { tab in
            let controller = ReviewTabController(tab: tab, env: self.environment, configuration: configuration, isPopup: true)
            self.wire(controller, for: tab)
            tab.controller = controller
            made = controller
        }
        return made!
    }

    private func wire(_ controller: ReviewTabController, for tab: ReviewTab) {
        controller.onClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            DispatchQueue.main.async { self.close(tab) }
        }
        controller.onNewWindow = { [weak self, weak tab] configuration, url in
            guard let self, let tab else { return nil }
            return self.makePopup(from: tab, configuration: configuration, url: url)
        }
        controller.onStateChange = { [weak self] in self?.persist() }
    }
}
