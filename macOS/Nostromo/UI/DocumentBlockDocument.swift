import AppKit

/// What the app does with a link inside a document pane, and with the `open_url` of a
/// `pane_action_result`. The client-side safety rail for daemon-rendered documents: the daemon
/// builds the links, but a client opens only what is on this list.
///
/// Foundation-only logic, so the host-less `NostromoTests` bundle can test it directly.
enum DocumentLinkPolicy {
    /// The scheme of an inline action link: `nostromo-action:<id>`.
    static let actionScheme = "nostromo-action"

    enum Disposition: Equatable {
        /// An `https:` link: open it in the browser.
        case openInBrowser(URL)
        /// A `nostromo-action:<id>` link: send the id back as a `pane_action`.
        case action(String)
        /// Anything else (`javascript:`, `file:`, `http:`, `data:`, a relative link, ...): do nothing.
        case ignore
    }

    /// Classify a link attribute value (an `NSTextView` link is a `URL` or a `String`).
    static func disposition(for link: Any) -> Disposition {
        let url: URL?
        switch link {
        case let u as URL: url = u
        case let s as String: url = URL(string: s)
        default: url = nil
        }
        guard let url, let scheme = url.scheme?.lowercased() else { return .ignore }
        switch scheme {
        case "https":
            return (url.host?.isEmpty == false) ? .openInBrowser(url) : .ignore
        case actionScheme:
            guard let id = actionID(from: url) else { return .ignore }
            return .action(id)
        default:
            return .ignore
        }
    }

    /// The action id carried by a `nostromo-action:<id>` URL, or nil when it carries none.
    /// The id is everything after the first colon, so ids such as `verdict:2026-10-26:1:2:useful`
    /// survive intact.
    static func actionID(from url: URL) -> String? {
        let prefix = actionScheme + ":"
        let whole = url.absoluteString
        guard whole.lowercased().hasPrefix(prefix) else { return nil }
        let rest = String(whole.dropFirst(prefix.count))
        let id = rest.removingPercentEncoding ?? rest
        return id.isEmpty ? nil : id
    }

    /// The Huey folder `open_url` may point into: `~/.nostromo/huey/`.
    static func hueyRoot(home: URL = NostromoHome.current) -> URL {
        home.appendingPathComponent(".nostromo/huey", isDirectory: true)
    }

    /// Parse a `pane_action_result`'s `open_url` and return it only if the app may open it: an
    /// `https:` URL, or a `file:` URL that resolves to a path strictly inside `hueyRoot`.
    static func allowedOpenURL(_ raw: String, hueyRoot: URL = DocumentLinkPolicy.hueyRoot()) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https":
            return (url.host?.isEmpty == false) ? url : nil
        case "file":
            // A file URL names a path on this machine; a host other than localhost does not.
            if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" { return nil }
            return isInside(url, root: hueyRoot) ? url : nil
        default:
            return nil
        }
    }

    /// Whether `file` resolves (`..` and symlinks included) to a path strictly inside `root`.
    static func isInside(_ file: URL, root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let fileParts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileParts.count > rootParts.count else { return false }
        return Array(fileParts.prefix(rootParts.count)) == rootParts
    }
}

/// Turns a `document` payload into one attributed string (a dated title, then the blocks), and finds
/// the `nostromo-action:` links in it (Huey's report, context and setup panes).
///
/// `AppKit`-only logic — no `NSTextView`, no window — so the host-less `NostromoTests` bundle can
/// compile and test it directly (dual-membership in `project.pbxproj`). Every block is delegated to
/// `MarkdownBlockDocument`'s rendering helpers; this file adds only the title and the link policy.
/// `DocumentContentView` draws the banner and the action buttons, which are not part of the text.
struct DocumentBlockDocument: Equatable {
    /// One `nostromo-action:` link in the rendered text.
    struct ActionLink: Equatable {
        let range: NSRange
        let actionID: String
    }

    let attributedString: NSAttributedString
    /// Every `nostromo-action:` link in `attributedString`, in order.
    let actionLinks: [ActionLink]

    init(payload: DocumentPayload) {
        let result = NSMutableAttributedString()
        if !payload.title.isEmpty {
            result.append(MarkdownBlockDocument.headingRun(payload.title, level: 1))
            result.append(MarkdownBlockDocument.paragraphBreak())
        }
        result.append(MarkdownBlockDocument.render(blocks: payload.blocks, indent: 0))
        Self.stripDisallowedLinks(in: result)
        attributedString = result
        actionLinks = Self.findActionLinks(in: result)
    }

    /// The action id of the link at `index`, if it is a `nostromo-action:` link.
    func actionID(atCharacterIndex index: Int) -> String? {
        actionLinks.first { NSLocationInRange(index, $0.range) }?.actionID
    }

    static func == (lhs: DocumentBlockDocument, rhs: DocumentBlockDocument) -> Bool {
        lhs.attributedString.isEqual(to: rhs.attributedString) && lhs.actionLinks == rhs.actionLinks
    }

    // MARK: - Links

    /// A link the policy would ignore is not a link at all: it renders as plain text, so it looks
    /// inert and offers no click target or "Open Link" menu item.
    private static func stripDisallowedLinks(in text: NSMutableAttributedString) {
        let whole = NSRange(location: 0, length: text.length)
        var inert: [NSRange] = []
        text.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard let value else { return }
            if DocumentLinkPolicy.disposition(for: value) == .ignore { inert.append(range) }
        }
        for range in inert {
            text.removeAttribute(.link, range: range)
            text.removeAttribute(.underlineStyle, range: range)
            text.addAttribute(.foregroundColor, value: Theme.fg, range: range)
        }
    }

    private static func findActionLinks(in text: NSAttributedString) -> [ActionLink] {
        var found: [ActionLink] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let value, case .action(let id) = DocumentLinkPolicy.disposition(for: value) else { return }
            found.append(ActionLink(range: range, actionID: id))
        }
        return found
    }
}
