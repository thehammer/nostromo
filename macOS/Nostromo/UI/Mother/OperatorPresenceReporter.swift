import AppKit
import CoreGraphics

/// Tells the daemon whether the operator is at this Mac, so a decision is pushed to a phone at once when
/// the Mac presenting it is locked, asleep or idle for 2 minutes (W13, S7a).
///
/// `away` = the screen is locked, or the Mac is asleep, or no input for `idleThreshold`; otherwise `active`.
/// Re-evaluated every 15 s and on every lock, unlock, sleep and wake. A state goes out only when it
/// changes, and again after each reconnect's welcome. The change to `away` is urgent and not debounced;
/// the change to `active` waits 1 s. Sleep is best effort: the daemon sleeps with the Mac, so an `away`
/// sent at `willSleep` may never leave it, and the daemon's own 30-second rule covers that.
/// Nothing is sent to a daemon that did not advertise `presence`.
final class OperatorPresenceReporter {
    enum State: String, Equatable { case active, away }

    static let idleThreshold: TimeInterval = 120
    static let reevaluateEvery: TimeInterval = 15
    static let activeDebounce: TimeInterval = 1

    typealias Scheduler = AuthoredPrsDemandReporter.Scheduler

    private let supported: () -> Bool
    private let send: (String) -> Void
    private let idleSeconds: () -> TimeInterval
    private let distributedCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let debounce: TimeInterval
    private let schedule: Scheduler
    private var cancelPending: (() -> Void)?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: Timer?

    private(set) var lastSent: State?
    private var screenLocked = false
    private var asleep = false

    init(supported: @escaping () -> Bool,
         send: @escaping (String) -> Void,
         idleSeconds: @escaping () -> TimeInterval = AuthoredPrsDemandReporter.systemIdleSeconds,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         debounce: TimeInterval = OperatorPresenceReporter.activeDebounce,
         schedule: @escaping Scheduler = AuthoredPrsDemandReporter.timerScheduler) {
        self.supported = supported
        self.send = send
        self.idleSeconds = idleSeconds
        self.distributedCenter = distributedCenter
        self.workspaceCenter = workspaceCenter
        self.debounce = debounce
        self.schedule = schedule
    }

    deinit { stop() }

    func start() {
        guard observers.isEmpty else { return }
        func observe(_ center: NotificationCenter, _ name: Notification.Name,
                     _ handler: @escaping (OperatorPresenceReporter) -> Void) {
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
        timer = Timer.scheduledTimer(withTimeInterval: Self.reevaluateEvery, repeats: true) { [weak self] _ in self?.evaluate() }
        timer?.tolerance = 2
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

    /// A connection came up (after its welcome): the daemon knows nothing of the last state.
    func connectionStarted() {
        lastSent = nil
        evaluate()
    }

    func connectionLost() {
        lastSent = nil
        cancelPending?()
        cancelPending = nil
    }

    var state: State {
        (screenLocked || asleep || idleSeconds() >= Self.idleThreshold) ? .away : .active
    }

    @discardableResult
    func evaluate() -> State {
        let now = state
        guard supported() else { return now }
        if now == lastSent {
            cancelPending?()
            cancelPending = nil
        } else if now == .away || lastSent == nil || debounce <= 0 {
            cancelPending?()
            cancelPending = nil
            sendIfChanged(now)
        } else if cancelPending == nil {
            cancelPending = schedule(debounce) { [weak self] in
                guard let self else { return }
                self.cancelPending = nil
                self.sendIfChanged(self.state)
            }
        }
        return now
    }

    private func sendIfChanged(_ state: State) {
        guard supported(), state != lastSent else { return }
        lastSent = state
        send(state.rawValue)
    }
}
