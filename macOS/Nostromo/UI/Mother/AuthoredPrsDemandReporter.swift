import AppKit
import CoreGraphics
import NostromoKit

/// Tells the daemon whether anyone is looking at the author's open-PR list, so it polls GitHub fast while
/// the Overview is on screen, slowly while it is not, and not at all while the user is away.
///
/// - `visible`: some window shows the Mother focus with the Overview on the right, that window is on screen
///   and the app is not hidden.
/// - `idle`: no input for 15 minutes, or the screen is locked, or the Mac is asleep.
/// - `hidden`: anything else. The app in the background while the user works elsewhere is still `hidden`:
///   the daemon keeps a slow cadence so the pills (slice 3) stay current.
///
/// A level goes out only when it changes, and again at once after every reconnect's welcome. A change is held
/// for `debounce` (1 s) so flipping tabs sends only the final level; the daemon does not debounce demand itself
/// (its 250 ms debounce is for snapshot publishing). Even a change to `visible` waits that second: the freshness
/// criterion is about seconds, and the Overview shows the last snapshot meanwhile. An old daemon gets nothing.
final class AuthoredPrsDemandReporter {
    enum Level: String, Equatable {
        case visible, hidden, idle
    }

    /// No input for this long counts as away.
    static let idleThreshold: TimeInterval = 900
    /// How often the level is re-evaluated when nothing notified.
    static let reevaluateEvery: TimeInterval = 60
    /// A level change is held this long, so a flip storm sends one message.
    static let debounceInterval: TimeInterval = 1

    /// Runs `work` after `delay` seconds; the returned closure cancels it.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    static let timerScheduler: Scheduler = { delay, work in
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in work() }
        return { timer.invalidate() }
    }

    private let supported: () -> Bool
    private let send: (String) -> Void
    private let idleSeconds: () -> TimeInterval
    private var isOverviewVisible: () -> Bool
    private let distributedCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let appCenter: NotificationCenter
    private let debounce: TimeInterval
    private let schedule: Scheduler
    private var cancelPending: (() -> Void)?

    private(set) var lastSent: Level?
    private var screenLocked = false
    private var asleep = false
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?
    /// The Overview views now in a window; the default visibility check reads these.
    private var overviews = NSHashTable<NSView>.weakObjects()

    /// Seconds since the last keyboard, mouse or trackpad event of any kind.
    static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    init(supported: @escaping () -> Bool,
         send: @escaping (String) -> Void,
         idleSeconds: @escaping () -> TimeInterval = AuthoredPrsDemandReporter.systemIdleSeconds,
         isOverviewVisible: (() -> Bool)? = nil,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         appCenter: NotificationCenter = .default,
         debounce: TimeInterval = AuthoredPrsDemandReporter.debounceInterval,
         schedule: @escaping Scheduler = AuthoredPrsDemandReporter.timerScheduler) {
        self.debounce = debounce
        self.schedule = schedule
        self.supported = supported
        self.send = send
        self.idleSeconds = idleSeconds
        self.distributedCenter = distributedCenter
        self.workspaceCenter = workspaceCenter
        self.appCenter = appCenter
        self.isOverviewVisible = { false }
        self.isOverviewVisible = isOverviewVisible ?? { [weak self] in self?.anyOverviewOnScreen() ?? false }
    }

    deinit { stop() }

    // MARK: Lifecycle

    /// Start listening for lock, sleep, window and app changes, and re-evaluating on a timer.
    func start() {
        guard observers.isEmpty else { return }
        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping (AuthoredPrsDemandReporter) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                handler(self)
            }
            observers.append((center, token))
        }
        observe(distributedCenter, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true; $0.evaluate() }
        observe(distributedCenter, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false; $0.evaluate() }
        observe(workspaceCenter, NSWorkspace.willSleepNotification) { $0.asleep = true; $0.evaluate() }
        observe(workspaceCenter, NSWorkspace.didWakeNotification) { $0.asleep = false; $0.evaluate() }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification, NSWindow.didChangeScreenNotification] {
            observe(appCenter, name) { $0.evaluate() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.reevaluateEvery, repeats: true) { [weak self] _ in self?.evaluate() }
        timer?.tolerance = 5
        evaluate()
    }

    func stop() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        timer?.invalidate()
        timer = nil
        cancelPending?()
        cancelPending = nil
    }

    /// A connection came up (after its welcome): the daemon knows nothing of the last level.
    func connectionStarted() {
        lastSent = nil
        evaluate()
    }

    /// The connection dropped: whatever was last sent is gone with it.
    func connectionLost() {
        lastSent = nil
        cancelPending?()
        cancelPending = nil
    }

    // MARK: Views

    /// An Overview view joined a window (or was shown).
    func overviewChanged(_ view: NSView) {
        overviews.add(view)
        evaluate()
    }

    /// An Overview view left its window.
    func overviewRemoved(_ view: NSView) {
        overviews.remove(view)
        evaluate()
    }

    // MARK: Level

    /// The level right now.
    var level: Level {
        if screenLocked || asleep || idleSeconds() >= Self.idleThreshold { return .idle }
        return isOverviewVisible() ? .visible : .hidden
    }

    /// Work out the level and send it if it changed: at once when the daemon was told nothing yet (first
    /// evaluation, reconnect), else after the debounce, sending whatever the level is by then.
    /// Sends nothing to a daemon without the feature.
    @discardableResult
    func evaluate() -> Level {
        let now = level
        guard supported() else { return now }
        if lastSent == nil || debounce <= 0 {
            cancelPending?()
            cancelPending = nil
            sendIfChanged(now)
        } else if now == lastSent {
            cancelPending?()
            cancelPending = nil
        } else if cancelPending == nil {
            cancelPending = schedule(debounce) { [weak self] in
                guard let self else { return }
                self.cancelPending = nil
                self.sendIfChanged(self.level)
            }
        }
        return now
    }

    private func sendIfChanged(_ level: Level) {
        guard supported(), level != lastSent else { return }
        lastSent = level
        send(level.rawValue)
    }

    // MARK: Visibility

    /// Whether some registered Overview is shown in an on-screen window of a visible app.
    private func anyOverviewOnScreen() -> Bool {
        Self.isOnScreen(overviews.allObjects, appIsHidden: NSApp?.isHidden ?? true) { window in
            window.occlusionState.contains(.visible) && window.isOnActiveSpace
        }
    }

    static func isOnScreen(_ views: [NSView], appIsHidden: Bool, windowIsVisible: (NSWindow) -> Bool) -> Bool {
        guard !appIsHidden else { return false }
        return views.contains { view in
            guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return windowIsVisible(window)
        }
    }
}

// MARK: - Debug ▸ Copy GitHub usage

/// What Debug ▸ Copy GitHub usage puts on the pasteboard: the daemon's charged-request counts, nothing else
/// (no titles, repos, logins or tokens).
enum AuthoredPrsDiagnostics {
    static func report(for snapshot: AuthoredPrsSnapshot?) -> String {
        guard let snapshot else { return "No GitHub usage reported yet." }
        return AuthoredPrsPresentation.usageReport(snapshot.usage)
    }

    @discardableResult
    static func copyReportToPasteboard(store: AppStore = .shared, pasteboard: NSPasteboard = .general) -> String {
        let text = report(for: store.authoredPrs)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return text
    }
}
