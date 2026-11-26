// NostromoKit — PushModel.swift
//
// The phone's side of push notifications (W13), over the same WebSocket transport as everything else:
//
//   - registers the Apple push token with the primary whenever the link is up (`register_push`);
//   - holds this device's settings, the read-only host classes and work owners, and whether
//     notifications are getting through (`push_status`);
//   - reconciles on every foreground connect: asks what waits (`push_waiting`), so the app can remove
//     delivered notifications whose item is no longer waiting and set the badge (S1: replace in place,
//     and removal when the app runs);
//   - lists the notifications sent to this device (`push_sent_log`);
//   - remembers which notification the operator tapped.
//
// It sends only the four paired-device push verbs, none of which changes anything on a Mac, and
// answers nothing: a tapped decision opens a read-only screen ("Answer it on your Mac").

import Foundation
import Combine

@MainActor
public final class PushModel: ObservableObject {

    // MARK: - State

    @Published public private(set) var prefs = PushPrefsWire.default
    @Published public private(set) var status: PushStatusWire?
    @Published public private(set) var waiting: [PushWaitingItemWire] = []
    @Published public private(set) var badge = 0
    @Published public private(set) var sentLog: [PushSentEntryWire] = []
    /// Set once the first `push_waiting` answer after a (re)connect arrived or the wait gave up.
    @Published public private(set) var reconciled = false
    /// The notification the operator tapped, until the screen for it is dismissed.
    @Published public var tapped: PushPayload?

    /// The hex APNs token iOS issued, once it has. Setting it registers it if the link is up.
    public var apnsToken: String? {
        didSet { registerIfPossible() }
    }

    /// `sandbox` in a development build, `production` otherwise.
    public var environment: PushEnvironmentWire

    /// How long the first screen waits for the reconcile before it accepts input anyway.
    public let reconcileTimeout: TimeInterval

    // MARK: - Wiring

    private let transport: DaemonTransport
    private var bag = Set<AnyCancellable>()
    private var reconcileDeadline: Task<Void, Never>?

    public init(transport: DaemonTransport, environment: PushEnvironmentWire = .production,
                reconcileTimeout: TimeInterval = 2) {
        self.transport = transport
        self.environment = environment
        self.reconcileTimeout = reconcileTimeout
        transport.framePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handle($0) }
            .store(in: &bag)
        transport.connectedPublisher
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] up in
                if up { self?.connected() } else { self?.disconnected() }
            }
            .store(in: &bag)
    }

    // MARK: - Verbs

    /// Tell the primary about this device's token, if the link is up and iOS issued one.
    public func registerIfPossible() {
        guard transport.connected, let token = apnsToken, !token.isEmpty else { return }
        transport.send(ClientRegisterPush(apnsToken: token, environment: environment))
    }

    /// Ask what waits on the operator now.
    public func requestWaiting() {
        guard transport.connected else { return }
        transport.send(ClientPushWaiting())
    }

    public func requestSentLog() {
        guard transport.connected else { return }
        transport.send(ClientPushSentLog())
    }

    /// Change this device's settings. The screen shows the new value at once; the primary's
    /// `push_status` answer replaces it with what it kept.
    public func update(_ change: (inout PushPrefsWire) -> Void) {
        var next = prefs
        change(&next)
        prefs = next
        transport.send(ClientSetPushPrefs(prefs: next))
    }

    // MARK: - Link

    private func connected() {
        reconciled = false
        registerIfPossible()
        requestWaiting()
        reconcileDeadline?.cancel()
        let timeout = reconcileTimeout
        reconcileDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reconciled = true
        }
    }

    private func disconnected() {
        // Nothing to wait for while the primary is out of reach: do not hold the first screen.
        reconcileDeadline?.cancel()
        reconciled = true
    }

    // MARK: - Frames

    private func handle(_ hosted: HostedServerMsg) {
        guard hosted.host == nil else { return }
        switch hosted.msg {
        case .pushStatus(let status):
            self.status = status
            prefs = status.prefs
        case .pushWaiting(let items, let badge):
            waiting = items
            self.badge = badge
            reconciled = true
            reconcileDeadline?.cancel()
        case .pushSentLog(let entries):
            sentLog = entries
        default:
            break
        }
    }

    // MARK: - Pure helpers

    /// The delivered notifications to remove: those naming an item that is no longer waiting. A
    /// summary stays (it is not one item). `delivered` is each delivered notification's payload.
    public static func staleItems(delivered: [PushPayload], waiting: [PushWaitingItemWire]) -> [String] {
        let live = Set(waiting.map(\.itemRef))
        return delivered
            .filter { $0.kind != .summary && !live.contains($0.item) }
            .map(\.item)
    }

    /// The banner for notifications that are not getting through: shown when the failure is older than
    /// 15 minutes. `Notifications haven't been delivered since 2:14 pm`.
    public static func bannerText(failingSince: Date?, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let since = failingSince, now.timeIntervalSince(since) > 15 * 60 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return "Notifications haven't been delivered since \(f.string(from: since))"
    }

    /// `Details stay on kobe`: how the settings screen lists a work host (no toggle, operator Q3).
    public static func workHosts(in classes: [String: HostClassWire], seen: [String]) -> [String] {
        Set(seen + classes.keys).filter { classes[$0] != .personal }.sorted()
    }
}
