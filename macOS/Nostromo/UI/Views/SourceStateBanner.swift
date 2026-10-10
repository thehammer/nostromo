import AppKit

/// One banner per `SourceState` (PRD "Source states"), plus the daemon-
/// disconnected variant. A pure view: feed it a status via `show`, it decides
/// what to say and whether to appear at all. Never shows secret values — it
/// only prints the daemon's plain-English `reason`.
final class SourceStateBanner: NSView {
    /// What the banner should present. `nil` text means "hidden".
    struct Content: Equatable {
        let message: String
        /// Offer a Retry button (stale / error).
        let showsRetry: Bool
    }

    /// Called when the user presses Retry.
    var onRetry: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    /// Present `status` for a source named `sourceName` ("Jira", "Sentry", …).
    /// Hidden for fresh data and for the positive empty state (the list shows
    /// its own empty message).
    func show(status: SourceStatus?, sourceName: String, now: Date = Date()) {
        apply(Self.content(for: status, sourceName: sourceName, now: now))
    }

    /// The single "Disconnected from nostromd" banner shown over all tabs.
    func showDisconnected() {
        apply(Self.disconnectedContent)
    }

    var content: Content? { currentContent }
    private var currentContent: Content?

    // MARK: - Content (pure)

    static let disconnectedContent = Content(message: "Disconnected from nostromd", showsRetry: false)

    static func content(for status: SourceStatus?, sourceName: String, now: Date = Date()) -> Content? {
        guard let status else {
            return Content(message: "Loading \(sourceName)…", showsRetry: false)
        }
        let reason = status.reason.map { ": \($0)" } ?? ""
        switch status.state {
        case .loading:
            return Content(message: "Loading \(sourceName)…", showsRetry: false)
        case .fresh, .empty:
            return nil
        case .stale:
            let age = status.updatedAt.map { " last updated \(relative($0, now: now))" } ?? ""
            return Content(message: "Stale:\(age)\(reason)", showsRetry: true)
        case .notConfigured, .unauthenticated:
            let why = status.reason ?? "no credentials found"
            return Content(message: "\(sourceName): \(why)", showsRetry: false)
        case .rateLimited:
            let retry = status.retryAt.map { "; retrying at \(clock($0))" } ?? ""
            return Content(message: "Rate-limited by \(sourceName)\(retry)", showsRetry: false)
        case .error:
            return Content(message: "\(sourceName) failed\(reason)", showsRetry: true)
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let secs = max(0, Int(now.timeIntervalSince(date)))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) min ago" }
        return "\(secs / 3600) h ago"
    }

    private static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    // MARK: - View

    private func setUp() {
        wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isHidden = true
    }

    private func apply(_ content: Content?) {
        currentContent = content
        isHidden = content == nil
        label.stringValue = content?.message ?? ""
        retryButton.isHidden = !(content?.showsRetry ?? false)
    }

    @objc private func retryPressed() { onRetry?() }
}
