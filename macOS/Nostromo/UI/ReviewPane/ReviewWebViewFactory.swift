import AppKit
import WebKit

/// A `WKWebView` that records when a **person** last clicked or typed in it. The navigation policy
/// treats a link click as a user gesture only when a human event reached the view within
/// `gestureWindow`; page script cannot fake that (SR3). Events app-control synthesised
/// (`SyntheticInputGate`) never count.
final class ReviewWebView: WKWebView {

    static let gestureWindow: TimeInterval = 1

    private var lastHumanInput: TimeInterval?

    var recentHumanInput: Bool {
        guard let last = lastHumanInput else { return false }
        return ProcessInfo.processInfo.systemUptime - last <= Self.gestureWindow
    }

    /// The first click on a link in an inactive window follows the link, as in a browser.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { note(event); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { note(event); super.rightMouseDown(with: event) }
    override func keyDown(with event: NSEvent) { note(event); super.keyDown(with: event) }

    private func note(_ event: NSEvent) {
        guard !SyntheticInputGate.isSynthetic(event) else { return }
        lastHumanInput = ProcessInfo.processInfo.systemUptime
    }
}

/// Builds the configuration every review web view uses (SR6: no message handler, no page-world script).
enum ReviewWebViewFactory {

    /// The only script: the unsent-input probe, in its own content world (`UnsentInputProbe`).
    static func makeConfiguration(dataStore: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        // `WKProcessPool` is deprecated and a no-op since macOS 12: one app-wide pool is the default.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true   // every popup reaches the policy
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        if #available(macOS 15.0, *) { config.upgradeKnownHostsToHTTPS = true }
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addUserScript(UnsentInputProbe.userScript)
        return config
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> ReviewWebView {
        let webView = ReviewWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        return webView
    }
}

/// Answers "did the person type text that is still unsent?" for a tab (criterion 23, reframed).
///
/// WebKit has no public API that says whether a page's `beforeunload` would ask without running the
/// handler, so this watches trusted `input` events instead. The script lives in a private content world:
/// page script cannot see or call it, and there is no message handler. Only a boolean leaves the page,
/// never text. `<input>` elements are never considered (no password, search or code field is read).
enum UnsentInputProbe {

    static let world = WKContentWorld.world(name: "nostromo-review")

    private static let source = """
    (function () {
      if (window.__nostromoSeen) { return; }
      const seen = new Set();
      window.__nostromoSeen = seen;
      document.addEventListener('input', function (e) {
        if (e.isTrusted === true && e.target) { seen.add(e.target); }
      }, true);
    })();
    """

    private static let query = """
    (function () {
      const seen = window.__nostromoSeen;
      if (!seen) { return false; }
      for (const el of seen) {
        if (!el.isConnected) { continue; }
        if (el.tagName === 'TEXTAREA' && el.value.trim().length > 0) { return true; }
        if (el.isContentEditable && (el.textContent || '').trim().length > 0) { return true; }
      }
      return false;
    })();
    """

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// True when text is unsent. A probe that errors or takes over 500 ms counts as unsent (fail safe:
    /// the tab is kept).
    static func hasUnsentInput(in webView: WKWebView) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                do {
                    let result = try await webView.evaluateJavaScript(query, in: nil, contentWorld: world)
                    return (result as? Bool) ?? true
                } catch {
                    return true
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return true
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
    }
}
