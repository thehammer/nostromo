import AppKit
import WebKit

/// A `WKWebView` that records the last gesture a **person** made in it. The navigation policy treats a
/// link click as a user gesture only when a human mouse-up landed ON that link, or Return/Space was
/// pressed with that link focused, within `gestureWindow` (checked by `gestureConfirms(link:)`); page
/// script cannot fake either (SR3). Events app-control synthesised (`SyntheticInputGate`) never count.
final class ReviewWebView: WKWebView {

    static let gestureWindow: TimeInterval = 1

    private enum Gesture {
        /// A mouse-up at a point in this view's (flipped, top-left origin) coordinates.
        case click(CGPoint)
        /// Return or Space (by key code): acts on the focused element.
        case key(UInt16)
    }

    private var lastGesture: (gesture: Gesture, at: TimeInterval)?

    /// A person clicked or pressed Return/Space in the view within `gestureWindow`. Necessary, not
    /// sufficient: `gestureConfirms(link:)` decides whether it was on the link.
    var recentHumanInput: Bool { recentGesture != nil }

    private var recentGesture: Gesture? {
        guard let last = lastGesture, ProcessInfo.processInfo.systemUptime - last.at <= Self.gestureWindow else { return nil }
        return last.gesture
    }

    /// The first click on a link in an inactive window follows the link, as in a browser.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if !SyntheticInputGate.isSynthetic(event) {
            lastGesture = (.click(convert(event.locationInWindow, from: nil)), ProcessInfo.processInfo.systemUptime)
        }
        super.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Return, keypad Enter, Space. Any other key (typing) is not a gesture and forgets an earlier one.
        if !SyntheticInputGate.isSynthetic(event), [36, 76, 49].contains(event.keyCode) {
            lastGesture = (.key(event.keyCode), ProcessInfo.processInfo.systemUptime)
        } else {
            lastGesture = nil
        }
        super.keyDown(with: event)
    }

    /// Whether the recent human gesture was on the link to `url`: the mouse-up was over an `<a href>` for
    /// it, or the focused element is one. False when there was no recent gesture, or the page did not
    /// answer in time.
    @MainActor
    func gestureConfirms(link url: URL) async -> Bool {
        guard let gesture = recentGesture else { return false }
        let target = Self.jsString(url.absoluteString)
        let script: String
        switch gesture {
        case .click(let p):
            script = "(function(){const el=document.elementFromPoint(\(p.x),\(p.y));const a=el&&el.closest('a[href]');"
                + "return !!a && new URL(a.href).href===new URL(\(target)).href;})();"
        case .key:
            script = "(function(){const el=document.activeElement;const a=el&&el.closest&&el.closest('a[href]');"
                + "return !!a && new URL(a.href).href===new URL(\(target)).href;})();"
        }
        return await UnsentInputProbe.boundedBool(timeout: 0.5, onTimeout: false) { [weak self] in
            guard let self else { return false }
            return (try? await self.evaluateJavaScript(script, in: nil, contentWorld: UnsentInputProbe.world)) as? Bool ?? false
        }
    }

    /// Whether the recent human gesture was on the FORM being submitted to `url`: the mouse-up was over
    /// one of its submit controls, or the focused element is one (Return or Space), or Return was pressed
    /// in one of its single-line fields (implicit submission). A click on empty page, or in a textarea or
    /// a different form, is not a gesture on this form, so a script's `form.submit()` that follows it is not
    /// the person's. The form is matched by its (or the control's `formaction`) target, resolved in the page.
    @MainActor
    func gestureConfirms(form url: URL) async -> Bool {
        guard let gesture = recentGesture else { return false }
        let target = Self.jsString(url.absoluteString)
        let pick: String
        var returnKey = "false"
        switch gesture {
        case .click(let p):
            pick = "document.elementFromPoint(\(p.x),\(p.y))"
        case .key(let code):
            pick = "document.activeElement"
            returnKey = code == 49 ? "false" : "true"
        }
        let script = """
        (function(){
          const t=new URL(\(target));
          const same=function(a){try{const u=new URL(a,document.baseURI);return u.protocol===t.protocol&&u.host===t.host&&u.pathname===t.pathname;}catch(e){return false;}};
          const el=\(pick);
          if(!el||!el.closest){return false;}
          let c=el.closest('button,input');
          if(!c||!c.form){return false;}
          const submit=(c.type==='submit'||c.type==='image');
          const field=\(returnKey)&&c.tagName==='INPUT'&&c.type!=='button'&&c.type!=='reset'&&c.type!=='file';
          if(!submit&&!field){return false;}
          const ga=function(n,k){return Element.prototype.getAttribute.call(n,k);};
          const fa=submit?ga(c,'formaction'):null;
          const attr=fa!==null?fa:ga(c.form,'action');
          return same(attr===null||attr===''?document.URL:attr);
        })();
        """
        return await UnsentInputProbe.boundedBool(timeout: 0.5, onTimeout: false) { [weak self] in
            guard let self else { return false }
            return (try? await self.evaluateJavaScript(script, in: nil, contentWorld: UnsentInputProbe.world)) as? Bool ?? false
        }
    }

    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())
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
    /// the tab is kept). Returns on the first answer: a page busy for seconds does not hold it up.
    static func hasUnsentInput(in webView: WKWebView) async -> Bool {
        await boundedBool(timeout: 0.5, onTimeout: true) {
            do {
                let result = try await webView.evaluateJavaScript(query, in: nil, contentWorld: world)
                return (result as? Bool) ?? true
            } catch {
                return true
            }
        }
    }

    /// Runs `work` and a timer against each other and returns whichever answers first. Not a task group:
    /// a group waits for every child, and `evaluateJavaScript` cannot be cancelled, so a busy page would
    /// hold the group (and the caller) until the page answered.
    @MainActor
    static func boundedBool(timeout: TimeInterval, onTimeout: Bool, _ work: @escaping @MainActor () async -> Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            let gate = OnceGate(continuation)
            Task { @MainActor in gate.resume(await work()) }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { gate.resume(onTimeout) }
        }
    }

    /// Resumes a continuation the first time it is asked to, and ignores later answers.
    private final class OnceGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
